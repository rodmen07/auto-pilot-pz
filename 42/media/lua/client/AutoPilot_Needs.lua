-- AutoPilot_Needs.lua
-- Handles survival needs and idle behaviour.
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

-- ── Thresholds ────────────────────────────────────────────────────────────────

-- B42 Stats: player:getStats():get(CharacterStat.HUNGER), etc.
-- Hunger/Thirst/Fatigue: 0.0 = fine, ~1.0 = critical
-- Boredom: 0-100 scale
-- Endurance: 1.0 = full, 0.0 = empty
local HUNGER_STAT_THRESHOLD  = 0.20
local THIRST_STAT_THRESHOLD  = 0.08   -- react at slight thirst
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

-- Safe stat getter — B42 uses player:getStats():get(CharacterStat.XXX).
-- Direct getters like :getHunger() were removed in B42.
local function safeStat(player, charStat)
    local ok, val = pcall(function()
        return player:getStats():get(charStat)
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

    for dx = -REST_SEARCH_DIST, REST_SEARCH_DIST do
        for dy = -REST_SEARCH_DIST, REST_SEARCH_DIST do
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            if sq then
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
            end
        end
    end

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
        -- Use bed action for beds; walk-to for chairs/sofas
        local okB, isBed = pcall(function()
            return furniture:getSprite()
                and furniture:getSprite():getProperties()
                    :has(IsoFlagType.bed)
        end)
        if okB and isBed then
            AutoPilot_LLM.log("[Needs] Exhausted — resting on bed.")
            ISTimedActionQueue.add(ISGetOnBedAction:new(player, furniture))
        else
            AutoPilot_LLM.log("[Needs] Exhausted — resting on furniture.")
            local sq = furniture:getSquare()
            if sq then
                ISTimedActionQueue.add(ISWalkToTimedAction:new(player, sq))
            end
        end
    else
        AutoPilot_LLM.log("[Needs] Exhausted — resting in place.")
    end

    restCooldownMs = ms + 15000
    return true
end

local BED_SEARCH_DIST = 100
local BED_SEARCH_FLOORS = 3  -- check z, z+1, z-1 (ground floor + upstairs + basement)

local function doSleep(player)
    AutoPilot_LLM.log("[Needs] Sleeping...")
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local bestObj  = nil
    local bestDist = math.huge

    for dz = 0, BED_SEARCH_FLOORS - 1 do
        for _, z in ipairs({pz + dz, pz - dz}) do
            if z >= 0 then
                for dx = -BED_SEARCH_DIST, BED_SEARCH_DIST do
                    for dy = -BED_SEARCH_DIST, BED_SEARCH_DIST do
                        local sq = getCell():getGridSquare(px + dx, py + dy, z)
                        if sq then
                            for i = 0, sq:getObjects():size() - 1 do
                                local obj = sq:getObjects():get(i)
                                local ok, isBed = pcall(function()
                                    return obj:getSprite()
                                        and obj:getSprite():getProperties()
                                            :has(IsoFlagType.bed)
                                end)
                                if ok and isBed then
                                    -- Prefer same floor; penalize other floors
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
    end

    if bestObj then
        local bedSq = bestObj:getSquare()
        local bedZ = bedSq and bedSq:getZ() or pz
        if bedZ ~= pz then
            AutoPilot_LLM.log(string.format(
                "[Needs] Found bed on floor %d — walking there.", bedZ))
        else
            AutoPilot_LLM.log("[Needs] Found bed — getting on it.")
        end
        ISTimedActionQueue.add(ISGetOnBedAction:new(player, bestObj))
        return true
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
    -- Don't start exercise if endurance is too low — just idle and let it recover
    local endurance = safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance < ENDURANCE_EXERCISE_MIN or enduranceMoodle > 2 then
        -- Log once every 30s of game time, not every tick
        local ok, now = pcall(function()
            return getGameTime():getCalender():getTimeInMillis()
        end)
        local ms = ok and now or 0
        if ms >= exerciseWaitLogMs then
            AutoPilot_LLM.log(string.format(
                "[Needs] Waiting for endurance to recover (%.0f%%) before exercising.",
                endurance * 100))
            exerciseWaitLogMs = ms + 30000
        end
        return false  -- no action queued; endurance recovers passively while idle
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
    local thirst = safeStat(player, CharacterStat.THIRST)
    if thirst >= THIRST_STAT_THRESHOLD then return true end

    -- Hunger interrupts
    local hunger = safeStat(player, CharacterStat.HUNGER)
    if hunger >= HUNGER_STAT_THRESHOLD then return true end

    -- Exhaustion interrupts
    local endurance = safeStat(player, CharacterStat.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN then return true end

    return false
end

--- Main survival needs check. Both modes call this.
--- @param skipExercise boolean  If true, skip the idle→exercise step (pilot mode).
function AutoPilot_Needs.check(player, skipExercise)
    -- 1. Bleeding — treat immediately (fatal if untreated)
    if AutoPilot_Medical.hasCriticalWound(player) then
        if AutoPilot_Medical.check(player, true) then return true end
    end

    -- 2. Thirst (0.0=hydrated, ~1.0=dying)
    local thirst = safeStat(player, CharacterStat.THIRST)
    if thirst >= THIRST_STAT_THRESHOLD then
        return doDrink(player)
    end

    -- 3. Hunger (0.0=full, ~1.0=starving)
    local hunger = safeStat(player, CharacterStat.HUNGER)
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
    local fatigue = safeStat(player, CharacterStat.FATIGUE)
    if fatigue >= FATIGUE_STAT_THRESHOLD then
        return doSleep(player)
    end

    -- 6. Exhausted — check both raw endurance AND the exertion moodle.
    -- The moodle can appear before the stat drops to REST_MIN.
    local endurance = safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN or enduranceMoodle >= 1 then
        local cooldownOk, nowMs = pcall(function()
            return getGameTime():getCalender():getTimeInMillis()
        end)
        if cooldownOk and nowMs < restCooldownMs then return true end
        return doRest(player)
    end

    -- 7. Bored or Sad -> read literature first, then go outside
    local boredom = safeStat(player, CharacterStat.BOREDOM)
    local sadness = safeStat(player, CharacterStat.SANITY)
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

-- Returns a snapshot of current stat levels for LLM state reporting.
-- B42: Uses player:getStats():get(CharacterStat.XXX) pattern.
function AutoPilot_Needs.getMoodleSnapshot(player)
    return {
        hungry   = math.floor(safeStat(player, CharacterStat.HUNGER) * 100),
        thirsty  = math.floor(safeStat(player, CharacterStat.THIRST) * 100),
        tired    = math.floor(safeStat(player, CharacterStat.FATIGUE) * 100),
        panicked = math.floor(safeStat(player, CharacterStat.PANIC)),
        injured  = safeMoodleLevel(player, MoodleType.PAIN),
        sick     = math.floor(safeStat(player, CharacterStat.SICKNESS)),
        stressed = math.floor(safeStat(player, CharacterStat.STRESS)),
        bored    = math.floor(safeStat(player, CharacterStat.BOREDOM)),
        sad      = math.floor(safeStat(player, CharacterStat.SANITY)),
    }
end
