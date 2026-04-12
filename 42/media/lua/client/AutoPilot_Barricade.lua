--- AutoPilot_Barricade.lua
--- One-time safehouse barricading: nails up windows and reinforces doors near home.
-- Runs once after home is set; uses player ModData to record completion.
-- M3.4 Barricade maintenance: after BARRICADE_RECHECK_INTERVAL in-game days,
-- re-check home perimeter for newly broken windows.

AutoPilot_Barricade = {}

local function _apNoop(...) end
local print = _apNoop

local MODDATA_KEY        = "AutoPilot_Barricaded"
local MODDATA_RECHECK_KEY = "AutoPilot_BarricadeRecheckDay"

--- Return true if barricading has already been completed for this home.
function AutoPilot_Barricade.isDone(player)
    local ok, md = pcall(function() return player:getModData() end)
    if not ok or not md then return false end
    return md[MODDATA_KEY] == true
end

--- Mark barricading as complete in player ModData.
local function _markDone(player)
    local ok = pcall(function()
        player:getModData()[MODDATA_KEY] = true
        player:transmitModData()
    end)
    if ok then
        print("[AutoPilot] [Barricade] Home barricading complete — marked in ModData.")
    end
end

--- Record the in-game day of the last barricade recheck.
local function _markRecheckDay(player)
    local day = 0
    pcall(function()
        local gt = GameTime.getInstance()
        if gt then day = gt:getDay() or 0 end
    end)
    pcall(function()
        player:getModData()[MODDATA_RECHECK_KEY] = day
        player:transmitModData()
    end)
end

--- Return true if the barricade maintenance window has passed.
local function _needsRecheck(player)
    local ok, day = pcall(function()
        local gt = GameTime.getInstance()
        return gt and gt:getDay() or 0
    end)
    if not ok then return false end
    local lastDay = 0
    pcall(function()
        lastDay = player:getModData()[MODDATA_RECHECK_KEY] or 0
    end)
    return (day - lastDay) >= AutoPilot_Constants.BARRICADE_RECHECK_INTERVAL
end

--- Internal: scan and queue barricade actions.
--- Returns count of actions queued.
local function _scanAndBarricade(player)
    local px  = math.floor(player:getX())
    local py  = math.floor(player:getY())
    local pz  = math.floor(player:getZ())
    local pnum = 0
    pcall(function() pnum = player:getPlayerNum() end)
    local count = 0

    AutoPilot_Utils.iterateNearbySquares(px, py, pz,
        AutoPilot_Constants.BARRICADE_SEARCH_RADIUS,
        function(sq)
            if not AutoPilot_Home.isInside(sq, pnum) then return false end
            local okSz, sz = pcall(function() return sq:getObjects():size() end)
            if not (okSz and sz) then return false end
            for oi = 0, sz - 1 do
                local obj = sq:getObjects():get(oi)
                if obj then
                    pcall(function()
                        local okN, nm = pcall(function() return obj:getName() end)
                        if okN and nm and nm:lower():find("window") then
                            local inv = player:getInventory()
                            local nails  = inv:getFirstTypeRecurse("Nails")
                            local hammer = inv:getFirstTypeRecurse("Hammer")
                            if nails and hammer then
                                ISTimedActionQueue.add(ISBarricadeAction:new(
                                    player, obj, false, hammer, nails))
                                count = count + 1
                            end
                        end
                    end)
                end
            end
            return false
        end)
    return count
end

--- Queue barricade actions for all windows and doors within home bounds.
--- Returns the number of actions queued.
function AutoPilot_Barricade.doBarricade(player)
    if AutoPilot_Barricade.isDone(player) then
        -- M3.4: maintenance recheck — re-barricade broken windows periodically.
        if _needsRecheck(player) then
            print("[AutoPilot] [Barricade] Maintenance recheck — scanning for broken windows.")
            local recheckCount = _scanAndBarricade(player)
            _markRecheckDay(player)
            if recheckCount > 0 then
                print(("[AutoPilot] [Barricade] Maintenance: queued %d action(s)."):format(recheckCount))
            else
                print("[AutoPilot] [Barricade] Maintenance: no new windows to barricade.")
            end
            return recheckCount
        end
        print("[AutoPilot] [Barricade] Already barricaded — skipping.")
        return 0
    end
    if not AutoPilot_Home.isSet(player) then
        print("[AutoPilot] [Barricade] Home not set — cannot barricade.")
        return 0
    end

    local count = _scanAndBarricade(player)

    if count > 0 then
        print("[AutoPilot] " .. ("[Barricade] Queued %d barricade action(s)."):format(count))
        _markDone(player)
        _markRecheckDay(player)
    else
        print("[AutoPilot] [Barricade] No barricadable windows found (or missing nails/hammer).")
    end
    return count
end
