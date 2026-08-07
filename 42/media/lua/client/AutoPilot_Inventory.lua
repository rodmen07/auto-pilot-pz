-- AutoPilot_Inventory.lua
-- Utility functions for scanning and selecting items from player inventory.
--
-- SPLITSCREEN NOTE: _lastSearchResults is a module-level variable shared
-- across all local players.  Splitscreen is NOT supported.

AutoPilot_Inventory = {}

local function _apNoop(...) end
local print = _apNoop

local LOOT_SEARCH_RADIUS    = AutoPilot_Constants.LOOT_SEARCH_RADIUS
local WATER_SEARCH_RADIUS   = AutoPilot_Constants.WATER_SEARCH_RADIUS
local PLACE_SEARCH_DIST     = AutoPilot_Constants.PLACE_SEARCH_DIST
local SEARCH_RESULTS_MAX    = AutoPilot_Constants.SEARCH_RESULTS_MAX
local INVENTORY_SUMMARY_MAX = AutoPilot_Constants.INVENTORY_SUMMARY_MAX

-- V6.0-1: the SAFETY gate, split out of the old single isFoodSafe predicate.
-- Rejects only food the character must not eat AT ALL: rotten, frozen, still
-- needing cooking, poisonous, or tainted.  Hunger never overrides it.
--
-- Poison and taint are new here and both are verified engine surfaces, not
-- assumed: item:getPoisonPower() at install client/ISUI/ISInventoryPane.lua
-- :2094,2097 and client/Foraging/ISForageIcon.lua:24, item:isTainted() at
-- client/ISUI/ISInventoryPane.lua:2310,2349 (both guarded there on
-- instanceof(item, "Food"), same as here).  Reading getPoisonPower directly
-- rather than player:isKnownPoison(item) is the milestone's Q2 default: a
-- foraging-illiterate character who eats a poisonous berry dies just as dead.
--
-- Every new getter is pcall-wrapped exactly like getUnhappyChange below,
-- because the Lua suites build item stubs that define only the getters in use
-- today; an unguarded call would break four suites this slice must not touch.
local function isFoodEdible(item)
    if not item or not item:isFood() or item:isRotten() then return false end
    local frozen = false
    pcall(function() frozen = item:isFrozen() end)
    if frozen then return false end
    local needsCooking = false
    pcall(function()
        needsCooking = item:isIsCookable() and not item:isCooked()
    end)
    if needsCooking then return false end
    local poison = 0
    pcall(function() poison = item:getPoisonPower() or 0 end)
    if poison > 0 then return false end
    local tainted = false
    pcall(function() tainted = item:isTainted() end)
    if tainted then return false end
    return true
end

--- V6.0-1: the PREFERENCE score, the other half of the old isFoodSafe.
--- Lower is better; 0 means the food carries no malus at all.
---
--- Only POSITIVE changes are penalties.  A food that REDUCES unhappiness or
--- boredom scores the same 0 as an inert ration, because ranking the bonus is
--- the mood arm's job (preferTastyFood), not the hunger path's.
---
--- These are item deltas on the engine's own unbounded item scale (Pasta
--- carries UnhappyChange 40), NOT 0.0-1.0 character stats, so the milestone's
--- scale-agnostic rule does not apply to them; see docs/MILESTONE_V6_0.md
--- section 4.1.  Public because V6.0-2 ranks looting with the same helper.
--- @return number  0 for malus-free food, higher for worse, huge for nil
function AutoPilot_Inventory.foodMalusScore(item)
    if not item then return math.huge end
    local unhappy, boring = 0, 0
    pcall(function() unhappy = item:getUnhappyChange() or 0 end)
    pcall(function() boring  = item:getBoredomChange() or 0 end)
    return math.max(unhappy, 0) + math.max(boring, 0)
end

