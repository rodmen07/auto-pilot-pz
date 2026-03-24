-- AutoPilot_Main.lua
-- Entry point. Registers the OnTick event and orchestrates all sub-modules.
--
-- luacheck: globals HaloTextHelper isKeyDown
-- Updated for local autonomous survivor mode with prompt override.
-- Ctrl+1: autopilot on/off
-- Ctrl+2: prompt override (modal)
-- Ctrl+3-7: prompt option selection
--
-- Sidecar/LLM logic removed; all behavior is local.

AutoPilot = {}

local TICK_INTERVAL = 15
local tickCounter = 0

-- Modes: "off", "autopilot", "prompt"
local mode = "off"
local actionCooldown = 0
local ACTION_COOLDOWN_CYCLES = 4

-- Prompt override state
local decisionPending = false
local decisionPrompt = ""
local decisionOptions = {}
local decisionCallback = nil
local decisionStartTime = 0
local PROMPT_TIMEOUT = 30 -- seconds

-- Current priority override active after prompt
local currentPriority = nil

-- Debug/log state
local debugEnabled = false

local function apLog(msg)
    if debugEnabled then
        print("[AutoPilot] " .. tostring(msg))
    end
end

local function sayMode(player)
    local label = mode:upper()
    if player then
        if mode == "off" then
            HaloTextHelper.addBadText(player, "AutoPilot: OFF")
        else
            HaloTextHelper.addGoodText(player, "AutoPilot: " .. label)
        end
    end
    apLog("Mode: " .. label)
end

local function clearPrompt()
    decisionPending = false
    decisionPrompt = ""
    decisionOptions = {}
    decisionCallback = nil
    decisionStartTime = 0
end

local function updatePromptDisplay(player)
    if not decisionPending then return end
    local text = "[Prompt] " .. decisionPrompt .. "\n"
    for i, opt in ipairs(decisionOptions) do
        local keynum = 2 + i
        text = text .. string.format("Ctrl+%d: %s  ", keynum, opt)
    end
    if player then
        HaloTextHelper.addText(player, text)
    end
end

local function promptTimeoutCheck(player)
    if not decisionPending then return false end
    local now = getGameTime():getCalender():getTimeInMillis() / 1000
    if now - decisionStartTime >= PROMPT_TIMEOUT then
        apLog("Prompt timed out; reverting to autopilot")
        clearPrompt()
        mode = "autopilot"
        return true
    end
    return false
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

local function _clearCurrentPriorityIfSatisfied(player)
    if not currentPriority then return end

    local satisfied = false
    local zombiesNearby = #AutoPilot_Threat.getNearbyZombies(player)

    if currentPriority == "survival" then
        local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
        local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
        local hasCritical = AutoPilot_Medical.hasCriticalWound(player)
        satisfied = thirst < 0.2 and hunger < 0.2 and not hasCritical
        if zombiesNearby > 0 then satisfied = false end
    elseif currentPriority == "safety" then
        satisfied = zombiesNearby == 0
    elseif currentPriority == "comfort" then
        local tired = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
        satisfied = tired < 0.7
    elseif currentPriority == "training" then
        local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
        satisfied = endurance < 0.5 or AutoPilot_Needs.getExerciseSetsToday() >= AutoPilot_Constants.EXERCISE_DAILY_CAP
    elseif currentPriority == "status" then
        satisfied = true
    end

    if satisfied then
        apLog("Priority " .. tostring(currentPriority) .. " satisfied; resuming autopilot")
        currentPriority = nil
    end
end

local function _runPriorityAction(player)
    if not currentPriority then return false end

    if currentPriority == "survival" then
        if _runNeedsCheck(player) then return true end
    elseif currentPriority == "safety" then
        if _runThreatCheck(player) then return true end
        currentPriority = nil
        return false
    elseif currentPriority == "comfort" then
        if _runNeedsCheck(player) then return true end
        if AutoPilot_Needs.tryGoOutside(player) then return true end
        if AutoPilot_Needs.trySleep(player) then return true end
        currentPriority = nil
        return false
    elseif currentPriority == "training" then
        if AutoPilot_Needs.check(player) then return true end
        currentPriority = nil
        return false
    elseif currentPriority == "status" then
        currentPriority = nil
        return false
    end

    return false
end

local function isCtrlDown()
    local ok, val = pcall(function()
        return isKeyDown and (isKeyDown(Keyboard.KEY_LCONTROL) or isKeyDown(Keyboard.KEY_RCONTROL))
    end)
    return ok and val
end

local function onTick()
    if mode == "off" then return end

    if getPlayerCount and getPlayerCount() > 1 then return end

    tickCounter = tickCounter + 1
    if tickCounter < TICK_INTERVAL then return end
    tickCounter = 0

    local player = getPlayer()
    if not player or player:isDead() then return end

    local asleepOk, isAsleep = pcall(function() return player:isAsleep() end)
    if asleepOk and isAsleep then return end

    if _runThreatCheck(player) then return end

    if decisionPending then
        updatePromptDisplay(player)
        if promptTimeoutCheck(player) then return end
        return
    end

    if currentPriority then
        _clearCurrentPriorityIfSatisfied(player)
        if currentPriority and _runPriorityAction(player) then return end
        if not currentPriority then
            apLog("Priority cleared; continuing normal autopilot")
        end
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
    local player = getPlayer()

    if not isCtrlDown() then
        return
    end

    if key == Keyboard.KEY_1 then
        if mode == "autopilot" then
            mode = "off"
            clearPrompt()
            currentPriority = nil
        else
            mode = "autopilot"
            if player and not AutoPilot_Home.isSet(player) then
                AutoPilot_Home.set(player)
                apLog("AutoPilot enabled — home set to current position.")
            end
        end
        sayMode(player)

    elseif key == Keyboard.KEY_2 then
        if mode == "autopilot" and not decisionPending then
            decisionPending = true
            mode = "prompt"
            decisionPrompt = "Choose priority"
            decisionOptions = {"survival", "safety", "comfort", "training", "status"}
            decisionCallback = function(option)
                currentPriority = option
                apLog("Selected prompt priority: " .. option)
            end
            decisionStartTime = getGameTime():getCalender():getTimeInMillis() / 1000
            sayMode(player)
        end

    elseif key >= Keyboard.KEY_3 and key <= Keyboard.KEY_7 then
        if mode == "prompt" and decisionPending then
            local idx = key - Keyboard.KEY_3 + 1
            local option = decisionOptions[idx]
            if option and decisionCallback then
                decisionCallback(option)
            end
            clearPrompt()
            mode = "autopilot"
            sayMode(player)
        end
    end

    if key == Keyboard.KEY_H then
        if mode ~= "off" and player then
            AutoPilot_Home.set(player)
        end
    end
end

Events.OnTick.Add(onTick)
Events.OnKeyPressed.Add(onKeyPressed)

print("[AutoPilot] AutoPilot loaded. Ctrl+1=Autopilot, Ctrl+2=Prompt, Ctrl+3-7=Prompt options, H=Set Home.")
