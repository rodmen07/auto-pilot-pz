-- tests/test_food_malus.lua
-- V6.0-1: malus-aware EAT ranking.
--
-- The user's V6.0 decision was "prioritise food gathering and eating by the
-- ABSENCE OF MALUS EFFECTS".  A source read (docs/MILESTONE_V6_0.md section 2)
-- found the eat path was already doing the OPPOSITE of what a naive "filter
-- harder" reading would add: AutoPilot_Inventory.isFoodSafe ended
--
--     return unhappy <= 0 and boring <= 0
--
-- and every hunger-path selector ran through it, so a food the game considers
-- edible but joyless was not deprioritised, it was INVISIBLE, at any hunger
-- level, with no override.  Measured against the installed 42.19 item scripts
-- (media/scripts/generated/items/food.txt, 722 item blocks): 141 foods define a
-- positive UnhappyChange and 46 of those are not cookable, so that one clause
-- was the SOLE reason the mod could never eat them -- Pasta (40), Macaroni (40),
-- Ramen (20), Butter (20), Coffee2 (20), cheese_powdered (14), Teabag2 (10).
-- A character carrying only dry pasta and ramen starved while "having food".
--
-- So the predicate is split in two:
--
--   isFoodEdible(item)          the SAFETY gate, never overridden by hunger:
--                               not rotten, not frozen, not uncooked-cookable,
--                               getPoisonPower() <= 0, not isTainted().
--   foodMalusScore(item)        the PREFERENCE, lower is better, built from the
--                               POSITIVE part of getUnhappyChange/getBoredomChange.
--
-- Malus-free food is preferred; each selector's own key (calories, hunger fit,
-- weight fit) decides within a malus tier; malus food is eaten only when
-- nothing better is carried.  Poison and taint are the only NEW hard rejects,
-- because those two are safety properties rather than preferences.
--
-- Both new engine getters were verified live in the 42.19 install before being
-- called, not assumed (verified-surface discipline):
--   item:getPoisonPower()  client/ISUI/ISInventoryPane.lua:2094,2097 and
--                          client/Foraging/ISForageIcon.lua:24
--   item:isTainted()       client/ISUI/ISInventoryPane.lua:2310,2349, guarded
--                          there on instanceof(item, "Food") exactly as here
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_food_malus.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.findNearestSquare    = function(_cx, _cy, _cz, _r, _pred) return nil end
AutoPilot_Utils.iterateNearbySquares = function(...) end

-- V6.0-2 additions.  The loot path walks real world squares, so it needs the
-- three modules _iterateContainersNearby and _queueTransfer call into, plus the
-- two engine globals the transfer touches.  Same harness as
-- tests/test_carry_capacity.lua:38-47, which already drives lootNearbyFood.
dofile("42/media/lua/client/AutoPilot_Map.lua")
dofile("42/media/lua/client/AutoPilot_Home.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")

ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}
luautils = { walkAdj = function(_player, _sq, _) end }

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

local function assert_true(desc, val) assert_eq(desc, not not val, true) end
local function assert_nil(desc, val)  assert_eq(desc, val == nil, true)  end

-- ── Item builder ──────────────────────────────────────────────────────────────
-- Mirrors the real food surface the split predicate reads, INCLUDING the two
-- getters V6.0-1 adds.  Defaults are a plain, safe, inert ration: edible,
-- fresh, thawed, needing no cooking, non-poisonous, untainted, moving neither
-- moodle.  Existing suites keep their own narrower factories on purpose (the
-- pcall guards in isFoodEdible are what lets those keep passing unchanged).
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
        getHungerChange  = function(_self) return cfg.hungerChange or -20 end,
        getThirstChange  = function(_self) return 0 end,
        getUnhappyChange = function(_self) return cfg.unhappy or 0 end,
        getBoredomChange = function(_self) return cfg.boredom or 0 end,
        getPoisonPower   = function(_self) return cfg.poison or 0 end,
        isTainted        = function(_self) return cfg.tainted or false end,
    }
end

local function carrying(items)
    return MockContainer.attach(MockPlayer.new({}), MockContainer.new(items))
end

