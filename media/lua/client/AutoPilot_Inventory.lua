-- AutoPilot_Inventory.lua
-- Utility functions for scanning and selecting items from player inventory.
--
-- SPLITSCREEN NOTE: _lastSearchResults is a module-level variable shared
-- across all local players.  Splitscreen is NOT supported.

AutoPilot_Inventory = {}

local LOOT_SEARCH_RADIUS   = 150  -- tiles to search for loot containers (one cell radius)
local WATER_SEARCH_RADIUS  = 150  -- tiles to scan for sinks / rain barrels (one cell radius)
local PLACE_SEARCH_DIST    = 50   -- tiles to find a container for placeItem
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

--- Choose best food item for current hunger level to avoid large overeating.
function AutoPilot_Inventory.getBestFoodForHunger(player, currentHunger)
    local target = (currentHunger or 0) * 100
    local inv = player:getInventory()
    local items = inv:getItems()
    local best = nil
    local bestDelta = math.huge

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item:isFood() and not item:isRotten() then
            local frozen = false
            pcall(function() frozen = item:isFrozen() end)
            if not frozen then
                local needsCooking = false
                pcall(function()
                    needsCooking = item:isIsCookable() and not item:isCooked()
                end)
                if not needsCooking then
                    local unhappy = 0
                    pcall(function()
                        unhappy = item:getUnhappyChange() or 0
                    end)
                    local boring = 0
                    pcall(function()
                        boring = item:getBoredomChange() or 0
                    end)
                    if unhappy <= 0 and boring <= 0 then
                        local hungerChange = 0
                        pcall(function() hungerChange = math.abs(item:getHungerChange() or 0) end)

                        -- Avoid gross overeating relative to current hunger
                        -- (e.g., do not choose 90+ hunger food when only ~25 hunger needed)
                        local maxAcceptable = math.max(25, target * 1.5)
                        if hungerChange <= maxAcceptable then
                            local delta = math.abs(target - hungerChange)
                            if delta < bestDelta then
                                bestDelta = delta
                                best = item
                            end
                        end
                    end
                end
            end
        end
    end

    if best then
        return best
    end

    -- Fallback: if we could not find food close to hunger target, return any safe food.
    return AutoPilot_Inventory.getBestFood(player)
end

--- Phase 3: Select the best food item considering player weight.
--- Underweight: prioritise high-calorie food; overweight: prefer low-calorie.
--- Applies the same frozen/needs-cooking safety filters as getBestFood.
--- Returns an IsoObject food item, or nil.
function AutoPilot_Inventory.selectFoodByWeight(player)
    local weight = 75
    pcall(function()
        local nutrition = player:getNutrition()
        if nutrition then weight = nutrition:getWeight() or 75 end
    end)

    local inv    = player:getInventory()
    local best, bestScore = nil, nil

    for i = 0, inv:getItems():size() - 1 do
        local item = inv:getItems():get(i)
        if item and item:isFood() and not item:isRotten() then
            local frozen = false
            pcall(function() frozen = item:isFrozen() end)
            if not frozen then
                local needsCooking = false
                pcall(function()
                    needsCooking = item:isIsCookable() and not item:isCooked()
                end)
                if not needsCooking then
                    local calories = 0
                    pcall(function() calories = item:getCalories() or 0 end)
                    local hunger = 0
                    pcall(function() hunger = item:getHungerChange() or 0 end)

                    local score
                    if weight < AutoPilot_Constants.WEIGHT_UNDERWEIGHT then
                        score = calories + math.abs(hunger)     -- max calories
                    elseif weight > AutoPilot_Constants.WEIGHT_OVERWEIGHT then
                        score = -calories + math.abs(hunger)    -- min calories
                    else
                        score = math.abs(hunger)                -- just satisfy hunger
                    end

                    if bestScore == nil or score > bestScore then
                        best, bestScore = item, score
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
-- `radius` tiles of the player.  Calls callback(item, container, sq) for each
-- non-nil item.  If the callback returns true, iteration stops early (use for
-- first-match searches).  Returns true if the callback ever stopped early.
-- ignoreHome: when true, skips the AutoPilot_Home.isInside check (supply runs).
-- Phase 3: skips squares marked depleted by AutoPilot_Map; marks empty containers.
local function _iterateContainersNearby(player, radius, callback, ignoreHome)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local stopped = false
    AutoPilot_Utils.iterateNearbySquares(px, py, pz, radius, function(sq)
        if not ignoreHome and not AutoPilot_Home.isInside(sq) then return false end
        if AutoPilot_Map.isDepleted(sq) then return false end
        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            if obj then
                local container = obj:getContainer()
                if container then
                    local items = container:getItems()
                    if items:size() == 0 then
                        -- Empty container — mark square as depleted
                        AutoPilot_Map.markDepleted(sq)
                    else
                        for j = 0, items:size() - 1 do
                            local item = items:get(j)
                            if item and callback(item, container, sq) then
                                stopped = true
                                return true  -- stop iterateNearbySquares
                            end
                        end
                    end
                end
            end
        end
        return false
    end)
    return stopped
