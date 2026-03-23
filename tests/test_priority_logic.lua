-- tests/test_priority_logic.lua
-- Dry-run behavioral tests for AutoPilot_Needs priority logic.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_priority_logic.lua
--
-- These tests load the production AutoPilot_Needs.lua against a mocked PZ
-- API surface so the priority chain can be verified without launching the game.

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants (no PZ deps; 'C' sorts first so safe to load stand-alone) ─
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Stub dependency modules ───────────────────────────────────────────────────
-- These modules are used by AutoPilot_Needs.lua. We replace them with minimal
-- stubs that the tests can reconfigure per case.

AutoPilot_LLM = {
    log = function(_msg) end,   -- silence all log output during tests
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

AutoPilot_Utils = {
    safeStat = function(player, charStat)
        local ok, val = pcall(function()
            return player:getStats():get(charStat)
        end)
        if ok and type(val) == "number" then return val end
        return 0
    end,
    -- Square iteration is a no-op in tests (getCell() returns nil).
    iterateNearbySquares = function(_cx, _cy, _cz, _radius, _callback) end,
}

AutoPilot_Home = {
    isSet        = function(_player) return false end,
    isInside     = function(_sq)     return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

-- ── Load the module under test ────────────────────────────────────────────────
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
    AutoPilot_Inventory.selectFoodByWeight = function(_player) return nil end
    AutoPilot_Inventory.getBestFood        = function(_player) return nil end
    AutoPilot_Inventory.lootNearbyFood     = function(_player) return false end
end

-- Return the action-type string of the last item queued, or nil.
local function last_action_type()
    local c = ISTimedActionQueue_calls
    if #c == 0 then return nil end
    return c[#c].type
end

-- ── Test cases ────────────────────────────────────────────────────────────────
-- Note: most tests pass skipExercise=true to AutoPilot_Needs.check() so that
-- exercise does not become the terminal action when all other needs are met.
-- The skipExercise parameter only controls the final idle→exercise step (step 8);
-- it has no effect when an earlier priority (bleeding, thirst, etc.) triggers
-- first.  Tests 6 and 11 explicitly verify skipExercise=false and =true behaviour.

print("=== AutoPilot_Needs Priority Logic Tests ===")

-- 1. Bleeding → bandage immediately (highest priority)
print("\n-- Test 1: Bleeding → bandage")
do
    reset()
    AutoPilot_Medical._bleeding = true
    local player = MockPlayer.new({
        stats = { HUNGER = 0.50, THIRST = 0.50, FATIGUE = 0.05, ENDURANCE = 0.90 },
    })
    local result = AutoPilot_Needs.check(player, true)
    assert_true("check() returns true when bleeding", result)
    assert_eq("action queued is 'bandage'", last_action_type(), "bandage")
end

-- 2. Thirst ≥ threshold → drink (no bleeding)
print("\n-- Test 2: Thirst → drink")
do
    reset()
    local drinkItem = { getName = function() return "WaterBottle" end }
    AutoPilot_Inventory.getBestDrink = function(_player) return drinkItem end
    local player = MockPlayer.new({
        stats = {
            THIRST    = 0.30,   -- above threshold (0.20)
            HUNGER    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
        },
    })
    local result = AutoPilot_Needs.check(player, true)
    assert_true("check() returns true when thirsty", result)
    -- doDrink queues an ISEatFoodAction (PZ uses this for liquids too)
    assert_eq("action queued is 'eat' (drink via ISEatFoodAction)", last_action_type(), "eat")
end

-- 3. Hunger ≥ threshold → eat (no bleeding, no thirst)
print("\n-- Test 3: Hunger → eat")
do
    reset()
    local foodItem = {
        getName    = function() return "Chips" end,
        getCalories = function() return 200 end,
    }
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem end
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.25,   -- above threshold (0.20)
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
        },
    })
    local result = AutoPilot_Needs.check(player, true)
    assert_true("check() returns true when hungry", result)
    assert_eq("action queued is 'eat'", last_action_type(), "eat")
end

-- 4. High fatigue → sleep attempt
print("\n-- Test 4: High fatigue → sleep path entered")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.80,   -- above threshold (0.70)
            ENDURANCE = 0.90,
        },
    })
    -- No bed available (getCell() returns nil), so doSleep returns false.
    -- The test verifies the sleep path was entered (no eat/drink queued).
    local result = AutoPilot_Needs.check(player, true)
    assert_false("check() returns false when fatigued but no bed found", result)
    assert_eq("no eat/drink action queued on fatigue path", last_action_type(), nil)
