-- AutoPilot_Needs.lua
-- Handles survival needs and idle behaviour.
--
-- luacheck: globals getClimateManager
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

-- Phase 2: daily exercise tracking (resets on day rollover)
local _exerciseSetsToday = 0
local _lastTrackedDay    = -1

-- Phase 3: consecutive loot cycles with no food/drink found (triggers supply run)
local _emptyLootCycles = 0
local drinkCooldownMs = 0

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
local OUTDOOR_SEARCH_DIST    = 150

local PAIN_SLEEP_THRESHOLD   = 30   -- 0-100 scale: pain above this may prevent sleeping

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
    -- Prefer food close to current hunger need to avoid overfeeding.
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    local food = nil
    if AutoPilot_Inventory and AutoPilot_Inventory.getBestFoodForHunger then
        local ok, selected = pcall(function()
            return AutoPilot_Inventory.getBestFoodForHunger(player, hunger)
        end)
        if ok then food = selected end
    end
    if not food and AutoPilot_Inventory and AutoPilot_Inventory.selectFoodByWeight then
        local ok, selected = pcall(function()
            return AutoPilot_Inventory.selectFoodByWeight(player)
        end)
        if ok then food = selected end
    end
    if not food and AutoPilot_Inventory and AutoPilot_Inventory.getBestFood then
        local ok, selected = pcall(function()
            return AutoPilot_Inventory.getBestFood(player)
        end)
        if ok then food = selected end
    end
    if not food then
        print("[Needs] Hungry but no food in inventory — looting nearby.")
        local found = AutoPilot_Inventory.lootNearbyFood(player)
        if not found then
            _emptyLootCycles = _emptyLootCycles + 1
            print(("[Needs] Empty loot cycle %d/%d."):format(
                _emptyLootCycles, AutoPilot_Constants.SUPPLY_RUN_TRIGGER))
            if _emptyLootCycles >= AutoPilot_Constants.SUPPLY_RUN_TRIGGER then
                print("[Needs] Supply run triggered — expanding food loot radius.")
                local foodPred = function(item)
                    return item:isFood() and not item:isRotten()
                        and (item:getCalories() or 0) > 0
                end
                AutoPilot_Inventory.supplyRunLoot(player, foodPred)
                _emptyLootCycles = 0
            end
        else
            _emptyLootCycles = 0
        end
        return false
    end
    _emptyLootCycles = 0
    print("[Needs] Best food: " .. tostring(food:getName())
        .. " (cal=" .. tostring(food:getCalories()) .. ")")
    print("[Needs] Eating: " .. tostring(food:getName()))
    ISTimedActionQueue.add(ISEatFoodAction:new(player, food, 1))
    return true
end

local function doDrink(player)
    local okNow, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms = okNow and nowMs or 0
    if ms < drinkCooldownMs then
        return false
    end

    -- Priority 1: nearby water source — fill container first, then drink
    local waterObj = AutoPilot_Inventory.findWaterSource(player)
    if waterObj then
        _emptyLootCycles = 0
        AutoPilot_Inventory.refillWaterContainer(player, waterObj)
        local drank = AutoPilot_Inventory.drinkFromSource(player, waterObj)
        if drank then
            drinkCooldownMs = ms + 8000
        end
        return drank
    end

    -- Priority 2: Drink from inventory (filled glass/bottle)
    local drink = AutoPilot_Inventory.getBestDrink(player)
    if drink then
        _emptyLootCycles = 0
        print("[Needs] Drinking: " .. tostring(drink:getName()))
        ISTimedActionQueue.add(ISEatFoodAction:new(player, drink, 1))
        drinkCooldownMs = ms + 5000
        return true
    end

    -- Priority 3: Loot a drink from nearby containers
    print("[Needs] Thirsty but no drink — attempting to loot nearby.")
    local found = AutoPilot_Inventory.lootNearbyDrink(player)
    if not found then
        _emptyLootCycles = _emptyLootCycles + 1
        print(("[Needs] Empty loot cycle %d/%d."):format(
            _emptyLootCycles, AutoPilot_Constants.SUPPLY_RUN_TRIGGER))
        if _emptyLootCycles >= AutoPilot_Constants.SUPPLY_RUN_TRIGGER then
            print("[Needs] Supply run triggered — expanding drink loot radius.")
            local drinkPred = function(item)
                return item:isFood() and not item:isRotten()
                    and item:getThirstChange() and item:getThirstChange() < 0
            end
            AutoPilot_Inventory.supplyRunLoot(player, drinkPred)
            _emptyLootCycles = 0
        end
    else
        _emptyLootCycles = 0
    end
    return false