end

-- Queue an ISInventoryTransferAction, walking to the container first if needed.
-- For world containers (those with a parent IsoObject), the player must be
-- adjacent before transferring; this function prepends a walk-to when the
-- container is more than 2 tiles away.
-- Returns true on success, false when PZ refuses the action (MP-unsafe path).
local function _queueTransfer(player, item, container, label)
    -- Resolve the world square of the container (nil for player-inventory containers).
    local contSq
    local ok_p, parent = pcall(function() return container:getParent() end)
    if ok_p and parent then
        local ok_sq, sq = pcall(function() return parent:getSquare() end)
        if ok_sq and sq then contSq = sq end
    end

    -- Walk to the container if it is a world object more than 2 tiles away.
    if contSq then
        local px, py = player:getX(), player:getY()
        local distSq = (contSq:getX() - px)^2 + (contSq:getY() - py)^2
        if distSq > 4 then
            local walkOk = pcall(function()
                luautils.walkAdj(player, contSq, true)
            end)
            if not walkOk then
                ISTimedActionQueue.add(ISWalkToTimedAction:new(player, contSq))
            end
        end
    end

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

-- Phase 3: Generic predicate-based loot. Finds the first item matching predicate
-- within radius. respectHome=false ignores home bounds (supply runs).
-- Returns true if a transfer was queued.
local function _lootNearbyByPredicate(player, predicate, radius, respectHome)
    local found, foundContainer = nil, nil
    _iterateContainersNearby(player, radius, function(item, container)
        if predicate(item) then
            found = item
            foundContainer = container
            return true  -- stop on first match
        end
        return false
    end, not respectHome)
    if found then
        return _queueTransfer(player, found, foundContainer, "supply run")
    end
    return false
end

--- Loot food/drink in an expanded radius for supply runs.
--- Clears the depletion cache first so previously-empty squares get re-checked.
--- Returns true if any item was found and queued.
function AutoPilot_Inventory.supplyRunLoot(player, predicate)
    AutoPilot_Map.resetDepleted()
    return _lootNearbyByPredicate(player, predicate, AutoPilot_Constants.LOOT_RADIUS_SUPPLY, false)
end

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

    local tainted = false
    local ok = pcall(function() tainted = waterObj:isTaintedWater() end)
    if ok and tainted then
        AutoPilot_LLM.log("[Inventory] Skipping tainted water source.")
        return false
    end

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

    local tainted = false
    local ok = pcall(function() tainted = waterObj:isTaintedWater() end)
    if ok and tainted then
        AutoPilot_LLM.log("[Inventory] Not refilling from tainted water source.")
        return false
    end

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
    return _queueTransfer(player, best.item, best.container, best.name)
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
        if AutoPilot_Home.isSet(player) and not AutoPilot_Home.isInside(sq) then
            return false
        end
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

-- ---------------------------------------------------------------------------
-- Phase 2: Exercise equipment helpers
-- ---------------------------------------------------------------------------

--- Scan containers within home bounds for exercise equipment.
--- Returns best item found and its tier string, or nil, nil.
local function _findExerciseEquipment(player)
    local bestItem, bestMult, bestTier = nil, 0, nil
    local px = math.floor(player:getX())
    local py = math.floor(player:getY())
    local pz = math.floor(player:getZ())
    AutoPilot_Utils.iterateNearbySquares(px, py, pz,
        AutoPilot_Constants.EXERCISE_EQUIP_SEARCH_RADIUS,
        function(sq)
            if AutoPilot_Home.isSet(player) and not AutoPilot_Home.isInside(sq) then
                return false
            end
            for oi = 0, sq:getObjects():size() - 1 do
                local obj  = sq:getObjects():get(oi)
                local cont = obj:getContainer()
                if cont then
                    for i = 0, cont:getItems():size() - 1 do
                        local item = cont:getItems():get(i)
                        local name = item:getType()
                        for _, entry in ipairs(AutoPilot_Constants.EXERCISE_EQUIPMENT) do
                            if name:find(entry.keyword) and entry.multiplier > bestMult then
                                bestItem  = item
                                bestMult  = entry.multiplier
                                bestTier  = entry.tier
                            end
                        end
                    end
                end
            end
        end)
    return bestItem, bestTier
