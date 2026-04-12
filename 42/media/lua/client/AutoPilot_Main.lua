-- AutoPilot_Main.lua

AutoPilot = {}

local function _apNoop(...) end
local print = _apNoop

local TICK_INTERVAL = 15
local tickCounter = 0

-- Modes: "off", "autopilot"
local mode = "off"
local actionCooldown = 0
local ACTION_COOLDOWN_CYCLES = 4

-- Prevent writing the death telemetry marker more than once per death event.
local _deathLogged = false

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

local function apLog(_) end

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
        if not _deathLogged then
            _deathLogged = true
            AutoPilot_Telemetry.onDeath(player)
        end
        return
    end
    _deathLogged = false

    local asleepOk, isAsleep = pcall(function() return player:isAsleep() end)
    if asleepOk and isAsleep then
        AutoPilot_Telemetry.logTick(player, "sleep", "asleep")
        return
    end

    if _runThreatCheck(player) then
        AutoPilot_Telemetry.logTick(player, "combat", "threat")
        return
    end

    if actionCooldown > 0 then
        actionCooldown = actionCooldown - 1
        AutoPilot_Telemetry.logTick(player, "cooldown", "post_action")
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
            AutoPilot_Telemetry.logTick(player, "busy", "action_running")
            return
        end
    end

    if _runNeedsCheck(player) then
        AutoPilot_Telemetry.logTick(player)
        return
    end

    AutoPilot_Telemetry.logTick(player, "idle", "no_action")
end

local function onKeyPressed(key)
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
