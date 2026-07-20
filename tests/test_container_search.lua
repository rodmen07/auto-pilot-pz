-- tests/test_container_search.lua
-- V4.8: carried-inventory search must descend into worn and carried
-- sub-containers (backpacks, fanny packs, bags inside bags).
--
-- Before V4.8 every selector scanned player:getInventory():getItems(), which
-- lists ONLY the top-level items of the main inventory.  Anything stashed in a
-- bag was invisible: the reported symptom was a scratched character refusing to
-- bandage with a bandage sitting in a fanny pack, but food, drink, weapons and
-- clothing were equally unreachable.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_container_search.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.findNearestSquare    = function(_cx, _cy, _cz, _r, _pred) return nil end
AutoPilot_Utils.iterateNearbySquares = function(...) end

dofile("42/media/lua/client/AutoPilot_Map.lua")
dofile("42/media/lua/client/AutoPilot_Home.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")

ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}
ISTakeWaterAction = {
    new = function(_, _player, container, _waterObj, _tainted)
        return { type = "take_water", container = container }
    end,
}
-- V4.9: adjustClothing and checkAndSwapWeapon queue these behind a transfer.
ISWearClothing = {
    new = function(_, _player, item, _time)
        return { type = "wear", item = item }
    end,
}
ISEquipWeaponAction = {
    new = function(_, _player, item, _time, _primary)
        return { type = "equip_weapon", item = item }
    end,
}
luautils = { walkAdj = function(_player, _sq, _) end }

-- Suite-local enums: the shared mock records these as a documented gap because
-- every production callsite is pcall-guarded.  The V4.9 readable case needs the
-- guarded branch to actually SUCCEED, so the two keys the mod reads are defined
-- here (and nowhere else, keeping the gap intact for the other suites).
ItemType = { LITERATURE = "LITERATURE" }
ItemTag  = { UNINTERESTING = "UNINTERESTING" }

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
local function assert_false(desc, val) assert_eq(desc, not not val, false) end

-- ── Item builders ─────────────────────────────────────────────────────────────

-- A plain (non-container) inventory item.  Deliberately has NO
-- getItemContainer, matching a real non-container item.
local function makeItem(cfg)
    cfg = cfg or {}
    return {
        getName         = function(_self) return cfg.name or "item" end,
        getType         = function(_self) return cfg.type or cfg.name or "item" end,
        isFood          = function(_self) return cfg.isFood or false end,
        isRotten        = function(_self) return cfg.isRotten or false end,
        isFrozen        = function(_self) return cfg.isFrozen or false end,
        isIsCookable    = function(_self) return false end,
        isCooked        = function(_self) return true end,
        getCalories     = function(_self) return cfg.calories or 0 end,
        getHungerChange = function(_self) return cfg.hungerChange or 0 end,
        getThirstChange = function(_self) return cfg.thirstChange or 0 end,
        getUnhappyChange = function(_self) return cfg.unhappy or 0 end,
        getBoredomChange = function(_self) return cfg.boredom or 0 end,
        isCanBandage    = function(_self) return cfg.canBandage or false end,
    }
end

local function player()
    return MockPlayer.new({})
end

-- ── 1. iteratePlayerItems: flat inventory still works ─────────────────────────
print("=== V4.8 Test 1: flat inventory is still fully visited ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        makeItem({ name = "A" }), makeItem({ name = "B" }),
    }))
    local seen = {}
    AutoPilot_Utils.iteratePlayerItems(p, function(item)
        table.insert(seen, item:getName())
        return false
    end)
    assert_eq("both top-level items visited", #seen, 2)
    assert_eq("first item is A (main inventory order preserved)", seen[1], "A")
end

-- ── 2. iteratePlayerItems: descends into a bag ────────────────────────────────
print("\n=== V4.8 Test 2: items inside a bag are visited ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        makeItem({ name = "Top" }),
        MockContainer.bag("Backpack", { makeItem({ name = "InBag" }) }),
    }))
    local names = {}
    AutoPilot_Utils.iteratePlayerItems(p, function(item)
        names[item:getName()] = true
        return false
    end)
    assert_true("top-level item visited", names["Top"])
    assert_true("bag itself is visited as an item", names["Backpack"])
    assert_true("item inside the bag is visited", names["InBag"])
