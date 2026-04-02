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
-- SPLITSCREEN NOTE: Module-level cache (home_x/y/z/r) is shared across all
-- local players.  Splitscreen is NOT supported.

AutoPilot_Home = {}

local HOME_DEFAULT_RADIUS = 150
local PLAYER_MODDATA_KEY  = "AutoPilot_Home"

-- In-memory cache (populated on set or first load from ModData)
local home_x = nil
local home_y = nil
local home_z = nil
local home_r = HOME_DEFAULT_RADIUS

-- ── Persistence helpers ───────────────────────────────────────────────────────

-- Loads home from the player's own ModData table.
-- Returns true if valid data was found and cached.
local function loadFromModData(player)
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
        home_x = data.x
        home_y = data.y
        home_z = data.z
        home_r = math.min(data.r or HOME_DEFAULT_RADIUS, 50)
        return true
    end
    return false
end

-- Saves home into the player's own ModData and transmits to the server.
-- Uses player:transmitModData() — the server expects clients to own their
-- own player ModData, so this is the MP-safe pattern (no global ModData.transmit).
local function saveToModData(player)
    if not player then return end
    pcall(function()
        player:getModData()[PLAYER_MODDATA_KEY] = {
            x = home_x,
            y = home_y,
            z = home_z,
            r = home_r,
        }
        player:transmitModData()
    end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Lock home to the player's current position.
function AutoPilot_Home.set(player)
    home_x = math.floor(player:getX())
    home_y = math.floor(player:getY())
    home_z = player:getZ()
    home_r = HOME_DEFAULT_RADIUS
    saveToModData(player)
    -- Use log only — player:Say() is world-visible in MP and reveals AFK status.
    print(string.format("[AutoPilot] [Home] Home set at %d, %d (z=%d, r=%d).", home_x, home_y, home_z, home_r))
end

--- Returns true if a home position has been registered.
--- Accepts an optional player to load from their ModData on a cache miss.
--- Call sites that have no player context (e.g. isInside) pass nil and rely
--- on the in-memory cache that was populated earlier in the session.
function AutoPilot_Home.isSet(player)
    if home_x then return true end
    return loadFromModData(player)
end

--- Returns true if the given IsoSquare is within home bounds.
--- When home is not set, all squares are considered inside (no restriction).
function AutoPilot_Home.isInside(sq)
    if not AutoPilot_Home.isSet() then return true end
    if not sq then return false end
    if sq:getZ() ~= home_z then return false end
    local dx = sq:getX() - home_x
    local dy = sq:getY() - home_y
    return (dx * dx + dy * dy) <= (home_r * home_r)
end

--- If targetSq is outside home bounds, returns the nearest free in-bounds square.
--- Returns targetSq unchanged if it is already inside.
--- Returns nil if no suitable square is found near the edge.
function AutoPilot_Home.clampSq(targetSq, player)
    if not AutoPilot_Home.isSet(player) then return targetSq end
    if not targetSq then return nil end
    if AutoPilot_Home.isInside(targetSq) then return targetSq end

    -- Project target onto the edge of the home circle
    local tx = targetSq:getX()
    local ty = targetSq:getY()
    local dx = tx - home_x
    local dy = ty - home_y
    local len = math.sqrt(dx * dx + dy * dy)
    local edgeX, edgeY
    if len < 0.001 then
        edgeX = home_x
        edgeY = home_y
    else
        edgeX = math.floor(home_x + (dx / len) * (home_r - 1))
        edgeY = math.floor(home_y + (dy / len) * (home_r - 1))
    end

    -- Search near the projected edge point for a free walkable in-bounds square.
    local sq = AutoPilot_Utils.findNearestSquare(edgeX, edgeY, home_z, 5, function(s)
        return s:isFree(false) and AutoPilot_Home.isInside(s)
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

    local searchR = math.min(radius or home_r, home_r)
    local bestSq   = nil
    local bestDist = math.huge

    local cell = getCell()
    if not cell then return nil end
    for dx = -searchR, searchR do
        for dy = -searchR, searchR do
            -- Skip corners outside the circular radius
            if dx * dx + dy * dy <= home_r * home_r then
                local sq = cell:getGridSquare(home_x + dx, home_y + dy, home_z)
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

--- Returns the current home values for state JSON.
--- All values may be nil if home has not been set.
function AutoPilot_Home.getState()
    AutoPilot_Home.isSet(nil)  -- cache-only check; player not available here
    return home_x, home_y, home_z, home_r
end
