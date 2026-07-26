-- tests/test_mood_food_choice.lua
-- The UNHAPPY arm of mood relief: which food it picks, and when it is allowed
-- to spend food at all.
--
-- Part of the user-reported bug from 2026-07-24 ("negative moodles / status
-- effects accumulate over long autopilot runs", vitals healthy at H:11 T:12
-- F:18 while the negative-moodle stack grew past six icons).  Three earlier
-- root causes have already been closed (the rest hold stopping above the mood
-- step, the Perks.Literacy gate that killed reading, and the MoodleType.Unhappy
-- misspelling that made the unhappy arm unreachable).  This suite pins the two
-- that remain in the same arm:
--
--   1. WHICH food.  AutoPilot_Inventory.preferTastyFood ranked candidates by
--      getBoredomChange() alone, but its only caller is the UNHAPPINESS arm.
--      Boredom and unhappiness are different moodles, so the relief could pick
--      a food that reduced boredom while RAISING unhappiness -- making the
--      moodle it was invoked for worse -- and its gate (isFood and not
--      isRotten) was weaker than this module's own isFoodSafe, so it could also
--      eat frozen or raw-cookable food that the hunger path already refuses.
--
--   2. WHETHER food may be spent.  AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY
--      has been defined and documented since Phase 3 but was read by no code:
--      the tasty-food sub-branch gated on HAPPINESS_LOW_THRESHOLD, so the
--      "relief runs at all" level and the "relief may eat" level were one knob.
--
-- Sign convention is verified against the live 42.19 install, not assumed:
-- the item tooltip marks a food good exactly when item:getUnhappyChange() < 0
-- (client/ISUI/ISInventoryPaneContextMenu.lua:2079-2082, the same shape as the
-- thirst row directly above it), and ISReadABook only lowers
-- CharacterStat.UNHAPPINESS when self.item:getUnhappyChange() < 0.0
-- (shared/TimedActions/ISReadABook.lua:72).  More negative = better.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_mood_food_choice.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.findNearestSquare    = function(_cx, _cy, _cz, _r, _pred) return nil end
AutoPilot_Utils.iterateNearbySquares = function(...) end

-- Part 1 exercises the REAL selector.  Part 2 needs AutoPilot_Inventory to be a
-- stub table (AutoPilot_Needs.check touches a dozen of its functions), so the
-- real module is loaded first, used, and then replaced below.
dofile("42/media/lua/client/AutoPilot_Inventory.lua")

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
local function assert_nil(desc, val)   assert_eq(desc, val == nil, true)   end

-- ── Item builder ──────────────────────────────────────────────────────────────
-- Mirrors the real food surface isFoodSafe reads.  Defaults are a plain, safe,
-- inert ration: edible, fresh, thawed, needing no cooking, moving neither
-- moodle.
local function food(cfg)
    cfg = cfg or {}
    return {
        getName          = function(_self) return cfg.name or "food" end,
        getType          = function(_self) return cfg.name or "food" end,
        isFood           = function(_self) return true end,
        isRotten         = function(_self) return cfg.rotten or false end,
        isFrozen         = function(_self) return cfg.frozen or false end,
        isIsCookable     = function(_self) return cfg.cookable or false end,
        isCooked         = function(_self) return cfg.cooked ~= false end,
        getCalories      = function(_self) return cfg.calories or 100 end,
        getHungerChange  = function(_self) return cfg.hungerChange or 0 end,
        getThirstChange  = function(_self) return 0 end,
        getUnhappyChange = function(_self) return cfg.unhappy or 0 end,
        getBoredomChange = function(_self) return cfg.boredom or 0 end,
    }
end

local function carrying(items)
    return MockContainer.attach(MockPlayer.new({}), MockContainer.new(items))
end

print("=== Part 1: which food the unhappy arm picks ===")

-- ── 1. HEADLINE: unhappiness outranks boredom ────────────────────────────────
-- The defect in one case: both foods are safe and both relieve boredom, but
-- only one relieves the moodle this arm was called for.
print("\n-- Test 1: the food that relieves UNHAPPINESS wins over the more boring-fighting one")
do
    local chocolate = food({ name = "Chocolate", unhappy =   0, boredom = -30 })
    local iceCream  = food({ name = "IceCream",  unhappy = -20, boredom =  -5 })
    local best = AutoPilot_Inventory.preferTastyFood(carrying({ chocolate, iceCream }))
    assert_eq("the unhappiness-reducing food is chosen", best and best:getName(), "IceCream")