end

-- ── 3. Depth reporting: main inventory is depth 0, bag contents depth 1 ───────
print("\n=== V4.8 Test 3: depth is reported per nesting level ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        MockContainer.bag("Backpack", {
            MockContainer.bag("FannyPack", { makeItem({ name = "Deep" }) }),
        }),
    }))
    local depths = {}
    AutoPilot_Utils.iteratePlayerItems(p, function(item, _container, depth)
        depths[item:getName()] = depth
        return false
    end)
    assert_eq("Backpack sits at depth 0", depths["Backpack"], 0)
    assert_eq("FannyPack sits at depth 1", depths["FannyPack"], 1)
    assert_eq("item in the nested fanny pack sits at depth 2", depths["Deep"], 2)
end

-- ── 4. Early stop ─────────────────────────────────────────────────────────────
print("\n=== V4.8 Test 4: callback returning true stops iteration ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        makeItem({ name = "A" }), makeItem({ name = "B" }), makeItem({ name = "C" }),
    }))
    local count = 0
    local stopped = AutoPilot_Utils.iteratePlayerItems(p, function()
        count = count + 1
        return count == 2
    end)
    assert_true("iteratePlayerItems reports the early stop", stopped)
    assert_eq("iteration halted at the second item", count, 2)
end

-- ── 5. Depth guard: nesting beyond the limit terminates ───────────────────────
print("\n=== V4.8 Test 5: depth guard bounds a deeply nested bag chain ===")
do
    -- Build a chain deeper than PLAYER_ITEM_MAX_DEPTH with a marker at the end.
    local innermost = MockContainer.bag("Bag6", { makeItem({ name = "TooDeep" }) })
    local chain = innermost
    for i = 5, 1, -1 do
        chain = MockContainer.bag("Bag" .. i, { chain })
    end
    local p = MockContainer.attach(player(), MockContainer.new({ chain }))

    local names = {}
    AutoPilot_Utils.iteratePlayerItems(p, function(item)
        names[item:getName()] = true
        return false
    end)
    assert_true("walk terminates (no stack overflow / hang)", true)
    assert_true("bags within the depth limit are visited", names["Bag3"])
    assert_false("items beyond PLAYER_ITEM_MAX_DEPTH are not visited",
        names["TooDeep"])
end

-- ── 6. Cycle guard: a self-referential bag visits once and terminates ─────────
print("\n=== V4.8 Test 6: self-referential container terminates ===")
do
    local inner = MockContainer.new({})
    local selfBag = {
        getName          = function(_self) return "SelfBag" end,
        getType          = function(_self) return "SelfBag" end,
        isFood           = function(_self) return false end,
        isRotten         = function(_self) return false end,
        isCanBandage     = function(_self) return false end,
        getItemContainer = function(_self) return inner end,
    }
    -- The bag contains ITSELF: walking it must not recurse forever.
    inner:add(selfBag)

    local p = MockContainer.attach(player(), MockContainer.new({ selfBag }))
    local visits = 0
    AutoPilot_Utils.iteratePlayerItems(p, function()
        visits = visits + 1
        return false
    end)
    assert_true("self-referential container terminates", true)
    assert_true("each container is walked at most once", visits <= 4)
end

-- ── 7. Non-container items are safe ───────────────────────────────────────────
print("\n=== V4.8 Test 7: items without getItemContainer are treated as leaves ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        makeItem({ name = "Rock" }),
    }))
    local visits = 0
    AutoPilot_Utils.iteratePlayerItems(p, function()
        visits = visits + 1
        return false
    end)
    assert_eq("plain item visited exactly once", visits, 1)
