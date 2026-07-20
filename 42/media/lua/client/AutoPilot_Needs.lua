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
--   7. Scavenge      -> proactive supply top-up before stats drop
--   8. Explore       -> frontier scouting and supply runs
--   9. Bored/Sad     -> read literature, then go outside
--  10. Idle          -> exercise (strength/fitness alternating by level)

AutoPilot_Needs = {}

local function _apNoop(...) end
local print = _apNoop

-- Phase 2: daily exercise tracking (resets on day rollover)
local _exerciseSetsToday = 0
local _lastTrackedDay    = -1
-- In-game day of the last equipment-fetch attempt (one trip per day).
local _equipFetchDay     = -1

-- Phase 3: consecutive loot cycles with no food/drink found (triggers supply run)
local _emptyLootCycles = 0
local drinkCooldownMs = 0

-- ── Thresholds ────────────────────────────────────────────────────────────────
-- All policy numbers are defined in AutoPilot_Constants.  The local aliases
-- below exist purely for readability inside this module; changing the policy
-- means updating AutoPilot_Constants, not this file.

-- B42 Stats: player:getStats():get(CharacterStat.HUNGER), etc.
-- Hunger/Thirst/Fatigue: 0.0 = fine, ~1.0 = critical
-- Boredom: 0-100 scale
-- Endurance: 1.0 = full, 0.0 = empty
-- NOTE: hunger/thirst trigger thresholds are read LIVE from
-- AutoPilot_Constants at each use site (not cached here): the Adaptive layer
-- lowers them after starvation/dehydration deaths at runtime.
local FATIGUE_STAT_THRESHOLD = AutoPilot_Constants.FATIGUE_THRESHOLD
local BOREDOM_STAT_THRESHOLD = AutoPilot_Constants.BOREDOM_THRESHOLD
local ENDURANCE_REST_MIN     = AutoPilot_Constants.ENDURANCE_REST_MIN
local ENDURANCE_EXERCISE_MIN = AutoPilot_Constants.ENDURANCE_EXERCISE_MIN
local EXERCISE_MINUTES       = AutoPilot_Constants.EXERCISE_MINUTES
local OUTDOOR_SEARCH_DIST    = AutoPilot_Constants.OUTDOOR_SEARCH_DIST

local PAIN_SLEEP_THRESHOLD   = AutoPilot_Constants.PAIN_SLEEP_THRESHOLD

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

-- Helper: handle empty loot cycle tracking and supply run triggering.
-- itemPred: predicate function to select items for supply run.
-- Returns true if a supply run was triggered.
local function trackEmptyLootCycle(player, itemPred)
    _emptyLootCycles = _emptyLootCycles + 1
    print(("[Needs] Empty loot cycle %d/%d."):format(
        _emptyLootCycles, AutoPilot_Constants.SUPPLY_RUN_TRIGGER))
    if _emptyLootCycles >= AutoPilot_Constants.SUPPLY_RUN_TRIGGER then
        print("[Needs] Supply run triggered — expanding loot radius.")
        AutoPilot_Inventory.supplyRunLoot(player, itemPred)
        _emptyLootCycles = 0
        return true
    end
    return false
end

local function doEat(player)
    -- Prefer food close to current hunger need to avoid overfeeding.
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    local food, foodCont = nil, nil
    if AutoPilot_Inventory and AutoPilot_Inventory.getBestFoodForHunger then
        local ok, selected, cont = pcall(function()
            return AutoPilot_Inventory.getBestFoodForHunger(player, hunger)
        end)
        if ok then food, foodCont = selected, cont end
    end
    if not food and AutoPilot_Inventory and AutoPilot_Inventory.selectFoodByWeight then
        local ok, selected, cont = pcall(function()
            return AutoPilot_Inventory.selectFoodByWeight(player)
        end)
        if ok then food, foodCont = selected, cont end
    end
    if not food and AutoPilot_Inventory and AutoPilot_Inventory.getBestFood then
        local ok, selected, cont = pcall(function()
            return AutoPilot_Inventory.getBestFood(player)
        end)
        if ok then food, foodCont = selected, cont end
    end
    if not food then
        print("[Needs] Hungry but no food in inventory — looting nearby.")
        local found = AutoPilot_Inventory.lootNearbyFood(player)
        if not found then
            local foodPred = function(item)
                return item:isFood() and not item:isRotten()
                    and (item:getCalories() or 0) > 0
            end
            trackEmptyLootCycle(player, foodPred)
        else
            _emptyLootCycles = 0
        end
        return false
    end
    _emptyLootCycles = 0
    print("[Needs] Best food: " .. tostring(food:getName())
        .. " (cal=" .. tostring(food:getCalories()) .. ")")
    print("[Needs] Eating: " .. tostring(food:getName()))
    -- V4.9: food found inside a backpack (V4.8) cannot be eaten from there;
    -- queue the move to the main inventory first, then the eat behind it.
    local _, usable = AutoPilot_Utils.queueItemToMainInventory(player, food, foodCont)
    if not usable then
        print("[Needs] Food transfer refused: not eating this cycle.")
        return false
    end
    AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, food, 1))
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
    local drink, drinkCont = AutoPilot_Inventory.getBestDrink(player)
    if drink then
        _emptyLootCycles = 0
        print("[Needs] Drinking: " .. tostring(drink:getName()))
        -- V4.9: transfer out of a bag first, then drink (same cycle, in order).
        local _, usable = AutoPilot_Utils.queueItemToMainInventory(
            player, drink, drinkCont)
        if not usable then
            print("[Needs] Drink transfer refused: not drinking this cycle.")
            return false
        end
        AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, drink, 1))
        drinkCooldownMs = ms + 5000
        return true
    end

    -- Priority 3: Loot a drink from nearby containers
    print("[Needs] Thirsty but no drink — attempting to loot nearby.")
    local found = AutoPilot_Inventory.lootNearbyDrink(player)
    if not found then
        local drinkPred = function(item)
            return item:isFood() and not item:isRotten()
                and item:getThirstChange() and item:getThirstChange() < 0
        end
        trackEmptyLootCycle(player, drinkPred)
    else
        _emptyLootCycles = 0
    end
    return false
