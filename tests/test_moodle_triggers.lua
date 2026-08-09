-- tests/test_moodle_triggers.lua
-- V6.2 C1: moodle-aligned hunger/thirst triggers (approved with defaults
-- 2026-08-01, docs/EXPANSION_PROPOSAL_V6_2.md).
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- Before this change the mod reacted to raw HUNGER/THIRST stats only, so its
-- eat/drink timing needed explaining ("why is it not eating? the slider says
-- 0.15") and was welded to a hidden stat scale — the exact defect class that
-- killed the original V6 C1 (a threshold on a scale the author assumed wrong).
-- Now the game's own Hungry/Thirsty moodle (level >= 1) ALSO fires the
-- trigger: the mod reacts to the same signal the player sees on screen.
--
-- The defaults under test, from the proposal:
--   D1  moodle >= 1 OR the tunable stat threshold — a pure widening.  The
--       moodle arm can never make the mod eat/drink LATER than today, and the
--       stat arm keeps precedence AND its reason token.
--   D2  both check() and shouldInterrupt() carry the widening.
--   D3  telemetry honesty: "hunger_moodle"/"thirst_moodle" are recorded ONLY
--       when the moodle arm fired and the stat arm alone would not have.
--
-- MoodleType.HUNGRY and MoodleType.THIRST were verified in the 42.19 jar's
-- constant pool (zombie/scripting/objects/MoodleType.class — neither name
-- exists anywhere in the install's Lua); see the mock's MoodleType note.
--
-- New test logic lives in its own file rather than growing
-- tests/test_priority_logic.lua (preflight C10 flags it at 2600+ lines).
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_moodle_triggers.lua

-- ── Load mocks (same harness shape as tests/test_endurance_band.lua) ──────────
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
AutoPilot_Utils.iterateNearbySquares = function(_cx, _cy, _cz, _radius, _cb) end

AutoPilot_Home = {
    isSet            = function(_player) return false end,
    isInside         = function(_sq)     return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

dofile("42/media/lua/client/AutoPilot_Consumption.lua")
dofile("42/media/lua/client/AutoPilot_Sleep.lua")
dofile("42/media/lua/client/AutoPilot_Rest.lua")
dofile("42/media/lua/client/AutoPilot_Exercise.lua")
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

-- Capture every setDecision call (the stock mock stub discards them).
local captured
local function captureDecisions()
    captured = {}
    AutoPilot_Telemetry.setDecision =
        function(action, reason, _player, stage, fail_reason, _retry)
            table.insert(captured, {
                action = action, reason = reason,
                stage = stage, fail_reason = fail_reason,
            })
        end
end

-- The reason recorded for a given action, or nil when that action never
-- reached setDecision this cycle.  check() records speculative decisions for
-- branches that then decline (wound, clothing, ...), so lookups are by action.
local function reasonFor(action)
    for _, d in ipairs(captured) do
        if d.action == action then return d.reason end
    end
    return nil
end

-- A character whose hunger/thirst state is the ONLY variable: everything else
-- in check()'s chain declines, so any drink/eat decision below is the trigger
-- under test and nothing else.
local function player(cfg)
    return MockPlayer.new({
        stats = {
            HUNGER    = cfg.hunger or 0.02,
            THIRST    = cfg.thirst or 0.02,
            FATIGUE   = 0.02,
            BOREDOM   = 0,
            SANITY    = 0,
            ENDURANCE = 0.95,
        },
        moodles = {
            ENDURANCE = 0,
            UNHAPPY   = 0,
            HUNGRY    = cfg.hungryMoodle or 0,
            THIRST    = cfg.thirstMoodle or 0,
        },
    })
end

local function reset()
    ISTimedActionQueue_calls = {}
    MockTime.advance((AutoPilot_Constants.REST_HOLD_MS or 60000) + 120000)
    AutoPilot_Rest.clearRestHold()
    AutoPilot_Needs.endTrainingRun()
    captureDecisions()
end

print("=== V6.2 C1: moodle-aligned hunger/thirst triggers ===")

-- ── 1. HEADLINE: the moodle alone now triggers, where it used to be ignored ──
print("\n-- Test 1 (HEADLINE): Thirsty moodle 1, stat under the slider ->"
    .. " the mod drinks, and says why")
do
    reset()
    AutoPilot_Needs.check(player({ thirst = 0.02, thirstMoodle = 1 }))
    assert_eq("the drink decision carries the new honest reason",
        reasonFor("drink"), "thirst_moodle")

    -- Pre-change behaviour, for the difference: same character, moodle 0.
    reset()
    AutoPilot_Needs.check(player({ thirst = 0.02, thirstMoodle = 0 }))
    assert_eq("without the moodle the same stats never reach the drink branch",
        reasonFor("drink"), nil)
end

print("\n-- Test 2 (HEADLINE): Hungry moodle 1, stat under the slider ->"
    .. " the mod eats, and says why")
do
    reset()
    AutoPilot_Needs.check(player({ hunger = 0.02, hungryMoodle = 1 }))
    assert_eq("the eat decision carries the new honest reason",
        reasonFor("eat"), "hunger_moodle")

    reset()
    AutoPilot_Needs.check(player({ hunger = 0.02, hungryMoodle = 0 }))
    assert_eq("without the moodle the same stats never reach the eat branch",
        reasonFor("eat"), nil)
end

-- ── 2. The stat arm is untouched: same trigger, same reason as before ────────
print("\n-- Test 3: at or above the slider nothing changed — same reason"
    .. " token, moodle or not")
do
    reset()
    AutoPilot_Needs.check(player({ thirst = 0.50, thirstMoodle = 0 }))
    assert_eq("stat-triggered drink keeps thirst_thresh (moodle absent)",
        reasonFor("drink"), "thirst_thresh")

    -- D3 honesty in the other direction: when the stat arm fired anyway, the
    -- moodle must NOT relabel the decision — "thirst_moodle" is reserved for
    -- cycles the stat alone would have missed.
    reset()
    AutoPilot_Needs.check(player({ thirst = 0.50, thirstMoodle = 3 }))
    assert_eq("stat-triggered drink keeps thirst_thresh (moodle present)",
        reasonFor("drink"), "thirst_thresh")

    reset()
    AutoPilot_Needs.check(player({ hunger = 0.50, hungryMoodle = 3 }))
    assert_eq("stat-triggered eat keeps hunger_thresh (moodle present)",
        reasonFor("eat"), "hunger_thresh")
end

-- ── 3. D2: shouldInterrupt carries the same widening ─────────────────────────
print("\n-- Test 4: the moodle interrupts an in-progress action, level 0"
    .. " does not")
do
    assert_true("Thirsty moodle 1 interrupts (stat under the slider)",
        AutoPilot_Needs.shouldInterrupt(player({ thirstMoodle = 1 })))
    assert_true("Hungry moodle 1 interrupts (stat under the slider)",
        AutoPilot_Needs.shouldInterrupt(player({ hungryMoodle = 1 })))
    assert_false("neither moodle, stats under the sliders: no interrupt",
        AutoPilot_Needs.shouldInterrupt(player({})))
    assert_true("the stat arm still interrupts on its own (thirst 0.50)",
        AutoPilot_Needs.shouldInterrupt(player({ thirst = 0.50 })))
end

-- ── 4. D1 is a pure widening: moodle 0 changes nothing anywhere ──────────────
print("\n-- Test 5: with both moodles at 0 the calm chain is untouched")
do
    reset()
    local p = player({})
    AutoPilot_Needs.check(p)
    assert_eq("no drink decision on a calm cycle", reasonFor("drink"), nil)
    assert_eq("no eat decision on a calm cycle", reasonFor("eat"), nil)
    -- The cycle still resolves to the chain tail (training), proving the new
    -- arms declined by returning nothing rather than by breaking the chain.
    local last = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_eq("the calm cycle still falls through to training",
        last and last.type, "exercise")
end

-- ── 5. Precedence: the thirst trigger LOSES to a sleepable fatigue ───────────
-- Behavioral pin for the sleep-above-thirst precedence (backlog follow-up
-- opened 2026-08-08 by PR #141).  test_priority_logic.lua Test 4 stages thirst
-- at 0.05, so it proves the sleep path is ENTERED, never that sleep WINS a
-- live contest; test_priority_chain_truth.py binds the PROSE to the source
-- order, so a reorder that also updates the prose ships as "documented".
-- This case stages BOTH needs above their thresholds with canSleepNow true
-- (PAIN and PANIC moodles default to 0), so the sleep branch is TERMINAL —
-- doSleep's result is returned even though the mock cell has no bed — and a
-- regression that moves the fatigue gate below the thirst trigger fails HERE
-- on the CODE, whatever the prose says.  It lives in this suite rather than
-- growing test_priority_logic.lua back over the 1000-line C10 threshold six
-- code-health slices just got it under; the thirst trigger under contest is
-- this suite's subject.
print("\n-- Test 6: fatigue and thirst both live -> sleep wins the contest")
do
    reset()
    -- A drink IS available, so if the thirst branch were reached it would act.
    AutoPilot_Inventory.getBestDrink = function(_player)
        return { getName = function() return "WaterBottle" end }
    end
    local p = MockPlayer.new({
        stats = {
            HUNGER    = 0.02,
            THIRST    = 0.30,   -- above THIRST_THRESHOLD (0.15): a real contest
            FATIGUE   = 0.80,   -- above FATIGUE_THRESHOLD (0.70)
            BOREDOM   = 0,
            SANITY    = 0,
            ENDURANCE = 0.95,
        },
        moodles = { ENDURANCE = 0, UNHAPPY = 0, HUNGRY = 0, THIRST = 0 },
    })
    AutoPilot_Needs.check(p)

    assert_eq("the contested cycle decides sleep for the fatigue reason",
        reasonFor("sleep"), "fatigue_thresh")
    -- Discriminate the WIN from the pain-blocked fall-through, which records
    -- the same action+reason plus a fail_reason and then reaches thirst.
    local sleepFail
    for _, d in ipairs(captured) do
        if d.action == "sleep" then sleepFail = d.fail_reason end
    end
    assert_eq("the sleep decision carries no engine-block fail_reason",
        sleepFail, nil)
    assert_eq("the thirst branch is never reached: no drink decision",
        reasonFor("drink"), nil)
    assert_eq("no action was queued for the drinkable thirst",
        #ISTimedActionQueue_calls, 0)

    -- Restore the stock stub for any case added after this one.
    AutoPilot_Inventory.getBestDrink = function(_player) return nil end
end

-- ── Summary ──────────────────────────────────────────────────────────────────
print(("\n=== MoodleTriggers: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