end

-- ── 2. Never worsen the moodle being treated ─────────────────────────────────
print("\n-- Test 2: food that RAISES unhappiness is never eaten for unhappiness")
do
    local beans = food({ name = "BitterBeans", unhappy = 10, boredom = -30 })
    local best = AutoPilot_Inventory.preferTastyFood(carrying({ beans }))
    assert_nil("a boredom-reducing but unhappiness-raising food is refused", best)
end

-- ── 3. Boredom stays the tie-break ───────────────────────────────────────────
-- Most vanilla food carries no unhappiness value at all, so without a tie-break
-- the old behaviour would be lost.
print("\n-- Test 3: with no unhappiness values in play, the most boredom-reducing food wins")
do
    local chips = food({ name = "Chips", unhappy = 0, boredom =  -5 })
    local cake  = food({ name = "Cake",  unhappy = 0, boredom = -20 })
    local best = AutoPilot_Inventory.preferTastyFood(carrying({ chips, cake }))
    assert_eq("the boredom tie-break still applies", best and best:getName(), "Cake")
end

-- ── 4. Equal unhappiness, boredom decides ────────────────────────────────────
print("\n-- Test 4: equal unhappiness relief -> boredom decides between them")
do
    local candyA = food({ name = "CandyA", unhappy = -10, boredom =  -2 })
    local candyB = food({ name = "CandyB", unhappy = -10, boredom = -25 })
    local best = AutoPilot_Inventory.preferTastyFood(carrying({ candyA, candyB }))
    assert_eq("the more boredom-reducing of two equal moods wins",
        best and best:getName(), "CandyB")
end

-- ── 5-7. The safety gate the mood path used to skip ──────────────────────────
-- isFoodSafe is what the HUNGER path has always used.  Each of these would have
-- been eaten by the old mood path, which only checked isFood and isRotten.
print("\n-- Test 5: frozen food is refused even when it is the best mood food")
do
    local best = AutoPilot_Inventory.preferTastyFood(carrying({
        food({ name = "FrozenIceCream", unhappy = -30, boredom = -30, frozen = true }),
    }))
    assert_nil("frozen mood food is refused", best)
end

print("\n-- Test 6: raw food that still needs cooking is refused")
do
    local best = AutoPilot_Inventory.preferTastyFood(carrying({
        food({ name = "RawSteak", unhappy = -30, boredom = -30,
               cookable = true, cooked = false }),
    }))
    assert_nil("uncooked cookable mood food is refused", best)
end

print("\n-- Test 7: rotten food is still refused (unchanged, guarded)")
do
    local best = AutoPilot_Inventory.preferTastyFood(carrying({
        food({ name = "RottenCake", unhappy = -30, boredom = -30, rotten = true }),
    }))
    assert_nil("rotten mood food is refused", best)
end

-- ── 8. Inert food is not worth eating ────────────────────────────────────────
print("\n-- Test 8: food that moves neither moodle is not spent on mood relief")
do
    local best = AutoPilot_Inventory.preferTastyFood(carrying({
        food({ name = "Crackers", unhappy = 0, boredom = 0 }),
    }))
    assert_nil("an inert ration is not eaten for mood", best)
end

-- ── 9. The V4.8/V4.9 container contract still holds ──────────────────────────
print("\n-- Test 9: bagged mood food is still found, and its container reported")
do
    local cake = food({ name = "Cake", unhappy = -15, boredom = -5 })
    local bag  = MockContainer.bag("Backpack", { cake })
    local inner = bag:getItemContainer()
    local player = MockContainer.attach(MockPlayer.new({}), MockContainer.new({ bag }))

    local best, cont = AutoPilot_Inventory.preferTastyFood(player)
    assert_eq("the bagged mood food is selected", best, cake)
    assert_eq("its holding container is reported for the transfer", cont, inner)
end

-- ── 10. Empty inventory ──────────────────────────────────────────────────────
print("\n-- Test 10: nothing carried -> no selection")
do
    assert_nil("an empty inventory yields nil", AutoPilot_Inventory.preferTastyFood(carrying({})))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Part 2: HAPPINESS_FOOD_PRIORITY, the gate that decides whether the unhappy
-- arm may spend food at all.  From here on AutoPilot_Inventory is a stub table,
-- because AutoPilot_Needs.check() reaches into a dozen of its functions.
-- ─────────────────────────────────────────────────────────────────────────────

ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}

