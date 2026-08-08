-- tests/test_exercise_trainer.lua
-- The exercise TRAINER: the three blocks that decide whether a set is worth
-- doing, whether the mod is allowed to start one, and when it must stop.
--
--   * V3.2 XP-fatigue detection -- PZ silently drops a repeated exercise's XP
--     to ~zero, so the mod measures the XP a completed set produced and
--     rotates to the next exercise, or pauses the pool (Tests 24-29).
--   * V4.5 intervention backoff + mod-action ownership -- the mod must never
--     judge or cancel an action it did not queue, an observed FOREIGN exercise
--     holds training off, and F10 engages the backoff immediately
--     (Tests 30-37).
--   * V4.6 the daily set cap is an opt-in ceiling -- XP gain is the limiter,
--     cap 0 means unlimited, a cap > 0 stays available as a safety valve, and
--     getExerciseStatus reports honestly in both modes (Tests 38-41).
--
-- Moved VERBATIM out of tests/test_priority_logic.lua (code-health split,
-- 2026-08-08, SIXTH slice; the V5.7 trainer-state block moved in PR #115, the
-- V5.4 rest band in PR #116, the V5.8 seat-and-status block in PR #118, the
-- 2026-07-24 smoke-test regressions in PR #125 and the V5.2 auto-day rotation
-- in PR #127).  That file was still 1,404 lines after five slices, over the
-- 1000-line hard threshold preflight C10 flags; this slice is the one that
-- puts it under.  Test bodies, stubs and assertions are unchanged; only this
-- header and the bootstrap each standalone suite carries by repo convention
-- (mock loads, module stubs, mini-framework) are copied alongside.
--
-- WHY THIS SEAM, and where the handed-over mapping was RIGHT and where it was
-- WRONG.  Slice 5's header and the backlog both prescribed this cut ("the next
-- natural seam is the whole exercise family (V3.2 + V4.5 + V4.6) with
-- count_action_type left behind for V4.9 ... one shared 4-line helper
-- duplicated").  The prescription was re-derived here before anything moved
-- rather than taken on trust, and the re-derivation split two ways:
--
--   * CONFIRMED, the part that mattered: exercisePlayer is defined at line 678
--     inside V3.2 and its 15 call sites (690, 708, 722, 745, 816, 838, 858,
--     876, 895, 932, 938, 953, 981, 1011, 1047) are ALL inside the family, so
--     the three blocks move together and the kit goes with them.  productiveSet
--     (969) has exactly two callers (991, 1016), both inside V4.6.  FULL_SET_MS
--     (676) has ten callers, all inside.  Nothing in the family is reachable
--     from the file it leaves.
--   * FALSIFIED: NO helper is duplicated by this slice.  count_action_type is
--     not "defined inside V4.6" -- it is defined at line 1093, BELOW the cut,
--     under the V4.7 comment block that explains why it exists, and its five
--     call sites (1118, 1160, 1237, 1275, 1276) are all below the cut too.  It
--     is not moved, not copied, and not referenced from here.  The predicted
--     duplication cost of this seam was zero.
--
-- The one piece of shared STATE the cut carries is
-- AutoPilot_Constants.EXERCISE_DAILY_CAP = 0, set at line 809 in the V4.5
-- header and restored to 0 at the end of every V4.6 case that changes it.  It
-- leaves with the family, which is safe in both directions and was checked
-- rather than assumed: 42/media/lua/client/AutoPilot_Constants.lua:389 already
-- declares the same value, so the cases below the cut in the source file see
-- an identical cap with the line gone, and the suite totals prove it (see the
-- PR body: 146 + 39 = 185 = the pre-split baseline, 0 failures either side).
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_exercise_trainer.lua

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

-- ── Exercise XP-fatigue detection (V3.2) ─────────────────────────────────────
-- PZ silently drops a repeated exercise's XP to ~zero; the mod detects that
-- by measuring the XP a completed set produced and rotates / pauses.

local FULL_SET_MS = AutoPilot_Constants.EXERCISE_MINUTES * 60000

local function exercisePlayer()
    return MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                    ENDURANCE = 0.90 },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
    })
end

