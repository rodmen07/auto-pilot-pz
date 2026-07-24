-- AutoPilot_Needs.lua
-- Handles survival needs and idle behaviour.
--
-- luacheck: globals getClimateManager
-- SPLITSCREEN NOTE: module-level mutable state (_activityOutcome,
-- _scavengeCooldown, _scavengeStuck, _scavengeLastTotal) is shared across
-- all local players. Splitscreen is NOT supported.
-- (Re-verified 2026-07-20 via fresh grep, fourth time this note has been
-- corrected: doExercise's own state -- _exerciseSetsToday, _pendingSet,
-- _backoffUntilMs, exerciseWaitLogMs, _runActive/_runOwner and the rest --
-- moved to AutoPilot_Exercise.lua in this session's fourth and final
-- code-health slice, joining sleepCooldownMs (AutoPilot_Sleep.lua),
-- drinkCooldownMs (AutoPilot_Consumption.lua) and restCooldownMs
-- (AutoPilot_Rest.lua) from the earlier three. This file now owns none of
-- the per-behavior state the note originally listed, only the cross-cutting
-- activity string and the scavenge chore's own state. Re-verify this list
-- with a fresh grep the next time this file's module-level locals change,
-- rather than trust it again.)
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
local OUTDOOR_SEARCH_DIST    = AutoPilot_Constants.OUTDOOR_SEARCH_DIST

--- End the current training run, if any. Delegates to AutoPilot_Exercise
--- (code-health split, 2026-07-20, fourth slice), which now owns the run
--- state. Public API kept here unchanged: AutoPilot_Leveler.lua, tests, and
--- this file's own check() still reach it as AutoPilot_Needs.endTrainingRun.
function AutoPilot_Needs.endTrainingRun()
    AutoPilot_Exercise.endTrainingRun()
end

-- ── V5.8: ONE activity string for the whole needs layer ─────────────────────
--
-- User report (with a screenshot of the running v5.7 build): the F11 panel
-- read "Status: training: burpees" at the same moment the V4.4 on-screen HUD
-- read "Action: Resting".  Both were drawn from the same module and they
-- disagreed, because this string was written ONLY by doExercise.  When the
-- chain stopped training and started resting, nothing overwrote it, so the
-- panel kept displaying the last training outcome indefinitely.
--
-- The fix is not "add a second field for resting": two fields that can
-- disagree IS the bug.  This one string is now the single answer to "what is
-- the needs layer doing", written by every path that claims the cycle -- the
-- trainer below and, since the 2026-07-20 code-health split, AutoPilot_Rest
-- across the module boundary via AutoPilot_Needs.setActivity below -- and
-- read by getExerciseStatus, which is what both the panel and the HUD
-- already call. NOTE: verified AutoPilot_Sleep does NOT call setActivity at
-- all (grepped, zero matches) -- unclear whether that is intentional or a
-- pre-existing gap; out of scope for this split, not investigated further
-- here, but worth a QA look since it is the same "two things can disagree"
-- shape the V5.8 fix above was written to close.
--
-- It is declared HERE, near the top of the file, so every later local
-- function in this module can see it as an upvalue (Lua locals are only
-- visible below their declaration). doRest itself moved out to
-- AutoPilot_Rest.lua in the same split that made this a cross-module export;
-- the positioning constraint outlived the specific function that first
-- required it.
local _activityOutcome = "idle"

local function _setActivity(text)
    _activityOutcome = text
end

--- Cross-module accessor: AutoPilot_Rest.doRest (extracted 2026-07-20) calls
--- this instead of the private local above, since it no longer lives in this
--- file. Internal call sites within this file continue to use _setActivity
--- directly, unchanged.
function AutoPilot_Needs.setActivity(text)
    _setActivity(text)
end

--- Cross-module reader counterpart to setActivity above: AutoPilot_Exercise
--- .getExerciseStatus (extracted 2026-07-20, fourth slice) reads the shared
--- activity string across the module boundary the same way AutoPilot_Rest
--- writes it.
function AutoPilot_Needs.getActivityOutcome()
    return _activityOutcome
