-- AutoPilot_Home.lua
-- Safehouse containment: defines and enforces a home radius for automated modes.
--
-- The "Goldilocks" system ensures the player never wanders outside their
-- safehouse bounds during automated exercise or pilot mode.
--
-- Home position persists via player:getModData() so it survives save/load
-- and is scoped per-player (no cross-player key collision in MP).
-- ModData key (within player's table): "AutoPilot_Home" → {x, y, z, r}
--
-- SPLITSCREEN: Per-player cache — homes[playerNum] is independent for each
-- local player.  Up to 4 players each get their own home anchor.

AutoPilot_Home = {}

local function _apNoop(...) end
local print = _apNoop

local HOME_DEFAULT_RADIUS = AutoPilot_Constants.HOME_DEFAULT_RADIUS
local PLAYER_MODDATA_KEY  = "AutoPilot_Home"

-- Per-player in-memory cache.  Keyed by playerNum (0-based integer).
-- Each entry: { x, y, z, r }
local homes = {}
-- Per-player list of up to 3 fallback shelter squares (M3.4 multi-shelter).
-- Each entry: IsoGridSquare reference.
local homeFallbacks = {}   -- [playerNum] -> { sq, sq, … } (up to 3)

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Derive a 0-based player number from either a player object or an explicit
-- integer.  Falls back to 0 so all code remains backward-compatible with
-- single-player paths that never call player:getPlayerNum().
local function _pnum(player, playerNum)
    if playerNum ~= nil then return playerNum end
    if player then
        local ok, n = pcall(function() return player:getPlayerNum() end)
        if ok and type(n) == "number" then return n end
    end
    return 0
end

local function _getHome(pnum)
    return homes[pnum] or {}
end

local function _setHome(pnum, x, y, z, r)
    homes[pnum] = { x = x, y = y, z = z, r = r }
end

-- ── Persistence helpers ───────────────────────────────────────────────────────

-- Loads home from the player's own ModData table into homes[pnum].
-- Returns true if valid data was found and cached.
local function loadFromModData(player, pnum)
    if not player then return false end
    local ok, data = pcall(function()
        return player:getModData()[PLAYER_MODDATA_KEY]
    end)
    if ok and data and data.x then
        local px = math.floor(player:getX())
        local py = math.floor(player:getY())
        local dist2 = (data.x - px)^2 + (data.y - py)^2
        if dist2 > 300 * 300 then
            print("[AutoPilot] [Home] ModData home rejected: too far from current position.")
            return false
        end
        -- M3.4: validate home coordinate is not inside a wall; shift if needed.
        local hx, hy, hz = data.x, data.y, data.z or 0
        local cell = getCell()
        if cell then
            local sq = cell:getGridSquare(hx, hy, hz)
            if sq then
                local okFree, isFree = pcall(function() return sq:isFree(false) end)
                if not (okFree and isFree) then
                    print("[AutoPilot] [Home] Home square is inside a wall — scanning nearby.")
                    local freeSq = AutoPilot_Utils.findNearestSquare(hx, hy, hz, 5, function(s)
                        local f, v = pcall(function() return s:isFree(false) end)
                        return f and v
                    end)
                    if freeSq then
                        hx = freeSq:getX()
                        hy = freeSq:getY()
                        hz = freeSq:getZ()
                        print("[AutoPilot] [Home] Shifted home to nearest free square.")
                    else
                        print("[AutoPilot] [Home] No free square found near ModData home; using as-is.")
                    end
                end
            end
        end
        _setHome(pnum, hx, hy, hz,
            math.min(data.r or HOME_DEFAULT_RADIUS, 50))
        return true
    end
    return false
end

-- Saves homes[pnum] into the player's own ModData and transmits to the server.
local function saveToModData(player, pnum)
    if not player then return end
    local h = _getHome(pnum)
    pcall(function()
        player:getModData()[PLAYER_MODDATA_KEY] = {
            x = h.x,
            y = h.y,
            z = h.z,
            r = h.r,
        }
        player:transmitModData()
    end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Lock home to the player's current position.
function AutoPilot_Home.set(player)
    local pnum = _pnum(player)
    local x = math.floor(player:getX())
    local y = math.floor(player:getY())
    local z = player:getZ()
    local r = HOME_DEFAULT_RADIUS
    _setHome(pnum, x, y, z, r)
    saveToModData(player, pnum)
    print(string.format("[AutoPilot] [Home] Player %d home set at %d, %d (z=%d, r=%d).",
        pnum, x, y, z, r))
end

--- Returns true if a home position has been registered for this player.
--- Accepts an optional explicit playerNum for call sites that have no player.
function AutoPilot_Home.isSet(player, playerNum)
    local pnum = _pnum(player, playerNum)
    local h = _getHome(pnum)
    if h.x then return true end
    return loadFromModData(player, pnum)
end

--- Returns true if the given IsoSquare is within home bounds for playerNum.
--- When home is not set, all squares are considered inside (no restriction).
--- playerNum defaults to 0 for backward-compatible single-player callers.
function AutoPilot_Home.isInside(sq, playerNum)
    local pnum = playerNum or 0
    if not AutoPilot_Home.isSet(nil, pnum) then return true end
    if not sq then return false end
    local h = _getHome(pnum)
    if sq:getZ() ~= h.z then return false end
    local dx = sq:getX() - h.x
    local dy = sq:getY() - h.y
    return (dx * dx + dy * dy) <= (h.r * h.r)
end

--- If targetSq is outside home bounds, returns the nearest free in-bounds square.
--- Returns targetSq unchanged if it is already inside.
--- Returns nil if no suitable square is found near the edge.
function AutoPilot_Home.clampSq(targetSq, player)
    if not AutoPilot_Home.isSet(player) then return targetSq end
    if not targetSq then return nil end
    local pnum = _pnum(player)
    if AutoPilot_Home.isInside(targetSq, pnum) then return targetSq end

    local h = _getHome(pnum)
    -- Project target onto the edge of the home circle.
    local tx = targetSq:getX()
    local ty = targetSq:getY()
    local dx = tx - h.x
    local dy = ty - h.y
    local len = math.sqrt(dx * dx + dy * dy)
    local edgeX, edgeY
    if len < 0.001 then
        edgeX = h.x
        edgeY = h.y
    else
        edgeX = math.floor(h.x + (dx / len) * (h.r - 1))
        edgeY = math.floor(h.y + (dy / len) * (h.r - 1))
    end

    -- Search near the projected edge point for a free walkable in-bounds square.
    local sq = AutoPilot_Utils.findNearestSquare(edgeX, edgeY, h.z, 5, function(s)
        return s:isFree(false) and AutoPilot_Home.isInside(s, pnum)
    end)
    if sq then return sq end

    print("[AutoPilot] [Home] clampSq: no free in-bounds square found near edge.")
    return nil
end

--- Scans all squares inside home bounds and returns the nearest one satisfying predicate.
--- predicate: function(sq) -> boolean
--- radius: optional search radius cap (capped to home_r)
function AutoPilot_Home.getNearestInside(player, predicate, radius)
    if not AutoPilot_Home.isSet(player) then return nil end

    local pnum = _pnum(player)
    local h    = _getHome(pnum)
    local hr   = h.r or HOME_DEFAULT_RADIUS
    local searchR = math.min(radius or hr, hr)
    local bestSq   = nil
    local bestDist = math.huge

    local cell = getCell()
    if not cell then return nil end
    for dx = -searchR, searchR do
        for dy = -searchR, searchR do
            -- Skip corners outside the circular radius.
            if dx * dx + dy * dy <= hr * hr then
                local sq = cell:getGridSquare(h.x + dx, h.y + dy, h.z)
                if sq then
                    local ok, match = pcall(predicate, sq)
                    if ok and match then
                        local dist = dx * dx + dy * dy
                        if dist < bestDist then
                            bestDist = dist
                            bestSq   = sq
                        end
                    end
                end
            end
        end
    end

    return bestSq
end

--- Returns the current home values for the given player.
--- Accepts an optional player; falls back to player 0 cache when nil.
function AutoPilot_Home.getState(player)
    local pnum = _pnum(player)
    AutoPilot_Home.isSet(player, pnum)   -- trigger ModData load on cache miss
    local h = _getHome(pnum)
    return h.x, h.y, h.z, h.r
end

--- Register a candidate fallback shelter square for a player (M3.4 multi-shelter).
--- Keeps up to 3 entries; oldest is discarded when the list is full.
--- @param player IsoPlayer
--- @param sq     IsoGridSquare
function AutoPilot_Home.addFallback(player, sq)
    if not sq then return end
    local pnum = _pnum(player)
    if not homeFallbacks[pnum] then homeFallbacks[pnum] = {} end
    local list = homeFallbacks[pnum]
    -- Avoid duplicates (same coordinate)
    for _, s in ipairs(list) do
        if s:getX() == sq:getX() and s:getY() == sq:getY() and s:getZ() == sq:getZ() then
            return
        end
    end
    if #list >= 3 then table.remove(list, 1) end
    table.insert(list, sq)
end

--- Return the nearest valid fallback shelter square for a player (M3.4).
--- Checks isFree on each candidate; removes stale entries.
--- @param player IsoPlayer
--- @return IsoGridSquare|nil
function AutoPilot_Home.getNearestFallback(player)
    local pnum = _pnum(player)
    local list = homeFallbacks[pnum]
    if not list or #list == 0 then return nil end
    local px, py = player:getX(), player:getY()
    local bestSq, bestDist = nil, math.huge
    local stale = {}
    for i, sq in ipairs(list) do
        local okFree, isFree = pcall(function() return sq:isFree(false) end)
        if okFree and isFree then
            local dist = (sq:getX() - px)^2 + (sq:getY() - py)^2
            if dist < bestDist then
                bestDist = dist
                bestSq   = sq
            end
        else
            table.insert(stale, i)
        end
    end
    -- Remove stale entries (reverse order to preserve indices)
    for i = #stale, 1, -1 do
        table.remove(list, stale[i])
    end
    return bestSq
end
