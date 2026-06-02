-- AutoPilot_Vehicles.lua
-- Vehicle management: detection, fuel, maintenance, long-distance travel.
--
-- Phase 1 expansion: integrate vehicles as mobile base and transport.
-- Vehicles enable supply runs 500+ tiles away and emergency shelter.

AutoPilot_Vehicles = {}

local function _apNoop(...) end
local print = _apNoop

-- ── Vehicle Registry ───────────────────────────────────────────────────────
-- Tracks vehicles: location, condition, fuel, inventory.

local _vehicles = {}  -- indexed by vehicle id or location key

-- ── Vehicle Detection & Management ─────────────────────────────────────────

--- Find all vehicles within a search radius.
function AutoPilot_Vehicles.findNearbyVehicles(player, radius)
    if not player then return {} end

    local px, py = player:getX(), player:getY()
    local vehicles = {}

    local ok, allVehicles = pcall(function()
        local cell = getCell()
        if not cell then return nil end
        return cell:getVehicles()
    end)

    if not ok or not allVehicles then
        return vehicles
    end

    for i = 0, allVehicles:size() - 1 do
        local veh = allVehicles:get(i)
        if veh then
            local vx, vy = veh:getX(), veh:getY()
            local dist = math.sqrt((vx - px) ^ 2 + (vy - py) ^ 2)
            if dist <= radius then
                table.insert(vehicles, {vehicle = veh, distance = dist})
            end
        end
    end

    table.sort(vehicles, function(a, b) return a.distance < b.distance end)
    return vehicles
end

--- Register a vehicle as a known base location.
function AutoPilot_Vehicles.registerVehicle(vehicle)
    if not vehicle then return end

    local ok, x, y = pcall(function()
        return vehicle:getX(), vehicle:getY()
    end)

    if ok then
        local key = string.format("%d,%d", math.floor(x), math.floor(y))
        _vehicles[key] = {
            vehicle = vehicle,
            x = x,
            y = y,
            registered_ms = getGameTime():getCalender():getTimeInMillis(),
        }
        print("[Vehicles] Registered vehicle at (" .. key .. ")")
    end
end

--- Get registered vehicles.
function AutoPilot_Vehicles.getRegisteredVehicles()
    local list = {}
    for _, data in pairs(_vehicles) do
        table.insert(list, data)
    end
    return list
end

-- ── Fuel Management ───────────────────────────────────────────────────────

--- Check vehicle fuel level (0.0-1.0).
local function getVehicleFuelLevel(vehicle)
    if not vehicle then return 0 end

    local ok, tank = pcall(function()
        return vehicle:getTank(0)  -- tank 0 = primary fuel
    end)

    if ok and tank then
        local ok2, capacity = pcall(function()
            return tank:getCapacity()
        end)
        local ok3, amount = pcall(function()
            return tank:getAmount()
        end)

        if ok2 and ok3 and capacity and capacity > 0 then
            return amount / capacity
        end
    end

    return 0
end

--- Estimate fuel needed for a distance (rough heuristic).
local function estimateFuelNeeded(distance)
    -- Average vehicle gets ~5 tiles per fuel unit
    -- Adjust based on vehicle type (car vs truck)
    return distance / 5
end

--- Check if vehicle has enough fuel for a trip.
function AutoPilot_Vehicles.canMakTrip(vehicle, distance)
    if not vehicle then return false end

    local fuelLevel = getVehicleFuelLevel(vehicle)
    local fuelNeeded = estimateFuelNeeded(distance)
    local capacity = 100  -- default estimate

    local ok, tank = pcall(function()
        return vehicle:getTank(0)
    end)
    if ok and tank then
        local ok2, cap = pcall(function() return tank:getCapacity() end)
        if ok2 and cap then capacity = cap end
    end

    local currentFuel = fuelLevel * capacity
    return currentFuel >= fuelNeeded * 1.2  -- 20% safety margin
end

--- Get fuel status for telemetry.
function AutoPilot_Vehicles.getFuelStatus(vehicle)
    if not vehicle then return nil end

    return {
        fuel_level = getVehicleFuelLevel(vehicle),
        estimated_range_tiles = getVehicleFuelLevel(vehicle) * 500,  -- rough estimate
    }
end

-- ── Vehicle as Mobile Base ─────────────────────────────────────────────────

--- Check if vehicle can serve as shelter (is accessible, has seats/trunk).
function AutoPilot_Vehicles.isVehicleSafe(vehicle)
    if not vehicle then return false end

    local ok, hasSeats = pcall(function()
        return vehicle:getSeatCount() and vehicle:getSeatCount() > 0
    end)

    if ok and hasSeats then
        -- Check if doors can be locked
        local ok2, locked = pcall(function()
            return vehicle:isLocked()
        end)
        if ok2 then
            return true
        end
    end

    return false
end

--- Walk to vehicle and board it.
function AutoPilot_Vehicles.boardVehicle(player, vehicle)
    if not player or not vehicle then return false end

    local ok, vx, vy, vz = pcall(function()
        return vehicle:getX(), vehicle:getY(), vehicle:getZ()
    end)

    if not ok then return false end

    local vSq = getCell():getGridSquare(vx, vy, vz)
    if not vSq then return false end

    -- Walk to vehicle
    pcall(function()
        luautils.walkAdj(player, vSq, true)
    end)

    -- Attempt to enter vehicle
    local ok2 = pcall(function()
        ISTimedActionQueue.add(ISEnterVehicleAction:new(player, vSq, vehicle))
    end)

    return ok2
end

-- ── Long-Distance Travel ───────────────────────────────────────────────────

--- Plan a supply run to a distant location (500+ tiles).
--- Returns {viable, vehicle, distance, fuel_needed} or nil.
function AutoPilot_Vehicles.planDistantSupplyRun(player, targetX, targetY)
    if not player then return nil end

    local px, py = player:getX(), player:getY()
    local distance = math.sqrt((targetX - px) ^ 2 + (targetY - py) ^ 2)

    -- Only consider for distant trips
    if distance < 100 then
        return nil
    end

    -- Find best available vehicle
    local vehicles = AutoPilot_Vehicles.findNearbyVehicles(player, 150)
    for _, vehData in ipairs(vehicles) do
        local veh = vehData.vehicle
        if AutoPilot_Vehicles.canMakTrip(veh, distance) then
            return {
                viable = true,
                vehicle = veh,
                distance = distance,
                fuel_needed = estimateFuelNeeded(distance),
            }
        end
    end

    print("[Vehicles] No vehicle suitable for " .. tostring(distance) .. " tile trip.")
    return {viable = false, reason = "no_vehicle_or_fuel"}
end

-- ── Maintenance ────────────────────────────────────────────────────────────

--- Check vehicle condition and flag for maintenance.
function AutoPilot_Vehicles.getMaintenanceStatus(vehicle)
    if not vehicle then return nil end

    local ok, engine = pcall(function()
        return vehicle:getPartByName("Engine")
    end)

    local engineHealth = 1.0
    if ok and engine then
        local ok2, health = pcall(function()
            return engine:getCondition() / (engine:getConditionMax() or 1)
        end)
        if ok2 then engineHealth = health end
    end

    return {
        engine_condition = engineHealth,
        needs_repair = engineHealth < 0.5,
    }
end

print("[Vehicles] AutoPilot_Vehicles module loaded.")
