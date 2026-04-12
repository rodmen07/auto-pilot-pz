-- AutoPilot_Main.lua

AutoPilot = {}

local function _apNoop(...) end
local print = _apNoop

local TICK_INTERVAL          = AutoPilot_Constants.TICK_INTERVAL
local ACTION_COOLDOWN_CYCLES = AutoPilot_Constants.ACTION_COOLDOWN_CYCLES
local tickCounter = 0

-- ── Per-player state ───────────────────────────────────────────────────────────
-- Keys are playerNum (0-based integer matching player:getPlayerNum() and the
-- joypad index in PZ splitscreen — joypad 0 = player 0, joypad 1 = player 1, …).
--
-- Default mode is "autopilot" — always on.  The toggle (F10 for the keyboard
-- player, controller double-tap for players 1-3) flips to "off" and back.
local _playerModes     = {}   -- [playerNum] -> "autopilot" | "off"
local _playerCooldowns = {}   -- [playerNum] -> action-cooldown cycles remaining
local _deathLogged     = {}   -- [playerNum] -> bool
local _playerInited    = {}   -- [playerNum] -> bool (home set + barricade queued)

-- Joypad double-tap toggle (controller players).
-- Press the configured button twice within JOYPAD_DOUBLE_TAP_MS to toggle.
-- The joypad index in PZ splitscreen matches the player number directly.
local JOYPAD_TOGGLE_BUTTON = AutoPilot_Constants.JOYPAD_TOGGLE_BUTTON
local JOYPAD_DOUBLE_TAP_MS = AutoPilot_Constants.JOYPAD_DOUBLE_TAP_MS
local _joypadLastPressMs   = {}   -- [joypadIndex] -> timestamp of last press (ms)

-- ── Helpers ────────────────────────────────────────────────────────────────────

local function _getMode(pnum)
    if _playerModes[pnum] == nil then
        _playerModes[pnum] = "autopilot"
    end
    return _playerModes[pnum]
end

-- Resolve a player object by 0-based index.
-- Tries getPlayer(n) first (B42 splitscreen API), falls back to getPlayer() for
-- player 0 on runtimes where the indexed overload is not available.
local function _getPlayerByIndex(pnum)
    local ok, player = pcall(function() return getPlayer(pnum) end)
    if ok and player then return player end
    if pnum == 0 then
        ok, player = pcall(getPlayer)
        if ok and player then return player end
    end
    return nil
end

local function hudAddText(player, text)
    local halo = rawget(_G, "HaloTextHelper")
    if halo and halo.addText then halo.addText(player, text) end
end

local function hudAddGood(player, text)
    local halo = rawget(_G, "HaloTextHelper")
    if halo and halo.addGoodText then halo.addGoodText(player, text) end
end

local function hudAddBad(player, text)
    local halo = rawget(_G, "HaloTextHelper")
    if halo and halo.addBadText then halo.addBadText(player, text) end
end

local function apLog(_) end

local function _sayMode(player, pnum)
    local mode  = _getMode(pnum)
    local label = mode:upper()
    if player then
        if mode == "off" then
            hudAddBad(player, "AutoPilot: OFF")
        else
            hudAddGood(player, "AutoPilot: " .. label)
        end
    end
    apLog("Player " .. pnum .. " Mode: " .. label)
end

local function _updateStatusHUD(player, pnum)
    if not player then return end
    local mode      = _getMode(pnum)
    local hunger    = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    local thirst    = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    local fatigue   = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    local zombies   = #AutoPilot_Threat.getNearbyZombies(player)
    local statusLabel = (mode == "autopilot") and "ON" or "OFF"
    local ctrlHint    = (pnum == 0) and "F10 Toggle" or "Back x2 Toggle"

    local latest = string.format("[AP%d] %s | H:%.0f%% T:%.0f%% F:%.0f%% Z:%d | %s",
        pnum, statusLabel, hunger * 100, thirst * 100, fatigue * 100,
        zombies, ctrlHint)
    hudAddText(player, latest)
end

-- ── Per-player init (first-tick home setup) ────────────────────────────────────
-- Always-on: home is auto-set the moment a player is first seen, with no
-- manual toggle needed.  Barricade attempt is idempotent (ModData-backed).

local function _initPlayer(player, pnum)
    if _playerInited[pnum] then return end
    _playerInited[pnum] = true
    if not AutoPilot_Home.isSet(player) then
        AutoPilot_Home.set(player)
        apLog("Player " .. pnum .. " home auto-set (always-on).")
    end
    pcall(function() AutoPilot_Barricade.doBarricade(player) end)