-- Every hunger-path selector, run over the same pack.  "At any hunger" in the
-- poison and taint cases means literally every selector at both ends of the
-- hunger range, not one spot check.
local function allSelectors(player)
    return {
        { name = "getBestFood",                 item = AutoPilot_Inventory.getBestFood(player) },
        { name = "getBestFoodForHunger(0.05)",  item = AutoPilot_Inventory.getBestFoodForHunger(player, 0.05) },
        { name = "getBestFoodForHunger(0.95)",  item = AutoPilot_Inventory.getBestFoodForHunger(player, 0.95) },
        { name = "selectFoodByWeight",          item = AutoPilot_Inventory.selectFoodByWeight(player) },
    }
end

print("=== V6.0-1: malus-aware eat ranking ===")

-- ── 1. HEADLINE: the starvation gap closes ───────────────────────────────────
-- Done-when 3a.  Before this slice getBestFood returned nil here, because
-- isFoodSafe rejected every candidate on `unhappy <= 0`.
print("\n-- Test 1: a pack holding only joyless food is now edible, not invisible")
do
    local pasta = food({ name = "Pasta", unhappy = 40, calories = 300 })
    local ramen = food({ name = "Ramen", unhappy = 20, calories = 250 })
    local player = carrying({ pasta, ramen })

    for _, sel in ipairs(allSelectors(player)) do
        assert_true(("%s feeds a character carrying only malus food"):format(sel.name),
            sel.item ~= nil)
    end
    -- ...and it picks the LEAST bad of the two, not just any of them.
    assert_eq("the lower-malus food wins between two malus foods",
        AutoPilot_Inventory.getBestFood(player):getName(), "Ramen")
end

-- ── 2. Malus-free food is preferred, at equal calories ───────────────────────
-- Done-when 3b, the literal case: nothing but the malus separates them.
print("\n-- Test 2: at equal calories the malus-free food wins")
do
    local plain  = food({ name = "CannedBeans", calories = 300 })
    local bitter = food({ name = "Pasta", unhappy = 40, calories = 300 })
    assert_eq("equal calories, malus-free chosen",
        AutoPilot_Inventory.getBestFood(carrying({ bitter, plain })):getName(), "CannedBeans")
    -- Order-independence: the loop must not be able to win by arriving first.
    assert_eq("still chosen when the malus food is visited first",
        AutoPilot_Inventory.getBestFood(carrying({ plain, bitter })):getName(), "CannedBeans")
end

-- ── 3. Preference outranks the selector's own key ────────────────────────────
-- "Eat malus food whenever nothing better is carried" (milestone Q3) is a
-- stronger statement than a tie-break: a malus-free option beats a
-- malus-carrying one even when the malus one scores better on calories.
print("\n-- Test 3: malus-free beats a higher-calorie malus food")
do
    local small = food({ name = "Crackers", calories = 100 })
    local big   = food({ name = "Pasta", unhappy = 40, calories = 400 })
    assert_eq("the malus-free 100-calorie food beats the 400-calorie one",
        AutoPilot_Inventory.getBestFood(carrying({ big, small })):getName(), "Crackers")
end

-- ── 4. Within a malus tier the old keys are untouched ────────────────────────
-- The regression guard for the ranking change: among malus-free food every
-- selector must behave exactly as it did before V6.0-1.
print("\n-- Test 4: among malus-free food, each selector keeps its own key")
do
    local small = food({ name = "Crackers", calories = 100, hungerChange = -10 })
    local big   = food({ name = "Ham",      calories = 400, hungerChange = -60 })
    local player = carrying({ small, big })

    assert_eq("getBestFood still maximises calories",
        AutoPilot_Inventory.getBestFood(player):getName(), "Ham")
    assert_eq("getBestFoodForHunger still fits the hunger level",
        AutoPilot_Inventory.getBestFoodForHunger(player, 0.10):getName(), "Crackers")
end

-- ── 5. Boredom counts as a malus too ─────────────────────────────────────────
print("\n-- Test 5: a boredom-raising food is ranked below a malus-free one")
do
    local plain = food({ name = "CannedBeans", calories = 300 })
    local dull  = food({ name = "DriedRation", boredom = 25, calories = 300 })
    assert_eq("positive boredom is a malus, not just unhappiness",
        AutoPilot_Inventory.getBestFood(carrying({ dull, plain })):getName(), "CannedBeans")
