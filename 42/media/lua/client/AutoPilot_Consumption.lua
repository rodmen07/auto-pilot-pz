-- AutoPilot_Consumption.lua
-- Eat and drink behaviour, extracted from AutoPilot_Needs.lua (code-health
-- split, 2026-07-20): AutoPilot_Needs.lua was 1848 lines and preflight's
-- 1000-line hard threshold flagged it as a refactor candidate. doEat/doDrink
-- were a clean extraction candidate because their only module-level state
-- (_emptyLootCycles, drinkCooldownMs) has exactly one external reader
-- (AutoPilot_Needs.getEmptyLootCycles, now a one-line delegation to
-- AutoPilot_Consumption.getEmptyLootCycles below) and no writer outside this
-- file. Moved verbatim; behavior is unchanged.

local function _apNoop(...) end
local print = _apNoop

AutoPilot_Consumption = {}

-- Phase 3: consecutive loot cycles with no food/drink found (triggers supply run)
local _emptyLootCycles = 0
local drinkCooldownMs = 0

-- Helper: handle empty loot cycle tracking and supply run triggering.
-- itemPred: predicate function to select items for supply run.
-- Returns true if a supply run was triggered.
local function trackEmptyLootCycle(player, itemPred)
    _emptyLootCycles = _emptyLootCycles + 1
    print(("[Needs] Empty loot cycle %d/%d."):format(
        _emptyLootCycles, AutoPilot_Constants.SUPPLY_RUN_TRIGGER))
    if _emptyLootCycles >= AutoPilot_Constants.SUPPLY_RUN_TRIGGER then
        print("[Needs] Supply run triggered — expanding loot radius.")
        AutoPilot_Inventory.supplyRunLoot(player, itemPred)
        _emptyLootCycles = 0
        return true
    end
    return false
end

function AutoPilot_Consumption.doEat(player)
    -- Prefer food close to current hunger need to avoid overfeeding.
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    local food, foodCont = nil, nil
    if AutoPilot_Inventory and AutoPilot_Inventory.getBestFoodForHunger then
        local ok, selected, cont = pcall(function()
            return AutoPilot_Inventory.getBestFoodForHunger(player, hunger)
        end)
        if ok then food, foodCont = selected, cont end
    end
    if not food and AutoPilot_Inventory and AutoPilot_Inventory.selectFoodByWeight then
        local ok, selected, cont = pcall(function()
            return AutoPilot_Inventory.selectFoodByWeight(player)
        end)
        if ok then food, foodCont = selected, cont end
    end
    if not food and AutoPilot_Inventory and AutoPilot_Inventory.getBestFood then
        local ok, selected, cont = pcall(function()
            return AutoPilot_Inventory.getBestFood(player)
        end)
        if ok then food, foodCont = selected, cont end
    end
    if not food then
        print("[Needs] Hungry but no food in inventory — looting nearby.")
        local found = AutoPilot_Inventory.lootNearbyFood(player)
        if not found then
            local foodPred = function(item)
                return item:isFood() and not item:isRotten()
                    and (item:getCalories() or 0) > 0
            end
            trackEmptyLootCycle(player, foodPred)
        else
            _emptyLootCycles = 0
        end
        return false
    end
    _emptyLootCycles = 0
    print("[Needs] Best food: " .. tostring(food:getName())
        .. " (cal=" .. tostring(food:getCalories()) .. ")")
    print("[Needs] Eating: " .. tostring(food:getName()))
    -- V4.9: food found inside a backpack (V4.8) cannot be eaten from there;
    -- queue the move to the main inventory first, then the eat behind it.
    local _, usable = AutoPilot_Utils.queueItemToMainInventory(player, food, foodCont)
    if not usable then
        print("[Needs] Food transfer refused: not eating this cycle.")
        return false
    end
    AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, food, 1))
    return true
end

function AutoPilot_Consumption.doDrink(player)
    local okNow, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms = okNow and nowMs or 0
    if ms < drinkCooldownMs then
        return false
    end

    -- Priority 1: nearby water source — fill container first, then drink
    local waterObj = AutoPilot_Inventory.findWaterSource(player)
    if waterObj then
        _emptyLootCycles = 0
        AutoPilot_Inventory.refillWaterContainer(player, waterObj)
        local drank = AutoPilot_Inventory.drinkFromSource(player, waterObj)
        if drank then
            drinkCooldownMs = ms + 8000
        end
        return drank
    end

    -- Priority 2: Drink from inventory (filled glass/bottle)
    local drink, drinkCont = AutoPilot_Inventory.getBestDrink(player)
    if drink then
        _emptyLootCycles = 0
        print("[Needs] Drinking: " .. tostring(drink:getName()))
        -- V4.9: transfer out of a bag first, then drink (same cycle, in order).
        local _, usable = AutoPilot_Utils.queueItemToMainInventory(
            player, drink, drinkCont)
        if not usable then
            print("[Needs] Drink transfer refused: not drinking this cycle.")
            return false
        end
        AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, drink, 1))
        drinkCooldownMs = ms + 5000
        return true
    end

    -- Priority 3: Loot a drink from nearby containers
    print("[Needs] Thirsty but no drink — attempting to loot nearby.")
    local found = AutoPilot_Inventory.lootNearbyDrink(player)
    if not found then
        local drinkPred = function(item)
            return item:isFood() and not item:isRotten()
                and item:getThirstChange() and item:getThirstChange() < 0
        end
        trackEmptyLootCycle(player, drinkPred)
    else
        _emptyLootCycles = 0
    end
    return false
end

function AutoPilot_Consumption.getEmptyLootCycles()
    return _emptyLootCycles
end
