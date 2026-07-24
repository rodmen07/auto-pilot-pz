-- AutoPilot_Sleep.lua
-- Sleep behaviour and bed-finding, extracted from AutoPilot_Needs.lua
-- (code-health split, 2026-07-20, second slice — see AutoPilot_Consumption.lua
-- for the first). doSleep was a clean extraction candidate for the same
-- reason doEat/doDrink were: its only module-level state (sleepCooldownMs)
-- has zero external readers or writers, and doSleep itself has exactly two
-- call sites in AutoPilot_Needs.lua, both simple black-box invocations
-- (`doSleep(player)`) with no direct inspection of its internal state by the
-- caller — unlike doRest, whose restCooldownMs is read and written directly
-- inside AutoPilot_Needs.check()'s own priority-chain gate. Moved verbatim;
-- behavior is unchanged.

local function _apNoop(...) end
local print = _apNoop

AutoPilot_Sleep = {}

local sleepCooldownMs = 0

local BED_SEARCH_DIST   = AutoPilot_Constants.BED_SEARCH_DIST
local BED_SEARCH_FLOORS = AutoPilot_Constants.BED_SEARCH_FLOORS
local PAIN_SLEEP_THRESHOLD = AutoPilot_Constants.PAIN_SLEEP_THRESHOLD

local function getBedObjectOnSquare(sq)
    for i = 0, sq:getObjects():size() - 1 do
        local obj = sq:getObjects():get(i)
        local ok, isBed = pcall(function()
            return obj:getSprite()
                and obj:getSprite():getProperties()
                    :has(IsoFlagType.bed)
        end)
        if ok and isBed then return obj end
    end
    return nil
end

-- Search for the nearest bed object around `player`.
-- Prefers home bounds when home is set; falls back to a wide multi-floor scan.
-- Returns the IsoObject with the bed flag, or nil if none is found.
local function _findBedNearby(player)
    -- Always do a multi-floor scan around the player — home bounds are z-locked
    -- to ground floor, which misses upstairs beds. Prefer nearest bed regardless.
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local bestObj  = nil
    local bestDist = math.huge

    -- Build z-level candidates: current floor first, then alternating up/down
    local zlevels = {pz}
    for offset = 1, BED_SEARCH_FLOORS - 1 do
        table.insert(zlevels, pz + offset)
        table.insert(zlevels, pz - offset)
    end

    for _, z in ipairs(zlevels) do
        if z >= 0 then
            for dx = -BED_SEARCH_DIST, BED_SEARCH_DIST do
                for dy = -BED_SEARCH_DIST, BED_SEARCH_DIST do
                    local sq = getCell():getGridSquare(px + dx, py + dy, z)
                    if sq then
                        local obj = getBedObjectOnSquare(sq)
                        if obj then
                            local floorPenalty = math.abs(z - pz) * 200
                            local dist = dx * dx + dy * dy + floorPenalty
                            if dist < bestDist then
                                bestDist = dist
                                bestObj  = obj
                            end
                        end
                    end
                end
            end
        end
    end
    return bestObj
end

-- Return the level (0-4) of a moodle, defensively: B42 stores moodles in a Map
-- and a missing entry throws a Java NPE, so pcall and treat any failure as 0.
local function _moodleLevel(player, moodleType)
    if not moodleType then return 0 end
    local ok, lvl = pcall(function()
        return player:getMoodles():getMoodleLevel(moodleType)
    end)
    return (ok and lvl) or 0
end

-- Predict whether the engine will actually let the character sleep right now,
-- mirroring the gate in ISWorldObjectContextMenu.onSleepWalkToComplete (verified
-- against the live 42.19 install): a strong sleeping-tablet effect (>= 2000)
-- bypasses the checks; otherwise sleep is refused while the PAIN moodle is >= 2
-- and fatigue <= 0.85, or while the PANIC moodle is >= 1.  Zombies are NOT checked
-- here: AutoPilot_Main preempts on threat before AutoPilot_Needs.check() runs.
-- Returns (canSleep, blockReason): (true, nil) when sleep will proceed, or
-- (false, "pain_block"|"panic") with the label used for the telemetry fail_reason.
function AutoPilot_Sleep.canSleepNow(player)
    local tablet = 0
    pcall(function() tablet = player:getSleepingTabletEffect() or 0 end)
    if tablet >= 2000 then return true, nil end

    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    if _moodleLevel(player, MoodleType.PAIN) >= 2 and fatigue <= 0.85 then
        return false, "pain_block"
    end
    if _moodleLevel(player, MoodleType.PANIC) >= 1 then
        return false, "panic"
    end
    return true, nil
end

