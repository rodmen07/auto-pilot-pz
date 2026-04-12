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

-- ── Per-player state ───────────────────────────────────────────────────────────
-- Keys are playerNum (0-based integer from player:getPlayerNum()).

local _runTick       = {}   -- [playerNum] -> monotonically increasing counter
local _pendingAction = {}   -- [playerNum] -> action label set by setDecision()
local _pendingReason = {}   -- [playerNum] -> reason label set by setDecision()

-- ── Helpers ────────────────────────────────────────────────────────────────────

local function _pn(player)
    local ok, n = pcall(function() return player:getPlayerNum() end)
    return (ok and type(n) == "number") and n or 0
end

local function _logFile(pnum)
    if pnum == 0 then return "auto_pilot_run.log" end
    return "auto_pilot_run_p" .. pnum .. ".log"
end

local function _endFile(pnum)
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

local function _appendLine(pnum, line)
    pcall(function()
        local w = getFileWriter(_logFile(pnum), true, false)
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
        local w = getFileWriter(_endFile(pnum), false, false)
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
-- The optional player parameter scopes the pending decision to that player's
-- log; defaults to player 0 when nil.
--
-- @param action  string     Decision label (e.g. "eat", "flee")
-- @param reason  string     Short trigger description (e.g. "hunger_thresh")
-- @param player  IsoPlayer  (optional) the player this decision belongs to
function AutoPilot_Telemetry.setDecision(action, reason, player)
    local pnum = player and _pn(player) or 0
    _pendingAction[pnum] = action or "idle"
    _pendingReason[pnum] = reason or ""
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
    _pendingAction[pnum] = "idle"
    _pendingReason[pnum] = ""

    local s   = _collectStats(player)
    local ff  = (s.zombies > 0) and "active" or "normal"
    local cls = _classifyAction(action)

    local line = string.format(
        "player=%d,mode=autopilot,ff=%s,run_tick=%d,action=%s,reason=%s,class=%s,"
        .. "hunger=%d,thirst=%d,fatigue=%d,endurance=%d,"
        .. "zombies=%d,bleeding=%d,str=%d,fit=%d",
        pnum, ff, _runTick[pnum], action, reason, cls,
        s.hunger, s.thirst, s.fatigue, s.endurance,
        s.zombies, s.bleeding, s.str, s.fit
    )
    _appendLine(pnum, line)
end

--- Call exactly once when a player dies.
-- @param player  IsoPlayer
function AutoPilot_Telemetry.onDeath(player)
    AutoPilot_Telemetry.logTick(player, "dead", "player_died")
    local pnum = player and _pn(player) or 0
    _writeEndMarker(pnum, "dead", "player_died")
end

--- Return the current run-tick count for a player (defaults to player 0).
-- @param player  IsoPlayer|nil
function AutoPilot_Telemetry.getRunTick(player)
    local pnum = player and _pn(player) or 0
    return _runTick[pnum] or 0
end
