-- AutoPilot_Telemetry.lua
-- Structured per-tick telemetry writer for run logging and offline benchmark analysis.
--
-- Writes one key=value CSV line per evaluation cycle to:
--   ~/Zomboid/Lua/auto_pilot_run.log         (player 0)
--   ~/Zomboid/Lua/auto_pilot_run_p1.log      (player 1, splitscreen)
--   ~/Zomboid/Lua/auto_pilot_run_p2.log      ...
-- and a JSON end-marker to:
--   ~/Zomboid/Lua/auto_pilot_run_end.json    (player 0)
--   ~/Zomboid/Lua/auto_pilot_run_p1_end.json (player 1, etc.)
--
-- File I/O uses getFileWriter() — the only game-safe file API in PZ's sandbox.
-- All operations are wrapped in pcall to prevent crashes on any I/O failure.

AutoPilot_Telemetry = {}

-- Telemetry schema version — increment when new fields are added.
-- Old parsers that don't know this field simply ignore it (additive-only).
-- v3 (V4.1): appends wood/doc (Woodwork and Doctor perk levels) after fit,
-- the read-only action-perk visibility from expansion candidates C2/C6.
local SCHEMA_VERSION = 3

-- ── Per-player state ───────────────────────────────────────────────────────────
-- Keys are playerNum (0-based integer from player:getPlayerNum()).

local _runTick        = {}   -- [playerNum] -> monotonically increasing counter
local _pendingAction  = {}   -- [playerNum] -> action label set by setDecision()
local _pendingReason  = {}   -- [playerNum] -> reason label set by setDecision()
local _pendingStage   = {}   -- [playerNum] -> priority tier label
local _pendingFail    = {}   -- [playerNum] -> fail_reason label
local _pendingRetry   = {}   -- [playerNum] -> retry_count at decision time

-- ── Helpers ────────────────────────────────────────────────────────────────────

local function _pn(player)
    local ok, n = pcall(function() return player:getPlayerNum() end)
    return (ok and type(n) == "number") and n or 0
end

local function _logFile(pnum)
    -- Player 0 keeps the legacy filename for backward compatibility with existing
    -- log analysis scripts (e.g. auto_tune.py).  Players 1-3 get numbered files.
    if pnum == 0 then return "auto_pilot_run.log" end
    return "auto_pilot_run_p" .. pnum .. ".log"
end

local function _endFile(pnum)
    -- Same intentional asymmetry as _logFile — player 0 is the legacy baseline.
    if pnum == 0 then return "auto_pilot_run_end.json" end
    return "auto_pilot_run_p" .. pnum .. "_end.json"
end

-- ── Reason-class classifier ───────────────────────────────────────────────────
local REASON_CLASS = {
    eat        = "survival",
    drink      = "survival",
    sleep      = "survival",
    rest       = "survival",
    shelter    = "survival",
    bandage    = "survival",
    loot       = "survival",
    scavenge   = "survival",
    barricade  = "survival",
    fight      = "combat",
    flee       = "combat",
    combat     = "combat",
    read       = "wellness",
    outside    = "wellness",
    clothing   = "wellness",
    happiness  = "wellness",
    exercise   = "exercise",
    recover    = "recover",
    idle       = "idle",
    busy       = "idle",
    cooldown   = "idle",
    dead       = "idle",
    blocked    = "idle",
}

local function _classifyAction(action)
    return REASON_CLASS[action] or "idle"
end

-- Once-per-session log rotation: when the run log exceeds TELEMETRY_MAX_LINES
-- the oldest lines are dropped, keeping the newest TELEMETRY_KEEP_LINES.
local _rotated = {}