-- The MOOD arm's gate: edible AND completely malus-free.  preferTastyFood must
-- never worsen the moodle it was invoked for (tests/test_mood_food_choice.lua
-- Test 2), so it keeps the stricter predicate the hunger path used to share.
-- The hunger path deliberately no longer uses this: rejecting joyless food
-- outright made 46 non-cookable vanilla foods permanently inedible to the mod
-- and could starve a character carrying only pasta and ramen.
local function isFoodSafe(item)
    return isFoodEdible(item) and AutoPilot_Inventory.foodMalusScore(item) <= 0
end

-- Returns the best edible food item by calorie count.
-- V4.8: searches worn/carried sub-containers too (see AutoPilot_Utils).
-- V4.9: also returns the container holding the winner, so the caller can move
-- it into the main inventory before eating.  Callers that want only the item
-- are unaffected (Lua drops extra return values).
-- V6.0-1: malus-free food is preferred over malus-carrying food; calories
-- decide within a malus tier.  Malus food is eaten only when nothing better is
-- carried, so the mod ranks rather than starves.
-- @return item|nil, container|nil
function AutoPilot_Inventory.getBestFood(player)
    local best = nil
    local bestCont = nil
    local bestMalus = math.huge
    local bestCal = -999

    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        if isFoodEdible(item) then
            local malus = AutoPilot_Inventory.foodMalusScore(item)
            local cal = item:getCalories() or 0
            if malus < bestMalus or (malus == bestMalus and cal > bestCal) then
                bestMalus = malus
                bestCal = cal
                best = item
                bestCont = container
            end
        end
        return false
    end)
    return best, bestCont
end

--- Choose best food item for current hunger level to avoid large overeating.
--- V6.0-1: malus-free food is preferred; hunger fit decides within a tier.
--- @return item|nil, container|nil  (V4.9: container holding the winner)
function AutoPilot_Inventory.getBestFoodForHunger(player, currentHunger)
    local target = (currentHunger or 0) * 100
    local best = nil
    local bestCont = nil
    local bestMalus = math.huge
    local bestDelta = math.huge

    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        if isFoodEdible(item) then
            local malus = AutoPilot_Inventory.foodMalusScore(item)
            local hungerChange = 0
            pcall(function() hungerChange = math.abs(item:getHungerChange() or 0) end)

            local maxAcceptable = math.max(25, target * 1.5)
            if hungerChange <= maxAcceptable then
                local delta = math.abs(target - hungerChange)
                if malus < bestMalus or (malus == bestMalus and delta < bestDelta) then
                    bestMalus = malus
                    bestDelta = delta
                    best = item
                    bestCont = container
                end
            end
        end
        return false
    end)

    if best then
        return best, bestCont
    end

    return AutoPilot_Inventory.getBestFood(player)
end

--- Phase 3: Select the best food item considering player weight.
--- Underweight: prioritise high-calorie food; overweight: prefer low-calorie.
--- Applies the same frozen/needs-cooking safety filters as getBestFood.
--- V6.0-1: malus-free food is preferred; the weight score decides within a tier.
--- Returns an IsoObject food item, or nil.
--- @return item|nil, container|nil  (V4.9: container holding the winner)
function AutoPilot_Inventory.selectFoodByWeight(player)
    local weight = 75
    pcall(function()
        local nutrition = player:getNutrition()
        if nutrition then weight = nutrition:getWeight() or 75 end
    end)

    local best, bestScore = nil, nil
    local bestCont = nil
    local bestMalus = math.huge

    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        if isFoodEdible(item) then
            local malus = AutoPilot_Inventory.foodMalusScore(item)
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

            if bestScore == nil
                or malus < bestMalus
                or (malus == bestMalus and score > bestScore) then
                best, bestScore = item, score
                bestMalus = malus
                bestCont = container
            end
        end
        return false
    end)
    return best, bestCont
end

