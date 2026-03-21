-- AutoPilot_Threat.lua
-- Detects nearby zombies and decides: fight (default) or flee (>2 negative moodles).

AutoPilot_Threat = {}

local DETECTION_RADIUS   = 10   -- tiles to scan for zombies
local FLEE_MOODLE_LIMIT  = 2    -- flee if *more than* this many negative stats are elevated
local FLEE_DISTANCE      = 20   -- tiles to run when fleeing

-- Stat thresholds that count as "negative" for flee decision.
-- B42: Uses player:getStats():get(CharacterStat.XXX) pattern.
local NEGATIVE_STAT_CHECKS = {
    { stat = CharacterStat.HUNGER,   threshold = 0.40 },
    { stat = CharacterStat.THIRST,   threshold = 0.40 },
    { stat = CharacterStat.FATIGUE,  threshold = 0.60 },
    { stat = CharacterStat.PANIC,    threshold = 40   },
    { stat = CharacterStat.PAIN,     threshold = 30   },
    { stat = CharacterStat.SICKNESS, threshold = 20   },
    { stat = CharacterStat.STRESS,   threshold = 40   },
    { stat = CharacterStat.SANITY,   threshold = 40   },
}

-- Safe stat getter — B42 uses player:getStats():get(CharacterStat.XXX).
local function safeStat(player, charStat)
    local ok, val = pcall(function()
        return player:getStats():get(charStat)
    end)
    if ok and type(val) == "number" then return val end
    return 0
end

-- Returns a list of living zombies within DETECTION_RADIUS tiles.
function AutoPilot_Threat.getNearbyZombies(player)
    local zombies = {}
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local ok, zombieList = pcall(function() return getCell():getZombieList() end)
    if not ok or not zombieList then return zombies end

    for i = 0, zombieList:size() - 1 do
        local z = zombieList:get(i)
        if z and not z:isDead() then
            local dx = z:getX() - px
            local dy = z:getY() - py
            if (dx * dx + dy * dy) <= (DETECTION_RADIUS * DETECTION_RADIUS) then
                table.insert(zombies, z)
            end
        end
    end
    return zombies
end

-- Counts how many negative stats are above their thresholds.
function AutoPilot_Threat.countNegativeMoodles(player)
    local count = 0
    for _, check in ipairs(NEGATIVE_STAT_CHECKS) do
        local val = safeStat(player, check.stat)
        if val >= check.threshold then
            count = count + 1
        end
    end
    return count
end

-- Fight the nearest zombie: equip best weapon, then walk toward it.
local function doFight(player, zombies)
    local px, py = player:getX(), player:getY()
    table.sort(zombies, function(a, b)
        local da = (a:getX()-px)^2 + (a:getY()-py)^2
        local db = (b:getX()-px)^2 + (b:getY()-py)^2
        return da < db
    end)
    local target = zombies[1]

    -- Equip best weapon if it outclasses what's currently held
    local weapon = AutoPilot_Inventory.getBestWeapon(player)
    local primary = player:getPrimaryHandItem()
    if weapon and (not primary or primary:getMaxDamage() < weapon:getMaxDamage()) then
        ISTimedActionQueue.add(ISEquipWeaponAction:new(player, weapon, 50, true))
    end

    -- Walk into the zombie's square — engine triggers melee automatically
    local targetSq = target:getSquare()
    if targetSq then
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, targetSq))
    end

    AutoPilot_LLM.log("[Threat] FIGHT — " .. #zombies .. " zombie(s) nearby.")
end

-- Flee away from the zombie centroid.
local function doFlee(player, zombies)
    local cx, cy = 0, 0
    for _, z in ipairs(zombies) do
        cx = cx + z:getX()
        cy = cy + z:getY()
    end
    cx = cx / #zombies
    cy = cy / #zombies

    local dx = player:getX() - cx
    local dy = player:getY() - cy
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then dx, dy = 1, 0 else dx, dy = dx / len, dy / len end

    local targetX = math.floor(player:getX() + dx * FLEE_DISTANCE)
    local targetY = math.floor(player:getY() + dy * FLEE_DISTANCE)
    local targetZ = player:getZ()

    local cell = getCell()
    targetX = math.max(0, math.min(targetX, cell:getWidth()  - 1))
    targetY = math.max(0, math.min(targetY, cell:getHeight() - 1))

    local destSq = cell:getGridSquare(targetX, targetY, targetZ)
    if destSq then
        player:setRunning(true)
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, destSq))
    end

    AutoPilot_LLM.log("[Threat] FLEE — " .. #zombies .. " zombie(s), " ..
        AutoPilot_Threat.countNegativeMoodles(player) .. " negative stats elevated.")
end

-- Force fight regardless of moodle state (used by LLM overrides).
function AutoPilot_Threat.forceFight(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)
    if #zombies == 0 then return end
    ISTimedActionQueue.clear(player)
    doFight(player, zombies)
end

-- Force flee regardless of moodle state (used by LLM overrides).
function AutoPilot_Threat.forceFlee(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)
    if #zombies == 0 then return end
    ISTimedActionQueue.clear(player)
    doFlee(player, zombies)
end

-- Main threat check. Returns true if a threat was detected and action queued.
function AutoPilot_Threat.check(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)
    if #zombies == 0 then return false end

    ISTimedActionQueue.clear(player)

    -- Always flee if critically wounded (actively bleeding)
    if AutoPilot_Medical.hasCriticalWound(player) then
        AutoPilot_LLM.log("[Threat] FLEE — critical wound (bleeding).")
        doFlee(player, zombies)
        return true
    end

    -- Flee if unarmed and outnumbered
    local weapon = AutoPilot_Inventory.getBestWeapon(player)
    if not weapon and #zombies > 1 then
        AutoPilot_LLM.log("[Threat] FLEE — unarmed and " .. #zombies .. " zombies.")
        doFlee(player, zombies)
        return true
    end

    if AutoPilot_Threat.countNegativeMoodles(player) > FLEE_MOODLE_LIMIT then
        doFlee(player, zombies)
    else
        doFight(player, zombies)
    end

    return true
end
