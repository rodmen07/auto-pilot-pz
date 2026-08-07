-- tests/test_status_honesty.lua
-- V5.8 seat-and-status suite: resting must actually SIT DOWN, and the F11
-- panel status must agree with the on-screen action HUD instead of leaving a
-- stale "training: <exercise>" line under a "Resting" HUD (V5.8-1..7).
--
-- Moved VERBATIM out of tests/test_priority_logic.lua (code-health split,
-- 2026-08-07, third slice; the V5.7 block moved first, then the V5.4 rest
-- band): that file was still 1,927 lines after two slices.  Test bodies are
-- unchanged; only this header, and the bootstrap/helpers each standalone
-- suite carries by repo convention (mock loads, stubs, mini-framework, the
-- furniture kit, and drivenPlayer/repAt), are copied alongside.
--
-- drivenPlayer/repAt came ACROSS rather than staying behind: after this move
-- the V5.8 cases are their only callers in the source file (grep over the
-- whole of test_priority_logic.lua: definitions plus five call sites, all
-- inside this block).
--
-- The MockTime.advance that preceded this block in the source file did NOT
-- come with it, and does not need to: it existed to clear the XP fatigue the
-- V5.2 auto-rotation cases left on the fitness pool, and a standalone suite
-- bootstraps with no prior training state at all (same reason slices 1 and 2
-- needed none).
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_status_honesty.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants (no PZ deps; 'C' sorts first so safe to load stand-alone) ─
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Stub dependency modules ───────────────────────────────────────────────────
-- These modules are used by AutoPilot_Needs.lua. We replace them with minimal
-- stubs that the tests can reconfigure per case.

-- V4.9: Needs moves an item out of a sub-container before using it.
ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}

-- Internal state flag; tests flip _bleeding to simulate wounds.
AutoPilot_Medical = {
    _bleeding = false,

    hasCriticalWound = function(player)
        return AutoPilot_Medical._bleeding
    end,

    check = function(player, _bleedingOnly)
        if AutoPilot_Medical._bleeding then
            -- Mirror the real module's side-effect: queue a bandage action.
            table.insert(ISTimedActionQueue_calls, { type = "bandage" })
            return true
        end
        return false
    end,
}

-- Inventory stubs — tests override individual functions per case.
AutoPilot_Inventory = {
    findWaterSource       = function(_player) return nil end,
    getBestDrink          = function(_player) return nil end,
    lootNearbyDrink       = function(_player) return false end,
    supplyRunLoot         = function(_player, _pred) end,
    getBestFoodForHunger  = function(_player, _hunger) return nil end,
    selectFoodByWeight    = function(_player) return nil end,
    getBestFood           = function(_player) return nil end,
    lootNearbyFood        = function(_player) return false end,
    getReadable           = function(_player) return nil end,
    lootNearbyReadable    = function(_player) return false end,
    adjustClothing        = function(_player) return false end,
    preferTastyFood       = function(_player) return nil end,
    refillWaterContainer  = function(_player, _src) end,
    drinkFromSource       = function(_player, _src) return true end,
    equipBestExerciseItem = function(_player) return "none" end,
}

-- Real Utils (V4.5: the intervention detector and the ownership registry
-- under test live there); square iteration is a no-op in tests (getCell()
-- returns a stub whose squares are all nil).
dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.iterateNearbySquares = function(_cx, _cy, _cz, _radius, _callback) end

AutoPilot_Home = {
    isSet        = function(_player) return false end,
    isInside     = function(_sq)     return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

-- Real Consumption (doEat/doDrink moved here in the 2026-07-20 code-health
-- split; AutoPilot_Needs.check/forceEat/forceDrink now call into it).
dofile("42/media/lua/client/AutoPilot_Consumption.lua")

-- Real Sleep (doSleep moved here in the same split's second slice;
-- AutoPilot_Needs.check/forceSleep now call into it).
dofile("42/media/lua/client/AutoPilot_Sleep.lua")

-- Real Rest (doRest moved here in the same split's third slice, after a
-- prior increment gave restCooldownMs a seam so check()'s V5.4 rest-hold
-- gate could call across the module boundary; AutoPilot_Needs.check/
-- forceRest/seatPriorityForSprite now call into it).
dofile("42/media/lua/client/AutoPilot_Rest.lua")

-- AutoPilot_Exercise.lua: doExercise and the trainer state (code-health
-- split, 2026-07-20, fourth slice). Unlike doRest, no separate seam PR was
-- needed -- check()'s three touch points (syncSetsCounter, isInTrainingRun,
-- enduranceResumeGate) were already named functions before the move, not
-- bare variable reads.
dofile("42/media/lua/client/AutoPilot_Exercise.lua")

