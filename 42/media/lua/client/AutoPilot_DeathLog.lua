-- AutoPilot_DeathLog.lua
-- Death learning layer, part 1: recording.
--
-- Keeps a ring buffer of recent decisions per player and, on death, writes a
-- rich context snapshot (stats, wounds, threat, position, active skill, recent
-- decisions, best-guess cause) as ONE key=value line appended to:
--   ~/Zomboid/Lua/auto_pilot_deaths.log
--
-- The same file is read back at session start by AutoPilot_Adaptive to adjust
-- thresholds, and is analysis-friendly for the offline Python tooling
-- (key=value CSV, same house format as the telemetry run log).

AutoPilot_DeathLog = {}

local function _apNoop(...) end
local print = _apNoop

local DEATHS_FILE    = "auto_pilot_deaths.log"
local SCHEMA_VERSION = 1
local RING_SIZE      = 15   -- recent decisions kept per player

-- _ring[pnum] = { "action:reason", ... } newest last
local _ring = {}

local function _pnum(player)
    local ok, n = pcall(function() return player:getPlayerNum() end)
    return (ok and type(n) == "number") and n or 0
end

-- ── Decision ring buffer ──────────────────────────────────────────────────────

--- Record one decision label; called from Telemetry.logTick each cycle.
--- Consecutive duplicates are collapsed (a 10-minute idle streak is one entry).
function AutoPilot_DeathLog.recordDecision(player, action, reason)
    local pnum  = _pnum(player)
    local entry = tostring(action or "idle") .. ":" .. tostring(reason or "")
    _ring[pnum] = _ring[pnum] or {}
    local ring  = _ring[pnum]
    if ring[#ring] ~= entry then
        table.insert(ring, entry)
        while #ring > RING_SIZE do table.remove(ring, 1) end
    end
end

function AutoPilot_DeathLog.getRecentDecisions(player)
    return _ring[_pnum(player)] or {}
end

-- ── Snapshot collection ───────────────────────────────────────────────────────

local function _safe(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return default
end

-- Best-guess cause classifier, evaluated from the state AT death.
-- Order matters: the most specific signal wins.
local function _classifyCause(ctx)
    if ctx.zombies >= AutoPilot_Constants.FLEE_HORDE_SIZE then return "horde" end
    if ctx.zombies > 0 and ctx.bleeding > 0 then return "zombie_wounded" end
    if ctx.bleeding > 0 then return "bleed_out" end
    if ctx.bitten then return "infection" end
    if ctx.hunger >= 0.90 then return "starvation" end
    if ctx.thirst >= 0.90 then return "dehydration" end
    if ctx.zombies > 0 then return "zombies" end
    return "unknown"
end

--- Collect the death context table (also unit-testable without file I/O).
function AutoPilot_DeathLog.collectContext(player)
    local pnum = _pnum(player)

    local px = math.floor(_safe(function() return player:getX() end, 0))
    local py = math.floor(_safe(function() return player:getY() end, 0))
    local pz = math.floor(_safe(function() return player:getZ() end, 0))

    -- Distance from home (0 when no home set).
    local distHome, homeSet = 0, false
    pcall(function()
        if AutoPilot_Home.isSet(player) then
            homeSet = true
            local hx, hy = AutoPilot_Home.getState(player)
            if type(hx) == "number" and type(hy) == "number" then
                distHome = math.floor(math.sqrt((px - hx) ^ 2 + (py - hy) ^ 2))
            end
        end
    end)

    local wounds = {}
    pcall(function() wounds = AutoPilot_Medical.getWoundSnapshot(player) or {} end)

    local zombies = 0
    pcall(function() zombies = #AutoPilot_Threat.getNearbyZombies(player) end)

    local outside = _safe(function()
        return player:getCurrentSquare():isOutside()
    end, false)

    local hoursSurvived = _safe(function()
        return math.floor(player:getHoursSurvived())
    end, 0)

    -- Active leveling target, when the Leveler is loaded.
    local skill = "none"
    pcall(function()
        skill = AutoPilot_Leveler.getTargetSkillName(player) or "none"
    end)

    local ctx = {
        schema     = SCHEMA_VERSION,
        player     = pnum,
        hours      = hoursSurvived,
        x = px, y = py, z = pz,
        outside    = outside and 1 or 0,
        home_set   = homeSet and 1 or 0,
        dist_home  = distHome,
        zombies    = zombies,
        hunger     = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER),
        thirst     = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST),
        fatigue    = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE),
        endurance  = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE),
        bleeding   = wounds.bleeding or 0,
        deep_wound = wounds.deep_wounded or 0,
        bitten     = (wounds.bitten == true or wounds.bitten == 1
                     or (tonumber(wounds.bitten) or 0) > 0),
        skill      = skill,
        decisions  = table.concat(AutoPilot_DeathLog.getRecentDecisions(player), "|"),
    }
    ctx.cause = _classifyCause(ctx)
    return ctx