local function _rotateIfNeeded(pnum)
    if _rotated[pnum] then return end
    _rotated[pnum] = true
    pcall(function()
        local keepLines = AutoPilot_Constants.TELEMETRY_KEEP_LINES
        local maxLines  = AutoPilot_Constants.TELEMETRY_MAX_LINES
        local r = getFileReader(_logFile(pnum), true)
        if not r then return end
        -- Ring buffer of the newest keepLines lines while counting the total.
        local keep, count = {}, 0
        local line = r:readLine()
        while line ~= nil do
            count = count + 1
            keep[(count % keepLines) + 1] = line
            line = r:readLine()
        end
        r:close()
        if count <= maxLines then return end
        local w = getFileWriter(_logFile(pnum), true, false)  -- truncate
        if not w then return end
        for c = count - keepLines + 1, count do
            local kept = keep[(c % keepLines) + 1]
            if kept then w:write(kept .. "\n") end
        end
        w:close()
        print(string.format("[Telemetry] Rotated log for player %d: %d -> %d lines.",
            pnum, count, keepLines))
    end)
end

local function _appendLine(pnum, line)
    _rotateIfNeeded(pnum)
    pcall(function()
        -- getFileWriter(name, createIfNotExist, append) — append=true, or every
        -- write truncates the log down to its single most recent line.
        local w = getFileWriter(_logFile(pnum), true, true)
        if w then
            w:write(line .. "\n")
            w:close()
        end
    end)
end

local function _writeEndMarker(pnum, status, reason)
    local ok, ts = pcall(function()
        return getGameTime():getCalender():getTimeInMillis() / 1000
    end)
    local timestamp = ok and ts or 0
    local tick = _runTick[pnum] or 0
    local json = string.format(
        '{"player":%d,"status":"%s","reason":"%s","ticks":%d,"timestamp":%d}',
        pnum, status, reason, tick, math.floor(timestamp)
    )
    pcall(function()
        -- create=true so the end marker is written even on the first-ever run;
        -- append=false intentionally keeps only the latest end marker.
        local w = getFileWriter(_endFile(pnum), true, false)
        if w then
            w:write(json .. "\n")
            w:close()
        end
    end)
end

local function _collectStats(player)
    local hunger    = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    local thirst    = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    local fatigue   = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)

    local zombies = 0
    pcall(function()
        zombies = #AutoPilot_Threat.getNearbyZombies(player)
    end)

    local bleeding = 0
    pcall(function()
        local snap = AutoPilot_Medical.getWoundSnapshot(player)
        bleeding = snap and snap.bleeding or 0
    end)

    local strLvl = 0
    local fitLvl = 0
    pcall(function() strLvl = player:getPerkLevel(Perks.Strength) end)
    pcall(function() fitLvl = player:getPerkLevel(Perks.Fitness)  end)

    -- Schema v3 (V4.1 C2/C6): action-perk levels for the perks the mod
    -- trains through real queued actions (barricade pass / wound treatment).
    local woodLvl = 0
    local docLvl  = 0
    pcall(function() woodLvl = player:getPerkLevel(Perks.Woodwork) end)
    pcall(function() docLvl  = player:getPerkLevel(Perks.Doctor)   end)

    return {
        hunger    = math.floor(hunger    * 100),
        thirst    = math.floor(thirst    * 100),
        fatigue   = math.floor(fatigue   * 100),
        endurance = math.floor(endurance * 100),
        zombies   = zombies,
        bleeding  = bleeding,
        str       = strLvl,
        fit       = fitLvl,
        wood      = woodLvl,
        doc       = docLvl,
    }
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Set the pending decision that the next logTick() call will record.
-- The optional player parameter scopes the pending decision to that player's
-- log; defaults to player 0 when nil.
--
-- @param action      string     Decision label (e.g. "eat", "flee")
-- @param reason      string     Short trigger description (e.g. "hunger_thresh")
-- @param player      IsoPlayer  (optional) the player this decision belongs to
-- @param stage       string     (optional) priority tier ("medical","survival",…)
-- @param fail_reason string     (optional) why the action failed ("no_item",…)
-- @param retry_count number     (optional) retry counter at decision time
function AutoPilot_Telemetry.setDecision(action, reason, player, stage, fail_reason, retry_count)
    local pnum = player and _pn(player) or 0
    _pendingAction[pnum] = action      or "idle"
    _pendingReason[pnum] = reason      or ""
    _pendingStage[pnum]  = stage       or ""
    _pendingFail[pnum]   = fail_reason or ""
    _pendingRetry[pnum]  = retry_count or 0