-- ── Load the module under test ────────────────────────────────────────────────
-- Loader plumbing only (code-health split, 2026-08-01): doMoodRelief and its
-- two private arms moved out of AutoPilot_Needs into AutoPilot_Mood.  No test
-- case, stub or assertion below changed.
dofile("42/media/lua/client/AutoPilot_Mood.lua")
dofile("42/media/lua/client/AutoPilot_Needs.lua")

-- ── Minimal test framework ────────────────────────────────────────────────────
local PASS = 0
local FAIL = 0

local function assert_eq(desc, got, expected)
    if got == expected then
        print(("  PASS  %s"):format(desc))
        PASS = PASS + 1
    else
        io.stderr:write(("  FAIL  %s  (got=%s, expected=%s)\n"):format(
            desc, tostring(got), tostring(expected)))
        FAIL = FAIL + 1
    end
end

local function assert_true(desc, val)
    assert_eq(desc, not not val, true)
end

local function assert_false(desc, val)
    assert_eq(desc, not not val, false)
end

-- Reset shared state between test cases.
local function reset()
    ISTimedActionQueue_calls = {}
    AutoPilot_Medical._bleeding = false
    -- Advance the mock clock well past any active cooldowns (rest: 60 s,
    -- sleep: 15 s) so a stale cooldownMs from a previous test cannot block
    -- the next one.  restCooldownMs / sleepCooldownMs are locals in
    -- AutoPilot_Needs.lua; they are bounded by the mock clock value.
    MockTime.advance(120000)
    -- Restore inventory stubs that individual tests may have replaced.
    AutoPilot_Inventory.findWaterSource    = function(_player) return nil end
    AutoPilot_Inventory.getBestDrink       = function(_player) return nil end
    AutoPilot_Inventory.lootNearbyDrink    = function(_player) return false end
    AutoPilot_Inventory.getBestFoodForHunger = function(_player, _hunger) return nil end
    AutoPilot_Inventory.selectFoodByWeight = function(_player) return nil end
    AutoPilot_Inventory.getBestFood        = function(_player) return nil end
    AutoPilot_Inventory.lootNearbyFood     = function(_player) return false end
    AutoPilot_Inventory.bodyTemperature    = function(_player) return 0 end
end

local function makeArray(items)
    return {
        size = function(self) return #items end,
        get = function(self, i) return items[i + 1] end,
    }
end

-- Return the action-type string of the last item queued, or nil.
local function last_action_type()
    local c = ISTimedActionQueue_calls
    if #c == 0 then return nil end
    return c[#c].type
end

-- ── Furniture / endurance helper kit ──────────────────────────────────────────
-- Copied from tests/test_priority_logic.lua with the block (repo convention:
-- every standalone suite carries its own helpers).  noFurniture, resetRest,
-- mockFurniture and placeFurniture stay in BOTH files -- the source file's
-- un-versioned tail still calls them.
-- Restore the suite's default no-op iteration after a furniture case.
local function noFurniture()
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, _callback) end
end

-- Clear any rest hold left by an earlier case.  reset() only advances two
-- game minutes, which no longer clears the V5.4 hold.
local function resetRest()
    reset()
    MockTime.advance((AutoPilot_Constants.REST_HOLD_MS or 60000) + 60000)
    noFurniture()
    AutoPilot_Home.isInside = function(_sq) return false end
end

-- A world object whose sprite carries a name and, optionally, the bed flag.
local function mockFurniture(spriteName, isBed, sq, seatData)
    local sprite = {
        getName = function(_self) return spriteName end,
        getProperties = function(_self)
            return {
                has = function(_p, flag)
                    return isBed == true and flag == IsoFlagType.bed
                end,
            }
        end,
    }
    return {
        getSprite = function(_self) return sprite end,
        getSquare = function(_self) return sq end,
        -- SeatingManager sit-position count (see the SeatingManager mock).
        -- Default 1 (sittable); a test passes seatData=false for a dining chair
        -- the engine has no sit data for, so the character would rest standing.
        _seatData = (seatData == false) and 0 or 1,
    }
end

-- Publish one square holding the named furniture at offset (dx, dy).
local function placeFurniture(specs)
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, cb)
            for _, spec in ipairs(specs) do
                local sq = {}
                local obj = mockFurniture(spec.sprite, spec.bed, sq, spec.seatData)
                sq.getObjects = function(_self) return makeArray({ obj }) end
                sq.getX = function(_self) return spec.dx or 0 end
                sq.getY = function(_self) return spec.dy or 0 end
                sq.getZ = function(_self) return 0 end
                sq.isOutside = function(_self) return false end
                if cb(sq, spec.dx or 0, spec.dy or 0) then return end
            end
        end
end

