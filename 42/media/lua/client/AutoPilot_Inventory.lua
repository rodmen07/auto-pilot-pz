-- AutoPilot_Inventory.lua
-- Utility functions for scanning and selecting items from player inventory.

AutoPilot_Inventory = {}

-- Returns the best non-rotten food item by calorie count.
function AutoPilot_Inventory.getBestFood(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local best = nil
    local bestCal = -999

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item:isFood() and not item:isRotten() then
            local cal = item:getCalories() or 0
            if cal > bestCal then
                bestCal = cal
                best = item
            end
        end
    end
    return best
end

-- Returns the best drink item (negative thirst change = hydrating).
function AutoPilot_Inventory.getBestDrink(player)
    local inv = player:getInventory()
    local items = inv:getItems()

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item:isFood() and not item:isRotten() then
            local thirstChange = item:getThirstChange()
            if thirstChange and thirstChange < 0 then
                return item
            end
        end
    end
    return nil
end

-- Returns the highest-damage melee weapon in inventory.
function AutoPilot_Inventory.getBestWeapon(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local best = nil
    local bestDmg = 0

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item:isWeapon() then
            local dmg = item:getMaxDamage() or 0
            if dmg > bestDmg then
                bestDmg = dmg
                best = item
            end
        end
    end
    return best
end

-- Returns any readable item (book, magazine) from inventory.
function AutoPilot_Inventory.getReadable(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local itemType = item:getType()
            -- Literature covers books, magazines, newspapers
            if itemType and string.find(itemType, "Book") or
               itemType and string.find(itemType, "Magazine") or
               itemType and string.find(itemType, "Newspaper") then
                return item
            end
        end
    end
    return nil
end

-- ── Auto-loot from nearby containers ────────────────────────────────────────

local LOOT_SEARCH_RADIUS = 8  -- tiles to search for containers

-- Scans nearby containers for food and transfers the best item to player inventory.
function AutoPilot_Inventory.lootNearbyFood(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local best = nil
    local bestCal = -999
    local bestContainer = nil

    for dx = -LOOT_SEARCH_RADIUS, LOOT_SEARCH_RADIUS do
        for dy = -LOOT_SEARCH_RADIUS, LOOT_SEARCH_RADIUS do
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            if sq then
                for i = 0, sq:getObjects():size() - 1 do
                    local obj = sq:getObjects():get(i)
                    if obj then
                        local container = obj:getContainer()
                        if container then
                            local items = container:getItems()
                            for j = 0, items:size() - 1 do
                                local item = items:get(j)
                                if item and item:isFood() and not item:isRotten() then
                                    local cal = item:getCalories() or 0
                                    if cal > bestCal then
                                        bestCal = cal
                                        best = item
                                        bestContainer = container
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if best and bestContainer then
        AutoPilot_LLM.log("[Inventory] Looting food: " .. tostring(best:getName()))
        local ok, _ = pcall(function()
            ISTimedActionQueue.add(ISInventoryTransferAction:new(player, best, bestContainer, player:getInventory()))
        end)
        if not ok then
            -- Fallback: direct transfer
            bestContainer:Remove(best)
            player:getInventory():AddItem(best)
        end
        return true
    end
    AutoPilot_LLM.log("[Inventory] No food found in nearby containers.")
    return false
end

-- Scans nearby containers for drinks and transfers the best item to player inventory.
function AutoPilot_Inventory.lootNearbyDrink(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    for dx = -LOOT_SEARCH_RADIUS, LOOT_SEARCH_RADIUS do
        for dy = -LOOT_SEARCH_RADIUS, LOOT_SEARCH_RADIUS do
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            if sq then
                for i = 0, sq:getObjects():size() - 1 do
                    local obj = sq:getObjects():get(i)
                    if obj then
                        local container = obj:getContainer()
                        if container then
                            local items = container:getItems()
                            for j = 0, items:size() - 1 do
                                local item = items:get(j)
                                if item and item:isFood() and not item:isRotten() then
                                    local thirstChange = item:getThirstChange()
                                    if thirstChange and thirstChange < 0 then
                                        AutoPilot_LLM.log("[Inventory] Looting drink: " .. tostring(item:getName()))
                                        local ok, _ = pcall(function()
                                            ISTimedActionQueue.add(ISInventoryTransferAction:new(player, item, container, player:getInventory()))
                                        end)
                                        if not ok then
                                            container:Remove(item)
                                            player:getInventory():AddItem(item)
                                        end
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    AutoPilot_LLM.log("[Inventory] No drinks found in nearby containers.")
    return false
end

-- Counts how many food/drink items are available.
function AutoPilot_Inventory.getSupplyCounts(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local foodCount = 0
    local drinkCount = 0

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item:isFood() and not item:isRotten() then
            local thirst = item:getThirstChange()
            if thirst and thirst < 0 then
                drinkCount = drinkCount + 1
            else
                local cal = item:getCalories() or 0
                if cal > 0 then
                    foodCount = foodCount + 1
                end
            end
        end
    end
    return foodCount, drinkCount
end
