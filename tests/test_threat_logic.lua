-- tests/test_threat_logic.lua
-- Behavioral tests for AutoPilot_Threat.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_threat_logic.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants ────────────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- Extend CharacterStat with stats used by Threat's NEGATIVE_STAT_CHECKS
CharacterStat.PANIC    = "PANIC"
CharacterStat.SICKNESS = "SICKNESS"
CharacterStat.STRESS   = "STRESS"

-- Additional timed-action stub required by Threat
ISEquipWeaponAction = {
    new = function(_, player, weapon, _time, _primary)
        return { type = "equip_weapon", weapon = weapon }
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

AutoPilot_Home = {
    _homeSet = false,
    isSet    = function(_player) return AutoPilot_Home._homeSet end,
    isInside = function(_sq)     return true end,
    getState = function()        return 0, 0, 0, 150 end,
    clampSq  = function(sq, _)   return sq end,
}

AutoPilot_Medical = {
    _bleeding = false,
    hasCriticalWound = function(_player)
        return AutoPilot_Medical._bleeding
    end,
}

AutoPilot_Inventory = {
    _weapon = nil,
    getBestWeapon      = function(_player) return AutoPilot_Inventory._weapon end,
    checkAndSwapWeapon = function(_player) return false end,
}

-- ── Load module under test ────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Threat.lua")

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

local function reset()
    ISTimedActionQueue_calls = {}
    AutoPilot_Medical._bleeding = false
    AutoPilot_Inventory._weapon = nil
    AutoPilot_Home._homeSet     = false
end

-- ── World helpers ─────────────────────────────────────────────────────────────

-- Build a zombie stub at world position (x, y).
local function makeZombie(x, y)
    return {
        isDead    = function(self) return false end,
        getX      = function(self) return x end,
        getY      = function(self) return y end,
        getZ      = function(self) return 0 end,
        getSquare = function(self) return nil end,
    }
end

-- Override getCell() to return a zombie list and a zero-size grid.
local function setZombies(zombieList)
    _G.getCell = function()
        return {
            getGridSquare = function() return nil end,
            getZombieList = function()
                return {
                    size = function(self) return #zombieList end,
                    get  = function(self, i) return zombieList[i + 1] end,
                }
            end,
            getWidth  = function() return 300 end,
            getHeight = function() return 300 end,
        }
    end
end

-- Restore the no-zombie default cell.
local function clearZombies()
    _G.getCell = function()
        return {
            getGridSquare = function() return nil end,
            getZombieList = function()
                return {
                    size = function(self) return 0 end,
                    get  = function(self, _i) return nil end,
                }
            end,
            getWidth  = function() return 300 end,
            getHeight = function() return 300 end,
        }
    end
end

clearZombies()

-- ── Test cases ────────────────────────────────────────────────────────────────
print("=== AutoPilot_Threat Logic Tests ===")

-- 1. No zombies → check returns false, no actions queued.
print("\n-- Test 1: No zombies → check returns false")
do
    reset(); clearZombies()
    local player = MockPlayer.new({})
    local result = AutoPilot_Threat.check(player)
    assert_false("check() returns false with no zombies", result)
    assert_eq("no actions queued when no zombies", #ISTimedActionQueue_calls, 0)
end

-- 2. getNearbyZombies returns zombie within DETECTION_RADIUS.
print("\n-- Test 2: getNearbyZombies detects zombie within radius")
do
    reset()
    setZombies({ makeZombie(0, 5) })  -- 5 tiles away; DETECTION_RADIUS = 10
    local player = MockPlayer.new({})
    local result = AutoPilot_Threat.getNearbyZombies(player)
    assert_eq("one zombie detected within radius", #result, 1)
end

-- 3. getNearbyZombies ignores zombie beyond DETECTION_RADIUS.
print("\n-- Test 3: getNearbyZombies ignores zombie outside radius")
do
    reset()
    setZombies({ makeZombie(0, 999) })  -- far away
    local player = MockPlayer.new({})
    local result = AutoPilot_Threat.getNearbyZombies(player)
    assert_eq("zombie beyond radius not detected", #result, 0)
end

-- 4. Bleeding + zombie nearby → check returns true (flee path entered).
print("\n-- Test 4: Bleeding + zombie → check returns true")
do
    reset()
    AutoPilot_Medical._bleeding = true
    setZombies({ makeZombie(3, 3) })
    local player = MockPlayer.new({ stats = { ENDURANCE = 0.90 } })
    local result = AutoPilot_Threat.check(player)
    assert_true("check() returns true when bleeding + zombie", result)
end

-- 5. Unarmed + multiple zombies → check returns true (flee path).
print("\n-- Test 5: Unarmed + multiple zombies → check returns true")
do
    reset()
    AutoPilot_Inventory._weapon = nil
    setZombies({ makeZombie(2, 2), makeZombie(4, 4) })
    local player = MockPlayer.new({ stats = { ENDURANCE = 0.90 } })
    local result = AutoPilot_Threat.check(player)
    assert_true("check() returns true when unarmed + outnumbered", result)
end

-- 6. Many negative moodles → check returns true (flee path).
print("\n-- Test 6: Many negative moodles → check returns true")
do
    reset()
    setZombies({ makeZombie(2, 2) })
    -- Stats deliberately above all relevant thresholds (see NEGATIVE_STAT_CHECKS).
    local player = MockPlayer.new({
        stats = {
            HUNGER  = 0.50,   -- ≥ 0.40
            THIRST  = 0.50,   -- ≥ 0.40
            FATIGUE = 0.70,   -- ≥ 0.60
            PANIC   = 50,     -- ≥ 40
        },
    })
    local result = AutoPilot_Threat.check(player)
    assert_true("check() returns true with many negative moodles", result)
end

-- 7. countNegativeMoodles counts only elevated stats.
print("\n-- Test 7: countNegativeMoodles counts elevated stats correctly")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER  = 0.50,   -- ≥ 0.40 → counts
            THIRST  = 0.10,   -- < 0.40 → skipped
            FATIGUE = 0.80,   -- ≥ 0.60 → counts
        },
    })
    local count = AutoPilot_Threat.countNegativeMoodles(player)
    assert_eq("countNegativeMoodles returns 2", count, 2)
end

-- 8. countNegativeMoodles returns 0 when all stats are fine.
print("\n-- Test 8: countNegativeMoodles with all stats fine → 0")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER   = 0.05, THIRST  = 0.05, FATIGUE = 0.10,
            PANIC    = 0,    PAIN    = 0,    SICKNESS = 0,
            STRESS   = 0,    SANITY  = 0,
        },
    })
    local count = AutoPilot_Threat.countNegativeMoodles(player)
    assert_eq("countNegativeMoodles returns 0 when all fine", count, 0)