end

--- Log one evaluation cycle for a player.
-- Increments the per-player run-tick counter and appends a structured line
-- to that player's log file.
--
-- @param player  IsoPlayer
-- @param action  string|nil  Override label; nil uses the pending decision.
-- @param reason  string|nil  Override trigger; nil uses the pending reason.
function AutoPilot_Telemetry.logTick(player, action, reason)
    local pnum = player and _pn(player) or 0
    _runTick[pnum] = (_runTick[pnum] or 0) + 1

    action = action or _pendingAction[pnum] or "idle"
    reason = reason or _pendingReason[pnum] or ""

    -- Feed the death-learning decision ring buffer (collapses duplicates).
    if AutoPilot_DeathLog and AutoPilot_DeathLog.recordDecision then
        pcall(function()
            AutoPilot_DeathLog.recordDecision(player, action, reason)
        end)
    end
    local stage       = _pendingStage[pnum]  or ""
    local fail_reason = _pendingFail[pnum]   or ""
    local retry_count = _pendingRetry[pnum]  or 0
    _pendingAction[pnum] = "idle"
    _pendingReason[pnum] = ""
    _pendingStage[pnum]  = ""
    _pendingFail[pnum]   = ""
    _pendingRetry[pnum]  = 0

    local s   = _collectStats(player)
    local ff  = (s.zombies > 0) and "active" or "normal"
    local cls = _classifyAction(action)

    local line = string.format(
        "schema_version=%d,player=%d,mode=autopilot,ff=%s,run_tick=%d,"
        .. "action=%s,reason=%s,class=%s,stage=%s,fail_reason=%s,retry_count=%d,"
        .. "hunger=%d,thirst=%d,fatigue=%d,endurance=%d,"
        .. "zombies=%d,bleeding=%d,str=%d,fit=%d,wood=%d,doc=%d",
        SCHEMA_VERSION, pnum, ff, _runTick[pnum],
        action, reason, cls, stage, fail_reason, retry_count,
        s.hunger, s.thirst, s.fatigue, s.endurance,
        s.zombies, s.bleeding, s.str, s.fit, s.wood, s.doc
    )
    _appendLine(pnum, line)
end

--- Call exactly once when a player dies.
-- @param player  IsoPlayer
function AutoPilot_Telemetry.onDeath(player)
    AutoPilot_Telemetry.logTick(player, "dead", "player_died")
    local pnum = player and _pn(player) or 0
    _writeEndMarker(pnum, "dead", "player_died")
    -- Death learning layer: rich context snapshot for AutoPilot_Adaptive.
    if AutoPilot_DeathLog and AutoPilot_DeathLog.writeSnapshot then
        pcall(function() AutoPilot_DeathLog.writeSnapshot(player) end)
    end
end

--- Call when autopilot is disabled or the game session ends while autopilot is
-- still active (e.g. main-menu return, new-game queue).  Writes a
-- "timeout"-status end marker so benchmark analysis can distinguish a clean
-- session end from an in-game death.
-- @param player  IsoPlayer|nil  Pass nil to write for player 0.
function AutoPilot_Telemetry.onShutdown(player)
    local pnum = player and _pn(player) or 0
    _writeEndMarker(pnum, "timeout", "session_end")
end

--- Return the pending action label for a player (defaults to player 0).
-- Used by Main to track decision labels for streak detection.
-- @param player  IsoPlayer|nil
function AutoPilot_Telemetry.getPendingAction(player)
    local pnum = player and _pn(player) or 0
    return _pendingAction[pnum] or "idle"
end

--- Return the current run-tick count for a player (defaults to player 0).
-- @param player  IsoPlayer|nil
function AutoPilot_Telemetry.getRunTick(player)
    local pnum = player and _pn(player) or 0
    return _runTick[pnum] or 0
end
