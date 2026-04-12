-- tests/test_splitscreen.lua
-- Verifies per-player isolation for AutoPilot_Map depletion, AutoPilot_Home
-- anchors, and AutoPilot_Telemetry log separation in splitscreen.
--
-- Run from the project root with standard Lua 5.1:
--   lua5.1 tests/test_splitscreen.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Stub AutoPilot_Utils ──────────────────────────────────────────────────────
AutoPilot_Utils = {
    EPSILON = 0.001,
    safeStat = function(player, charStat)
        local ok, val = pcall(function() return player:getStats():get(charStat) end)
        if ok and type(val) == "number" then return val end
        return 0
    end,
    findNearestSquare    = function(_cx, _cy, _cz, _r, _pred) return nil end,
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

-- ── Square stub ───────────────────────────────────────────────────────────────
local function makeSquare(x, y, z)
    return {
        getX = function(self) return x end,
        getY = function(self) return y end,
        getZ = function(self) return z or 0 end,
    }
end

-- ── MockPlayer with per-player number ────────────────────────────────────────
local function makePlayer(pnum)
    return MockPlayer.new({
        playerNum = pnum,
        stats   = { HUNGER = 0.10, THIRST = 0.05, ENDURANCE = 0.90, FATIGUE = 0.10 },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
    })
end

-- ── Test 1: Map depletion is per-player ──────────────────────────────────────
print("=== Splitscreen Test 1: Map depletion is per-player ===")
do
    local sq = makeSquare(10, 20, 0)
    AutoPilot_Map.resetDepleted(0)
    AutoPilot_Map.resetDepleted(1)

    AutoPilot_Map.markDepleted(sq, 0)
    assert_true("Player 0 sees depleted sq", AutoPilot_Map.isDepleted(sq, 0))
    assert_false("Player 1 does NOT see player-0 depleted sq", AutoPilot_Map.isDepleted(sq, 1))
end

-- ── Test 2: resetDepleted is per-player ──────────────────────────────────────
print("\n=== Splitscreen Test 2: resetDepleted is per-player ===")
do
    local sq = makeSquare(5, 5, 0)
    AutoPilot_Map.resetDepleted(0)
    AutoPilot_Map.resetDepleted(1)

    AutoPilot_Map.markDepleted(sq, 0)
    AutoPilot_Map.markDepleted(sq, 1)
    AutoPilot_Map.resetDepleted(0)

    assert_false("After reset player 0: sq not depleted for p0", AutoPilot_Map.isDepleted(sq, 0))
    assert_true("After reset player 0: sq still depleted for p1", AutoPilot_Map.isDepleted(sq, 1))
end

-- ── Test 3: Map getStats is per-player ───────────────────────────────────────
print("\n=== Splitscreen Test 3: Map.getStats is per-player ===")
do
    AutoPilot_Map.resetDepleted(0)
    AutoPilot_Map.resetDepleted(1)

    AutoPilot_Map.markDepleted(makeSquare(1,1,0), 0)
    AutoPilot_Map.markDepleted(makeSquare(2,2,0), 0)
    AutoPilot_Map.markDepleted(makeSquare(3,3,0), 1)

    local stats0 = AutoPilot_Map.getStats(0)
    local stats1 = AutoPilot_Map.getStats(1)
    assert_eq("Player 0 has 2 depleted squares", stats0.depleted_squares, 2)
    assert_eq("Player 1 has 1 depleted square",  stats1.depleted_squares, 1)
end

-- ── Test 4: Home anchors are per-player ──────────────────────────────────────
print("\n=== Splitscreen Test 4: Home anchors are per-player ===")
do
    -- Create two players at different positions
    local p0 = MockPlayer.new({ playerNum=0 })
    p0.getX = function(self) return 100 end
    p0.getY = function(self) return 200 end
    p0.getZ = function(self) return 0 end
    p0.getModData = function(self)
        return { AutoPilot_HomeData = { x=100, y=200, z=0, r=150 } }
    end
    p0.transmitModData = function(self) end

    local p1 = MockPlayer.new({ playerNum=1 })
    p1.getX = function(self) return 300 end
    p1.getY = function(self) return 400 end
    p1.getZ = function(self) return 0 end
    p1.getModData = function(self)
        return { AutoPilot_HomeData = { x=300, y=400, z=0, r=150 } }
    end
    p1.transmitModData = function(self) end

    AutoPilot_Home.set(p0)
    AutoPilot_Home.set(p1)

    local hx0, hy0 = AutoPilot_Home.getState(p0)
    local hx1, hy1 = AutoPilot_Home.getState(p1)
    assert_eq("Player 0 home x=100", hx0, 100)
    assert_eq("Player 1 home x=300", hx1, 300)
    assert_eq("Player 0 home y=200", hy0, 200)
    assert_eq("Player 1 home y=400", hy1, 400)
end

-- ── Test 5: Telemetry run-tick is per-player ─────────────────────────────────
print("\n=== Splitscreen Test 5: Telemetry run-tick is per-player ===")
do
    -- logTick silently handles file-write failures (pcall-wrapped) in tests.
    local p0 = makePlayer(0)
    local p1 = makePlayer(1)

    AutoPilot_Telemetry.logTick(p0, "exercise", "idle")
    AutoPilot_Telemetry.logTick(p1, "eat",      "hunger")
    AutoPilot_Telemetry.logTick(p0, "exercise", "idle")

    local tick0 = AutoPilot_Telemetry.getRunTick(p0)
    local tick1 = AutoPilot_Telemetry.getRunTick(p1)
    -- tick0 may be > 2 if earlier tests also called logTick for p0; just check monotonic.
    assert_true("Player 0 run_tick >= 2 after 2 logTick calls", tick0 >= 2)
    assert_true("Player 1 run_tick >= 1 after 1 logTick call",  tick1 >= 1)
    -- Each player's tick counter advances independently
    assert_true("Player 0 tick > Player 1 tick", tick0 > tick1)
end

-- ── Test 6: Fallback shelter is per-player ───────────────────────────────────
print("\n=== Splitscreen Test 6: Fallback shelters are per-player ===")
do
    local p0 = makePlayer(0)
    local p1 = makePlayer(1)

    local sq0 = makeSquare(10, 10, 0)
    sq0.isFree = function(self) return true end
    local sq1 = makeSquare(20, 20, 0)
    sq1.isFree = function(self) return true end

    AutoPilot_Home.addFallback(p0, sq0)
    AutoPilot_Home.addFallback(p1, sq1)

    local fb0 = AutoPilot_Home.getNearestFallback(p0)
    local fb1 = AutoPilot_Home.getNearestFallback(p1)
    assert_eq("P0 fallback x=10", fb0 and fb0:getX() or -1, 10)
    assert_eq("P1 fallback x=20", fb1 and fb1:getX() or -1, 20)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
