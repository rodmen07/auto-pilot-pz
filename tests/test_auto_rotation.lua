-- tests/test_auto_rotation.lua
-- The V5.2 auto-day exercise rotation: an auto-focus day must prefer the
-- equipment the mod itself fetched over burpees, and a fatigued equipment
-- exercise must ROTATE rather than stall.
--
-- User report (in game): the character walked out, picked up dumbbells, added
-- them to inventory, "but then continued doing burpees instead of dumbell
-- presses or bicep curls".  Burpees led the auto pool, so the equipment the
-- mod itself fetches (fetchExerciseEquipment) was never used on an auto day,
-- and bicepscurl/barbellcurl were not in the auto pool at all.  Test 47 is the
-- collateral guard that the strength and fitness pools were NOT reordered.
--
-- Moved VERBATIM out of tests/test_priority_logic.lua (code-health split,
-- 2026-08-08, FIFTH slice; the V5.7 trainer-state block moved in PR #115, the
-- V5.4 rest band in PR #116, the V5.8 seat-and-status block in PR #118 and the
-- 2026-07-24 smoke-test regressions in PR #125).  That file was still 1,509
-- lines after four slices, over the 1000-line hard threshold preflight C10
-- flags.  Test bodies, stubs and assertions are unchanged; only this header
-- and the bootstrap each standalone suite carries by repo convention (mock
-- loads, module stubs, mini-framework) are copied alongside.
--
-- WHY THIS SEAM, measured rather than assumed (the method that has now worked
-- five times: cut where a helper kit has callers on ONE side only).  The three
-- candidate blocks the backlog listed were re-measured in the source file
-- before anything moved:
--
--   * V5.2 auto rotation (this block): autoExercisePlayer and
--     fatigueAndAdvance are defined inside it and called ONLY inside it
--     (lines 1406-1482 of the pre-split file) -- a clean cut.
--   * V4.5 ownership/backoff: every case calls exercisePlayer(), which is
--     defined in the V3.2 block ABOVE it and also called by V4.6 BELOW it, so
--     the kit straddles the cut in both directions.
--   * V4.6 XP cap: same exercisePlayer straddle, plus count_action_type is
--     defined inside V4.6 and called by the V4.9 transfer block below it.
--
-- So V4.5 and V4.6 are NOT independently movable; the next natural seam is the
-- whole exercise family (V3.2 + V4.5 + V4.6) with count_action_type left
-- behind for V4.9.  Recorded here so slice 6 does not re-derive it.
--
-- FULL_SET_MS is the one thing that came across rather than being referenced:
-- it is a derived constant (EXERCISE_MINUTES x 60000), not behaviour, and
-- tests/test_exercise_gates.lua already keeps its own copy for the same
-- reason.  It stays in the source file too, where the V3.2/V4.5/V4.6 blocks
-- still use it.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_auto_rotation.lua

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

-- Full-length set duration (see the header: derived constant, copied).
local FULL_SET_MS = AutoPilot_Constants.EXERCISE_MINUTES * 60000

-- ── V5.2: auto days prefer carried equipment over burpees ────────────────────
-- User report (in game): the character walked out, picked up dumbbells, added
-- them to inventory, "but then continued doing burpees instead of dumbell
-- presses or bicep curls".  Burpees led the auto pool, so the equipment the
-- mod itself fetches (fetchExerciseEquipment) was never used on an auto day,
-- and bicepscurl/barbellcurl were not in the auto pool at all.  The auto pool
-- now leads with equipment, then burpees, then bodyweight work.

--- A calm player who may or may not be carrying exercise gear.
local function autoExercisePlayer(gear)
    return MockPlayer.new({
        stats    = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                     ENDURANCE = 0.90 },
        moodles  = { ENDURANCE = 0, UNHAPPY = 0 },
        hasItems = gear and true or false,
    })
end

--- Burn one full-length set that produced NO XP, so the exercise just queued
--- is judged fatigued on the next call, and return the next queued exType.
local function fatigueAndAdvance(p, focus)
    MockTime.advance(FULL_SET_MS)
    local queued = AutoPilot_Needs.trainExercise(p, focus)
    if not queued then return nil end
    return ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType
end

print("\n-- Test 44 (V5.2): an auto day uses a CARRIED dumbbell, not burpees")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
    local p = autoExercisePlayer(true)
    assert_true("auto-focus set queues with gear carried",
        AutoPilot_Needs.trainExercise(p, nil))
    -- The exact user scenario: dumbbells in inventory on an auto day.
    assert_eq("dumbbell press picked over burpees (1.8x exercise)",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType,
        "dumbbellpress")
end

print("\n-- Test 45 (V5.2): a barehanded auto day still starts on burpees")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = autoExercisePlayer(false)
    assert_true("auto-focus set queues without gear",
        AutoPilot_Needs.trainExercise(p, nil))
    -- Equipment entries fail _hasExerciseItem and fall through silently, so
    -- the both-stats exercise still leads for a character carrying nothing.
    assert_eq("burpees picked when no equipment is carried",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "burpees")
end

print("\n-- Test 46 (V5.2): the auto rotation reaches bicepscurl, then burpees")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = autoExercisePlayer(true)
    assert_true("auto set queues", AutoPilot_Needs.trainExercise(p, nil))
    assert_eq("starts on the dumbbell press",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType,
        "dumbbellpress")
    -- Fatigued equipment work must ROTATE, never stall.  Before V5.2
    -- bicepscurl was unreachable on an auto day at any point.
    assert_eq("XP-fatigued dumbbell press falls through to bicep curls",
        fatigueAndAdvance(p, nil), "bicepscurl")
    assert_eq("fatigued bicep curls fall through to barbell curls",
        fatigueAndAdvance(p, nil), "barbellcurl")
    -- ...and the both-stats exercise is still in the rotation behind them,
    -- so Fitness keeps progressing on an auto day.
    assert_eq("fatigued equipment work falls through to burpees",
        fatigueAndAdvance(p, nil), "burpees")
end

print("\n-- Test 47 (V5.2): the strength and fitness pools are untouched")
do
    -- Collateral guard: V5.2 reordered the AUTO pool only.
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = autoExercisePlayer(true)
    assert_true("strength set queues", AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("strength still starts on the dumbbell press",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType,
        "dumbbellpress")
    assert_eq("strength order 2: bicepscurl",
        fatigueAndAdvance(p, "strength"), "bicepscurl")
    assert_eq("strength order 3: barbellcurl",
        fatigueAndAdvance(p, "strength"), "barbellcurl")
    assert_eq("strength order 4: pushups",
        fatigueAndAdvance(p, "strength"), "pushups")
    assert_eq("the strength pool ends after push-ups (no burpees in it)",
        fatigueAndAdvance(p, "strength"), nil)

    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local q = autoExercisePlayer(true)
    assert_true("fitness set queues", AutoPilot_Needs.trainExercise(q, "fitness"))
    assert_eq("fitness still starts on squats",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "squats")
    assert_eq("fitness order 2: situp", fatigueAndAdvance(q, "fitness"), "situp")
    -- Gear is carried here, so this also proves no equipment leaked into the
    -- bodyweight-only fitness pool.
    assert_eq("the fitness pool ends after sit-ups",
        fatigueAndAdvance(q, "fitness"), nil)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