end

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
-- doEat/doDrink/trackEmptyLootCycle moved to AutoPilot_Consumption.lua
-- (code-health split, 2026-07-20); see that file's header for why.

-- Rest on nearby furniture to recover endurance.
-- Searches for bed > sofa/couch/armchair > chair/bench/stool/pew.
-- Falls back to sitting on the ground if nothing is found.
-- findRestFurniture/restHoldFrom/doRest (and the restCooldownMs seam
-- functions) moved to AutoPilot_Rest.lua (code-health split, 2026-07-20,
-- third slice); see that file's header.
-- getBedObjectOnSquare/_findBedNearby/doSleep moved to AutoPilot_Sleep.lua
-- (code-health split, 2026-07-20, second slice); see that file's header.

--- Delegates to AutoPilot_Rest, which now owns the seating classification.
--- Public API kept here unchanged: test_priority_logic.lua and any external
--- caller still reach it as AutoPilot_Needs.seatPriorityForSprite.
function AutoPilot_Needs.seatPriorityForSprite(spriteName)
    return AutoPilot_Rest.seatPriorityForSprite(spriteName)
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
    return AutoPilot_Rest.doRest(player)
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

-- doExercise and its helpers (candidate selection, XP-fatigue tracking,
-- player-intervention backoff, daily set counter, endurance hysteresis
-- gates) moved to AutoPilot_Exercise.lua (code-health split, 2026-07-20,
-- fourth slice); see that file's header for why. The public functions below
-- are kept here as one-line delegations so every existing external caller
-- (AutoPilot_Main.lua, AutoPilot_UI.lua, AutoPilot_Leveler.lua, tests) keeps
-- reaching them as AutoPilot_Needs.*, unchanged, the same pattern already
-- used for seatPriorityForSprite (AutoPilot_Rest) above.
-- ── Public API ──────────────────────────────────────────────────────────────

function AutoPilot_Needs.getExerciseStatus()
    return AutoPilot_Exercise.getExerciseStatus()
end

function AutoPilot_Needs.noteForeignExercise(player)
    return AutoPilot_Exercise.noteForeignExercise(player)
end

function AutoPilot_Needs.noteModExerciseCleared()
    return AutoPilot_Exercise.noteModExerciseCleared()
end

function AutoPilot_Needs.notePanicStop()
    return AutoPilot_Exercise.notePanicStop()
end

function AutoPilot_Needs.resetInterventionForTest()
    return AutoPilot_Exercise.resetInterventionForTest()
end

