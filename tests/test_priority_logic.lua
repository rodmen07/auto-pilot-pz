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

-- ── Test cases ────────────────────────────────────────────────────────────────
-- Note: AutoPilot_Needs.check(player) takes the player ONLY.  An extra second
-- argument some older cases still pass (a since-removed "skipExercise" flag) is
-- ignored by production, so check() always falls through to the idle→exercise
-- step when no earlier priority triggers (tests 6 and 11 assert exactly that).
-- A case proving a need branch did NOT fire must therefore assert on that
-- branch's action type, not on an empty queue (see count_action_type below).

print("=== AutoPilot_Needs Priority Logic Tests ===")

-- 1. Bleeding → bandage immediately (highest priority)
print("\n-- Test 1: Bleeding → bandage")
do
    reset()
    AutoPilot_Medical._bleeding = true
    local player = MockPlayer.new({
        stats = { HUNGER = 0.50, THIRST = 0.50, FATIGUE = 0.05, ENDURANCE = 0.90 },
    })
    local result = AutoPilot_Needs.check(player)
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
    local result = AutoPilot_Needs.check(player)
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
    local result = AutoPilot_Needs.check(player)
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
    local result = AutoPilot_Needs.check(player)
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
    AutoPilot_Needs.check(player)
    -- No furniture found → falls back to ISSitOnGround
    assert_eq("action queued is 'rest'", last_action_type(), "rest")
end

-- 6. All needs met → exercise
print("\n-- Test 6: All needs met → exercise")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            -- V5.7: full endurance.  The stand-up target moved to 0.95, so a
            -- character parked at 0.90 is legitimately still mid-rest; these
            -- two tests are about the "nothing is wrong at all" case.
            ENDURANCE = 1.00,
            BOREDOM   = 0,
            SANITY    = 0,
        },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
        perks   = { Strength = 3, Fitness = 3 },
    })
    AutoPilot_Needs.check(player)    -- skipExercise = false
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
    local result = AutoPilot_Needs.check(player)
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

-- 11. check() with no urgent needs queues exercise
print("\n-- Test 11: check() queues exercise when no urgent needs")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            -- V5.7: full endurance.  The stand-up target moved to 0.95, so a
            -- character parked at 0.90 is legitimately still mid-rest; these
            -- two tests are about the "nothing is wrong at all" case.
            ENDURANCE = 1.00,
            BOREDOM   = 0,
            SANITY    = 0,
        },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
        perks   = { Strength = 3, Fitness = 3 },
    })
    local result = AutoPilot_Needs.check(player)
    assert_true("check() returns true when no urgent needs and exercise queued", result)
    assert_eq("exercise action queued", last_action_type(), "exercise")
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

-- 13. Hunger path should tolerate missing getBestFoodForHunger helper
print("\n-- Test 13: Hunger fallback when getBestFoodForHunger is missing")
do
    reset()
    AutoPilot_Inventory.getBestFoodForHunger = nil
    local foodItem = {
        getName = function() return "Canned Beans" end,
        getCalories = function() return 400 end,
    }
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem end
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.35,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
        },
    })
    local result = AutoPilot_Needs.check(player)
    assert_true("check() still returns true when helper is missing", result)
    assert_eq("fallback food selection queues eat", last_action_type(), "eat")
end

-- 14. Missing bodyTemperature helper should not crash needs check
print("\n-- Test 14: Missing bodyTemperature helper")
do
    reset()
    AutoPilot_Inventory.bodyTemperature = nil
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
        perks = { Strength = 4, Fitness = 4 },
    })
    local result = AutoPilot_Needs.check(player)
    assert_true("check() succeeds when bodyTemperature helper is missing", result)
end

-- 15. Pain + fatigue should queue medical treatment before bed search
print("\n-- Test 15: Painful fatigue queues medical treatment")
do
    reset()
    local oldCheck = AutoPilot_Medical.check
    AutoPilot_Medical.check = function(_player, bleedingOnly)
        if bleedingOnly then return false end
        table.insert(ISTimedActionQueue_calls, { type = "bandage" })
        return true
    end
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.85,
            ENDURANCE = 0.90,
            PAIN      = 80,
        },
    })
    local result = AutoPilot_Needs.check(player)
    assert_true("check() returns true when pain relief treatment is queued", result)
    assert_eq("medical treatment is queued before sleep", last_action_type(), "bandage")
    AutoPilot_Medical.check = oldCheck
end

-- 16. Pain + fatigue should consume painkiller if medical does not queue treatment
print("\n-- Test 16: Painful fatigue uses painkiller fallback")
do
    reset()
    local oldCheck = AutoPilot_Medical.check
    AutoPilot_Medical.check = function(_player, _bleedingOnly) return false end

    local pill = {
        getType = function() return "Painkillers" end,
        getName = function() return "Painkillers" end,
    }
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.90,
            ENDURANCE = 0.90,
            PAIN      = 95,
        },
    })
    local inv = {
        getItems = function(self) return makeArray({ pill }) end,
    }
    player.getInventory = function(self) return inv end

    local result = AutoPilot_Needs.check(player)
    assert_true("check() returns true when painkiller fallback is used", result)
    assert_eq("painkiller fallback queues eat action", last_action_type(), "eat")
    AutoPilot_Medical.check = oldCheck
end

-- ── Regression: Rest-cooldown gating ─────────────────────────────────────────
-- After rest executes, a cooldown prevents the rest path from re-triggering on
-- the very next evaluation cycle.  This prevents oscillation where the bot
-- repeatedly stands up and sits down every tick.
print("\n-- Test 17: Rest cooldown prevents immediate re-trigger")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.10,  -- not fatigued enough to sleep
            ENDURANCE = 0.20,  -- below ENDURANCE_REST_MIN (0.30) → triggers rest
        },
    })
    -- First check should trigger rest.
    local result1 = AutoPilot_Needs.check(player)
    assert_true("first check triggers rest when endurance is low", result1)
    -- Immediately call again without advancing the clock — cooldown is active.
    -- The rest path should be blocked, and check() should fall through to exercise
    -- (which defaults to false when skipExercise=true).
    local result2 = AutoPilot_Needs.check(player, true)
    -- result2 may be false (cooldown blocks rest, exercise skipped) or true if
    -- another need fires — either way it must not crash.
    local ok = pcall(function() AutoPilot_Needs.check(player, true) end)
    assert_true("repeated check during rest cooldown does not crash", ok)
end

-- ── Regression: Supply-run trigger after empty loot cycles ───────────────────
-- When the bot fails to find food/drink for SUPPLY_RUN_TRIGGER consecutive
-- loot cycles, it should expand its search radius and call supplyRunLoot.
print("\n-- Test 18: Supply run triggered after consecutive empty loot cycles")
do
    reset()
    local supplyRunCalled = false
    AutoPilot_Inventory.supplyRunLoot = function(_player, _pred)
        supplyRunCalled = true
    end
    -- Stub lootNearbyFood to always fail so empty-cycle counter increments.
    AutoPilot_Inventory.lootNearbyFood = function(_player) return false end
    AutoPilot_Inventory.getBestFood    = function(_player) return nil end
    local player = MockPlayer.new({
        stats = { HUNGER = 0.30, THIRST = 0.05, FATIGUE = 0.05, ENDURANCE = 0.90 },
    })
    -- Fire enough hunger checks to exceed SUPPLY_RUN_TRIGGER (5).
    -- Each call: getBestFood=nil, lootNearbyFood=false → empty cycle.
    for _ = 1, AutoPilot_Constants.SUPPLY_RUN_TRIGGER + 1 do
        MockTime.advance(120000)   -- advance clock past cooldowns each cycle
        AutoPilot_Needs.check(player)
    end
    assert_true("supplyRunLoot called after exceeding SUPPLY_RUN_TRIGGER empty cycles",
        supplyRunCalled)
    -- Restore stubs.
    AutoPilot_Inventory.supplyRunLoot  = function(_player, _pred) end
    AutoPilot_Inventory.lootNearbyFood = function(_player) return false end
end

-- ── Regression: shouldInterrupt returns false when no urgent need ─────────────
print("\n-- Test 19: shouldInterrupt returns false with all stats fine")
do
    reset()
    local player = MockPlayer.new({
        stats = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10, ENDURANCE = 0.90 },
    })
    local result = AutoPilot_Needs.shouldInterrupt(player)
    assert_false("shouldInterrupt returns false when all stats are fine", result)
end

-- ── Regression: shouldInterrupt returns true when bleeding ───────────────────
print("\n-- Test 20: shouldInterrupt returns true when bleeding")
do
    reset()
    AutoPilot_Medical._bleeding = true
    local player = MockPlayer.new({
        stats = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10, ENDURANCE = 0.90 },
    })
    local result = AutoPilot_Needs.shouldInterrupt(player)
    assert_true("shouldInterrupt returns true when bleeding", result)
end

-- ── New: clothing adjustment propagates true ──────────────────────────────────
-- adjustClothing returning true must cause check() to return true so the main
-- loop records the action and sets a cooldown.
print("\n-- Test 21: adjustClothing returning true causes check() to return true")
do
    reset()
    AutoPilot_Inventory.adjustClothing = function(_player) return true end
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
    })
    local result = AutoPilot_Needs.check(player, true)  -- skipExercise=true
    assert_true("check() returns true when adjustClothing fires", result)
    AutoPilot_Inventory.adjustClothing = function(_player) return false end
end

-- ── New: supply-run counters are independent (food vs drink) ──────────────────
-- Incrementing the drink counter must not trigger the food supply-run and
-- vice versa.
print("\n-- Test 22: Drink empty cycles do not trigger food supply run")
do
    reset()
    local foodSupplyRunCalled  = false
    local drinkSupplyRunCalled = false
    AutoPilot_Inventory.supplyRunLoot = function(_player, pred)
        -- Determine which type of supply run by probing the predicate on a
        -- synthetic item that has calories but no thirst reduction.
        local calorieOnlyItem = {
            isFood        = function() return true  end,
            isRotten      = function() return false end,
            getCalories   = function() return 200   end,
            getThirstChange = function() return 0   end,  -- no thirst benefit
        }
        if pred(calorieOnlyItem) then
            foodSupplyRunCalled = true
        else
            drinkSupplyRunCalled = true
        end
    end
    AutoPilot_Inventory.lootNearbyDrink = function(_player) return false end
    AutoPilot_Inventory.findWaterSource = function(_player) return nil   end
    AutoPilot_Inventory.getBestDrink    = function(_player) return nil   end
    -- Hungry = fine; only thirsty.
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,   -- NOT hungry — only drink path fires
            THIRST    = 0.30,   -- triggers doDrink
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
        },
    })
    -- Drive drink empty cycles past the trigger threshold.
    for _ = 1, AutoPilot_Constants.SUPPLY_RUN_TRIGGER + 1 do
        MockTime.advance(120000)
        AutoPilot_Needs.check(player)
    end
    assert_true("drink empty cycles trigger drink supply run", drinkSupplyRunCalled)
    assert_false("drink empty cycles do NOT trigger food supply run", foodSupplyRunCalled)
    -- Restore stubs.
    AutoPilot_Inventory.supplyRunLoot   = function(_player, _pred) end
    AutoPilot_Inventory.lootNearbyDrink = function(_player) return false end
