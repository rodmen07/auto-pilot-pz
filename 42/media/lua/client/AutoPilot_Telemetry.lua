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
-- V4.2 (C5): each logTick also feeds AutoPilot_SessionHistory.observe, and
-- onDeath/onShutdown finalize the session summary (auto_pilot_sessions.log,
-- owned by AutoPilot_SessionHistory).  All three callsites are existence
-- guarded + pcall-wrapped, same pattern as the DeathLog feed.
--
-- File I/O uses getFileWriter() — the only game-safe file API in PZ's sandbox.
-- All operations are wrapped in pcall to prevent crashes on any I/O failure.

AutoPilot_Telemetry = {}

-- Telemetry schema version: increment when the field set changes.
-- Old parsers that don't know this field simply ignore it.
-- v3 (V4.1): appended wood/doc (Woodwork and Doctor perk levels) after fit,
-- the read-only action-perk visibility from expansion candidates C2/C6.
-- v4 (V5.0): drops wood, the only non-additive change so far.  Barricading
-- and woodworking left the mod's scope, so the field could only ever report
-- a perk the mod no longer touches.  Safe because both offline parsers
-- (triage_run_log.py, benchmark.py) are key=value readers that require only
-- action and run_tick: triage coerces wood when present and never consumes
-- it, and benchmark never listed it at all.  Existing v3 logs therefore keep
-- parsing verbatim, and mixed v3/v4 files parse line by line.
-- v5 (2026-07-24): added the `speed` field (real game multiplier).
-- v6 (2026-08-10): appended `mod_version`, the BUILD STAMP.  Additive, so v2-v5
-- lines keep parsing untouched and both offline parsers ignore the new key.
--
-- Why a build stamp is worth a schema bump: this log is APPEND-ONLY at a FIXED
-- PATH across every session AND every mod update, and nothing in a line said
-- which build wrote it.  A telemetry finding is evidence about a BUILD, so
-- without the stamp a defect that has since been FIXED keeps failing the
-- run-log guard forever, indistinguishable from a live regression.  That is not
-- hypothetical: on 2026-08-10 a HIGH "the FLEE path stalls" bug was filed
-- against current main from five findings whose every byte was written
-- 2026-08-07 04:01 or earlier -- BEFORE all three merged fixes that target
-- exactly those two shapes (#120 16:28Z, #122 18:43Z, #123 2026-08-08T01:35Z).
-- The entry's own "confirmed pre-existing on origin/main" control could not
-- have failed: the guard re-reads the same historical bytes whatever commit is
-- checked out, so it says nothing about the code under test.  With this field
-- that question is one comparison instead of an archaeology session.
local SCHEMA_VERSION = 6

-- ── Per-player state ───────────────────────────────────────────────────────────
-- Keys are playerNum (0-based integer from player:getPlayerNum()).

local _runTick        = {}   -- [playerNum] -> monotonically increasing counter
local _pendingAction  = {}   -- [playerNum] -> action label set by setDecision()
local _pendingReason  = {}   -- [playerNum] -> reason label set by setDecision()
local _pendingStage   = {}   -- [playerNum] -> priority tier label
local _pendingFail    = {}   -- [playerNum] -> fail_reason label
local _pendingRetry   = {}   -- [playerNum] -> retry_count at decision time

-- V6.0-3 (C2): what the most recent LOGGED cycle recorded, surviving the
-- pending-state clear at the end of logTick().  The pending stores above are
-- consumed by logTick mid-cycle, but the F11 panel and the action HUD render
-- AFTER the cycle returns, so the read side needs the logged values, not the
-- pending ones.
local _lastReason     = {}   -- [playerNum] -> reason of the last logged cycle
local _lastFail       = {}   -- [playerNum] -> fail_reason of the last logged cycle

-- ── Helpers ────────────────────────────────────────────────────────────────────

local function _pn(player)
    local ok, n = pcall(function() return player:getPlayerNum() end)
    return (ok and type(n) == "number") and n or 0
end

-- The build stamp written into every schema-v6 line (see SCHEMA_VERSION above).
-- AutoPilot_Constants.VERSION is already bound to `modversion=` in BOTH mod.info
-- files by tests/test_version_constant.lua and tests/test_version_sync.py, so
-- this reuses a checked value rather than minting a second version home.
-- Returns "unknown" rather than nil when Constants has not loaded: a line that
-- cannot name its build must still SAY so, because an absent field means
-- "pre-v6" to every reader and would silently mis-date a current session.
local function _modBuild()
    local v = AutoPilot_Constants and AutoPilot_Constants.VERSION
    if type(v) ~= "string" then return "unknown" end
    -- The line is comma-delimited key=value, so a stamp carrying "," or "="
    -- would split into phantom fields and corrupt every field after it.  This
    -- clamps a value that is already guarded; it is not a parser.
    v = v:gsub("[^%w%.%-_]", "")
    if v == "" then return "unknown" end
    return v
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
    fight      = "combat",
    flee       = "combat",
    combat     = "combat",
    read       = "wellness",
    media      = "wellness",
    outside    = "wellness",
    clothing   = "wellness",
    dry        = "wellness",
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

    -- Schema v4 (V4.1 C6, trimmed in V5.0): action-perk level for the perk
    -- the mod trains through a real queued action (wound treatment).
    local docLvl = 0
    pcall(function() docLvl = player:getPerkLevel(Perks.Doctor) end)

    -- Raw XP totals beside the levels (2026-07-26, HIGH observability bug).
    -- PZ levels move rarely, so a session summary built on levels alone shows
    -- "5 -> 5" for a session that gained most of a level and for one that
    -- gained nothing at all.  These feed AutoPilot_SessionHistory ONLY: the
    -- run-log line below carries no XP field (the schema bump to v6 appended
    -- mod_version and nothing else; tests/test_session_xp.lua pins the absence).
    -- API verified live in the 42.19 install: player:getXp():getXP(Perks.X)
    -- (client/ISUI/PlayerStats/ISPlayerStatsUI.lua:515, server/XpSystem/
    -- XpUpdate.lua:311).  Read inline, like the perk levels above, rather
    -- than through AutoPilot_XP: that module owns the rate/ETA math and
    -- loads AFTER Telemetry, and a missing-module fallback here would report
    -- a silent 0 gain, which is the exact failure this fix exists to end.
    local strXp, fitXp, docXp = 0, 0, 0
    pcall(function() strXp = player:getXp():getXP(Perks.Strength) end)
    pcall(function() fitXp = player:getXp():getXP(Perks.Fitness)  end)
    pcall(function() docXp = player:getXp():getXP(Perks.Doctor)   end)

    return {
        hunger    = math.floor(hunger    * 100),
        thirst    = math.floor(thirst    * 100),
        fatigue   = math.floor(fatigue   * 100),
        endurance = math.floor(endurance * 100),
        zombies   = zombies,
        bleeding  = bleeding,
        str       = strLvl,
        fit       = fitLvl,
        doc       = docLvl,
        str_xp    = strXp,
        fit_xp    = fitXp,
        doc_xp    = docXp,
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

    -- V6.0-3 (C2): keep the logged reason readable after the pending clear.
    -- Note fail_reason is read from the PENDING store even when action/reason
    -- were passed as literal overrides (the idle/no_action gate in Main), so a
    -- blocked sleep that fell through to nothing still surfaces its
    -- "pain_block"/"panic" here — exactly the "why is it doing nothing" case.
    _lastReason[pnum] = reason
    _lastFail[pnum]   = fail_reason

    local s   = _collectStats(player)
    -- NOTE: `ff` is a ZOMBIE-PRESENCE flag (active = a zombie was in this cycle's
    -- cached scan), NOT fast-forward -- a historical misnomer that has misled
    -- fast-forward investigations.  The real game speed is the separate `speed`
    -- field (schema v5, 2026-07-24): getGameTime():getMultiplier(), so
    -- speed-related reports now carry evidence.
    --
    -- That multiplier is an ARBITRARY POSITIVE NUMBER, not one of 5/20/40 (this
    -- comment claimed *"1 = normal, 5/20/40 = fast-forward x1/x2/x3"* until
    -- 2026-08-10).  5/20/40 are only SpeedControlsHandler's three keyboard
    -- buttons (client/ISUI/SpeedControlsHandler.lua:28-40); the engine's debug
    -- panel binds a 0..1000 slider with step 0.1 straight to setMultiplier
    -- (client/DebugUIs/DebugMenu/General/ISGameDebugPanel.lua:42), and this
    -- log's own `speed` field records 1, 4, 9..20, 23, 30..33, 80 and 100 in a
    -- single 11.7k-tick capture.
    local ff  = (s.zombies > 0) and "active" or "normal"
    local speed = 1
    pcall(function() speed = getGameTime():getMultiplier() end)
    if type(speed) ~= "number" or speed < 1 then speed = 1 end
    -- FLOOR before %d.  This is the only %d argument in the line below that is
    -- not already integral -- the stats are floored in _collectStats and the
    -- rest are counts -- and a fractional multiplier makes string.format raise
    -- "number has no integer representation", which loses the whole line
    -- SILENTLY: _tickForPlayer is pcall-wrapped at AutoPilot_Main.lua:501 and
    -- discards the error, so the run log just stops.  Identity on integers, so
    -- every speed the buttons produce is byte-for-byte unchanged.
    speed = math.floor(speed)
    local cls = _classifyAction(action)

    local line = string.format(
        "schema_version=%d,player=%d,mode=autopilot,ff=%s,speed=%d,run_tick=%d,"
        .. "action=%s,reason=%s,class=%s,stage=%s,fail_reason=%s,retry_count=%d,"
        .. "hunger=%d,thirst=%d,fatigue=%d,endurance=%d,"
        .. "zombies=%d,bleeding=%d,str=%d,fit=%d,doc=%d,mod_version=%s",
        SCHEMA_VERSION, pnum, ff, speed, _runTick[pnum],
        action, reason, cls, stage, fail_reason, retry_count,
        s.hunger, s.thirst, s.fatigue, s.endurance,
        s.zombies, s.bleeding, s.str, s.fit, s.doc, _modBuild()
    )
    _appendLine(pnum, line)

    -- Feed the V4.2 session-history data layer (per-session summaries with
    -- checkpoint writes; see AutoPilot_SessionHistory).
    if AutoPilot_SessionHistory and AutoPilot_SessionHistory.observe then
        pcall(function() AutoPilot_SessionHistory.observe(player, s) end)
    end
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
    -- Session history: the definitive "dead" summary line (V4.2).
    if AutoPilot_SessionHistory and AutoPilot_SessionHistory.finalize then
        pcall(function() AutoPilot_SessionHistory.finalize(player, "dead") end)
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
    -- Session history: the definitive "timeout" summary line (V4.2).  A
    -- no-op when the session was already finalized by a death.
    if AutoPilot_SessionHistory and AutoPilot_SessionHistory.finalize then
        pcall(function()
            AutoPilot_SessionHistory.finalize(player, "timeout")
        end)
    end
end

--- Return the pending action label for a player (defaults to player 0).
-- Used by Main to track decision labels for streak detection.
-- @param player  IsoPlayer|nil
function AutoPilot_Telemetry.getPendingAction(player)
    local pnum = player and _pn(player) or 0
    return _pendingAction[pnum] or "idle"
end

--- V6.0-3 (C2): the decision reason recorded by the player's most recent
-- logged cycle (defaults to player 0).  Mirrors getPendingAction: a pure
-- per-player read with a safe default that never mutates or clears state.
-- A non-empty fail_reason wins over the decision reason because it answers
-- "why is it doing nothing" (e.g. a sleep the engine refused: "pain_block",
-- "panic").  This is the read side the F11 panel and the action HUD render
-- through AutoPilot.reasonLine.
-- @param player  IsoPlayer|nil
-- @return string  reason token, or "" when no cycle has been logged yet
function AutoPilot_Telemetry.getDecisionReason(player)
    local pnum = player and _pn(player) or 0
    local fail = _lastFail[pnum] or ""
    if fail ~= "" then return fail end
    return _lastReason[pnum] or ""
end

--- Return the current run-tick count for a player (defaults to player 0).
-- @param player  IsoPlayer|nil
function AutoPilot_Telemetry.getRunTick(player)
    local pnum = player and _pn(player) or 0
    return _runTick[pnum] or 0
end
