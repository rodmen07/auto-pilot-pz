-- AutoPilot_XP.lua
-- XP metrics engine for the auto-leveler: per-player, per-perk tracking of
-- XP gained, XP/hour rate, and time to next level.
--
-- Verified 42.19 APIs (client/XpSystem/ISUI/ISSkillProgressBar.lua,
-- server/XpSystem/XpUpdate.lua):
--   player:getXp():getXP(Perks.X)                    -> total XP (number)
--   player:getXp():getMultiplier(perkType)           -> skill-book multiplier
--   player:getPerkLevel(Perks.X)                     -> current level (0-10)
--   PerkFactory.getPerk(perk):getTotalXpForLevel(n)  -> cumulative XP threshold
--   getTimestampMs()                                 -> real-time wall clock ms
--
-- Rates use REAL time (wall clock), not game time: "XP per hour" and "time to
-- next level" describe the AFK player's actual wait, and game-time jumps
-- during sleep would corrupt the rate.

AutoPilot_XP = {}

local function _apNoop(...) end
local print = _apNoop

-- _track[pnum][perkKey] = {
--   firstMs, firstXp,          -- session baseline for this perk
--   samples = { {ms, xp} ... } -- rolling window for rate calculation
-- }
local _track = {}

-- Rolling-window tuning.
local SAMPLE_WINDOW_MS = 10 * 60 * 1000  -- rate computed over last 10 minutes
local SAMPLE_MAX       = 120             -- hard cap on stored samples per perk

local MAX_PERK_LEVEL = 10

local function _pnum(player)
    local ok, pnum = pcall(function() return player:getPlayerNum() end)
    return ok and pnum or 0
end

local function _perkKey(perk)
    return tostring(perk)
end

local function _nowMs()
    local ok, ms = pcall(getTimestampMs)
    if ok and type(ms) == "number" then return ms end
    -- Fallback: game time (mock/test environments without a wall clock).
    local ok2, gms = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    return (ok2 and type(gms) == "number") and gms or 0
end

local function _getXp(player, perk)
    local ok, xp = pcall(function() return player:getXp():getXP(perk) end)
    return (ok and type(xp) == "number") and xp or 0
end

local function _getLevel(player, perk)
    local ok, lvl = pcall(function() return player:getPerkLevel(perk) end)
    return (ok and type(lvl) == "number") and lvl or 0
end

local function _getMultiplier(player, perk)
    local ok, mult = pcall(function()
        return player:getXp():getMultiplier(perk)
    end)
    return (ok and type(mult) == "number") and mult or 0
end

-- Cumulative XP needed to reach `level` for this perk, or nil when unknown
-- (max level, or PerkFactory unavailable in a test environment).
local function _totalXpForLevel(perk, level)
    if level > MAX_PERK_LEVEL then return nil end
    local ok, xp = pcall(function()
        return PerkFactory.getPerk(perk):getTotalXpForLevel(level)
    end)
    return (ok and type(xp) == "number") and xp or nil
end

local function _entry(player, perk)
    local pnum = _pnum(player)
    _track[pnum] = _track[pnum] or {}
    local key = _perkKey(perk)
    local e = _track[pnum][key]
    if not e then
        local now = _nowMs()
        e = {
            firstMs = now,
            firstXp = _getXp(player, perk),
            samples = {},
        }
        _track[pnum][key] = e
    end
    return e
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Record an XP sample for this perk.  Cheap; call once per eval cycle for the
--- active target perk.  Establishes the session baseline on first call.
function AutoPilot_XP.sample(player, perk)
    if not player or not perk then return end
    local e   = _entry(player, perk)
    local now = _nowMs()
    local xp  = _getXp(player, perk)

    table.insert(e.samples, { ms = now, xp = xp })

    -- Prune: outside the window, or over the hard cap.
    while #e.samples > SAMPLE_MAX
        or (#e.samples > 1 and (now - e.samples[1].ms) > SAMPLE_WINDOW_MS) do
        table.remove(e.samples, 1)
    end
end

--- XP gained per hour of REAL time over the rolling window (0 when unknown).
function AutoPilot_XP.ratePerHour(player, perk)
    if not player or not perk then return 0 end
    local e = _entry(player, perk)
    local n = #e.samples
    if n < 2 then return 0 end
    local first, last = e.samples[1], e.samples[n]
    local dMs = last.ms - first.ms
    if dMs <= 0 then return 0 end
    local dXp = last.xp - first.xp
    if dXp <= 0 then return 0 end
    return dXp * 3600000 / dMs
end

--- Full metrics snapshot for the UI / telemetry.
--- Returns: { level, xp, xpToNext (nil at max), multiplier, sessionGain,
---            ratePerHour, etaHours (nil when unknown) }
function AutoPilot_XP.getMetrics(player, perk)
    if not player or not perk then return nil end
    local e     = _entry(player, perk)
    local level = _getLevel(player, perk)
    local xp    = _getXp(player, perk)

    local xpToNext = nil
    if level < MAX_PERK_LEVEL then
        local threshold = _totalXpForLevel(perk, level + 1)
        if threshold then
            xpToNext = math.max(0, threshold - xp)
        end
    end

    local rate = AutoPilot_XP.ratePerHour(player, perk)
    local etaHours = nil
    if xpToNext and rate > 0 then
        etaHours = xpToNext / rate
    end

    return {
        level       = level,
        xp          = xp,
        xpToNext    = xpToNext,
        multiplier  = _getMultiplier(player, perk),
        sessionGain = xp - e.firstXp,
        ratePerHour = rate,
        etaHours    = etaHours,
    }
end

--- Reset tracking for one player (e.g. on death/respawn).
function AutoPilot_XP.reset(player)
    _track[_pnum(player)] = nil
end

--- Reset everything (tests).
function AutoPilot_XP.resetAll()
    _track = {}
end