end

-- Rest on nearby furniture to recover endurance.
-- Searches for bed > couch/sofa > chair within REST_SEARCH_DIST tiles.
-- Falls back to resting in place if nothing found.
local restCooldownMs = 0
local REST_SEARCH_DIST = AutoPilot_Constants.REST_SEARCH_DIST

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
            AutoPilot_Utils.queueModAction(sitAction)
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
        -- B42 sleep goes through ISWorldObjectContextMenu.onSleepWalkToComplete,
        -- which takes the 0-based player index (not the player object) and handles
        -- the walk-to + setAsleep, including MP SleepAllowed checks.
        local pnum = player:getPlayerNum()
        if AdjacentFreeTileFinder.isTileOrAdjacent(player:getCurrentSquare(), targetSq) then
            ISWorldObjectContextMenu.onSleepWalkToComplete(pnum, target)
            queued = true
        else
            local adjacent = AdjacentFreeTileFinder.Find(targetSq, player)
            if adjacent then
                local walkAction = ISWalkToTimedAction:new(player, adjacent)
                walkAction:setOnComplete(ISWorldObjectContextMenu.onSleepWalkToComplete, pnum, target)
                AutoPilot_Utils.queueModAction(walkAction)
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
                AutoPilot_Utils.queueModAction(pathAction)
                queued = true
            end
        end

        if ISRestAction and ISRestAction.new then
            -- Real 42.19 signature (shared/TimedActions/ISRestAction.lua:245):
            -- ISRestAction:new(character, bed, useAnimations).
            local okRest, restAction = pcall(function()
                return ISRestAction:new(player, target, nil)
            end)
            if okRest and restAction then
                AutoPilot_Utils.queueModAction(restAction)
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