end

-- ── Per-player evaluation ──────────────────────────────────────────────────────

local function _tickForPlayer(player, pnum)
    _updateStatusHUD(player, pnum)
    if _getMode(pnum) == "off" then return end

    local deadOk, isDead = pcall(function() return player:isDead() end)
    if deadOk and isDead then
        if not _deathLogged[pnum] then
            _deathLogged[pnum] = true
            AutoPilot_Telemetry.onDeath(player)
        end
        return
    end
    _deathLogged[pnum] = false

    local asleepOk, isAsleep = pcall(function() return player:isAsleep() end)
    if asleepOk and isAsleep then
        AutoPilot_Telemetry.logTick(player, "sleep", "asleep")
        return
    end

    if AutoPilot_Threat.check(player) then
        _playerCooldowns[pnum] = ACTION_COOLDOWN_CYCLES
        AutoPilot_Telemetry.logTick(player, "combat", "threat")
        return
    end

    local cooldown = _playerCooldowns[pnum] or 0
    if cooldown > 0 then
        _playerCooldowns[pnum] = cooldown - 1
        AutoPilot_Telemetry.logTick(player, "cooldown", "post_action")
        return
    end

    if ISTimedActionQueue.isPlayerDoingAction(player) then
        local actionQueue   = ISTimedActionQueue.getTimedActionQueue(player)
        local currentAction = actionQueue and actionQueue.queue and actionQueue.queue[1]
        local isExercise    = currentAction and currentAction.Type == "ISFitnessAction"
        if isExercise and AutoPilot_Needs.shouldInterrupt(player) then
            apLog("Interrupting exercise for urgent need.")
            ISTimedActionQueue.clear(player)
        else
            AutoPilot_Telemetry.logTick(player, "busy", "action_running")
            return
        end
    end

    if AutoPilot_Needs.check(player) then
        _playerCooldowns[pnum] = ACTION_COOLDOWN_CYCLES
        AutoPilot_Telemetry.logTick(player)
        return
    end

    AutoPilot_Telemetry.logTick(player, "idle", "no_action")
end

-- ── Main OnTick ────────────────────────────────────────────────────────────────

local function onTick()
    tickCounter = tickCounter + 1
    if tickCounter < TICK_INTERVAL then return end
    tickCounter = 0

    local count = getPlayerCount and getPlayerCount() or 1
    for pnum = 0, count - 1 do
        local player = _getPlayerByIndex(pnum)
        if player then
            pcall(_initPlayer,    player, pnum)
            pcall(_tickForPlayer, player, pnum)
        end
    end
end

-- ── Toggle logic ───────────────────────────────────────────────────────────────

local function _togglePlayer(player, pnum)
    if _getMode(pnum) == "autopilot" then
        _playerModes[pnum] = "off"
    else
        _playerModes[pnum] = "autopilot"
        -- Re-run init if somehow home was never set (e.g. first enable after clear).
        if player and not AutoPilot_Home.isSet(player) then
            AutoPilot_Home.set(player)
            pcall(function() AutoPilot_Barricade.doBarricade(player) end)
        end
    end
    _sayMode(player, pnum)
end

-- ── Keyboard toggle — player 0 (keyboard / mouse player) ──────────────────────

local function onKeyPressed(key)
    if key ~= Keyboard.KEY_F10 then return end
    local player = _getPlayerByIndex(0)
    _togglePlayer(player, 0)
end

-- ── Joypad double-tap toggle — players 1-3 (controller players) ───────────────
-- Press the Back / Select / View button (xinput button 6) twice within
-- JOYPAD_DOUBLE_TAP_MS milliseconds to toggle AutoPilot for that player.
-- The joypad index in PZ splitscreen equals the player number directly.

local function onJoypadButtonPress(joypadIndex, buttonId)
    if buttonId ~= JOYPAD_TOGGLE_BUTTON then return end

    local ok, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms   = ok and nowMs or 0
    local last = _joypadLastPressMs[joypadIndex] or 0

    if (ms - last) <= JOYPAD_DOUBLE_TAP_MS and last > 0 then
        -- Second tap within window — toggle this player.
        local player = _getPlayerByIndex(joypadIndex)
        _togglePlayer(player, joypadIndex)
        _joypadLastPressMs[joypadIndex] = 0
    else
        -- First tap — record timestamp and wait for the second.
        _joypadLastPressMs[joypadIndex] = ms
    end
end

Events.OnTick.Add(onTick)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnJoypadButtonPress.Add(onJoypadButtonPress)