end

-- ── 8. Degrades safely when the engine lacks getItemContainer ─────────────────
print("\n=== V4.8 Test 8: missing getItemContainer degrades to top-level only ===")
do
    -- A "bag" whose accessor raises, standing in for a build where the surface
    -- is unavailable: the walk must fall back to pre-V4.8 behavior, not error.
    local hostile = {
        getName          = function(_self) return "BrokenBag" end,
        getType          = function(_self) return "BrokenBag" end,
        isFood           = function(_self) return false end,
        isRotten         = function(_self) return false end,
        isCanBandage     = function(_self) return false end,
        getItemContainer = function(_self) error("no such method") end,
    }
    local p = MockContainer.attach(player(), MockContainer.new({
        hostile, makeItem({ name = "Top" }),
    }))
    local names = {}
    local ok = pcall(function()
        AutoPilot_Utils.iteratePlayerItems(p, function(item)
            names[item:getName()] = true
            return false
        end)
    end)
    assert_true("walk does not propagate the engine error", ok)
    assert_true("remaining top-level items are still visited", names["Top"])
end

-- ── 9. findPlayerItem returns the item and its holding container ──────────────
print("\n=== V4.8 Test 9: findPlayerItem reports the holding container ===")
do
    local bag = MockContainer.bag("Backpack", { makeItem({ name = "Needle" }) })
    local mainInv = MockContainer.new({ bag })
    local p = MockContainer.attach(player(), mainInv)

    local item, container = AutoPilot_Utils.findPlayerItem(p, function(it)
        return it:getName() == "Needle"
    end)
    assert_eq("nested item found", item and item:getName(), "Needle")
    assert_eq("container is the bag's inner container, not the main inventory",
        container, bag._container)
end

-- ── 10. findPlayerItem: no match returns nil ──────────────────────────────────
print("\n=== V4.8 Test 10: findPlayerItem returns nil when nothing matches ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        makeItem({ name = "Rock" }),
    }))
    local item = AutoPilot_Utils.findPlayerItem(p, function() return false end)
    assert_eq("no match returns nil", item, nil)
end

-- ── 11. getBestFood finds food only present inside a bag ──────────────────────
print("\n=== V4.8 Test 11: getBestFood sees food inside a backpack ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        MockContainer.bag("Backpack", {
            makeItem({ name = "Beans", isFood = true, calories = 300 }),
        }),
    }))
    local best = AutoPilot_Inventory.getBestFood(p)
    assert_eq("food inside a bag is selected", best and best:getName(), "Beans")
end

-- ── 12. getBestFood still ranks by calories across depths ─────────────────────
print("\n=== V4.8 Test 12: highest-calorie food wins regardless of depth ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        makeItem({ name = "Crisps", isFood = true, calories = 100 }),
        MockContainer.bag("Backpack", {
            MockContainer.bag("FannyPack", {
                makeItem({ name = "Steak", isFood = true, calories = 900 }),
            }),
        }),
    }))
    local best = AutoPilot_Inventory.getBestFood(p)
    assert_eq("deep high-calorie food outranks a shallow low-calorie one",
        best and best:getName(), "Steak")
end

-- ── 13. getBestDrink finds a drink only present inside a bag ──────────────────
print("\n=== V4.8 Test 13: getBestDrink sees a drink inside a fanny pack ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        MockContainer.bag("FannyPack", {
            makeItem({ name = "WaterBottle", isFood = true, thirstChange = -30 }),
        }),
    }))
    local drink = AutoPilot_Inventory.getBestDrink(p)
    assert_eq("drink inside a bag is selected", drink and drink:getName(), "WaterBottle")
end

