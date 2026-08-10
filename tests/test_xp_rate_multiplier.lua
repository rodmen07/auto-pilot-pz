-- tests/test_xp_rate_multiplier.lua
-- V6.2 C2 (FF-4): multiplier-honest XP/hr under fast-forward (approved with
-- defaults 2026-08-01, docs/EXPANSION_PROPOSAL_V6_2.md section 3).
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- Before this change AutoPilot_XP.ratePerHour divided the XP delta by RAW
-- wall-clock time, so the F11 rate and ETA swung with game speed: the same
-- character doing the same training read the multiplier's worth of extra
-- XP/hr the moment the player fast-forwarded.  (This line read *"5/20/40x
-- the XP/hr"* until 2026-08-10 -- the multiplier is an arbitrary positive
-- number, see Test 6.)  Display-only (sole consumer AutoPilot_UI:218, the
-- F11 perk line; re-verified by grep this run), but dishonest.
--
-- The fix accumulates elapsed real time SCALED by getGameTime():getMultiplier()
-- (the same verified call, and the same guard shape, as AutoPilot_Main's FF-1
-- cadence fix) and divides by THAT.  Two properties, both pinned here:
--   1. BEHAVIOUR DIFFERENCE: the same XP delta over the same real window
--      reports a multiplier-honest rate at speed 5 (and 40), where the
--      pre-fix wall-clock formula reports the inflated number.
--   2. UNCHANGED AT 1x: at speed 1 the scaled clock equals the wall clock,
--      so every number matches the pre-fix formula exactly.
-- The sample WINDOW still prunes on raw wall-clock ms (sleep's game-time
-- jump must not flush it; a fast-forward must not either), pinned by Test 4.
--
-- New test logic lives in its own file rather than growing
-- tests/test_priority_logic.lua (preflight C10 flags it at 2600+ lines).
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_xp_rate_multiplier.lua

-- ── Load mocks (same harness shape as tests/test_leveler_metrics.lua) ─────────
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")
dofile("42/media/lua/client/AutoPilot_XP.lua")

local PASS, FAIL = 0, 0

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

local function assert_true(desc, val) assert_eq(desc, not not val, true) end

local function assert_near(desc, got, expected, eps)
    eps = eps or 0.001
    if type(got) == "number" and math.abs(got - expected) <= eps then
        print(("  PASS  %s"):format(desc))
        PASS = PASS + 1
    else
        io.stderr:write(("  FAIL  %s  (got=%s, expected=%s)\n"):format(
            desc, tostring(got), tostring(expected)))
        FAIL = FAIL + 1
    end
end

-- Shared scenario: +10 XP over 6 real minutes (inside the 10-minute window).
-- Pre-fix wall-clock formula: 10 * 3600000 / 360000 = 100 XP/hr, the exact
-- number tests/test_leveler_metrics.lua XP Test 2 has pinned since V3.0.
local SIX_MIN = 6 * 60 * 1000
local WALL_CLOCK_RATE = 10 * 3600000 / SIX_MIN   -- 100

local function runScenario(speed)
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    MockGameSpeed.set(speed)
    local p = MockPlayer.new({})
    p._xp.Strength = 0
    AutoPilot_XP.sample(p, "Strength")
    MockRealTime.advance(SIX_MIN)
    p._xp.Strength = 10
    AutoPilot_XP.sample(p, "Strength")
    return p
end

print("=== FF-4 Test 1: speed 1 stays exactly the pre-fix wall-clock rate ===")
do
    local p = runScenario(1)
    assert_near("rate at 1x = 100 XP/hour (pre-fix number, unchanged)",
        AutoPilot_XP.ratePerHour(p, "Strength"), WALL_CLOCK_RATE, 0.001)
    local m = AutoPilot_XP.getMetrics(p, "Strength")
    -- level 0 -> next threshold 100 total; 90 remaining at 100/hr = 0.9 h
    assert_near("etaHours at 1x = 0.9 (unchanged)", m.etaHours, 0.9, 0.001)
    MockGameSpeed.set(1)
end

print("\n=== FF-4 Test 2: BEHAVIOUR DIFFERENCE — speed 5 divides by scaled time ===")
do
    local p = runScenario(5)
    local rate = AutoPilot_XP.ratePerHour(p, "Strength")
    -- Same +10 XP, same 6 real minutes, but each real ms counted 5x:
    -- 10 * 3600000 / 1800000 = 20 XP/hr.
    assert_near("rate at 5x = 20 XP/hour (multiplier-honest)", rate, 20, 0.001)
    assert_true("rate at 5x differs from the pre-fix wall-clock number",
        math.abs(rate - WALL_CLOCK_RATE) > 1)
    local m = AutoPilot_XP.getMetrics(p, "Strength")
    -- 90 XP remaining at 20/hr = 4.5 scaled hours; eta stays consistent
    -- with the honest rate rather than mixing the two clocks.
    assert_near("etaHours at 5x = xpToNext / honest rate", m.etaHours, 4.5, 0.001)
    MockGameSpeed.set(1)
end

