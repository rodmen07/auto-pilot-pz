-- AutoPilot_Foraging.lua
-- Intelligent foraging system: learns zones, prioritizes searches, tracks item types.
--
-- Phase 1 expansion: replaces dumb "loot nearby" with smart zone learning and
-- item-type targeting. Zones improve over time as they're successfully looted.

AutoPilot_Foraging = {}

local function _apNoop(...) end
local print = _apNoop

-- ── Zone State ──────────────────────────────────────────────────────────────
-- Zone format: { x, y, z, quality_score, last_searched_ms, item_types_found }
-- Quality score: 0.0 = bad, 1.0 = excellent (increases with successful loots)

local _zones = {}  -- indexed by "x,y,z" string
local ZONE_QUALITY_INITIAL = 0.5
local ZONE_QUALITY_SUCCESS_BOOST = 0.1
local ZONE_QUALITY_FAIL_PENALTY = -0.05
local ZONE_QUALITY_MIN = 0.0
local ZONE_QUALITY_MAX = 1.0
local ZONE_EXHAUSTION_HOURS = 4  -- don't re-search same zone for 4 hours

-- ── Item Type Registry ──────────────────────────────────────────────────────
-- Categorizes items for targeted looting.

local ITEM_TYPES = {
    FOOD = "food",
    DRINK = "drink",
    WEAPON = "weapon",
    MEDICAL = "medical",
    TOOL = "tool",
    AMMO = "ammo",
    EQUIPMENT = "equipment",
    CLOTHING = "clothing",
    FUEL = "fuel",
    OTHER = "other",
}

local function categorizeItem(item)
    if not item then return ITEM_TYPES.OTHER end

    local ok, isFood = pcall(function() return item:isFood() end)
    if ok and isFood then
        local thirst = item:getThirstChange()
        if thirst and thirst < 0 then
            return ITEM_TYPES.DRINK
        end
        return ITEM_TYPES.FOOD
    end

    local ok2, isWeapon = pcall(function() return item:isWeapon() end)
    if ok2 and isWeapon then
        return ITEM_TYPES.WEAPON
    end

    local ok3, isMedical = pcall(function() return item:isCanBandage() end)
    if ok3 and isMedical then
        return ITEM_TYPES.MEDICAL
    end

    local ok4, name = pcall(function() return item:getType():lower() end)
    if ok4 and name then
        if name:find("axe") or name:find("hammer") or name:find("saw")
            or name:find("crowbar") or name:find("wrench") then
            return ITEM_TYPES.TOOL
        elseif name:find("bullet") or name:find("ammo") or name:find("magazine") then
            return ITEM_TYPES.AMMO
        elseif name:find("gas") or name:find("fuel") or name:find("petrol") then
            return ITEM_TYPES.FUEL
        elseif name:find("shirt") or name:find("pants") or name:find("jacket")
            or name:find("hat") or name:find("shoes") then
            return ITEM_TYPES.CLOTHING
        end
    end

    return ITEM_TYPES.OTHER
end

-- ── Zone Management ────────────────────────────────────────────────────────

local function _getZoneKey(x, y, z)
    return string.format("%d,%d,%d", math.floor(x), math.floor(y), z)
end

local function _getOrCreateZone(x, y, z)
    local key = _getZoneKey(x, y, z)
    if not _zones[key] then
        _zones[key] = {
            x = math.floor(x),
            y = math.floor(y),
            z = z,
            quality = ZONE_QUALITY_INITIAL,
            last_searched_ms = 0,
            item_types = {},
        }
    end
    return _zones[key]
end

local function _isZoneExhausted(zone)
    local ok, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms = ok and nowMs or 0
    local exhaustion_ms = ZONE_EXHAUSTION_HOURS * 60 * 60 * 1000
    return (ms - zone.last_searched_ms) < exhaustion_ms
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Analyze a square and record what item types were found there.
--- Called after a successful loot to learn zone quality.
function AutoPilot_Foraging.recordZone(player, sq, itemsFound)
    if not sq or not itemsFound then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local zone = _getOrCreateZone(x, y, z)

    -- Record item types
    for _, itemType in ipairs(itemsFound) do
        if not zone.item_types[itemType] then
            zone.item_types[itemType] = 0
        end
        zone.item_types[itemType] = zone.item_types[itemType] + 1
    end

    -- Boost zone quality on success
    zone.quality = math.min(ZONE_QUALITY_MAX,
        zone.quality + ZONE_QUALITY_SUCCESS_BOOST)
    zone.last_searched_ms = getGameTime():getCalender():getTimeInMillis()

    print(string.format("[Foraging] Zone (%d,%d,%d) quality now %.2f",
        zone.x, zone.y, zone.z, zone.quality))
end

--- Called when a zone search yields nothing. Penalizes quality.
function AutoPilot_Foraging.recordZoneEmpty(player, sq)
    if not sq then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local zone = _getOrCreateZone(x, y, z)

    zone.quality = math.max(ZONE_QUALITY_MIN,
        zone.quality + ZONE_QUALITY_FAIL_PENALTY)
    zone.last_searched_ms = getGameTime():getCalender():getTimeInMillis()

    print(string.format("[Foraging] Zone (%d,%d,%d) quality now %.2f (empty)",
        zone.x, zone.y, zone.z, zone.quality))
end

--- Get the best zone for a given item type within search radius.
--- Returns {zone, distance} or nil if no good zones found.
function AutoPilot_Foraging.findBestZoneForItem(player, itemType, radius)
    if not player or not itemType then return nil end

    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local bestZone = nil
    local bestQuality = 0
    local bestDist = math.huge

    for _, zone in pairs(_zones) do
        if zone.z == pz then  -- same floor
            local dx = zone.x - px
            local dy = zone.y - py
            local dist = dx * dx + dy * dy

            if dist <= radius * radius and not _isZoneExhausted(zone) then
                -- If zone has seen this item type, boost priority
                local itemBonus = (zone.item_types[itemType] or 0) * 0.1
                local quality = zone.quality + itemBonus

                if quality > bestQuality or (quality == bestQuality and dist < bestDist) then
                    bestZone = zone
                    bestQuality = quality
                    bestDist = dist
                end
            end
        end
    end

    if bestZone then
        return {zone = bestZone, distance = math.sqrt(bestDist)}
    end
    return nil
end

--- Get all zones sorted by quality (best first).
function AutoPilot_Foraging.getZonesByQuality()
    local sorted = {}
    for _, zone in pairs(_zones) do
        table.insert(sorted, zone)
    end
    table.sort(sorted, function(a, b)
        return a.quality > b.quality
    end)
    return sorted
end

--- Get zone statistics for telemetry.
function AutoPilot_Foraging.getZoneStats()
    local count = 0
    local avgQuality = 0
    local bestZone = nil
    local bestQuality = 0

    for _, zone in pairs(_zones) do
        count = count + 1
        avgQuality = avgQuality + zone.quality
        if zone.quality > bestQuality then
            bestZone = zone
            bestQuality = zone.quality
        end
    end

    if count > 0 then
        avgQuality = avgQuality / count
    end

    return {
        zone_count = count,
        avg_quality = avgQuality,
        best_zone = bestZone,
        best_quality = bestQuality,
    }
end

--- Categorize an item.
function AutoPilot_Foraging.categorizeItem(item)
    return categorizeItem(item)
end

--- Get the list of item types.
function AutoPilot_Foraging.getItemTypes()
    return ITEM_TYPES
end

print("[Foraging] AutoPilot_Foraging module loaded.")
