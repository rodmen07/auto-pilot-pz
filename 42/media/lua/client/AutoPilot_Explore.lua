-- AutoPilot_Explore.lua
-- Autonomous frontier exploration: scouts 8 compass sectors, loots at the
-- frontier, and returns home between trips.
--
-- State machine:
--   idle      -> countdown decrements each cycle; when 0 flip to outbound.
--   outbound  -> queue walk to frontier; flip to returning; wait for queue.
--   returning -> wait for queue; loot at frontier; queue walk home; arrive.
--
-- Depends on: AutoPilot_Constants, AutoPilot_Home, AutoPilot_Inventory,
--             AutoPilot_Utils, ISTimedActionQueue, ISWalkToTimedAction.

AutoPilot_Explore = {}

local function _apNoop(...) end
local print = _apNoop

-- 8 compass directions as unit vectors (N, NE, E, SE, S, SW, W, NW).
local SECTORS = {
    {  0, -1 },   -- N
    {  1, -1 },   -- NE
    {  1,  0 },   -- E
    {  1,  1 },   -- SE
    {  0,  1 },   -- S
    { -1,  1 },   -- SW
    { -1,  0 },   -- W
    { -1, -1 },   -- NW
}
-- Normalize diagonal unit vectors so all have length 1.
for _, v in ipairs(SECTORS) do
    local len = math.sqrt(v[1] * v[1] + v[2] * v[2])
    v[1] = v[1] / len
    v[2] = v[2] / len
end

-- Module state -----------------------------------------------------------
AutoPilot_Explore._phase       = "idle"   -- "idle" | "outbound" | "returning"
AutoPilot_Explore._cooldown    = 0        -- eval cycles before next trip
AutoPilot_Explore._sectorIdx   = 1        -- current sector index (1..EXPLORE_SECTORS)
AutoPilot_Explore._expandCount = 0        -- full rotations completed (drives radius)
AutoPilot_Explore._looted      = false    -- true once loot pass done this trip

-- Current exploration radius (tiles from home centre).
-- Grows by EXPLORE_RADIUS_INCREMENT each full sector rotation.
local function exploreRadius()
    local _, _, _, home_r = AutoPilot_Home.getState()
    local base = (type(home_r) == "number" and home_r > 0)
        and home_r or AutoPilot_Constants.HOME_DEFAULT_RADIUS
    local r = base
        + AutoPilot_Explore._expandCount * AutoPilot_Constants.EXPLORE_RADIUS_INCREMENT
    return math.min(r, AutoPilot_Constants.EXPLORE_RADIUS_MAX)
end

-- Walk to the nearest free square inside home bounds.
local function queueReturnHome(player)
    if not AutoPilot_Home.isSet(player) then return false end
    local hx, hy, hz = AutoPilot_Home.getState()
    local homeZ = hz or player:getZ()
    local destSq = AutoPilot_Utils.findNearestSquare(hx, hy, homeZ, 5, function(sq)
        return sq:isFree(false) and AutoPilot_Home.isInside(sq)
    end)
    if destSq then
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, destSq))
        print("[Explore] Returning home.")
        return true
    end
    print("[Explore] queueReturnHome: no reachable square inside home bounds.")
    return false
end

-- Advance sector index; increment expand count after a full rotation.
local function advanceSector()
    AutoPilot_Explore._sectorIdx = AutoPilot_Explore._sectorIdx + 1
    if AutoPilot_Explore._sectorIdx > AutoPilot_Constants.EXPLORE_SECTORS then
        AutoPilot_Explore._sectorIdx   = 1
        AutoPilot_Explore._expandCount = AutoPilot_Explore._expandCount + 1
        print(string.format("[Explore] Full rotation — frontier radius now %d tiles.",
            exploreRadius()))
    end
end

-- Queue a supply loot pass at the current player position (no home-bound filter).
local function doFrontierLoot(player)
    if not (AutoPilot_Inventory and AutoPilot_Inventory.supplyRunLoot) then
        return
    end
    local anySupply = function(item)
        if item:isFood() and not item:isRotten() then
            local cal   = item:getCalories()
            local thst  = item:getThirstChange()
            return (cal and cal > 0) or (thst and thst < 0)
        end
        return false
    end
    pcall(function() AutoPilot_Inventory.supplyRunLoot(player, anySupply) end)
end

