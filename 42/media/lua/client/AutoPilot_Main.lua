-- AutoPilot_Main.lua
-- Orchestrator for the local player.  Splitscreen is not supported (V3.2);
-- in multiplayer each client runs this for its own character only.

AutoPilot = {}

-- Keep a handle on the REAL print before the debug shadow: genuine failures
-- (like the F11 panel erroring) must reach the console, never a noop.
local _realPrint = print

local function _apNoop(...) end
-- luacheck: ignore print
-- The shadow is deliberate and uniform across the 19 modules that carry it: it
-- makes any print() added to this file a noop by default, so debug output can
-- never reach a player's console by accident.  This file calls print() nowhere
-- today, which is exactly why luacheck 211 flags it -- the shadow is a standing
-- guarantee about FUTURE lines here, not dead code.  Suppressed at the one line
-- it applies to rather than repo-wide, so 211 keeps judging every other local.
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

-- V4.4: read-only action/intention line.  Deliberately NOT called from
-- inside _updateStatusHUD above: that call happens at the very TOP of
-- _tickForPlayer, before this cycle's decision logic has updated
-- _lastActionLabel, which would make the line always one cycle stale.
-- Calling this instead AFTER _tickForPlayer returns (see onTick below)
-- reads _lastActionLabel post-update, so the line reflects THIS cycle's
-- decision.  Same halo mechanism and font as the status line; toggleable
-- via Options ("Show current action on HUD"), default ON.
local function _updateActionHUD(player)
    if not player then return end
    local showAction = AutoPilot_Constants.HUD_SHOW_ACTION
    if showAction == nil or showAction ~= 0 then
        -- V6.0-3 (C2): render through the composed reason line, the same
        -- single source the F11 panel draws, so "Action: Eating (hungry)"
        -- and the panel's "Status: Eating (hungry)" can never disagree.
        hudAddText(player, "Action: " .. AutoPilot.getActionLine(player))
    end
end