-- ── 14. getBestDrink still prefers a top-level item when one exists ───────────
print("\n=== V4.8 Test 14: top-level drink still wins (order preserved) ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        makeItem({ name = "TopWater", isFood = true, thirstChange = -20 }),
        MockContainer.bag("Backpack", {
            makeItem({ name = "BagWater", isFood = true, thirstChange = -50 }),
        }),
    }))
    local drink = AutoPilot_Inventory.getBestDrink(p)
    assert_eq("first-match semantics still favour the main inventory",
        drink and drink:getName(), "TopWater")
end

-- ── 15. getSupplyCounts counts nested food and drink ──────────────────────────
print("\n=== V4.8 Test 15: getSupplyCounts counts items inside bags ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        makeItem({ name = "TopBeans", isFood = true, calories = 200 }),
        MockContainer.bag("Backpack", {
            makeItem({ name = "BagBeans", isFood = true, calories = 250 }),
            makeItem({ name = "BagWater", isFood = true, thirstChange = -30 }),
        }),
    }))
    local food, drink = AutoPilot_Inventory.getSupplyCounts(p)
    assert_eq("food count includes the bagged tin", food, 2)
    assert_eq("drink count includes the bagged bottle", drink, 1)
end

-- ── 16. getBestFoodForHunger sees nested food ─────────────────────────────────
print("\n=== V4.8 Test 16: getBestFoodForHunger sees nested food ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        MockContainer.bag("Backpack", {
            makeItem({ name = "Sandwich", isFood = true,
                       calories = 300, hungerChange = -30 }),
        }),
    }))
    local best = AutoPilot_Inventory.getBestFoodForHunger(p, 0.30)
    assert_eq("nested food is matched against hunger",
        best and best:getName(), "Sandwich")
end

-- ── 17. preferTastyFood sees nested food ──────────────────────────────────────
print("\n=== V4.8 Test 17: preferTastyFood sees nested boredom-reducing food ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        MockContainer.bag("Backpack", {
            makeItem({ name = "Chocolate", isFood = true, boredom = -15 }),
        }),
    }))
    local best = AutoPilot_Inventory.preferTastyFood(p)
    assert_eq("nested tasty food is selected", best and best:getName(), "Chocolate")
end

-- ── 18. getInventorySummary reports nested items ──────────────────────────────
print("\n=== V4.8 Test 18: getInventorySummary includes bagged items ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({
        MockContainer.bag("Backpack", { makeItem({ name = "Hammer" }) }),
    }))
    local names = AutoPilot_Inventory.getInventorySummary(p)
    local found = false
    for _, n in ipairs(names) do
        if n:find("Hammer", 1, true) then found = true end
    end
    assert_true("a bagged item shows up in the inventory summary", found)
end

-- ── 19. Empty inventory is still safe ─────────────────────────────────────────
print("\n=== V4.8 Test 19: empty inventory yields no selections ===")
do
    local p = MockContainer.attach(player(), MockContainer.new({}))
    assert_eq("getBestFood returns nil", AutoPilot_Inventory.getBestFood(p), nil)
    assert_eq("getBestDrink returns nil", AutoPilot_Inventory.getBestDrink(p), nil)
    local food, drink = AutoPilot_Inventory.getSupplyCounts(p)
    assert_eq("food count is 0", food, 0)
    assert_eq("drink count is 0", drink, 0)
end

-- ── 20. A nil inventory does not error ────────────────────────────────────────
print("\n=== V4.8 Test 20: nil inventory degrades quietly ===")
do
    local p = player()
    p.getInventory = function(_self) return nil end
    local ok = pcall(function() return AutoPilot_Inventory.getBestFood(p) end)
    assert_true("selectors survive a nil inventory", ok)
    assert_false("iteratePlayerItems reports no early stop",
        AutoPilot_Utils.iteratePlayerItems(p, function() return true end))
end

-- ── V4.9: queueItemToMainInventory + selectors reporting their container ──────
-- Finding an item is not the same as being able to use it: PZ acts on the MAIN
-- inventory, so an item still nested in a bag must be moved there first.

local function queuedTypes()
    local t = {}
    for _, a in ipairs(ISTimedActionQueue_calls) do table.insert(t, a.type) end
    return t