-- Returns true when the action queue is empty / all actions are done.
local function isQueueDone(player)
    local done = true
    pcall(function() done = ISTimedActionQueue.isAllDone(player) end)
    return done
end

-- ── Main check ──────────────────────────────────────────────────────────────

--- Called every eval cycle.  Returns true when an action was queued (blocks
--- lower-priority idle tasks).
function AutoPilot_Explore.check(player)
    if not AutoPilot_Home.isSet(player) then return false end

    -- ── Idle: wait for cooldown ────────────────────────────────────────────
    if AutoPilot_Explore._phase == "idle" then
        if AutoPilot_Explore._cooldown > 0 then
            AutoPilot_Explore._cooldown = AutoPilot_Explore._cooldown - 1
            return false
        end
        -- Cooldown expired — start outbound leg immediately.
        AutoPilot_Explore._phase  = "outbound"
        AutoPilot_Explore._looted = false
    end

    -- ── Outbound: walk to frontier ─────────────────────────────────────────
    if AutoPilot_Explore._phase == "outbound" then
        local sector = SECTORS[AutoPilot_Explore._sectorIdx]
        local radius = exploreRadius()
        local hx, hy, hz = AutoPilot_Home.getState()
        local homeZ  = hz or player:getZ()

        -- Waypoint: home centre projected along the sector vector.
        local dist = radius + AutoPilot_Constants.EXPLORE_STEP_TILES
        local tx   = math.floor(hx + sector[1] * dist)
        local ty   = math.floor(hy + sector[2] * dist)

        local cell = getCell()
        if cell then
            tx = math.max(0, math.min(tx, cell:getWidth()  - 1))
            ty = math.max(0, math.min(ty, cell:getHeight() - 1))
        end

        local destSq = cell and cell:getGridSquare(tx, ty, homeZ)
        if destSq then
            ISTimedActionQueue.add(ISWalkToTimedAction:new(player, destSq))
            print(string.format("[Explore] Outbound: sector %d/%d radius=%d target=(%d,%d).",
                AutoPilot_Explore._sectorIdx,
                AutoPilot_Constants.EXPLORE_SECTORS,
                radius, tx, ty))
        else
            print("[Explore] Frontier square not found — skipping sector.")
        end

        advanceSector()
        AutoPilot_Explore._phase  = "returning"
        AutoPilot_Explore._looted = false
        return true
    end

    -- ── Returning: loot at frontier, then walk home ────────────────────────
    if AutoPilot_Explore._phase == "returning" then
        if not isQueueDone(player) then return true end

        -- Check if already back inside home bounds.
        local currentSq = player:getCurrentSquare()
        if currentSq and AutoPilot_Home.isInside(currentSq) then
            AutoPilot_Explore._phase    = "idle"
            AutoPilot_Explore._cooldown = AutoPilot_Constants.EXPLORE_COOLDOWN_CYCLES
            print(string.format("[Explore] Trip complete — cooldown %d cycles.",
                AutoPilot_Constants.EXPLORE_COOLDOWN_CYCLES))
            return false
        end

        -- Not yet home. First do a frontier loot pass if not done this trip.
        if not AutoPilot_Explore._looted then
            AutoPilot_Explore._looted = true
            doFrontierLoot(player)
            print("[Explore] Frontier loot pass queued.")
            return true   -- wait for loot queue to drain next cycle
        end

        -- Loot done — queue walk home.
        local walked = queueReturnHome(player)
        if walked then return true end

        -- Pathfinding failed; reset gracefully.
        print("[Explore] Cannot pathfind home — resetting to idle.")
        AutoPilot_Explore._phase    = "idle"
        AutoPilot_Explore._cooldown = AutoPilot_Constants.EXPLORE_COOLDOWN_CYCLES
        return false
    end

    return false
end

-- ── Public utilities ────────────────────────────────────────────────────────

--- Reset all exploration state (call when home is cleared or AP is disabled).
function AutoPilot_Explore.reset()
    AutoPilot_Explore._phase       = "idle"
    AutoPilot_Explore._cooldown    = 0
    AutoPilot_Explore._sectorIdx   = 1
    AutoPilot_Explore._expandCount = 0
    AutoPilot_Explore._looted      = false
end

--- Current frontier radius in tiles (for telemetry / state snapshots).
function AutoPilot_Explore.currentRadius()
    return exploreRadius()
end

--- Current phase string ("idle", "outbound", "returning").
function AutoPilot_Explore.getPhase()
    return AutoPilot_Explore._phase
end
