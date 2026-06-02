-- AutoPilot_Threat.lua
-- Detects nearby zombies (same z-level only) and decides: fight, flee, or
-- encircled-fight.
--
-- Improvements vs. previous version:
--   * Detection radius 20 tiles (was 10) -- enough lead time for action queue to drain.
--   * Z-level filter -- zombies on a different floor are ignored.
--   * Horde threshold -- flee if >= FLEE_HORDE_SIZE zombies regardless of weapon/moodles.
--   * Directional spread analysis -- finds the largest angular gap in the zombie ring;
--     flee vector points through that gap instead of blindly away from centroid.
--   * Encirclement detection -- if no gap exceeds FLEE_ESCAPE_ARC_MIN degrees, the
--     player is surrounded; fight through the gap rather than attempting to flee.
--   * Flee stutter prevention -- ongoing flee walk is not interrupted; a short
--     post-arrival cooldown stops instant re-triggers after reaching the destination.
--   * Weapon condition gate -- weapon below WEAPON_FIGHT_CONDITION_MIN treated as absent.

AutoPilot_Threat = {}

local function _apNoop(...) end
local print = _apNoop

local DETECTION_RADIUS      = AutoPilot_Constants.DETECTION_RADIUS
local FLEE_MOODLE_LIMIT     = AutoPilot_Constants.FLEE_MOODLE_LIMIT
local FLEE_DISTANCE         = AutoPilot_Constants.FLEE_DISTANCE
local FLEE_HORDE_SIZE       = AutoPilot_Constants.FLEE_HORDE_SIZE
local FLEE_ESCAPE_ARC_MIN   = AutoPilot_Constants.FLEE_ESCAPE_ARC_MIN
local FLEE_COOLDOWN_CYCLES  = AutoPilot_Constants.FLEE_COOLDOWN_CYCLES
local WEAPON_FIGHT_COND_MIN = AutoPilot_Constants.WEAPON_FIGHT_CONDITION_MIN

-- Flee stutter-prevention state.
-- _fleeActive:   true while a flee walk is still in the action queue.
-- _fleeCooldown: counts down (in eval cycles) after the walk completes.
AutoPilot_Threat._fleeActive   = false
AutoPilot_Threat._fleeCooldown = 0

-- Stat thresholds that count as "negative" for the flee decision.
-- All thresholds are normalized to 0.0-1.0 scale for consistent comparison.
-- HUNGER/THIRST/FATIGUE: already 0.0-1.0 from B42
-- PANIC/PAIN/SICKNESS/STRESS/SANITY: 0-100 integer from B42; normalized by dividing by 100
local NEGATIVE_STAT_CHECKS = {
    { stat = CharacterStat.HUNGER,   threshold = 0.40, isNormalized = true  },
    { stat = CharacterStat.THIRST,   threshold = 0.40, isNormalized = true  },
    { stat = CharacterStat.FATIGUE,  threshold = 0.60, isNormalized = true  },
    { stat = CharacterStat.PANIC,    threshold = 0.40, isNormalized = false }, -- 40/100 = 0.40
    { stat = CharacterStat.PAIN,     threshold = 0.30, isNormalized = false }, -- 30/100 = 0.30
    { stat = CharacterStat.SICKNESS, threshold = 0.20, isNormalized = false }, -- 20/100 = 0.20
    { stat = CharacterStat.STRESS,   threshold = 0.40, isNormalized = false }, -- 40/100 = 0.40
    { stat = CharacterStat.SANITY,   threshold = 0.40, isNormalized = false }, -- 40/100 = 0.40
}

-- Returns condition ratio (0.0-1.0) for any weapon item.  Returns 0 on failure.
local function getWeaponCondition(weapon)
    if not weapon then return 0 end
    local ok, ratio = pcall(function()
        local max = weapon:getConditionMax()
        if not max or max == 0 then return 1.0 end
        return weapon:getCondition() / max
    end)
    return (ok and type(ratio) == "number") and ratio or 0
end

-- Analyzes the angular distribution of zombies around the player.
-- Returns:
--   escDx, escDy  -- unit vector through the largest angular gap
--                    (flee direction if clear; weakest-cluster direction if encircled)
--   encircled     -- true when no gap exceeds FLEE_ESCAPE_ARC_MIN degrees
local function analyzeSpread(player, zombies)
    if #zombies == 0 then return 1, 0, false end

    local px, py       = player:getX(), player:getY()
    local minEscapeRad = FLEE_ESCAPE_ARC_MIN * math.pi / 180

    local angles = {}
    for _, z in ipairs(zombies) do
        table.insert(angles, math.atan2(z:getY() - py, z:getX() - px))
    end
    table.sort(angles)

    if #angles == 1 then
        local away = angles[1] + math.pi
        return math.cos(away), math.sin(away), false
    end

    -- Find the largest angular gap (circular list).
    -- Wrap-around gap: last angle to first angle + 2*pi.
    local maxGap      = 0
    local gapMidAngle = angles[1] + math.pi
    local n = #angles

    for i = 1, n do
        local a1  = angles[i]
        local a2  = (i < n) and angles[i + 1] or (angles[1] + 2 * math.pi)
        local gap = a2 - a1
        if gap > maxGap then
            maxGap        = gap
            gapMidAngle   = a1 + gap / 2
        end
    end

    local encircled = maxGap < minEscapeRad
    return math.cos(gapMidAngle), math.sin(gapMidAngle), encircled