function AutoPilot_Needs.syncSetsCounterForTest(player)
    return AutoPilot_Exercise.syncSetsCounterForTest(player)
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
    -- V5.7: keep the daily set counter honest about WHO it belongs to before
    -- anything can return early.  doExercise syncs too, but it is at the
    -- bottom of the chain and a new character with an urgent need would show
    -- the dead character's set total in the F11 panel until they got there.
    -- Cross-module call: the counter moved to AutoPilot_Exercise (code-health
    -- split, 2026-07-20, fourth slice).
    AutoPilot_Exercise.syncSetsCounter(player)

    -- 1. Bleeding — treat immediately (fatal if untreated)
    if AutoPilot_Medical.hasCriticalWound(player) then
        AutoPilot_Telemetry.setDecision("bandage", "bleeding")
        if AutoPilot_Medical.check(player, true) then return true end
    end

    -- Sleep overrides rest cooldown — fatigue is checked before the cooldown gate
    -- so the character can transition from resting to sleeping when tired enough.
    -- The sleep branch is TERMINAL only when the engine will actually allow sleep:
    -- canSleepNow mirrors the engine's pain/panic gate, so a sore character (PAIN
    -- moodle >= 2 while fatigue <= 0.85) no longer monopolises the decision with a
    -- sleep the engine silently refuses ("too much pain to sleep").  When blocked,
    -- record why (fail_reason), try a one-shot pain remedy, then FALL THROUGH so
    -- thirst, hunger, wound care and rest still run instead of idling.
    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    if fatigue >= FATIGUE_STAT_THRESHOLD then
        local canSleep, blockReason = AutoPilot_Sleep.canSleepNow(player)
        if canSleep then
            AutoPilot_Telemetry.setDecision("sleep", "fatigue_thresh")
            return AutoPilot_Sleep.doSleep(player)
        end
        AutoPilot_Telemetry.setDecision("sleep", "fatigue_thresh", nil, nil, blockReason)
        if blockReason == "pain_block" and AutoPilot_Sleep.relievePain(player) then
            return true
        end
        -- fall through: address lower needs instead of idling on a blocked sleep
    end

    -- 2. Thirst (0.0=hydrated, ~1.0=dying)
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    if thirst >= AutoPilot_Constants.THIRST_THRESHOLD then
        AutoPilot_Telemetry.setDecision("drink", "thirst_thresh")
        return AutoPilot_Consumption.doDrink(player)
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
        local ate = AutoPilot_Consumption.doEat(player)
        if ate then return true end
        print("[Needs] doEat returned false — no food available, continuing.")
    end

    -- 4. Wounds — treat non-bleeding wounds (scratches, bites, deep wounds)
    AutoPilot_Telemetry.setDecision("bandage", "wound")
    if AutoPilot_Medical.check(player, false) then return true end

    -- Phase 4: temperature comfort check
    AutoPilot_Telemetry.setDecision("clothing", "temperature")
    if AutoPilot_Inventory.adjustClothing(player) then return true end

    -- 5. Tired: already checked above (fatigue -> sleep)

    -- 6. Exhausted: rest when endurance is critically low (stat ≤ 30%) or the
    -- exertion moodle is severe (level 3+).  This is the path that may walk to
    -- a bed and hand off to sleep; V5.4 left it untouched.
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN or enduranceMoodle >= 3 then
        AutoPilot_Telemetry.setDecision("rest", "low_endurance")
        return AutoPilot_Rest.doRest(player)
    end

    -- 6b. V5.4: hold an in-progress rest so the character actually stays
    -- seated.  This gate used to sit at the TOP of check() where it outranked
    -- thirst, hunger and wounds; that was safe only because the hold was a
    -- single game minute.  Now that a rest lasts until endurance recovers, the
    -- gate lives HERE, below every real survival need, so drinking, eating and
    -- wound care still preempt it (threat is handled by Main before check()
    -- runs at all).  The hold releases the moment endurance reaches
    -- ENDURANCE_REST_TARGET, so it is a recovery condition, not a timer.
    local okNow, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if okNow and AutoPilot_Rest.isRestHoldActive(nowMs) then
        local restTarget = tonumber(AutoPilot_Constants.ENDURANCE_REST_TARGET) or 0
        if endurance < restTarget then
            AutoPilot_Telemetry.setDecision("rest", "rest_cooldown")
            -- V5.8: the cycle is a rest, so the reported activity says rest.
            -- This branch queues nothing, which is exactly why it used to
            -- leave the panel showing the last training outcome.
            _setActivity("resting (recovering endurance)")
            return true  -- still resting; keep recovering
        end
        -- Recovered ahead of the maximum hold: stand up and resume the chain.
        AutoPilot_Rest.clearRestHold()
        print(string.format(
            "[Needs] Endurance recovered to %.0f%%; ending rest.", endurance * 100))
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

    -- 7b. V5.4: SIT TO RECOVER, closing the endurance dead zone.
    -- Training is gated at the exercise endurance minimum and the critical
    -- rest above at ENDURANCE_REST_MIN (30%).  Between those two numbers the old
    -- chain did neither: doExercise returned false with the comment "no action
    -- queued; endurance recovers passively while idle", and the cycle fell
    -- through to scavenging or to nothing.  A live run log showed the result:
    -- ZERO rest actions in ~16,000 ticks, idle streaks of 403 / 118 / 116 /
    -- 115 ticks logged as reason=no_action, and an observed endurance floor of
    -- 40% that never reached the 30% gate.  Sitting down recovers endurance
    -- far faster than standing idle, so the band is now spent recovering.
    -- Placed BELOW every survival and wellness need and ABOVE exercise: it
    -- replaces the idle that the exercise endurance gate was producing, and
    -- yields to anything more urgent.  sitOnly=true keeps beds (and therefore
    -- sleep) out of this path.
    --
    -- V5.7: the sit threshold is RUN-AWARE, and that is what keeps the dead
    -- zone shut under hysteresis.  The dead zone is not a property of any one
    -- number: it is the band between "will not sit" and "will not train", so
    -- it opens wherever those two disagree.
    --
    --   MID-RUN: sit only near the floor (ENDURANCE_SIT_MIN, 0.35).  Training
    --     is still allowed all the way down to EXERCISE_ENDURANCE_MIN (0.30),
    --     and sitting at 80% would cut short exactly the long productive run
    --     the hysteresis exists to produce.  The small gap above the floor is
    --     deliberate: the character goes and sits down rather than first
    --     dipping under the floor and ending the run on the stat.
    --
    --   NOT MID-RUN: sit all the way up to the RESUME gate.  A character who
    --     is not training and is below the resume gate has nothing else to
    --     do; standing there idle is strictly worse than sitting, which
    --     recovers endurance faster and moves it toward
    --     ENDURANCE_REST_TARGET.  This is the branch that catches the whole
    --     band the old single-gate code left idle, including a rest that hit
    --     its maximum hold before endurance recovered.
    --
    -- Because the not-mid-run threshold IS the resume gate, there is no value
    -- of endurance at which the character neither sits nor trains, for ANY
    -- combination of these sliders.
    local sitMin = tonumber(AutoPilot_Constants.ENDURANCE_SIT_MIN) or 0.35
    if not AutoPilot_Exercise.isInTrainingRun(player) then
        sitMin = math.max(sitMin, AutoPilot_Exercise.enduranceResumeGate())
    end
    if endurance < sitMin then
        -- Sitting down is the end of any run that was still nominally open.
        AutoPilot_Needs.endTrainingRun()
        AutoPilot_Telemetry.setDecision("rest", "sit_recover")
        print(string.format(
            "[Needs] Endurance %.0f%% below sit threshold %.0f%%; sitting to recover.",
            endurance * 100, sitMin * 100))
        if AutoPilot_Rest.doRest(player, true) then return true end
        -- Could not sit at all (no furniture, no ground square): fall through
        -- rather than burn the cycle.
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
        trained = AutoPilot_Exercise.doExercise(player)
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