end

-- Rest on nearby furniture to recover endurance.
-- Searches for bed > couch/sofa > chair within REST_SEARCH_DIST tiles.
-- Falls back to resting in place if nothing found.
local restCooldownMs = 0
local REST_SEARCH_DIST = 150

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

    local function queueGroundRest()
        if not ISSitOnGround or not ISSitOnGround.new then
            return false
        end
        local okSit, sitAction = pcall(function()
            local sq = player and player.getCurrentSquare and player:getCurrentSquare() or nil
            return ISSitOnGround:new(player, sq)
        end)
        if okSit and sitAction then
            print("[Needs] Exhausted — no furniture found; sitting on ground to recover.")
            ISTimedActionQueue.add(sitAction)
            return true
        end
        return false
    end

    local target = findRestFurniture(player)
    if not target then
        if queueGroundRest() then
            restCooldownMs = ms + 60000
            return true
        end
        print("[Needs] Exhausted but no valid rest furniture found; skipping rest.")
        return false
    end

    local targetSq = target:getSquare()
    if not targetSq then
        print("[Needs] Rest target has no square; skipping rest.")
        return false
    end

    ISTimedActionQueue.clear(player)

    local queued = false

    local okBed, isBed = pcall(function()
        return target:getSprite()
            and target:getSprite():getProperties()
                :has(IsoFlagType.bed)
    end)

    if okBed and isBed then
        print("[Needs] Exhausted — using nearby bed to recover.")
        if AdjacentFreeTileFinder.isTileOrAdjacent(player:getCurrentSquare(), targetSq) then
            ISTimedActionQueue.add(ISGetOnBedAction:new(player, target))
            queued = true
        else
            local adjacent = AdjacentFreeTileFinder.Find(targetSq, player)
            if adjacent then
                ISTimedActionQueue.add(ISWalkToTimedAction:new(player, adjacent))
                ISTimedActionQueue.add(ISGetOnBedAction:new(player, target))
                queued = true
            end
        end
    else
        print("[Needs] Exhausted — resting using nearby furniture.")

        if ISPathFindAction and ISPathFindAction.pathToSitOnFurniture then
            local okPath, pathAction = pcall(function()
                return ISPathFindAction:pathToSitOnFurniture(player, target, nil)
            end)
            if okPath and pathAction then
                ISTimedActionQueue.add(pathAction)
                queued = true
            end
        end

        if ISRestAction and ISRestAction.new then
            local okRest, restAction = pcall(function()
                return ISRestAction:new(player, target, nil)
            end)
            if okRest and restAction then
                ISTimedActionQueue.add(restAction)
                queued = true
            end
        end
    end

    if not queued then
        if queueGroundRest() then
            restCooldownMs = ms + 60000
            return true
        end
        print("[Needs] Unable to queue a safe rest action.")
        return false
    end

    restCooldownMs = ms + 60000   -- 60s: give endurance time to recover
    return true
end

local sleepCooldownMs = 0