end

-- ── New: boredom preference order (tasty food > read > outside) ───────────────
print("\n-- Test 23: Boredom — tasty food preferred over reading when unhappy")
do
    reset()
    local tastyFood = {
        getName   = function() return "Cake" end,
        getCalories = function() return 500 end,
    }
    AutoPilot_Inventory.preferTastyFood = function(_player) return tastyFood end
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
            BOREDOM   = 50,  -- above threshold
            SANITY    = 0,
        },
        moodles = {
            ENDURANCE = 0,
            Unhappy   = AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD,
        },
    })
    local result = AutoPilot_Needs.check(player, true)  -- skipExercise=true
    assert_true("check() returns true when bored+unhappy and tasty food available", result)
    assert_eq("action queued is 'eat' (tasty food for unhappiness)", last_action_type(), "eat")
    AutoPilot_Inventory.preferTastyFood = function(_player) return nil end
end

-- ── Exercise XP-fatigue detection (V3.2) ─────────────────────────────────────
-- PZ silently drops a repeated exercise's XP to ~zero; the mod detects that
-- by measuring the XP a completed set produced and rotates / pauses.

local FULL_SET_MS = AutoPilot_Constants.EXERCISE_MINUTES * 60000

local function exercisePlayer()
    return MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                    ENDURANCE = 0.90 },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
    })
end