-- Returns the best drink item (negative thirst change = hydrating).
-- V4.8: searches worn/carried sub-containers too.  Main-inventory items are
-- still visited first, so the previously-chosen item still wins when present.
-- V4.9: also returns the container holding it.
-- @return item|nil, container|nil
function AutoPilot_Inventory.getBestDrink(player)
    local found = nil
    local foundCont = nil

    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        if item and item:isFood() and not item:isRotten() then
            local thirstChange = item:getThirstChange()
            if thirstChange and thirstChange < 0 then
                found = item
                foundCont = container
                return true  -- first hydrating item wins
            end
        end
        return false
    end)
    return found, foundCont
end

-- Returns the highest-damage melee weapon in inventory.
-- B42: instanceof avoids Java-level exceptions that pcall(isWeapon) still logs.
-- V4.9: also returns the container holding it (equipping needs it in the main
-- inventory).
-- @return item|nil, container|nil
function AutoPilot_Inventory.getBestWeapon(player)
    local best = nil
    local bestCont = nil
    local bestDmg = 0

    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        if item and instanceof(item, "HandWeapon") then
            local dmg = item:getMaxDamage() or 0
            if dmg > bestDmg then
                bestDmg = dmg
                best = item
                bestCont = container
            end
        end
        return false
    end)
    return best, bestCont
end

-- Returns any readable literature item from inventory.
-- B42: ItemType.LITERATURE covers all books, magazines, newspapers, comics, novels.
-- Skips uninteresting items (blank notebooks) and already-read items with no pages left.
-- V4.9: also returns the container holding it.
-- @return item|nil, container|nil
function AutoPilot_Inventory.getReadable(player)
    local found = nil
    local foundCont = nil

    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
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
                            found = item
                            foundCont = container
                            return true  -- first readable wins
                        end
                    end
                end
            end
        end
        return false
    end)
    return found, foundCont
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
-- A carry-gate refusal returns false PLUS the fail label "carry_full", so a
-- caller can tell "the pickup was refused" apart from "nothing was found" —
-- the two were indistinguishable in telemetry, which made an overloaded
-- character's scavenge backoff log as "no supply gain" with no hint the mod
-- was full (2026-07-26 follow-up to PR #85).  The label travels through the
-- public loot functions' tail calls (return _queueTransfer(...)), and callers
-- that ignore the second value are byte-for-byte unaffected.
-- allowOverload=true skips the carry-capacity gate.  Reserved for transfers the
-- mod must make even at the cost of a Heavy Load moodle (bleeding out beats
-- encumbrance); every discretionary pickup leaves it nil and is gated.
local function _queueTransfer(player, item, container, label, allowOverload)
    if not allowOverload and not AutoPilot_Utils.hasCarryRoom(player, item) then
        print("[Inventory] Skipping " .. label
            .. " — carrying too much already (Heavy Load / no capacity).")
        return false, "carry_full"
    end

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
            -- The engine discards any walk queued above game-speed index 2, and
            -- walkAdj queues an ISWalkToTimedAction internally, so BOTH branches
            -- below need the gate -- not just the fallback.
            AutoPilot_Utils.prepareWalk("loot")
            local walkOk = pcall(function()
                luautils.walkAdj(player, contSq, true)
            end)
            if not walkOk then
                AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, contSq))
            end
        end
    end

    local ok = pcall(function()
        AutoPilot_Utils.queueModAction(ISInventoryTransferAction:new(
            player, item, container, player:getInventory()))
    end)
    if not ok then
        print("[Inventory] ISInventoryTransferAction failed for "
            .. label .. " — skipping direct transfer (MP-unsafe).")
    end
    return ok
end

-- ── Auto-loot from nearby containers ─────────────────────────────────────────

-- Phase 3: Generic predicate-based loot. Finds the first item matching predicate
-- within radius. ignoreHome=true ignores home bounds (supply runs).
-- Returns true if a transfer was queued.
local function _lootNearbyByPredicate(player, predicate, radius, ignoreHome, allowOverload)
    local found, foundContainer = nil, nil
    _iterateContainersNearby(player, radius, function(item, container)
        if predicate(item) then
            found = item
            foundContainer = container
            return true  -- stop on first match
        end
        return false
    end, ignoreHome)
    if found then
        return _queueTransfer(player, found, foundContainer, "supply run", allowOverload)
    end
    return false
