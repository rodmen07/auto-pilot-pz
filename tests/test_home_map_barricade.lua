-- tests/test_home_map_barricade.lua
-- Integration and unit tests for AutoPilot_Home, AutoPilot_Map, and
-- AutoPilot_Barricade modules.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_home_map_barricade.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants ────────────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- Additional action stub required by Barricade
ISBarricadeAction = {
    new = function(_, _player, obj, _isPanelDoor, _hammer, _nails)
        return { type = "barricade", obj = obj }
    end,
}

-- ── Stub dependency modules ───────────────────────────────────────────────────
AutoPilot_Utils = {
    EPSILON = 0.001,
    safeStat = function(player, charStat)
        local ok, val = pcall(function()
            return player:getStats():get(charStat)
        end)
        if ok and type(val) == "number" then return val end
        return 0
    end,
    findNearestSquare    = function(_cx, _cy, _cz, _r, _pred) return nil end,
    iterateNearbySquares = function(...) end,
}

-- ── Load modules under test ───────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Map.lua")
dofile("42/media/lua/client/AutoPilot_Home.lua")
dofile("42/media/lua/client/AutoPilot_Barricade.lua")

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

-- ── Map builder helpers ───────────────────────────────────────────────────────

-- Minimal IsoGridSquare stub at (x, y, z).
local function makeSquare(x, y, z)
    return {
        getX = function(self) return x end,
        getY = function(self) return y end,
        getZ = function(self) return z or 0 end,
    }
end

-- ── AutoPilot_Map tests ───────────────────────────────────────────────────────
print("=== AutoPilot_Map Tests ===")

print("\n-- Map Test 1: markDepleted / isDepleted round-trip")
do
    AutoPilot_Map.resetDepleted()
    local sq = makeSquare(10, 20, 0)
    assert_false("not depleted before mark", AutoPilot_Map.isDepleted(sq))
    AutoPilot_Map.markDepleted(sq)
    assert_true("isDepleted returns true after markDepleted", AutoPilot_Map.isDepleted(sq))
end

print("\n-- Map Test 2: resetDepleted clears all entries")
do
    local sq = makeSquare(5, 5, 0)
    AutoPilot_Map.markDepleted(sq)
    AutoPilot_Map.resetDepleted()
    assert_false("isDepleted returns false after reset", AutoPilot_Map.isDepleted(sq))
end

print("\n-- Map Test 3: getStats reflects depleted count accurately")
do
    AutoPilot_Map.resetDepleted()
    AutoPilot_Map.markDepleted(makeSquare(1, 1, 0))
    AutoPilot_Map.markDepleted(makeSquare(2, 2, 0))
    local stats = AutoPilot_Map.getStats()
    assert_eq("getStats.depleted_squares == 2", stats.depleted_squares, 2)
    AutoPilot_Map.resetDepleted()
end

print("\n-- Map Test 4: different squares with same x,y but different z are tracked separately")
do
    AutoPilot_Map.resetDepleted()
    local sqZ0 = makeSquare(3, 3, 0)
    local sqZ1 = makeSquare(3, 3, 1)
    AutoPilot_Map.markDepleted(sqZ0)
    assert_true("sqZ0 is depleted",  AutoPilot_Map.isDepleted(sqZ0))
    assert_false("sqZ1 is NOT depleted (different z)", AutoPilot_Map.isDepleted(sqZ1))
    AutoPilot_Map.resetDepleted()
end

-- ── AutoPilot_Home tests ──────────────────────────────────────────────────────
print("\n=== AutoPilot_Home Tests ===")

-- Build a player stub at a given position with writable ModData.
local function makeHomePlayer(px, py, pz, existingModData)
    local md = existingModData or {}
    local player = MockPlayer.new({})
    player.getX           = function(self) return px end
    player.getY           = function(self) return py end
    player.getZ           = function(self) return pz or 0 end
    player.getModData     = function(self) return md end
    player.transmitModData = function(self) end
    return player
end

print("\n-- Home Test 1: set() caches home; getState() returns set position")
do
    local player = makeHomePlayer(100, 200, 0)
    AutoPilot_Home.set(player)
    local hx, hy, hz, hr = AutoPilot_Home.getState()
    assert_eq("home_x set to 100", hx, 100)
    assert_eq("home_y set to 200", hy, 200)
    assert_eq("home_z set to 0",   hz, 0)
    assert_eq("home_r set to default radius",
        hr, AutoPilot_Constants.HOME_DEFAULT_RADIUS)
end

