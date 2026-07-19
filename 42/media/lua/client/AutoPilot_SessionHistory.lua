-- AutoPilot_SessionHistory.lua
-- Session history data layer (V4.2, expansion candidate C5).
--
-- Persists one compact key=value summary line per game session to:
--   ~/Zomboid/Lua/auto_pilot_sessions.log       (player 0)
--   ~/Zomboid/Lua/auto_pilot_sessions_pN.log    (players 1+, legacy plumbing)
-- and serves the parsed history back to the F11 panel as pre-formatted
-- strings, so ALL logic (format, parser, aggregation, retention) lives here
-- and is unit-testable; AutoPilot_UI only renders what this module returns.
--
-- File format (mirrors the run-log discipline):
--   * line 1: a versioned header comment ("# auto_pilot_sessions schema=1");
--   * one key=value CSV line per session, fields additive-only, so old
--     parsers ignore unknown keys and new parsers tolerate old lines;
--   * writes are APPEND-only (the V2.1 truncate bug rule): session-end
--     lines on death/shutdown plus periodic "open" checkpoint lines, so a
--     crash still leaves a recent summary.  At read time the LATEST line
--     per session id wins, collapsing the checkpoints.
--   * bounded: once per Lua session, on the first session begin, the file
--     is collapsed (one line per session) and only the newest
--     SESSION_HISTORY_KEEP summaries are retained (V3.3 rotation pattern).
--
-- Field conventions reuse triage_run_log.py's session summary (str_start /
-- str_end etc., ticks, ended in {open, dead, timeout}); the triage tool
-- already proved these derivable from telemetry, this module computes them
-- directly at session end instead of re-parsing the run log in Kahlua.
--
-- Load-order note: "SessionHistory" sorts after Constants and before
-- Telemetry; cross-module references live only inside function bodies and
-- resolve at call time.  This module registers NO events: the write hooks
-- ride Telemetry's existing logTick/onDeath/onShutdown paths (which Main
-- already existence-guards), so no new Events guards are needed.
--
-- File I/O uses getFileWriter/getFileReader (the only game-safe file APIs
-- in PZ's sandbox); every I/O call is pcall-wrapped.

AutoPilot_SessionHistory = {}

local SCHEMA_VERSION = 1
local FILE_HEADER    = "# auto_pilot_sessions schema=" .. SCHEMA_VERSION

-- ── Per-player state ─────────────────────────────────────────────────────────
-- Keys are playerNum.  _state[pnum] = {
--   id            session id (monotonic per file),
--   ticks         evaluation cycles observed this session,
--   start / last  { str, fit, wood, doc } perk levels,
--   lastFlush     ticks value at the most recent checkpoint write,
--   ended         nil while open, else "dead" / "timeout",
-- }
local _state  = {}
local _nextId = {}   -- [pnum] -> next session id (max id in file + 1)
local _begun  = {}   -- [pnum] -> true once rotation ran this Lua session

local function _pn(player)
    local ok, n = pcall(function() return player:getPlayerNum() end)
    return (ok and type(n) == "number") and n or 0
end

local function _file(pnum)
    -- Player 0 keeps the short filename (same asymmetry as the run log).
    if pnum == 0 then return "auto_pilot_sessions.log" end
    return "auto_pilot_sessions_p" .. pnum .. ".log"
end

local function _keep()
    return (AutoPilot_Constants and AutoPilot_Constants.SESSION_HISTORY_KEEP)
        or 30
end

-- ── Line format and tolerant parser ──────────────────────────────────────────

--- Format one session summary line (fixed field order, additive-only).
local function _formatLine(pnum, st, ended)
    return string.format(
        "schema=%d,session=%d,player=%d,ticks=%d,"
        .. "str_start=%d,str_end=%d,fit_start=%d,fit_end=%d,"
        .. "wood_start=%d,wood_end=%d,doc_start=%d,doc_end=%d,ended=%s",
        SCHEMA_VERSION, st.id, pnum, st.ticks,
        st.start.str, st.last.str, st.start.fit, st.last.fit,
        st.start.wood, st.last.wood, st.start.doc, st.last.doc,
        ended)
end

--- Parse one summary line into a flat table.  Tolerant by design: returns
--- nil for header/comment lines, blank lines, and anything without a
--- numeric session id, numeric ticks, and an ended label; unknown keys are
--- kept, missing additive fields simply stay absent.
function AutoPilot_SessionHistory.parseLine(line)
    if type(line) ~= "string" then return nil end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")   -- stray CR/LF tolerated
    if line == "" then return nil end
    if line:sub(1, 1) == "#" then return nil end
    local t = {}
    for key, value in line:gmatch("([%w_]+)=([^,]*)") do
        t[key] = tonumber(value) or value
    end
    if type(t.session) ~= "number" or type(t.ticks) ~= "number"
            or t.ended == nil then
        return nil
    end
    return t
end

local function _delta(startV, endV)
    if type(startV) == "number" and type(endV) == "number" then
        return endV - startV
    end
    return nil
end

--- Attach per-perk level deltas (nil when a field pair is absent, so old
--- lines missing an additive pair degrade to "?" in the display).
local function _withDeltas(sum)
    sum.dstr  = _delta(sum.str_start,  sum.str_end)
    sum.dfit  = _delta(sum.fit_start,  sum.fit_end)
    sum.dwood = _delta(sum.wood_start, sum.wood_end)
    sum.ddoc  = _delta(sum.doc_start,  sum.doc_end)
    return sum
end

-- ── File access ──────────────────────────────────────────────────────────────

local function _readRawLines(pnum)
    local lines = {}
    pcall(function()
        local r = getFileReader(_file(pnum), true)
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

local function _append(pnum, line)
    pcall(function()
        -- append=true always: a false flag would truncate (the V2.1 bug).
        local w = getFileWriter(_file(pnum), true, true)
        if w then
            w:write(line .. "\n")
            w:close()
        end
    end)
end

--- Collapse raw file lines to the LATEST raw line per session id, in
--- ascending id order.  Returns (entries, rawCount, hadHeader) where each
--- entry is { id = n, raw = line }.  Raw text is preserved so a rotation
--- rewrite never drops additive fields this version does not know about.
local function _collapse(rawLines)
    local byId, ids = {}, {}
    local hadHeader = (rawLines[1] ~= nil and rawLines[1]:sub(1, 1) == "#")
    for i = 1, #rawLines do
        local parsed = AutoPilot_SessionHistory.parseLine(rawLines[i])
        if parsed then
            if byId[parsed.session] == nil then
                table.insert(ids, parsed.session)
            end
            byId[parsed.session] = rawLines[i]
        end
    end
    table.sort(ids)
    local entries = {}
    for i = 1, #ids do
        table.insert(entries, { id = ids[i], raw = byId[ids[i]] })
    end
    return entries, #rawLines, hadHeader
end

-- Once per Lua session, on the first session begin: collapse checkpoint
-- duplicates, drop malformed lines, retain only the newest KEEP summaries,
-- and learn the next session id.  Mirrors the run log's once-per-session
-- rotation; the rewrite is the ONLY non-append write this module makes.
local function _beginFile(pnum)
    -- Second and later sessions in the same Lua state (death + respawn):
    -- rotation already ran and the id counter is live; skip the file read.
    if _begun[pnum] and _nextId[pnum] ~= nil then return end
    local entries, rawCount, hadHeader = _collapse(_readRawLines(pnum))
    local maxId = 0
    for i = 1, #entries do
        if entries[i].id > maxId then maxId = entries[i].id end
    end
    if _nextId[pnum] == nil then _nextId[pnum] = maxId + 1 end

    if _begun[pnum] then return end
    _begun[pnum] = true

    local keep = _keep()
    local bodyCount = rawCount - (hadHeader and 1 or 0)
    local needsRewrite = (#entries > keep)
        or (bodyCount ~= #entries)
        or (not hadHeader and rawCount > 0)

    if needsRewrite then
        pcall(function()
            local w = getFileWriter(_file(pnum), true, false)  -- rotate
            if not w then return end
            w:write(FILE_HEADER .. "\n")
            local first = math.max(1, #entries - keep + 1)
            for i = first, #entries do
                w:write(entries[i].raw .. "\n")
            end
            w:close()
            print(string.format(
                "[SessionHistory] Rotated summaries for player %d: %d -> %d line(s).",
                pnum, rawCount, math.min(#entries, keep) + 1))
        end)
    elseif rawCount == 0 then
        _append(pnum, FILE_HEADER)
    end
end

-- ── Session lifecycle ────────────────────────────────────────────────────────

local function _levelsFrom(stats)
    return {
        str  = tonumber(stats.str)  or 0,
        fit  = tonumber(stats.fit)  or 0,
        wood = tonumber(stats.wood) or 0,
        doc  = tonumber(stats.doc)  or 0,
    }
end

local function _newSession(pnum, stats)
    _beginFile(pnum)
    local id = _nextId[pnum] or 1
    _nextId[pnum] = id + 1
    local start = _levelsFrom(stats)
    return {
        id        = id,
        ticks     = 0,
        start     = start,
        last      = _levelsFrom(stats),
        lastFlush = 0,
        ended     = nil,
    }
end

--- Observe one evaluation cycle.  Called from Telemetry.logTick with the
--- collected stats table (str/fit/wood/doc perk levels).  Lazily begins the
--- session (first observe after load, or the first one after a death
--- finalized the previous session) and appends an "open" checkpoint line
--- every SESSION_HISTORY_CHECKPOINT_CYCLES cycles.
function AutoPilot_SessionHistory.observe(player, stats)
    if type(stats) ~= "table" then return end
    local pnum = _pn(player)
    local st = _state[pnum]
    if st == nil or st.ended ~= nil then
        st = _newSession(pnum, stats)
        _state[pnum] = st
    end
    st.ticks = st.ticks + 1
    st.last  = _levelsFrom(stats)

    local every = (AutoPilot_Constants
        and AutoPilot_Constants.SESSION_HISTORY_CHECKPOINT_CYCLES) or 400
    if st.ticks - st.lastFlush >= every then
        st.lastFlush = st.ticks
        _append(pnum, _formatLine(pnum, st, "open"))
    end
end

--- Finalize the current session.  Called from Telemetry.onDeath ("dead")
--- and Telemetry.onShutdown ("timeout").  Appends the definitive summary
--- line; idempotent (a shutdown after a death changes nothing), and a
--- session that never observed a cycle writes nothing.
function AutoPilot_SessionHistory.finalize(player, reason)
    local pnum = _pn(player)
    local st = _state[pnum]
    if st == nil or st.ticks == 0 or st.ended ~= nil then return false end
    st.ended = (reason == "dead") and "dead" or "timeout"
    _append(pnum, _formatLine(pnum, st, st.ended))
    return true
end

-- ── Read side (history, aggregation, panel strings) ──────────────────────────

--- Return parsed session summaries, NEWEST FIRST, capped at maxN (default:
--- the retention bound).  File checkpoints collapse (latest line per id
--- wins) and the live in-memory session overlays its own file lines.
function AutoPilot_SessionHistory.getHistory(player, maxN)
    local pnum = _pn(player)
    maxN = maxN or _keep()
    local entries = _collapse(_readRawLines(pnum))
    local sums, byId = {}, {}
    for i = 1, #entries do
        local parsed = AutoPilot_SessionHistory.parseLine(entries[i].raw)
        if parsed then
            table.insert(sums, _withDeltas(parsed))
            byId[parsed.session] = #sums
        end
    end
    -- Live overlay: the current session's freshest values win over any
    -- checkpoint line already flushed for the same id.
    local st = _state[pnum]
    if st ~= nil and st.ticks > 0 then
        local live = _withDeltas({
            schema     = SCHEMA_VERSION,
            session    = st.id,
            player     = pnum,
            ticks      = st.ticks,
            str_start  = st.start.str,  str_end  = st.last.str,
            fit_start  = st.start.fit,  fit_end  = st.last.fit,
            wood_start = st.start.wood, wood_end = st.last.wood,
            doc_start  = st.start.doc,  doc_end  = st.last.doc,
            ended      = st.ended or "open",
        })
        if byId[st.id] then
            sums[byId[st.id]] = live
        else
            table.insert(sums, live)
        end
    end
    table.sort(sums, function(a, b) return a.session > b.session end)
    while #sums > maxN do table.remove(sums) end
    return sums
end

--- Format one summary for the panel: "#3  812t  S+1 F+0 W+2 D+0  dead".
--- A delta whose field pair is absent (older line) renders as "?".
function AutoPilot_SessionHistory.formatSummary(sum)
    local function d(v)
        if type(v) ~= "number" then return "?" end
        return string.format("%+d", v)
    end
    return string.format("#%d  %dt  S%s F%s W%s D%s  %s",
        sum.session, sum.ticks,
        d(sum.dstr), d(sum.dfit), d(sum.dwood), d(sum.ddoc),
        tostring(sum.ended))
end

-- ASCII ramp for the trend sparkline: index = clamped total level gain.
local SPARK_RAMP = { "_", ".", ":", "-", "=", "+", "*", "#" }

--- Render a list of numeric gains as a compact ASCII sparkline.
--- Non-numbers and negatives clamp to the floor; gains past the ramp top
--- clamp to "#".
function AutoPilot_SessionHistory.sparkline(gains)
    local out = {}
    for i = 1, #gains do
        local g = gains[i]
        if type(g) ~= "number" or g < 0 then g = 0 end
        if g > #SPARK_RAMP - 1 then g = #SPARK_RAMP - 1 end
        out[#out + 1] = SPARK_RAMP[g + 1]
    end
    return table.concat(out)
end

local function _totalGain(sum)
    return (sum.dstr or 0) + (sum.dfit or 0) + (sum.dwood or 0)
        + (sum.ddoc or 0)
end

--- Pre-formatted panel strings: up to maxRows session rows (newest first)
--- plus a trend sparkline of total level gains (oldest to newest, across
--- every retained session) when there are at least two sessions.  Returns
--- a placeholder row when nothing is recorded yet, so the UI never has to
--- special-case an empty history.
function AutoPilot_SessionHistory.getPanelLines(player, maxRows)
    maxRows = maxRows or (AutoPilot_Constants
        and AutoPilot_Constants.SESSION_HISTORY_PANEL_ROWS) or 5
    local hist = AutoPilot_SessionHistory.getHistory(player)
    if #hist == 0 then
        return { "(no sessions recorded yet)" }
    end
    local lines = {}
    for i = 1, math.min(#hist, maxRows) do
        table.insert(lines, AutoPilot_SessionHistory.formatSummary(hist[i]))
    end
    if #hist >= 2 then
        local gains = {}
        for i = #hist, 1, -1 do   -- hist is newest first; trend reads old>new
            table.insert(gains, _totalGain(hist[i]))
        end
        table.insert(lines,
            "trend: " .. AutoPilot_SessionHistory.sparkline(gains))
    end
    return lines
end

--- Reset all in-memory state (tests simulate a fresh Lua session, i.e. a
--- game restart; the summaries FILE deliberately survives, that is the
--- module's whole point).
function AutoPilot_SessionHistory.reset()
    _state  = {}
    _nextId = {}
    _begun  = {}
end
