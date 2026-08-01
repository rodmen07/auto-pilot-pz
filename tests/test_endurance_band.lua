-- tests/test_endurance_band.lua
-- V6.1-1: behaviour-difference tests for the endurance idle band.
--
-- The bug (HIGH, filed from the 2026-07-26 in-game session, 10,400 ticks of
-- `auto_pilot_run.log`): the leveler trained for 1.5% of the session.  Of
-- 1,636 action episodes, 1,374 were rest and 1,341 of those logged
-- `reason=rest_cooldown`; measured endurance ran min 58 / max 100 / mean 85.3,
-- and the 0.30 training floor that would justify all that resting was never
-- approached.  The mod was not broken, it was PARKED: with the V5.7 defaults
-- (`EXERCISE_ENDURANCE_RESUME = 0.90`, `ENDURANCE_REST_TARGET = 0.95`) the
-- run-aware sit threshold in AutoPilot_Needs check 7b raises the sit gate to
-- the RESUME value whenever no run is active, so every endurance between 0.35
-- and 0.90 sat the character down and held it there while endurance crawled
-- across the flattest part of the recovery curve.
--
-- The fix is the user's answer to `docs/MILESTONE_V6_1.md` Q1, option (a),
-- given 2026-08-01: lower the two upper defaults to 0.75 / 0.80.  Both stay
-- player-tunable sliders with unchanged ranges, so this moves the DEFAULT and
-- not the ceiling.
--
-- These cases exist because a constant change is invisible to luacheck and to
-- every existing suite except an expected-value edit.  What has to be proven
-- is the BEHAVIOUR DIFFERENCE: the same character, at the same endurance, on
-- the same code, doing something different under the two default sets.  Every
-- case below therefore runs check() twice -- once on the shipped constants and
-- once with the V5.7 pair restored -- rather than asserting a number.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_endurance_band.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}

AutoPilot_Medical = {
    hasCriticalWound = function(_player) return false end,
    check            = function(_player, _bleedingOnly) return false end,
}

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
    bodyTemperature       = function(_player) return 0 end,
}

dofile("42/media/lua/client/AutoPilot_Utils.lua")
-- No furniture anywhere: a sit falls back to the ground square, which is what
-- the V5.4 cases already rely on, and keeps seat selection out of this file.
AutoPilot_Utils.iterateNearbySquares = function(_cx, _cy, _cz, _radius, _cb) end