print("\n-- Test 24: productive exercise keeps repeating")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)   -- fresh window, clears prior fatigue
    local p = exercisePlayer()
    assert_true("first fitness set queues",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("fitness focus starts with squats",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "squats")

    MockTime.advance(FULL_SET_MS)       -- full set elapsed...
    p._xp.Fitness = (p._xp.Fitness or 0) + 12   -- ...and it produced XP
    assert_true("productive set repeats",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("still squats while productive",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "squats")
end

print("\n-- Test 25: zero-XP set rotates to the next exercise in the pool")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    local p = exercisePlayer()
    assert_true("squat set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    MockTime.advance(FULL_SET_MS)
    -- no XP gained -> squats fatigued -> sit-ups take over
    assert_true("fatigued squats fall back to sit-ups",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("second set is situp",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "situp")
end

print("\n-- Test 26: single-exercise pool pauses training when fatigued")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    local p = exercisePlayer()
    assert_true("push-up set queues", AutoPilot_Needs.trainExercise(p, "strength"))
    MockTime.advance(FULL_SET_MS)
    local before = #ISTimedActionQueue_calls
    assert_false("zero-XP push-ups pause strength training",
        AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("nothing queued while paused", #ISTimedActionQueue_calls, before)

    -- After the recovery window the exercise is retried.
    MockTime.advance(AutoPilot_Constants.EXERCISE_FATIGUE_RECOVERY_MS + 60000)
    assert_true("push-ups retried after recovery window",
        AutoPilot_Needs.trainExercise(p, "strength"))
end

print("\n-- Test 27: a player-cancelled set backs off and is not judged as fatigue")
do
    -- V4.5 semantics: a mod-queued set that vanishes from the queue well
    -- short of a full set, without the mod clearing it itself, is a PLAYER
    -- CANCEL.  Training must back off (never bulldoze the cancel), and the
    -- aborted set must not be judged as XP-fatigue.
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    assert_true("set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))   -- cancelled early
    local before = #ISTimedActionQueue_calls
    assert_false("cancelled set does NOT requeue immediately (backoff)",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("nothing queued during the backoff window",
        #ISTimedActionQueue_calls, before)
    assert_true("panel status reports the backoff",
        AutoPilot_Needs.getExerciseStatus().outcome:find("backing off", 1, true)
            ~= nil)
    -- Backoff holds mid-window...
    MockTime.advance(math.floor(
        AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES * 60000 / 2))
    assert_false("backoff still holds halfway through the window",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    -- ...then releases, and the cancelled set was NOT marked XP-fatigued:
    -- squats queue again instead of rotating to sit-ups.
    MockTime.advance(math.floor(
        AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES * 60000 / 2) + 60000)
    assert_true("training resumes after the backoff window",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("still squats (cancel was not judged as XP-fatigue)",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "squats")
end

print("\n-- Test 28: equipment exercises lead the strength pool when gear is carried")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    local p = MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                    ENDURANCE = 0.90 },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
        hasItems = true,   -- inventory:contains(...) reports gear carried
    })
    assert_true("strength set queues with gear",
        AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("dumbbell press picked over push-ups (1.8x exercise)",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType,
        "dumbbellpress")
end

print("\n-- Test 29: without gear the strength pool falls back to push-ups")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    local p = MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                    ENDURANCE = 0.90 },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
        hasItems = false,
    })
    assert_true("strength set queues without gear",
        AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("push-ups picked when no equipment is carried",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "pushups")
end

-- ── V4.5: intervention backoff + mod-action ownership lifecycle ──────────────
-- The mock's in-game day never rolls over, so _exerciseSetsToday accumulates
-- across the whole suite.  V4.6 made 0 (unlimited) the default, so the
-- daily-count gate cannot shadow what these tests assert; pin it anyway so
-- the intent survives a future default change.
AutoPilot_Constants.EXERCISE_DAILY_CAP = 0

print("\n-- Test 30: mod-queued sets are tagged; consuming the record untags")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    assert_true("set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local action = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_true("queued exercise is tagged as mod-owned",
        AutoPilot_Utils.isModAction(action))
    assert_false("an arbitrary foreign action is NOT mod-owned",
        AutoPilot_Utils.isModAction({ Type = "ISFitnessAction" }))
    -- The set vanishes early (mock queue reads empty): the detector consumes
    -- the record, untags the action, and engages the backoff.
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))
    assert_false("early vanish backs training off",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_false("consumed set is untagged (no ownership leak)",
        AutoPilot_Utils.isModAction(action))
    AutoPilot_Needs.resetInterventionForTest()
end

print("\n-- Test 31: a mod-initiated clear is NOT misread as a player cancel")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    assert_true("set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local action = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    -- Main clears the mod's own exercise (urgent need / threat / thrash)
    -- and notifies; the early vanish must then NOT trigger the backoff.
    AutoPilot_Needs.noteModExerciseCleared()
    assert_false("notification untagged the cleared set",
        AutoPilot_Utils.isModAction(action))
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))
    local before = #ISTimedActionQueue_calls
    assert_true("training re-queues immediately after a MOD-initiated clear",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("a new set was queued", #ISTimedActionQueue_calls, before + 1)
end

print("\n-- Test 32: F10 panic stop engages the backoff immediately")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    AutoPilot_Needs.notePanicStop()
    assert_false("training declines right after the panic stop",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_true("panel status reports the backoff",
        AutoPilot_Needs.getExerciseStatus().outcome:find("backing off", 1, true)
            ~= nil)
    MockTime.advance(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES * 60000
        + 60000)
    assert_true("training resumes after the panic-stop window",
        AutoPilot_Needs.trainExercise(p, "fitness"))
end

print("\n-- Test 33: an observed FOREIGN exercise holds training off")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    -- Main reports a manual exercise as the running action each busy cycle.
    AutoPilot_Needs.noteForeignExercise(p)
    local before = #ISTimedActionQueue_calls
    assert_false("training yields while the manual exercise is observed",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("nothing queued over the manual session",
        #ISTimedActionQueue_calls, before)
    MockTime.advance(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES * 60000
        + 60000)
    assert_true("training resumes one full window after the last observation",
        AutoPilot_Needs.trainExercise(p, "fitness"))
end

print("\n-- Test 34: a set still in the queue is not judged at all")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    assert_true("set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local action = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    -- Simulate the engine still running the set: the queue contains it.
    local origGetQueue = ISTimedActionQueue.getTimedActionQueue
    ISTimedActionQueue.getTimedActionQueue = function(_p)
        return { queue = { action } }
    end
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))
    AutoPilot_Needs.trainExercise(p, "fitness")
    assert_true("no backoff while the set is still queued (record intact)",
        AutoPilot_Needs.getExerciseStatus().outcome:find("backing off", 1, true)
            == nil)
    assert_true("the running set stays tagged as mod-owned",
        AutoPilot_Utils.isModAction(action))
    ISTimedActionQueue.getTimedActionQueue = origGetQueue
    AutoPilot_Needs.resetInterventionForTest()
end

print("\n-- Test 35: a Lua reload starts an empty ownership registry")
do
    local action = AutoPilot_Utils.tagModAction({ Type = "ISFitnessAction" })
    assert_true("tagged before the reload", AutoPilot_Utils.isModAction(action))
    -- An MP server join re-executes all mod Lua; re-dofile the real module
    -- exactly as the engine would.
    dofile("42/media/lua/client/AutoPilot_Utils.lua")
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, _callback) end
    assert_false("pre-reload tag is gone: the action now reads FOREIGN",
        AutoPilot_Utils.isModAction(action))
end

print("\n-- Test 36: a pending set from a dead character is discarded silently")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local pA = exercisePlayer()
    assert_true("character A queues a set",
        AutoPilot_Needs.trainExercise(pA, "fitness"))
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))
    -- Character A dies; the respawned character B trains: A's early-vanished
    -- set must NOT back B's training off (the who-guard).
    local pB = exercisePlayer()
    local before = #ISTimedActionQueue_calls
    assert_true("character B trains immediately (no cross-character backoff)",
        AutoPilot_Needs.trainExercise(pB, "fitness"))
    assert_eq("a new set was queued for B", #ISTimedActionQueue_calls,
        before + 1)
end

print("\n-- Test 37: backoff 0 disables the intervention hold entirely")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local savedBackoff = AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES
    AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES = 0
    local p = exercisePlayer()
    AutoPilot_Needs.notePanicStop()
    assert_true("with backoff 0 training never yields",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES = savedBackoff
    AutoPilot_Needs.resetInterventionForTest()
end

-- ── V4.6: XP gain is the limiter; the daily set cap is an opt-in ceiling ─────
-- User request: "Exercise should be capped by experience gain.  Meaning only
-- should stop when stop gaining xp from doing a given exercise."  So a cap of
-- 0 means unlimited and the XP-productivity detector is what halts training;
-- a cap > 0 stays available as a hard safety ceiling.

--- Run one productive set: a full-length set that actually gained XP, which
--- is what the XP-productivity gate wants to see before allowing the next.
local function productiveSet(p, gain)
    MockTime.advance(FULL_SET_MS)
    p._xp.Fitness = (p._xp.Fitness or 0) + (gain or 12)
    return AutoPilot_Needs.trainExercise(p, "fitness")
end

print("\n-- Test 38 (V4.6): cap 0 never halts training, at any set count")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
    local p = exercisePlayer()
    -- V5.7: the counter is per-character now, so a brand new player object
    -- zeroes it.  Establish ownership first, then take the baseline through
    -- the same character the 50 sets are about to run on.
    AutoPilot_Needs.syncSetsCounterForTest(p)
    local startCount = AutoPilot_Needs.getExerciseSetsToday()
    assert_eq("a fresh character starts the day on zero sets", startCount, 0)
    assert_true("first set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local blockedAt = nil
    for i = 2, 50 do
        if not productiveSet(p) then
            blockedAt = i
            break
        end
    end
    assert_eq("50 productive sets in one day, none blocked by a count",
        blockedAt, nil)
    assert_eq("every one of the 50 sets was really queued",
        #ISTimedActionQueue_calls, 50)
    assert_eq("the counter still ran while uncapped",
        AutoPilot_Needs.getExerciseSetsToday(), startCount + 50)
    assert_eq("status is training, not resting", AutoPilot_Needs
        .getExerciseStatus().outcome, "training: squats")
end

print("\n-- Test 39 (V4.6): a cap > 0 is still a hard ceiling (safety valve)")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    -- V5.7: a fresh character's counter starts at zero, and a cap of 0 means
    -- UNLIMITED, so put real sets on the board first and pin the ceiling
    -- exactly there: the next attempt is the one that must be refused.
    assert_true("warm-up set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    productiveSet(p)
    -- Clear the V4.5 intervention record the warm-up left behind, or the very
    -- next call reads the just-queued set as a player cancel and backs off
    -- before the cap gate is ever reached.
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP =
        AutoPilot_Needs.getExerciseSetsToday()
    assert_true("the ceiling is a real, non-zero count",
        AutoPilot_Constants.EXERCISE_DAILY_CAP > 0)
    local before = #ISTimedActionQueue_calls
    assert_false("training stops at a configured ceiling",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("nothing queued once the ceiling is hit",
        #ISTimedActionQueue_calls, before)
    assert_eq("panel reports the cap as the reason",
        AutoPilot_Needs.getExerciseStatus().outcome,
        "resting (daily set cap reached)")
    -- Raising the ceiling releases training again on the very next cycle.
    AutoPilot_Constants.EXERCISE_DAILY_CAP =
        AutoPilot_Needs.getExerciseSetsToday() + 5
    assert_true("a raised ceiling releases training",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
end

print("\n-- Test 40 (V4.6): with no cap, zero-XP sets are what stop training")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
    local p = exercisePlayer()
    -- Strength without equipment is a single-exercise pool (push-ups), so
    -- one unproductive set exhausts the whole pool.
    assert_true("push-up set queues", AutoPilot_Needs.trainExercise(p, "strength"))
    MockTime.advance(FULL_SET_MS)   -- full set, and NO XP gained
    local before = #ISTimedActionQueue_calls
    assert_false("an unproductive exercise halts training even uncapped",
        AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("nothing queued while XP-fatigued",
        #ISTimedActionQueue_calls, before)
    assert_eq("panel names XP fatigue, not the cap",
        AutoPilot_Needs.getExerciseStatus().outcome,
        "resting (exercises fatigued)")
    -- ...and the recovery window still returns it to service.
    MockTime.advance(AutoPilot_Constants.EXERCISE_FATIGUE_RECOVERY_MS + 60000)
    assert_true("push-ups retried after the recovery window",
        AutoPilot_Needs.trainExercise(p, "strength"))
end

print("\n-- Test 41 (V4.6): getExerciseStatus reads honestly in both modes")
do
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
    local st = AutoPilot_Needs.getExerciseStatus()
    local sets = st.setsToday
    assert_eq("uncapped: cap reads 0", st.cap, 0)
    assert_eq("uncapped: the panel line says so, never 'n/0'",
        st.setsLine, ("Sets today: %d (no cap)"):format(sets))
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 25
    st = AutoPilot_Needs.getExerciseStatus()
    assert_eq("capped: cap is reported", st.cap, 25)
    assert_eq("capped: the panel line shows count out of cap",
        st.setsLine, ("Sets today: %d/25"):format(sets))
    assert_eq("the raw count is unchanged by the cap setting",
        st.setsToday, sets)
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
