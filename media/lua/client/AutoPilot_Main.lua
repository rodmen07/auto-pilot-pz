-- AutoPilot_Main.lua

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
-- Debug/log state
local debugEnabled = true
-- Visual/audible feedback for keypresses
local KEYPRESS_VISUAL_DEBUG = true
local KEYPRESS_SOUND_DEBUG = true
local helpVisible = false
local helpStartTime = 0
local HELP_TIMEOUT = 20 -- seconds

local telemetryEnabled = true
local telemetryCounter = 0
local telemetryFilename = "auto_pilot_run.log"
local telemetryFlag = "auto_pilot_run_end.json"
-- Timestamp of the last Alt key press (ms) — used as a short fallback when
-- modifier state isn't visible during the F10 event due to event ordering.
local lastAltPressMs = 0

local function nowMs()
    local ok, now = pcall(function() return getGameTime():getCalender():getTimeInMillis() end)
    return ok and now or 0
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

local function updateHelpDisplay(player)
    if not helpVisible then return end
    local text = "[AutoPilot Help] Alt+F10=Toggle AutoPilot, Ctrl+0=Help, Ctrl+2=Prompt, Ctrl+3-7=Priority. F10=Home.\n"
    text = text .. "Survival: thirst/hunger/wounds/sleep/rest/brain. Safety: evade when threatened.\n"
    text = text .. "Ctrl+0 again to close.\n"
    if player then
        HaloTextHelper.addText(player, text)
    end
    local now = getGameTime():getCalender():getTimeInMillis()/1000
    if now - helpStartTime >= HELP_TIMEOUT then
        helpVisible = false
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

local function updateStatusHUD(player)
    if not player or mode == "off" then return end

    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    local zombies = #AutoPilot_Threat.getNearbyZombies(player)
    local priority = currentPriority or "auto"

    local latest = string.format("[AP] %s | P:%s | H:%.0f%% T:%.0f%% F:%.0f%% Z:%d",
        mode:upper(), priority, hunger * 100, thirst * 100, fatigue * 100, zombies)

    if decisionPending and decisionPrompt ~= "" then
        latest = latest .. " | PROMPT: " .. decisionPrompt
    end

    latest = latest .. " | Help: Ctrl+0"
    HaloTextHelper.addText(player, latest)
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

local function isAltDown()
    local ok, val = pcall(function()
        return isKeyDown and (isKeyDown(Keyboard.KEY_LMENU) or isKeyDown(Keyboard.KEY_RMENU))
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
    if not player then return end

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
            run_tick = tickCounter,
            mode = mode,
            hunger = hunger,
            thirst = thirst,
            fatigue = fatigue,
            zombies = zombies
        })
    end

    updateStatusHUD(player)

    if _runThreatCheck(player) then return end

    if helpVisible then
        updateHelpDisplay(player)
        return
    end

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
    pcall(function()
        print("[AutoPilot] onKeyPressed key=" .. tostring(key))
        if KEYPRESS_VISUAL_DEBUG then
            local pl = getPlayer()
            if pl then HaloTextHelper.addText(pl, "[AutoPilot] Key=" .. tostring(key)) end
        end
        if KEYPRESS_SOUND_DEBUG then
            local ok, sm = pcall(function() return getSoundManager() end)
            if ok and sm and sm.playSound then pcall(function() sm:playSound("UIConfirm") end) end
        end
    end)
    local player = getPlayer()
    local now = nowMs()

    -- Record Alt key presses for a short-window fallback in case the modifier
    -- state isn't visible when the F10 event arrives (race between key events).
    if key == Keyboard.KEY_LMENU or key == Keyboard.KEY_RMENU
        or key == Keyboard.KEY_LALT or key == Keyboard.KEY_RALT then
        lastAltPressMs = now
    end

    -- Alt+F10: toggle autopilot (user-requested special binding)
    local altRecently = (now - (lastAltPressMs or 0)) <= 500
    if key == Keyboard.KEY_F10 and (isAltDown() or altRecently) then
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
        return
    end

    if not isCtrlDown() then
        return
    end

    -- NOTE: Ctrl+1 autopilot mapping removed to avoid duplicate mappings.
    -- Use Alt+F10 exclusively for toggling autopilot. Ctrl+2/3-7 remain.
    if key == Keyboard.KEY_2 then
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

    if key == Keyboard.KEY_0 and isCtrlDown() then
        helpVisible = not helpVisible
        helpStartTime = getGameTime():getCalender():getTimeInMillis()/1000
        return
    end

    if key == Keyboard.KEY_F10 then
        if mode ~= "off" and player then
            AutoPilot_Home.set(player)
            showHomeConfirmation(player, "Home updated")
        end
        return
    end
end

Events.OnTick.Add(onTick)
Events.OnKeyPressed.Add(onKeyPressed)

print("[AutoPilot] AutoPilot loaded. Alt+F10=Toggle AutoPilot, Ctrl+2=Prompt, Ctrl+3-7=Prompt options, F10=Set Home.")