end

-- 5. Low endurance → rest in place
print("\n-- Test 5: Low endurance → rest")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.20,   -- below ENDURANCE_REST_MIN (0.30)
        },
        moodles = { ENDURANCE = 0 },
    })
    AutoPilot_Needs.check(player, true)
    -- No furniture found → falls back to ISSitOnGround
    assert_eq("action queued is 'rest'", last_action_type(), "rest")
end

-- 6. All needs met, skipExercise=false → exercise
print("\n-- Test 6: All needs met → exercise")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
            BOREDOM   = 0,
            SANITY    = 0,
        },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
        perks   = { Strength = 3, Fitness = 3 },
    })
    AutoPilot_Needs.check(player, false)    -- skipExercise = false
    assert_eq("action queued is 'exercise'", last_action_type(), "exercise")
end

-- 7. Bleeding takes priority over thirst
print("\n-- Test 7: Bleeding > thirst priority")
do
    reset()
    AutoPilot_Medical._bleeding = true
    local drinkItem = { getName = function() return "WaterBottle" end }
    AutoPilot_Inventory.getBestDrink = function(_player) return drinkItem end
    local player = MockPlayer.new({
        stats = {
            THIRST    = 0.50,   -- also very thirsty
            HUNGER    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
        },
    })
    local result = AutoPilot_Needs.check(player, true)
    assert_true("check() returns true when bleeding+thirsty", result)
    assert_eq("bandage beats drink (bleeding is highest priority)", last_action_type(), "bandage")
end

-- 8. shouldInterrupt: bleeding → always interrupts
print("\n-- Test 8: shouldInterrupt with bleeding")
do
    AutoPilot_Medical._bleeding = true
    local player = MockPlayer.new({ stats = { ENDURANCE = 0.90 } })
    local result = AutoPilot_Needs.shouldInterrupt(player)
    assert_true("shouldInterrupt returns true when bleeding", result)
    AutoPilot_Medical._bleeding = false
end

-- 9. shouldInterrupt: no urgent needs → does not interrupt
print("\n-- Test 9: shouldInterrupt with no urgent needs")
do
    AutoPilot_Medical._bleeding = false
    local player = MockPlayer.new({
        stats = {
            THIRST    = 0.05,
            HUNGER    = 0.05,
            ENDURANCE = 0.90,
        },
        moodles = { ENDURANCE = 0 },
    })
    local result = AutoPilot_Needs.shouldInterrupt(player)
    assert_false("shouldInterrupt returns false when all needs are satisfied", result)
end

-- 10. shouldInterrupt: critical thirst → interrupts
print("\n-- Test 10: shouldInterrupt with critical thirst")
do
    AutoPilot_Medical._bleeding = false
    local player = MockPlayer.new({
        stats = {
            THIRST    = 0.50,   -- above threshold (0.20)
            HUNGER    = 0.05,
            ENDURANCE = 0.90,
        },
    })
    local result = AutoPilot_Needs.shouldInterrupt(player)
    assert_true("shouldInterrupt returns true when thirsty", result)
end

-- 11. skipExercise=true → no exercise queued even when all needs are met
print("\n-- Test 11: skipExercise flag suppresses exercise")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
            BOREDOM   = 0,
            SANITY    = 0,
        },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
        perks   = { Strength = 3, Fitness = 3 },
    })
    local result = AutoPilot_Needs.check(player, true)  -- skipExercise = true
    assert_false("check() returns false when skipExercise=true and no needs", result)
    assert_eq("no exercise action queued", last_action_type(), nil)
end

-- 12. preferredExerciseType: lower Strength → prefer strength training
print("\n-- Test 12: preferredExerciseType selects lagging skill")
do
    local player = MockPlayer.new({
        perks = { Strength = 2, Fitness = 5 },
    })
    local pref = AutoPilot_Needs.preferredExerciseType(player)
    assert_eq("prefers strength when STR < FIT", pref, "strength")

    local player2 = MockPlayer.new({
        perks = { Strength = 5, Fitness = 2 },
    })
    local pref2 = AutoPilot_Needs.preferredExerciseType(player2)
    assert_eq("prefers fitness when FIT < STR", pref2, "fitness")

    local player3 = MockPlayer.new({
        perks = { Strength = 4, Fitness = 4 },
    })
    local pref3 = AutoPilot_Needs.preferredExerciseType(player3)
    assert_eq("returns 'either' when STR == FIT", pref3, "either")
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