end

local function resetQueue() ISTimedActionQueue_calls = {} end

-- 21. Nothing to do when the item is already in the main inventory.
print("\n=== V4.9 Test 21: an item already in the main inventory is not moved ===")
do
    resetQueue()
    local item = makeItem({ name = "Bandage" })
    local mainInv = MockContainer.new({ item })
    local p = MockContainer.attach(player(), mainInv)

    local queued, usable = AutoPilot_Utils.queueItemToMainInventory(p, item, mainInv)
    assert_false("no transfer is reported", queued)
    assert_true("the item is usable as-is", usable)
    assert_eq("nothing was queued", #ISTimedActionQueue_calls, 0)
end

-- 22. An item in a bag is moved into the main inventory.
print("\n=== V4.9 Test 22: an item in a bag is transferred to the main inventory ===")
do
    resetQueue()
    local item = makeItem({ name = "Bandage" })
    local bag  = MockContainer.bag("FannyPack", { item })
    local mainInv = MockContainer.new({ bag })
    local p = MockContainer.attach(player(), mainInv)

    local queued, usable = AutoPilot_Utils.queueItemToMainInventory(
        p, item, bag:getItemContainer())
    assert_true("a transfer is reported", queued)
    assert_true("the item is usable behind the transfer", usable)
    assert_eq("exactly one action queued", #ISTimedActionQueue_calls, 1)
    assert_eq("the queued action is a transfer", queuedTypes()[1], "transfer")
    assert_eq("the transfer moves the right item",
        ISTimedActionQueue_calls[1].item, item)
    assert_eq("the transfer source is the bag's container",
        ISTimedActionQueue_calls[1].from, bag:getItemContainer())
    assert_eq("the transfer destination is the main inventory",
        ISTimedActionQueue_calls[1].to, mainInv)
end

-- 23. An unknown container (nil) is the pre-V4.9 path: no transfer, still usable.
print("\n=== V4.9 Test 23: a nil holding container queues nothing ===")
do
    resetQueue()
    local p = MockContainer.attach(player(), MockContainer.new({}))
    local queued, usable = AutoPilot_Utils.queueItemToMainInventory(
        p, makeItem({ name = "X" }), nil)
    assert_false("no transfer is reported", queued)
    assert_true("the caller may still act on the item", usable)
    assert_eq("nothing was queued", #ISTimedActionQueue_calls, 0)
end

-- 24. A refused transfer degrades quietly and marks the item unusable.
print("\n=== V4.9 Test 24: a refused transfer reports the item unusable ===")
do
    resetQueue()
    local saved = ISInventoryTransferAction
    ISInventoryTransferAction = { new = function() error("PZ refused") end }

    local item = makeItem({ name = "Bandage" })
    local bag  = MockContainer.bag("FannyPack", { item })
    local p = MockContainer.attach(player(), MockContainer.new({ bag }))

    local ok, queued, usable = pcall(function()
        return AutoPilot_Utils.queueItemToMainInventory(p, item, bag:getItemContainer())
    end)
    ISInventoryTransferAction = saved

    assert_true("a refused transfer does not raise", ok)
    assert_false("no transfer is reported", queued)
    assert_false("the item is reported unusable", usable)
    assert_eq("nothing was queued", #ISTimedActionQueue_calls, 0)
end

-- 25. Nil player / nil item are no-ops.
print("\n=== V4.9 Test 25: nil player or item is a no-op ===")
do
    resetQueue()
    local _, usableNoPlayer = AutoPilot_Utils.queueItemToMainInventory(
        nil, makeItem({}), MockContainer.new({}))
    local _, usableNoItem = AutoPilot_Utils.queueItemToMainInventory(
        player(), nil, MockContainer.new({}))
    assert_true("nil player degrades to usable", usableNoPlayer)
    assert_true("nil item degrades to usable", usableNoItem)
    assert_eq("nothing was queued", #ISTimedActionQueue_calls, 0)
end

-- 26. Selectors report the container that actually holds the winner.
print("\n=== V4.9 Test 26: selectors return the holding container ===")
do
    local bagFood  = makeItem({ name = "Chips",  isFood = true, calories = 300 })
    local bagDrink = makeItem({ name = "Bottle", isFood = true, thirstChange = -20 })
    local tasty    = makeItem({ name = "Cake",   isFood = true, boredom = -10, calories = 100 })
    local bag = MockContainer.bag("Backpack", { bagFood, bagDrink, tasty })
    local inner = bag:getItemContainer()
    local mainInv = MockContainer.new({ bag })
    local p = MockContainer.attach(player(), mainInv)

    local food, foodCont = AutoPilot_Inventory.getBestFood(p)
    assert_eq("getBestFood returns the bagged food", food, bagFood)
    assert_eq("getBestFood reports the bag's container", foodCont, inner)

    local drink, drinkCont = AutoPilot_Inventory.getBestDrink(p)
    assert_eq("getBestDrink returns the bagged drink", drink, bagDrink)
    assert_eq("getBestDrink reports the bag's container", drinkCont, inner)

    local best, bestCont = AutoPilot_Inventory.getBestFoodForHunger(p, 0.30)
    assert_true("getBestFoodForHunger returns a bagged item", best ~= nil)
    assert_eq("getBestFoodForHunger reports the bag's container", bestCont, inner)

    local weighted, weightedCont = AutoPilot_Inventory.selectFoodByWeight(p)
    assert_true("selectFoodByWeight returns a bagged item", weighted ~= nil)
    assert_eq("selectFoodByWeight reports the bag's container", weightedCont, inner)

    local mood, moodCont = AutoPilot_Inventory.preferTastyFood(p)
    assert_eq("preferTastyFood returns the bagged cake", mood, tasty)
    assert_eq("preferTastyFood reports the bag's container", moodCont, inner)
end

-- 27. A top-level winner reports the MAIN inventory, so no transfer follows.
print("\n=== V4.9 Test 27: a top-level winner reports the main inventory ===")
do
    local topFood = makeItem({ name = "Steak", isFood = true, calories = 900 })
    local mainInv = MockContainer.new({
        topFood,
        MockContainer.bag("Backpack", {
            makeItem({ name = "Chips", isFood = true, calories = 100 }),
        }),
    })
    local p = MockContainer.attach(player(), mainInv)

    local food, cont = AutoPilot_Inventory.getBestFood(p)
    assert_eq("the top-level food wins", food, topFood)
    assert_eq("the reported container is the main inventory", cont, mainInv)

    resetQueue()
    local queued = AutoPilot_Utils.queueItemToMainInventory(p, food, cont)
    assert_false("no transfer is queued for a main-inventory item", queued)
    assert_eq("nothing was queued", #ISTimedActionQueue_calls, 0)
end

-- 28. adjustClothing: wear a bagged garment only after moving it.
print("\n=== V4.9 Test 28: bagged clothing transfers THEN is worn ===")
do
    resetQueue()
    local coat = makeItem({ name = "Coat" })
    coat.getInsulation = function(_self) return 0.9 end
    local bag = MockContainer.bag("Backpack", { coat })
    local p = MockContainer.attach(player(), MockContainer.new({ bag }))

    local savedTemp = AutoPilot_Inventory.bodyTemperature
    AutoPilot_Inventory.bodyTemperature = function(_p) return -50 end
    local worn = AutoPilot_Inventory.adjustClothing(p)
    AutoPilot_Inventory.bodyTemperature = savedTemp

    assert_true("adjustClothing reports an action", worn)
    assert_eq("exactly two actions queued", #ISTimedActionQueue_calls, 2)
    assert_eq("action 1 is the transfer", queuedTypes()[1], "transfer")
    assert_eq("action 2 is the wear", queuedTypes()[2], "wear")
end

-- 29. checkAndSwapWeapon: swap to a bagged weapon only after moving it.
print("\n=== V4.9 Test 29: a bagged weapon transfers THEN is equipped ===")
do
    resetQueue()
    local axe = makeItem({ name = "Axe" })
    axe.isWeapon        = function(_self) return true end
    axe.getCondition    = function(_self) return 10 end
    axe.getConditionMax = function(_self) return 10 end
    axe.getMaxDamage    = function(_self) return 5 end
    local bag = MockContainer.bag("Backpack", { axe })
    local p = MockContainer.attach(player(), MockContainer.new({ bag }))

    local savedCond = AutoPilot_Inventory.equippedWeaponCondition
    AutoPilot_Inventory.equippedWeaponCondition = function(_p) return 0.05 end
    local swapped = AutoPilot_Inventory.checkAndSwapWeapon(p)
    AutoPilot_Inventory.equippedWeaponCondition = savedCond

    assert_true("checkAndSwapWeapon reports a swap", swapped)
    assert_eq("exactly two actions queued", #ISTimedActionQueue_calls, 2)
    assert_eq("action 1 is the transfer", queuedTypes()[1], "transfer")
    assert_eq("action 2 is the equip", queuedTypes()[2], "equip_weapon")
end

-- 30. getReadable reports its container too (doRead moves the book first).
print("\n=== V4.9 Test 30: getReadable reports the holding container ===")
do
    local book = makeItem({ name = "Novel" })
    book.getScriptItem        = function(_self)
        return { isItemType = function(_s, t) return t == ItemType.LITERATURE end }
    end
    book.hasTag               = function(_self, _t) return false end
    book.getNumberOfPages     = function(_self) return 100 end
    book.getAlreadyReadPages  = function(_self) return 0 end
    local bag = MockContainer.bag("Backpack", { book })
    local p = MockContainer.attach(player(), MockContainer.new({ bag }))

    local found, cont = AutoPilot_Inventory.getReadable(p)
    assert_eq("the bagged book is found", found, book)
    assert_eq("the bag's container is reported", cont, bag:getItemContainer())
end

print("\n=== V5.1 Test 31: an ordinary item is NEVER probed for a sub-container ===")
do
    -- The V4.8 regression: getItemContainer() was called on every carried item
    -- behind a pcall.  Functionally that read as "not a container", but on a
    -- real 42.19 client the call raises a JAVA exception that pcall does not
    -- stop PZ logging, so the console and the in-game ERROR badge filled up on
    -- every survival tick.  A mock cannot reproduce PZ's logging, so the fix is
    -- asserted directly: an ordinary item must be type-checked and skipped
    -- WITHOUT the probe ever being attempted.
    local probed = false
    local plain = makeItem({ name = "Screwdriver" })
    plain.getItemContainer = function(_self)
        probed = true
        error("getItemContainer must never be called on a non-container item")
    end
    local p = MockContainer.attach(player(), MockContainer.new({ plain }))

    local seen = {}
    AutoPilot_Utils.iteratePlayerItems(p, function(item) table.insert(seen, item) end)

    assert_eq("the ordinary item is still visited", #seen, 1)
    assert_eq("it was never probed for a sub-container", probed, false)
end

print("\n=== V5.1 Test 32: a real bag IS probed and its contents visited ===")
do
    -- The type check must not over-correct into skipping genuine containers.
    local inner = makeItem({ name = "Bandage" })
    local bag   = MockContainer.bag("FannyPack", { inner })
    local p     = MockContainer.attach(player(), MockContainer.new({ bag }))

    assert_eq("the bag type-checks as a container",
        instanceof(bag, "InventoryContainer"), true)

    local names = {}
    AutoPilot_Utils.iteratePlayerItems(p, function(item)
        table.insert(names, item:getName())
    end)
    assert_eq("both the bag and its contents are visited", #names, 2)
    assert_eq("the nested item is reached", names[2], "Bandage")
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
