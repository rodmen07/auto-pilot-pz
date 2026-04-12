-- AutoPilot_Telemetry.lua
-- Structured per-tick telemetry writer for run logging and offline benchmark analysis.
--
-- Writes one key=value CSV line per evaluation cycle to:
--   ~/Zomboid/Lua/auto_pilot_run.log   (appended)
-- and a JSON end-marker to:
--   ~/Zomboid/Lua/auto_pilot_run_end.json  (overwritten on death)
--
-- File I/O uses getFileWriter() — the only game-safe file API in PZ's sandbox.
-- All operations are wrapped in pcall to prevent crashes on any I/O failure.
--
-- Load order note: 'T' sorts after 'N','M','I','H','C','B','A' and before 'Th','U'.
-- All references to other AutoPilot globals are inside function bodies and are
-- resolved at call time — load order is not a concern.

AutoPilot_Telemetry = {}

local LOG_FILE = "auto_pilot_run.log"
local END_FILE = "auto_pilot_run_end.json"

-- Monotonically increasing counter: incremented once per evaluation cycle.
local _runTick = 0

-- Decision set by the Needs/Threat modules before returning so that logTick
-- can record the actual action rather than a coarse "needs" label.
local _pendingAction = "idle"
local _pendingReason = ""

-- ── Reason-class classifier ───────────────────────────────────────────────────
-- Maps well-known action labels to a broad category used for offline analysis.
-- "survival"  — the character was fulfilling a basic biological need
-- "combat"    — a zombie threat was being handled
-- "wellness"  — morale/happiness/clothing/pain management
-- "exercise"  — intentional fitness training
-- "idle"      — no action taken; covers cooldown and busy ticks too
local REASON_CLASS = {
    eat        = "survival",
    drink      = "survival",
    sleep      = "survival",
    rest       = "survival",
    shelter    = "survival",
    bandage    = "survival",
    loot       = "survival",
    fight      = "combat",
    flee       = "combat",
    combat     = "combat",
    read       = "wellness",
    outside    = "wellness",
    clothing   = "wellness",
    happiness  = "wellness",
    exercise   = "exercise",
    idle       = "idle",
    busy       = "idle",
    cooldown   = "idle",
    dead       = "idle",
}

local function _classifyAction(action)
    return REASON_CLASS[action] or "idle"
end

-- Append a single text line to the log file.
local function _appendLine(line)
    pcall(function()
        local w = getFileWriter(LOG_FILE, true, false)
        if w then
            w:write(line .. "\n")
            w:close()
        end
    end)
end

-- Overwrite the run-end JSON marker file.
local function _writeEndMarker(status, reason)
    local ok, ts = pcall(function()
        return getGameTime():getCalender():getTimeInMillis() / 1000
    end)
    local timestamp = ok and ts or 0
    local json = string.format(
        '{"status":"%s","reason":"%s","ticks":%d,"timestamp":%d}',
        status, reason, _runTick, math.floor(timestamp)
    )
    pcall(function()
        local w = getFileWriter(END_FILE, false, false)
        if w then
            w:write(json .. "\n")
            w:close()
        end
    end)
end

-- Collect a lightweight player stat snapshot.  All getters are pcall-wrapped
-- to be safe during cell loading or on any missing API surface.
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

    return {
        hunger    = math.floor(hunger    * 100),
        thirst    = math.floor(thirst    * 100),
        fatigue   = math.floor(fatigue   * 100),
        endurance = math.floor(endurance * 100),
        zombies   = zombies,
        bleeding  = bleeding,
        str       = strLvl,
        fit       = fitLvl,
    }
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Set the pending decision that the next logTick() call will record.
-- Called by AutoPilot_Needs and AutoPilot_Threat immediately before the
-- action that may return true, so the recorded label is accurate even when
-- logTick() is called from Main after the action completes.
--
-- @param action  string  Decision label (e.g. "eat", "drink", "flee")
-- @param reason  string  Short trigger description (e.g. "hunger_thresh")
function AutoPilot_Telemetry.setDecision(action, reason)
    _pendingAction = action or "idle"
    _pendingReason = reason or ""
end

--- Log one evaluation cycle.
-- Increments the internal run-tick counter and appends a structured line to the
-- log file.  When `action` is nil the pending decision set by setDecision() is
-- used and then cleared, so the label reflects the actual action taken.
-- The `ff` field is "active" when zombies are nearby, "normal" otherwise.
--
-- @param player  IsoPlayer
-- @param action  string|nil  Override label; nil uses the pending decision.
-- @param reason  string|nil  Override trigger; nil uses the pending reason.
function AutoPilot_Telemetry.logTick(player, action, reason)
    _runTick = _runTick + 1
    -- Consume pending decision if no explicit override was supplied.
    action = action or _pendingAction
    reason = reason or _pendingReason
    _pendingAction = "idle"
    _pendingReason = ""

    local s  = _collectStats(player)
    local ff = (s.zombies > 0) and "active" or "normal"
    local cls = _classifyAction(action)

    local line = string.format(
        "mode=autopilot,ff=%s,run_tick=%d,action=%s,reason=%s,class=%s,"
        .. "hunger=%d,thirst=%d,fatigue=%d,endurance=%d,"
        .. "zombies=%d,bleeding=%d,str=%d,fit=%d",
        ff, _runTick, action, reason, cls,
        s.hunger, s.thirst, s.fatigue, s.endurance,
        s.zombies, s.bleeding, s.str, s.fit
    )
    _appendLine(line)
end

--- Call exactly once when the player dies.
-- Logs a final "dead" tick and writes the run-end JSON marker so that the
-- external Python harness can detect natural run termination.
--
-- @param player  IsoPlayer
function AutoPilot_Telemetry.onDeath(player)
    AutoPilot_Telemetry.logTick(player, "dead", "player_died")
    _writeEndMarker("dead", "player_died")
end

--- Return the current run-tick count (number of evaluation cycles logged so far).
function AutoPilot_Telemetry.getRunTick()
    return _runTick
end