end

-- Returns living zombies within DETECTION_RADIUS tiles on the same z-level.
-- Z-level filter prevents zombies on different floors inflating threat counts.
function AutoPilot_Threat.getNearbyZombies(player)
    local zombies = {}
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local ok, zombieList = pcall(function() return getCell():getZombieList() end)
    if not ok or not zombieList then return zombies end

    local rSq = DETECTION_RADIUS * DETECTION_RADIUS
    for i = 0, zombieList:size() - 1 do
        local z = zombieList:get(i)
        if z and not z:isDead() and z:getZ() == pz then
            local dx = z:getX() - px
            local dy = z:getY() - py
            if (dx * dx + dy * dy) <= rSq then
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
        local val = AutoPilot_Utils.safeStat(player, check.stat)
        if not check.isNormalized then
            val = val / 100  -- normalize 0-100 integer scale to 0.0-1.0
        end
        if val >= check.threshold then
            count = count + 1
        end
    end
    return count
end

-- Flee toward the escape arc (or home center if safehouse mode is active).
-- escDx/escDy: optional pre-computed unit escape vector; computed internally if nil.
local function doFlee(player, zombies, escDx, escDy)
    local destSq

    if AutoPilot_Home.isSet(player) then
        local hx, hy, hz = AutoPilot_Home.getState()
        local homeZ = hz or player:getZ()
        destSq = AutoPilot_Utils.findNearestSquare(hx, hy, homeZ, 5, function(sq)
            return sq:isFree(false) and AutoPilot_Home.isInside(sq)
        end)
    else
        if not escDx then
            escDx, escDy = analyzeSpread(player, zombies)
        end

        local targetX = math.floor(player:getX() + escDx * FLEE_DISTANCE)
        local targetY = math.floor(player:getY() + escDy * FLEE_DISTANCE)
        local targetZ = player:getZ()

        local cell = getCell()
        if not cell then return false end
        targetX = math.max(0, math.min(targetX, cell:getWidth()  - 1))
        targetY = math.max(0, math.min(targetY, cell:getHeight() - 1))

        destSq = cell:getGridSquare(targetX, targetY, targetZ)
    end

    if destSq then
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, destSq))
        AutoPilot_Threat._fleeActive   = true
        AutoPilot_Threat._fleeCooldown = FLEE_COOLDOWN_CYCLES
        print("[Threat] FLEE -> " .. #zombies .. " zombie(s), " ..
            AutoPilot_Threat.countNegativeMoodles(player) .. " negative stats elevated.")
        return true
    end

    print("[Threat] FLEE failed -- no reachable square; falling back to fight.")
    return false
end