-- Attempt to reduce pain via medical treatment or a carried painkiller.  Returns
-- true if a remedy was queued this tick, false if none was available.  Kept
-- separate from doSleep so AutoPilot_Needs.check() can call it when sleep is
-- pain-blocked and then fall through to lower needs, instead of leaving a sore,
-- tired character idle on a sleep the engine will refuse.
function AutoPilot_Sleep.relievePain(player)
    local okMed, medQueued = pcall(function() return AutoPilot_Medical.check(player, false) end)
    if okMed and medQueued then
        print("[Needs] Queued medical treatment to reduce pain.")
        return true
    end

    -- Try to find painkillers the player is carrying (match type/name
    -- heuristics).  V4.8: searches worn/carried sub-containers too, so
    -- pills in a backpack or fanny pack are no longer invisible.
    local tookPill = false
    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        if not item then return false end
        local okType, typ = pcall(function() return item:getType() end)
        local okName, name = pcall(function() return item:getName() end)
        local lower = ""
        if okType and typ then lower = lower .. typ:lower() end
        if okName and name then lower = lower .. " " .. name:lower() end
        if lower:find("painkill") or lower:find("aspirin") or lower:find("paracetamol") then
            -- V4.9: pills in a bag must reach the main inventory first.
            local _, usable = AutoPilot_Utils.queueItemToMainInventory(
                player, item, container)
            if not usable then
                print("[Needs] Painkiller transfer refused: skipping this item.")
                return false
            end
            local takePill = rawget(_G, "ISTakePillAction")
            local okUse = pcall(function()
                if takePill and takePill.new then
                    AutoPilot_Utils.queueModAction(takePill:new(player, item))
                else
                    AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, item, 1))
                end
            end)
            if okUse then
                local pname = (okName and name) or typ
                print("[Needs] Taking painkiller: " .. tostring(pname))
                tookPill = true
                return true
            end
        end
        return false
    end)
    return tookPill
end

function AutoPilot_Sleep.doSleep(player)
    -- Cooldown guard: prevent re-queuing bed action every tick
    local ok, now = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms = ok and now or 0
    if ms < sleepCooldownMs then return true end

    -- If pain is high, attempt medical relief or painkillers before sleeping.
    -- (AutoPilot_Needs.check() already pre-screens with canSleepNow, but doSleep
    -- keeps this guard for its other callers and as a defence in depth.)
    local painVal = AutoPilot_Utils.safeStat(player, CharacterStat.PAIN)
    if painVal >= PAIN_SLEEP_THRESHOLD then
        print("[Needs] Sleep blocked by pain (" .. tostring(painVal) .. "). Attempting medical/pain relief.")
        if AutoPilot_Sleep.relievePain(player) then return true end
        -- No treatment available; delay sleep attempts to avoid a busy loop.
        sleepCooldownMs = ms + 60000
        print("[Needs] No medical/painkiller available; delaying sleep for 60s.")
        return false
    end

    print("[Needs] Sleeping...")
    ISTimedActionQueue.clear(player)

    local bedObj = _findBedNearby(player)
    if not bedObj then
        -- Already seated in a vehicle? B42 counts it as "averageBed"
        -- (onSleepWalkToComplete with a nil bed checks getVehicle()).
        local inVehicle = false
        pcall(function() inVehicle = player:getVehicle() ~= nil end)
        if inVehicle then
            player:setVariable("ExerciseStarted", false)
            player:setVariable("ExerciseEnded", true)
            ISWorldObjectContextMenu.onSleepWalkToComplete(player:getPlayerNum(), nil)
            print("[Needs] Sleeping in vehicle (no bed found).")
            sleepCooldownMs = ms + 15000
            return true
        end
        -- Forcing sleep via setAsleep is client-only; the server never learns of
        -- the state change, causing fatigue desync in MP.  Retry next cycle.
        if AutoPilot_Home.isSet(player) then
            print(
                "[Needs] No bed found inside home bounds — cannot force sleep (MP-unsafe); will retry.")
        else
            print("[Needs] No bed found — cannot force sleep (MP-unsafe); will retry.")
        end
        return false
    end

    local bedSq = bedObj:getSquare()
    print("[Needs] Found bed — walking to it.")

    -- Build 42 sleeps via ISWorldObjectContextMenu.onSleepWalkToComplete(playerIndex, bed):
    -- it takes the 0-based player index (not the player object), re-resolves the player
    -- with getSpecificPlayer, runs the zombie/pain/panic safety checks, and calls
    -- setAsleep(true) — mirrors the vanilla onConfirmSleep flow.
    player:setVariable("ExerciseStarted", false)
    player:setVariable("ExerciseEnded", true)

    local pnum = player:getPlayerNum()
    if AdjacentFreeTileFinder.isTileOrAdjacent(player:getCurrentSquare(), bedSq) then
        ISWorldObjectContextMenu.onSleepWalkToComplete(pnum, bedObj)
        print("[Needs] Sleeping in adjacent bed.")
    else
        local adjacent = AdjacentFreeTileFinder.Find(bedSq, player)
        if adjacent then
            local walkAction = ISWalkToTimedAction:new(player, adjacent)
            walkAction:setOnComplete(ISWorldObjectContextMenu.onSleepWalkToComplete, pnum, bedObj)
            AutoPilot_Utils.queueModAction(walkAction)
            print("[Needs] Walking to bed, then sleeping.")
        else
            print("[Needs] Bed unreachable — no adjacent free tile found.")
            return false
        end
    end

    sleepCooldownMs = ms + 15000
    return true
end