end

--- Transfer the best available exercise equipment into the player's inventory.
--- Returns the tier string ("dumbbell" | "barbell" | "none").
function AutoPilot_Inventory.equipBestExerciseItem(player)
    local inv = player:getInventory()
    -- Already holding suitable gear?
    for _, entry in ipairs(AutoPilot_Constants.EXERCISE_EQUIPMENT) do
        if inv:getFirstTypeRecurse(entry.keyword) then
            AutoPilot_LLM.log("[Inv] Already holding " .. entry.keyword)
            return entry.tier
        end
    end
    local item, tier = _findExerciseEquipment(player)
    if not item then
        AutoPilot_LLM.log("[Inv] No exercise equipment found in home area.")
        return "none"
    end
    local srcContainer = item:getContainer()
    if not srcContainer then
        AutoPilot_LLM.log("[Inv] Exercise item has no container — skipping transfer.")
        return "none"
    end
    -- Walk to the equipment container before transferring.
    local ok_p, equipParent = pcall(function() return srcContainer:getParent() end)
    if ok_p and equipParent then
        local ok_sq, equipSq = pcall(function() return equipParent:getSquare() end)
        if ok_sq and equipSq then
            local px, py = player:getX(), player:getY()
            local distSq = (equipSq:getX() - px)^2 + (equipSq:getY() - py)^2
            if distSq > 4 then
                local walkOk = pcall(function()
                    luautils.walkAdj(player, equipSq, true)
                end)
                if not walkOk then
                    ISTimedActionQueue.add(ISWalkToTimedAction:new(player, equipSq))
                end
            end
        end
    end
    ISTimedActionQueue.add(ISInventoryTransferAction:new(
        player, item, srcContainer, inv))
    AutoPilot_LLM.log("[Inv] Queued transfer of " .. item:getType()
        .. " (" .. (tier or "?") .. ")")
    return tier or "none"
end

--- Return the XP-multiplier tier currently held by the player, or "none".
function AutoPilot_Inventory.currentExerciseTier(player)
    local inv = player:getInventory()
    for _, entry in ipairs(AutoPilot_Constants.EXERCISE_EQUIPMENT) do
        if inv:getFirstTypeRecurse(entry.keyword) then
            return entry.tier
        end
    end
    return "none"
end

-- ---------------------------------------------------------------------------
-- Phase 3: Happiness / unhappiness helpers
-- ---------------------------------------------------------------------------

--- Find the food item in inventory with the best boredom-reduction value.
--- Prefers items with the most negative getBoredomChange() (reduces boredom most).
--- Returns an item, or nil if no boredom-reducing food is in inventory.
function AutoPilot_Inventory.preferTastyFood(player)
    local inv   = player:getInventory()
    local items = inv:getItems()
    local best, bestBoredom = nil, 0  -- want most negative (most reducing)

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item:isFood() and not item:isRotten() then
            local boring = 0
            pcall(function() boring = item:getBoredomChange() or 0 end)
            if boring < bestBoredom then  -- more negative = better mood food
                bestBoredom = boring
                best = item
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Phase 3: Bulk looting
-- ---------------------------------------------------------------------------

-- Default keyword list for bulk looting (food, water, medical, equipment).
AutoPilot_Inventory.BULK_LOOT_KEYWORDS = {
    "food", "can", "soup", "beans", "water", "bottle", "bandage",
    "disinfectant", "painkillers", "splint", "magazine", "book",
    "dumbbells", "barbell", "weightbar",
}

--- Bulk loot a container: transfer ALL items matching any keyword in the list.
--- Returns the count of items transferred.
function AutoPilot_Inventory.bulkLoot(player, container, keywords)
    if not container then return 0 end
    local inv   = player:getInventory()
    local count = 0
    for i = 0, container:getItems():size() - 1 do
        local item = container:getItems():get(i)
        if item then
            local name = ""
            pcall(function() name = item:getType():lower() end)
            for _, kw in ipairs(keywords) do
                if name:find(kw:lower(), 1, true) then
                    local ok = pcall(function()
                        ISTimedActionQueue.add(ISInventoryTransferAction:new(
                            player, item, container, inv))
                    end)
                    if ok then count = count + 1 end
                    break
                end
            end
        end
    end
    if count > 0 then
        AutoPilot_LLM.log(("[Inv] Bulk looted %d items from container."):format(count))
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Phase 4: Weapon durability helpers
-- ---------------------------------------------------------------------------

