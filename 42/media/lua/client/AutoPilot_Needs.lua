-- AutoPilot_Needs.lua
-- Handles survival needs and idle behaviour.
--
-- SPLITSCREEN NOTE: Module-level variables (restCooldownMs, sleepCooldownMs,
-- exerciseCycle, exerciseWaitLogMs) are shared across all local players.
-- Splitscreen is NOT supported.
--
-- Priority order (highest -> lowest):
--   1. Bleeding      -> bandage immediately (fatal if untreated)
--   2. Thirst        -> drink from tap/sink, then inventory, then loot
--   3. Hunger        -> eat
--   4. Wounds        -> treat non-bleeding wounds (scratches, bites, etc.)
--   5. Tired         -> sleep (recovers both fatigue AND endurance)
--   6. Exhausted     -> rest in place (endurance critically low, but not sleepy)
--   7. Bored/Sad     -> read literature, then go outside
--   8. Idle          -> exercise (strength/fitness alternating by level)

AutoPilot_Needs = {}

-- Phase 2: Daily exercise tracking
local _exerciseSetsToday = 0
local _lastTrackedDay     = -1

-- ── Thresholds ────────────────────────────────────────────────────────────────

-- B42 Stats: player:getStats():get(CharacterStat.HUNGER), etc.
-- Hunger/Thirst/Fatigue: 0.0 = fine, ~1.0 = critical
-- Boredom: 0-100 scale
-- Endurance: 1.0 = full, 0.0 = empty
local HUNGER_STAT_THRESHOLD  = 0.20
local THIRST_STAT_THRESHOLD  = 0.20   -- moderate thirst, matches hunger sensitivity
local FATIGUE_STAT_THRESHOLD = 0.70
local BOREDOM_STAT_THRESHOLD = 30
local SADNESS_STAT_THRESHOLD = 20
local ENDURANCE_REST_MIN     = 0.30   -- rest before fully wiped
local ENDURANCE_EXERCISE_MIN = 0.50   -- don't start exercise below this
local EXERCISE_MINUTES       = 20
local OUTDOOR_SEARCH_DIST    = 120

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- Safe moodle level getter — returns 0 if the moodle type doesn't exist or isn't active.
-- B42 stores moodles in a Map; missing entries cause a Java NPE, so we pcall.
local function safeMoodleLevel(player, moodleType)
    if not moodleType then return 0 end
    local ok, level = pcall(function()
        return player:getMoodles():getMoodleLevel(moodleType)
    end)
    if ok and type(level) == "number" then
        return level
    end
    return 0
end

-- Returns current perk level (0-10) for the given PerkList entry.
local function getPerkLevel(player, perk)
    return player:getPerkLevel(perk)
end

-- ── Actions ─────────────────────────────────────────────────────────────────

local function doEat(player)
    local food = AutoPilot_Inventory.getBestFood(player)
    if not food then
        AutoPilot_LLM.log("[Needs] Hungry but no food in inventory — looting nearby.")
        AutoPilot_Inventory.lootNearbyFood(player)
        return false
    end
    AutoPilot_LLM.log("[Needs] Best food: " .. tostring(food:getName())
        .. " (cal=" .. tostring(food:getCalories()) .. ")")
    AutoPilot_LLM.log("[Needs] Eating: " .. tostring(food:getName()))
    ISTimedActionQueue.add(ISEatFoodAction:new(player, food, 1))
    return true
end

local function doDrink(player)
    -- Priority 1: nearby water source — fill container first, then drink
    local waterObj = AutoPilot_Inventory.findWaterSource(player)
    if waterObj then
        AutoPilot_Inventory.refillWaterContainer(player, waterObj)
        return AutoPilot_Inventory.drinkFromSource(player, waterObj)
    end

    -- Priority 2: Drink from inventory (filled glass/bottle)
    local drink = AutoPilot_Inventory.getBestDrink(player)
    if drink then
        AutoPilot_LLM.log("[Needs] Drinking: " .. tostring(drink:getName()))
        ISTimedActionQueue.add(ISEatFoodAction:new(player, drink, 1))
        return true
    end

    -- Priority 3: Loot a drink from nearby containers
    AutoPilot_LLM.log("[Needs] Thirsty but no drink — attempting to loot nearby.")
    AutoPilot_Inventory.lootNearbyDrink(player)
    return false
end

