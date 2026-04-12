-- tests/test_medical_logic.lua
-- Behavioral tests for AutoPilot_Medical.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_medical_logic.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants ────────────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- Additional PZ stubs needed by Medical
ISInventoryTransferAction = {
    new = function(_, _player, item, _src, _dst)
        return { type = "transfer", item = item }
    end,
}

-- BodyPartType: Medical uses getDisplayName for debug printing; mock it.
BodyPartType.getDisplayName = function(_) return "MockBodyPart" end

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
    iterateNearbySquares = function(...) end,
}

-- ── Load module under test ────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Medical.lua")

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
end

-- ── Player builder helpers ────────────────────────────────────────────────────

-- Add a usable bandage item to the player's inventory.
local function addBandageToInventory(player)
    local bandageItem = {
        getType      = function(self) return "Bandage" end,
        getName      = function(self) return "Bandage" end,
        isCanBandage = function(self) return true end,
    }
    local itemsArr = { bandageItem }
    local items = {
        size = function(self) return #itemsArr end,
        get  = function(self, i) return itemsArr[i + 1] end,
    }
    player.getInventory = function(self) return { getItems = function() return items end } end
    return player
end

-- ── Test cases ────────────────────────────────────────────────────────────────
print("=== AutoPilot_Medical Logic Tests ===")

-- 1. No wounds → check returns false, no actions queued.
print("\n-- Test 1: No wounds → check returns false")
do
    reset()
    local player = MockPlayer.new({})
    local result = AutoPilot_Medical.check(player, false)
    assert_false("check() returns false when no wounds", result)
    assert_eq("no bandage actions queued", #ISTimedActionQueue_calls, 0)
end

-- 2. hasCriticalWound: no bleeding → returns false.
print("\n-- Test 2: hasCriticalWound with no bleeding")
do
    local player = MockPlayer.new({ bleeding = false })
    assert_false("hasCriticalWound returns false when not bleeding",
        AutoPilot_Medical.hasCriticalWound(player))
end

-- 3. hasCriticalWound: actively bleeding → returns true.
print("\n-- Test 3: hasCriticalWound with bleeding")
do
    local player = MockPlayer.new({ bleeding = true })
    assert_true("hasCriticalWound returns true when bleeding",
        AutoPilot_Medical.hasCriticalWound(player))
end

-- 4. Bleeding wound + bandage in inventory → bandage action queued.
print("\n-- Test 4: Bleeding + bandage in inventory → bandage action queued")
do
    reset()
    local player = addBandageToInventory(MockPlayer.new({ bleeding = true }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check() returns true when bleeding + bandage available", result)
    local hasBandage = false
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == "bandage" then hasBandage = true end
    end
    assert_true("bandage action was queued", hasBandage)
end

-- 5. bleedingOnly=true with scratch-only wound → no treatment.
print("\n-- Test 5: bleedingOnly=true + scratch-only wound → no treatment")
do
    reset()
    local player = addBandageToInventory(MockPlayer.new({ scratched = true, bleeding = false }))
    local result = AutoPilot_Medical.check(player, true)
    assert_false("check(bleedingOnly=true) returns false for scratch-only wound", result)
end

-- 6. bleedingOnly=false with scratch wound → bandage queued.
print("\n-- Test 6: bleedingOnly=false + scratch wound → bandage queued")
do
    reset()
    local player = addBandageToInventory(MockPlayer.new({ scratched = true, bleeding = false }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check(bleedingOnly=false) returns true for scratch wound", result)
end

-- 7. getWoundSnapshot: no wounds → all zeroes / false.
print("\n-- Test 7: getWoundSnapshot with no wounds")
do
    local player = MockPlayer.new({})
    local snap = AutoPilot_Medical.getWoundSnapshot(player)
    assert_eq("bleeding count is 0",  snap.bleeding, 0)
    assert_eq("scratched count is 0", snap.scratched, 0)
    assert_false("bitten is false", snap.bitten)
    assert_eq("burnt count is 0", snap.burnt, 0)
end

-- 8. getWoundSnapshot: bleeding wound → bleeding = 1.
print("\n-- Test 8: getWoundSnapshot with bleeding wound")
do
    local player = MockPlayer.new({ bleeding = true })
    local snap = AutoPilot_Medical.getWoundSnapshot(player)
    assert_eq("bleeding count is 1", snap.bleeding, 1)
end

-- 9. getWoundSnapshot: bitten wound → bitten = true.
print("\n-- Test 9: getWoundSnapshot with bitten wound")
do
    local player = MockPlayer.new({ bitten = true })
    local snap = AutoPilot_Medical.getWoundSnapshot(player)
    assert_true("bitten is true", snap.bitten)
end

-- 10. Bleeding + no bandage anywhere → check returns false.
print("\n-- Test 10: Bleeding + no bandage → check returns false (loot needed)")
do
    reset()
    -- Empty inventory, iterateNearbySquares is a no-op in tests.
    local player = MockPlayer.new({ bleeding = true })
    local result = AutoPilot_Medical.check(player, false)
    assert_false("check() returns false when bleeding but no bandage available", result)
end

-- 11. check(): deepWounded wound treated before scratched when both present.
print("\n-- Test 11: deepWounded takes priority over scratched")
do
    reset()
    -- Both deepWounded and scratched; the mock only supports one wound type per
    -- player, but we verify that deepWounded alone is treated (no crash).
    local player = addBandageToInventory(MockPlayer.new({ deepWounded = true }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check() returns true for deepWounded wound", result)
end

-- 12. check(): burnt wound is treated when no higher-priority wound exists.
print("\n-- Test 12: Burnt wound treated when no bleed/deep/bite/scratch")
do
    reset()
    local player = addBandageToInventory(MockPlayer.new({ burnt = true }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check() returns true for burnt wound", result)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
