-- AutoPilot_Main.lua
-- Orchestrator for the local player.  Splitscreen is not supported (V3.2);
-- in multiplayer each client runs this for its own character only.

AutoPilot = {}

-- Keep a handle on the REAL print before the debug shadow: genuine failures
-- (like the F11 panel erroring) must reach the console, never a noop.
local _realPrint = print

local function _apNoop(...) end
local print = _apNoop

local TICK_INTERVAL          = AutoPilot_Constants.TICK_INTERVAL
local ACTION_COOLDOWN_CYCLES = AutoPilot_Constants.ACTION_COOLDOWN_CYCLES
-- Max consecutive identical-action ticks before the guard clears the queue.
local MAX_ACTION_STREAK      = AutoPilot_Constants.MAX_ACTION_STREAK

-- ── Local-player state ─────────────────────────────────────────────────────────
-- Default mode is "off" (V3.2): the mod is a deliberate tool, not an
-- always-on autopilot.  The intended flow is: reach a stable state first
-- (vicinity cleared, supplies stocked), THEN press F10 to start grinding —
-- the survival layer is a fail-safe while training, not a comprehensive
-- caretaker.
local _mode            = "off"
local _cooldown        = 0
local _deathLogged     = false
local _inited          = false
-- Queue-thrash guard: track last decision label and consecutive-count.
local _lastActionLabel = nil
local _actionStreak    = 0

-- ── Helpers ────────────────────────────────────────────────────────────────────

-- Resolve the local player.  getSpecificPlayer(0) is the canonical accessor;
-- getPlayer() is the fallback on runtimes where it is unavailable.
local function _getLocalPlayer()
    local ok, player = pcall(function() return getSpecificPlayer(0) end)
    if ok and player then return player end
    ok, player = pcall(getPlayer)
    if ok and player then return player end
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

local function _sayMode(player)
    if player then
        if _mode == "off" then
            hudAddBad(player, "AutoPilot: OFF")
        else
            hudAddGood(player, "AutoPilot: " .. _mode:upper())
        end
    end
    apLog("Mode: " .. _mode)
end

local function _updateStatusHUD(player)
    if not player then return end
    local hunger  = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    local thirst  = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    local zombies = #AutoPilot_Threat.getNearbyZombies(player)
    local statusLabel = (_mode == "autopilot") and "ON" or "OFF"

    local latest = string.format(
        "[AP] %s | H:%.0f%% T:%.0f%% F:%.0f%% Z:%d | F10 Toggle, F11 Panel",
        statusLabel, hunger * 100, thirst * 100, fatigue * 100, zombies)
    hudAddText(player, latest)
end

-- ── First-active-tick init (home setup) ────────────────────────────────────────
-- Runs on the first evaluation cycle AFTER the player arms the mod (F10):
-- anchors home at the current position and queues an initial barricade pass.
-- Barricade attempt is idempotent (ModData-backed).

local function _initPlayer(player)
    if _inited then return end
    _inited = true
    if not AutoPilot_Home.isSet(player) then
        AutoPilot_Home.set(player)
        apLog("Home auto-set (always-on).")
    end
    pcall(function() AutoPilot_Barricade.doBarricade(player) end)
end

-- ── Per-cycle evaluation ───────────────────────────────────────────────────────

local function _tickForPlayer(player)
    -- Clear + arm the per-cycle zombie-scan cache so HUD, threat check, and
    -- telemetry all share a single scan this cycle.
    if AutoPilot_Threat.beginCycle then AutoPilot_Threat.beginCycle(player) end
    _updateStatusHUD(player)
    if _mode == "off" then return end

    -- Home anchor + initial barricade pass on the first ACTIVE cycle.
    _initPlayer(player)

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

    if AutoPilot_Threat.check(player) then
        _cooldown = ACTION_COOLDOWN_CYCLES
        -- Threat clears streak (context changed)
        _lastActionLabel = "combat"
        _actionStreak    = 1
        AutoPilot_Telemetry.logTick(player, "combat", "threat")
        return
    end

    if _cooldown > 0 then
        _cooldown = _cooldown - 1
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
            -- Queue-thrash guard: track consecutive "busy" ticks; clear if stuck.
            local busyStreak = _actionStreak
            if (_lastActionLabel or "") == "busy" then
                busyStreak = busyStreak + 1
            else
                busyStreak = 1
            end
            _lastActionLabel = "busy"
            _actionStreak    = busyStreak
            if busyStreak > MAX_ACTION_STREAK then
                apLog("Queue-thrash detected (busy streak " .. busyStreak
                    .. ") — clearing action queue.")
                ISTimedActionQueue.clear(player)
                _actionStreak = 0
            else
                AutoPilot_Telemetry.logTick(player, "busy", "action_running")
                return
            end
        end
    end

    if AutoPilot_Needs.check(player) then
        _cooldown = ACTION_COOLDOWN_CYCLES
        -- Record the decision label for streak tracking
        local label = AutoPilot_Telemetry.getPendingAction and
            AutoPilot_Telemetry.getPendingAction(player) or "action"
        if label == (_lastActionLabel or "") then
            _actionStreak = _actionStreak + 1
        else
            _lastActionLabel = label
            _actionStreak    = 1
        end
        AutoPilot_Telemetry.logTick(player)
        return
    end

    -- Compare against the PREVIOUS label before overwriting it, so the streak
    -- resets to 1 whenever we transition into idle from something else.
    local wasIdle = (_lastActionLabel == "idle")
    _lastActionLabel = "idle"
    _actionStreak    = wasIdle and (_actionStreak + 1) or 1
    AutoPilot_Telemetry.logTick(player, "idle", "no_action")