end

-- ── 6. A mood BONUS is not a malus ───────────────────────────────────────────
-- Only the positive part of each change is penalised, so a food that REDUCES a
-- moodle ties with an inert ration and the existing key still decides.  Without
-- this, ranking the bonus here would quietly duplicate preferTastyFood's job.
print("\n-- Test 6: negative unhappy/boredom values score the same as inert food")
do
    assert_eq("a mood-improving food scores 0",
        AutoPilot_Inventory.foodMalusScore(food({ unhappy = -30, boredom = -30 })), 0)
    assert_eq("an inert ration also scores 0",
        AutoPilot_Inventory.foodMalusScore(food({})), 0)
    assert_eq("malus is the sum of the positive parts only",
        AutoPilot_Inventory.foodMalusScore(food({ unhappy = 40, boredom = -30 })), 40)
    local tasty = food({ name = "Cake", unhappy = -30, calories = 100 })
    local big   = food({ name = "Ham",  calories = 400 })
    assert_eq("so calories still decide between a tasty and a plain food",
        AutoPilot_Inventory.getBestFood(carrying({ tasty, big })):getName(), "Ham")
end

-- ── 7. Poison is a HARD reject, at any hunger, in every selector ─────────────
-- Done-when 3c.  Q2's default: the mod reads getPoisonPower() directly rather
-- than player:isKnownPoison(item), so it avoids poison the CHARACTER would not
-- recognise.  A foraging-illiterate character who eats a poisonous berry dies
-- just as dead.
print("\n-- Test 7: a poisonous item is never selected, at any hunger")
do
    local berry = food({ name = "PoisonBerry", poison = 30, calories = 500 })
    local player = carrying({ berry })
    for _, sel in ipairs(allSelectors(player)) do
        assert_nil(("%s refuses a poisonous item even as the only food"):format(sel.name),
            sel.item)
    end
    -- And it never wins over safe food either, despite the higher calories.
    local beans = food({ name = "CannedBeans", calories = 100 })
    assert_eq("safe food is chosen over higher-calorie poison",
        AutoPilot_Inventory.getBestFood(carrying({ berry, beans })):getName(), "CannedBeans")
    -- The mood arm inherits the same gate: it runs through isFoodSafe, which is
    -- now isFoodEdible plus the malus clause.
    assert_nil("mood relief also refuses poison",
        AutoPilot_Inventory.preferTastyFood(carrying({
            food({ name = "PoisonCake", poison = 10, unhappy = -30 }) })))
end

-- ── 8. Taint is a HARD reject, at any hunger, in every selector ──────────────
-- Done-when 3d.
print("\n-- Test 8: a tainted item is never selected, at any hunger")
do
    local stew = food({ name = "TaintedStew", tainted = true, calories = 500 })
    local player = carrying({ stew })
    for _, sel in ipairs(allSelectors(player)) do
        assert_nil(("%s refuses a tainted item even as the only food"):format(sel.name),
            sel.item)
    end
    local beans = food({ name = "CannedBeans", calories = 100 })
    assert_eq("safe food is chosen over higher-calorie taint",
        AutoPilot_Inventory.getBestFood(carrying({ stew, beans })):getName(), "CannedBeans")
    assert_nil("mood relief also refuses tainted food",
        AutoPilot_Inventory.preferTastyFood(carrying({
            food({ name = "TaintedCake", tainted = true, unhappy = -30 }) })))
end

-- ── 9. The old safety gates did not move ─────────────────────────────────────
-- isFoodEdible must still reject everything isFoodSafe rejected apart from the
-- two moodle clauses.  Without this the split could quietly widen the gate.
print("\n-- Test 9: rotten, frozen and uncooked-cookable food is still refused")
do
    assert_nil("rotten food is still refused",
        AutoPilot_Inventory.getBestFood(carrying({ food({ rotten = true }) })))
    assert_nil("frozen food is still refused",
        AutoPilot_Inventory.getBestFood(carrying({ food({ frozen = true }) })))
    assert_nil("uncooked cookable food is still refused",
        AutoPilot_Inventory.getBestFood(carrying({
            food({ cookable = true, cooked = false }) })))
    assert_true("cooked cookable food is accepted",
        AutoPilot_Inventory.getBestFood(carrying({
            food({ cookable = true, cooked = true }) })) ~= nil)
