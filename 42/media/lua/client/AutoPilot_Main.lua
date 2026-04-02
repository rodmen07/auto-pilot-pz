-- AutoPilot_Main.lua

AutoPilot = {}

local TICK_INTERVAL = 15
local tickCounter = 0

-- Modes: "off", "autopilot"
local mode = "off"
local actionCooldown = 0
local ACTION_COOLDOWN_CYCLES = 4

-- Debug/log state
local debugEnabled = true

-- Visual/audible feedback for keypresses
local KEYPRESS_VISUAL_DEBUG = true
local KEYPRESS_SOUND_DEBUG = true

local telemetryEnabled = true
local telemetryFilename = "auto_pilot_run.log"
local telemetryFlag = "auto_pilot_run_end.json"

local function hudAddText(player, text)
    local halo = rawget(_G, "HaloTextHelper")
    if halo and halo.addText then
        halo.addText(player, text)
    end
end

local function hudAddGood(player, text)
    local halo = rawget(_G, "HaloTextHelper")
    if halo and halo.addGoodText then
        halo.addGoodText(player, text)
    end
end

local function hudAddBad(player, text)
    local halo = rawget(_G, "HaloTextHelper")
    if halo and halo.addBadText then
        halo.addBadText(player, text)
    end
end

local function playConfirmSfx()
    local getSm = rawget(_G, "getSoundManager")
    if not getSm then return end
    local ok, sm = pcall(getSm)
    if ok and sm and sm.playSound then
        pcall(function() sm:playSound("UIConfirm") end)
    end
end

local function apLog(msg)
    if debugEnabled then
        print("[AutoPilot] " .. tostring(msg))
    end
end

local function writeTelemetryEntry(entry)
    if not telemetryEnabled then return end
    local ok, fw = pcall(function() return getFileWriter(telemetryFilename, true, false) end)
    if not ok or not fw then return end
    if type(entry) == "table" then
        local parts = {}
        for k, v in pairs(entry) do
            table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
        fw:write(table.concat(parts, ",") .. "\n")
    else
        fw:write(tostring(entry) .. "\n")
    end
    fw:close()
end

local function markRunEnd(reason)
    if not telemetryEnabled then return end
    local fw = getFileWriter(telemetryFlag, false, false)
    if not fw then return end
    local status = {status = "dead", reason = reason, timestamp = os.time()}
    fw:write(
        "{"
        .. "\"status\":\"dead\","
        .. "\"reason\":\"" .. tostring(reason) .. "\","
        .. "\"timestamp\":" .. tostring(status.timestamp)
        .. "}"
    )
    fw:close()
end

local function sayMode(player)
    local label = mode:upper()
    if player then
        if mode == "off" then
            hudAddBad(player, "AutoPilot: OFF")
        else
            hudAddGood(player, "AutoPilot: " .. label)
        end
    end
    apLog("Mode: " .. label)
end

local function updateStatusHUD(player)
    if not player then return end

    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    local zombies = #AutoPilot_Threat.getNearbyZombies(player)
    local statusLabel = (mode == "autopilot") and "ON" or "OFF"

    local latest = string.format("[AP] %s | H:%.0f%% T:%.0f%% F:%.0f%% Z:%d | F10 Toggle",
        statusLabel, hunger * 100, thirst * 100, fatigue * 100, zombies)
    hudAddText(player, latest)
end

local function _runThreatCheck(player)
    if AutoPilot_Threat.check(player) then
        actionCooldown = ACTION_COOLDOWN_CYCLES
        return true
    end
    return false
end

local function _runNeedsCheck(player)
    if AutoPilot_Needs.check(player) then
        actionCooldown = ACTION_COOLDOWN_CYCLES
        return true
    end
    return false
end

local function onTick()
    if getPlayerCount and getPlayerCount() > 1 then return end

    tickCounter = tickCounter + 1
    if tickCounter < TICK_INTERVAL then return end
    tickCounter = 0

    local player = getPlayer()
    if not player then return end

    updateStatusHUD(player)
    if mode == "off" then return end

    local deadOk, isDead = pcall(function() return player:isDead() end)
    if deadOk and isDead then
        markRunEnd("dead")
        return
    end

    local asleepOk, isAsleep = pcall(function() return player:isAsleep() end)
    if asleepOk and isAsleep then return end

    if telemetryEnabled then
        local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
        local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
        local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
        local zombies = #AutoPilot_Threat.getNearbyZombies(player)
        writeTelemetryEntry({
            mode = mode,
            hunger = hunger,
            thirst = thirst,
            fatigue = fatigue,
            zombies = zombies
        })
    end

    if _runThreatCheck(player) then return end

    if actionCooldown > 0 then
        actionCooldown = actionCooldown - 1
        return
    end

    if ISTimedActionQueue.isPlayerDoingAction(player) then
        local actionQueue = ISTimedActionQueue.getTimedActionQueue(player)
        local currentAction = actionQueue and actionQueue.queue and actionQueue.queue[1]
        local isExercise = currentAction and currentAction.Type == "ISFitnessAction"
        if isExercise and AutoPilot_Needs.shouldInterrupt(player) then
            apLog("Interrupting exercise for urgent need.")
            ISTimedActionQueue.clear(player)
        else
            return
        end
    end

    if _runNeedsCheck(player) then return end
end

local function onKeyPressed(key)
    pcall(function()
        print("[AutoPilot] onKeyPressed key=" .. tostring(key))
        if KEYPRESS_VISUAL_DEBUG then
            local pl = getPlayer()
            if pl then hudAddText(pl, "[AutoPilot] Key=" .. tostring(key)) end
        end
        if KEYPRESS_SOUND_DEBUG then
            playConfirmSfx()
        end
    end)

    local player = getPlayer()
    if key ~= Keyboard.KEY_F10 then return end

    if mode == "autopilot" then
        mode = "off"
    else
        mode = "autopilot"
        if player and not AutoPilot_Home.isSet(player) then
            AutoPilot_Home.set(player)
            apLog("AutoPilot enabled - home set to current position.")
        end
    end
    sayMode(player)
end

Events.OnTick.Add(onTick)
Events.OnKeyPressed.Add(onKeyPressed)

print("[AutoPilot] AutoPilot loaded. F10=Toggle AutoPilot.")
