-- tests/test_scavenge_telemetry.lua
-- The scavenge decision must say WHY it claimed nothing (2026-07-26 follow-up
-- to PR #85, the carry-capacity gate).
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- doProactiveScavenge counts trips that produce no supply gain and backs off
-- after SCAVENGE_STUCK_LIMIT trips.  A pickup the carry gate REFUSED and a
-- container with NOTHING USEFUL both looked identical to that counter and to
-- the run log, so an overloaded character tripped the stuck-backoff and the
-- log read "no supply gain after 3 trips" with no hint the mod was full.
-- The fix threads the gate's fail label ("carry_full") into the scavenge
-- telemetry decision, the same shape PR #67 used for a blocked sleep — which
-- is what made the sleep-starvation bug visible from the log alone.
--
-- The stuck-counter/backoff BEHAVIOUR is deliberately unchanged (an overloaded
-- character should still stop scavenging); only its observability changed.
-- Test 4 pins that.
--
-- New test logic lives in its own file rather than growing
-- tests/test_priority_logic.lua (preflight C10 flags it at 2600+ lines).
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_scavenge_telemetry.lua

-- ── Load mocks (same harness shape as tests/test_priority_logic.lua) ──────────
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

-- Inventory stub — each case reconfigures lootNearbyFood/lootNearbyDrink and
-- getSupplyCounts.  Returning a SECOND value from the loot stubs mirrors the
-- production tail-call contract (_queueTransfer -> lootNearbyFood), which
-- tests/test_carry_capacity.lua proves against the real module.
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
AutoPilot_Utils.iterateNearbySquares = function(_cx, _cy, _cz, _radius, _callback) end

AutoPilot_Home = {
    isSet            = function(_player) return false end,
    isInside         = function(_sq)     return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

dofile("42/media/lua/client/AutoPilot_Consumption.lua")
dofile("42/media/lua/client/AutoPilot_Sleep.lua")
dofile("42/media/lua/client/AutoPilot_Rest.lua")
dofile("42/media/lua/client/AutoPilot_Exercise.lua")
dofile("42/media/lua/client/AutoPilot_Needs.lua")

-- Decline training everywhere in this suite: the subject is the TAIL of the
-- chain (step 9), so every case must fall past the exercise slot.
AutoPilot_Leveler = { check = function(_p) return false end }

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

-- Capture every setDecision call with its full argument list (the stock mock
-- stub discards them).  Restored per-case is unnecessary: every case installs
-- its own capture table first.
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

-- The LAST setDecision call wins the logged line (logTick reads the pending
-- store, and every setDecision overwrites it — including the fail_reason,
-- which a later call without one clears to "").
local function lastDecision()
    return captured[#captured]
end

-- A calm player: every survival branch above step 9 declines, matching the
-- chain-tail case in tests/test_priority_logic.lua.
local function calmPlayer()
    return MockPlayer.new({
        stats = {
            HUNGER    = 0.02,
            THIRST    = 0.02,
            FATIGUE   = 0.02,
            ENDURANCE = 0.95,
        },
    })
end

-- Supplies low, so doProactiveScavenge attempts a trip (both counts under
-- SUPPLY_FOOD_MIN / SUPPLY_DRINK_MIN).
local function suppliesLow()
    AutoPilot_Inventory.getSupplyCounts = function(_player) return 0, 0 end
end

-- Fresh scavenge module state per case: the cooldown/stuck counters are
-- locals in AutoPilot_Needs.lua, so expire the cooldown by running enough
-- calm no-need cycles (a no-need cycle resets stuck and never sets the
-- cooldown; a cooldown only counts down).  SCAVENGE_COOLDOWN_CYCLES bounds
-- the number of cycles needed.
local function drainScavengeCooldown(player)
    local prevCounts = AutoPilot_Inventory.getSupplyCounts
    -- Plenty of supplies: the trip is skipped, stuck/backoff state resets.
    AutoPilot_Inventory.getSupplyCounts = function(_player) return 99, 99 end
    for _ = 1, (AutoPilot_Constants.SCAVENGE_BACKOFF_CYCLES or 1200) + 1 do
        AutoPilot_Needs.check(player)
    end
    AutoPilot_Inventory.getSupplyCounts = prevCounts
end

print("=== Scavenge telemetry: carry_full fail_reason (PR #85 follow-up) ===")

-- 1. The behaviour difference this increment ships: a refused pickup logs
--    fail_reason=carry_full where an empty area logs none.
print("\n-- Test 1: a carry-gate refusal threads fail_reason=carry_full")
do
    local player = calmPlayer()
    captureDecisions()
    drainScavengeCooldown(player)
    suppliesLow()
    AutoPilot_Inventory.lootNearbyFood  = function(_p, _r) return false, "carry_full" end
    AutoPilot_Inventory.lootNearbyDrink = function(_p, _r) return false, "carry_full" end
    captured = {}
    local result = AutoPilot_Needs.check(player)
    assert_false("the refused trip claims no cycle", result)
    local last = lastDecision()
    assert_true("a decision was recorded", last ~= nil)
    assert_eq("the last decision is scavenge", last and last.action, "scavenge")
    assert_eq("its reason is low_supplies", last and last.reason, "low_supplies")
    assert_eq("and its fail_reason is carry_full",
        last and last.fail_reason, "carry_full")
end

-- 2. Control: the SAME trip over a looted-out area carries no fail_reason.
--    (Before this increment, Tests 1 and 2 were indistinguishable.)
print("\n-- Test 2: an empty area logs the plain scavenge decision, no fail")
do
    local player = calmPlayer()
    captureDecisions()
    drainScavengeCooldown(player)
    suppliesLow()
    AutoPilot_Inventory.lootNearbyFood  = function(_p, _r) return false end
    AutoPilot_Inventory.lootNearbyDrink = function(_p, _r) return false end
    captured = {}
    local result = AutoPilot_Needs.check(player)
    assert_false("the empty trip claims no cycle", result)
    local last = lastDecision()
    assert_eq("the last decision is scavenge", last and last.action, "scavenge")
    assert_eq("no fail_reason is threaded for an empty area",
        last and last.fail_reason, nil)
end

-- 3. A successful loot still claims the cycle with the plain decision.
print("\n-- Test 3: a successful pickup is unchanged by the threading")
do
    local player = calmPlayer()
    captureDecisions()
    drainScavengeCooldown(player)
    suppliesLow()
    AutoPilot_Inventory.lootNearbyFood = function(_p, _r) return true end
    captured = {}
    local result = AutoPilot_Needs.check(player)
    assert_true("the successful trip claims the cycle", result)
    local last = lastDecision()
    assert_eq("the decision is scavenge", last and last.action, "scavenge")
    assert_eq("a successful trip carries no fail_reason",
        last and last.fail_reason, nil)
end

-- 4. The backoff behaviour is UNCHANGED: refused trips still count toward the
--    stuck limit, and a cooldown cycle threads no fail_reason (no trip ran).
print("\n-- Test 4: refusals still back off; cooldown cycles carry no fail")
do
    local player = calmPlayer()
    captureDecisions()
    drainScavengeCooldown(player)
    suppliesLow()
    AutoPilot_Inventory.lootNearbyFood  = function(_p, _r) return false, "carry_full" end
    AutoPilot_Inventory.lootNearbyDrink = function(_p, _r) return false, "carry_full" end

    -- First refused trip (fail threads), then the cooldown it sets.
    captured = {}
    AutoPilot_Needs.check(player)
    assert_eq("trip cycle: fail_reason is carry_full",
        lastDecision() and lastDecision().fail_reason, "carry_full")

    captured = {}
    AutoPilot_Needs.check(player)
    local last = lastDecision()
    assert_eq("cooldown cycle: the decision is still scavenge",
        last and last.action, "scavenge")
    assert_eq("cooldown cycle: no trip ran, so no fail_reason",
        last and last.fail_reason, nil)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== scavenge telemetry: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