-- Fight the nearest zombie: swap to best usable weapon, then walk toward it.
-- In safehouse mode (home set), redirects to flee.
-- escDx/escDy: passed through to doFlee on safehouse redirect.
local function doFight(player, zombies, escDx, escDy)
    if AutoPilot_Home.isSet(player) then
        print("[Threat] Safehouse mode -- redirecting FIGHT to FLEE.")
        doFlee(player, zombies, escDx, escDy)
        return
    end

    AutoPilot_Inventory.checkAndSwapWeapon(player)

    local px, py = player:getX(), player:getY()
    table.sort(zombies, function(a, b)
        return (a:getX()-px)^2 + (a:getY()-py)^2 < (b:getX()-px)^2 + (b:getY()-py)^2
    end)
    local target = zombies[1]

    local weapon       = AutoPilot_Inventory.getBestWeapon(player)
    local weaponUsable = weapon and getWeaponCondition(weapon) >= WEAPON_FIGHT_COND_MIN

    local okPrimary, primary = pcall(function() return player:getPrimaryHandItem() end)
    if not okPrimary then primary = nil end

    local function safeMaxDamage(item)
        if not item then return nil end
        local ok, dmg = pcall(function() return item:getMaxDamage() end)
        return (ok and type(dmg) == "number") and dmg or nil
    end

    local primaryDamage = safeMaxDamage(primary)
    local weaponDamage  = safeMaxDamage(weapon)

    local shouldEquip = weaponUsable and not primary
    if not shouldEquip and weaponUsable and weaponDamage then
        shouldEquip = not primaryDamage or primaryDamage < weaponDamage
    end

    if shouldEquip then
        ISTimedActionQueue.add(ISEquipWeaponAction:new(player, weapon, 50, true))
    end

    local targetSq = target:getSquare()
    if targetSq then
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, targetSq))
    end

    print("[Threat] FIGHT -- " .. #zombies .. " zombie(s) nearby.")
end

-- Force fight regardless of moodle state (used by LLM commands).
function AutoPilot_Threat.forceFight(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)
    if #zombies == 0 then return end
    AutoPilot_Threat._fleeActive   = false
    AutoPilot_Threat._fleeCooldown = 0
    ISTimedActionQueue.clear(player)
    doFight(player, zombies)
end

-- Force flee regardless of moodle state (used by LLM commands).
function AutoPilot_Threat.forceFlee(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)
    if #zombies == 0 then return end
    AutoPilot_Threat._fleeActive   = false
    AutoPilot_Threat._fleeCooldown = 0
    ISTimedActionQueue.clear(player)
    doFlee(player, zombies)
end

-- Called every evaluation cycle.  Returns true if a threat was detected and an
-- action was queued (or an existing flee walk is still in progress).
function AutoPilot_Threat.check(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)

    if #zombies == 0 then
        AutoPilot_Threat._fleeActive   = false
        AutoPilot_Threat._fleeCooldown = 0
        return false
    end

    -- Flee stutter prevention: if a flee walk is still executing, leave the queue alone.
    if AutoPilot_Threat._fleeActive then
        local queueDone = true
        pcall(function() queueDone = ISTimedActionQueue.isAllDone(player) end)
        if not queueDone then
            return true
        end
        AutoPilot_Threat._fleeActive = false
    end

    if AutoPilot_Threat._fleeCooldown > 0 then
        AutoPilot_Threat._fleeCooldown = AutoPilot_Threat._fleeCooldown - 1
        return true
    end

    ISTimedActionQueue.clear(player)

    -- Priority 1: Critical wound (active bleeding) -- always flee.
    if AutoPilot_Medical.hasCriticalWound(player) then
        local dx, dy = analyzeSpread(player, zombies)
        print("[Threat] FLEE -- critical wound (bleeding).")
        if not doFlee(player, zombies, dx, dy) then doFight(player, zombies, dx, dy) end
        return true
    end

    -- Phase 1 Enhancement: Use tactical combat analysis if available
    if AutoPilot_Combat and AutoPilot_Combat.analyzeThreat then
        local tacticAnalysis = AutoPilot_Combat.analyzeThreat(player, zombies)
        if tacticAnalysis and tacticAnalysis.tactic then
            print(("[Threat] Combat analysis: %s (reason: %s)"):format(
                tacticAnalysis.tactic, tacticAnalysis.reason or "unknown"))
            -- Tactic analysis is advisory; continue with existing threat logic
        end
    end

    -- Pre-compute spread once; reused across all remaining priority checks.
    local escDx, escDy, encircled = analyzeSpread(player, zombies)

    -- Priority 2: Horde threshold -- flee regardless of weapon or moodles.
    if #zombies >= FLEE_HORDE_SIZE then
        print("[Threat] FLEE -- horde (" .. #zombies .. " zombies).")
        if not doFlee(player, zombies, escDx, escDy) then doFight(player, zombies, escDx, escDy) end
        return true
    end

    -- Priority 3: No usable weapon and outnumbered -- flee.
    local weapon       = AutoPilot_Inventory.getBestWeapon(player)
    local weaponUsable = weapon and getWeaponCondition(weapon) >= WEAPON_FIGHT_COND_MIN
    if not weaponUsable and #zombies > 1 then
        print("[Threat] FLEE -- no usable weapon, " .. #zombies .. " zombies.")
        if not doFlee(player, zombies, escDx, escDy) then doFight(player, zombies, escDx, escDy) end
        return true
    end

    -- Priority 4: Encircled -- fight through the widest gap (fleeing is unsafe).
    if encircled then
        print("[Threat] ENCIRCLED -- " .. #zombies .. " zombies; fighting through gap.")
        doFight(player, zombies, escDx, escDy)
        return true
    end

    -- Priority 5: Too many negative moodles -- flee.
    if AutoPilot_Threat.countNegativeMoodles(player) > FLEE_MOODLE_LIMIT then
        if not doFlee(player, zombies, escDx, escDy) then doFight(player, zombies, escDx, escDy) end
    else
        doFight(player, zombies, escDx, escDy)
    end

    return true
end