--- Return how many consecutive empty loot cycles have accumulated (Phase 3).
--- Delegates to AutoPilot_Consumption, which now owns the counter.
function AutoPilot_Needs.getEmptyLootCycles()
    return AutoPilot_Consumption.getEmptyLootCycles()
end

--- Return how many exercise sets have been performed today.
--- Delegates to AutoPilot_Exercise, which now owns the counter.
function AutoPilot_Needs.getExerciseSetsToday()
    return AutoPilot_Exercise.getExerciseSetsToday()
end

--- Return preferred exercise type based on STR vs FIT perk level.
--- Returns "strength", "fitness", or "either". Delegates to AutoPilot_Exercise.
function AutoPilot_Needs.preferredExerciseType(player)
    return AutoPilot_Exercise.preferredExerciseType(player)
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
    return AutoPilot_Exercise.doExercise(player, focus)
end

function AutoPilot_Needs.forceEat(player)
    return AutoPilot_Consumption.doEat(player)
end

function AutoPilot_Needs.forceDrink(player)
    return AutoPilot_Consumption.doDrink(player)
end

function AutoPilot_Needs.forceSleep(player)
    return AutoPilot_Sleep.doSleep(player)
end

--- @param sitOnly  V5.4: true to skip beds (sit-to-recover semantics).
function AutoPilot_Needs.forceRest(player, sitOnly)
    return AutoPilot_Rest.doRest(player, sitOnly)
end

function AutoPilot_Needs.forceExercise(player)
    return AutoPilot_Exercise.doExercise(player)
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