-- V5.7: ONE character whose endurance can be driven up and down.
--
-- A training run belongs to a player OBJECT (same ownership rule as the V4.5
-- `who` guards), so a test that builds a fresh MockPlayer for every endurance
-- level is testing a fresh CHARACTER every time and can never observe a run
-- continuing.  MockPlayer closes over the stats table it is given, so writing
-- through that table moves the live stat.
local function drivenPlayer(endurance, moodle)
    local stats = { HUNGER = 0.02, THIRST = 0.02, FATIGUE = 0.02,
                    ENDURANCE = endurance }
    local p = MockPlayer.new({
        stats   = stats,
        moodles = { ENDURANCE = moodle or 0, UNHAPPY = 0 },
    })
    p.setEndurance = function(_self, e) stats.ENDURANCE = e end
    return p
end

-- One COMPLETED, productive set at a given endurance, on the same character:
-- the shape of a real training run.  Advancing a full set length matters for
-- two reasons beyond realism -- an instant re-queue reads as a player cancel
-- (V4.5) and would trigger the backoff, and a set that gains no XP reads as
-- diminishing returns (V3.2) and would fatigue the exercise.
local function repAt(p, endurance)
    MockTime.advance(AutoPilot_Constants.EXERCISE_MINUTES * 60000)
    p._xp.Fitness = (p._xp.Fitness or 0) + 12
    p:setEndurance(endurance)
    return AutoPilot_Needs.trainExercise(p, "fitness")
end

-- A character whose only problem is endurance.
local function windedPlayer(endurance, moodle)
    return MockPlayer.new({
        stats = {
            HUNGER    = 0.02,
            THIRST    = 0.02,
            FATIGUE   = 0.02,
            ENDURANCE = endurance,
        },
        moodles = { ENDURANCE = moodle or 0, UNHAPPY = 0 },
    })
end

-- ── Test cases ────────────────────────────────────────────────────────────────
print("=== AutoPilot_Needs V5.8 Seat-and-Status Tests ===")

-- ── V5.8: actually sit down, and report one honest status ────────────────────
-- User report, with a screenshot of the running v5.7 build: "Text says
-- resting, but character is not sitting in the chair as expected".  The panel
-- read "Status: training: burpees", the on-screen HUD read "Action: Resting",
-- and the character was standing beside an empty chair.

