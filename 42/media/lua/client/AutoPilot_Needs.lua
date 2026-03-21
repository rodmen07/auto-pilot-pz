-- AutoPilot_Needs.lua
-- Handles survival needs and idle behaviour.
--
-- Priority order (highest -> lowest):
--   1. Bleeding      -> bandage immediately (fatal if untreated)
--   2. Thirst        -> drink from tap/sink, then inventory, then loot
--   3. Hunger        -> eat
--   4. Wounds        -> treat non-bleeding wounds (scratches, bites, etc.)
--   5. Exhausted     -> rest in place (endurance critically low)
--   6. Tired         -> sleep
--   7. Bored         -> read literature, then go outside
--   8. Idle          -> exercise (strength/fitness alternating by level)

AutoPilot_Needs = {}

-- ── Thresholds ────────────────────────────────────────────────────────────────

-- B42 Stats use direct getters: player:getStats():getHunger(), etc.
-- Hunger/Thirst/Fatigue: 0.0 = fine, ~1.0 = critical
-- Boredom: 0-100 scale
-- Endurance: 1.0 = full, 0.0 = empty
local HUNGER_STAT_THRESHOLD  = 0.30
local THIRST_STAT_THRESHOLD  = 0.25
local FATIGUE_STAT_THRESHOLD = 0.70
local BOREDOM_STAT_THRESHOLD = 30
local ENDURANCE_REST_MIN     = 0.15
local EXERCISE_MINUTES       = 20
local OUTDOOR_SEARCH_DIST    = 20

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

-- Safe stat getter — wraps individual Stats getter in pcall.
-- getter is a function: function(stats) return stats:getHunger() end
local function safeStat(player, getter)
    local ok, val = pcall(function()
        return getter(player:getStats())
    end)
    if ok and type(val) == "number" then
        return val
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
        AutoPilot_LLM.log("[Needs] Hungry but no food — attempting to loot nearby.")
        AutoPilot_Inventory.lootNearbyFood(player)
        return false
    end
    AutoPilot_LLM.log("[Needs] Eating: " .. tostring(food:getName()))
    ISTimedActionQueue.add(ISEatFoodAction:new(player, food, 1))
    return true
end

local function doDrink(player)
    -- Priority 1: Drink from a nearby water source (sink, rain barrel)
    local waterObj = AutoPilot_Inventory.findWaterSource(player)
    if waterObj then
        return AutoPilot_Inventory.drinkFromSource(player, waterObj)
    end

    -- Priority 2: Drink from inventory
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

-- Rest in place: clear queue and let the engine recover endurance passively.
local function doRest(player)
    AutoPilot_LLM.log("[Needs] Exhausted — resting.")
    ISTimedActionQueue.clear(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    for dx = -3, 3 do
        for dy = -3, 3 do
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            if sq then
                for i = 0, sq:getObjects():size() - 1 do
                    local obj = sq:getObjects():get(i)
                    if obj and obj:getProperties() and obj:getProperties():Is("IsSeat") then
                        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, sq))
                        return true
                    end
                end
            end
        end
    end
    return true
end

local function doSleep(player)
    AutoPilot_LLM.log("[Needs] Sleeping...")
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    for dx = -5, 5 do
        for dy = -5, 5 do
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            if sq then
                for i = 0, sq:getObjects():size() - 1 do
                    local obj = sq:getObjects():get(i)
                    if obj and obj:getProperties() and obj:getProperties():Is("IsBed") then
                        AutoPilot_LLM.log("[Needs] Found bed — getting on it.")
                        ISTimedActionQueue.add(ISGetOnBedAction:new(player, obj, sq))
                        return true
                    end
                end
            end
        end
    end

    AutoPilot_LLM.log("[Needs] No bed found — sleeping in place.")
    player:setAsleep(true)
    player:setAsleepTime(0.0)
    return true
end