print("\n-- Test 24: productive exercise keeps repeating")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)   -- fresh window, clears prior fatigue
    local p = exercisePlayer()
    assert_true("first fitness set queues",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("fitness focus starts with squats",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "squats")

    MockTime.advance(FULL_SET_MS)       -- full set elapsed...
    p._xp.Fitness = (p._xp.Fitness or 0) + 12   -- ...and it produced XP
    assert_true("productive set repeats",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("still squats while productive",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "squats")
end

print("\n-- Test 25: zero-XP set rotates to the next exercise in the pool")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    local p = exercisePlayer()
    assert_true("squat set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    MockTime.advance(FULL_SET_MS)
    -- no XP gained -> squats fatigued -> sit-ups take over
    assert_true("fatigued squats fall back to sit-ups",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("second set is situp",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "situp")
end

print("\n-- Test 26: single-exercise pool pauses training when fatigued")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    local p = exercisePlayer()
    assert_true("push-up set queues", AutoPilot_Needs.trainExercise(p, "strength"))
    MockTime.advance(FULL_SET_MS)
    local before = #ISTimedActionQueue_calls
    assert_false("zero-XP push-ups pause strength training",
        AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("nothing queued while paused", #ISTimedActionQueue_calls, before)

    -- After the recovery window the exercise is retried.
    MockTime.advance(AutoPilot_Constants.EXERCISE_FATIGUE_RECOVERY_MS + 60000)
    assert_true("push-ups retried after recovery window",
        AutoPilot_Needs.trainExercise(p, "strength"))
end

print("\n-- Test 27: a player-cancelled set backs off and is not judged as fatigue")
do
    -- V4.5 semantics: a mod-queued set that vanishes from the queue well
    -- short of a full set, without the mod clearing it itself, is a PLAYER
    -- CANCEL.  Training must back off (never bulldoze the cancel), and the
    -- aborted set must not be judged as XP-fatigue.
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    assert_true("set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))   -- cancelled early
    local before = #ISTimedActionQueue_calls
    assert_false("cancelled set does NOT requeue immediately (backoff)",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("nothing queued during the backoff window",
        #ISTimedActionQueue_calls, before)
    assert_true("panel status reports the backoff",
        AutoPilot_Needs.getExerciseStatus().outcome:find("backing off", 1, true)
            ~= nil)
    -- Backoff holds mid-window...
    MockTime.advance(math.floor(
        AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES * 60000 / 2))
    assert_false("backoff still holds halfway through the window",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    -- ...then releases, and the cancelled set was NOT marked XP-fatigued:
    -- squats queue again instead of rotating to sit-ups.
    MockTime.advance(math.floor(
        AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES * 60000 / 2) + 60000)
    assert_true("training resumes after the backoff window",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("still squats (cancel was not judged as XP-fatigue)",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "squats")
end

print("\n-- Test 28: equipment exercises lead the strength pool when gear is carried")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    local p = MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                    ENDURANCE = 0.90 },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
        hasItems = true,   -- inventory:contains(...) reports gear carried
    })
    assert_true("strength set queues with gear",
        AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("dumbbell press picked over push-ups (1.8x exercise)",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType,
        "dumbbellpress")
end

print("\n-- Test 29: without gear the strength pool falls back to push-ups")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    local p = MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                    ENDURANCE = 0.90 },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
        hasItems = false,
    })
    assert_true("strength set queues without gear",
        AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("push-ups picked when no equipment is carried",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "pushups")
end

-- ── V4.5: intervention backoff + mod-action ownership lifecycle ──────────────
-- The mock's in-game day never rolls over, so _exerciseSetsToday accumulates
-- across the whole suite.  V4.6 made 0 (unlimited) the default, so the
-- daily-count gate cannot shadow what these tests assert; pin it anyway so
-- the intent survives a future default change.
AutoPilot_Constants.EXERCISE_DAILY_CAP = 0

print("\n-- Test 30: mod-queued sets are tagged; consuming the record untags")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    assert_true("set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local action = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_true("queued exercise is tagged as mod-owned",
        AutoPilot_Utils.isModAction(action))
    assert_false("an arbitrary foreign action is NOT mod-owned",
        AutoPilot_Utils.isModAction({ Type = "ISFitnessAction" }))
    -- The set vanishes early (mock queue reads empty): the detector consumes
    -- the record, untags the action, and engages the backoff.
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))
    assert_false("early vanish backs training off",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_false("consumed set is untagged (no ownership leak)",
        AutoPilot_Utils.isModAction(action))
    AutoPilot_Needs.resetInterventionForTest()
end

print("\n-- Test 31: a mod-initiated clear is NOT misread as a player cancel")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    assert_true("set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local action = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    -- Main clears the mod's own exercise (urgent need / threat / thrash)
    -- and notifies; the early vanish must then NOT trigger the backoff.
    AutoPilot_Needs.noteModExerciseCleared()
    assert_false("notification untagged the cleared set",
        AutoPilot_Utils.isModAction(action))
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))
    local before = #ISTimedActionQueue_calls
    assert_true("training re-queues immediately after a MOD-initiated clear",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("a new set was queued", #ISTimedActionQueue_calls, before + 1)
end

print("\n-- Test 32: F10 panic stop engages the backoff immediately")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    AutoPilot_Needs.notePanicStop()
    assert_false("training declines right after the panic stop",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_true("panel status reports the backoff",
        AutoPilot_Needs.getExerciseStatus().outcome:find("backing off", 1, true)
            ~= nil)
    MockTime.advance(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES * 60000
        + 60000)
    assert_true("training resumes after the panic-stop window",
        AutoPilot_Needs.trainExercise(p, "fitness"))
end

print("\n-- Test 33: an observed FOREIGN exercise holds training off")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    -- Main reports a manual exercise as the running action each busy cycle.
    AutoPilot_Needs.noteForeignExercise(p)
    local before = #ISTimedActionQueue_calls
    assert_false("training yields while the manual exercise is observed",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("nothing queued over the manual session",
        #ISTimedActionQueue_calls, before)
    MockTime.advance(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES * 60000
        + 60000)
    assert_true("training resumes one full window after the last observation",
        AutoPilot_Needs.trainExercise(p, "fitness"))
end

print("\n-- Test 34: a set still in the queue is not judged at all")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    assert_true("set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local action = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    -- Simulate the engine still running the set: the queue contains it.
    local origGetQueue = ISTimedActionQueue.getTimedActionQueue
    ISTimedActionQueue.getTimedActionQueue = function(_p)
        return { queue = { action } }
    end
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))
    AutoPilot_Needs.trainExercise(p, "fitness")
    assert_true("no backoff while the set is still queued (record intact)",
        AutoPilot_Needs.getExerciseStatus().outcome:find("backing off", 1, true)
            == nil)
    assert_true("the running set stays tagged as mod-owned",
        AutoPilot_Utils.isModAction(action))
    ISTimedActionQueue.getTimedActionQueue = origGetQueue
    AutoPilot_Needs.resetInterventionForTest()
end

print("\n-- Test 35: a Lua reload starts an empty ownership registry")
do
    local action = AutoPilot_Utils.tagModAction({ Type = "ISFitnessAction" })
    assert_true("tagged before the reload", AutoPilot_Utils.isModAction(action))
    -- An MP server join re-executes all mod Lua; re-dofile the real module
    -- exactly as the engine would.
    dofile("42/media/lua/client/AutoPilot_Utils.lua")
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, _callback) end
    assert_false("pre-reload tag is gone: the action now reads FOREIGN",
        AutoPilot_Utils.isModAction(action))
end

print("\n-- Test 36: a pending set from a dead character is discarded silently")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local pA = exercisePlayer()
    assert_true("character A queues a set",
        AutoPilot_Needs.trainExercise(pA, "fitness"))
    MockTime.advance(math.floor(FULL_SET_MS * 0.1))
    -- Character A dies; the respawned character B trains: A's early-vanished
    -- set must NOT back B's training off (the who-guard).
    local pB = exercisePlayer()
    local before = #ISTimedActionQueue_calls
    assert_true("character B trains immediately (no cross-character backoff)",
        AutoPilot_Needs.trainExercise(pB, "fitness"))
    assert_eq("a new set was queued for B", #ISTimedActionQueue_calls,
        before + 1)
end

print("\n-- Test 37: backoff 0 disables the intervention hold entirely")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local savedBackoff = AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES
    AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES = 0
    local p = exercisePlayer()
    AutoPilot_Needs.notePanicStop()
    assert_true("with backoff 0 training never yields",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES = savedBackoff
    AutoPilot_Needs.resetInterventionForTest()
end

-- ── V4.6: XP gain is the limiter; the daily set cap is an opt-in ceiling ─────
-- User request: "Exercise should be capped by experience gain.  Meaning only
-- should stop when stop gaining xp from doing a given exercise."  So a cap of
-- 0 means unlimited and the XP-productivity detector is what halts training;
-- a cap > 0 stays available as a hard safety ceiling.

--- Run one productive set: a full-length set that actually gained XP, which
--- is what the XP-productivity gate wants to see before allowing the next.
local function productiveSet(p, gain)
    MockTime.advance(FULL_SET_MS)
    p._xp.Fitness = (p._xp.Fitness or 0) + (gain or 12)
    return AutoPilot_Needs.trainExercise(p, "fitness")
end

print("\n-- Test 38 (V4.6): cap 0 never halts training, at any set count")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
    local p = exercisePlayer()
    -- V5.7: the counter is per-character now, so a brand new player object
    -- zeroes it.  Establish ownership first, then take the baseline through
    -- the same character the 50 sets are about to run on.
    AutoPilot_Needs.syncSetsCounterForTest(p)
    local startCount = AutoPilot_Needs.getExerciseSetsToday()
    assert_eq("a fresh character starts the day on zero sets", startCount, 0)
    assert_true("first set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local blockedAt = nil
    for i = 2, 50 do
        if not productiveSet(p) then
            blockedAt = i
            break
        end
    end
    assert_eq("50 productive sets in one day, none blocked by a count",
        blockedAt, nil)
    assert_eq("every one of the 50 sets was really queued",
        #ISTimedActionQueue_calls, 50)
    assert_eq("the counter still ran while uncapped",
        AutoPilot_Needs.getExerciseSetsToday(), startCount + 50)
    assert_eq("status is training, not resting", AutoPilot_Needs
        .getExerciseStatus().outcome, "training: squats")
end

print("\n-- Test 39 (V4.6): a cap > 0 is still a hard ceiling (safety valve)")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    -- V5.7: a fresh character's counter starts at zero, and a cap of 0 means
    -- UNLIMITED, so put real sets on the board first and pin the ceiling
    -- exactly there: the next attempt is the one that must be refused.
    assert_true("warm-up set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    productiveSet(p)
    -- Clear the V4.5 intervention record the warm-up left behind, or the very
    -- next call reads the just-queued set as a player cancel and backs off
    -- before the cap gate is ever reached.
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP =
        AutoPilot_Needs.getExerciseSetsToday()
    assert_true("the ceiling is a real, non-zero count",
        AutoPilot_Constants.EXERCISE_DAILY_CAP > 0)
    local before = #ISTimedActionQueue_calls
    assert_false("training stops at a configured ceiling",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("nothing queued once the ceiling is hit",
        #ISTimedActionQueue_calls, before)
    assert_eq("panel reports the cap as the reason",
        AutoPilot_Needs.getExerciseStatus().outcome,
        "resting (daily set cap reached)")
    -- Raising the ceiling releases training again on the very next cycle.
    AutoPilot_Constants.EXERCISE_DAILY_CAP =
        AutoPilot_Needs.getExerciseSetsToday() + 5
    assert_true("a raised ceiling releases training",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
end

print("\n-- Test 40 (V4.6): with no cap, zero-XP sets are what stop training")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
    local p = exercisePlayer()
    -- Strength without equipment is a single-exercise pool (push-ups), so
    -- one unproductive set exhausts the whole pool.
    assert_true("push-up set queues", AutoPilot_Needs.trainExercise(p, "strength"))
    MockTime.advance(FULL_SET_MS)   -- full set, and NO XP gained
    local before = #ISTimedActionQueue_calls
    assert_false("an unproductive exercise halts training even uncapped",
        AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("nothing queued while XP-fatigued",
        #ISTimedActionQueue_calls, before)
    assert_eq("panel names XP fatigue, not the cap",
        AutoPilot_Needs.getExerciseStatus().outcome,
        "resting (exercises fatigued)")
    -- ...and the recovery window still returns it to service.
    MockTime.advance(AutoPilot_Constants.EXERCISE_FATIGUE_RECOVERY_MS + 60000)
    assert_true("push-ups retried after the recovery window",
        AutoPilot_Needs.trainExercise(p, "strength"))
end

print("\n-- Test 41 (V4.6): getExerciseStatus reads honestly in both modes")
do
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
    local st = AutoPilot_Needs.getExerciseStatus()
    local sets = st.setsToday
    assert_eq("uncapped: cap reads 0", st.cap, 0)
    assert_eq("uncapped: the panel line says so, never 'n/0'",
        st.setsLine, ("Sets today: %d (no cap)"):format(sets))
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 25
    st = AutoPilot_Needs.getExerciseStatus()
    assert_eq("capped: cap is reported", st.cap, 25)
    assert_eq("capped: the panel line shows count out of cap",
        st.setsLine, ("Sets today: %d/25"):format(sets))
    assert_eq("the raw count is unchanged by the cap setting",
        st.setsToday, sets)
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
end

-- V4.7: the hunger and thirst trigger points became options sliders.  The
-- seam that makes that work is the live read in check(): the thresholds are
-- NOT captured at load time, so whatever Options.applyToConstants last wrote
-- decides the very next cycle.  These tests drive check() with a mock player
-- parked just under and just over a CUSTOM threshold, which a hardcoded 0.20
-- could not satisfy in either direction.
-- Count queued actions of a given type.  check() falls through to exercise
-- when no need triggers, so "the eat branch did not fire" has to be asserted
-- on the eat actions specifically, not on an empty queue.
local function count_action_type(t)
    local n = 0
    for _, c in ipairs(ISTimedActionQueue_calls) do
        if c.type == t then n = n + 1 end
    end
    return n
end

print("\n-- Test 42 (V4.7): the eat branch honors the configured hunger threshold")
do
    local foodItem = {
        getName     = function() return "Chips" end,
        getCalories = function() return 200 end,
    }
    local baseHunger = AutoPilot_Constants.HUNGER_THRESHOLD
    assert_eq("shipped default is the user-tuned 15%", baseHunger, 0.15)

    -- Raised trigger: 25% hunger no longer eats, though it did at the default.
    reset()
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem end
    AutoPilot_Constants.HUNGER_THRESHOLD = 0.40
    local hungry25 = MockPlayer.new({
        stats = { HUNGER = 0.25, THIRST = 0.05, FATIGUE = 0.05, ENDURANCE = 0.90 },
    })
    AutoPilot_Needs.check(hungry25)
    assert_eq("below a raised threshold: no eat queued", count_action_type("eat"), 0)

    -- Same player, same tick, threshold lowered under him: he eats now.
    reset()
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem end
    AutoPilot_Constants.HUNGER_THRESHOLD = 0.15
    assert_true("above a lowered threshold: check() acts",
        AutoPilot_Needs.check(hungry25))
    assert_eq("lowered threshold queues the eat", last_action_type(), "eat")

    -- Exactly at the configured value still fires (the use site is >=).
    reset()
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem end
    AutoPilot_Constants.HUNGER_THRESHOLD = 0.25
    assert_true("hunger exactly at the threshold still eats",
        AutoPilot_Needs.check(hungry25))
    assert_eq("boundary is inclusive", last_action_type(), "eat")

    -- shouldInterrupt reads the same live constant, so exercise yields too.
    AutoPilot_Constants.HUNGER_THRESHOLD = 0.15
    assert_true("shouldInterrupt honors a lowered hunger threshold",
        AutoPilot_Needs.shouldInterrupt(hungry25))
    AutoPilot_Constants.HUNGER_THRESHOLD = 0.40
    assert_false("shouldInterrupt honors a raised hunger threshold",
        AutoPilot_Needs.shouldInterrupt(hungry25))

    AutoPilot_Constants.HUNGER_THRESHOLD = baseHunger
end

print("\n-- Test 43 (V4.7): the drink branch honors the configured thirst threshold")
do
    local drinkItem = { getName = function() return "WaterBottle" end }
    local baseThirst = AutoPilot_Constants.THIRST_THRESHOLD
    assert_eq("shipped default is the user-tuned 15%", baseThirst, 0.15)

    reset()
    AutoPilot_Inventory.getBestDrink = function(_player) return drinkItem end
    AutoPilot_Constants.THIRST_THRESHOLD = 0.40
    local thirsty25 = MockPlayer.new({
        stats = { THIRST = 0.25, HUNGER = 0.05, FATIGUE = 0.05, ENDURANCE = 0.90 },
    })
    AutoPilot_Needs.check(thirsty25)
    assert_eq("below a raised threshold: no drink queued", count_action_type("eat"), 0)

    reset()
    AutoPilot_Inventory.getBestDrink = function(_player) return drinkItem end
    AutoPilot_Constants.THIRST_THRESHOLD = 0.15
    assert_true("above a lowered threshold: check() acts",
        AutoPilot_Needs.check(thirsty25))
    -- doDrink queues an ISEatFoodAction (PZ uses this for liquids too), which
    -- is exactly why the eat mechanism is proven working whenever this passes.
    assert_eq("lowered threshold queues the drink", last_action_type(), "eat")

    AutoPilot_Constants.THIRST_THRESHOLD = 0.25
    assert_true("shouldInterrupt honors a thirst threshold at the boundary",
        AutoPilot_Needs.shouldInterrupt(thirsty25))
    AutoPilot_Constants.THIRST_THRESHOLD = 0.40
    assert_false("shouldInterrupt honors a raised thirst threshold",
        AutoPilot_Needs.shouldInterrupt(thirsty25))

    AutoPilot_Constants.THIRST_THRESHOLD = baseThirst
end

-- ── V4.9: transfer to the main inventory before eating/drinking/reading ───────
-- V4.8 let the selectors see items inside worn and carried containers; PZ still
-- consumes items from the MAIN inventory only, so a transfer is queued first
-- and the use action right behind it, in the same cycle and in that order.

-- The suite's Inventory stub returns items with no holding container by
-- default, which is the "already usable" case.  These cases hand back a
-- (item, container) pair, exactly like the real selectors now do.
local BAG = { _tag = "bagContainer" }

local function typeAt(n)
    local a = ISTimedActionQueue_calls[n]
    return a and a.type or nil
end

local function hungryPlayer()
    return MockPlayer.new({
        stats = { HUNGER = 0.25, THIRST = 0.05, FATIGUE = 0.05, ENDURANCE = 0.90 },
    })
end

local function thirstyPlayer()
    return MockPlayer.new({
        stats = { THIRST = 0.30, HUNGER = 0.05, FATIGUE = 0.05, ENDURANCE = 0.90 },
    })
end

-- Food in a backpack: transfer, then eat.
print("\n-- Test 28 (V4.9): food in a backpack transfers THEN eats")
do
    reset()
    local foodItem = {
        getName     = function() return "Chips" end,
        getCalories = function() return 200 end,
    }
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem, BAG end

    assert_true("check() returns true when hungry", AutoPilot_Needs.check(hungryPlayer()))
    assert_eq("exactly two actions queued", #ISTimedActionQueue_calls, 2)
    assert_eq("action 1 is the transfer", typeAt(1), "transfer")
    assert_eq("action 2 is the eat", typeAt(2), "eat")
    assert_eq("the transfer carries the food", ISTimedActionQueue_calls[1].item, foodItem)
end

-- Food already in the main inventory: no transfer at all.
print("\n-- Test 29 (V4.9): food in the main inventory queues NO transfer")
do
    reset()
    local player = hungryPlayer()
    local foodItem = {
        getName     = function() return "Chips" end,
        getCalories = function() return 200 end,
    }
    AutoPilot_Inventory.getBestFood = function(_p) return foodItem, player:getInventory() end

    assert_true("check() returns true when hungry", AutoPilot_Needs.check(player))
    assert_eq("no transfer queued", count_action_type("transfer"), 0)
    assert_eq("the eat is the only queued action", #ISTimedActionQueue_calls, 1)
    assert_eq("action 1 is the eat", typeAt(1), "eat")
end

-- Drink in a backpack: transfer, then drink (ISEatFoodAction).
print("\n-- Test 30 (V4.9): a drink in a bag transfers THEN drinks")
do
    reset()
    local drinkItem = { getName = function() return "WaterBottle" end }
    AutoPilot_Inventory.getBestDrink = function(_player) return drinkItem, BAG end

    assert_true("check() returns true when thirsty",
        AutoPilot_Needs.check(thirstyPlayer()))
    assert_eq("exactly two actions queued", #ISTimedActionQueue_calls, 2)
    assert_eq("action 1 is the transfer", typeAt(1), "transfer")
    assert_eq("action 2 is the drink (ISEatFoodAction)", typeAt(2), "eat")
    assert_eq("the transfer carries the drink",
        ISTimedActionQueue_calls[1].item, drinkItem)
end

-- A refused transfer must not leave a use action queued on an unreachable item.
print("\n-- Test 31 (V4.9): a refused transfer queues no eat and does not error")
do
    reset()
    local savedTransfer = ISInventoryTransferAction
    ISInventoryTransferAction = { new = function() error("PZ refused the transfer") end }

    local foodItem = {
        getName     = function() return "Chips" end,
        getCalories = function() return 200 end,
    }
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem, BAG end

    local ok = pcall(function() return AutoPilot_Needs.check(hungryPlayer()) end)
    ISInventoryTransferAction = savedTransfer

    assert_true("a refused transfer does not raise", ok)
    assert_eq("no eat action queued", count_action_type("eat"), 0)
    assert_eq("no transfer action queued", count_action_type("transfer"), 0)
end

-- Painkillers in a bag: the pain-blocked sleep path takes its container
-- straight from the V4.8 iterator, so it must transfer before taking the pill.
print("\n-- Test 32 (V4.9): bagged painkillers transfer THEN are taken")
do
    reset()
    local pills = {
        getType = function() return "Painkillers" end,
        getName = function() return "Painkillers" end,
    }
    local player = MockPlayer.new({
        stats = {
            FATIGUE   = 0.80,   -- above FATIGUE_THRESHOLD: sleep is attempted
            PAIN      = 100,    -- blocks sleep, routes to pain relief
            HUNGER    = 0.05,
            THIRST    = 0.05,
            ENDURANCE = 0.90,
        },
    })
    MockContainer.attach(player, MockContainer.new({
        MockContainer.bag("FannyPack", { pills }),
    }))

    assert_true("check() returns true when pain relief is queued",
        AutoPilot_Needs.check(player))
    assert_eq("exactly two actions queued", #ISTimedActionQueue_calls, 2)
    assert_eq("action 1 is the transfer", typeAt(1), "transfer")
    assert_eq("action 2 is the pill (ISEatFoodAction fallback)", typeAt(2), "eat")
    assert_eq("the transfer carries the painkillers",
        ISTimedActionQueue_calls[1].item, pills)
end

-- ── V5.0 scope guard: the priority chain never calls a barricade module ─────
-- Through V4.9 the chain ended with a base-maintenance slot that delegated to
-- AutoPilot_Barricade.checkMaintenance and tagged the cycle
-- setDecision("barricade", "maintenance").  Barricading left the mod's scope
-- in V5.0.  This case plants a booby-trapped AutoPilot_Barricade global and a
-- recording telemetry stub, then drives a fully idle cycle (no survival
-- pressure, nothing to loot, no exercise queued) so evaluation walks the
-- WHOLE chain to its end.  Any resurrection of the call site or the label
-- fails here.
print("\n=== Scope Test 1 (V5.0): no barricade module in the priority chain ===")
do
    ISTimedActionQueue_calls = {}
    local barricadeCalls = 0
    AutoPilot_Barricade = setmetatable({}, {
        __index = function(_t, _k)
            barricadeCalls = barricadeCalls + 1
            return function() barricadeCalls = barricadeCalls + 1 return true end
        end,
    })

    -- Decline training so evaluation continues past the exercise slot; the
    -- point of this case is the TAIL of the chain, not the exercise gates.
    local origLeveler = AutoPilot_Leveler
    AutoPilot_Leveler = { check = function(_p) return false end }

    local decisions = {}
    local origSetDecision = AutoPilot_Telemetry.setDecision
    AutoPilot_Telemetry.setDecision = function(action, reason, ...)
        table.insert(decisions, tostring(action))
        return origSetDecision(action, reason, ...)
    end

    -- Calm player: every survival branch above declines, so the chain runs
    -- all the way down past scavenging to its end and returns false.
    local player = MockPlayer.new({
        stats = {
            HUNGER    = 0.02,
            THIRST    = 0.02,
            FATIGUE   = 0.02,
            ENDURANCE = 0.95,
        },
    })
    local result = AutoPilot_Needs.check(player)

    AutoPilot_Telemetry.setDecision = origSetDecision
    AutoPilot_Leveler = origLeveler
    AutoPilot_Barricade = nil

    assert_eq("no AutoPilot_Barricade member was ever touched", barricadeCalls, 0)
    local sawBarricade = false
    for _, a in ipairs(decisions) do
        if a == "barricade" then sawBarricade = true end
    end
    assert_false("no cycle is tagged with the retired 'barricade' decision",
        sawBarricade)
    -- Scavenging is the LAST slot since V5.0: reaching it proves the walk got
    -- past every earlier branch, and nothing follows it any more.
    assert_eq("the chain's final decision is now scavenge, not barricade",
        decisions[#decisions], "scavenge")
    assert_eq("an idle calm cycle queues nothing", #ISTimedActionQueue_calls, 0)
    assert_false("an idle calm cycle returns false from check()", result)
end

-- ── V5.2: auto days prefer carried equipment over burpees ────────────────────
-- User report (in game): the character walked out, picked up dumbbells, added
-- them to inventory, "but then continued doing burpees instead of dumbell
-- presses or bicep curls".  Burpees led the auto pool, so the equipment the
-- mod itself fetches (fetchExerciseEquipment) was never used on an auto day,
-- and bicepscurl/barbellcurl were not in the auto pool at all.  The auto pool
-- now leads with equipment, then burpees, then bodyweight work.

--- A calm player who may or may not be carrying exercise gear.
local function autoExercisePlayer(gear)
    return MockPlayer.new({
        stats    = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                     ENDURANCE = 0.90 },
        moodles  = { ENDURANCE = 0, Unhappy = 0 },
        hasItems = gear and true or false,
    })
end

--- Burn one full-length set that produced NO XP, so the exercise just queued
--- is judged fatigued on the next call, and return the next queued exType.
local function fatigueAndAdvance(p, focus)
    MockTime.advance(FULL_SET_MS)
    local queued = AutoPilot_Needs.trainExercise(p, focus)
    if not queued then return nil end
    return ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType
end

print("\n-- Test 44 (V5.2): an auto day uses a CARRIED dumbbell, not burpees")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0
    local p = autoExercisePlayer(true)
    assert_true("auto-focus set queues with gear carried",
        AutoPilot_Needs.trainExercise(p, nil))
    -- The exact user scenario: dumbbells in inventory on an auto day.
    assert_eq("dumbbell press picked over burpees (1.8x exercise)",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType,
        "dumbbellpress")
end

print("\n-- Test 45 (V5.2): a barehanded auto day still starts on burpees")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = autoExercisePlayer(false)
    assert_true("auto-focus set queues without gear",
        AutoPilot_Needs.trainExercise(p, nil))
    -- Equipment entries fail _hasExerciseItem and fall through silently, so
    -- the both-stats exercise still leads for a character carrying nothing.
    assert_eq("burpees picked when no equipment is carried",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "burpees")
end

print("\n-- Test 46 (V5.2): the auto rotation reaches bicepscurl, then burpees")
do
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = autoExercisePlayer(true)
    assert_true("auto set queues", AutoPilot_Needs.trainExercise(p, nil))
    assert_eq("starts on the dumbbell press",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType,
        "dumbbellpress")
    -- Fatigued equipment work must ROTATE, never stall.  Before V5.2
    -- bicepscurl was unreachable on an auto day at any point.
    assert_eq("XP-fatigued dumbbell press falls through to bicep curls",
        fatigueAndAdvance(p, nil), "bicepscurl")
    assert_eq("fatigued bicep curls fall through to barbell curls",
        fatigueAndAdvance(p, nil), "barbellcurl")
    -- ...and the both-stats exercise is still in the rotation behind them,
    -- so Fitness keeps progressing on an auto day.
    assert_eq("fatigued equipment work falls through to burpees",
        fatigueAndAdvance(p, nil), "burpees")
end

print("\n-- Test 47 (V5.2): the strength and fitness pools are untouched")
do
    -- Collateral guard: V5.2 reordered the AUTO pool only.
    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local p = autoExercisePlayer(true)
    assert_true("strength set queues", AutoPilot_Needs.trainExercise(p, "strength"))
    assert_eq("strength still starts on the dumbbell press",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType,
        "dumbbellpress")
    assert_eq("strength order 2: bicepscurl",
        fatigueAndAdvance(p, "strength"), "bicepscurl")
    assert_eq("strength order 3: barbellcurl",
        fatigueAndAdvance(p, "strength"), "barbellcurl")
    assert_eq("strength order 4: pushups",
        fatigueAndAdvance(p, "strength"), "pushups")
    assert_eq("the strength pool ends after push-ups (no burpees in it)",
        fatigueAndAdvance(p, "strength"), nil)

    ISTimedActionQueue_calls = {}
    MockTime.advance(24 * 60 * 60000)
    AutoPilot_Needs.resetInterventionForTest()
    local q = autoExercisePlayer(true)
    assert_true("fitness set queues", AutoPilot_Needs.trainExercise(q, "fitness"))
    assert_eq("fitness still starts on squats",
        ISTimedActionQueue_calls[#ISTimedActionQueue_calls].exType, "squats")
    assert_eq("fitness order 2: situp", fatigueAndAdvance(q, "fitness"), "situp")
    -- Gear is carried here, so this also proves no equipment leaked into the
    -- bodyweight-only fitness pool.
    assert_eq("the fitness pool ends after sit-ups",
        fatigueAndAdvance(q, "fitness"), nil)
end

-- ── V5.4: endurance recovery (the 30-50% dead zone) ─────────────────────────
-- User report: "the PC does not rest for long enough or utilize things like
-- chairs or benches to recover endurance.  They should at least sit on the
-- ground to improve the efficiency of recovering."
--
-- The live run log backed every part of that: no action=rest entries at all
-- across ~16,000 ticks, idle streaks of 403 / 118 / 116 / 115 ticks tagged
-- reason=no_action, and an endurance floor of 40% that never reached the 30%
-- rest gate.  Training was gated at 50%, so the band between the two gates was
-- spent idling.  These cases pin the fix.

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
local function mockFurniture(spriteName, isBed, sq)
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
    }
end

-- Publish one square holding the named furniture at offset (dx, dy).
local function placeFurniture(specs)
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, cb)
            for _, spec in ipairs(specs) do
                local sq = {}
                local obj = mockFurniture(spec.sprite, spec.bed, sq)
                sq.getObjects = function(_self) return makeArray({ obj }) end
                sq.getX = function(_self) return spec.dx or 0 end
                sq.getY = function(_self) return spec.dy or 0 end
                sq.getZ = function(_self) return 0 end
                sq.isOutside = function(_self) return false end
                if cb(sq, spec.dx or 0, spec.dy or 0) then return end
            end
        end
end

-- V5.7: ONE character whose endurance can be driven up and down.
--
-- A training run belongs to a player OBJECT (same ownership rule as the V4.5
-- `who` guards), so a test that builds a fresh MockPlayer for every endurance
-- level is testing a fresh CHARACTER every time and can never observe a run
-- continuing.  MockPlayer closes over the stats table it is given, so writing
-- through that table moves the live stat.
local function drivenPlayer(endurance, moodle)
    local stats = { HUNGER = 0.02, THIRST = 0.02, FATIGUE = 0.02,
                    ENDURANCE = endurance }
    local p = MockPlayer.new({
        stats   = stats,
        moodles = { ENDURANCE = moodle or 0, Unhappy = 0 },
    })
    p.setEndurance = function(_self, e) stats.ENDURANCE = e end
    return p
end

-- One COMPLETED, productive set at a given endurance, on the same character:
-- the shape of a real training run.  Advancing a full set length matters for
-- two reasons beyond realism -- an instant re-queue reads as a player cancel
-- (V4.5) and would trigger the backoff, and a set that gains no XP reads as
-- diminishing returns (V3.2) and would fatigue the exercise.
local function repAt(p, endurance)
    MockTime.advance(AutoPilot_Constants.EXERCISE_MINUTES * 60000)
    p._xp.Fitness = (p._xp.Fitness or 0) + 12
    p:setEndurance(endurance)
    return AutoPilot_Needs.trainExercise(p, "fitness")
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
        moodles = { ENDURANCE = moodle or 0, Unhappy = 0 },
    })
end

print("\n-- Test V5.4-1 (HEADLINE): 40% endurance sits instead of idling")
do
    resetRest()
    -- 0.40 is the exact floor the live log recorded: above the 30% rest gate,
    -- below the 50% training gate.  Before V5.4 this cycle produced NO action.
    local player = windedPlayer(0.40)
    local decisions = {}
    local origSetDecision = AutoPilot_Telemetry.setDecision
    AutoPilot_Telemetry.setDecision = function(action, reason, ...)
        table.insert(decisions, tostring(action) .. ":" .. tostring(reason))
        return origSetDecision(action, reason, ...)
    end
    local result = AutoPilot_Needs.check(player)
    AutoPilot_Telemetry.setDecision = origSetDecision

    assert_true("check() claims the cycle at 40% endurance", result)
    assert_eq("the dead zone now queues a rest, not nothing",
        last_action_type(), "rest")
    local sawSit = false
    for _, d in ipairs(decisions) do
        if d == "rest:sit_recover" then sawSit = true end
    end
    assert_true("telemetry records action=rest reason=sit_recover", sawSit)
end

print("\n-- Test V5.4-2: the dead zone spans the whole 30-50% band")
do
    for _, e in ipairs({ 0.31, 0.35, 0.45, 0.49 }) do
        resetRest()
        local player = windedPlayer(e)
        assert_true(("endurance %.0f%% claims the cycle"):format(e * 100),
            AutoPilot_Needs.check(player))
        assert_eq(("endurance %.0f%% queues a rest"):format(e * 100),
            last_action_type(), "rest")
    end
end

print("\n-- Test V5.4-3: at the training gate and above it trains, never sits")
do
    resetRest()
    -- The sit threshold tracks the exercise threshold: at or above it the
    -- character must go back to its actual job.  V5.7 moved both to 0.90, so
    -- this reads the gate rather than hardcoding the number.
    -- V5.7: with no run in progress, the threshold that matters is the
    -- RESUME gate, not the floor.
    AutoPilot_Needs.endTrainingRun()
    local player = windedPlayer(AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME)
    AutoPilot_Needs.check(player)
    assert_eq("at exactly the resume gate it trains, not rests",
        last_action_type(), "exercise")
    resetRest()
    AutoPilot_Needs.check(windedPlayer(1.00))
    assert_eq("at full endurance it trains, not rests",
        last_action_type(), "exercise")
end

print("\n-- Test V5.4-4: bench and friends are recognised as seating")
do
    local seat = AutoPilot_Needs.seatPriorityForSprite
    assert_eq("B42's outdoor seating sheet is seating",
        seat("furniture_seating_outdoor_01_16"), 3)
    assert_eq("a named bench is seating",      seat("location_park_bench_01"), 3)
    assert_eq("a stool is seating",            seat("furniture_barstool_02"), 3)
    assert_eq("a church pew is seating",       seat("church_pew_01"), 3)
    assert_eq("a chair is seating",            seat("furniture_seating_indoor_chair_04"), 3)
    assert_eq("a sofa outranks a chair",       seat("furniture_seating_indoor_sofa_01"), 2)
    assert_eq("a couch outranks a chair",      seat("couch_green_02"), 2)
    assert_eq("a loveseat outranks a chair",   seat("loveseat_red_01"), 2)
    assert_eq("an armchair outranks a chair",  seat("armchair_blue_03"), 2)
    -- Guard against the obvious false positives.
    assert_eq("a workbench is NOT seating",    seat("carpentry_workbench_01"), nil)
    assert_eq("a carpentry bench is NOT seating", seat("crafted_carpentry_bench"), nil)
    assert_eq("a bench saw is NOT seating",    seat("industry_benchsaw_01"), nil)
    assert_eq("a fridge is NOT seating",       seat("appliances_refrigeration_01"), nil)
    assert_eq("a non-string is NOT seating",   seat(nil), nil)
end

print("\n-- Test V5.4-5: a bench OUTSIDE the home is now eligible")
do
    resetRest()
    -- isInside() is false for every square in this suite, which is exactly the
    -- pre-V5.4 blind spot: the old code bailed on the first line of the scan.
    placeFurniture({ { sprite = "location_park_bench_01", dx = 5, dy = 0 } })
    local player = windedPlayer(0.40)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(player))
    -- V5.8: the furniture path queues the SEAT action (pathToSitOnFurniture),
    -- so the recorded type is "sit_furniture" rather than "rest_furniture".
    assert_eq("the outdoor bench is used, not the ground",
        last_action_type(), "sit_furniture")
    noFurniture()
end

print("\n-- Test V5.4-6: outside-home seating beyond the tighter radius is refused")
do
    resetRest()
    local far = AutoPilot_Constants.REST_OUTSIDE_SEARCH_DIST + 5
    placeFurniture({ { sprite = "location_park_bench_01", dx = far, dy = 0 } })
    local player = windedPlayer(0.40)
    assert_true("check() still claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("a bench across town is ignored; it sits on the ground instead",
        last_action_type(), "rest")
    noFurniture()
end

print("\n-- Test V5.4-7: inside-home seating wins over closer outside seating")
do
    resetRest()
    -- Mark only the far square as inside home.
    AutoPilot_Home.isInside = function(sq) return sq:getX() == 40 end
    placeFurniture({
        { sprite = "location_park_bench_01", dx = 2,  dy = 0 },
        { sprite = "furniture_seating_indoor_sofa_01", dx = 40, dy = 0 },
    })
    local player = windedPlayer(0.40)
    AutoPilot_Needs.check(player)
    assert_eq("furniture was used", last_action_type(), "sit_furniture")
    local chosen = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_eq("the far INSIDE sofa beat the near OUTSIDE bench",
        chosen.target:getSprite():getName(), "furniture_seating_indoor_sofa_01")
    AutoPilot_Home.isInside = function(_sq) return false end
    noFurniture()
end

print("\n-- Test V5.4-8: the ground-sit fallback fires when nothing qualifies")
do
    resetRest()
    -- No furniture anywhere: the user's "at least sit on the ground".
    local player = windedPlayer(0.40)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("ISSitOnGround is queued", last_action_type(), "rest")
end

print("\n-- Test V5.4-9: a rest outlasts one in-game minute")
do
    resetRest()
    local player = windedPlayer(0.40)
    assert_true("first cycle sits down", AutoPilot_Needs.check(player))
    local queuedAfterSit = #ISTimedActionQueue_calls

    -- The old code held the rest for exactly 60000 game ms and then stood the
    -- character back up.  Step past that and well beyond it.
    MockTime.advance(60000)
    assert_true("still resting one game minute later", AutoPilot_Needs.check(player))
    assert_eq("no second action was queued a minute in",
        #ISTimedActionQueue_calls, queuedAfterSit)

    MockTime.advance(10 * 60000)
    assert_true("still resting ten game minutes later",
        AutoPilot_Needs.check(player))
    assert_eq("still no second action ten minutes in",
        #ISTimedActionQueue_calls, queuedAfterSit)
end

print("\n-- Test V5.4-10: the rest ends when endurance reaches the target")
do
    resetRest()
    local player = windedPlayer(0.40)
    assert_true("sits down", AutoPilot_Needs.check(player))
    -- Endurance recovers past ENDURANCE_REST_TARGET (V5.7: 0.95) while seated.
    local recovered = windedPlayer(
        AutoPilot_Constants.ENDURANCE_REST_TARGET + 0.01)
    AutoPilot_Needs.check(recovered)
    -- The hold is released, so the chain runs on; a further cycle must not be
    -- swallowed by the rest gate.
    ISTimedActionQueue_calls = {}
    AutoPilot_Needs.check(recovered)
    assert_true("a recovered character is no longer held in the rest",
        last_action_type() ~= "rest")
end

print("\n-- Test V5.4-11: the maximum hold releases even if endurance never moves")
do
    resetRest()
    local player = windedPlayer(0.40)
    assert_true("sits down", AutoPilot_Needs.check(player))
    ISTimedActionQueue_calls = {}
    MockTime.advance((AutoPilot_Constants.REST_HOLD_MS or 60000) + 1000)
    -- Past the wedge guard: the chain re-evaluates and sits again rather than
    -- staying stuck in a hold forever.
    assert_true("the cycle is re-evaluated after the maximum hold",
        AutoPilot_Needs.check(player))
    assert_eq("a fresh rest is queued", last_action_type(), "rest")
end

print("\n-- Test V5.4-12: bleeding preempts an active rest")
do
    resetRest()
    local player = windedPlayer(0.40)
    assert_true("sits down", AutoPilot_Needs.check(player))
    ISTimedActionQueue_calls = {}
    AutoPilot_Medical._bleeding = true
    assert_true("bleeding still claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("the bandage outranks the rest", last_action_type(), "bandage")
    AutoPilot_Medical._bleeding = false
end

print("\n-- Test V5.4-13: hunger and thirst preempt an active rest")
do
    resetRest()
    assert_true("sits down", AutoPilot_Needs.check(windedPlayer(0.40)))

    ISTimedActionQueue_calls = {}
    local foodItem = {
        getName     = function() return "Chips" end,
        getCalories = function() return 200 end,
    }
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem end
    local hungry = MockPlayer.new({
        stats = { HUNGER = 0.25, THIRST = 0.02, FATIGUE = 0.02, ENDURANCE = 0.40 },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
    })
    assert_true("hunger claims the cycle mid-rest", AutoPilot_Needs.check(hungry))
    assert_eq("eating outranks the rest hold", last_action_type(), "eat")

    resetRest()
    assert_true("sits down again", AutoPilot_Needs.check(windedPlayer(0.40)))
    ISTimedActionQueue_calls = {}
    AutoPilot_Inventory.getBestDrink =
        function(_player) return { getName = function() return "WaterBottle" end } end
    local thirsty = MockPlayer.new({
        stats = { THIRST = 0.30, HUNGER = 0.02, FATIGUE = 0.02, ENDURANCE = 0.40 },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
    })
    assert_true("thirst claims the cycle mid-rest", AutoPilot_Needs.check(thirsty))
    assert_eq("drinking outranks the rest hold", last_action_type(), "eat")
    reset()
end

print("\n-- Test V5.4-14: high fatigue still overrides the rest hold")
do
    resetRest()
    assert_true("sits down", AutoPilot_Needs.check(windedPlayer(0.40)))
    ISTimedActionQueue_calls = {}
    local sleepy = MockPlayer.new({
        stats = { HUNGER = 0.02, THIRST = 0.02, FATIGUE = 0.80, ENDURANCE = 0.40 },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
    })
    -- doSleep finds no bed here, so it returns false; what matters is that the
    -- rest hold did NOT swallow the cycle before the sleep branch ran.
    AutoPilot_Needs.check(sleepy)
    assert_eq("no rest action was queued on the fatigue path",
        last_action_type(), nil)
end

print("\n-- Test V5.4-15: the 30% critical path still prefers a bed")
do
    resetRest()
    local origAdjacent = AdjacentFreeTileFinder.isTileOrAdjacent
    AdjacentFreeTileFinder.isTileOrAdjacent = function(_a, _b) return true end
    placeFurniture({
        { sprite = "furniture_bedding_01_20", bed = true, dx = 3, dy = 0 },
        { sprite = "location_park_bench_01",  dx = 1, dy = 0 },
    })
    local player = windedPlayer(0.20)
    assert_true("critically low endurance claims the cycle",
        AutoPilot_Needs.check(player))
    assert_eq("the bed still wins below 30%, even next to a bench",
        last_action_type(), "sleep")
    AdjacentFreeTileFinder.isTileOrAdjacent = origAdjacent
    noFurniture()
end

print("\n-- Test V5.4-16: the sit path never takes a bed")
do
    resetRest()
    local origAdjacent = AdjacentFreeTileFinder.isTileOrAdjacent
    AdjacentFreeTileFinder.isTileOrAdjacent = function(_a, _b) return true end
    placeFurniture({
        { sprite = "furniture_bedding_01_20", bed = true, dx = 1, dy = 0 },
    })
    -- 40% is winded, not exhausted: putting the character to sleep in the
    -- middle of the day would be worse than the idling this fix removes.
    local player = windedPlayer(0.40)
    AutoPilot_Needs.check(player)
    assert_eq("a bed in the dead zone does NOT become sleep",
        last_action_type(), "rest")
    AdjacentFreeTileFinder.isTileOrAdjacent = origAdjacent
    noFurniture()
end

print("\n-- Test V5.4-17: the sit threshold is live-read from constants")
do
    resetRest()
    local saved     = AutoPilot_Constants.ENDURANCE_SIT_MIN
    local savedGate = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    -- V5.7: when NO run is in progress the sit threshold is raised to the
    -- RESUME gate, because a character who is not training and cannot start
    -- has nothing to do but recover.  Lowering the sit slider therefore only
    -- shows up once the resume gate is out of the way too, which is what a
    -- player lowering both sliders together would do.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.30
    AutoPilot_Constants.ENDURANCE_SIT_MIN         = 0.35
    -- 40% is now ABOVE the tuned-down sit threshold: no rest.
    AutoPilot_Needs.check(windedPlayer(0.40))
    assert_true("a lowered slider stops the sit immediately",
        last_action_type() ~= "rest")
    resetRest()
    AutoPilot_Constants.ENDURANCE_SIT_MIN = 0.80
    assert_true("a raised slider sits at 70% endurance",
        AutoPilot_Needs.check(windedPlayer(0.70)))
    assert_eq("and it queues a rest", last_action_type(), "rest")
    AutoPilot_Constants.ENDURANCE_SIT_MIN         = saved
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = savedGate
    resetRest()
end

-- ══ V5.7 ═════════════════════════════════════════════════════════════════════

print("\n-- Test V5.7-1: the set counter resets for a NEW CHARACTER")
do
    -- User report: "when starting a new character, the number of sets
    -- completed should reset".  The F11 panel opened on "Sets today: 150 (no
    -- cap)" for a survivor who had never trained, because the count keyed off
    -- the in-game day alone and module state outlives a death.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0

    local dead = exercisePlayer()
    AutoPilot_Needs.syncSetsCounterForTest(dead)
    assert_eq("a fresh character starts on zero",
        AutoPilot_Needs.getExerciseSetsToday(), 0)

    -- Put a real, non-zero total on the board for this character.
    assert_true("first set queues", AutoPilot_Needs.trainExercise(dead, "fitness"))
    for _ = 1, 4 do productiveSet(dead) end
    local carried = AutoPilot_Needs.getExerciseSetsToday()
    assert_eq("five sets counted for the first character", carried, 5)

    -- SAME character, SAME day, another cycle: the count must NOT reset, or
    -- the daily cap and the panel become meaningless.
    AutoPilot_Needs.syncSetsCounterForTest(dead)
    assert_eq("a same-character mid-day tick does not reset the count",
        AutoPilot_Needs.getExerciseSetsToday(), carried)
    AutoPilot_Needs.check(dead)
    assert_true("...not even through the full check() chain",
        AutoPilot_Needs.getExerciseSetsToday() >= carried)

    -- The character dies and the player starts a new one.  Same Lua session,
    -- same in-game day, same player number: a NEW player object is the only
    -- signal that anything changed, and it is the same signal the V4.5 `who`
    -- guards already key off.
    local reborn = exercisePlayer()
    assert_true("the respawn really is a different player object",
        reborn ~= dead)
    AutoPilot_Needs.syncSetsCounterForTest(reborn)
    assert_eq("a new character starts on zero sets, same day or not",
        AutoPilot_Needs.getExerciseSetsToday(), 0)
    assert_eq("the F11 panel agrees",
        AutoPilot_Needs.getExerciseStatus().setsToday, 0)
    assert_eq("...and says so in words, with no carried-over total",
        AutoPilot_Needs.getExerciseStatus().setsLine, "Sets today: 0 (no cap)")
end

print("\n-- Test V5.7-2: check() performs the reset even when exercise never runs")
do
    -- doExercise is the LAST step in the chain.  A new character with an
    -- urgent need would never reach it, so the reset also rides the top of
    -- check() -- otherwise the panel keeps showing the dead character's total
    -- for as long as the new one stays busy.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    local trained = exercisePlayer()
    AutoPilot_Needs.syncSetsCounterForTest(trained)
    assert_true("a set queues", AutoPilot_Needs.trainExercise(trained, "fitness"))
    assert_true("the counter is non-zero before the death",
        AutoPilot_Needs.getExerciseSetsToday() > 0)

    -- The new character is parched: check() returns on the thirst branch long
    -- before it ever reaches training.
    local thirsty = MockPlayer.new({
        stats   = { HUNGER = 0.02, THIRST = 0.95, FATIGUE = 0.02,
                    ENDURANCE = 1.00 },
        moodles = { ENDURANCE = 0, Unhappy = 0 },
    })
    AutoPilot_Needs.check(thirsty)
    assert_eq("the count resets on the very first cycle after a respawn",
        AutoPilot_Needs.getExerciseSetsToday(), 0)
end

print("\n-- Test V5.7-3: the day rollover still resets, for the SAME character")
do
    -- The original Phase 2 behaviour must survive the new guard.  getDay() is
    -- pinned at 1 in the mock, so the rollover is driven directly.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    AutoPilot_Needs.syncSetsCounterForTest(p)
    assert_true("a set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local before = AutoPilot_Needs.getExerciseSetsToday()
    assert_true("the counter moved", before > 0)

    local realGetDay = GameTime.getInstance().getDay
    GameTime.getInstance().getDay = function(_self) return 2 end
    AutoPilot_Needs.syncSetsCounterForTest(p)
    assert_eq("a new in-game day zeroes the same character's count",
        AutoPilot_Needs.getExerciseSetsToday(), 0)
    -- ...and the SAME day does not do it twice.
    AutoPilot_Needs.trainExercise(p, "fitness")
    local midDay = AutoPilot_Needs.getExerciseSetsToday()
    AutoPilot_Needs.syncSetsCounterForTest(p)
    assert_eq("a second tick on the same day leaves the count alone",
        AutoPilot_Needs.getExerciseSetsToday(), midDay)
    GameTime.getInstance().getDay = realGetDay
end

print("\n-- Test V5.7-4: TWO endurance gates, both LIVE-READ")
do
    -- Before V5.7 two constants gated exercise: a live-read one the slider
    -- wrote (0.30) and a FILE-LOCAL copy of a second, transposed-name one
    -- (0.50).  Being a load-time copy the second could not be moved by any
    -- options save, and being the larger it floored the first, so the
    -- slider's whole range did nothing.  Both halves of the replacement pair
    -- must be drivable at runtime with no reload.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    local savedR = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    local savedF = AutoPilot_Constants.EXERCISE_ENDURANCE_MIN

    -- 40% endurance, no run in progress: refused at the shipped 90% resume.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.90
    AutoPilot_Needs.endTrainingRun()
    assert_false("40% endurance cannot START a run at a 90% resume gate",
        AutoPilot_Needs.trainExercise(windedPlayer(0.40), "fitness"))

    -- An options save drops the resume gate to 30%.  No reload, no re-dofile:
    -- the very next call must honour it.  Under the old code this stayed
    -- refused, because the 0.50 file-local was still in the way.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.30
    AutoPilot_Needs.resetInterventionForTest()
    assert_true("the same 40% character starts once resume drops to 30%",
        AutoPilot_Needs.trainExercise(windedPlayer(0.40), "fitness"))

    -- And the FLOOR is live-read too, on the other side of the hysteresis.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.30
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = 0.10
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    local runner = drivenPlayer(0.50)
    assert_true("a run starts", AutoPilot_Needs.trainExercise(runner, "fitness"))
    assert_true("and it continues at 20%, above the 10% floor",
        repAt(runner, 0.20))
    -- Now raise the floor over the character's head mid-run, exactly as an
    -- options save would.  No reload: the very next decision must honour it.
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN = 0.60
    assert_false("raising the floor above the character ends the run at once",
        repAt(runner, 0.20))
    assert_eq("and the panel names endurance as the reason",
        AutoPilot_Needs.getExerciseStatus().outcome,
        "resting (endurance recovering)")

    -- The severe exertion moodle is a SEPARATE signal and survived the
    -- redesign: a level 3 moodle blocks a set even at full endurance, and
    -- even mid-run.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.30
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = 0.10
    AutoPilot_Needs.resetInterventionForTest()
    assert_false("a level 3 exertion moodle still blocks a set outright",
        AutoPilot_Needs.trainExercise(windedPlayer(1.00, 3), "fitness"))

    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = savedR
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = savedF
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
end

print("\n-- Test V5.7-4b: A RUN CONTINUES AT 0.80 (the single-rep bug is dead)")
do
    -- THE regression test for the user's report: "The old setting of 50 made
    -- it so that only a single rep would be completed after a period of
    -- resting."  Under a single threshold the first rep drops endurance below
    -- the very gate that started the set, and training stops dead.  With
    -- hysteresis, a run that STARTED above the resume gate must keep going
    -- well below it, all the way down to the floor.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()

    -- Start the run at 95%, comfortably above the 90% resume gate.
    local p = drivenPlayer(0.95)
    assert_true("a run starts at 95% endurance",
        AutoPilot_Needs.trainExercise(p, "fitness"))

    -- Now endurance falls as the reps go by.  Every level below is UNDER the
    -- resume gate that started the run, and every one must still train.
    -- 0.80 is the headline: under the old single-gate code this is the exact
    -- point at which training stopped after a single rep.
    for _, e in ipairs({ 0.80, 0.60, 0.40 }) do
        assert_true(
            ("the run CONTINUES at %.0f%% endurance, far below the resume gate")
                :format(e * 100),
            repAt(p, e))
        assert_eq(("...and the panel says training at %.0f%%"):format(e * 100),
            AutoPilot_Needs.getExerciseStatus().outcome:sub(1, 8), "training")
    end

    -- Below the floor the run finally stops.
    assert_false("the run STOPS below the 30% floor", repAt(p, 0.25))
    assert_eq("the panel reports endurance recovery, not a cap or fatigue",
        AutoPilot_Needs.getExerciseStatus().outcome,
        "resting (endurance recovering)")

    -- And having stopped, it must NOT restart just above the floor: the whole
    -- point of hysteresis is that the next run waits for the resume gate.
    assert_false("it does NOT restart at 40%, having ended the run",
        repAt(p, 0.40))
    assert_false("nor at 85%, one step under the resume gate", repAt(p, 0.85))
    assert_true("but it DOES resume at exactly 90%", repAt(p, 0.90))
    AutoPilot_Needs.endTrainingRun()
end

print("\n-- Test V5.7-4c: the full rest-train-rest cycle through check()")
do
    -- End to end, the cycle the user asked for: train down to the floor, sit,
    -- recover to nearly full, resume.  Driven through check() so the sit
    -- branch and the rest hold are exercised, not just the gates.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()

    local p = drivenPlayer(0.95)
    AutoPilot_Needs.check(p)
    assert_eq("full: the chain trains", last_action_type(), "exercise")

    -- Mid-run, well under the resume gate: still training, not sitting.
    for _, e in ipairs({ 0.80, 0.60, 0.40 }) do
        MockTime.advance(AutoPilot_Constants.EXERCISE_MINUTES * 60000)
        p._xp.Fitness = (p._xp.Fitness or 0) + 12
        p:setEndurance(e)
        ISTimedActionQueue_calls = {}
        AutoPilot_Needs.check(p)
        assert_eq(("mid-run at %.0f%% the chain still trains"):format(e * 100),
            last_action_type(), "exercise")
    end

    -- Under the sit threshold: the run ends and the character sits down.
    MockTime.advance(AutoPilot_Constants.EXERCISE_MINUTES * 60000)
    p._xp.Fitness = (p._xp.Fitness or 0) + 12
    p:setEndurance(0.33)
    ISTimedActionQueue_calls = {}
    AutoPilot_Needs.check(p)
    assert_eq("under the sit threshold the character sits",
        last_action_type(), "rest")

    -- Seated and recovering, but not yet at the stand-up target: stay put,
    -- and queue nothing new while the hold is in force.
    p:setEndurance(0.70)
    ISTimedActionQueue_calls = {}
    assert_true("still seated at 70%, below the 95% target",
        AutoPilot_Needs.check(p))
    assert_eq("nothing else was queued while resting",
        #ISTimedActionQueue_calls, 0)

    -- Recovered to the stand-up target: the hold releases and training
    -- resumes, because the target clears the resume gate by design.
    p:setEndurance(AutoPilot_Constants.ENDURANCE_REST_TARGET)
    ISTimedActionQueue_calls = {}
    AutoPilot_Needs.check(p)
    assert_eq("at the stand-up target it resumes training",
        last_action_type(), "exercise")
    AutoPilot_Needs.endTrainingRun()
end

print("\n-- Test V5.7-4d: everything that must END a run, ends it")
do
    -- A missed clear is the dangerous direction: the character would believe
    -- it is mid-run and keep training off the LOW floor when it should have
    -- been recovering to the resume gate.  Each hook is driven for real and
    -- then probed at 40% -- below the resume gate, above the floor -- which
    -- can only train if the run is still considered open.
    --
    -- repAt advances a full set length, which also carries every probe past
    -- the 10 game-minute V4.5 backoff window, so what is measured here is the
    -- run flag itself and not a backoff timer sitting in front of it.
    local function startRun()
        resetRest()
        AutoPilot_Needs.resetInterventionForTest()
        AutoPilot_Needs.endTrainingRun()
        local p = drivenPlayer(0.95)
        assert_true("(a run is started)",
            AutoPilot_Needs.trainExercise(p, "fitness"))
        return p
    end

    -- CONTROL: with a run genuinely open, 40% DOES train.  Without this the
    -- assertions below would all pass even if training never ran at all.
    assert_true("CONTROL: an open run trains at 40%", repAt(startRun(), 0.40))

    local p = startRun()
    AutoPilot_Needs.endTrainingRun()
    assert_false("endTrainingRun() ends it", repAt(p, 0.40))

    p = startRun()
    AutoPilot_Needs.noteModExerciseCleared()
    assert_false("a mod-side clear (urgent need, threat, thrash guard) ends it",
        repAt(p, 0.40))

    p = startRun()
    AutoPilot_Needs.notePanicStop()
    assert_false("the F10 panic stop ends it", repAt(p, 0.40))

    p = startRun()
    AutoPilot_Needs.noteForeignExercise()
    assert_false("the player exercising manually ends it", repAt(p, 0.40))

    -- Sitting down ends it, so standing up again waits for the resume gate.
    p = startRun()
    p:setEndurance(0.33)
    AutoPilot_Needs.check(p)
    assert_false("sitting down to recover ends it", repAt(p, 0.40))

    -- A NEW CHARACTER never inherits a run: the same guarantee as the sets
    -- counter and the V4.5 `who` records.
    startRun()
    local reborn = drivenPlayer(0.40)
    AutoPilot_Needs.resetInterventionForTest()
    assert_false("a respawned character does not inherit the run",
        AutoPilot_Needs.trainExercise(reborn, "fitness"))

    -- The daily cap ends it, so the next day starts a fresh run off resume.
    p = startRun()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 1
    assert_false("hitting the daily set cap ends it", repAt(p, 0.40))
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0

    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
end

print("\n-- Test V5.7-5: no idle dead zone anywhere below full endurance")
do
    -- The whole point of the V5.4 sit branch, re-verified against the V5.7
    -- defaults (gate 0.90, sit 0.90, stand-up target 0.95).  A rest target
    -- BELOW the gate would have been the regression: every completed rest
    -- would end straight back into a band where training is still refused.
    --
    -- The character is swept across the boundaries that matter -- the old
    -- 30/50/70 numbers, the new 90/95 ones, and points either side of each --
    -- and on every single one the cycle must be CLAIMED by something.  Idling
    -- is the failure this asserts against; "no_action" is what the live run
    -- log showed for 403 ticks at a time.
    local bands = {
        0.29, 0.30, 0.31, 0.40, 0.49, 0.50, 0.51, 0.60,
        0.69, 0.70, 0.71, 0.80, 0.89, 0.90, 0.91, 0.94, 0.95, 0.96, 1.00,
    }
    for _, e in ipairs(bands) do
        resetRest()
        AutoPilot_Needs.resetInterventionForTest()
        local p = windedPlayer(e)
        local claimed = AutoPilot_Needs.check(p)
        local act = last_action_type()
        assert_true(
            ("endurance %.0f%% is never left idle (action=%s)")
                :format(e * 100, tostring(act)),
            claimed == true)
        -- ...and what it did has to be resting or training, not busywork.
        -- windedPlayer has no other need, so anything else is a fall-through.
        assert_true(
            ("endurance %.0f%% either rests or trains, nothing else")
                :format(e * 100),
            act == "rest" or act == "sit_furniture"
                or act == "rest_furniture" or act == "exercise")
    end
end

print("\n-- Test V5.7-6: the sit/resume boundary is exact, and does not thrash")
do
    -- With no run open, below the resume gate the character sits and at or
    -- above it the character trains.  No gap, no overlap, nothing idle.
    local resume = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    AutoPilot_Needs.check(windedPlayer(resume - 0.01))
    assert_eq("one point below the resume gate the character sits",
        last_action_type(), "rest")

    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    AutoPilot_Needs.check(windedPlayer(resume))
    assert_eq("exactly at the resume gate the character trains",
        last_action_type(), "exercise")

    -- The stand-up target must clear the resume gate, or a finished rest
    -- lands back in a refused band and the character idles: the V5.4 bug,
    -- moved up the scale.
    assert_true("the stand-up target is strictly above the resume gate",
        AutoPilot_Constants.ENDURANCE_REST_TARGET > resume)

    -- The sit threshold is raised to the resume gate whenever no run is
    -- open, so even a player who drags the sit slider to its minimum cannot
    -- reopen the dead zone.
    local savedSit = AutoPilot_Constants.ENDURANCE_SIT_MIN
    AutoPilot_Constants.ENDURANCE_SIT_MIN = 0.10
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    AutoPilot_Needs.check(windedPlayer(resume - 0.05))
    assert_eq("a sit slider dragged under the gate still sits, not idles",
        last_action_type(), "rest")
    AutoPilot_Constants.ENDURANCE_SIT_MIN = savedSit
    resetRest()
    AutoPilot_Needs.endTrainingRun()
end

-- ── V5.8: actually sit down, and report one honest status ────────────────────
-- User report, with a screenshot of the running v5.7 build: "Text says
-- resting, but character is not sitting in the chair as expected".  The panel
-- read "Status: training: burpees", the on-screen HUD read "Action: Resting",
-- and the character was standing beside an empty chair.

print("\n-- Test V5.8-1 (HEADLINE): resting on furniture queues the SEAT action")
do
    resetRest()
    placeFurniture({ { sprite = "furniture_seating_indoor_chair_04", dx = 1, dy = 0 } })
    local player = windedPlayer(0.40)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(player))

    local queued = ISTimedActionQueue_calls
    assert_eq("exactly ONE action is queued for a furniture rest", #queued, 1)
    assert_eq("and it is the seat action, which walks there AND sits down",
        queued[1].type, "sit_furniture")
    assert_eq("the seat action was handed the chair that was found",
        queued[1].target:getSprite():getName(),
        "furniture_seating_indoor_chair_04")

    -- The pre-V5.8 shape: a second, non-pathing rest action stacked behind
    -- the sit, itself constructed with useAnimations = nil.
    for _, act in ipairs(queued) do
        assert_false("no rest action is stacked behind the sit",
            act.type == "rest_furniture")
    end
    noFurniture()
end

print("\n-- Test V5.8-2: the ISRestAction fallback never disables its animations")
do
    resetRest()
    placeFurniture({ { sprite = "furniture_seating_indoor_sofa_01", dx = 1, dy = 0 } })
    -- Take the seat action away: the fallback is the only thing left.
    local savedPath = ISPathFindAction.pathToSitOnFurniture
    ISPathFindAction.pathToSitOnFurniture = nil
    local player = windedPlayer(0.40)
    assert_true("check() still claims the cycle", AutoPilot_Needs.check(player))
    local last = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_eq("the fallback rest action is used", last.type, "rest_furniture")
    assert_eq("useAnimations is TRUE, not the falsy nil that rested standing up",
        last.useAnimations, true)
    ISPathFindAction.pathToSitOnFurniture = savedPath
    noFurniture()
end

print("\n-- Test V5.8-3 (HEADLINE): the panel status agrees with the action HUD")
do
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    -- Reproduce the screenshot exactly: train first, so the trainer's own
    -- outcome string is "training: <something>", THEN drop into the rest.
    local p = drivenPlayer(0.95)
    assert_true("(a set is queued first)",
        AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_eq("the trainer status reads as training",
        AutoPilot_Needs.getExerciseStatus().outcome:sub(1, 9), "training:")

    resetRest()
    placeFurniture({ { sprite = "furniture_seating_indoor_chair_04", dx = 1, dy = 0 } })
    AutoPilot_Needs.endTrainingRun()
    local winded = windedPlayer(0.40)
    assert_true("the winded cycle rests", AutoPilot_Needs.check(winded))
    assert_eq("the cycle queued the seat action", last_action_type(), "sit_furniture")

    local outcome = AutoPilot_Needs.getExerciseStatus().outcome
    -- The V4.4 HUD renders ACTION_LABELS["rest"] = "Resting" for this cycle.
    -- The panel must not be saying "training: burpees" underneath it.
    assert_eq("the panel status now says resting too", outcome:sub(1, 7), "resting")
    assert_eq("and it is NOT the stale training line", outcome:find("training", 1, true), nil)
    noFurniture()
end

print("\n-- Test V5.8-4: a training cycle still reports the exercise by name")
do
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    local p = drivenPlayer(1.00)
    assert_true("(a set is queued)", AutoPilot_Needs.trainExercise(p, "fitness"))
    local outcome = AutoPilot_Needs.getExerciseStatus().outcome
    assert_eq("the status still names the exercise being trained",
        outcome:sub(1, 10), "training: ")
    -- The panel's regularity row keys off exactly this shape.
    assert_true("the exercise name is still parseable from the status",
        outcome:match("^training: (%S+)") ~= nil)
end

print("\n-- Test V5.8-5: the ground fallback still fires, and reports honestly")
do
    resetRest()
    AutoPilot_Needs.endTrainingRun()
    -- No furniture anywhere: the V5.4 guaranteed floor is untouched.
    local player = windedPlayer(0.40)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("ISSitOnGround is still what gets queued", last_action_type(), "rest")
    assert_eq("exactly one action is queued", #ISTimedActionQueue_calls, 1)
    local outcome = AutoPilot_Needs.getExerciseStatus().outcome
    assert_eq("and the status says resting, not training",
        outcome:sub(1, 7), "resting")
end

print("\n-- Test V5.8-6: the rest HOLD cycle reports resting even though it queues nothing")
do
    resetRest()
    AutoPilot_Needs.endTrainingRun()
    local player = windedPlayer(0.40)
    assert_true("the first cycle sits down", AutoPilot_Needs.check(player))
    local queuedAfterSit = #ISTimedActionQueue_calls
    -- Second cycle, still inside REST_HOLD_MS: doRest short-circuits and the
    -- hold branch in check() claims the cycle without queueing anything.
    -- That is the branch that used to leave the panel on the training line.
    assert_true("the hold keeps claiming the cycle", AutoPilot_Needs.check(player))
    assert_eq("nothing new was queued during the hold",
        #ISTimedActionQueue_calls, queuedAfterSit)
    assert_eq("the held cycle still reports resting",
        AutoPilot_Needs.getExerciseStatus().outcome:sub(1, 7), "resting")
end

print("\n-- Test V5.8-7: V5.7's endurance hysteresis is untouched")
do
    -- A run started at 95% must still continue at 80%, which is below the
    -- 0.90 resume gate and above the 0.30 floor: the exact property V5.7
    -- exists to provide.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    local p = drivenPlayer(0.95)
    assert_true("a run starts at 95%", AutoPilot_Needs.trainExercise(p, "fitness"))
    assert_true("and it continues at 80%, below the resume gate", repAt(p, 0.80))
    assert_eq("the resume gate is unchanged",
        AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME, 0.90)
    assert_eq("the floor is unchanged",
        AutoPilot_Constants.EXERCISE_ENDURANCE_MIN, 0.30)
    assert_eq("the sit threshold is unchanged",
        AutoPilot_Constants.ENDURANCE_SIT_MIN, 0.35)
    assert_eq("the stand-up target is unchanged",
        AutoPilot_Constants.ENDURANCE_REST_TARGET, 0.95)
    -- A fresh character with no run open still has to clear the resume gate.
    AutoPilot_Needs.endTrainingRun()
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    assert_false("with no run open, 80% does NOT start one",
        AutoPilot_Needs.trainExercise(drivenPlayer(0.80), "fitness"))
    resetRest()
    AutoPilot_Needs.endTrainingRun()
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
