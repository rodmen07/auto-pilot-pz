-- AutoPilot_Medical.lua
-- Detects and treats wounds (bleeding, scratches, deep wounds, bites).
--
-- Priority: bleeding > deep wound > bite > scratch > burn
-- Treatment: find bandage in inventory → apply via ISApplyBandage.
-- Fallback: rip clothing into sheets if no bandages available.

AutoPilot_Medical = {}

-- ── Bandage item types, ordered by quality (best first) ─────────────────────
-- item:isCanBandage() is the authoritative check; this list guides selection.
local BANDAGE_PRIORITY = {
    "AlcoholBandage",
    "Bandage",
    "BandageDirty",
    "RippedSheets",
    "RippedSheetsDirty",
}

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- Safe wrapper for body-part method calls that may not exist in all B42 builds.
local function safeCall(bodyPart, method)
    local ok, val = pcall(function() return method(bodyPart) end)
    if ok then return val end
    return false
end

-- Returns the best bandage item from inventory, or nil.
local function findBandage(player)
    local inv = player:getInventory()
    -- Fast path: use the engine's isCanBandage() check
    local items = inv:getItems()
    local bestIdx = 999
    local bestItem = nil

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local ok, canBandage = pcall(function() return item:isCanBandage() end)
            if ok and canBandage then
                -- Rank by our priority list
                local itemType = item:getType()
                for idx, pType in ipairs(BANDAGE_PRIORITY) do
                    if itemType == pType and idx < bestIdx then
                        bestIdx = idx
                        bestItem = item
                        break
                    end
                end
                -- If not in our list but isCanBandage(), still use as fallback
                if bestItem == nil then
                    bestItem = item
                end
            end
        end
    end
    return bestItem
end

-- Scan nearby containers for bandage-type items and loot the first one found.
local MEDICAL_LOOT_RADIUS = 30