end

-- ── 10. Guarded calls: an item stub without the new getters still works ──────
-- The reason isFoodEdible pcall-wraps getPoisonPower/isTainted.  Four existing
-- suites build item stubs that predate V6.0-1 and define neither getter; this
-- reproduces that shape so the guard has its own test rather than relying on
-- those suites staying green by luck.
print("\n-- Test 10: a pre-V6.0 item stub (no poison/taint getters) is still edible")
do
    local legacy = {
        getName          = function(_self) return "LegacyRation" end,
        getType          = function(_self) return "LegacyRation" end,
        isFood           = function(_self) return true end,
        isRotten         = function(_self) return false end,
        isFrozen         = function(_self) return false end,
        isIsCookable     = function(_self) return false end,
        isCooked         = function(_self) return true end,
        getCalories      = function(_self) return 150 end,
        getHungerChange  = function(_self) return -20 end,
        getUnhappyChange = function(_self) return 0 end,
        getBoredomChange = function(_self) return 0 end,
    }
    assert_eq("a stub missing getPoisonPower/isTainted is still selectable",
        AutoPilot_Inventory.getBestFood(carrying({ legacy })):getName(), "LegacyRation")
    assert_eq("and scores as malus-free", AutoPilot_Inventory.foodMalusScore(legacy), 0)
end

-- ── 11. The V4.8/V4.9 container contract still holds ─────────────────────────
print("\n-- Test 11: bagged malus food is found, and its container reported")
do
    local pasta = food({ name = "Pasta", unhappy = 40, calories = 300 })
    local bag   = MockContainer.bag("Backpack", { pasta })
    local inner = bag:getItemContainer()
    local player = MockContainer.attach(MockPlayer.new({}), MockContainer.new({ bag }))

    local best, cont = AutoPilot_Inventory.getBestFood(player)
    assert_eq("the bagged malus food is found", best and best:getName(), "Pasta")
    assert_eq("its holding container is reported", cont, inner)
end

-- ═══ V6.0-2: malus-aware LOOT preference ══════════════════════════════════════
-- The gathering half of the same user decision.  V6.0-1 changed what the mod
-- EATS out of its own pack; this changes what it PICKS UP, reusing the one
-- foodMalusScore helper so the two halves cannot rank food differently.

-- Publish one world container on the player's own square holding `items`.
-- Mirrors tests/test_carry_capacity.lua:104-123.
local function placeContainer(items)
    local container = MockContainer.new(items)
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, cb)
            local sq = {}
            local obj = {
                getContainer = function(_self) return container end,
                getSquare    = function(_self) return sq end,
            }
            sq.getObjects = function(_self)
                return { size = function(_s) return 1 end,
                         get  = function(_s, _i) return obj end }
            end
            sq.getX = function(_self) return 0 end
            sq.getY = function(_self) return 0 end
            sq.getZ = function(_self) return 0 end
            cb(sq, 0, 0)
        end
    return container
end

local function resetQueue() ISTimedActionQueue_calls = {} end

-- The item the loot path actually queued, or nil.
local function lootedItem(player)
    resetQueue()
    local queued = AutoPilot_Inventory.lootNearbyFood(player)
    if not queued or #ISTimedActionQueue_calls == 0 then return nil end
    return ISTimedActionQueue_calls[1].item
end

-- ── 12. HEADLINE: the loot ranking difference ────────────────────────────────
-- Done-when 2 of docs/MILESTONE_V6_0.md section V6.0-2, literally: a malus-free
-- 200-calorie item and a malus-carrying 400-calorie item in the same container,
-- and the malus-free one is the one transferred.  Before this slice the loot
-- path took the highest-calorie item outright, so it would have taken the Pasta.
print("\n-- Test 12: looting prefers the malus-free food over a higher-calorie one")
do
    local plain = food({ name = "CannedBeans", calories = 200 })
    local pasta = food({ name = "Pasta", unhappy = 40, calories = 400 })
    local player = MockPlayer.new({})

    placeContainer({ pasta, plain })
    local got = lootedItem(player)
    assert_eq("the malus-free 200-calorie food is looted, not the 400-calorie one",
        got and got:getName(), "CannedBeans")

    -- Order-independence: arriving first must not win, in either direction.
    placeContainer({ plain, pasta })
    local got2 = lootedItem(player)
    assert_eq("still chosen when the malus food is scanned second",
        got2 and got2:getName(), "CannedBeans")