-- ── First-active-tick init (home setup) ────────────────────────────────────────
-- Runs on the first evaluation cycle AFTER the player arms the mod (F10):
-- anchors home at the current position.  (Through V4.9 this also queued an
-- initial barricade pass; barricading left the mod's scope in V5.0.)

local function _initPlayer(player)
    if _inited then return end
    _inited = true
    if not AutoPilot_Home.isSet(player) then
        AutoPilot_Home.set(player)
        apLog("Home auto-set (always-on).")
    end
end

-- ── Per-cycle evaluation ───────────────────────────────────────────────────────

local function _tickForPlayer(player)
    -- Clear + arm the per-cycle zombie-scan cache so HUD, threat check, and
    -- telemetry all share a single scan this cycle.
    if AutoPilot_Threat.beginCycle then AutoPilot_Threat.beginCycle(player) end
    _updateStatusHUD(player)
    if _mode == "off" then return end

    -- Home anchor on the first ACTIVE cycle.
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
        -- V4.5: the threat response may clear the mod's own queued exercise;
        -- consume the pending record so that clear is never misread as a
        -- player cancel (training may resume right after combat).
        if AutoPilot_Needs.noteModExerciseCleared then
            pcall(AutoPilot_Needs.noteModExerciseCleared)
        end
        -- V5.6: log WHICH engage branch ran.  Every combat tick used to log
        -- the single reason "threat", so a run log could not tell a fight
        -- from a flee from a decision that queued nothing at all — which is
        -- why the reported spin (1889 combat ticks, frozen stats) was
        -- invisible in telemetry.  The action label stays "combat" (the
        -- REASON_CLASS / benchmark._ACTION_CLASS_MAP sync guard is over
        -- ACTION keys); only the free-form reason field gains detail.
        local threatReason = "threat"
        if AutoPilot_Threat.getEngageReason then
            local okReason, engageReason = pcall(AutoPilot_Threat.getEngageReason)
            if okReason and type(engageReason) == "string" and engageReason ~= "" then
                threatReason = engageReason
            end
        end
        AutoPilot_Telemetry.logTick(player, "combat", threatReason)
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
        -- V4.5: identity check.  Only actions the mod itself queued (tagged
        -- at queue time in AutoPilot_Utils) may ever be interrupted or
        -- thrash-cleared.  Missing tracker degrades to FOREIGN, i.e. to
        -- never touching the queue, which is the safe direction.
        local isModAction = false
        if AutoPilot_Utils and AutoPilot_Utils.isModAction then
            isModAction = AutoPilot_Utils.isModAction(currentAction)
        end
        if not isModAction then
            -- FOREIGN action (player-initiated, another mod, or a vanilla
            -- internal queue): never cleared, never interrupted, never
            -- counted toward the thrash guard.  A foreign EXERCISE also
            -- notifies the trainer so armed training backs off instead of
            -- re-queuing the moment the player cancels it.
            if isExercise and AutoPilot_Needs.noteForeignExercise then
                pcall(AutoPilot_Needs.noteForeignExercise, player)
            end
            _lastActionLabel = "foreign"
            _actionStreak    = 0
            AutoPilot_Telemetry.logTick(player, "busy", "foreign_action")
            return
        end
        if isExercise and AutoPilot_Needs.shouldInterrupt(player) then
            apLog("Interrupting exercise for urgent need.")
            -- Mod-initiated clear of the mod's own set: consume the pending
            -- record so it is not misread as a player cancel (no backoff).
            if AutoPilot_Needs.noteModExerciseCleared then
                pcall(AutoPilot_Needs.noteModExerciseCleared)
            end
            ISTimedActionQueue.clear(player)
        else
            -- Queue-thrash guard: track consecutive "busy" ticks; clear if
            -- stuck.  Reachable only for MOD-QUEUED actions (see above).
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
                if AutoPilot_Needs.noteModExerciseCleared then
                    pcall(AutoPilot_Needs.noteModExerciseCleared)
                end
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

-- ── V4.4: on-screen action/intention display ────────────────────────────────
-- Read-only presentation of what the mod is currently doing (or why it is
-- doing nothing), so the player can tell at a glance without opening the
-- F11 panel.  Sourced entirely from state already tracked for OTHER
-- purposes: _lastActionLabel (computed every cycle above for the
-- queue-thrash guard) and, for exercise, AutoPilot_Needs.getExerciseStatus
-- (the same read the F11 panel already performs, itself backed by the V4.5
-- ownership registry's pending-set bookkeeping).  This adds no new
-- decision state and mutates nothing: per the V4.5 player-agency guarantee,
-- presentation must never gate or influence a decision.
local ACTION_LABELS = {
    idle      = "Idle, evaluating",
    busy      = "Busy (action in progress)",
    foreign   = "Busy (player action in progress)",
    cooldown  = "Cooldown",
    combat    = "Fighting/fleeing zombies",
    sleep     = "Sleeping",
    eat       = "Eating",
    drink     = "Drinking",
    rest      = "Resting",
    bandage   = "Treating wound",
    shelter   = "Taking shelter",
    clothing  = "Adjusting clothing",
    read      = "Reading",
    outside   = "Getting fresh air",
    scavenge  = "Scavenging supplies",
    exercise  = "Training",
    -- V6.0-3: these two decision labels existed without display labels, so a
    -- drying-off or media cycle rendered "Idle, evaluating" on the HUD — the
    -- exact lie the reason line exists to remove.
    dry       = "Drying off",
    media     = "Enjoying media",
}

local function _capitalize(s)
    if type(s) ~= "string" or s == "" then return s end
    return s:sub(1, 1):upper() .. s:sub(2)
end

--- Read-only current action/intention label for the on-screen HUD (V4.4).
--- Never mutates any state; safe to call any number of times per cycle.
--- Disarmed reads honestly: the survival cycle returns immediately when
--- "off" (see _tickForPlayer above), so nothing is being monitored or
--- queued, and the label says so rather than implying otherwise.
--- @param player IsoPlayer|nil  Used only to read isDead()/isAsleep(); optional.
--- @return string
function AutoPilot.getActionIntention(player)
    if _mode == "off" then
        return "Disarmed (no monitoring)"
    end
    if player then
        local okDead, dead = pcall(function() return player:isDead() end)
        if okDead and dead then return "Dead" end
        local okAsleep, asleep = pcall(function() return player:isAsleep() end)
        if okAsleep and asleep then return "Sleeping" end
    end
    local label = _lastActionLabel
    if label == "exercise" or label == "busy" then
        -- Enrich with the live trainer status (e.g. "training: barbellcurl")
        -- when one is available; falls back to the generic label otherwise.
        local status = nil
        pcall(function() status = AutoPilot_Needs.getExerciseStatus() end)
        if status and type(status.outcome) == "string" and status.outcome ~= "idle" then
            return _capitalize(status.outcome)
        end
    end
    return ACTION_LABELS[label] or "Idle, evaluating"
end

-- ── V6.0-3 (C2): decision-reason visibility ───────────────────────────────────
-- Human phrasing for the reason tokens the telemetry vocabulary defines
-- (docs/triage.md, "Action / reason inventory", plus the fail_reason labels
-- from AutoPilot_Sleep.canSleepNow).  Only tokens that ADD information over
-- the action label are mapped: persistent-state reasons (asleep, no_action,
-- post_action, foreign_action, action_running, player_died), "training"
-- (the exercise label already carries the live trainer status), "threat"
-- and the combat sub-reasons (the combat label already says it), and
-- "wound" (redundant under "Treating wound") deliberately render as the
-- plain action string — as does any token this table does not know, so a
-- NEW reason token can never blank the panel, only lose its parenthetical.
local REASON_LABELS = {
    -- decision reasons (AutoPilot_Needs via setDecision)
    bleeding       = "bleeding",
    fatigue_thresh = "tired",
    low_endurance  = "worn out",
    rest_cooldown  = "catching breath",
    sit_recover    = "recovering",
    thirst_thresh  = "thirsty",
    hunger_thresh  = "hungry",
    -- V6.2 C1: the moodle arm fired where the stat slider alone would not
    -- have — the character LOOKS thirsty/hungry on screen, so the label says
    -- exactly that instead of restating the stat-threshold phrasing.
    thirst_moodle  = "thirsty moodle",
    hunger_moodle  = "hungry moodle",
    unhappy        = "low mood",
    weather        = "bad weather",
    temperature    = "body temperature",
    boredom        = "bored",
    low_supplies   = "supplies low",
    wet            = "soaked",
    no_towel       = "wet, no towel",
    stalled        = "broadcast not helping",
    -- fail reasons: the engine refused the queued action; these answer
    -- "why is it doing nothing" (set via setDecision's fail_reason argument)
    pain_block     = "sleep blocked by pain",
    panic          = "sleep blocked by panic",
    carry_full     = "carrying too much",
}

-- Exposed read-only for the drift-guard test (tests/test_reason_line.lua),
-- which asserts every mapped token above is actually emitted somewhere in
-- the mod, so a renamed or deleted reason cannot leave a dead mapping here.
AutoPilot._REASON_LABELS = REASON_LABELS

--- V6.0-3 (C2): the ONE pure formatter both the F11 panel and the action
--- HUD render through, so the two surfaces cannot drift the way they did
--- before V5.8 unified them on getActionIntention.  String in, string out:
--- no state, no player, unit-testable directly.
--- @param action string      intention label (AutoPilot.getActionIntention)
--- @param reason string|nil  reason token (AutoPilot_Telemetry.getDecisionReason)
--- @return string  "<action> (<human reason>)", or the plain action string
---                 when the reason is empty, unknown, or adds nothing
function AutoPilot.reasonLine(action, reason)
    if type(action) ~= "string" or action == "" then
        action = "Idle, evaluating"
    end
    local label = (type(reason) == "string") and REASON_LABELS[reason] or nil
    if not label then return action end
    return string.format("%s (%s)", action, label)
end

--- V6.0-3 (C2): the composed action line, the single source BOTH render
--- surfaces call — the panel's status row and the HUD's action line are two
--- renderings of this one string, extending the V5.8 rule to the reason.
--- Disarmed never carries a reason: the last logged reason belongs to a
--- cycle that is no longer running, and appending it would be stale.
--- @param player IsoPlayer|nil
--- @return string
function AutoPilot.getActionLine(player)
    local action = AutoPilot.getActionIntention(player)
    if _mode == "off" then return action end
    local reason = ""
    if AutoPilot_Telemetry and AutoPilot_Telemetry.getDecisionReason then
        local ok, r = pcall(AutoPilot_Telemetry.getDecisionReason, player)
        if ok and type(r) == "string" then reason = r end
    end
    return AutoPilot.reasonLine(action, reason)
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

    -- FF-1 (2026-07-24): advance the cadence by the game-speed MULTIPLIER, not a
    -- flat 1, so evaluations stay roughly constant per unit of GAME time at any
    -- speed.  Fast-forward is getGameTime():setMultiplier(5/20/40); OnTick still
    -- fires at ~20/s REAL, so a flat "+1 per frame, decide every 15 frames" made
    -- decisions every ~0.75 s REAL = up to ~30 s of GAME time at 40x, leaving the
    -- character unmonitored across long game windows.  Mirrors the engine idiom
    -- (ISAnimalTracksFinder decrements its counter by getMultiplier() per tick).
    -- mult defaults to 1, so normal (1x) speed is byte-for-byte unchanged.
    local mult = 1
    pcall(function() mult = getGameTime():getMultiplier() end)
    if type(mult) ~= "number" or mult < 1 then mult = 1 end
    st.tickCounter = (tonumber(st.tickCounter) or 0) + mult
    if st.tickCounter < (tonumber(TICK_INTERVAL) or 15) then return end
    st.tickCounter = 0

    -- Stale-closure guard: dead upvalues mean this copy must retire quietly.
    if not (_getLocalPlayer and _initPlayer and _tickForPlayer
        and _updateActionHUD) then return end

    -- Player-configured options first, THEN the death-learning deltas on top,
    -- so both layers of tuning compose in a stable order.
    if AutoPilot_Options and AutoPilot_Options.applyOnce then
        pcall(AutoPilot_Options.applyOnce)
    end
    if AutoPilot_Adaptive and AutoPilot_Adaptive.init then
        pcall(AutoPilot_Adaptive.init)
    end

    local player = _getLocalPlayer()
    if player then
        pcall(_tickForPlayer, player)
        -- V4.4: emitted AFTER _tickForPlayer so _lastActionLabel reflects
        -- THIS cycle's decision, not the previous one (see _updateActionHUD
        -- above for why this cannot live inside _tickForPlayer itself).
        pcall(_updateActionHUD, player)
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
        end
    end
    _sayMode(player)
end

--- Arm/disarm from code (the F11 panel's button).  Same path as F10.
--- Defined here, after _togglePlayer, so the upvalue binds correctly.
function AutoPilot.toggle()
    _togglePlayer(_getLocalPlayer())
end

-- ── Keyboard controls ──────────────────────────────────────────────────────────

local function onKeyPressed(key)
    -- Stale-closure guard (see onTick): retire quietly after a Lua reload.
    if not (_getLocalPlayer and _togglePlayer) then return end
    -- Rebindable via mod options; hard fallbacks F10/F11.
    local armKey, panelKey = Keyboard.KEY_F10, Keyboard.KEY_F11
    if AutoPilot_Options and AutoPilot_Options.getKey then
        armKey   = AutoPilot_Options.getKey("armKey", armKey)
        panelKey = AutoPilot_Options.getKey("panelKey", panelKey)
    end
    if key == panelKey then
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
    if key ~= armKey then return end
    local player = _getLocalPlayer()
    -- V4.5 PANIC STOP: F10 always stops a RUNNING exercise first, mod-queued
    -- or manual, armed or disarmed, IN ADDITION to the normal arm/disarm
    -- toggle below.  This is the guaranteed escape hatch for the reported
    -- "cannot cancel a manually started exercise" lockup (which can also be
    -- vanilla fitness-UI input capture, so the mod must offer a reliable
    -- way out regardless of who queued the set).
    pcall(function()
        if not player then return end
        if not ISTimedActionQueue.isPlayerDoingAction(player) then return end
        local q   = ISTimedActionQueue.getTimedActionQueue(player)
        local cur = q and q.queue and q.queue[1]
        if cur and cur.Type == "ISFitnessAction" then
            -- Player-initiated stop: consume the pending set record and
            -- start the training backoff so a (still or newly) armed
            -- trainer cannot re-queue an exercise right away.
            if AutoPilot_Needs and AutoPilot_Needs.notePanicStop then
                pcall(AutoPilot_Needs.notePanicStop)
            end
            ISTimedActionQueue.clear(player)
            apLog("F10 panic stop: cleared running exercise.")
            hudAddGood(player, "AutoPilot: exercise stopped")
        end
    end)
    _togglePlayer(player)
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