-- Rest on nearby furniture to recover endurance.
-- Searches for bed > couch/sofa > chair within REST_SEARCH_DIST tiles.
-- Falls back to resting in place if nothing found.
local restCooldownMs = 0
local REST_SEARCH_DIST = 30

local function findRestFurniture(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local bestObj  = nil
    local bestDist = math.huge
    local bestPriority = 99  -- lower = better (bed=1, sofa=2, chair=3)

    AutoPilot_Utils.iterateNearbySquares(px, py, pz, REST_SEARCH_DIST, function(sq, dx, dy)
        if not AutoPilot_Home.isInside(sq) then return false end
        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            local priority = nil

            -- Check for bed
            local okB, isBed = pcall(function()
                return obj:getSprite()
                    and obj:getSprite():getProperties()
                        :has(IsoFlagType.bed)
            end)
            if okB and isBed then
                priority = 1
            end

            -- Check for chair/sofa by sprite name
            if not priority then
                local okN, spName = pcall(function()
                    return obj:getSprite()
                        and obj:getSprite():getName() or ""
                end)
                if okN and spName then
                    local lower = spName:lower()
                    if lower:find("sofa") or lower:find("couch") then
                        priority = 2
                    elseif lower:find("chair") then
                        priority = 3
                    end
                end
            end

            if priority then
                local dist = dx * dx + dy * dy
                -- Prefer better furniture, then closer distance
                if priority < bestPriority
                    or (priority == bestPriority and dist < bestDist)
                then
                    bestPriority = priority
                    bestDist = dist
                    bestObj = obj
                end
            end
        end
        return false  -- always continue: want best furniture, not first
    end)

    return bestObj
end

local function doRest(player)
    local ok, now = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms = ok and now or 0

    if ms < restCooldownMs then return true end  -- still resting, skip silently

    ISTimedActionQueue.clear(player)

    local furniture = findRestFurniture(player)
    if furniture then
        AutoPilot_LLM.log("[Needs] Exhausted — resting on furniture.")
        -- Pathfind to the furniture seat, then sit via ISRestAction (mirrors ISWorldObjectContextMenu.onRest)
        local pathAction = ISPathFindAction:pathToSitOnFurniture(player, furniture, true)
        pathAction:setOnComplete(function(pl, act)
            local target = act.goalFurnitureObject or furniture
            local restAction = ISRestAction:new(pl, target, true)
            if act:addAfter(restAction) == nil then
                ISTimedActionQueue.add(restAction)
            end
        end, player, pathAction)
        pathAction:setOnFail(function(pl, obj, act)
            -- Furniture unreachable; walk adjacent then sit on ground near it
            local adjacent = AdjacentFreeTileFinder.Find(obj:getSquare(), pl, nil)
            act:setRunActionsAfterFailing(true)
            if adjacent and adjacent ~= pl:getCurrentSquare() then
                act:addAfter(ISWalkToTimedAction:new(pl, adjacent))
            end
            act:addAfter(ISSitOnGround:new(pl, obj))
        end, player, furniture, pathAction)
        ISTimedActionQueue.add(pathAction)
    else
        AutoPilot_LLM.log("[Needs] Exhausted — resting in place.")
        ISTimedActionQueue.add(ISSitOnGround:new(player, nil))
    end

    restCooldownMs = ms + 60000   -- 60s: give endurance time to recover
    return true
end

local sleepCooldownMs = 0

local BED_SEARCH_DIST = 100
local BED_SEARCH_FLOORS = 3  -- check z, z+1, z-1 (ground floor + upstairs + basement)

local function getBedObjectOnSquare(sq)
    for i = 0, sq:getObjects():size() - 1 do
        local obj = sq:getObjects():get(i)
        local ok, isBed = pcall(function()
            return obj:getSprite()
                and obj:getSprite():getProperties()
                    :has(IsoFlagType.bed)
        end)
        if ok and isBed then return obj end
    end
    return nil
end

-- Search for the nearest bed object around `player`.
-- Prefers home bounds when home is set; falls back to a wide multi-floor scan.
-- Returns the IsoObject with the bed flag, or nil if none is found.
local function _findBedNearby(player)
    if AutoPilot_Home.isSet(player) then
        local bedSq = AutoPilot_Home.getNearestInside(player, function(sq)
            return getBedObjectOnSquare(sq) ~= nil
        end)
        if bedSq then
            return getBedObjectOnSquare(bedSq)
        end
        return nil  -- no bed inside home bounds; caller logs the failure
    end

    -- No home set: wide multi-floor scan
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local bestObj  = nil
    local bestDist = math.huge

    for dz = 0, BED_SEARCH_FLOORS - 1 do
        for _, z in ipairs(dz == 0 and {pz} or {pz + dz, pz - dz}) do
            if z >= 0 then
                for dx = -BED_SEARCH_DIST, BED_SEARCH_DIST do
                    for dy = -BED_SEARCH_DIST, BED_SEARCH_DIST do
                        local sq = getCell():getGridSquare(px + dx, py + dy, z)
                        if sq then
                            local obj = getBedObjectOnSquare(sq)
                            if obj then
                                local floorPenalty = math.abs(z - pz) * 200
                                local dist = dx * dx + dy * dy + floorPenalty
                                if dist < bestDist then
                                    bestDist = dist
                                    bestObj  = obj
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return bestObj
end

local function doSleep(player)
    -- Cooldown guard: prevent re-queuing bed action every tick
    local ok, now = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms = ok and now or 0
    if ms < sleepCooldownMs then return true end

    AutoPilot_LLM.log("[Needs] Sleeping...")
    ISTimedActionQueue.clear(player)

    local bedObj = _findBedNearby(player)
    if not bedObj then
        -- Forcing sleep via setAsleep is client-only; the server never learns of
        -- the state change, causing fatigue desync in MP.  Retry next cycle.
        if AutoPilot_Home.isSet(player) then
            AutoPilot_LLM.log(
                "[Needs] No bed found inside home bounds — cannot force sleep (MP-unsafe); will retry.")
        else
            AutoPilot_LLM.log("[Needs] No bed found — cannot force sleep (MP-unsafe); will retry.")
        end
        return false
    end

    local bedSq = bedObj:getSquare()
    local bedZ  = bedSq and bedSq:getZ() or player:getZ()
    if bedZ ~= player:getZ() then
        AutoPilot_LLM.log(string.format("[Needs] Found bed on floor %d — walking there.", bedZ))
    else
        AutoPilot_LLM.log("[Needs] Found bed — getting on it.")
    end
    ISTimedActionQueue.add(ISGetOnBedAction:new(player, bedObj))
    sleepCooldownMs = ms + 15000
    return true
end

-- Walk to the nearest outdoor square to relieve boredom.
local function doGoOutside(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local cell = getCell()
    if not cell then return false end
    local curSq = cell:getGridSquare(px, py, pz)
    if curSq and curSq:isOutside() then
        AutoPilot_LLM.log("[Needs] Already outside — boredom will decrease naturally.")
        return false
    end

    AutoPilot_LLM.log("[Needs] Bored — finding outdoor square.")

    -- Home set: only search within home bounds
    if AutoPilot_Home.isSet(player) then
        local outsideSq = AutoPilot_Home.getNearestInside(player, function(sq)
            return sq:isOutside() and sq:isFree(false)
        end)
        if outsideSq then
            ISTimedActionQueue.add(ISWalkToTimedAction:new(player, outsideSq))
            return true
        end
        AutoPilot_LLM.log("[Needs] No outdoor square found inside home bounds — skipping.")
        return false
    end

    -- No home set: skip outdoor walk for safety (containment guard)
    AutoPilot_LLM.log("[Needs] No home set — skipping outdoor walk.")
    return false
end

-- ── Reading (boredom/unhappiness relief) ────────────────────────────────────

local function doRead(player)
    local book = AutoPilot_Inventory.getReadable(player)
    if not book then
        -- No readable in inventory — try looting one from nearby containers
        return AutoPilot_Inventory.lootNearbyReadable(player)
    end

    -- Check if too dark to read
    local ok, tooDark = pcall(function() return player:tooDarkToRead() end)
    if ok and tooDark then
        AutoPilot_LLM.log("[Needs] Too dark to read.")
        return false
    end

    AutoPilot_LLM.log("[Needs] Reading: " .. tostring(book:getName()))
    local readOk, _ = pcall(function()
        ISTimedActionQueue.add(ISReadABook:new(player, book))
    end)
    return readOk
end

-- ── Exercise ────────────────────────────────────────────────────────────────
-- B42: ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)
-- Exercise data comes from FitnessExercises.exercisesType table.
-- Strength: pushups, squats   |   Fitness: situp, burpees

local STRENGTH_EXERCISES = {"pushups", "squats"}
local FITNESS_EXERCISES  = {"situp",   "burpees"}

local exerciseCycle = 1

-- Log cooldown for "waiting for endurance" to prevent spam
local exerciseWaitLogMs = 0

local function doExercise(player)
    -- Phase 2: day-rollover reset for exercise counter
    local currentDay = GameTime.getInstance() and GameTime.getInstance():getDay() or 0
    if currentDay ~= _lastTrackedDay then
        _exerciseSetsToday = 0
        _lastTrackedDay    = currentDay
    end
    -- Phase 2: gate on daily cap
    if _exerciseSetsToday >= AutoPilot_Constants.EXERCISE_DAILY_CAP then
        AutoPilot_LLM.log(("[Needs] Daily exercise cap %d reached — skipping."):format(
            AutoPilot_Constants.EXERCISE_DAILY_CAP))
        return false
    end
    -- Phase 2: gate on endurance (hysteresis: skip <30%, resume >70%)
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance < AutoPilot_Constants.EXERCISE_ENDURANCE_MIN or enduranceMoodle > 2 then
        -- Log once every 30s of game time, not every tick
        local ok, now = pcall(function()
            return getGameTime():getCalender():getTimeInMillis()
        end)
        local ms = ok and now or 0
        if ms >= exerciseWaitLogMs then
            AutoPilot_LLM.log(("[Needs] Endurance %.2f < %.2f — skipping exercise, resting."):format(
                endurance, AutoPilot_Constants.EXERCISE_ENDURANCE_MIN))
            exerciseWaitLogMs = ms + 30000
        end
        return false  -- no action queued; endurance recovers passively while idle
    end
    if endurance < AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME then
        -- Endurance is between MIN and RESUME — wait for full recovery before next set
        local ok, now = pcall(function()
            return getGameTime():getCalender():getTimeInMillis()
        end)
        local ms = ok and now or 0
        if ms >= exerciseWaitLogMs then
            AutoPilot_LLM.log(("[Needs] Endurance %.2f < %.2f resume threshold — waiting."):format(
                endurance, AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME))
            exerciseWaitLogMs = ms + 30000
        end
        return false
    end

    local strLevel = getPerkLevel(player, Perks.Strength)
    local fitLevel = getPerkLevel(player, Perks.Fitness)

    local exercises
    if strLevel <= fitLevel then
        exercises = STRENGTH_EXERCISES
        AutoPilot_LLM.log(string.format("[Needs] Exercise — training Strength (STR %d / FIT %d)",
            strLevel, fitLevel))
    else
        exercises = FITNESS_EXERCISES
        AutoPilot_LLM.log(string.format("[Needs] Exercise — training Fitness (STR %d / FIT %d)",
            strLevel, fitLevel))
    end

    -- Guard: exercises table must be non-empty before indexing.
    if #exercises == 0 then
        AutoPilot_LLM.log("[Needs] No exercises defined for current focus — skipping.")
        return false
    end
    local exType = exercises[((exerciseCycle - 1) % #exercises) + 1]
    exerciseCycle = exerciseCycle + 1

    local exeData = nil
    if FitnessExercises and FitnessExercises.exercisesType then
        exeData = FitnessExercises.exercisesType[exType]
    end

    if not exeData then
        AutoPilot_LLM.log("[Needs] FitnessExercises data not found for: " .. exType)
        return false
    end

    -- Pre-initialize the Java Fitness object so currentExe is set before
    -- the action lifecycle starts (prevents exerciseRepeat NPE).
    pcall(function()
        local fitness = player:getFitness()
        fitness:init()
        fitness:setCurrentExercise(exeData.type)
    end)

    local ok, action = pcall(function()
        return ISFitnessAction:new(player, exType, EXERCISE_MINUTES, exeData, exeData.type)
    end)

    if ok and action then
        ISTimedActionQueue.addGetUpAndThen(player, action)
        _exerciseSetsToday = _exerciseSetsToday + 1
        return true
    else
        AutoPilot_LLM.log("[Needs] ISFitnessAction failed for: " .. exType .. " — " .. tostring(action))
        return false
    end
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Returns true if an urgent need should interrupt the current action (e.g. exercise).
--- Called by Main before the isPlayerDoingAction guard.
function AutoPilot_Needs.shouldInterrupt(player)
    -- Bleeding always interrupts
    if AutoPilot_Medical.hasCriticalWound(player) then return true end

    -- Thirst interrupts at threshold
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    if thirst >= THIRST_STAT_THRESHOLD then return true end

    -- Hunger interrupts
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    if hunger >= HUNGER_STAT_THRESHOLD then return true end

    -- Exhaustion interrupts (stat threshold OR severe moodle — mirrors check())
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN then return true end
    if safeMoodleLevel(player, MoodleType.ENDURANCE) >= 3 then return true end

    return false
end

--- Main survival needs check. Both modes call this.
--- @param skipExercise boolean  If true, skip the idle→exercise step (pilot mode).
function AutoPilot_Needs.check(player, skipExercise)
    -- 1. Bleeding — treat immediately (fatal if untreated)
    if AutoPilot_Medical.hasCriticalWound(player) then
        if AutoPilot_Medical.check(player, true) then return true end
    end

    -- If the PC recently sat down to rest, suppress routine needs (thirst,
    -- hunger, etc.) so they don't immediately stand back up.  We reuse the
    -- restCooldownMs timer that doRest already sets.  Only bleeding (above)
    -- may interrupt passive rest.
    local okNow, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if okNow and nowMs < restCooldownMs then
        return true  -- still resting, skip routine needs
    end

    -- 2. Thirst (0.0=hydrated, ~1.0=dying)
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    if thirst >= THIRST_STAT_THRESHOLD then
        return doDrink(player)
    end

    -- 3. Hunger (0.0=full, ~1.0=starving)
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    if hunger >= HUNGER_STAT_THRESHOLD then
        AutoPilot_LLM.log(string.format(
            "[Needs] Hunger triggered (%.0f%%). Attempting to eat.", hunger * 100))
        local ate = doEat(player)
        if not ate then
            AutoPilot_LLM.log("[Needs] doEat returned false — no food available?")
        end
        return ate
    end

    -- 4. Wounds — treat non-bleeding wounds (scratches, bites, deep wounds)
    if AutoPilot_Medical.check(player, false) then return true end

    -- 5. Tired (fatigue: 0.0=rested, ~1.0=exhausted) — checked BEFORE endurance
    -- because sleep recovers both fatigue AND endurance.
    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    if fatigue >= FATIGUE_STAT_THRESHOLD then
        return doSleep(player)
    end

    -- 6. Exhausted — rest only when endurance is critically low (stat ≤ 30%)
    -- or the exertion moodle is severe (level 3+).  Moodle level 1-2 is mild
    -- exertion that recovers on its own; reacting to it causes a sit-stand loop.
    -- (Rest cooldown is already enforced at the top of check().)
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN or enduranceMoodle >= 3 then
        return doRest(player)
    end

    -- 7. Bored or Sad -> read literature first, then go outside
    local boredom = AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM)
    local sadness = AutoPilot_Utils.safeStat(player, CharacterStat.SANITY)
    if boredom >= BOREDOM_STAT_THRESHOLD or sadness >= SADNESS_STAT_THRESHOLD then
        if doRead(player) then return true end
        if boredom >= BOREDOM_STAT_THRESHOLD then
            local went = doGoOutside(player)
            if went then return true end
        end
    end

    -- 8. Idle -> exercise (exercise mode only)
    if skipExercise then return false end
    return doExercise(player)
end

-- ── Public aliases for chain-action use ──────────────────────────────────────
-- AutoPilot_Actions.lua references these so it can delegate without duplicating
-- the full bed-search and outdoor-square-search logic.
AutoPilot_Needs.trySleep    = doSleep
AutoPilot_Needs.tryGoOutside = doGoOutside

-- Returns a snapshot of current stat levels for LLM state reporting.
-- B42: Uses player:getStats():get(CharacterStat.XXX) pattern.
function AutoPilot_Needs.getMoodleSnapshot(player)
    return {
        hungry   = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER) * 100),
        thirsty  = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.THIRST) * 100),
        tired    = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE) * 100),
        panicked = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.PANIC)),
        injured  = safeMoodleLevel(player, MoodleType.PAIN),
        sick     = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.SICKNESS)),
        stressed = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.STRESS)),
        bored    = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM)),
        sad      = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.SANITY)),
    }
end
