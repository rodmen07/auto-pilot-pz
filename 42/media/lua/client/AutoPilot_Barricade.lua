-- AutoPilot_Barricade.lua
-- Ongoing safehouse barricade maintenance.
--
-- Replaces the one-time "done forever" flag with a periodic re-check that
-- re-barricades any windows that have since been de-barricaded.
--
-- checkMaintenance(player) is called from AutoPilot_Needs on every eval cycle;
-- it only does real work when the countdown reaches zero, so the cost is a
-- single decrement in the common case.
--
-- doBarricade(player) is preserved for backward compatibility (LLM commands).

AutoPilot_Barricade = {}

local function _apNoop(...) end
local print = _apNoop

-- Legacy ModData key kept so existing saves do not error; value is ignored.
local MODDATA_KEY = "AutoPilot_Barricaded"

-- Countdown (eval cycles) until the next maintenance scan.
-- Starts at 0 so the first evaluation triggers an immediate check.
AutoPilot_Barricade._recheckCountdown = 0

--- (Legacy) Always returns false -- the permanent "done" flag is no longer used.
function AutoPilot_Barricade.isDone(_player)
    return false
end

-- Returns true if obj already has a barricade on its surface.
local function isBarricaded(obj)
    local ok, result = pcall(function()
        return obj:getBarricadeOnSurface() ~= nil
    end)
    return ok and result == true
end

-- Scan within BARRICADE_SEARCH_RADIUS and queue barricade actions for any
-- un-barricaded windows inside home bounds.  Returns actions queued.
local function _doScan(player)
    if not AutoPilot_Home.isSet(player) then
        print("[Barricade] Home not set -- skipping scan.")
        return 0
    end

    local px    = math.floor(player:getX())
    local py    = math.floor(player:getY())
    local pz    = math.floor(player:getZ())
    local count = 0
    local inv   = player:getInventory()

    -- B42 wood barricade requirements (shared/TimedActions/ISBarricadeAction.lua
    -- isValid): hammer EQUIPPED (HAMMER tag), plank EQUIPPED (secondary is
    -- consumed as the material), and >= 2 nails in inventory. The constructor is
    -- ISBarricadeAction:new(character, windowObj, isMetal, isMetalBar) — the
    -- window/door object is the `item`, materials come from the equipped hands.
    local hammer, plank
    local nailCount = 0
    pcall(function()
        hammer    = inv:getFirstTypeRecurse("Hammer")
        plank     = inv:getFirstTypeRecurse("Plank")
        nailCount = inv:getItemCount("Base.Nails", true)
    end)
    if not hammer or not plank or nailCount < 2 then
        print("[Barricade] Missing materials (need hammer + plank + 2 nails).")
        return 0
    end

    local equipsQueued = false

    AutoPilot_Utils.iterateNearbySquares(px, py, pz,
        AutoPilot_Constants.BARRICADE_SEARCH_RADIUS,
        function(sq)
            if not AutoPilot_Home.isInside(sq) then return false end
            for oi = 0, sq:getObjects():size() - 1 do
                local obj = sq:getObjects():get(oi)
                pcall(function()
                    local name = obj:getName()
                    if not name then return end
                    if not name:lower():find("window") then return end
                    if isBarricaded(obj) then return end
                    -- Equip hammer (primary) + plank (secondary) once per scan.
                    if not equipsQueued then
                        ISTimedActionQueue.add(
                            ISEquipWeaponAction:new(player, hammer, 50, true))
                        ISTimedActionQueue.add(
                            ISEquipWeaponAction:new(player, plank, 50, false))
                        equipsQueued = true
                    end
                    -- Walk adjacent to the window without clearing queued equips.
                    luautils.walkAdjWindowOrDoor(player, sq, obj, true)
                    ISTimedActionQueue.add(
                        ISBarricadeAction:new(player, obj, false, false))
                    count = count + 1
                end)
            end
        end)

    -- V4.1 (C2): read-only Woodwork XP visibility.  When a maintenance pass
    -- queues real ISBarricadeAction work, sample the Woodwork perk so the XP
    -- metrics window / F11 panel can show the XP the game itself grants for
    -- the barricading.  Observational only: no XP is granted here (the
    -- standing no-addXp rule), and no extra actions are queued.
    if count > 0 and AutoPilot_XP and AutoPilot_XP.sample then
        pcall(function() AutoPilot_XP.sample(player, Perks.Woodwork) end)
    end

    return count
end

--- Periodic maintenance: re-barricade any open windows inside home bounds.
--- Called every eval cycle from AutoPilot_Needs; only scans when countdown
--- reaches zero.  Returns true if any barricade actions were queued.
function AutoPilot_Barricade.checkMaintenance(player)
    if AutoPilot_Barricade._recheckCountdown > 0 then
        AutoPilot_Barricade._recheckCountdown = AutoPilot_Barricade._recheckCountdown - 1
        return false
    end
    AutoPilot_Barricade._recheckCountdown = AutoPilot_Constants.BARRICADE_RECHECK_CYCLES

    local count = _doScan(player)
    if count > 0 then
        print(string.format("[Barricade] Maintenance queued %d barricade action(s).", count))
        return true
    end
    print("[Barricade] Maintenance scan done -- all windows barricaded or no tools.")
    return false
end

--- (Legacy / LLM command) Force an immediate barricade pass and reset countdown.
function AutoPilot_Barricade.doBarricade(player)
    local count = _doScan(player)
    AutoPilot_Barricade._recheckCountdown = AutoPilot_Constants.BARRICADE_RECHECK_CYCLES
    pcall(function()
        player:getModData()[MODDATA_KEY] = true
        player:transmitModData()
    end)
    print(string.format("[Barricade] doBarricade: queued %d action(s).", count))
    return count
end
