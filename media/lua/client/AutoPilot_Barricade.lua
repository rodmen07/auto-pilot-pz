--- AutoPilot_Barricade.lua
--- One-time safehouse barricading: nails up windows and reinforces doors near home.
-- Runs once after home is set; uses player ModData to record completion.

AutoPilot_Barricade = {}

local function _apNoop(...) end
local print = _apNoop

local MODDATA_KEY = "AutoPilot_Barricaded"

--- Return true if barricading has already been completed for this home.
function AutoPilot_Barricade.isDone(player)
    local md = player:getModData()
    return md[MODDATA_KEY] == true
end

--- Mark barricading as complete in player ModData.
local function _markDone(player)
    player:getModData()[MODDATA_KEY] = true
    player:transmitModData()
    print("[AutoPilot] [Barricade] Home barricading complete — marked in ModData.")
end

--- Queue barricade actions for all windows and doors within home bounds.
--- Returns the number of actions queued.
function AutoPilot_Barricade.doBarricade(player)
    if AutoPilot_Barricade.isDone(player) then
        print("[AutoPilot] [Barricade] Already barricaded — skipping.")
        return 0
    end
    if not AutoPilot_Home.isSet(player) then
        print("[AutoPilot] [Barricade] Home not set — cannot barricade.")
        return 0
    end

    local px  = math.floor(player:getX())
    local py  = math.floor(player:getY())
    local pz  = math.floor(player:getZ())
    local count = 0

    AutoPilot_Utils.iterateNearbySquares(px, py, pz,
        AutoPilot_Constants.BARRICADE_SEARCH_RADIUS,
        function(sq)
            if not AutoPilot_Home.isInside(sq) then return false end
            for oi = 0, sq:getObjects():size() - 1 do
                local obj = sq:getObjects():get(oi)
                -- Windows
                pcall(function()
                    if obj:getName() and obj:getName():lower():find("window") then
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
        end)

    if count > 0 then
        print("[AutoPilot] " .. ("[Barricade] Queued %d barricade action(s)."):format(count))
        _markDone(player)
    else
        print("[AutoPilot] [Barricade] No barricadable windows found (or missing nails/hammer).")
    end
    return count
end
