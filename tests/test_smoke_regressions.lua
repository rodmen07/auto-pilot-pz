-- tests/test_smoke_regressions.lua
-- The three regressions the 2026-07-24 in-game smoke test produced, kept
-- together because they share one shape: the mod queued something the ENGINE
-- then refused, or read a value the engine spells differently, so the code
-- looked correct and did nothing.
--
--   1. Sleep pain-gate (HIGH, "sleep-priority starvation while in pain"):
--      canSleepNow mirrors the engine gate, and the fatigue branch stopped
--      being terminal so a pain-blocked character falls through to rest.
--   2. Unhappy relief dead clause (a 0-4 moodle LEVEL compared against a 0-100
--      threshold, then the CamelCase MoodleType.Unhappy that resolves to nil).
--   3. Rest seating-data preference (bug 2 core, "Resting but standing"):
--      furniture the engine has sit data for is preferred.
--
-- Moved VERBATIM out of tests/test_priority_logic.lua (code-health split,
-- 2026-08-07, FOURTH slice; the V5.7 block moved in PR #115, the V5.4 rest
-- band in PR #116, the V5.8 seat-and-status block in PR #118).  That file was
-- still 1,733 lines after three slices.  Test bodies, stubs and assertions are
-- unchanged; only this header and the bootstrap each standalone suite carries
-- by repo convention (mock loads, module stubs, mini-framework, and the
-- furniture kit) are copied alongside.
--
-- The furniture kit came ACROSS rather than staying behind, which is the
-- difference from slice 3: noFurniture / resetRest / mockFurniture /
-- placeFurniture / windedPlayer had callers on BOTH sides of that cut, and
-- after this move their only callers in the source file are gone (grep over
-- the whole of test_priority_logic.lua: definitions plus the call sites, all
-- inside this block).  test_status_honesty.lua keeps its own copy.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_smoke_regressions.lua

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
-- AutoPilot_Needs.check/forceSleep now call into it).  canSleepNow, the
-- subject of the first block below, lives there.
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
-- Moved with the block out of tests/test_priority_logic.lua (repo convention:
-- every standalone suite carries its own helpers).  The seating-preference
-- cases at the bottom are the only remaining callers.

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

-- ── Sleep pain-gate regression (bug: sleep starvation when sore, 2026-07-24) ──
-- The fatigue -> sleep branch used to be terminal, so a tired character in pain
-- queued a sleep the engine refuses ("Experiencing too much pain to sleep") and
-- then addressed no other need.  AutoPilot_Sleep.canSleepNow now mirrors the
-- engine gate (ISWorldObjectContextMenu.onSleepWalkToComplete) and the branch
-- falls through when sleep cannot actually proceed.
print("\n-- Test: canSleepNow mirrors the engine pain/panic sleep gate")
do
    local can, why = AutoPilot_Sleep.canSleepNow(MockPlayer.new({
        stats = { FATIGUE = 0.75 }, moodles = { [MoodleType.PAIN] = 2 } }))
    assert_false("PAIN moodle 2 + fatigue 0.75 -> cannot sleep", can)
    assert_eq("block reason is pain_block", why, "pain_block")

    -- Extreme fatigue (> 0.85) bypasses the pain gate, matching the engine.
    assert_true("PAIN moodle 2 but fatigue 0.90 -> can sleep",
        (AutoPilot_Sleep.canSleepNow(MockPlayer.new({
            stats = { FATIGUE = 0.90 }, moodles = { [MoodleType.PAIN] = 2 } }))))

    -- Mild pain (moodle 1) does not block.
    assert_true("PAIN moodle 1 -> can sleep",
        (AutoPilot_Sleep.canSleepNow(MockPlayer.new({
            stats = { FATIGUE = 0.75 }, moodles = { [MoodleType.PAIN] = 1 } }))))

    -- Panic blocks sleep with its own reason.
    local canP, whyP = AutoPilot_Sleep.canSleepNow(MockPlayer.new({
        stats = { FATIGUE = 0.75 }, moodles = { [MoodleType.PANIC] = 1 } }))
    assert_false("PANIC moodle 1 -> cannot sleep", canP)
    assert_eq("block reason is panic", whyP, "panic")

    -- A strong sleeping-tablet effect bypasses the gate entirely.
    assert_true("sleeping-tablet effect >= 2000 bypasses the pain block",
        (AutoPilot_Sleep.canSleepNow(MockPlayer.new({
            stats = { FATIGUE = 0.75 },
            moodles = { [MoodleType.PAIN] = 2 },
            sleepingTablet = 3000 }))))
end

print("\n-- Test: check() falls through to a lower need when sleep is pain-blocked")
do
    reset()
    resetRest()
    -- Tired (0.75 >= 0.70) AND sleep-blocked by pain (PAIN moodle 2, fatigue <= 0.85)
    -- AND exhausted (endurance 0.20 <= 0.30).  Before the fix the terminal sleep
    -- branch returned first and queued NOTHING; now it falls through to rest.
    local p = MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.75, ENDURANCE = 0.20 },
        moodles = { [MoodleType.PAIN] = 2 },
    })
    local result = AutoPilot_Needs.check(p)
    assert_true("check() acts (does not idle) when tired but sleep is pain-blocked", result)
    assert_eq("falls through to 'rest' instead of terminating on sleep",
        last_action_type(), "rest")

    -- Negative control: identical fatigue/endurance but NO pain.  The sleep
    -- branch stays terminal, so the rest below is never reached -- proving the
    -- new gate diverts ONLY on a real block (the behavior difference is real).
    reset()
    resetRest()
    local q = MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.75, ENDURANCE = 0.20 },
        moodles = {},
    })
    AutoPilot_Needs.check(q)
    assert_eq("with no pain the sleep branch stays terminal (no rest queued)",
        last_action_type(), nil)