local BED_SEARCH_DIST   = AutoPilot_Constants.BED_SEARCH_DIST
local BED_SEARCH_FLOORS = AutoPilot_Constants.BED_SEARCH_FLOORS

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

    -- Build z-level candidates: current floor first, then alternating up/down
    local zlevels = {pz}
    for offset = 1, BED_SEARCH_FLOORS - 1 do
        table.insert(zlevels, pz + offset)
        table.insert(zlevels, pz - offset)
    end

    for _, z in ipairs(zlevels) do
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

        -- Try to find painkillers the player is carrying (match type/name
        -- heuristics).  V4.8: searches worn/carried sub-containers too, so
        -- pills in a backpack or fanny pack are no longer invisible.
        local tookPill = false
        AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
            if not item then return false end
            local okType, typ = pcall(function() return item:getType() end)
            local okName, name = pcall(function() return item:getName() end)
            local lower = ""
            if okType and typ then lower = lower .. typ:lower() end
            if okName and name then lower = lower .. " " .. name:lower() end
            if lower:find("painkill") or lower:find("aspirin") or lower:find("paracetamol") then
                -- V4.9: pills in a bag must reach the main inventory first.
                local _, usable = AutoPilot_Utils.queueItemToMainInventory(
                    player, item, container)
                if not usable then
                    print("[Needs] Painkiller transfer refused: skipping this item.")
                    return false
                end
                local takePill = rawget(_G, "ISTakePillAction")
                local okUse = pcall(function()
                    if takePill and takePill.new then
                        AutoPilot_Utils.queueModAction(takePill:new(player, item))
                    else
                        AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, item, 1))
                    end
                end)
                if okUse then
                    local pname = (okName and name) or typ
                    print("[Needs] Taking painkiller: " .. tostring(pname))
                    tookPill = true
                    return true
                end
            end
            return false
        end)
        if tookPill then return true end

        -- No treatment available; delay sleep attempts to avoid a busy loop.
        sleepCooldownMs = ms + 60000
        print("[Needs] No medical/painkiller available; delaying sleep for 60s.")
        return false
    end

    print("[Needs] Sleeping...")
    ISTimedActionQueue.clear(player)

    local bedObj = _findBedNearby(player)
    if not bedObj then
        -- Already seated in a vehicle? B42 counts it as "averageBed"
        -- (onSleepWalkToComplete with a nil bed checks getVehicle()).
        local inVehicle = false
        pcall(function() inVehicle = player:getVehicle() ~= nil end)
        if inVehicle then
            player:setVariable("ExerciseStarted", false)
            player:setVariable("ExerciseEnded", true)
            ISWorldObjectContextMenu.onSleepWalkToComplete(player:getPlayerNum(), nil)
            print("[Needs] Sleeping in vehicle (no bed found).")
            sleepCooldownMs = ms + 15000
            return true
        end
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

    -- Build 42 sleeps via ISWorldObjectContextMenu.onSleepWalkToComplete(playerIndex, bed):
    -- it takes the 0-based player index (not the player object), re-resolves the player
    -- with getSpecificPlayer, runs the zombie/pain/panic safety checks, and calls
    -- setAsleep(true) — mirrors the vanilla onConfirmSleep flow.
    player:setVariable("ExerciseStarted", false)
    player:setVariable("ExerciseEnded", true)

    local pnum = player:getPlayerNum()
    if AdjacentFreeTileFinder.isTileOrAdjacent(player:getCurrentSquare(), bedSq) then
        ISWorldObjectContextMenu.onSleepWalkToComplete(pnum, bedObj)
        print("[Needs] Sleeping in adjacent bed.")
    else
        local adjacent = AdjacentFreeTileFinder.Find(bedSq, player)
        if adjacent then
            local walkAction = ISWalkToTimedAction:new(player, adjacent)
            walkAction:setOnComplete(ISWorldObjectContextMenu.onSleepWalkToComplete, pnum, bedObj)
            AutoPilot_Utils.queueModAction(walkAction)
            print("[Needs] Walking to bed, then sleeping.")
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
            AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, outsideSq))
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
            AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, inside))
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

    local book, bookCont = AutoPilot_Inventory.getReadable(player)
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
    -- V4.9: a book in a bag must reach the main inventory before ISReadABook.
    local _, usable = AutoPilot_Utils.queueItemToMainInventory(player, book, bookCont)
    if not usable then
        print("[Needs] Book transfer refused: not reading this cycle.")
        return false
    end
    local readOk, _ = pcall(function()
        AutoPilot_Utils.queueModAction(ISReadABook:new(player, book))
    end)
    return readOk
end

-- ── Proactive / AFK idle behaviours ────────────────────────────────────────

-- Proactive scavenge: loot when carried supply counts are low, even when
-- hunger/thirst stats have not yet reached their reactive thresholds.
-- RATE-LIMITED (V3.2): a background chore, not the mod's purpose.  It stays
-- within PROACTIVE_LOOT_RADIUS of the character, waits SCAVENGE_COOLDOWN
-- cycles between trips, and after SCAVENGE_STUCK_LIMIT trips with no supply
-- improvement it backs off for SCAVENGE_BACKOFF_CYCLES (the area is looted
-- out; reactive hunger/thirst paths still search the full radius when it
-- actually matters).
local _scavengeCooldown  = 0
local _scavengeStuck     = 0
local _scavengeLastTotal = -1

local function doProactiveScavenge(player)
    if not (AutoPilot_Inventory and AutoPilot_Inventory.getSupplyCounts) then
        return false
    end
    if _scavengeCooldown > 0 then
        _scavengeCooldown = _scavengeCooldown - 1
        return false
    end
    local ok, foodCount, drinkCount = pcall(function()
        return AutoPilot_Inventory.getSupplyCounts(player)
    end)
    if not ok then return false end
    foodCount  = foodCount  or 0
    drinkCount = drinkCount or 0

    local needFood  = foodCount  < AutoPilot_Constants.SUPPLY_FOOD_MIN
    local needDrink = drinkCount < AutoPilot_Constants.SUPPLY_DRINK_MIN
    if not needFood and not needDrink then
        _scavengeStuck     = 0
        _scavengeLastTotal = -1
        return false
    end

    -- Give-up detection: repeated trips without the counts improving mean the
    -- nearby area has nothing useful left.
    local total = foodCount + drinkCount
    if _scavengeLastTotal >= 0 and total <= _scavengeLastTotal then
        _scavengeStuck = _scavengeStuck + 1
    else
        _scavengeStuck = 0
    end
    _scavengeLastTotal = total
    if _scavengeStuck >= AutoPilot_Constants.SCAVENGE_STUCK_LIMIT then
        print(string.format(
            "[Needs] Proactive scavenge: no supply gain after %d trips -- backing off.",
            _scavengeStuck))
        _scavengeStuck    = 0
        _scavengeCooldown = AutoPilot_Constants.SCAVENGE_BACKOFF_CYCLES
        return false
    end

    _scavengeCooldown = AutoPilot_Constants.SCAVENGE_COOLDOWN_CYCLES
    local radius = AutoPilot_Constants.PROACTIVE_LOOT_RADIUS

    if needFood then
        print(string.format("[Needs] Proactive: food=%d < %d -- looting.",
            foodCount, AutoPilot_Constants.SUPPLY_FOOD_MIN))
        if AutoPilot_Inventory.lootNearbyFood(player, radius) then return true end
    end
    if needDrink then
        print(string.format("[Needs] Proactive: drink=%d < %d -- looting.",
            drinkCount, AutoPilot_Constants.SUPPLY_DRINK_MIN))
        if AutoPilot_Inventory.lootNearbyDrink(player, radius) then return true end
        -- No bottled drinks nearby: top up existing water containers from a
        -- source instead (only fires while thirst is still low).
        if AutoPilot_Inventory.proactiveWaterRefill
            and AutoPilot_Inventory.proactiveWaterRefill(player) then
            return true
        end
    end
    return false