-- Walk to the nearest outdoor square to relieve boredom.
local function doGoOutside(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local curSq = getCell():getGridSquare(px, py, pz)
    if curSq and curSq:isOutside() then
        AutoPilot_LLM.log("[Needs] Already outside — boredom will decrease naturally.")
        return false
    end

    AutoPilot_LLM.log("[Needs] Bored — finding outdoor square.")
    local bestSq  = nil
    local bestDist = math.huge

    for dx = -OUTDOOR_SEARCH_DIST, OUTDOOR_SEARCH_DIST do
        for dy = -OUTDOOR_SEARCH_DIST, OUTDOOR_SEARCH_DIST do
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            if sq and sq:isOutside() and sq:isFree(false) then
                local dist = dx * dx + dy * dy
                if dist < bestDist then
                    bestDist = dist
                    bestSq   = sq
                end
            end
        end
    end

    if bestSq then
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, bestSq))
        return true
    end

    AutoPilot_LLM.log("[Needs] No outdoor square found nearby.")
    return false
end

-- ── Reading (boredom/unhappiness relief) ────────────────────────────────────

local function doRead(player)
    local book = AutoPilot_Inventory.getReadable(player)
    if not book then return false end

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

local function doExercise(player)
    -- Check endurance — B42 MoodleType uses PascalCase
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.Endurance)
    if enduranceMoodle > 2 then
        AutoPilot_LLM.log("[Needs] Too exhausted to exercise (endurance moodle=" .. enduranceMoodle .. "), resting.")
        return doRest(player)
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

    local ok, action = pcall(function()
        return ISFitnessAction:new(player, exType, EXERCISE_MINUTES, exeData, exeData.type)
    end)

    if ok and action then
        ISTimedActionQueue.addGetUpAndThen(player, action)
        return true
    else
        AutoPilot_LLM.log("[Needs] ISFitnessAction failed for: " .. exType .. " — " .. tostring(action))
        return false
    end
end

-- ── Public API ──────────────────────────────────────────────────────────────

function AutoPilot_Needs.check(player)
    -- 1. Bleeding — treat immediately (fatal if untreated)
    if AutoPilot_Medical.hasCriticalWound(player) then
        if AutoPilot_Medical.check(player, true) then return true end
    end

    -- 2. Thirst (0.0=hydrated, ~1.0=dying)
    local thirst = safeStat(player, function(s) return s:getThirst() end)
    if thirst >= THIRST_STAT_THRESHOLD then
        return doDrink(player)
    end

    -- 3. Hunger (0.0=full, ~1.0=starving)
    local hunger = safeStat(player, function(s) return s:getHunger() end)
    if hunger >= HUNGER_STAT_THRESHOLD then
        return doEat(player)
    end

    -- 4. Wounds — treat non-bleeding wounds (scratches, bites, deep wounds)
    if AutoPilot_Medical.check(player, false) then return true end

    -- 5. Exhausted (endurance: 1.0=full, 0.0=empty)
    local endurance = safeStat(player, function(s) return s:getEndurance() end)
    if endurance <= ENDURANCE_REST_MIN then
        return doRest(player)
    end

    -- 6. Tired (fatigue: 0.0=rested, ~1.0=exhausted)
    local fatigue = safeStat(player, function(s) return s:getFatigue() end)
    if fatigue >= FATIGUE_STAT_THRESHOLD then
        return doSleep(player)
    end

    -- 7. Bored -> read literature first, then go outside
    local boredom = safeStat(player, function(s) return s:getBoredom() end)
    if boredom >= BOREDOM_STAT_THRESHOLD then
        if doRead(player) then return true end
        local went = doGoOutside(player)
        if went then return true end
    end

    -- 8. Idle -> exercise
    return doExercise(player)
end

-- Returns a snapshot of current stat levels for LLM state reporting.
-- B42: Uses direct Stats getters (CharacterStat enum does not exist).
function AutoPilot_Needs.getMoodleSnapshot(player)
    return {
        hungry   = math.floor(safeStat(player, function(s) return s:getHunger() end) * 100),
        thirsty  = math.floor(safeStat(player, function(s) return s:getThirst() end) * 100),
        tired    = math.floor(safeStat(player, function(s) return s:getFatigue() end) * 100),
        panicked = math.floor(safeStat(player, function(s) return s:getPanic() end)),
        injured  = safeMoodleLevel(player, MoodleType.Pain),
        sick     = math.floor(safeStat(player, function(s) return s:getSickness() end)),
        stressed = math.floor(safeStat(player, function(s) return s:getStress() end)),
        bored    = math.floor(safeStat(player, function(s) return s:getBoredom() end)),
        sad      = math.floor(safeStat(player, function(s) return s:getSanity() end)),
    }
end