local BED_SEARCH_DIST = 150
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
    -- Always do a multi-floor scan around the player — home bounds are z-locked
    -- to ground floor, which misses upstairs beds. Prefer nearest bed regardless.
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

    -- If pain is high, attempt medical relief or painkillers before sleeping.
    local painVal = AutoPilot_Utils.safeStat(player, CharacterStat.PAIN)
    if painVal >= PAIN_SLEEP_THRESHOLD then
        print("[Needs] Sleep blocked by pain (" .. tostring(painVal) .. "). Attempting medical/pain relief.")
        local okMed, medQueued = pcall(function() return AutoPilot_Medical.check(player, false) end)
        if okMed and medQueued then
            print("[Needs] Queued medical treatment to reduce pain.")
            return true
        end

        -- Try to find painkillers in inventory (match type/name heuristics)
        local inv = player:getInventory()
        local items = inv and inv:getItems()
        if items then
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                if item then
                    local okType, typ = pcall(function() return item:getType() end)
                    local okName, name = pcall(function() return item:getName() end)
                    local lower = ""
                    if okType and typ then lower = lower .. typ:lower() end
                    if okName and name then lower = lower .. " " .. name:lower() end
                    if lower:find("painkill") or lower:find("aspirin") or lower:find("paracetamol") then
                        local takePill = rawget(_G, "ISTakePillAction")
                        local okUse = pcall(function()
                            if takePill and takePill.new then
                                ISTimedActionQueue.add(takePill:new(player, item))
                            else
                                ISTimedActionQueue.add(ISEatFoodAction:new(player, item, 1))
                            end
                        end)
                        if okUse then
                            local pname = (okName and name) or typ
                            print("[Needs] Taking painkiller: " .. tostring(pname))
                            return true
                        end
                    end
                end
            end
        end

        -- No treatment available; delay sleep attempts to avoid a busy loop.
        sleepCooldownMs = ms + 60000
        print("[Needs] No medical/painkiller available; delaying sleep for 60s.")
        return false
    end

    print("[Needs] Sleeping...")
    ISTimedActionQueue.clear(player)

    local bedObj = _findBedNearby(player)
    if not bedObj then
        -- Forcing sleep via setAsleep is client-only; the server never learns of
        -- the state change, causing fatigue desync in MP.  Retry next cycle.
        if AutoPilot_Home.isSet(player) then
            print(
                "[Needs] No bed found inside home bounds — cannot force sleep (MP-unsafe); will retry.")
        else
            print("[Needs] No bed found — cannot force sleep (MP-unsafe); will retry.")
        end
        return false
    end

    local bedSq = bedObj:getSquare()
    print("[Needs] Found bed — walking to it.")

    -- Build 42 beds are multi-tile sprite grids. Walk to an adjacent tile first,
    -- then queue ISGetOnBedAction — mirrors ISWorldObjectContextMenu.onConfirmSleep.
    player:setVariable("ExerciseStarted", false)
    player:setVariable("ExerciseEnded", true)

    if AdjacentFreeTileFinder.isTileOrAdjacent(player:getCurrentSquare(), bedSq) then
        local bedAction = ISGetOnBedAction:new(player, bedObj)
        ISTimedActionQueue.add(bedAction)
        print("[Needs] Queued ISGetOnBedAction directly.")
    else
        local adjacent = AdjacentFreeTileFinder.Find(bedSq, player)
        if adjacent then
            local walkAction = ISWalkToTimedAction:new(player, adjacent)
            local bedAction = ISGetOnBedAction:new(player, bedObj)
            if walkAction.addAfter then
                walkAction:addAfter(bedAction)
                ISTimedActionQueue.add(walkAction)
            else
                ISTimedActionQueue.add(walkAction)
                ISTimedActionQueue.add(bedAction)
            end
        else
            print("[Needs] Bed unreachable — no adjacent free tile found.")
            return false
        end
    end

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
        print("[Needs] Already outside — boredom will decrease naturally.")
        return false
    end

    print("[Needs] Bored — finding outdoor square.")

    -- Home set: only search within home bounds
    if AutoPilot_Home.isSet(player) then
        local outsideSq = AutoPilot_Home.getNearestInside(player, function(sq)
            return sq:isOutside() and sq:isFree(false)
        end)
        if outsideSq then
            ISTimedActionQueue.add(ISWalkToTimedAction:new(player, outsideSq))
            return true
        end
        print("[Needs] No outdoor square found inside home bounds — skipping.")
        return false
    end

    -- No home set: skip outdoor walk for safety (containment guard)
    print("[Needs] No home set — skipping outdoor walk.")
    return false
