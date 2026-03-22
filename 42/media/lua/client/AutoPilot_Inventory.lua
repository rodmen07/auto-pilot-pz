-- AutoPilot_Inventory.lua
-- Utility functions for scanning and selecting items from player inventory.
--
-- SPLITSCREEN NOTE: _lastSearchResults is a module-level variable shared
-- across all local players.  Splitscreen is NOT supported.

AutoPilot_Inventory = {}

local LOOT_SEARCH_RADIUS   = 80  -- tiles to search for loot containers
local WATER_SEARCH_RADIUS  = 80  -- tiles to scan for sinks / rain barrels (mirrors above)
local PLACE_SEARCH_DIST    = 20  -- tiles to find a container for placeItem
local SEARCH_RESULTS_MAX   = 10  -- max items returned by searchItem
local INVENTORY_SUMMARY_MAX = 20 -- max unique item names in inventory snapshot

-- Returns the best safe-to-eat food item by calorie count.
-- Skips: rotten, frozen, needs-cooking (raw dangerous), causes unhappiness/boredom.
function AutoPilot_Inventory.getBestFood(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local best = nil
    local bestCal = -999

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item:isFood() and not item:isRotten() then
            -- Skip frozen food (needs thawing + cooking)
            local frozen = false
            pcall(function() frozen = item:isFrozen() end)
            if not frozen then
                -- Skip food that requires cooking (raw chicken, raw meat, etc.)
                local needsCooking = false
                pcall(function()
                    needsCooking = item:isIsCookable()
                        and not item:isCooked()
                end)
                if not needsCooking then
                    -- Skip food that causes unhappiness
                    local unhappy = 0
                    pcall(function()
                        unhappy = item:getUnhappyChange() or 0
                    end)
                    -- Skip food that causes boredom
                    local boring = 0
                    pcall(function()
                        boring = item:getBoredomChange() or 0
                    end)
                    if unhappy <= 0 and boring <= 0 then
                        local cal = item:getCalories() or 0
                        if cal > bestCal then
                            bestCal = cal
                            best = item
                        end
                    end
                end
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
-- B42: instanceof avoids Java-level exceptions that pcall(isWeapon) still logs.
function AutoPilot_Inventory.getBestWeapon(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local best = nil
    local bestDmg = 0

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and instanceof(item, "HandWeapon") then
            local dmg = item:getMaxDamage() or 0
            if dmg > bestDmg then
                bestDmg = dmg
                best = item
            end
        end
    end
    return best
end

-- Returns any readable literature item from inventory.
-- B42: ItemType.LITERATURE covers all books, magazines, newspapers, comics, novels.
-- Skips uninteresting items (blank notebooks) and already-read items with no pages left.
function AutoPilot_Inventory.getReadable(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local ok, isLit = pcall(function()
                return item:getScriptItem():isItemType(ItemType.LITERATURE)
            end)
            if ok and isLit then
                -- Skip blank/uninteresting items
                local uninteresting = false
                pcall(function()
                    uninteresting = item:hasTag(ItemTag.UNINTERESTING)
                end)
                if not uninteresting then
                    -- Skip notepads, journals, blank notebooks
                    local name = ""
                    pcall(function() name = item:getName():lower() end)
                    local isBlank = name:find("notepad") or
                                    name:find("notebook") or
                                    name:find("journal") or
                                    name:find("empty")
                    if not isBlank then
                        -- Skip fully-read items (0 pages remaining)
                        local pages = -1
                        pcall(function()
                            pages = item:getNumberOfPages()
                        end)
                        local readPages = 0
                        pcall(function()
                            readPages = item:getAlreadyReadPages()
                        end)
                        if pages > 0 and readPages < pages then
                            return item
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- ── Container iteration helpers ───────────────────────────────────────────────

-- Iterates every item in every container on every in-bounds square within
-- `radius` tiles of the player.  Calls callback(item, container) for each
-- non-nil item.  If the callback returns true, iteration stops early (use for
-- first-match searches).  Returns true if the callback ever stopped early.
local function _iterateContainersNearby(player, radius, callback)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local stopped = false
    AutoPilot_Utils.iterateNearbySquares(px, py, pz, radius, function(sq)
        if not AutoPilot_Home.isInside(sq) then return false end
        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            if obj then
                local container = obj:getContainer()
                if container then
                    local items = container:getItems()
                    for j = 0, items:size() - 1 do
                        local item = items:get(j)
                        if item and callback(item, container) then
                            stopped = true
                            return true  -- stop iterateNearbySquares
                        end
                    end
                end
            end
        end
        return false
    end)
    return stopped
end

-- Queue an ISInventoryTransferAction and log the result.
-- Returns true on success, false when PZ refuses the action (MP-unsafe path).
local function _queueTransfer(player, item, container, label)
    local ok = pcall(function()
        ISTimedActionQueue.add(ISInventoryTransferAction:new(
            player, item, container, player:getInventory()))
    end)
    if not ok then
        AutoPilot_LLM.log("[Inventory] ISInventoryTransferAction failed for "
            .. label .. " — skipping direct transfer (MP-unsafe).")
    end
    return ok
end

-- ── Auto-loot from nearby containers ─────────────────────────────────────────

-- Scans nearby containers for readable literature and transfers it to inventory.
function AutoPilot_Inventory.lootNearbyReadable(player)
    local found, foundContainer = nil, nil
    _iterateContainersNearby(player, LOOT_SEARCH_RADIUS, function(item, container)
        local ok, isLit = pcall(function()
            return item:getScriptItem():isItemType(ItemType.LITERATURE)
        end)
        if ok and isLit then
            local uninteresting = false
            pcall(function() uninteresting = item:hasTag(ItemTag.UNINTERESTING) end)
            if not uninteresting then
                found = item
                foundContainer = container
                return true  -- stop scanning
            end
        end
        return false
    end)
    if found then
        AutoPilot_LLM.log("[Inventory] Looting readable: " .. tostring(found:getName()))
        return _queueTransfer(player, found, foundContainer, "readable")
    end
    AutoPilot_LLM.log("[Inventory] No readable items found in nearby containers.")
    return false
end

-- Scans nearby containers for food and transfers the highest-calorie item.
function AutoPilot_Inventory.lootNearbyFood(player)
    local best, bestCal, bestContainer = nil, -999, nil
    _iterateContainersNearby(player, LOOT_SEARCH_RADIUS, function(item, container)
        if item:isFood() and not item:isRotten() then
            local cal = item:getCalories() or 0
            if cal > bestCal then
                bestCal = cal
                best = item
                bestContainer = container
            end
        end
        return false  -- scan all squares to find the best
    end)
    if best then
        AutoPilot_LLM.log("[Inventory] Looting food: " .. tostring(best:getName()))
        return _queueTransfer(player, best, bestContainer, "food")
    end
    AutoPilot_LLM.log("[Inventory] No food found in nearby containers.")
    return false
end

-- Scans nearby containers for drinks and transfers the first hydrating item.
function AutoPilot_Inventory.lootNearbyDrink(player)
    local found, foundContainer = nil, nil
    _iterateContainersNearby(player, LOOT_SEARCH_RADIUS, function(item, container)
        if item:isFood() and not item:isRotten() then
            local thirstChange = item:getThirstChange()
            if thirstChange and thirstChange < 0 then
                found = item
                foundContainer = container
                return true  -- stop scanning
            end
        end
        return false
    end)
    if found then
        AutoPilot_LLM.log("[Inventory] Looting drink: " .. tostring(found:getName()))
        return _queueTransfer(player, found, foundContainer, "drink")
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

-- ── Water source management ────────────────────────────────────────────────

-- Finds the nearest world object with fluid (sink, rain barrel, etc.).
-- Returns the object and its square, or nil.
function AutoPilot_Inventory.findWaterSource(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local bestObj  = nil
    local bestDist = math.huge

    AutoPilot_Utils.iterateNearbySquares(px, py, pz, WATER_SEARCH_RADIUS, function(sq, dx, dy)
        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            if obj then
                local ok, hasFluid = pcall(function() return obj:hasFluid() end)
                if ok and hasFluid then
                    local dist = dx * dx + dy * dy
                    if dist < bestDist then
                        bestDist = dist
                        bestObj  = obj
                    end
                end
            end
        end
        return false  -- always scan all squares to find the nearest
    end)
    return bestObj
end

-- Drink directly from a water source (sink, rain barrel).
-- Queues walk-to + drink action. Returns true if action was queued.
function AutoPilot_Inventory.drinkFromSource(player, waterObj)
    if not waterObj then return false end

    local ok, tainted = pcall(function() return waterObj:isTaintedWater() end)
    if not ok then tainted = false end

    -- Walk adjacent to the water source
    local sq = waterObj:getSquare()
    if sq then
        local walkOk = pcall(function()
            luautils.walkAdj(player, sq, true)
        end)
        if not walkOk then
            ISTimedActionQueue.add(ISWalkToTimedAction:new(player, sq))
        end
    end

    local drinkOk, _ = pcall(function()
        ISTimedActionQueue.add(ISTakeWaterAction:new(player, nil, waterObj, tainted))
    end)
    if drinkOk then
        AutoPilot_LLM.log("[Inventory] Drinking from water source.")
    end
    return drinkOk
end

-- Refill a water container from a nearby water source.
-- Finds the first non-full container in inventory and fills it.
-- Returns true if a refill action was queued.
function AutoPilot_Inventory.refillWaterContainer(player, waterObj)
    if not waterObj then return false end

    local inv = player:getInventory()
    local items = inv:getItems()
    local container = nil

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            -- Check for FluidContainer-based items (B42 fluid system)
            local ok, fc = pcall(function() return item:getFluidContainer() end)
            if ok and fc then
                local ok1, isNotFull  = pcall(function() return not fc:isFull() end)
                local ok2, canAddWater = pcall(function() return fc:canAddFluid(Fluid.Water) end)
                if ok1 and isNotFull and ok2 and canAddWater then
                    container = item
                    break
                end
            end
            -- Fallback: legacy canStoreWater items
            if not container then
                local ok2, canStore = pcall(function() return item:canStoreWater() end)
                if ok2 and canStore then
                    local ok3, isFull = pcall(function()
                        return item:isWaterSource() and item:getCurrentUsesFloat() >= 1.0
                    end)
                    if ok3 and not isFull then
                        container = item
                        break
                    end
                end
            end
        end
    end

    if not container then return false end

    local ok, tainted = pcall(function() return waterObj:isTaintedWater() end)
    if not ok then tainted = false end

    local sq = waterObj:getSquare()
    if sq then
        pcall(function() luautils.walkAdj(player, sq, true) end)
    end

    local fillOk, _ = pcall(function()
        ISTimedActionQueue.add(ISTakeWaterAction:new(player, container, waterObj, tainted))
    end)
    if fillOk then
        AutoPilot_LLM.log("[Inventory] Refilling " .. tostring(container:getName()) .. " from water source.")
    end
    return fillOk
end

-- Returns true if a water source is nearby.
function AutoPilot_Inventory.hasNearbyWaterSource(player)
    return AutoPilot_Inventory.findWaterSource(player) ~= nil
end

-- ── Item search & loot (for Pilot mode) ──────────────────────────────────────

-- Last search results — stored so state writer can report them to the sidecar.
AutoPilot_Inventory._lastSearchResults = {}

-- Search nearby containers for items whose name contains `keyword` (case-insensitive).
-- Returns a list of {name, container, item, dist} tables, closest first.
function AutoPilot_Inventory.searchItem(player, keyword)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local kw = string.lower(keyword or "")
    local results = {}

    AutoPilot_Utils.iterateNearbySquares(px, py, pz, LOOT_SEARCH_RADIUS, function(sq, dx, dy)
        if not AutoPilot_Home.isInside(sq) then return false end
        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            if obj then
                local container = obj:getContainer()
                if container then
                    local items = container:getItems()
                    for j = 0, items:size() - 1 do
                        local item = items:get(j)
                        if item then
                            local ok, name = pcall(function() return item:getName() end)
                            if ok and name and string.find(string.lower(name), kw, 1, true) then
                                table.insert(results, {
                                    name      = name,
                                    container = container,
                                    item      = item,
                                    dist      = dx * dx + dy * dy,
                                })
                            end
                        end
                    end
                end
            end
        end
        return false  -- always scan all squares
    end)

    -- Sort by distance
    table.sort(results, function(a, b) return a.dist < b.dist end)

    -- Store names for state reporting (capped at SEARCH_RESULTS_MAX)
    local names = {}
    for i = 1, math.min(#results, SEARCH_RESULTS_MAX) do
        table.insert(names, results[i].name)
    end
    AutoPilot_Inventory._lastSearchResults = names

    AutoPilot_LLM.log("[Inventory] Search '" .. keyword .. "': found "
        .. #results .. " items")
    return results
end

-- Loot the first item matching `keyword` from nearby containers.
-- Returns true if a transfer was queued.
function AutoPilot_Inventory.lootItem(player, keyword)
    local results = AutoPilot_Inventory.searchItem(player, keyword)
    if #results == 0 then
        AutoPilot_LLM.log("[Inventory] Loot: nothing matching '" .. keyword .. "' found.")
        return false
    end

    local best = results[1]
    AutoPilot_LLM.log("[Inventory] Looting: " .. best.name)
    local ok = pcall(function()
        ISTimedActionQueue.add(ISInventoryTransferAction:new(
            player, best.item, best.container, player:getInventory()))
    end)
    if not ok then
        AutoPilot_LLM.log("[Inventory] ISInventoryTransferAction failed for loot — skipping direct transfer (MP-unsafe).")
        return false
    end
    return true
end

-- Place an item from player inventory into the nearest container.
-- keyword: partial name match for the inventory item to place.
function AutoPilot_Inventory.placeItem(player, keyword)
    if not keyword or keyword == "" then
        AutoPilot_LLM.log("[Inventory] placeItem: no keyword given.")
        return false
    end

    -- Find matching item in player inventory
    local inv = player:getInventory()
    local items = inv:getItems()
    local target = nil
    local kw = keyword:lower()

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local ok, name = pcall(function() return item:getName() end)
            if ok and name and name:lower():find(kw, 1, true) then
                target = item
                break
            end
        end
    end

    if not target then
        AutoPilot_LLM.log("[Inventory] placeItem: '"
            .. keyword .. "' not found in inventory.")
        return false
    end

    -- Find the nearest container on nearby tiles
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local bestContainer = nil
    local bestObj = nil
    local bestDist = math.huge

    AutoPilot_Utils.iterateNearbySquares(px, py, pz, PLACE_SEARCH_DIST, function(sq, dx, dy)
        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            local ok, ctr = pcall(function() return obj:getContainer() end)
            if ok and ctr then
                local dist = dx * dx + dy * dy
                if dist < bestDist then
                    bestDist      = dist
                    bestContainer = ctr
                    bestObj       = obj
                end
            end
        end
        return false  -- scan all to find nearest
    end)

    if not bestContainer then
        AutoPilot_LLM.log("[Inventory] placeItem: no container found nearby.")
        return false
    end

    -- Walk to the container's square first, then transfer
    local objSq = bestObj:getSquare()
    AutoPilot_LLM.log("[Inventory] Placing '"
        .. tostring(target:getName()) .. "' into container at ("
        .. tostring(objSq:getX()) .. ","
        .. tostring(objSq:getY()) .. ").")

    -- Queue walk then transfer
    if bestDist > 4 then
        ISTimedActionQueue.add(
            ISWalkToTimedAction:new(player, objSq))
    end

    local ok, err = pcall(function()
        ISTimedActionQueue.add(ISInventoryTransferAction:new(
            player, target, inv, bestContainer))
    end)
    if not ok then
        AutoPilot_LLM.log("[Inventory] ISInventoryTransferAction failed for placeItem: "
            .. tostring(err) .. " — skipping direct transfer (MP-unsafe).")
        return false
    end
    return true
end

-- Returns search result names from the last searchItem call.
function AutoPilot_Inventory.getLastSearchResults()
    return AutoPilot_Inventory._lastSearchResults or {}
end

-- Returns a summary of the player's inventory (item names, max 20).
function AutoPilot_Inventory.getInventorySummary(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local names = {}
    local seen = {}

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local ok, name = pcall(function() return item:getName() end)
            if ok and name then
                if not seen[name] then
                    seen[name] = 0
                end
                seen[name] = seen[name] + 1
            end
        end
    end

    for name, count in pairs(seen) do
        if count > 1 then
            table.insert(names, name .. " x" .. count)
        else
            table.insert(names, name)
        end
        if #names >= INVENTORY_SUMMARY_MAX then break end
    end
    return names
end