end

-- ── 13. Calories still decide inside a malus tier ────────────────────────────
-- The regression guard for the loot ranking: among equally-malus food the old
-- highest-calorie key is untouched, including among equally BAD food.
print("\n-- Test 13: within one malus tier the calorie key is unchanged")
do
    local player = MockPlayer.new({})

    placeContainer({ food({ name = "Crackers", calories = 100 }),
                     food({ name = "Ham",      calories = 400 }) })
    local got = lootedItem(player)
    assert_eq("among malus-free food the highest-calorie item still wins",
        got and got:getName(), "Ham")

    placeContainer({ food({ name = "Ramen", unhappy = 20, calories = 100 }),
                     food({ name = "Pasta", unhappy = 20, calories = 400 }) })
    local got2 = lootedItem(player)
    assert_eq("among equally-malus food the highest-calorie item still wins",
        got2 and got2:getName(), "Pasta")
end

-- ── 14. THE INVARIANT: the loot predicate stays a superset of the counter ────
-- Done-when 3.  The in-code comment at AutoPilot_Inventory.lootNearbyFood
-- records why: when the loot predicate and getSupplyCounts disagree, the mod
-- hauls items its own supply counter refuses to count and loots forever.  So
-- V6.0-2 had to be a RANKING change with the predicate untouched.
--
-- This is a drift guard, not a one-time reconciliation: it reads BOTH sources
-- for the same item -- what lootNearbyFood picks up, and what getSupplyCounts
-- counts once carried -- so re-tightening either one alone fails here.
print("\n-- Test 14: malus food the supply counter counts is still lootable")
do
    -- Nothing better nearby: a malus-carrying food is the only candidate.
    local pasta = food({ name = "Pasta", unhappy = 40, calories = 300 })
    placeContainer({ pasta })
    local got = lootedItem(MockPlayer.new({}))
    assert_eq("malus food is still looted when nothing better is nearby",
        got and got:getName(), "Pasta")

    -- ...and the counter counts that same item, which is what closes the loop.
    local foodCount, drinkCount = AutoPilot_Inventory.getSupplyCounts(
        carrying({ food({ name = "Pasta", unhappy = 40, calories = 300 }) }))
    assert_eq("and getSupplyCounts counts it as food", foodCount, 1)
    assert_eq("not as a drink", drinkCount, 0)

    -- Poison and taint are EAT-path safety gates, not loot-path filters.  The
    -- superset invariant is why: getSupplyCounts counts a tainted 300-calorie
    -- food, so refusing to loot it would reopen the mismatch this test guards.
    placeContainer({ food({ name = "TaintedStew", tainted = true, calories = 300 }) })
    local tainted = lootedItem(MockPlayer.new({}))
    assert_eq("a tainted food the counter counts is still lootable",
        tainted and tainted:getName(), "TaintedStew")
    local tcount = AutoPilot_Inventory.getSupplyCounts(
        carrying({ food({ name = "TaintedStew", tainted = true, calories = 300 }) }))
    assert_eq("because the counter counts it too", tcount, 1)
    -- The eat path is where it is refused, and Test 8 already proves that.
end

-- ── 15. The non-food half of the predicate did not move either ───────────────
-- Drinks and calorie-free items are getSupplyCounts' OTHER two buckets.  The
-- ranking rewrite must not have let either leak into the food loot path.
print("\n-- Test 15: drinks and calorie-free items are still not food loot")
do
    local drink = food({ name = "WaterBottle", calories = 0 })
    drink.getThirstChange = function(_self) return -20 end
    placeContainer({ drink })
    assert_nil("a hydrating drink is not taken by the FOOD loot path",
        lootedItem(MockPlayer.new({})))

    placeContainer({ food({ name = "Teabag", calories = 0 }) })
    assert_nil("a calorie-free item is not taken by the food loot path",
        lootedItem(MockPlayer.new({})))
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