end

-- ── Weather/shelter helpers ─────────────────────────────────────────────────

local function isRaining()
    local ok, raining = pcall(function()
        local cm = getClimateManager and getClimateManager()
        if cm and cm.getIsRaining then return cm:getIsRaining() end
        if cm and cm.getCurrentWeather and cm:getCurrentWeather() and cm:getCurrentWeather().isRaining then
            return cm:getCurrentWeather():isRaining()
        end
        return false
    end)
    return ok and raining
end

local function doSeekShelter(player)
    if not player then return false end

    local sq = player:getCurrentSquare()
    if not sq or not sq:isOutside() then
        return false
    end

    if AutoPilot_Home.isSet(player) then
        local inside = AutoPilot_Home.getNearestInside(player, function(s)
            return s and s:isFree(false)
        end)
        if inside then
            print("[Needs] Seeking shelter inside home.")
            ISTimedActionQueue.add(ISWalkToTimedAction:new(player, inside))
            return true
        end
    end

    print("[Needs] No home shelter available; resting in place while outside.")
    return doRest(player)
end

-- ── Reading (boredom/unhappiness relief) ────────────────────────────────────

local function doRead(player)
    local literate = false
    local ok, lvlOrErr = pcall(function() return player:getPerkLevel(Perks.Literacy) end)
    if ok and type(lvlOrErr) == "number" then
        literate = lvlOrErr > 0
    else
        print("[Needs] literacy check pcall failed: " .. tostring(lvlOrErr))
    end
    if not literate then
        print(("[Needs] Cannot read: player considered illiterate. PerkCheck ok=%s value=%s")
            :format(tostring(ok), tostring(lvlOrErr)))
        -- Fallback debug checks (safe): query trait presence if possible
        local traitOk, hasIll = pcall(function()
            if player and player.HasTrait then return player:HasTrait("Illiterate") end
            if player and player.getDescriptor and player:getDescriptor().hasTrait then
                return player:getDescriptor():hasTrait("Illiterate")
            end
            return false
        end)
        print(("[Needs] literacy fallback checks: HasTrait ok=%s value=%s")
            :format(tostring(traitOk), tostring(hasIll)))
        return false
    end

    local book = AutoPilot_Inventory.getReadable(player)
    if not book then
        -- No readable in inventory — try looting one from nearby containers
        return AutoPilot_Inventory.lootNearbyReadable(player)
    end

    -- Check if too dark to read
    local darkOk, tooDark = pcall(function() return player:tooDarkToRead() end)
    if darkOk and tooDark then
        print("[Needs] Too dark to read.")
        return false
    end

    print("[Needs] Reading: " .. tostring(book:getName()))
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
    -- Phase 2: day-rollover reset
    local _gameTime = GameTime.getInstance()
    local _today    = _gameTime and _gameTime:getDay() or 0
    if _today ~= _lastTrackedDay then
        _exerciseSetsToday = 0
        _lastTrackedDay    = _today
    end
    -- Phase 2: daily cap gate
    if _exerciseSetsToday >= AutoPilot_Constants.EXERCISE_DAILY_CAP then
        print(("[Needs] Daily exercise cap %d reached — resting."):format(
            AutoPilot_Constants.EXERCISE_DAILY_CAP))
        return false
    end
    -- Phase 2: endurance gate
    local _endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    if _endurance < AutoPilot_Constants.EXERCISE_ENDURANCE_MIN then
        print(("[Needs] Endurance %.2f < %.2f — skipping exercise."):format(
            _endurance, AutoPilot_Constants.EXERCISE_ENDURANCE_MIN))
        return false
    end
    -- Don't start exercise if endurance is too low — just idle and let it recover
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance < ENDURANCE_EXERCISE_MIN or enduranceMoodle > 2 then
        -- Log once every 30s of game time, not every tick
        local ok, now = pcall(function()
            return getGameTime():getCalender():getTimeInMillis()
        end)
        local ms = ok and now or 0
        if ms >= exerciseWaitLogMs then
            print(string.format(
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
        print(string.format("[Needs] Exercise — training Strength (STR %d / FIT %d)",
            strLevel, fitLevel))
    else
        exercises = FITNESS_EXERCISES
        print(string.format("[Needs] Exercise — training Fitness (STR %d / FIT %d)",
            strLevel, fitLevel))
    end

    -- Guard: exercises table must be non-empty before indexing.
    if #exercises == 0 then
        print("[Needs] No exercises defined for current focus — skipping.")
        return false
    end
    local exType = exercises[((exerciseCycle - 1) % #exercises) + 1]
    exerciseCycle = exerciseCycle + 1

    local exeData = nil
    if FitnessExercises and FitnessExercises.exercisesType then
        exeData = FitnessExercises.exercisesType[exType]
    end

    if not exeData then
        print("[Needs] FitnessExercises data not found for: " .. exType)
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
        -- Phase 2: equip best available exercise gear before starting
        local _tier = AutoPilot_Inventory.equipBestExerciseItem(player)
        print(("[Needs] Exercise tier: %s"):format(_tier))
        ISTimedActionQueue.addGetUpAndThen(player, action)
        _exerciseSetsToday = _exerciseSetsToday + 1
        print(("[Needs] Exercise set %d/%d queued."):format(
            _exerciseSetsToday, AutoPilot_Constants.EXERCISE_DAILY_CAP))
        return true
    else
        print("[Needs] ISFitnessAction failed for: " .. exType .. " — " .. tostring(action))
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

--- Main survival needs check.
function AutoPilot_Needs.check(player)
    -- 1. Bleeding — treat immediately (fatal if untreated)
    if AutoPilot_Medical.hasCriticalWound(player) then
        if AutoPilot_Medical.check(player, true) then return true end
    end

    -- Sleep overrides rest cooldown — fatigue is checked before the cooldown gate
    -- so the character can transition from resting to sleeping when tired enough.
    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    if fatigue >= FATIGUE_STAT_THRESHOLD then
        return doSleep(player)
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

    -- Environmental comfort guard: seek shelter if outside in bad conditions.
    local currentSq = player:getCurrentSquare()
    local tempDelta = 0
    if AutoPilot_Inventory and AutoPilot_Inventory.bodyTemperature then
        local okTemp, t = pcall(function()
            return AutoPilot_Inventory.bodyTemperature(player)
        end)
        if okTemp and type(t) == "number" then
            tempDelta = t
        end
    end
    if currentSq and currentSq:isOutside() then
        if isRaining() or tempDelta < AutoPilot_Constants.TEMP_TOO_COLD then
            print("[Needs] Outdoors bad comfort (rain/cold) — seeking shelter.")
            if doSeekShelter(player) then return true end
        end
    end

    -- 3. Hunger (0.0=full, ~1.0=starving)
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    if hunger >= HUNGER_STAT_THRESHOLD then
        print(string.format(
            "[Needs] Hunger triggered (%.0f%%). Attempting to eat.", hunger * 100))
        local ate = doEat(player)
        if ate then return true end
        print("[Needs] doEat returned false — no food available, continuing.")
    end

    -- 4. Wounds — treat non-bleeding wounds (scratches, bites, deep wounds)
    if AutoPilot_Medical.check(player, false) then return true end

    -- Phase 4: temperature comfort check
    if AutoPilot_Inventory.adjustClothing(player) then return end

    -- 5. Tired — already checked above (before rest cooldown gate)

    -- 6. Exhausted — rest only when endurance is critically low (stat ≤ 30%)
    -- or the exertion moodle is severe (level 3+).  Moodle level 1-2 is mild
    -- exertion that recovers on its own; reacting to it causes a sit-stand loop.
    -- (Rest cooldown is already enforced at the top of check().)
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN or enduranceMoodle >= 3 then
        return doRest(player)
    end

    -- 7. Bored, Sad, or Unhappy -> prefer tasty food, then read, then go outside
    local boredom     = AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM)
    local sadness     = AutoPilot_Utils.safeStat(player, CharacterStat.SANITY)
    local unhappyLvl  = safeMoodleLevel(player, MoodleType.Unhappy)
    if boredom >= BOREDOM_STAT_THRESHOLD or sadness >= SADNESS_STAT_THRESHOLD
        or unhappyLvl >= AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD then
        -- Phase 3: when unhappy, prefer food that reduces boredom first
        if unhappyLvl >= AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD then
            local tastyFood = AutoPilot_Inventory.preferTastyFood(player)
            if tastyFood then
                print("[Needs] Unhappy — eating tasty food: "
                    .. tostring(tastyFood:getName()))
                ISTimedActionQueue.add(ISEatFoodAction:new(player, tastyFood, 1))
                return true
            end
        end
        if doRead(player) then return true end
        if boredom >= BOREDOM_STAT_THRESHOLD then
            local went = doGoOutside(player)
            if went then return true end
        end
    end

    -- 8. Idle -> exercise (default behavior)
    return doExercise(player)
end

-- ── Public aliases for chain-action use ──────────────────────────────────────
-- AutoPilot_Actions.lua references these so it can delegate without duplicating
-- the full bed-search and outdoor-square-search logic.
AutoPilot_Needs.trySleep    = doSleep
AutoPilot_Needs.tryGoOutside = doGoOutside

--- Return how many consecutive empty loot cycles have accumulated (Phase 3).
function AutoPilot_Needs.getEmptyLootCycles()
    return _emptyLootCycles
end

--- Return how many exercise sets have been performed today.
function AutoPilot_Needs.getExerciseSetsToday()
    return _exerciseSetsToday
end

--- Return preferred exercise type based on STR vs FIT perk level.
--- Returns "strength", "fitness", or "either".
function AutoPilot_Needs.preferredExerciseType(player)
    local ok, strLvl, fitLvl = pcall(function()
        return player:getPerkLevel(Perks.Strength),
               player:getPerkLevel(Perks.Fitness)
    end)
    if not ok or strLvl == nil or fitLvl == nil then return "either" end
    if strLvl < fitLvl then
        print(("[Needs] STR %d < FIT %d — preferring strength."):format(strLvl, fitLvl))
        return "strength"
    elseif fitLvl < strLvl then
        print(("[Needs] FIT %d < STR %d — preferring fitness."):format(fitLvl, strLvl))
        return "fitness"
    end
    return "either"
end

-- Returns a snapshot of current stat levels for state reporting.
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

--- Force a single survival action if needed.
function AutoPilot_Needs.forceSurvival(player)
    return AutoPilot_Needs.check(player)
end

function AutoPilot_Needs.forceEat(player)
    return doEat(player)
end

function AutoPilot_Needs.forceDrink(player)
    return doDrink(player)
end

function AutoPilot_Needs.forceSleep(player)
    return doSleep(player)
end

function AutoPilot_Needs.forceRest(player)
    return doRest(player)
end

function AutoPilot_Needs.forceExercise(player)
    return doExercise(player)
end

function AutoPilot_Needs.printStatus(player)
    local moodles = AutoPilot_Needs.getMoodleSnapshot(player)
    print(string.format(
        "[Needs] Status: health=%.0f%% endurance=%.0f%% hungry=%d thirsty=%d tired=%d bored=%d",
        player:getHealth() * 100,
        AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE) * 100,
        moodles.hungry, moodles.thirsty, moodles.tired, moodles.bored
    ))
end