end

-- ── Exercise ────────────────────────────────────────────────────────────────
-- B42: ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)
-- Exercise data comes from FitnessExercises.exercisesType
-- (shared/Definitions/FitnessExercises.lua): squats(legs), pushups(arms,chest),
-- situp(abs), burpees(legs,arms,chest).
--
-- Focus mapping (player design, V3.2):
--   strength -> push-ups (pure Strength work)
--   fitness  -> squats; sit-ups when the legs are too stiff for squats
--   auto     -> burpees (levels Strength AND Fitness together)

local LEG_PARTS = { "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R" }

-- True when any leg part's stiffness reaches the squat cutoff.
local function _legsTooStiffForSquats(player)
    local tooStiff = false
    pcall(function()
        local bd = player:getBodyDamage()
        for _, name in ipairs(LEG_PARTS) do
            local part = bd:getBodyPart(BodyPartType[name])
            if part and part:getStiffness()
                >= AutoPilot_Constants.SQUAT_STIFFNESS_MAX then
                tooStiff = true
                return
            end
        end
    end)
    return tooStiff
end

-- True when the exercise's required item (if any) is in the inventory.
-- Mirrors the vanilla gate (ISFitnessUI: inventory:contains(item, true)).
local function _hasExerciseItem(player, exeData)
    if not exeData.item then return true end
    local has = false
    pcall(function()
        has = player:getInventory():contains(exeData.item, true)
    end)
    return has
end

-- Ordered exercise candidates for the focus; the first one that has
-- definition data, whose required item is carried, and that is not
-- XP-fatigued is used.  Later entries are fallbacks for when the primary
-- exercise stops yielding XP (PZ diminishing returns).
--
-- Equipment exercises lead the Strength pool: their xpMod (dumbbell 1.8x,
-- barbell 1.2x) belongs to the EXERCISE TYPE, so doing dumbbellpress beats
-- push-ups whenever a dumbbell is carried.  No fitness equipment exists.
local function _exerciseCandidates(player, focus)
    if focus == "strength" then
        return { "dumbbellpress", "bicepscurl", "barbellcurl", "pushups" }
    elseif focus == "fitness" then
        if _legsTooStiffForSquats(player) then
            print("[Needs] Legs too stiff for squats — switching to sit-ups.")
            return { "situp" }
        end
        return { "squats", "situp" }
    end
    -- auto: burpees train both stats at once; on fatigue, alternate strength
    -- (equipment first) and fitness work to keep both moving.
    return { "burpees", "dumbbellpress", "squats", "pushups", "situp" }
end

-- ── Per-exercise XP-productivity tracking ───────────────────────────────────
-- PZ applies per-exercise diminishing returns: repeat one exercise long
-- enough and its XP drops to ~zero while the animation happily continues.
-- The engine does not expose that fatigue to Lua (only long-term
-- getRegularity), so it is detected the honest way: by measuring the actual
-- XP a completed set produced.

-- [exType] -> { str, fit, ms }  snapshot taken when the set was queued.
local _exSetStart     = {}
-- [exType] -> game-ms until which the exercise is considered fatigued.
local _exFatiguedUntil = {}
-- Human-readable state of the trainer, shown in the F11 panel.
local _exerciseOutcome = "idle"