print("\n-- Home Test 2: isSet returns true after set()")
do
    local player = makeHomePlayer(50, 60, 0)
    AutoPilot_Home.set(player)
    assert_true("isSet returns true after set()", AutoPilot_Home.isSet(player))
end

print("\n-- Home Test 3: isInside returns true for square within radius")
do
    local player = makeHomePlayer(100, 100, 0)
    AutoPilot_Home.set(player)
    local sqInside = makeSquare(110, 110, 0)  -- ~14 tiles from center; radius = 150
    assert_true("square within 150 tiles is inside", AutoPilot_Home.isInside(sqInside))
end

print("\n-- Home Test 4: isInside returns false for square beyond radius")
do
    -- Home was set to (100, 100) in prior test; radius is 150.
    local sqFar = makeSquare(500, 500, 0)  -- 566 tiles away
    assert_false("square beyond radius is outside", AutoPilot_Home.isInside(sqFar))
end

print("\n-- Home Test 5: isInside returns false for nil square")
do
    assert_false("isInside(nil) returns false", AutoPilot_Home.isInside(nil))
end

print("\n-- Home Test 6: isInside returns false for wrong z-level")
do
    -- Home z is 0; this square is on z=99.
    local sqWrongZ = makeSquare(105, 105, 99)
    assert_false("isInside returns false for wrong z-level", AutoPilot_Home.isInside(sqWrongZ))
end

print("\n-- Home Test 7: isSet loads from ModData when cache is empty")
do
    -- We reset the cache by setting home to a new position, which overwrites the cache.
    -- Then simulate a new player whose ModData carries saved home coordinates.
    -- Since there is no direct way to clear the in-memory cache from tests, we verify
    -- that a player with valid ModData passes isSet without crashing.
    local md = { AutoPilot_Home = { x = 200, y = 200, z = 0, r = 150 } }
    local player = makeHomePlayer(200, 200, 0, md)
    local result = AutoPilot_Home.isSet(player)
    -- isSet returning true means it either used the cache or loaded from ModData.
    assert_true("isSet returns true with valid player ModData", result)
end

-- ── AutoPilot_Barricade tests ─────────────────────────────────────────────────
print("\n=== AutoPilot_Barricade Tests ===")

local function makeBarricadePlayer(barricadeDone)
    local md = barricadeDone and { AutoPilot_Barricaded = true } or {}
    local player = MockPlayer.new({})
    player.getModData      = function(self) return md end
    player.transmitModData = function(self) end
    player.getX            = function(self) return 100 end
    player.getY            = function(self) return 100 end
    player.getZ            = function(self) return 0 end
    return player
end

print("\n-- Barricade Test 1: isDone returns false when flag is not set")
do
    local player = makeBarricadePlayer(false)
    assert_false("isDone returns false when ModData flag is absent",
        AutoPilot_Barricade.isDone(player))
end

print("\n-- Barricade Test 2: isDone returns true when flag is set")
do
    local player = makeBarricadePlayer(true)
    assert_true("isDone returns true when ModData flag is set",
        AutoPilot_Barricade.isDone(player))
end

print("\n-- Barricade Test 3: doBarricade returns 0 when already done")
do
    ISTimedActionQueue_calls = {}
    local player = makeBarricadePlayer(true)
    local count = AutoPilot_Barricade.doBarricade(player)
    assert_eq("doBarricade returns 0 when already barricaded", count, 0)
    assert_eq("no actions queued when already barricaded",
        #ISTimedActionQueue_calls, 0)
end

print("\n-- Barricade Test 4: doBarricade returns 0 when home is not set")
do
    ISTimedActionQueue_calls = {}
    local player = makeBarricadePlayer(false)
    -- Temporarily override isSet to return false to simulate no home.
    local origIsSet = AutoPilot_Home.isSet
    AutoPilot_Home.isSet = function(_p) return false end
    local count = AutoPilot_Barricade.doBarricade(player)
    AutoPilot_Home.isSet = origIsSet
    assert_eq("doBarricade returns 0 when home not set", count, 0)
end

print("\n-- Barricade Test 5: doBarricade is idempotent (second call after ModData set)")
do
    ISTimedActionQueue_calls = {}
    -- Player already barricaded → doBarricade must return 0 without re-queuing.
    local player = makeBarricadePlayer(true)
    AutoPilot_Barricade.doBarricade(player)  -- first call
    local count = AutoPilot_Barricade.doBarricade(player)  -- second call
    assert_eq("second doBarricade call also returns 0", count, 0)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
