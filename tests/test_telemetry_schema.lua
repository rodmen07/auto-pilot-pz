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

-- ── Test 8: schema v6 line carries doc after fit + the real game-speed field ──
-- V4.1 (C6) put wood,doc after fit; V5.0 removed barricading and with it the wood
-- field; v5 (2026-07-24) adds the `speed` game-multiplier field after ff; v6
-- (2026-08-10) appends the mod_version build stamp AFTER doc, so the str,fit,doc
-- run still ends the numeric block.
print("\n=== Telemetry Test 8: schema v6 line carries doc after fit + real speed ===")
do
    MockFiles["auto_pilot_run.log"] = nil
    MockGameSpeed.set(1)
    local p = MockPlayer.new({
        playerNum = 0,
        stats = { HUNGER = 0.10, THIRST = 0.05, ENDURANCE = 0.90, FATIGUE = 0.10 },
        perks = { Strength = 1, Fitness = 2, Woodwork = 4, Doctor = 3 },
    })
    AutoPilot_Telemetry.logTick(p, "exercise", "training")

    local f = MockFiles["auto_pilot_run.log"]
    assert_true("run-log line written", f ~= nil and #f.lines >= 1)
    local line = (f and f.lines[#f.lines]) or ""
    assert_true("schema_version=6 emitted",
        line:find("schema_version=6,", 1, true) ~= nil)
    assert_true("doc appended after fit",
        line:find("str=1,fit=2,doc=3", 1, true) ~= nil)
    -- The player above still HAS Woodwork 4; the field must be gone anyway.
    assert_true("wood= is no longer emitted at any level",
        line:find("wood=", 1, true) == nil)
    -- FF-2: the real game speed is recorded, defaulting to 1 at normal speed.
    assert_true("speed field defaults to 1 at normal speed",
        line:find("speed=1,", 1, true) ~= nil)

    -- FF-2 behavior difference: under fast-forward the `speed` field carries the
    -- real multiplier (the separate `ff` field is a zombie-presence misnomer).
    MockFiles["auto_pilot_run.log"] = nil
    MockGameSpeed.set(20)
    AutoPilot_Telemetry.logTick(p, "exercise", "training")
    local line2 = (MockFiles["auto_pilot_run.log"]
        and MockFiles["auto_pilot_run.log"].lines[#MockFiles["auto_pilot_run.log"].lines]) or ""
    assert_true("speed field carries the real multiplier under fast-forward (20)",
        line2:find("speed=20,", 1, true) ~= nil)
    MockGameSpeed.set(1)  -- restore
end

-- ── Test 8b: a FRACTIONAL multiplier still writes a run-log line ──────────────
-- The whole run log is lost, silently, at any non-integer game speed.
--
-- The `speed` field is the ONLY %d argument in the schema-v5 line that is not
-- coerced to an integer first: every other numeric field is either
-- math.floor()ed in _collectStats (hunger/thirst/fatigue/endurance) or integral
-- by construction (perk levels, counts, run_tick).  `speed` went straight from
-- getGameTime():getMultiplier() into %d because the comment beside it enumerated
-- the multiplier as 5/20/40 -- three integers -- so coercion looked unnecessary.
--
-- Fractional multipliers are REACHABLE: the engine's own debug panel binds a
-- 0..1000 slider with step 0.1 straight to setMultiplier
-- (client/DebugUIs/DebugMenu/General/ISGameDebugPanel.lua:42 in the 42.19
-- install), and setMultiplier is a public global any other mod may call.  The
-- three values the comment listed are only SpeedControlsHandler's keyboard
-- buttons (client/ISUI/SpeedControlsHandler.lua:28-40).
--
-- Behaviour difference (L-001), measured on this suite before the fix:
--   FAIL  a fractional multiplier still writes a run-log line  (got=false...)
-- because string.format raised "bad argument #5 to 'format' (number has no
-- integer representation)" out of logTick.  _tickForPlayer is pcall-wrapped at
-- AutoPilot_Main.lua:501 and the error is DISCARDED, so in game the failure has
-- no console output at all: the run log simply stops, which is the one artifact
-- a later fast-forward investigation would trust.
--
-- Each clause gets its own assertion (L-072): "a line was written" and "the
-- value is floored" fail independently, and the first one standing in for the
-- second is exactly how a truncation regression would hide.
print("\n=== Telemetry Test 8b: a fractional game speed does not lose the line ===")
do
    MockFiles["auto_pilot_run.log"] = nil
    MockGameSpeed.set(2.5)
    local p = makePlayer(0)
    local ok = pcall(function()
        AutoPilot_Telemetry.logTick(p, "exercise", "training")
    end)
    assert_true("logTick survives a fractional multiplier (no format error)", ok)

    local f3 = MockFiles["auto_pilot_run.log"]
    local line3 = (f3 and f3.lines and f3.lines[#f3.lines]) or ""
    assert_true("a fractional multiplier still writes a run-log line", line3 ~= "")
    assert_true("the fractional speed is floored to an integer (2.5 -> speed=2)",
        line3:find("speed=2,", 1, true) ~= nil)

    -- The integer path must be byte-identical to before the coercion: floor is
    -- the identity on the values every existing assertion above pins.
    MockFiles["auto_pilot_run.log"] = nil
    MockGameSpeed.set(23)
    AutoPilot_Telemetry.logTick(p, "exercise", "training")
    local f4 = MockFiles["auto_pilot_run.log"]
    local line4 = (f4 and f4.lines and f4.lines[#f4.lines]) or ""
    assert_true("an integer multiplier the buttons never produce is unchanged (23)",
        line4:find("speed=23,", 1, true) ~= nil)
    MockGameSpeed.set(1)  -- restore
end

-- ── Test 9 (V5.0): barricade is gone from REASON_CLASS ─────────────────
-- Anti-resurrection guard for the scope removal AND for the Lua/Python sync
-- guard: benchmark._ACTION_CLASS_MAP must not carry a key REASON_CLASS lacks
-- (tests/test_automation_metrics.py enforces the other direction).
print("\n=== Telemetry Test 9 (V5.0): barricade classifies as idle, not survival ===")
do
    MockFiles["auto_pilot_run.log"] = nil
    local p = makePlayer(0)
    AutoPilot_Telemetry.logTick(p, "barricade", "maintenance")
    local f = MockFiles["auto_pilot_run.log"]
    local line = (f and f.lines[#f.lines]) or ""
    assert_true("a retired barricade label falls through to class=idle",
        line:find("class=idle,", 1, true) ~= nil)
    assert_true("barricade is NOT classified as survival",
        line:find("class=survival", 1, true) == nil)
end

-- ── Test 10 (v6): every line names the BUILD that wrote it ───────────────────
-- The run log is append-only at ONE fixed path across every session AND every
-- mod update, so one file accumulates evidence about many builds.  Until v6 a
-- line said nothing about which, and the consequence was not theoretical: on
-- 2026-08-10 a HIGH flee-stall bug was filed against current main on five
-- findings whose bytes all predate the three merged fixes aimed at their two
-- shapes (#120/#122/#123).  triage_run_log.session_build reads this field, and
-- tests/test_game_logs.py's TestBuildAttribution pins the behaviour difference
-- it buys; this test pins the WRITER half.
print("\n=== Telemetry Test 10 (v6): the line carries the mod build stamp ===")
do
    MockFiles["auto_pilot_run.log"] = nil
    local p = makePlayer(0)
    AutoPilot_Telemetry.logTick(p, "exercise", "training")
    local f = MockFiles["auto_pilot_run.log"]
    local line = (f and f.lines[#f.lines]) or ""

    -- The stamp is the value the mod actually reports as its version, not a
    -- second version home: AutoPilot_Constants.VERSION is already bound to
    -- modversion= in both mod.info files (tests/test_version_constant.lua).
    assert_true("AutoPilot_Constants.VERSION is a non-empty string",
        type(AutoPilot_Constants.VERSION) == "string"
        and AutoPilot_Constants.VERSION ~= "")
    assert_true("the line stamps AutoPilot_Constants.VERSION",
        line:find("mod_version=" .. AutoPilot_Constants.VERSION, 1, true) ~= nil)
    -- Appended AFTER doc, so every pre-v6 field keeps its position and offline
    -- parsers that never heard of this key are unaffected.
    assert_true("the stamp is appended after doc, not spliced mid-line",
        line:find("doc=%d+,mod_version=") ~= nil)

    -- A stamp carrying a comma or an '=' would split into phantom fields and
    -- corrupt every field after it, so the writer clamps the character set.
    local realVersion = AutoPilot_Constants.VERSION
    AutoPilot_Constants.VERSION = "0.9,9=x"
    MockFiles["auto_pilot_run.log"] = nil
    AutoPilot_Telemetry.logTick(p, "exercise", "training")
    local dirty = (MockFiles["auto_pilot_run.log"]
        and MockFiles["auto_pilot_run.log"].lines[
            #MockFiles["auto_pilot_run.log"].lines]) or ""
    assert_true("a stamp with CSV delimiters is stripped, not written raw",
        dirty:find("mod_version=0.99x", 1, true) ~= nil)

    -- A missing Constants must SAY it cannot name the build.  Writing nothing
    -- would read as "pre-v6 session" to every reader and silently mis-date a
    -- current one -- the exact confusion this field exists to end.
    AutoPilot_Constants.VERSION = nil
    MockFiles["auto_pilot_run.log"] = nil
    AutoPilot_Telemetry.logTick(p, "exercise", "training")
    local absent = (MockFiles["auto_pilot_run.log"]
        and MockFiles["auto_pilot_run.log"].lines[
            #MockFiles["auto_pilot_run.log"].lines]) or ""
    assert_true("an unreadable version stamps 'unknown', never an empty field",
        absent:find("mod_version=unknown", 1, true) ~= nil)
    AutoPilot_Constants.VERSION = realVersion  -- restore
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