end

-- ── Main OnTick ────────────────────────────────────────────────────────────────
-- MP-reload hardening: joining a server makes PZ re-execute all mod Lua, and a
-- previously registered OnTick closure can survive with DEAD upvalues (this
-- exact failure spammed "__add not defined" every tick on a live 42.19 server).
-- Therefore the tick state lives on the shared GLOBAL table — global lookups
-- resolve at call time, so every registered copy of this handler shares one
-- live state — and duplicate registrations dedupe via the frame timestamp.

AutoPilot = AutoPilot or {}
AutoPilot.tickCounter = 0

--- True while the mod is armed (F10).  Used by the F11 panel and tests.
function AutoPilot.isActive()
    return _mode == "autopilot"
end

local function onTick()
    local st = AutoPilot
    if type(st) ~= "table" then return end

    -- Dedupe: if a stale duplicate handler already ran this frame, skip.
    local okMs, nowMs = pcall(getTimestampMs)
    if okMs and nowMs then
        if st.lastTickMs == nowMs then return end
        st.lastTickMs = nowMs
    end

    st.tickCounter = (tonumber(st.tickCounter) or 0) + 1
    if st.tickCounter < (tonumber(TICK_INTERVAL) or 15) then return end
    st.tickCounter = 0

    -- Stale-closure guard: dead upvalues mean this copy must retire quietly.
    if not (_getLocalPlayer and _initPlayer and _tickForPlayer) then return end

    -- Death-learning: apply bounded threshold adjustments once per session.
    if AutoPilot_Adaptive and AutoPilot_Adaptive.init then
        pcall(AutoPilot_Adaptive.init)
    end

    local player = _getLocalPlayer()
    if player then
        pcall(_tickForPlayer, player)
    end
end

-- ── Toggle logic ───────────────────────────────────────────────────────────────

local function _togglePlayer(player)
    if _mode == "autopilot" then
        _mode = "off"
    else
        _mode = "autopilot"
        -- Re-run init if somehow home was never set (e.g. first enable after clear).
        if player and not AutoPilot_Home.isSet(player) then
            AutoPilot_Home.set(player)
            pcall(function() AutoPilot_Barricade.doBarricade(player) end)
        end
    end
    _sayMode(player)
end

-- ── Keyboard controls ──────────────────────────────────────────────────────────

local function onKeyPressed(key)
    -- Stale-closure guard (see onTick): retire quietly after a Lua reload.
    if not (_getLocalPlayer and _togglePlayer) then return end
    if key == Keyboard.KEY_F11 then
        -- Leveler panel: focus selection + XP metrics.  NEVER fail silently:
        -- a swallowed error here made F11 look dead on a live server.
        if AutoPilot_UI and AutoPilot_UI.toggle then
            local okUI, err = pcall(AutoPilot_UI.toggle)
            if not okUI then
                _realPrint("[AutoPilot] F11 panel error: " .. tostring(err))
                hudAddBad(_getLocalPlayer(), "AutoPilot: panel error (see console)")
            end
        else
            _realPrint("[AutoPilot] F11 pressed but AutoPilot_UI is not loaded."
                .. " A mod file failed during Lua load — files after the failure"
                .. " never load; check the console for the FIRST error.")
            hudAddBad(_getLocalPlayer(), "AutoPilot: UI not loaded (see console)")
        end
        return
    end
    if key ~= Keyboard.KEY_F10 then return end
    _togglePlayer(_getLocalPlayer())
end

Events.OnTick.Add(onTick)
Events.OnKeyPressed.Add(onKeyPressed)

-- ── Session-end telemetry ───────────────────────────────────────────────────
-- Write a "timeout" end marker whenever the player returns to the main menu
-- or starts a new game while autopilot is still active.  This lets benchmark
-- analysis distinguish a clean session end from an in-game death.
local function onSessionEnd()
    if _mode == "autopilot" then
        pcall(AutoPilot_Telemetry.onShutdown, _getLocalPlayer())
    end
end

-- These events do not exist in every Lua environment: OnQueueNewGame is
-- ABSENT during the 42.19 MP server-connect Lua reload, and indexing it here
-- crashed this file's load — which also prevented every alphabetically-later
-- module (Needs, Threat, Telemetry, UI...) from loading at all.  Guard both.
if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(onSessionEnd) end
if Events.OnQueueNewGame  then Events.OnQueueNewGame.Add(onSessionEnd)  end
