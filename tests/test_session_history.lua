-- tests/test_session_history.lua
-- V4.2 (expansion candidate C5) suite: the AutoPilot_SessionHistory data
-- layer that persists per-session summaries to auto_pilot_sessions.log and
-- serves the F11 panel's history block as pre-formatted strings.
--
-- Covers: summary write + parse round-trip, checkpoint cadence and
-- collapse-on-read, rotation/retention (newest KEEP survive, malformed and
-- duplicate lines dropped), parser tolerance, per-perk delta computation,
-- panel-line formatting + trend sparkline, and the Telemetry integration
-- (logTick observes, onDeath/onShutdown finalize), all through the mock's
-- append-counting getFileWriter, so append-vs-truncate discipline is
-- asserted (normal writes NEVER truncate; only the once-per-session
-- rotation rewrite may).
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_session_history.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

AutoPilot_Utils = {
    EPSILON = 0.001,
    safeStat = function(player, charStat)
        local ok, val = pcall(function() return player:getStats():get(charStat) end)
        if ok and type(val) == "number" then return val end
        return 0
    end,
    findNearestSquare    = function(...) return nil end,
    iterateNearbySquares = function(...) end,
}

dofile("42/media/lua/client/AutoPilot_Map.lua")
dofile("42/media/lua/client/AutoPilot_Home.lua")
dofile("42/media/lua/client/AutoPilot_SessionHistory.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")

local SESSIONS_FILE = "auto_pilot_sessions.log"
local CHECKPOINT = AutoPilot_Constants.SESSION_HISTORY_CHECKPOINT_CYCLES
local KEEP       = AutoPilot_Constants.SESSION_HISTORY_KEEP

-- ── Minimal test framework ────────────────────────────────────────────────────
local PASS = 0
local FAIL = 0

local function assert_eq(desc, got, expected)
    if got == expected then
        print(("  PASS  %s"):format(desc))
        PASS = PASS + 1
    else
        io.stderr:write(("  FAIL  %s  (got=%s, expected=%s)\n"):format(
            desc, tostring(got), tostring(expected)))
        FAIL = FAIL + 1
    end
end
local function assert_true(desc, val)  assert_eq(desc, not not val, true)  end
local function assert_false(desc, val) assert_eq(desc, not not val, false) end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function makePlayer(perks)
    return MockPlayer.new({
        playerNum = 0,
        stats = { HUNGER = 0.10, THIRST = 0.05, ENDURANCE = 0.90, FATIGUE = 0.10 },
        perks = perks or { Strength = 1, Fitness = 2, Woodwork = 0, Doctor = 0 },
    })
end

local function statsFor(str, fit, wood, doc)
    return { str = str, fit = fit, wood = wood, doc = doc }
end

-- Fresh module state + fresh file: simulates a brand-new install.
local function freshInstall()
    MockFiles[SESSIONS_FILE] = nil
    AutoPilot_SessionHistory.reset()
end

-- Fresh module state, file kept: simulates a game restart (new Lua state).
local function restartGame()
    AutoPilot_SessionHistory.reset()
end

local function fileLines()
    local f = MockFiles[SESSIONS_FILE]
    return (f and f.lines) or {}
end

local function fileTruncates()
    local f = MockFiles[SESSIONS_FILE]
    return (f and f.truncates) or 0
end