end

-- ── Persistence ───────────────────────────────────────────────────────────────

local function _formatLine(ctx)
    -- Fixed field order for stable parsing.
    return string.format(
        "schema=%d,player=%d,cause=%s,hours=%d,x=%d,y=%d,z=%d,outside=%d,"
        .. "home_set=%d,dist_home=%d,zombies=%d,hunger=%.2f,thirst=%.2f,"
        .. "fatigue=%.2f,endurance=%.2f,bleeding=%d,deep_wound=%d,bitten=%d,"
        .. "skill=%s,decisions=%s",
        ctx.schema, ctx.player, ctx.cause, ctx.hours, ctx.x, ctx.y, ctx.z,
        ctx.outside, ctx.home_set, ctx.dist_home, ctx.zombies, ctx.hunger,
        ctx.thirst, ctx.fatigue, ctx.endurance, ctx.bleeding, ctx.deep_wound,
        ctx.bitten and 1 or 0, ctx.skill, ctx.decisions)
end

--- Write the death snapshot; called from Telemetry.onDeath.
function AutoPilot_DeathLog.writeSnapshot(player)
    local okCtx, ctx = pcall(AutoPilot_DeathLog.collectContext, player)
    if not okCtx or not ctx then return false end
    local line = _formatLine(ctx)
    local okW = pcall(function()
        local w = getFileWriter(DEATHS_FILE, true, true)  -- create + APPEND
        if w then
            w:write(line .. "\n")
            w:close()
        end
    end)
    if okW then
        print("[DeathLog] Recorded death: cause=" .. ctx.cause)
    end
    return okW == true
end

--- Read all recorded death lines (raw strings, oldest first).
--- Used by AutoPilot_Adaptive at session start.
function AutoPilot_DeathLog.readLines()
    local lines = {}
    pcall(function()
        local r = getFileReader(DEATHS_FILE, true)
        if not r then return end
        local line = r:readLine()
        while line ~= nil do
            if line ~= "" then table.insert(lines, line) end
            line = r:readLine()
        end
        r:close()
    end)
    return lines
end

--- Parse one death line into a flat table (strings/numbers).  Returns nil on
--- malformed input.  Exposed for tests and for Adaptive.
function AutoPilot_DeathLog.parseLine(line)
    if type(line) ~= "string" or line == "" then return nil end
    local t = {}
    for key, value in line:gmatch("([%w_]+)=([^,]*)") do
        t[key] = tonumber(value) or value
    end
    if t.schema == nil or t.cause == nil then return nil end
    return t
end

--- Number of recorded deaths (for the UI panel).
function AutoPilot_DeathLog.getDeathCount()
    return #AutoPilot_DeathLog.readLines()
end

--- Reset the ring buffers (tests).
function AutoPilot_DeathLog.resetRings()
    _ring = {}
end