end

--- Emergency medical loot: grab the first bandage-capable item within
--- MEDICAL_LOOT_RADIUS, ignoring home bounds (bleeding out beats containment)
--- and ignoring the carry-capacity gate (bleeding out also beats a Heavy Load
--- moodle: a bandage weighs almost nothing and the alternative is death).
--- Returns true when a transfer was queued.
function AutoPilot_Inventory.emergencyMedicalLoot(player)
    local pred = function(item)
        local ok, can = pcall(function() return item:isCanBandage() end)
        return ok and can == true
    end
    return _lootNearbyByPredicate(player, pred,
        AutoPilot_Constants.MEDICAL_LOOT_RADIUS, true, true)
end

--- Loot food/drink in an expanded radius for supply runs.
--- Clears the depletion cache first so previously-empty squares get re-checked.
--- Returns true if any item was found and queued.
function AutoPilot_Inventory.supplyRunLoot(player, predicate)
    -- Reset only the CALLING player's depletion cache (splitscreen-safe).
    local pnum = 0
    pcall(function() pnum = player:getPlayerNum() end)
    AutoPilot_Map.resetDepleted(pnum)
    return _lootNearbyByPredicate(player, predicate, AutoPilot_Constants.LOOT_RADIUS_SUPPLY, true)
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
        print("[Inventory] Looting readable: " .. tostring(found:getName()))
        return _queueTransfer(player, found, foundContainer, "readable")
    end
    print("[Inventory] No readable items found in nearby containers.")
    return false
end

-- Scans nearby containers for food and transfers the best item.
-- radius: optional override (proactive scavenging passes a small radius so
-- background top-ups stay near home; reactive hunger uses the full default).
--
-- V6.0-2: malus-free food is preferred, calories decide within a malus tier —
-- the same two-key ranking the hunger-path selectors got in V6.0-1, sharing the
-- one AutoPilot_Inventory.foodMalusScore helper so the two halves of "prioritise
-- food by the ABSENCE OF MALUS EFFECTS" cannot drift apart.
--
-- This is a RANKING change and deliberately NOT a filter change: the WHAT-counts
-- predicate below is untouched, so nothing lootable before this slice became
-- unlootable.  That is load-bearing, not stylistic — see the predicate comment.
function AutoPilot_Inventory.lootNearbyFood(player, radius)
    local best, bestCal, bestContainer = nil, -999, nil
    local bestMalus = math.huge
    _iterateContainersNearby(player, radius or LOOT_SEARCH_RADIUS, function(item, container)
        if item:isFood() and not item:isRotten() then
            -- Match getSupplyCounts: only calorie-positive, non-drink items
            -- count as food, so looting always improves the supply counter
            -- (mismatched predicates caused an endless loot loop).  Malus is
            -- scored but never rejected here for exactly that reason: a malus
            -- food the supply counter counts must stay loot-eligible, or the
            -- mod would haul nothing while reporting itself short of food.
            local cal    = item:getCalories() or 0
            local thirst = item:getThirstChange() or 0
            if cal > 0 and thirst >= 0 then
                local malus = AutoPilot_Inventory.foodMalusScore(item)
                if malus < bestMalus or (malus == bestMalus and cal > bestCal) then
                    bestMalus = malus
                    bestCal = cal
                    best = item
                    bestContainer = container
                end
            end
        end
        return false  -- scan all squares to find the best
    end)
    if best then
        print("[Inventory] Looting food: " .. tostring(best:getName()))
        return _queueTransfer(player, best, bestContainer, "food")
    end
    print("[Inventory] No food found in nearby containers.")
    return false
end