print("\n=== FF-4 Test 3: a mid-window speed change is attributed per interval ===")
do
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    MockGameSpeed.set(1)
    local p = MockPlayer.new({})
    p._xp.Strength = 0
    AutoPilot_XP.sample(p, "Strength")
    MockRealTime.advance(3 * 60 * 1000)          -- 3 real min at 1x = 180000
    p._xp.Strength = 5
    AutoPilot_XP.sample(p, "Strength")
    MockGameSpeed.set(5)
    MockRealTime.advance(3 * 60 * 1000)          -- 3 real min at 5x = 900000
    p._xp.Strength = 10
    AutoPilot_XP.sample(p, "Strength")
    -- 10 XP over 180000 + 900000 = 1080000 scaled ms -> 33.333 XP/hr.
    assert_near("rate spans both intervals honestly",
        AutoPilot_XP.ratePerHour(p, "Strength"), 10 * 3600000 / 1080000, 0.001)
    MockGameSpeed.set(1)
end

print("\n=== FF-4 Test 4: the window still prunes on RAW wall-clock time ===")
do
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    MockGameSpeed.set(40)
    local p = MockPlayer.new({})
    p._xp.Strength = 0
    AutoPilot_XP.sample(p, "Strength")
    MockRealTime.advance(SIX_MIN)                 -- 6 REAL min; 240 scaled min
    p._xp.Strength = 10
    AutoPilot_XP.sample(p, "Strength")
    -- 6 real minutes is INSIDE the 10-minute window even though the scaled
    -- elapsed (14,400,000 ms) is far beyond it: samples must be KEPT, and the
    -- rate is the honest 10 * 3600000 / 14400000 = 2.5 XP/hr.
    assert_near("samples kept at 40x: honest rate 2.5 XP/hr",
        AutoPilot_XP.ratePerHour(p, "Strength"), 2.5, 0.001)
    -- And samples DO age out at the same real pace as before the fix:
    MockRealTime.advance(30 * 60 * 1000)
    AutoPilot_XP.sample(p, "Strength")
    assert_eq("stale window still prunes to zero rate",
        AutoPilot_XP.ratePerHour(p, "Strength"), 0)
    MockGameSpeed.set(1)
end

print("\n=== FF-4 Test 5: guard shape — bad multiplier degrades to wall clock ===")
do
    -- (a) multiplier 0 (paused-shaped value): clamped to 1, exactly Main's
    -- FF-1 guard, so the accumulator can never freeze or corrupt.
    local p = runScenario(0)
    assert_near("multiplier 0 clamps to 1 (wall-clock rate)",
        AutoPilot_XP.ratePerHour(p, "Strength"), WALL_CLOCK_RATE, 0.001)
    MockGameSpeed.set(1)

    -- (b) getGameTime unavailable: pcall default keeps mult = 1.  Restore the
    -- real function afterwards (same save/restore idiom as the leveler suite).
    local savedGetGameTime = getGameTime
    getGameTime = function() error("no game time surface") end
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    local q = MockPlayer.new({})
    q._xp.Strength = 0
    AutoPilot_XP.sample(q, "Strength")
    MockRealTime.advance(SIX_MIN)
    q._xp.Strength = 10
    AutoPilot_XP.sample(q, "Strength")
    assert_near("absent multiplier surface degrades to wall-clock rate",
        AutoPilot_XP.ratePerHour(q, "Strength"), WALL_CLOCK_RATE, 0.001)
    getGameTime = savedGetGameTime
end

print("\n=== FF-4 Test 6: a FRACTIONAL multiplier scales the rate like any other ===")
do
    -- Sibling sweep, 2026-08-10.  Every speed this suite sampled -- 1, 5, 40 --
    -- is a member of the 5/20/40 set the comments enumerated, and 0/nil are the
    -- guard's degenerate cases, so the whole suite sampled from a claim rather
    -- than from the distribution (L-050).  The real multiplier is an arbitrary
    -- positive NUMBER: the engine's debug panel binds a 0..1000 slider with
    -- step 0.1 to setMultiplier (client/DebugUIs/DebugMenu/General/
    -- ISGameDebugPanel.lua:42), so a non-integer speed is reachable in game.
    --
    -- This arm is CLEAN and is pinned as such: _speedMult only clamps < 1 and
    -- the accumulator is float math, so 2.5 needs no coercion here.  The same
    -- sweep found the third consumer broken -- AutoPilot_Telemetry formatted the
    -- multiplier with %d and lost the entire run-log line at any fractional
    -- speed (fixed the same run; tests/test_telemetry_schema.lua Test 8b).
    local p = runScenario(2.5)
    -- +10 XP over 6 real minutes at 2.5x = 900000 scaled ms -> 40 XP/hr.
    assert_near("rate at 2.5x = 40 XP/hour (fractional, multiplier-honest)",
        AutoPilot_XP.ratePerHour(p, "Strength"), 40, 0.001)
    -- Its own assertion (L-072): the honest number must also differ from the
    -- pre-fix wall-clock one, or a silently-truncated 2 would still read as 50.
    assert_true("2.5x is not truncated to 2x (a floored multiplier gives 50)",
        math.abs(AutoPilot_XP.ratePerHour(p, "Strength") - 50) > 1)
    MockGameSpeed.set(1)
end

-- ── Summary ──────────────────────────────────────────────────────────────────
print(string.format("\n=== FF4RateMultiplier: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