print("\n-- Test V5.8-1 (HEADLINE): resting on furniture queues the SEAT action")
do
    resetRest()
    placeFurniture({ { sprite = "furniture_seating_indoor_chair_04", dx = 1, dy = 0 } })
    local player = windedPlayer(0.40)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(player))

    local queued = ISTimedActionQueue_calls
    assert_eq("exactly ONE action is queued for a furniture rest", #queued, 1)
    assert_eq("and it is the seat action, which walks there AND sits down",
        queued[1].type, "sit_furniture")
    assert_eq("the seat action was handed the chair that was found",
        queued[1].target:getSprite():getName(),
        "furniture_seating_indoor_chair_04")

    -- V6: the seat path's onComplete chains ISRestAction, which is what actually
    -- SEATS the character (mirrors the engine's onRestPathFound).  V5.8 dropped
    -- this chaser and seated nothing; fire the onComplete and prove it is bound.
    local sitAction = queued[1]
    assert_true("the seat action has an onComplete chaser bound",
        sitAction.onComplete ~= nil)
    sitAction.onComplete.fn(sitAction.onComplete.args[1], sitAction.onComplete.args[2])
    local after = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_eq("firing it queues the ISRestAction that seats the character",
        after.type, "rest_furniture")
    assert_eq("seated on the furniture the pathfinder resolved",
        after.target:getSprite():getName(), "furniture_seating_indoor_chair_04")
    assert_eq("with useAnimations = true so the sit-down animation plays",
        after.useAnimations, true)
    noFurniture()
end

print("\n-- Test V5.8-2: with no seat pathfinder available, rest falls to the ground")
do
    resetRest()
    placeFurniture({ { sprite = "furniture_seating_indoor_sofa_01", dx = 1, dy = 0 } })
    -- Take the seat action away.  There is no ISRestAction "fallback" any more
    -- (resting always goes through the pathfind+seat chain, mirroring the engine),
    -- so the guaranteed safe floor is the ground-sit.
    local savedPath = ISPathFindAction.pathToSitOnFurniture
    ISPathFindAction.pathToSitOnFurniture = nil
    local player = windedPlayer(0.40)
    assert_true("check() still claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("the ground-sit is the fallback when the seat pathfinder is gone",
        last_action_type(), "rest")
    ISPathFindAction.pathToSitOnFurniture = savedPath
    noFurniture()
end

print("\n-- Test V5.8-3 (HEADLINE): the panel status agrees with the action HUD")
do
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    -- Reproduce the screenshot exactly: train first, so the trainer's own
    -- outcome string is "training: <something>", THEN drop into the rest.
    local p = drivenPlayer(0.95)
    assert_true("(a set is queued first)",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("the trainer status reads as training",
        AutoPilot_Needs.getExerciseStatus().outcome:sub(1, 9), "training:")

    resetRest()
    placeFurniture({ { sprite = "furniture_seating_indoor_chair_04", dx = 1, dy = 0 } })
    AutoPilot_Needs.endTrainingRun()
    local winded = windedPlayer(0.40)
    assert_true("the winded cycle rests", AutoPilot_Needs.check(winded))
    assert_eq("the cycle queued the seat action", last_action_type(), "sit_furniture")

    local outcome = AutoPilot_Needs.getExerciseStatus().outcome
    -- The V4.4 HUD renders ACTION_LABELS["rest"] = "Resting" for this cycle.
    -- The panel must not be saying "training: burpees" underneath it.
    assert_eq("the panel status now says resting too", outcome:sub(1, 7), "resting")
    assert_eq("and it is NOT the stale training line", outcome:find("training", 1, true), nil)
    noFurniture()
end

print("\n-- Test V5.8-4: a training cycle still reports the exercise by name")
do
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    local p = drivenPlayer(1.00)
    assert_true("(a set is queued)", AutoPilot_Needs.trainExercise(p, "fitness"))
    local outcome = AutoPilot_Needs.getExerciseStatus().outcome
    assert_eq("the status still names the exercise being trained",
        outcome:sub(1, 10), "training: ")
    -- The panel's regularity row keys off exactly this shape.
    assert_true("the exercise name is still parseable from the status",
        outcome:match("^training: (%S+)") ~= nil)
end

print("\n-- Test V5.8-5: the ground fallback still fires, and reports honestly")
do
    resetRest()
    AutoPilot_Needs.endTrainingRun()
    -- No furniture anywhere: the V5.4 guaranteed floor is untouched.
    local player = windedPlayer(0.40)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("ISSitOnGround is still what gets queued", last_action_type(), "rest")
    assert_eq("exactly one action is queued", #ISTimedActionQueue_calls, 1)
    local outcome = AutoPilot_Needs.getExerciseStatus().outcome
    assert_eq("and the status says resting, not training",
        outcome:sub(1, 7), "resting")
end

print("\n-- Test V5.8-6: the rest HOLD cycle reports resting even though it queues nothing")
do
    resetRest()
    AutoPilot_Needs.endTrainingRun()
    local player = windedPlayer(0.40)
    assert_true("the first cycle sits down", AutoPilot_Needs.check(player))
    local queuedAfterSit = #ISTimedActionQueue_calls
    -- Second cycle, still inside REST_HOLD_MS: doRest short-circuits and the
    -- hold branch in check() claims the cycle without queueing anything.
    -- That is the branch that used to leave the panel on the training line.
    assert_true("the hold keeps claiming the cycle", AutoPilot_Needs.check(player))
    assert_eq("nothing new was queued during the hold",
        #ISTimedActionQueue_calls, queuedAfterSit)
    assert_eq("the held cycle still reports resting",
        AutoPilot_Needs.getExerciseStatus().outcome:sub(1, 7), "resting")
end

print("\n-- Test V5.8-7: the endurance hysteresis SHAPE is untouched")
do
    -- A run started at full endurance must still continue well below the
    -- resume gate and above the 0.30 floor: the exact property V5.7 exists to
    -- provide.  V6.1-1 moved the two upper NUMBERS (resume 0.90 -> 0.75,
    -- stand-up target 0.95 -> 0.80) on the user's 2026-08-01 decision, so the
    -- probe endurances below are derived from the gate instead of written as
    -- literals -- the shape, not the value, is what this case guards.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    local gate  = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    local floor = AutoPilot_Constants.EXERCISE_ENDURANCE_MIN
    local belowGate = (gate + floor) / 2   -- comfortably inside the run band
    local p = drivenPlayer(0.95)
    assert_true("a run starts at 95%", AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_true(("and it continues at %.0f%%, below the resume gate")
        :format(belowGate * 100), repAt(p, belowGate))
    assert_eq("the resume gate is the V6.1-1 default",
        AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME, 0.75)
    assert_eq("the floor is unchanged",
        AutoPilot_Constants.EXERCISE_ENDURANCE_MIN, 0.30)
    assert_eq("the sit threshold is unchanged",
        AutoPilot_Constants.ENDURANCE_SIT_MIN, 0.35)
    assert_eq("the stand-up target is the V6.1-1 default",
        AutoPilot_Constants.ENDURANCE_REST_TARGET, 0.80)
    -- A fresh character with no run open still has to clear the resume gate.
    AutoPilot_Needs.endTrainingRun()
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    assert_false(("with no run open, %.0f%% does NOT start one")
        :format(belowGate * 100),
        AutoPilot_Needs.trainExercise(drivenPlayer(belowGate), "fitness"))
    resetRest()
    AutoPilot_Needs.endTrainingRun()
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