-- Scans nearby containers for drinks and transfers the first hydrating item.
-- radius: optional override (see lootNearbyFood).
function AutoPilot_Inventory.lootNearbyDrink(player, radius)
    local found, foundContainer = nil, nil
    _iterateContainersNearby(player, radius or LOOT_SEARCH_RADIUS, function(item, container)
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
        print("[Inventory] Looting drink: " .. tostring(found:getName()))
        return _queueTransfer(player, found, foundContainer, "drink")
    end
    print("[Inventory] No drinks found in nearby containers.")
    return false
end

-- Counts how many food/drink items are available.
function AutoPilot_Inventory.getSupplyCounts(player)
    local foodCount = 0
    local drinkCount = 0

    AutoPilot_Utils.iteratePlayerItems(player, function(item)
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
        return false
    end)
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
        AutoPilot_Utils.prepareWalk("drink")
        local walkOk = pcall(function()
            luautils.walkAdj(player, sq, true)
        end)
        if not walkOk then
            AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, sq))
        end
    end

    local drinkOk, _ = pcall(function()
        AutoPilot_Utils.queueModAction(ISTakeWaterAction:new(player, nil, waterObj, tainted))
    end)
    if drinkOk then
        print("[Inventory] Drinking from water source.")
    end
    return drinkOk
end

-- Refill a water container from a nearby water source.
-- Finds the first non-full container in inventory and fills it.
-- Returns true if a refill action was queued.
function AutoPilot_Inventory.refillWaterContainer(player, waterObj)
    if not waterObj then return false end

    local container = nil

    AutoPilot_Utils.iteratePlayerItems(player, function(item)
        if item then
            -- Check for FluidContainer-based items (B42 fluid system)
            local ok, fc = pcall(function() return item:getFluidContainer() end)
            if ok and fc then
                local ok1, isNotFull  = pcall(function() return not fc:isFull() end)
                local ok2, canAddWater = pcall(function() return fc:canAddFluid(Fluid.Water) end)
                if ok1 and isNotFull and ok2 and canAddWater then
                    container = item
                    return true
                end
            end
            -- Fallback: legacy canStoreWater items
            local ok2, canStore = pcall(function() return item:canStoreWater() end)
            if ok2 and canStore then
                local ok3, isFull = pcall(function()
                    return item:isWaterSource() and item:getCurrentUsesFloat() >= 1.0
                end)
                if ok3 and not isFull then
                    container = item
                    return true
                end
            end
        end
        return false
    end)

    if not container then return false end

    local ok, tainted = pcall(function() return waterObj:isTaintedWater() end)
    if not ok then tainted = false end

    local sq = waterObj:getSquare()
    if sq then
        -- walkAdj with no ISWalkToTimedAction fallback, which is exactly why a
        -- grep for ISWalkToTimedAction alone did not find this site.
        AutoPilot_Utils.prepareWalk("water refill")
        pcall(function() luautils.walkAdj(player, sq, true) end)
    end

    local fillOk, _ = pcall(function()
        AutoPilot_Utils.queueModAction(ISTakeWaterAction:new(player, container, waterObj, tainted))
    end)
    if fillOk then
        print("[Inventory] Refilling " .. tostring(container:getName()) .. " from water source.")
    end
    return fillOk
end

-- Returns true if a water source is nearby.
function AutoPilot_Inventory.hasNearbyWaterSource(player)
    return AutoPilot_Inventory.findWaterSource(player) ~= nil
end