-- ── Player-intervention backoff (V4.5) ──────────────────────────────────────
-- The user-reported lockup: cancel an exercise and the armed trainer
-- re-queues a new set ~0.75 s later, bulldozing the cancel.  Fix: track the
-- one exercise action the mod itself queues; when it vanishes from the
-- queue before running ~a full set AND the mod did not clear it itself
-- (urgent-need interrupt, threat response, thrash guard), the player
-- intervened, and training backs off for EXERCISE_BACKOFF_MINUTES (game
-- minutes, live-read so the Options slider applies immediately).  A
-- FOREIGN exercise observed running (Main's busy cycle) refreshes the same
-- window every cycle, so training also stays away while, and shortly
-- after, the player exercises manually.  Movement input has no verified
-- read surface in this mod; in PZ movement cancels the queued action, so
-- it lands in the vanished-uncompleted path and is covered the same way.
--
-- All state is module-local: a Lua reload (MP join) starts clean, and the
-- `who` field guards against judging a dead character's set against the
-- respawned character (same pattern as _exSetStart.who).
local _pendingSet    = nil   -- { action, exType, ms, who } last mod-queued set
local _backoffUntilMs = 0    -- game-ms; training yields while now < this

local function _backoffWindowMs()
    local mins = tonumber(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES) or 0
    if mins <= 0 then return 0 end
    return mins * 60000
end

local function _setBackoff(nowMs, why)
    local windowMs = _backoffWindowMs()
    if windowMs <= 0 then return end
    _backoffUntilMs = nowMs + windowMs
    _exerciseOutcome = "backing off (" .. why .. ")"
    print("[Needs] Training backoff (" .. why .. ") for "
        .. tostring(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES)
        .. " game minutes.")
end

-- Resolve the tracked mod-queued set: still running, completed normally, or
-- vanished uncompleted (= player intervention -> backoff).  Called at the
-- top of doExercise, before any gate, so the record can never go stale.
local function _updateInterventionState(player, nowMs)
    local ps = _pendingSet
    if not ps then return end
    -- Never judge a snapshot from a different character (death/respawn).
    if ps.who ~= player then
        _pendingSet = nil
        AutoPilot_Utils.clearModAction(ps.action)
        return
    end
    local stillQueued = false
    pcall(function()
        local q   = ISTimedActionQueue.getTimedActionQueue(player)
        local arr = q and q.queue
        if type(arr) == "table" then
            for i = 1, #arr do
                if arr[i] == ps.action then
                    stillQueued = true
                    break
                end
            end
        end
    end)
    if stillQueued then return end
    -- The set left the queue: resolve the record either way.
    _pendingSet = nil
    AutoPilot_Utils.clearModAction(ps.action)
    local fullSetMs = AutoPilot_Constants.EXERCISE_MINUTES * 60000
    if (nowMs - ps.ms) < fullSetMs * 0.8 then
        -- Vanished well short of a full set and the mod did not clear it
        -- itself (those paths consume the record via noteModExerciseCleared):
        -- the player cancelled it.  Do not judge the aborted set as
        -- XP-fatigue, and back off instead of re-queuing over player intent.
        _exSetStart[ps.exType] = nil
        _setBackoff(nowMs, "manual cancel")
    end
end

local function _perkXp(player, perk)
    local ok, xp = pcall(function() return player:getXp():getXP(perk) end)
    return (ok and type(xp) == "number") and xp or 0
end

-- Judge the previous set of exType (if one ran to roughly full length):
-- returns false when the exercise is now fatigued and should be skipped.
local function _exerciseStillProductive(player, exType, nowMs)
    local fatiguedUntil = _exFatiguedUntil[exType]
    if fatiguedUntil and nowMs < fatiguedUntil then
        return false
    end
    local s = _exSetStart[exType]
    if not s then return true end
    -- A snapshot from a DIFFERENT character (death/respawn) must never be
    -- judged: the new character's lower XP would read as negative gain and
    -- falsely fatigue the exercise.
    if s.who ~= player then
        _exSetStart[exType] = nil
        return true
    end
    -- Only judge sets that ran most of their duration (an interrupted set
    -- legitimately gains nothing).
    local fullSetMs = AutoPilot_Constants.EXERCISE_MINUTES * 60000
    if (nowMs - s.ms) < fullSetMs * 0.8 then return true end
    local gain = (_perkXp(player, Perks.Strength) - s.str)
               + (_perkXp(player, Perks.Fitness)  - s.fit)
    if gain < AutoPilot_Constants.EXERCISE_MIN_XP_PER_SET then
        print(string.format(
            "[Needs] %s produced %.1f XP last set — fatigued; resting it.",
            exType, gain))
        _exFatiguedUntil[exType] = nowMs
            + AutoPilot_Constants.EXERCISE_FATIGUE_RECOVERY_MS
        _exSetStart[exType] = nil
        return false
    end
    return true
end

-- Log cooldown for "waiting for endurance" to prevent spam
local exerciseWaitLogMs = 0

-- focus: "strength" | "fitness" | nil (nil = auto-balance the lower of the two)
local function doExercise(player, focus)
    -- Phase 2: day-rollover reset
    local _gameTime = GameTime.getInstance()
    local _today    = _gameTime and _gameTime:getDay() or 0
    if _today ~= _lastTrackedDay then
        _exerciseSetsToday = 0
        _lastTrackedDay    = _today
    end

    local okMs, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    nowMs = okMs and nowMs or 0

    -- V4.5: resolve the last mod-queued set (completed vs player-cancelled)
    -- BEFORE any gate, then honor the intervention backoff window.
    _updateInterventionState(player, nowMs)
    if nowMs < _backoffUntilMs then
        local minsLeft = math.ceil((_backoffUntilMs - nowMs) / 60000)
        _exerciseOutcome = "backing off (player intervened; "
            .. minsLeft .. "m left)"
        return false
    end

    -- V4.6: optional daily-cap gate.  The PRIMARY limiter is XP
    -- productivity (_exerciseStillProductive, below): training stops when an
    -- exercise stops paying XP, not at an arbitrary set count.  A cap of 0
    -- (the default) means unlimited, so this gate is skipped entirely; only
    -- a user-configured cap > 0 enforces a hard ceiling.
    local dailyCap = tonumber(AutoPilot_Constants.EXERCISE_DAILY_CAP) or 0
    if dailyCap > 0 and _exerciseSetsToday >= dailyCap then
        print(("[Needs] Daily exercise cap %d reached; resting."):format(
            dailyCap))
        _exerciseOutcome = "resting (daily set cap reached)"
        return false
    end
    -- Phase 2: endurance gate
    local _endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    if _endurance < AutoPilot_Constants.EXERCISE_ENDURANCE_MIN then
        print(("[Needs] Endurance %.2f < %.2f — skipping exercise."):format(
            _endurance, AutoPilot_Constants.EXERCISE_ENDURANCE_MIN))
        _exerciseOutcome = "resting (endurance recovering)"
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
        _exerciseOutcome = "resting (endurance recovering)"
        return false  -- no action queued; endurance recovers passively while idle
    end

    -- Once per day (strength/auto focus): fetch a dumbbell/barbell from home
    -- storage so the higher-XP equipment exercises unlock.  The fetch trip is
    -- itself this cycle's action.
    if focus ~= "fitness" and _equipFetchDay ~= _today
        and AutoPilot_Inventory.fetchExerciseEquipment
        and not AutoPilot_Inventory.hasExerciseEquipment(player) then
        _equipFetchDay = _today
        local okF, fetching = pcall(AutoPilot_Inventory.fetchExerciseEquipment, player)
        if okF and fetching then
            _exerciseOutcome = "fetching exercise equipment"
            return true
        end
    end

    local candidates = _exerciseCandidates(player, focus)
    local exType, exeData
    for _, cand in ipairs(candidates) do
        local data = FitnessExercises and FitnessExercises.exercisesType
            and FitnessExercises.exercisesType[cand] or nil
        if data and _hasExerciseItem(player, data)
            and _exerciseStillProductive(player, cand, nowMs) then
            exType, exeData = cand, data
            break
        end
    end

    if not exeData then
        print("[Needs] All exercises for focus '" .. tostring(focus or "auto")
            .. "' are XP-fatigued — pausing training while they recover.")
        _exerciseOutcome = "resting (exercises fatigued)"
        return false
    end
    print("[Needs] Exercise — focus: " .. tostring(focus or "auto")
        .. " -> " .. exType)

    -- Pre-initialize the Java Fitness object so currentExe is set before
    -- the action lifecycle starts (prevents exerciseRepeat NPE).
    pcall(function()
        local fitness = player:getFitness()
        fitness:init()
    end)

    -- 42.19 signature (shared/TimedActions/ISFitnessAction.lua:200, verified
    -- against the RUNNING game's stack trace):
    --   ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)
    -- The 5th arg feeds fitness:setCurrentExercise(exeDataType) — a String-typed
    -- Java call — so it must be the TYPE STRING, with the data table 4th.
    local ok, action = pcall(function()
        return ISFitnessAction:new(player, exType, EXERCISE_MINUTES, exeData, exeData.type)
    end)

    if ok and action then
        -- Equipment exercises: put the item in hand the same way vanilla's
        -- fitness UI does before starting (ISFitnessUI.lua:245-262) — prop
        -- "twohands" equips two-handed, "primary"/"switch" one-handed.
        if exeData.item then
            pcall(function()
                local twoHands = exeData.prop == "twohands"
                ISWorldObjectContextMenu.equip(player,
                    player:getPrimaryHandItem(), exeData.item, true, twoHands)
            end)
        end
        -- addGetUpAndThen (real 42.19 static, ISTimedActionQueue.lua:219):
        -- stands the character up from any furniture before exercising.
        -- V4.5: tag ownership BEFORE queueing, and remember the action so
        -- the intervention detector can tell a completed set from a
        -- player-cancelled one.
        AutoPilot_Utils.tagModAction(action)
        ISTimedActionQueue.addGetUpAndThen(player, action)
        _pendingSet = { action = action, exType = exType, ms = nowMs, who = player }
        -- Snapshot XP at set start so the NEXT attempt can judge whether this
        -- set actually produced XP (diminishing-returns detection).
        _exSetStart[exType] = {
            str = _perkXp(player, Perks.Strength),
            fit = _perkXp(player, Perks.Fitness),
            ms  = nowMs,
            who = player,
        }
        -- The counter keeps running even when uncapped: the F11 panel and
        -- the logs report it, it just no longer halts training on its own.
        _exerciseSetsToday = _exerciseSetsToday + 1
        _exerciseOutcome = "training: " .. exType
        if dailyCap > 0 then
            print(("[Needs] Exercise set %d/%d queued."):format(
                _exerciseSetsToday, dailyCap))
        else
            print(("[Needs] Exercise set %d queued (no daily cap)."):format(
                _exerciseSetsToday))
        end
        return true
    else
        print("[Needs] ISFitnessAction failed for: " .. exType .. " — " .. tostring(action))
        _exerciseOutcome = "error: could not start " .. tostring(exType)
        return false
    end
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Trainer status for the F11 panel.
--- Returns { outcome = "training: squats" | "resting (...)" | "idle",
---           setsToday, cap, setsLine }.
--- V4.6: `cap` is 0 when training is uncapped (XP productivity is the
--- limiter), so the panel must never print "12/0".  `setsLine` is the
--- pre-formatted, honest rendering of the count and is what the UI draws
--- verbatim (same data-layer-formats-it convention as the program line);
--- `setsToday` and `cap` stay for callers that want the raw numbers.
function AutoPilot_Needs.getExerciseStatus()
    local cap = tonumber(AutoPilot_Constants.EXERCISE_DAILY_CAP) or 0
    local setsLine
    if cap > 0 then
        setsLine = ("Sets today: %d/%d"):format(_exerciseSetsToday, cap)
    else
        setsLine = ("Sets today: %d (no cap)"):format(_exerciseSetsToday)
    end
    return {
        outcome   = _exerciseOutcome,
        setsToday = _exerciseSetsToday,
        cap       = cap,
        setsLine  = setsLine,
    }
end

-- ── Player-intervention notifications (V4.5) ────────────────────────────────
-- Called by Main; all three are argument-light so no player object is ever
-- closed over across a Lua reload (the MP stale-closure lesson).

--- Main observed a FOREIGN exercise as the running action (player-initiated
--- or vanilla-queued; identity says it is not ours).  Refreshing the
--- backoff window every observed cycle keeps training away while the
--- manual exercise runs and for one full window after it ends, so the
--- trainer never re-queues over the player's own session.
function AutoPilot_Needs.noteForeignExercise(_player)
    local ok, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if not ok or type(nowMs) ~= "number" then return end
    local windowMs = _backoffWindowMs()
    if windowMs <= 0 then return end
    _backoffUntilMs = nowMs + windowMs
    _exerciseOutcome = "waiting (manual exercise in progress)"
end

--- The MOD itself cleared its own queued exercise (urgent-need interrupt,
--- threat response, or thrash guard).  Consume the pending record so the
--- vanish is NOT misread as a player cancel (no backoff: training may
--- resume as soon as the interrupting condition is handled).
function AutoPilot_Needs.noteModExerciseCleared()
    local ps = _pendingSet
    if not ps then return end
    _pendingSet = nil
    AutoPilot_Utils.clearModAction(ps.action)
end

--- F10 panic stop: the player explicitly stopped a running exercise.
--- Consume the pending record (if the set was ours) and start the backoff
--- window immediately, so even a just-armed trainer cannot re-queue an
--- exercise right after the player asked for it to stop.
function AutoPilot_Needs.notePanicStop()
    local ps = _pendingSet
    if ps then
        _pendingSet = nil
        AutoPilot_Utils.clearModAction(ps.action)
    end
    local ok, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if not ok or type(nowMs) ~= "number" then return end
    _setBackoff(nowMs, "F10 panic stop")
end

--- Reset intervention state (tests only; mirrors Leveler.resetForTest).
function AutoPilot_Needs.resetInterventionForTest()
    if _pendingSet then
        AutoPilot_Utils.clearModAction(_pendingSet.action)
    end
    _pendingSet     = nil
    _backoffUntilMs = 0
end

--- Returns true if an urgent need should interrupt the current action (e.g. exercise).
--- Called by Main before the isPlayerDoingAction guard.
function AutoPilot_Needs.shouldInterrupt(player)
    -- Bleeding always interrupts
    if AutoPilot_Medical.hasCriticalWound(player) then return true end

    -- Thirst interrupts at threshold
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    if thirst >= AutoPilot_Constants.THIRST_THRESHOLD then return true end

    -- Hunger interrupts
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    if hunger >= AutoPilot_Constants.HUNGER_THRESHOLD then return true end

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
        AutoPilot_Telemetry.setDecision("bandage", "bleeding")
        if AutoPilot_Medical.check(player, true) then return true end
    end

    -- Sleep overrides rest cooldown — fatigue is checked before the cooldown gate
    -- so the character can transition from resting to sleeping when tired enough.
    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    if fatigue >= FATIGUE_STAT_THRESHOLD then
        AutoPilot_Telemetry.setDecision("sleep", "fatigue_thresh")
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
        AutoPilot_Telemetry.setDecision("rest", "rest_cooldown")
        return true  -- still resting, skip routine needs
    end

    -- 2. Thirst (0.0=hydrated, ~1.0=dying)
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    if thirst >= AutoPilot_Constants.THIRST_THRESHOLD then
        AutoPilot_Telemetry.setDecision("drink", "thirst_thresh")
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
            AutoPilot_Telemetry.setDecision("shelter", "weather")
            if doSeekShelter(player) then return true end
        end
    end

    -- 3. Hunger (0.0=full, ~1.0=starving)
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    if hunger >= AutoPilot_Constants.HUNGER_THRESHOLD then
        print(string.format(
            "[Needs] Hunger triggered (%.0f%%). Attempting to eat.", hunger * 100))
        AutoPilot_Telemetry.setDecision("eat", "hunger_thresh")
        local ate = doEat(player)
        if ate then return true end
        print("[Needs] doEat returned false — no food available, continuing.")
    end

    -- 4. Wounds — treat non-bleeding wounds (scratches, bites, deep wounds)
    AutoPilot_Telemetry.setDecision("bandage", "wound")
    if AutoPilot_Medical.check(player, false) then return true end

    -- Phase 4: temperature comfort check
    AutoPilot_Telemetry.setDecision("clothing", "temperature")
    if AutoPilot_Inventory.adjustClothing(player) then return true end

    -- 5. Tired — already checked above (before rest cooldown gate)

    -- 6. Exhausted — rest only when endurance is critically low (stat ≤ 30%)
    -- or the exertion moodle is severe (level 3+).  Moodle level 1-2 is mild
    -- exertion that recovers on its own; reacting to it causes a sit-stand loop.
    -- (Rest cooldown is already enforced at the top of check().)
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN or enduranceMoodle >= 3 then
        AutoPilot_Telemetry.setDecision("rest", "low_endurance")
        return doRest(player)
    end

    -- 7. Bored or Unhappy -> prefer tasty food, then read, then go outside.
    -- Kept above exercise: unhappiness slows every action (worse XP/hour) and
    -- these are quick one-shot fixes.
    -- NOTE: CharacterStat.SANITY reads HIGH when healthy, so it must not be used
    -- as a "sadness" signal (it made this branch fire nearly every idle cycle).
    -- The Unhappy moodle level is the correct low-mood source.
    local boredom     = AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM)
    local unhappyLvl  = safeMoodleLevel(player, MoodleType.Unhappy)
    if boredom >= BOREDOM_STAT_THRESHOLD
        or unhappyLvl >= AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD then
        -- Phase 3: when unhappy, prefer food that reduces boredom first
        if unhappyLvl >= AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD then
            local tastyFood, tastyCont = AutoPilot_Inventory.preferTastyFood(player)
            if tastyFood then
                AutoPilot_Telemetry.setDecision("eat", "unhappy")
                print("[Needs] Unhappy — eating tasty food: "
                    .. tostring(tastyFood:getName()))
                -- V4.9: transfer out of a bag first, then eat.
                local _, usable = AutoPilot_Utils.queueItemToMainInventory(
                    player, tastyFood, tastyCont)
                if usable then
                    AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, tastyFood, 1))
                    return true
                end
                print("[Needs] Tasty-food transfer refused: falling through to reading.")
            end
        end
        AutoPilot_Telemetry.setDecision("read", "boredom")
        if doRead(player) then return true end
        if boredom >= BOREDOM_STAT_THRESHOLD then
            AutoPilot_Telemetry.setDecision("outside", "boredom")
            local went = doGoOutside(player)
            if went then return true end
        end
    end

    -- 8. EXERCISE — the mod's primary purpose (V3.2 reorder: this sat at the
    -- bottom and proactive scavenging claimed every idle cycle, so training
    -- never ran).  Survival needs above always win; the endurance gates inside
    -- doExercise hand the cycle to the background chores below while
    -- recovering between sets.
    AutoPilot_Telemetry.setDecision("exercise", "training")
    local trained
    if AutoPilot_Leveler and AutoPilot_Leveler.check then
        trained = AutoPilot_Leveler.check(player)
    else
        trained = doExercise(player)
    end
    if trained then return true end

    -- 9. Proactive supply scavenge (rate-limited background chore)
    AutoPilot_Telemetry.setDecision("scavenge", "low_supplies")
    if doProactiveScavenge(player) then return true end

    -- V5.0: the priority chain used to end with a base-maintenance slot that
    -- ran a barricade re-check.  Barricading and woodworking left the mod's
    -- scope (an artifact of the broader auto-survival design), so the chain
    -- now ends at proactive scavenging.
    return false
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
        -- SANITY reads high when healthy; the Unhappy moodle (0-4) is the real
        -- low-mood signal. Keep the "sad" key for log-parser compatibility.
        sad      = safeMoodleLevel(player, MoodleType.Unhappy),
    }
end

--- Force a single survival action if needed.
function AutoPilot_Needs.forceSurvival(player)
    return AutoPilot_Needs.check(player)
end

--- Public seam for the auto-leveler: run one exercise set with an explicit
--- focus ("strength" | "fitness").  Honors the endurance gates and the daily
--- set cap.  Returns true when an exercise action was queued.
function AutoPilot_Needs.trainExercise(player, focus)
    return doExercise(player, focus)
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
