-- AutoPilot_Home.lua
-- Safehouse containment: defines and enforces a home radius for automated modes.
--
-- The "Goldilocks" system ensures the player never wanders outside their
-- safehouse bounds during automated exercise or pilot mode.
--
-- Home position persists via ModData so it survives save/load.
-- ModData key: "AutoPilot_Home" → {x, y, z, r}

AutoPilot_Home = {}

local HOME_DEFAULT_RADIUS = 15
local MODDATA_KEY = "AutoPilot_Home"

-- In-memory cache (populated on set or first load from ModData)
local home_x = nil
local home_y = nil
local home_z = nil
local home_r = HOME_DEFAULT_RADIUS

-- ── Persistence helpers ───────────────────────────────────────────────────────

local function loadFromModData()
    local ok, data = pcall(function()
        return ModData.getOrCreate(MODDATA_KEY)
    end)
    if ok and data and data.x then
        home_x = data.x
        home_y = data.y
        home_z = data.z
        home_r = data.r or HOME_DEFAULT_RADIUS
        return true
    end
    return false
end

local function saveToModData()
    pcall(function()
        local data = ModData.getOrCreate(MODDATA_KEY)
        data.x = home_x
        data.y = home_y
        data.z = home_z
        data.r = home_r
        ModData.transmit(MODDATA_KEY)
    end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Lock home to the player's current position.
function AutoPilot_Home.set(player)
    home_x = math.floor(player:getX())
    home_y = math.floor(player:getY())
    home_z = player:getZ()
    home_r = HOME_DEFAULT_RADIUS
    saveToModData()
    AutoPilot_LLM.log(string.format(
        "[Home] Home set at %d, %d (z=%d, r=%d).", home_x, home_y, home_z, home_r))
    if player then
        player:Say(string.format("Home set at %d, %d", home_x, home_y))
    end
end

--- Returns true if a home position has been registered (checks ModData if not cached).
function AutoPilot_Home.isSet()
    if home_x then return true end
    return loadFromModData()
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
    if not AutoPilot_Home.isSet() then return targetSq end
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

    -- Search near the projected edge point for a free walkable square inside bounds
    for r = 0, 5 do
        for ddx = -r, r do
            for ddy = -r, r do
                local sq = getCell():getGridSquare(edgeX + ddx, edgeY + ddy, home_z)
                if sq and sq:isFree(false) and AutoPilot_Home.isInside(sq) then
                    return sq
                end
            end
        end
    end

    AutoPilot_LLM.log("[Home] clampSq: no free in-bounds square found near edge.")
    return nil
end

--- Scans all squares inside home bounds and returns the nearest one satisfying predicate.
--- predicate: function(sq) -> boolean
--- radius: optional search radius cap (capped to home_r)
function AutoPilot_Home.getNearestInside(player, predicate, radius)
    if not AutoPilot_Home.isSet() then return nil end

    local searchR = math.min(radius or home_r, home_r)
    local bestSq   = nil
    local bestDist = math.huge

    for dx = -searchR, searchR do
        for dy = -searchR, searchR do
            -- Skip corners outside the circular radius
            if dx * dx + dy * dy <= home_r * home_r then
                local sq = getCell():getGridSquare(home_x + dx, home_y + dy, home_z)
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

--- Returns the current home values for LLM state JSON.
--- All values may be nil if home has not been set.
function AutoPilot_Home.getState()
    AutoPilot_Home.isSet()  -- trigger ModData load if not yet cached
    return home_x, home_y, home_z, home_r
end