--- Proactively top up water containers while calm.  Only runs when thirst is
--- still low (the normal doDrink path handles active thirst) and a water
--- source is within range.  Returns true when a refill action was queued.
function AutoPilot_Inventory.proactiveWaterRefill(player)
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    if thirst >= AutoPilot_Constants.PROACTIVE_WATER_THIRST_MAX then
        return false
    end
    local waterObj = AutoPilot_Inventory.findWaterSource(player)
    if not waterObj then return false end
    return AutoPilot_Inventory.refillWaterContainer(player, waterObj) == true
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

    print("[Inventory] Search '" .. keyword .. "': found "
        .. #results .. " items")
    return results
end

-- Loot the first item matching `keyword` from nearby containers.
-- Returns true if a transfer was queued.
function AutoPilot_Inventory.lootItem(player, keyword)
    local results = AutoPilot_Inventory.searchItem(player, keyword)
    if #results == 0 then
        print("[Inventory] Loot: nothing matching '" .. keyword .. "' found.")
        return false
    end

    local best = results[1]
    print("[Inventory] Looting: " .. best.name)
    return _queueTransfer(player, best.item, best.container, best.name)
end

-- Place an item from player inventory into the nearest container.
-- keyword: partial name match for the inventory item to place.
function AutoPilot_Inventory.placeItem(player, keyword)
    if not keyword or keyword == "" then
            print("[Inventory] placeItem: no keyword given.")
        return false
    end

    -- Find matching item anywhere the player is carrying it (V4.8), and keep
    -- the container that actually holds it: the transfer source must be that
    -- container, not the main inventory, or moving an item out of a backpack
    -- would name the wrong source.
    local inv = player:getInventory()
    local kw = keyword:lower()

    local target, targetContainer = AutoPilot_Utils.findPlayerItem(player, function(item)
        local name = item:getName()
        return name ~= nil and name:lower():find(kw, 1, true) ~= nil
    end)
    targetContainer = targetContainer or inv

    if not target then
        print("[Inventory] placeItem: '"
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
        print("[Inventory] placeItem: no container found nearby.")
        return false
    end

    -- Walk to the container's square first, then transfer
    local objSq = bestObj:getSquare()
    print("[Inventory] Placing '"
        .. tostring(target:getName()) .. "' into container at ("
        .. tostring(objSq:getX()) .. ","
        .. tostring(objSq:getY()) .. ").")

    -- Queue walk then transfer
    if bestDist > 4 then
        AutoPilot_Utils.prepareWalk("store item")
        AutoPilot_Utils.queueModAction(
            ISWalkToTimedAction:new(player, objSq))
    end

    local ok, err = pcall(function()
        AutoPilot_Utils.queueModAction(ISInventoryTransferAction:new(
            player, target, targetContainer, bestContainer))
    end)
    if not ok then
            print("[Inventory] ISInventoryTransferAction failed for placeItem: "
            .. tostring(err) .. " — skipping direct transfer (MP-unsafe).")
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Exercise equipment fetch (V3.3)
-- ---------------------------------------------------------------------------
-- Equipment exercises (dumbbellpress/bicepscurl at 1.8x, barbellcurl at 1.2x)
-- gate on the item being IN INVENTORY (vanilla: inventory:contains(item, true)
-- in ISFitnessUI).  These helpers fetch a dumbbell/barbell from home storage
-- so those exercises unlock.  NOTE: merely HOLDING gear grants nothing — the
-- xpMod belongs to the equipment exercise type (the pre-3.3 "tier multiplier"
-- logic was a misconception and is gone).

--- True when a dumbbell or barbell is already carried.
function AutoPilot_Inventory.hasExerciseEquipment(player)
    local has = false
    pcall(function()
        local inv = player:getInventory()
        has = inv:contains("Base.DumbBell", true)
            or inv:contains("Base.BarBell", true)
    end)
    return has
end

--- Queue a trip to fetch exercise equipment from home containers.
--- Returns true when a fetch trip (walk + transfer) was queued.
function AutoPilot_Inventory.fetchExerciseEquipment(player)
    if AutoPilot_Inventory.hasExerciseEquipment(player) then return false end
    local found, foundContainer = nil, nil
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
                        local okT, typ = pcall(function() return item:getType() end)
                        if okT and typ
                            and (typ:find("DumbBell") or typ:find("BarBell")) then
                            found, foundContainer = item, cont
                            return true
                        end
                    end
                end
            end
            return false
        end)
    if not found then
        print("[Inv] No exercise equipment found in home area.")
        return false
    end
    print("[Inv] Fetching exercise equipment: " .. tostring(found:getType()))
    return _queueTransfer(player, found, foundContainer, "exercise equipment")
end

-- ---------------------------------------------------------------------------
-- Phase 3: Happiness / unhappiness helpers
-- ---------------------------------------------------------------------------

--- Find the food item in inventory that best relieves LOW MOOD.
---
--- Its only caller is the UNHAPPY arm of AutoPilot_Needs.doMoodRelief, so the
--- primary ranking key is getUnhappyChange(), not getBoredomChange().  Sign
--- convention verified live against the 42.19 install, not assumed: the item
--- tooltip flags a food as good exactly when `item:getUnhappyChange() < 0`
--- (client/ISUI/ISInventoryPaneContextMenu.lua:2079-2082, the same shape as the
--- thirst row one block above), and ISReadABook only lowers
--- CharacterStat.UNHAPPINESS when `self.item:getUnhappyChange() < 0.0`
--- (shared/TimedActions/ISReadABook.lua:72).  So MORE NEGATIVE = better.
---
--- Ranking on boredom alone let a food that reduced boredom while RAISING
--- unhappiness win, making the moodle this arm treats worse; the old gate here
--- (isFood and not isRotten) was also weaker than this module's own isFoodSafe,
--- so mood relief could eat frozen or raw-cookable food the hunger path refuses.
--- isFoodSafe rejects rotten, frozen, uncooked-cookable, poisonous and tainted
--- food, and any POSITIVE unhappy or boredom change, so reusing it is what makes
--- "never worsen either moodle" true.  On top of it a candidate must help at
--- least one of the two (0 on both is inert).  Boredom stays the tie-break,
--- which keeps the old choice when no food carries an unhappiness value at all.
--- V6.0-1 NOTE: isFoodSafe is now the MOOD arm's gate alone.  The hunger path
--- moved to the looser isFoodEdible plus a malus RANKING, because refusing
--- joyless food outright could starve a character who was carrying food; the
--- mood arm keeps the strict predicate on purpose, since eating a food that
--- raises unhappiness to treat unhappiness is a contradiction, not a trade-off.
--- V4.9: also returns the container holding it.
--- @return item|nil, container|nil
function AutoPilot_Inventory.preferTastyFood(player)
    local best, bestCont = nil, nil
    local bestUnhappy, bestBoredom = 0, 0  -- want most negative (most reducing)

    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        if isFoodSafe(item) then
            local unhappy, boring = 0, 0
            pcall(function() unhappy = item:getUnhappyChange() or 0 end)
            pcall(function() boring  = item:getBoredomChange() or 0 end)
            -- Inert food helps neither moodle; skip it rather than eat rations.
            if unhappy < 0 or boring < 0 then
                if unhappy < bestUnhappy
                    or (unhappy == bestUnhappy and boring < bestBoredom) then
                    bestUnhappy = unhappy
                    bestBoredom = boring
                    best = item
                    bestCont = container
                end
            end
        end
        return false
    end)
    return best, bestCont
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
--- Carry-capacity gated per item, like every other pickup path: a bulk grab is
--- the easiest way to overload a character in one action.  (No production
--- caller today — a whole-mod grep finds only this definition — but it is a
--- public function, so the gate lives here rather than in a future caller.)
function AutoPilot_Inventory.bulkLoot(player, container, keywords)
    if not container then return 0 end
    local inv   = player:getInventory()
    local count = 0
    for i = 0, container:getItems():size() - 1 do
        local item = container:getItems():get(i)
        if item and AutoPilot_Utils.hasCarryRoom(player, item) then
            local name = ""
            pcall(function() name = item:getType():lower() end)
            for _, kw in ipairs(keywords) do
                if name:find(kw:lower(), 1, true) then
                    local ok = pcall(function()
                        AutoPilot_Utils.queueModAction(ISInventoryTransferAction:new(
                            player, item, container, inv))
                    end)
                    if ok then count = count + 1 end
                    break
                end
            end
        end
    end
    if count > 0 then
        print(("[Inv] Bulk looted %d items from container."):format(count))
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
--- V4.9: also returns the container holding it.
--- @return item|nil, container|nil
function AutoPilot_Inventory.bestMeleeWeapon(player)
    local best, bestScore = nil, -1
    local bestCont = nil
    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
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
            bestCont = container
        end
        return false
    end)
    return best, bestCont