--- Return the condition ratio (0.0–1.0) of the player's equipped weapon.
--- Returns 1.0 if no weapon or no condition data (treat as full).
function AutoPilot_Inventory.equippedWeaponCondition(player)
    local weapon = player:getPrimaryHandItem()
    if not weapon then return 1.0 end
    local ok, ratio = pcall(function()
        local max  = weapon:getConditionMax()
        if not max or max == 0 then return 1.0 end
        return weapon:getCondition() / max
    end)
    return ok and ratio or 1.0
end

--- Find the best melee weapon in inventory (highest condition × damage score).
--- Returns the item or nil.
function AutoPilot_Inventory.bestMeleeWeapon(player)
    local inv  = player:getInventory()
    local best, bestScore = nil, -1
    for i = 0, inv:getItems():size() - 1 do
        local item = inv:getItems():get(i)
        local ok, score = pcall(function()
            if not item:isWeapon() then return -1 end
            local max = item:getConditionMax()
            if not max or max == 0 then return -1 end
            local condRatio = item:getCondition() / max
            local dmg = (item.getMaxDamage and item:getMaxDamage()) or 1
            return condRatio * dmg
        end)
        if ok and score > bestScore then
            best, bestScore = item, score
        end
    end
    return best
end

--- Equip the best available melee weapon if current weapon is below WEAPON_CONDITION_MIN.
--- Returns true if a swap was made.
function AutoPilot_Inventory.checkAndSwapWeapon(player)
    local cond = AutoPilot_Inventory.equippedWeaponCondition(player)
    if cond >= AutoPilot_Constants.WEAPON_CONDITION_MIN then return false end
    AutoPilot_LLM.log(("[Inv] Weapon condition %.2f < %.2f — seeking replacement."):format(
        cond, AutoPilot_Constants.WEAPON_CONDITION_MIN))
    local replacement = AutoPilot_Inventory.bestMeleeWeapon(player)
    if not replacement then
        AutoPilot_LLM.log("[Inv] No replacement weapon found in inventory.")
        return false
    end
    local ok = pcall(function()
        ISTimedActionQueue.add(ISEquipWeaponAction:new(player, replacement, 50, true))
    end)
    if ok then
        AutoPilot_LLM.log("[Inv] Queued equip of " .. replacement:getType())
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Phase 4: Clothing / temperature helpers
-- ---------------------------------------------------------------------------

--- Return the player's current body temperature delta (from BodyStats).
--- Positive = too hot, negative = too cold. Returns 0 if unavailable.
function AutoPilot_Inventory.bodyTemperature(player)
    local ok, temp = pcall(function()
        return player:getBodyDamage():getThermoregulator():getBodyHeatDelta()
    end)
    return ok and temp or 0
end

--- Scan inventory/nearby containers for clothing with highest insulation (cold)
--- or lowest insulation (hot) depending on need. Returns item or nil.
--- @param wantWarm boolean  true = find warm clothing, false = find cool clothing
function AutoPilot_Inventory.findClothing(player, wantWarm)
    local inv     = player:getInventory()
    local best, bestVal = nil, nil
    -- Check inventory first
    for i = 0, inv:getItems():size() - 1 do
        local item = inv:getItems():get(i)
        local ok, insulation = pcall(function()
            return (item.getInsulation and item:getInsulation()) or nil
        end)
        if ok and insulation ~= nil then
            local score = wantWarm and insulation or -insulation
            if bestVal == nil or score > bestVal then
                best, bestVal = item, score
            end
        end
    end
    return best
end

--- Attempt to equip appropriate clothing for the current temperature.
--- Returns true if an action was queued.
function AutoPilot_Inventory.adjustClothing(player)
    local temp = AutoPilot_Inventory.bodyTemperature(player)
    if temp > AutoPilot_Constants.TEMP_TOO_HOT then
        AutoPilot_LLM.log(("[Inv] Too hot (%.1f) — seeking cool clothing."):format(temp))
        local item = AutoPilot_Inventory.findClothing(player, false)
        if item then
            ISTimedActionQueue.add(ISWearClothing:new(player, item, 50))
            AutoPilot_LLM.log("[Inv] Queued: wear " .. item:getType())
            return true
        end
    elseif temp < AutoPilot_Constants.TEMP_TOO_COLD then
        AutoPilot_LLM.log(("[Inv] Too cold (%.1f) — seeking warm clothing."):format(temp))
        local item = AutoPilot_Inventory.findClothing(player, true)
        if item then
            ISTimedActionQueue.add(ISWearClothing:new(player, item, 50))
            AutoPilot_LLM.log("[Inv] Queued: wear " .. item:getType())
            return true
        end
    end
    return false
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