end

-- 9. forceFlee does not crash even when no walkable square is found.
print("\n-- Test 9: forceFlee does not crash with zombie and no walkable square")
do
    reset()
    setZombies({ makeZombie(2, 2) })
    local player = MockPlayer.new({})
    local ok = pcall(function() AutoPilot_Threat.forceFlee(player) end)
    assert_true("forceFlee does not crash", ok)
end

-- 10. forceFight does not crash when zombie's square is nil.
print("\n-- Test 10: forceFight does not crash with zombie that has no square")
do
    reset()
    setZombies({ makeZombie(2, 2) })
    local player = MockPlayer.new({})
    player.getPrimaryHandItem = function(self) return nil end
    local ok = pcall(function() AutoPilot_Threat.forceFight(player) end)
    assert_true("forceFight does not crash", ok)
end

-- 11. Healthy player with weapon + one zombie → fight path, check returns true.
print("\n-- Test 11: Healthy + weapon + one zombie → fight path")
do
    reset()
    AutoPilot_Inventory._weapon = { getMaxDamage = function(self) return 5 end }
    setZombies({ makeZombie(3, 3) })
    local player = MockPlayer.new({
        stats = {
            HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10,
            PANIC  = 0,    PAIN   = 0,    SICKNESS = 0,
            STRESS = 0,    SANITY = 0,
        },
    })
    player.getPrimaryHandItem = function(self) return nil end
    local result = AutoPilot_Threat.check(player)
    assert_true("check() returns true with zombie present", result)
end

-- 12. getNearbyZombies: dead zombies are not counted.
print("\n-- Test 12: getNearbyZombies ignores dead zombies")
do
    reset()
    local dead = {
        isDead    = function(self) return true end,
        getX      = function(self) return 1 end,
        getY      = function(self) return 1 end,
    }
    setZombies({ dead })
    local player = MockPlayer.new({})
    local result = AutoPilot_Threat.getNearbyZombies(player)
    assert_eq("dead zombie not counted", #result, 0)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