end

--- Equip the best available melee weapon if current weapon is below WEAPON_CONDITION_MIN.
--- Returns true if a swap was made.
function AutoPilot_Inventory.checkAndSwapWeapon(player)
    local cond = AutoPilot_Inventory.equippedWeaponCondition(player)
    if cond >= AutoPilot_Constants.WEAPON_CONDITION_MIN then return false end
    print(("[Inv] Weapon condition %.2f < %.2f — seeking replacement."):format(
        cond, AutoPilot_Constants.WEAPON_CONDITION_MIN))
    local replacement, replacementCont = AutoPilot_Inventory.bestMeleeWeapon(player)
    if not replacement then
        print("[Inv] No replacement weapon found in inventory.")
        return false
    end
    -- V4.9: a weapon in a bag cannot be equipped from there; move it first.
    local _, usable = AutoPilot_Utils.queueItemToMainInventory(
        player, replacement, replacementCont)
    if not usable then
        print("[Inv] Weapon transfer refused: skipping the swap this cycle.")
        return false
    end
    local ok = pcall(function()
        AutoPilot_Utils.queueModAction(ISEquipWeaponAction:new(player, replacement, 50, true))
    end)
    if ok then
        print("[Inv] Queued equip of " .. replacement:getType())
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
--- V4.9: also returns the container holding it.
--- @return item|nil, container|nil
function AutoPilot_Inventory.findClothing(player, wantWarm)
    local best, bestVal = nil, nil
    local bestCont = nil
    -- Check the whole carried inventory tree (V4.8: spare clothing normally
    -- lives in a bag, which the old top-level-only scan could never see).
    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        local ok, insulation = pcall(function()
            return (item.getInsulation and item:getInsulation()) or nil
        end)
        if ok and insulation ~= nil then
            local score = wantWarm and insulation or -insulation
            if bestVal == nil or score > bestVal then
                best, bestVal = item, score
                bestCont = container
            end
        end
        return false
    end)
    return best, bestCont
