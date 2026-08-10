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
--   getGameTime():getMultiplier()                    -> game-speed multiplier
--     (the same call AutoPilot_Main's FF-1 cadence fix made load-bearing;
--      mirrors the engine idiom, e.g. ISAnimalTracksFinder decrements its
--      counter by getMultiplier() per tick)
--
-- Rates divide by REAL elapsed time SCALED by the game-speed multiplier
-- (FF-4, V6.2 C2): at 1x speed the scaled clock equals the wall clock, so
-- "XP per hour" is the AFK player's actual wait, byte-identical to the
-- pre-fix behaviour; under fast-forward each real millisecond counts
-- getMultiplier() times, so the displayed rate and ETA no longer inflate
-- with game speed.  (This line said the inflation was *"5/20/40x"* until
-- 2026-08-10; the multiplier is an arbitrary positive number, fractions
-- included -- see AutoPilot_Telemetry's `speed` field.)  The sample WINDOW
-- still prunes on raw wall-clock ms: sleep's game-time jump cannot flush
-- it, and a long fast-forward ages samples out at the same real pace as
-- before.

AutoPilot_XP = {}

local function _apNoop(...) end
-- luacheck: ignore print
-- Deliberate noop shadow, uniform across the 19 modules that carry it: any
-- print() added to this file is silenced by default so debug output cannot
-- reach a player's console by accident.  This file calls print() nowhere today,
-- which is why luacheck 211 flags it; the shadow is a standing guarantee about
-- FUTURE lines, not dead code.  Suppressed at its one line, not repo-wide.
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

-- FF-4 (V6.2 C2): game-speed multiplier for rate honesty.  Same verified call
-- and same guard shape as AutoPilot_Main's FF-1 cadence fix: defaults to 1 on
-- any failure or out-of-range value, so a mock without the surface, a load
-- gap, or a paused game (multiplier 0) all degrade to the pre-fix wall-clock
-- behaviour instead of corrupting the accumulator.
local function _speedMult()
    local mult = 1
    pcall(function() mult = getGameTime():getMultiplier() end)
    if type(mult) ~= "number" or mult < 1 then mult = 1 end
    return mult
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
            -- FF-4: the multiplier-scaled elapsed clock.  lastMs is the raw
            -- wall-clock time of the previous accumulation; scaledMs is the
            -- sum of (real interval x game speed at sample time).
            lastMs   = now,
            scaledMs = 0,
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

    -- FF-4: accumulate game-speed-scaled elapsed time.  The scaled clock is
    -- what the rate divides by; the RAW wall-clock ms stays on every sample
    -- because the window prunes on it (see the header note).  The interval
    -- since the previous sample is attributed to the CURRENT multiplier, the
    -- same per-observation approximation the FF-1 cadence fix uses.
    if now > e.lastMs then
        e.scaledMs = e.scaledMs + (now - e.lastMs) * _speedMult()
    end
    e.lastMs = now

    table.insert(e.samples, { ms = now, xp = xp, sms = e.scaledMs })

    -- Prune: outside the window, or over the hard cap.
    while #e.samples > SAMPLE_MAX
        or (#e.samples > 1 and (now - e.samples[1].ms) > SAMPLE_WINDOW_MS) do
        table.remove(e.samples, 1)
    end
end

--- XP gained per hour over the rolling window (0 when unknown).  Elapsed time
--- is REAL time scaled by the game-speed multiplier (FF-4): at 1x this is
--- exactly wall-clock XP/hour; under fast-forward the same real second counts
--- getMultiplier() times, so the rate and ETA stay put when speed changes.
function AutoPilot_XP.ratePerHour(player, perk)
    if not player or not perk then return 0 end
    local e = _entry(player, perk)
    local n = #e.samples
    if n < 2 then return 0 end
    local first, last = e.samples[1], e.samples[n]
    local dScaledMs = last.sms - first.sms
    if dScaledMs <= 0 then return 0 end
    local dXp = last.xp - first.xp
    if dXp <= 0 then return 0 end
    return dXp * 3600000 / dScaledMs
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
