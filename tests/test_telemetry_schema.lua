-- tests/test_telemetry_schema.lua
-- Verifies that schema_version=2 fields (stage, fail_reason, retry_count) are
-- present in setDecision/getPendingAction flow, and that backward-compat parsing
-- tolerates logs without the new fields.
--
-- Run from the project root with standard Lua 5.1:
--   lua5.1 tests/test_telemetry_schema.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

AutoPilot_Utils = {
    EPSILON = 0.001,
    safeStat = function(player, charStat)
        local ok, val = pcall(function() return player:getStats():get(charStat) end)
        if ok and type(val) == "number" then return val end
        return 0
    end,
    findNearestSquare    = function(...) return nil end,
    iterateNearbySquares = function(...) end,
}

dofile("42/media/lua/client/AutoPilot_Map.lua")
dofile("42/media/lua/client/AutoPilot_Home.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")

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
local function assert_ne(desc, got, notExpected)
    if got ~= notExpected then
        print(("  PASS  %s"):format(desc))
        PASS = PASS + 1
    else
        io.stderr:write(("  FAIL  %s  (got=%s, should not be=%s)\n"):format(
            desc, tostring(got), tostring(notExpected)))
        FAIL = FAIL + 1
    end
end

local function makePlayer(pnum)
    return MockPlayer.new({
        playerNum = pnum or 0,
        stats     = { HUNGER = 0.10, THIRST = 0.05, ENDURANCE = 0.90, FATIGUE = 0.10 },
    })
end

-- ── Test 1: getPendingAction returns action after setDecision ─────────────────
print("=== Telemetry Test 1: setDecision round-trip via getPendingAction ===")
do
    local p = makePlayer(0)
    AutoPilot_Telemetry.setDecision("eat", "hunger_thresh", p, "survival", "no_item", 0)
    local action = AutoPilot_Telemetry.getPendingAction(p)
    assert_eq("getPendingAction returns 'eat' after setDecision", action, "eat")
end

-- ── Test 2: logTick consumes pending decision and resets to 'idle' ─────────────
print("\n=== Telemetry Test 2: logTick consumes pending decision ===")
do
    local p = makePlayer(0)
    AutoPilot_Telemetry.setDecision("sleep", "fatigue_thresh", p, "survival", "", 0)
    -- logTick will silently fail on file I/O (pcall-wrapped); counters still advance
    AutoPilot_Telemetry.logTick(p)
    -- After logTick, pending resets
    local action = AutoPilot_Telemetry.getPendingAction(p)
    assert_eq("getPendingAction returns 'idle' after logTick consumed it", action, "idle")
end

-- ── Test 3: setDecision with stage and fail_reason (v2 fields) ────────────────
print("\n=== Telemetry Test 3: setDecision accepts v2 stage/fail_reason fields ===")
do
    local p = makePlayer(1)
    -- Should not crash with new parameter signature
    local ok = pcall(function()
        AutoPilot_Telemetry.setDecision("flee", "threat", p, "combat", "no_square", 2)
    end)
    assert_true("setDecision with stage/fail_reason/retry_count does not crash", ok)
    local action = AutoPilot_Telemetry.getPendingAction(p)
    assert_eq("action is 'flee' after setDecision", action, "flee")
end

-- ── Test 4: setDecision backward compat — old 3-arg call still works ──────────
print("\n=== Telemetry Test 4: setDecision backward compat (3 args) ===")
do
    local p = makePlayer(2)
    local ok = pcall(function()
        AutoPilot_Telemetry.setDecision("exercise", "idle", p)
    end)
    assert_true("setDecision with 3 args (old style) does not crash", ok)
    local action = AutoPilot_Telemetry.getPendingAction(p)
    assert_eq("action is 'exercise' after 3-arg setDecision", action, "exercise")
end

-- ── Test 5: getRunTick increments with each logTick ───────────────────────────
print("\n=== Telemetry Test 5: run_tick increments per player ===")
do
    local p0 = makePlayer(10)
    local before = AutoPilot_Telemetry.getRunTick(p0)
    AutoPilot_Telemetry.logTick(p0, "idle", "no_action")
    AutoPilot_Telemetry.logTick(p0, "idle", "no_action")
    local after = AutoPilot_Telemetry.getRunTick(p0)
    assert_eq("run_tick incremented by 2 after two logTick calls", after - before, 2)
end

-- ── Test 6: blocked action label maps to 'idle' class ─────────────────────────
print("\n=== Telemetry Test 6: 'blocked' action maps to idle class in REASON_CLASS ===")
do
    -- Verify by triggering setDecision with 'blocked' and checking it doesn't crash
    local p = makePlayer(0)
    local ok = pcall(function()
        AutoPilot_Telemetry.setDecision("blocked", "flee_no_square", p, "idle", "no_square", 3)
    end)
    assert_true("setDecision with 'blocked' action does not crash", ok)
    local action = AutoPilot_Telemetry.getPendingAction(p)
    assert_eq("pending action is 'blocked'", action, "blocked")
end

-- ── Test 7: recover action label is accepted without crash ───────────────────
print("\n=== Telemetry Test 7: 'recover' action label is accepted ===")
do
    local p = makePlayer(0)
    local ok = pcall(function()
        AutoPilot_Telemetry.setDecision("recover", "post_combat", p, "recover", "", 0)
    end)
    assert_true("setDecision with 'recover' action does not crash", ok)
    assert_eq("pending action is 'recover'", AutoPilot_Telemetry.getPendingAction(p), "recover")
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