AutoPilot_Home = {
    isSet            = function(_player) return false end,
    isInside         = function(_sq) return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

dofile("42/media/lua/client/AutoPilot_Consumption.lua")
dofile("42/media/lua/client/AutoPilot_Sleep.lua")
dofile("42/media/lua/client/AutoPilot_Rest.lua")
dofile("42/media/lua/client/AutoPilot_Exercise.lua")
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

local function assert_true(desc, val)  assert_eq(desc, not not val, true)  end
local function assert_false(desc, val) assert_eq(desc, not not val, false) end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- The V5.7 pair, kept here as literals ON PURPOSE: reading them back out of
-- AutoPilot_Constants would make every "before" assertion below compare the
-- shipped value against itself and pass no matter what ships.
local V5_7_RESUME      = 0.90
local V5_7_REST_TARGET = 0.95

-- A character whose ONLY variable is endurance: nothing above step 7b in
-- check()'s chain can claim the cycle, so whatever it does is the endurance
-- decision and nothing else.
local function windedPlayer(endurance)
    return MockPlayer.new({
        stats = {
            HUNGER    = 0.02,
            THIRST    = 0.02,
            FATIGUE   = 0.02,
            BOREDOM   = 0,
            SANITY    = 0,
            ENDURANCE = endurance,
        },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
    })
end

local function nowMs()
    return getGameTime():getCalender():getTimeInMillis()
end

-- Clear everything an earlier case could leak: the queue, an open rest hold,
-- and the training-run flag (which is what selects the floor over the gate).
local function reset()
    ISTimedActionQueue_calls = {}
    MockTime.advance((AutoPilot_Constants.REST_HOLD_MS or 60000) + 120000)
    AutoPilot_Rest.clearRestHold()
    AutoPilot_Needs.endTrainingRun()
end

local function lastActionType()
    local c = ISTimedActionQueue_calls
    if #c == 0 then return nil end
    return c[#c].type
end

-- Run fn() with a given (resume, restTarget) pair installed, then put the
-- shipped constants back whatever happens.  Constants are read live at every
-- decision (the V3.3 pattern), so this is exactly what moving the sliders in
-- game does -- no reload, no re-dofile.
local function withPair(resume, restTarget, fn)
    local savedR = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    local savedT = AutoPilot_Constants.ENDURANCE_REST_TARGET
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = resume
    AutoPilot_Constants.ENDURANCE_REST_TARGET     = restTarget
    local ok, err = pcall(fn)
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = savedR
    AutoPilot_Constants.ENDURANCE_REST_TARGET     = savedT
    if not ok then error(err, 0) end
end

-- What does an idle character at this endurance DO?  Returns the queued action
-- type ("exercise", "rest", ...) or nil when the cycle queued nothing.
local function actionAt(endurance)
    reset()
    AutoPilot_Needs.check(windedPlayer(endurance))
    return lastActionType()
end

print("=== V6.1-1: the endurance idle band ===")

-- ── 1. HEADLINE: the exact case the milestone names ──────────────────────────
print("\n-- Test 1 (HEADLINE): at 85% endurance the character now TRAINS,"
    .. " where it used to sit")
do
    -- 0.85 is not an arbitrary pick: the session's MEAN endurance was 85.3,
    -- so this is the single number the character actually lived at.
    assert_eq("shipped defaults: 85% endurance queues exercise",
        actionAt(0.85), "exercise")

    local before
    withPair(V5_7_RESUME, V5_7_REST_TARGET, function()
        before = actionAt(0.85)
    end)
    assert_eq("V5.7 defaults: the SAME character at 85% queued a rest instead",
        before, "rest")

    -- The two answers must differ, or the constants changed and behaviour did
    -- not -- which is the failure mode a value-only edit ships silently.
    assert_true("the two default sets genuinely disagree at 85%",
        before ~= actionAt(0.85))
end

-- ── 2. The reclaimed band, end to end ────────────────────────────────────────
print("\n-- Test 2: the whole 0.75-0.90 band flips from resting to training")
do
    for _, e in ipairs({ 0.75, 0.78, 0.85, 0.89 }) do
        assert_eq(("%.0f%% endurance trains under the shipped defaults")
            :format(e * 100), actionAt(e), "exercise")
    end
    withPair(V5_7_RESUME, V5_7_REST_TARGET, function()
        for _, e in ipairs({ 0.75, 0.78, 0.85, 0.89 }) do
            assert_eq(("%.0f%% endurance rested under the V5.7 defaults")
                :format(e * 100), actionAt(e), "rest")
        end
    end)
end

-- ── 3. The gate still gates: below it, nothing changed ───────────────────────
print("\n-- Test 3: below the new resume gate the character still sits down")
do
    -- The fix must not turn into "always train".  Under the resume gate and
    -- with no run open there is still nothing to do but recover.
    for _, e in ipairs({ 0.40, 0.60, 0.74 }) do
        assert_eq(("%.0f%% endurance still queues a rest"):format(e * 100),
            actionAt(e), "rest")
    end
    assert_eq("exactly AT the resume gate it trains, not rests",
        actionAt(AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME), "exercise")
end

-- ── 4. The seated target moved with it ───────────────────────────────────────
print("\n-- Test 4: a rest hold now RELEASES at 80%, not 95%")
do
    -- Engage a hold exactly as doRest does, then ask check() what happens.
    local function heldAt(endurance)
        ISTimedActionQueue_calls = {}
        AutoPilot_Needs.endTrainingRun()
        AutoPilot_Rest.clearRestHold()
        AutoPilot_Rest.extendRestHold(nowMs())
        local claimed = AutoPilot_Needs.check(windedPlayer(endurance))
        return claimed, AutoPilot_Rest.isRestHoldActive(nowMs()), lastActionType()
    end

    local claimed, stillHeld, act = heldAt(0.82)
    assert_true("check() claims the cycle at 82% while held", claimed)
    assert_false("the hold is RELEASED at 82% (above the new 80% target)",
        stillHeld)
    assert_eq("...and the freed cycle goes straight into training", act,
        "exercise")

    local _, stillHeld78, act78 = heldAt(0.78)
    assert_true("at 78% the hold is still active (below the new target)",
        stillHeld78)
    assert_eq("...and nothing new is queued; the character stays seated",
        act78, nil)

    withPair(V5_7_RESUME, V5_7_REST_TARGET, function()
        local _, held, actOld = heldAt(0.82)
        assert_true("V5.7 defaults: 82% was still holding (target was 95%)",
            held)
        assert_eq("...so the same cycle queued nothing at all", actOld, nil)
    end)
end

-- ── 5. The dead zone stays shut across the whole range ───────────────────────
print("\n-- Test 5: no endurance value leaves the character neither"
    .. " sitting nor training")
do
    -- The V5.4/V5.7 property this retune must not break: the band between
    -- "will not sit" and "will not train" has to be empty.  It is a property
    -- of the PAIR, not of either number, so moving both is exactly when it can
    -- silently reopen.  Swept rather than sampled, and reported as one
    -- assertion so the output stays readable.
    local idle = {}
    local e = 0.31
    while e <= 1.0 + 1e-9 do
        local act = actionAt(e)
        if act ~= "rest" and act ~= "exercise" then
            table.insert(idle, ("%.2f=%s"):format(e, tostring(act)))
        end
        e = e + 0.01
    end
    assert_eq("every endurance from 31% to 100% resolves to rest or exercise",
        #idle == 0 and "none idle" or table.concat(idle, ","), "none idle")
end

-- ── Summary ──────────────────────────────────────────────────────────────────
print(("\n=== EnduranceBand: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