end

--- Attempt to equip appropriate clothing for the current temperature.
--- Returns true if an action was queued.
--- V4.9: spare clothing normally lives in a bag, and ISWearClothing needs the
--- garment in the main inventory, so the move is queued ahead of the wear.
local function _queueWear(player, item, container)
    local _, usable = AutoPilot_Utils.queueItemToMainInventory(player, item, container)
    if not usable then
        print("[Inv] Clothing transfer refused: not wearing it this cycle.")
        return false
    end
    AutoPilot_Utils.queueModAction(ISWearClothing:new(player, item, 50))
    print("[Inv] Queued: wear " .. item:getType())
    return true
end

function AutoPilot_Inventory.adjustClothing(player)
    local temp = AutoPilot_Inventory.bodyTemperature(player)
    if temp > AutoPilot_Constants.TEMP_TOO_HOT then
        print(("[Inv] Too hot (%.1f) — seeking cool clothing."):format(temp))
        local item, cont = AutoPilot_Inventory.findClothing(player, false)
        if item then
            return _queueWear(player, item, cont)
        end
    elseif temp < AutoPilot_Constants.TEMP_TOO_COLD then
        print(("[Inv] Too cold (%.1f) — seeking warm clothing."):format(temp))
        local item, cont = AutoPilot_Inventory.findClothing(player, true)
        if item then
            return _queueWear(player, item, cont)
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
    local names = {}
    local seen = {}

    AutoPilot_Utils.iteratePlayerItems(player, function(item)
        if item then
            local ok, name = pcall(function() return item:getName() end)
            if ok and name then
                if not seen[name] then
                    seen[name] = 0
                end
                seen[name] = seen[name] + 1
            end
        end
        return false
    end)

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