-- ── Test 1: header + first checkpoint write/parse round-trip ─────────────────
print("=== SessionHistory Test 1: header + checkpoint write/parse round-trip ===")
do
    freshInstall()
    local p = makePlayer()
    for _ = 1, CHECKPOINT do
        AutoPilot_SessionHistory.observe(p, statsFor(1, 2, 0, 0))
    end
    local lines = fileLines()
    assert_eq("file holds header + one checkpoint line", #lines, 2)
    assert_true("line 1 is the versioned header",
        tostring(lines[1]):find("# auto_pilot_sessions schema=1", 1, true) ~= nil)
    local parsed = AutoPilot_SessionHistory.parseLine(lines[2])
    assert_true("checkpoint line parses", parsed ~= nil)
    assert_eq("parsed session id", parsed.session, 1)
    assert_eq("parsed ticks", parsed.ticks, CHECKPOINT)
    assert_eq("parsed str_start", parsed.str_start, 1)
    assert_eq("parsed fit_end", parsed.fit_end, 2)
    assert_eq("parsed ended is open (checkpoint)", parsed.ended, "open")
    assert_eq("no truncate on a fresh file (append discipline)",
        fileTruncates(), 0)
end

-- ── Test 2: checkpoint cadence + latest-line-wins collapse ───────────────────
print("\n=== SessionHistory Test 2: checkpoint cadence + collapse on read ===")
do
    freshInstall()
    local p = makePlayer()
    for i = 1, CHECKPOINT * 2 do
        -- Levels move mid-session; the collapse must serve the newest values.
        local fit = (i > CHECKPOINT) and 3 or 2
        AutoPilot_SessionHistory.observe(p, statsFor(1, fit, 0, 0))
    end
    assert_eq("two checkpoint lines after two intervals",
        #fileLines(), 3)  -- header + 2
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("collapse yields ONE session", #hist, 1)
    assert_eq("latest checkpoint wins (ticks)", hist[1].ticks, CHECKPOINT * 2)
    assert_eq("latest checkpoint wins (fit_end)", hist[1].fit_end, 3)
    assert_eq("still zero truncates (appends only)", fileTruncates(), 0)
end

-- ── Test 3: finalize on death; idempotent against a later shutdown ───────────
print("\n=== SessionHistory Test 3: finalize (dead) + idempotence ===")
do
    freshInstall()
    local p = makePlayer()
    for _ = 1, 10 do
        AutoPilot_SessionHistory.observe(p, statsFor(1, 2, 0, 1))
    end
    local wrote = AutoPilot_SessionHistory.finalize(p, "dead")
    assert_true("finalize returns true on the first call", wrote)
    local linesAfter = #fileLines()
    local wrote2 = AutoPilot_SessionHistory.finalize(p, "timeout")
    assert_false("second finalize is a no-op (returns false)", wrote2)
    assert_eq("second finalize wrote no line", #fileLines(), linesAfter)
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("history has one session", #hist, 1)
    assert_eq("ended stays dead (timeout cannot override)", hist[1].ended, "dead")
    assert_eq("ticks recorded", hist[1].ticks, 10)
end

-- ── Test 4: death starts a NEW session on the next observe ───────────────────
print("\n=== SessionHistory Test 4: respawn after death begins session id+1 ===")
do
    freshInstall()
    local p = makePlayer()
    AutoPilot_SessionHistory.observe(p, statsFor(1, 1, 0, 0))
    AutoPilot_SessionHistory.finalize(p, "dead")
    AutoPilot_SessionHistory.observe(p, statsFor(0, 0, 0, 0))
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("two sessions in history", #hist, 2)
    assert_eq("newest first: live session id 2", hist[1].session, 2)
    assert_eq("live session is open", hist[1].ended, "open")
    assert_eq("previous session id 1 ended dead", hist[2].ended, "dead")
end

-- ── Test 5: per-perk deltas ──────────────────────────────────────────────────
print("\n=== SessionHistory Test 5: STR/FIT/WOOD/DOC delta computation ===")
do
    freshInstall()
    local p = makePlayer()
    AutoPilot_SessionHistory.observe(p, statsFor(1, 2, 0, 1))
    AutoPilot_SessionHistory.observe(p, statsFor(2, 4, 1, 1))
    AutoPilot_SessionHistory.finalize(p, "timeout")
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("dstr = end - start", hist[1].dstr, 1)
    assert_eq("dfit = end - start", hist[1].dfit, 2)
    assert_eq("dwood = end - start", hist[1].dwood, 1)
    assert_eq("ddoc = end - start", hist[1].ddoc, 0)
    assert_eq("ended timeout", hist[1].ended, "timeout")
end

-- ── Test 6: parser tolerance ─────────────────────────────────────────────────
print("\n=== SessionHistory Test 6: tolerant parser ===")
do
    local P = AutoPilot_SessionHistory.parseLine
    assert_eq("nil input -> nil", P(nil), nil)
    assert_eq("empty string -> nil", P(""), nil)
    assert_eq("header/comment line -> nil", P("# auto_pilot_sessions schema=1"), nil)
    assert_eq("garbage without key=value -> nil", P("total garbage"), nil)
    assert_eq("non-numeric session id -> nil",
        P("schema=1,session=abc,ticks=5,ended=open"), nil)
    assert_eq("missing ended -> nil", P("schema=1,session=3,ticks=5"), nil)
    local old = P("schema=1,session=7,player=0,ticks=42,"
        .. "str_start=1,str_end=2,fit_start=1,fit_end=1,ended=dead")
    assert_true("older line missing wood/doc pairs still parses", old ~= nil)
    assert_eq("known fields coerce to numbers", old.ticks, 42)
    local future = P("schema=2,session=9,ticks=5,ended=open,"
        .. "sets=12,hours_survived=30")
    assert_true("future additive fields are tolerated", future ~= nil)
    assert_eq("unknown additive field preserved", future.sets, 12)
end

-- ── Test 7: formatSummary + missing-pair degradation ─────────────────────────
print("\n=== SessionHistory Test 7: panel summary formatting ===")
do
    local F = AutoPilot_SessionHistory.formatSummary
    local line = F({ session = 3, ticks = 812, dstr = 1, dfit = 0,
                     dwood = 2, ddoc = 0, ended = "dead" })
    assert_eq("full summary line", line, "#3  812t  S+1 F+0 W+2 D+0  dead")
    local degraded = F({ session = 7, ticks = 42, dstr = 1, dfit = 0,
                         ended = "dead" })
    assert_eq("absent delta pairs render as ? (old lines)",
        degraded, "#7  42t  S+1 F+0 W? D?  dead")
end

-- ── Test 8: sparkline ────────────────────────────────────────────────────────
print("\n=== SessionHistory Test 8: trend sparkline ===")
do
    local S = AutoPilot_SessionHistory.sparkline
    assert_eq("gain ramp 0..7", S({0, 1, 2, 3, 4, 5, 6, 7}), "_.:-=+*#")
    assert_eq("clamps above the ramp top", S({99}), "#")
    assert_eq("clamps negatives and non-numbers to the floor",
        S({-3, "x"}), "__")
    assert_eq("empty gains -> empty string", S({}), "")
end

-- ── Test 9: rotation (restart collapses + retains newest KEEP) ───────────────
print("\n=== SessionHistory Test 9: rotation keeps newest KEEP, drops junk ===")
do
    freshInstall()
    -- Build a dirty file: header, KEEP+5 sessions (with a stale duplicate
    -- checkpoint for one of them) and one malformed line.
    local f = { "# auto_pilot_sessions schema=1" }
    for id = 1, KEEP + 5 do
        table.insert(f, string.format(
            "schema=1,session=%d,player=0,ticks=100,str_start=0,str_end=1,"
            .. "fit_start=0,fit_end=1,wood_start=0,wood_end=0,"
            .. "doc_start=0,doc_end=0,ended=timeout", id))
    end
    table.insert(f, "corrupted line with no fields")
    table.insert(f,
        "schema=1,session=2,player=0,ticks=999,str_start=0,str_end=3,"
        .. "fit_start=0,fit_end=1,wood_start=0,wood_end=0,"
        .. "doc_start=0,doc_end=0,ended=dead")
    MockFiles[SESSIONS_FILE] = { lines = f, appends = 0, truncates = 0 }

    restartGame()
    local p = makePlayer()
    AutoPilot_SessionHistory.observe(p, statsFor(0, 0, 0, 0))

    local lines = fileLines()
    assert_eq("rotation rewrote exactly once", fileTruncates(), 1)
    assert_eq("file bounded to header + KEEP lines", #lines, KEEP + 1)
    assert_true("header survives rotation",
        tostring(lines[1]):find("schema=1", 1, true) ~= nil)
    local oldest = AutoPilot_SessionHistory.parseLine(lines[2])
    assert_eq("oldest retained session is id 6 (newest KEEP kept)",
        oldest and oldest.session, 6)
    for i = 2, #lines do
        local parsed = AutoPilot_SessionHistory.parseLine(lines[i])
        assert_true("rotated line " .. i .. " parses (junk dropped)",
            parsed ~= nil)
    end
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("new live session takes the next id (KEEP+6)",
        hist[1].session, KEEP + 6)
end

-- ── Test 10: no rewrite when the file is already clean ───────────────────────
print("\n=== SessionHistory Test 10: clean file is never truncated ===")
do
    freshInstall()
    local p = makePlayer()
    AutoPilot_SessionHistory.observe(p, statsFor(0, 0, 0, 0))
    AutoPilot_SessionHistory.finalize(p, "timeout")

    restartGame()
    AutoPilot_SessionHistory.observe(p, statsFor(0, 0, 0, 0))
    assert_eq("no truncate across restart with a clean small file",
        fileTruncates(), 0)
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("both sessions visible", #hist, 2)
end

-- ── Test 11: getPanelLines (rows + trend, placeholder when empty) ────────────
print("\n=== SessionHistory Test 11: pre-formatted panel lines ===")
do
    freshInstall()
    local p = makePlayer()
    local empty = AutoPilot_SessionHistory.getPanelLines(p, 5)
    assert_eq("placeholder when nothing recorded",
        empty[1], "(no sessions recorded yet)")

    -- Three finished sessions with rising gains, then a live one.
    for s = 1, 3 do
        AutoPilot_SessionHistory.observe(p, statsFor(0, 0, 0, 0))
        AutoPilot_SessionHistory.observe(p, statsFor(s, 0, 0, 0))
        AutoPilot_SessionHistory.finalize(p, "timeout")
        restartGame()
    end
    AutoPilot_SessionHistory.observe(p, statsFor(0, 0, 0, 0))

    local lines = AutoPilot_SessionHistory.getPanelLines(p, 2)
    -- 2 session rows (cap) + 1 trend row.
    assert_eq("row cap respected (+ trend line)", #lines, 3)
    assert_eq("newest session first", lines[1], "#4  1t  S+0 F+0 W+0 D+0  open")
    assert_eq("second row is session 3", lines[2], "#3  2t  S+3 F+0 W+0 D+0  timeout")
    assert_eq("trend spans ALL sessions oldest to newest",
        lines[3], "trend: .:-_")
end

-- ── Test 12: Telemetry integration (logTick observes, ends finalize) ─────────
print("\n=== SessionHistory Test 12: Telemetry drives the data layer ===")
do
    freshInstall()
    MockFiles["auto_pilot_run.log"] = nil
    local p = makePlayer({ Strength = 2, Fitness = 3, Woodwork = 1, Doctor = 0 })
    AutoPilot_Telemetry.logTick(p, "exercise", "training")
    AutoPilot_Telemetry.logTick(p, "idle", "no_action")
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("logTick fed observe (2 cycles)", hist[1].ticks, 2)
    assert_eq("perk levels flow from Telemetry's stat collection",
        hist[1].fit_start, 3)

    AutoPilot_Telemetry.onDeath(p)
    hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("onDeath finalized the session", hist[1].ended, "dead")
    assert_eq("the death tick itself was counted", hist[1].ticks, 3)

    local sessionLines = #fileLines()
    AutoPilot_Telemetry.onShutdown(p)
    assert_eq("onShutdown after death adds no session line",
        #fileLines(), sessionLines)
    local last = AutoPilot_SessionHistory.parseLine(
        fileLines()[sessionLines])
    assert_eq("file's final summary says dead", last and last.ended, "dead")
end

-- ── Test 13: shutdown-only session (clean exit) ──────────────────────────────
print("\n=== SessionHistory Test 13: clean shutdown finalizes as timeout ===")
do
    freshInstall()
    MockFiles["auto_pilot_run.log"] = nil
    AutoPilot_SessionHistory.reset()
    local p = makePlayer()
    AutoPilot_Telemetry.logTick(p, "exercise", "training")
    AutoPilot_Telemetry.onShutdown(p)
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("session ended timeout", hist[1].ended, "timeout")
    assert_true("summary line present in the file",
        #fileLines() >= 2)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