AutoPilot_Medical = {
    hasCriticalWound = function(_player) return false end,
    check            = function(_player, _bleedingOnly) return false end,
}

AutoPilot_Home = {
    isSet            = function(_player) return false end,
    isInside         = function(_sq) return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

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

dofile("42/media/lua/client/AutoPilot_Consumption.lua")
dofile("42/media/lua/client/AutoPilot_Sleep.lua")
dofile("42/media/lua/client/AutoPilot_Rest.lua")
dofile("42/media/lua/client/AutoPilot_Exercise.lua")
dofile("42/media/lua/client/AutoPilot_Needs.lua")

local LOW_THRESHOLD  = AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD
local FOOD_PRIORITY  = AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY

-- An otherwise-contented character: nothing above the mood step in the chain
-- has a reason to claim the cycle, and boredom sits BELOW its threshold so only
-- unhappiness drives the branch under test.
local function unhappyPlayer(level)
    return MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = 0.90,
            BOREDOM   = 0,
            SANITY    = 0,
        },
        moodles = { ENDURANCE = 0, UNHAPPY = level },
    })
end

local function book(name)
    return {
        getName             = function(_self) return name end,
        getNumberOfPages    = function(_self) return 100 end,
        getAlreadyReadPages = function(_self) return 0 end,
    }
end

local cake = { getName = function(_s) return "Cake" end,
               getCalories = function(_s) return 500 end }

-- Both relief arms are always available, so which one fires is decided purely
-- by the gate under test rather than by what the character happens to carry.
local function armRelief()
    ISTimedActionQueue_calls = {}
    MockTime.advance(120000)
    AutoPilot_Inventory.preferTastyFood = function(_player) return cake, nil end
    AutoPilot_Inventory.getReadable     = function(_player) return book("Novel"), nil end
end

local function last_action_type()
    local c = ISTimedActionQueue_calls
    if #c == 0 then return nil end
    return c[#c].type
end

print("\n=== Part 2: HAPPINESS_FOOD_PRIORITY gates the food arm ===")

-- ── 11. Default configuration is unchanged ───────────────────────────────────
print("\n-- Test 11: at the shipped defaults the unhappy arm still eats")
do
    armRelief()
    assert_eq("the two levels ship equal, so the default behaviour is unchanged",
        FOOD_PRIORITY, LOW_THRESHOLD)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(unhappyPlayer(LOW_THRESHOLD), true))
    assert_eq("mood food is eaten", last_action_type(), "eat")
end

-- ── 12. BEHAVIOUR DIFFERENCE: raising the gate withholds food ────────────────
-- This is the case that fails against the pre-fix code, where the constant was
-- read by nothing and the food arm gated on HAPPINESS_LOW_THRESHOLD instead.
print("\n-- Test 12: raising HAPPINESS_FOOD_PRIORITY makes mild unhappiness read, not eat")
do
    AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY = LOW_THRESHOLD + 1
    armRelief()
    assert_true("relief still runs (the entry threshold is unchanged)",
        AutoPilot_Needs.check(unhappyPlayer(LOW_THRESHOLD), true))
    assert_eq("food is withheld and the character reads instead",
        last_action_type(), "read")
end

-- ── 13. ...and the food arm returns at the raised level ──────────────────────
print("\n-- Test 13: at or above the raised gate the unhappy arm eats again")
do
    armRelief()
    assert_true("check() claims the cycle",
        AutoPilot_Needs.check(unhappyPlayer(LOW_THRESHOLD + 1), true))
    assert_eq("mood food is eaten once the raised gate is met",
        last_action_type(), "eat")
    AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY = FOOD_PRIORITY
end

-- ── 14. Below the entry threshold nothing happens at all ─────────────────────
print("\n-- Test 14: below HAPPINESS_LOW_THRESHOLD neither arm fires")
do
    armRelief()
    AutoPilot_Needs.check(unhappyPlayer(LOW_THRESHOLD - 1), true)
    -- The cycle falls through the mood step to a later one (exercise), so the
    -- assertion is that NEITHER relief arm fired, not that nothing was queued.
    local acted = last_action_type()
    assert_true("no mood food is eaten for a contented character", acted ~= "eat")
    assert_true("no book is read for a contented character", acted ~= "read")
    assert_eq("the constant was restored after Test 13",
        AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY, FOOD_PRIORITY)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