end

-- ── Unhappy relief dead-clause regression (2026-07-24, deepened 2026-07-25) ──
-- Cause 1 (fixed 2026-07-24, PR #68): the unhappy moodle is a 0-4 LEVEL, but
-- HAPPINESS_LOW_THRESHOLD was 40, so the unhappy relief branch in check() could
-- never fire (0-4 is never >= 40).  Test 23 in test_priority_logic.lua only
-- "passed" because it set the moodle to the constant's own value, an impossible
-- in-game level, so it referenced the bug instead of catching it.  This case
-- uses a REALISTIC level (2).
--
-- Cause 2 (fixed 2026-07-25): correcting the threshold was not enough, because the
-- moodle was read as MoodleType.Unhappy and B42 spells the constant
-- MoodleType.UNHAPPY (engine: shared/TimedActions/ISBaseTimedAction.lua:102).  The
-- CamelCase name resolved to nil in-game, safeMoodleLevel degraded it to 0, and the
-- branch stayed dead anyway.  This suite could not see that, because lua_mock_pz.lua
-- modelled the same wrong name -- the mock supplied a moodle only the tests had.
-- The mock now models UNHAPPY only, so this case fails on EITHER cause: revert the
-- threshold and 2 < 40 skips the branch; revert the constant and the level reads 0.
-- tests/test_engine_symbols.lua is the guard that stops cause 2 coming back.
print("\n-- Test: a realistic unhappy moodle level (2) triggers mood relief")
do
    reset()
    resetRest()
    local tastyFood = {
        getName     = function() return "Chocolate" end,
        getCalories = function() return 200 end,
    }
    AutoPilot_Inventory.preferTastyFood = function(_player) return tastyFood end
    -- Healthy vitals + BOREDOM 0 so ONLY the unhappy trigger can fire (isolates it,
    -- unlike Test 23 which also set BOREDOM=50).
    local p = MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05, ENDURANCE = 1.0, BOREDOM = 0 },
        moodles = { UNHAPPY = 2 },
    })
    local result = AutoPilot_Needs.check(p)
    AutoPilot_Inventory.preferTastyFood = function(_player) return nil end
    assert_true("check() acts on a realistic unhappy moodle (level 2)", result)
    assert_eq("queues 'eat' (mood relief) for unhappy 2, not exercise/idle",
        last_action_type(), "eat")
    -- V6.1-3 (2026-07-26): this test used to also assert on getMoodleSnapshot's
    -- `sad` key, fed by the same UNHAPPY lookup.  That snapshot and its only
    -- caller printStatus were DEAD CODE (printStatus had zero callers and its
    -- `print` is noop-shadowed) and were DELETED rather than wired -- the F11
    -- panel, the HUD reason line and the run log are the living surfaces.  The
    -- UNHAPPY-spelling regression stays covered by the check() assertions
    -- above, which read the same safeMoodleLevel lookup through doMoodRelief.
    -- These two make resurrecting the dead pair a deliberate act with a red
    -- build (spec: docs/MILESTONE_V6_1.md, V6.1-3).
    assert_eq("getMoodleSnapshot stays deleted (V6.1-3)",
        AutoPilot_Needs.getMoodleSnapshot, nil)
    assert_eq("printStatus stays deleted (V6.1-3)",
        AutoPilot_Needs.printStatus, nil)
end

-- ── Rest seating-data preference (bug 2 core, 2026-07-24) ────────────────────
-- Per the engine, ISRestAction only plays the sit-down animation on furniture
-- that has SeatingManager sit data; a dining chair without it rests the character
-- STANDING (the reported "Resting but standing" bug).  findRestFurniture now
-- prefers furniture the character can actually sit on, all TYPES otherwise equal.
print("\n-- Test: a sittable sofa is preferred over a NEARER un-sittable dining chair")
do
    resetRest()
    placeFurniture({
        { sprite = "furniture_seating_indoor_chair_04", dx = 1, dy = 0, seatData = false },
        { sprite = "furniture_seating_indoor_sofa_01",  dx = 2, dy = 0 },
    })
    local player = windedPlayer(0.40)
    assert_true("check() rests", AutoPilot_Needs.check(player))
    local sit = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_eq("the seat path is used", sit.type, "sit_furniture")
    assert_eq("the SITTABLE sofa is chosen over the nearer no-seat-data chair",
        sit.target:getSprite():getName(), "furniture_seating_indoor_sofa_01")
    noFurniture()
end

print("\n-- Test: a lone un-sittable chair is still used (the preference is not a gate)")
do
    resetRest()
    placeFurniture({
        { sprite = "furniture_seating_indoor_chair_04", dx = 1, dy = 0, seatData = false },
    })
    AutoPilot_Needs.check(windedPlayer(0.40))
    assert_eq("a no-seat-data chair still beats the ground for resting",
        last_action_type(), "sit_furniture")
    noFurniture()
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