local function lootNearbyBandage(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local result = false

    AutoPilot_Utils.iterateNearbySquares(px, py, pz, MEDICAL_LOOT_RADIUS, function(sq)
        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            if obj then
                local container = obj:getContainer()
                if container then
                    local items = container:getItems()
                    for j = 0, items:size() - 1 do
                        local item = items:get(j)
                        if item then
                            local ok, canBandage = pcall(function()
                                return item:isCanBandage()
                            end)
                            if ok and canBandage then
                                AutoPilot_LLM.log("[Medical] Looting bandage: " ..
                                    tostring(item:getName()))
                                local xferOk = pcall(function()
                                    ISTimedActionQueue.add(
                                        ISInventoryTransferAction:new(
                                            player, item, container,
                                            player:getInventory()))
                                end)
                                if not xferOk then
                                    AutoPilot_LLM.log(
                                        "[Medical] ISInventoryTransferAction failed — skipping (MP-unsafe).")
                                else
                                    result = true
                                end
                                return true  -- stop iterating (found a bandage)
                            end
                        end
                    end
                end
            end
        end
        return false
    end)

    if result then return true end
    AutoPilot_LLM.log("[Medical] No bandages found in nearby containers.")
    return false
end

-- Treat a single wounded body part: find bandage and apply.
local function doTreatWound(player, bodyPart)
    local bandage = findBandage(player)
    if not bandage then
        AutoPilot_LLM.log("[Medical] No bandage in inventory — searching nearby containers.")
        if lootNearbyBandage(player) then
            bandage = findBandage(player)
        end
    end
    if not bandage then return false end

    local partName = "unknown"
    pcall(function()
        partName = BodyPartType.getDisplayName(bodyPart:getType())
    end)

    AutoPilot_LLM.log("[Medical] Treating wound on " .. partName ..
        " with " .. tostring(bandage:getName()))

    local ok, _ = pcall(function()
        ISTimedActionQueue.add(ISApplyBandage:new(player, player, bandage, bodyPart, true))
    end)
    return ok
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Check for wounds and treat the most critical one.
-- @param player      The player character.
-- @param bleedingOnly If true, only treat actively bleeding wounds (highest priority).
-- @return boolean    True if a treatment action was queued.
function AutoPilot_Medical.check(player, bleedingOnly)
    local ok, bodyParts = pcall(function()
        return player:getBodyDamage():getBodyParts()
    end)
    if not ok or not bodyParts then return false end

    local ok2, maxIndex = pcall(function()
        return BodyPartType.ToIndex(BodyPartType.MAX)
    end)
    if not ok2 or not maxIndex then return false end

    -- Collect wounded parts, sorted by severity
    local bleedingParts  = {}
    local deepWoundParts = {}
    local bittenParts    = {}
    local scratchedParts = {}
    local burntParts     = {}

    for i = 0, maxIndex - 1 do
        local bodyPart = bodyParts:get(i)
        if bodyPart and not safeCall(bodyPart, function(bp) return bp:bandaged() end) then
            if safeCall(bodyPart, function(bp) return bp:bleeding() end) then
                table.insert(bleedingParts, bodyPart)
            elseif not bleedingOnly then
                if safeCall(bodyPart, function(bp) return bp:deepWounded() end) then
                    table.insert(deepWoundParts, bodyPart)
                elseif safeCall(bodyPart, function(bp) return bp:bitten() end) then
                    table.insert(bittenParts, bodyPart)
                elseif safeCall(bodyPart, function(bp) return bp:scratched() end) then
                    table.insert(scratchedParts, bodyPart)
                elseif safeCall(bodyPart, function(bp) return bp:isBurnt() end) then
                    table.insert(burntParts, bodyPart)
                end
            end
        end
    end

    -- Treat in priority order: bleeding > deep wound > bite > scratch > burn
    local target = bleedingParts[1]
        or deepWoundParts[1]
        or bittenParts[1]
        or scratchedParts[1]
        or burntParts[1]

    if target then
        return doTreatWound(player, target)
    end
    return false
end

--- Returns true if any body part is actively bleeding (unbandaged).
-- Used by AutoPilot_Threat to force flee when critically wounded.
function AutoPilot_Medical.hasCriticalWound(player)
    local ok, bodyParts = pcall(function()
        return player:getBodyDamage():getBodyParts()
    end)
    if not ok or not bodyParts then return false end

    local ok2, maxIndex = pcall(function()
        return BodyPartType.ToIndex(BodyPartType.MAX)
    end)
    if not ok2 or not maxIndex then return false end

    for i = 0, maxIndex - 1 do
        local bodyPart = bodyParts:get(i)
        if bodyPart
            and not safeCall(bodyPart, function(bp) return bp:bandaged() end)
            and safeCall(bodyPart, function(bp) return bp:bleeding() end) then
            return true
        end
    end
    return false
end

--- Returns a snapshot of wound state for LLM state reporting.
function AutoPilot_Medical.getWoundSnapshot(player)
    local snapshot = { bleeding = 0, scratched = 0, deep_wounded = 0, bitten = false, burnt = 0 }

    local ok, bodyParts = pcall(function()
        return player:getBodyDamage():getBodyParts()
    end)
    if not ok or not bodyParts then return snapshot end

    local ok2, maxIndex = pcall(function()
        return BodyPartType.ToIndex(BodyPartType.MAX)
    end)
    if not ok2 or not maxIndex then return snapshot end

    for i = 0, maxIndex - 1 do
        local bodyPart = bodyParts:get(i)
        if bodyPart and not safeCall(bodyPart, function(bp) return bp:bandaged() end) then
            if safeCall(bodyPart, function(bp) return bp:bleeding() end) then
                snapshot.bleeding = snapshot.bleeding + 1
            end
            if safeCall(bodyPart, function(bp) return bp:scratched() end) then
                snapshot.scratched = snapshot.scratched + 1
            end
            if safeCall(bodyPart, function(bp) return bp:deepWounded() end) then
                snapshot.deep_wounded = snapshot.deep_wounded + 1
            end
            if safeCall(bodyPart, function(bp) return bp:bitten() end) then
                snapshot.bitten = true
            end
            if safeCall(bodyPart, function(bp) return bp:isBurnt() end) then
                snapshot.burnt = snapshot.burnt + 1
            end
        end
    end
    return snapshot
end

AutoPilot_LLM.log("[Medical] AutoPilot_Medical module loaded.")
