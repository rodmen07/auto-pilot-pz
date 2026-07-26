-- tests/test_session_xp.lua
-- Regression suite for the HIGH observability bug filed 2026-07-26 from a
-- real in-game session: "the mod's own success metric is unmeasurable".
--
-- auto_pilot_sessions.log recorded perk LEVELS only.  PZ levels move rarely,
-- so across all fourteen sessions ever recorded the file read "str 5->5,
-- fit 3/4->4" — a session that trained for forty minutes and one that never
-- moved produced byte-identical progress fields.  Schema 3 adds the raw XP
-- totals behind those levels.
--
-- What this suite pins, and why each assertion can fail:
--   1. XP survives the real writer and the real parser (format and parser
--      are two artifacts that must agree, so both are read here: the raw
--      file text AND the parsed table).
--   2. THE BEHAVIOR DIFFERENCE: two sessions identical in every level field
--      are distinguishable when one gained XP.  Under the old format they
--      were not, and the level assertions in that test prove the old view
--      really was blind rather than merely coarse.
--   3. The panel row's compact XP formatting across magnitudes, including
--      the sub-1.0 gain that a truncating "%d" would have shown as "+0".
--   4. Telemetry actually reads player:getXp():getXP(perk) and the value
--      reaches the summary (the wiring, not just the data layer).
--   5. Schema 1/2 lines already on disk still parse and degrade to "?".
--   6. The trend sparkline is no longer flat-by-construction when XP moves
--      and levels do not.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_session_xp.lua

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

local function makePlayer(perks, xp)
    return MockPlayer.new({
        playerNum = 0,
        stats = { HUNGER = 0.10, THIRST = 0.05, ENDURANCE = 0.90, FATIGUE = 0.10 },
        perks = perks or { Strength = 5, Fitness = 3, Doctor = 0 },
        xp    = xp    or {},
    })
end

-- One cycle's collected stats, in the shape AutoPilot_Telemetry hands to
-- AutoPilot_SessionHistory.observe.
local function stats(str, fit, doc, strXp, fitXp, docXp)
    return {
        str = str, fit = fit, doc = doc,
        str_xp = strXp, fit_xp = fitXp, doc_xp = docXp,
    }
end

local function freshInstall()
    MockFiles[SESSIONS_FILE] = nil
    AutoPilot_SessionHistory.reset()
end

local function restartGame()
    AutoPilot_SessionHistory.reset()
end

local function fileLines()
    local f = MockFiles[SESSIONS_FILE]
    return (f and f.lines) or {}
end

-- Record one complete session: a start cycle, an end cycle, then finalize,
-- then a fresh Lua state so the next one gets its own id.
local function recordSession(p, startStats, endStats, ended)
    AutoPilot_SessionHistory.observe(p, startStats)
    AutoPilot_SessionHistory.observe(p, endStats)
    AutoPilot_SessionHistory.finalize(p, ended or "timeout")
    restartGame()
end

-- ── Test 1: XP round-trips the real writer and the real parser ───────────────
print("=== SessionXP Test 1: raw XP survives write + parse ===")
do
    freshInstall()
    local p = makePlayer()
    recordSession(p,
        stats(5, 3, 0, 1000,   220,  0),
        stats(5, 3, 0, 1430.5, 220.5, 3))

    local lines = fileLines()
    local final = lines[#lines]
    -- Read the FILE TEXT, so the "%.1f" contract is pinned and not merely
    -- round-tripped through the module's own parser.
    assert_true("line carries the strength XP pair verbatim",
        tostring(final):find("str_xp_start=1000.0,str_xp_end=1430.5", 1, true) ~= nil)
    assert_true("line carries the fitness XP pair verbatim",
        tostring(final):find("fit_xp_start=220.0,fit_xp_end=220.5", 1, true) ~= nil)
    assert_true("line carries the doctor XP pair verbatim",
        tostring(final):find("doc_xp_start=0.0,doc_xp_end=3.0", 1, true) ~= nil)
    assert_true("the line declares schema 3",
        tostring(final):find("schema=3,", 1, true) ~= nil)

    local parsed = AutoPilot_SessionHistory.parseLine(final)
    assert_true("the finalized line parses", parsed ~= nil)
    assert_eq("str_xp_start coerces to a number", parsed.str_xp_start, 1000)
    assert_eq("str_xp_end keeps its fraction", parsed.str_xp_end, 1430.5)
    assert_eq("levels are untouched by the XP fields", parsed.str_end, 5)
end

-- ── Test 2: the behavior difference the bug is about ─────────────────────────
-- A session that trained and one that idled are IDENTICAL in every level
-- field.  This is the assertion that fails if the XP pairs are removed.
print("\n=== SessionXP Test 2: trained vs idle, identical at level scale ===")
do
    freshInstall()
    local p = makePlayer()
    -- Session 1: forty minutes of exercise, no level crossed.
    recordSession(p,
        stats(5, 3, 0, 1000, 220, 0),
        stats(5, 3, 0, 1430.5, 265, 0))
    -- Session 2: the character sat still.
    recordSession(p,
        stats(5, 3, 0, 1430.5, 265, 0),
        stats(5, 3, 0, 1430.5, 265, 0))

    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("both sessions recorded", #hist, 2)
    local idle, trained = hist[1], hist[2]   -- newest first

    -- The old view: every level delta is zero for BOTH, which is exactly why
    -- the metric was unreadable.
    assert_eq("trained session moved no level (str)", trained.dstr, 0)
    assert_eq("trained session moved no level (fit)", trained.dfit, 0)
    assert_eq("idle session moved no level (str)", idle.dstr, 0)
    assert_eq("idle session moved no level (fit)", idle.dfit, 0)

    -- The new view separates them.
    assert_eq("trained session shows its strength XP", trained.dstrXp, 430.5)
    assert_eq("trained session shows its fitness XP", trained.dfitXp, 45)
    assert_eq("idle session shows zero strength XP", idle.dstrXp, 0)
    assert_eq("idle session shows zero fitness XP", idle.dfitXp, 0)

    local rowTrained = AutoPilot_SessionHistory.formatSummary(trained)
    local rowIdle    = AutoPilot_SessionHistory.formatSummary(idle)
    assert_false("the two panel rows are no longer interchangeable",
        rowTrained:gsub("^#%d+  ", "") == rowIdle:gsub("^#%d+  ", ""))
    assert_true("the trained row names its XP gain",
        rowTrained:find("S+431", 1, true) ~= nil)
    assert_true("the idle row still reads zero",
        rowIdle:find("S+0(+0)", 1, true) ~= nil)
end

-- ── Test 3: compact XP formatting across magnitudes ──────────────────────────
print("\n=== SessionXP Test 3: panel XP formatting matrix ===")
do
    local F = AutoPilot_SessionHistory.formatSummary
    local function row(strXp)
        return F({ session = 1, ticks = 10, dstr = 0, dfit = 0, ddoc = 0,
                   dstrXp = strXp, dfitXp = 0, ddocXp = 0, ended = "timeout" })
    end
    assert_true("hundreds render whole", row(430):find("S+430(", 1, true) ~= nil)
    assert_true("thousands collapse to k",
        row(12500):find("S+12.5k(", 1, true) ~= nil)
    assert_true("exactly 1000 collapses to k",
        row(1000):find("S+1.0k(", 1, true) ~= nil)
    -- The reason the file keeps a decimal: a short session earns fractions
    -- of a point, and "%d" truncation would report it as nothing at all.
    assert_true("sub-1.0 gains stay visible",
        row(0.6):find("S+0.6(", 1, true) ~= nil)
    assert_true("a true zero reads zero", row(0):find("S+0(", 1, true) ~= nil)
    assert_true("XP loss (defensive) keeps its sign",
        row(-5):find("S-5(", 1, true) ~= nil)
    assert_true("an absent XP delta degrades to ?",
        F({ session = 1, ticks = 10, dstr = 0, dfit = 0, ddoc = 0,
            ended = "timeout" }):find("S?(+0)", 1, true) ~= nil)
end

-- ── Test 4: Telemetry reads the engine XP surface ────────────────────────────
-- Proves the wiring, not just the data layer: the value has to come out of
-- player:getXp():getXP(Perks.X) and land in the summary.
print("\n=== SessionXP Test 4: logTick feeds engine XP into the summary ===")
do
    freshInstall()
    MockFiles["auto_pilot_run.log"] = nil
    local p = makePlayer({ Strength = 5, Fitness = 3, Doctor = 1 },
                         { [Perks.Strength] = 1000, [Perks.Fitness] = 220,
                           [Perks.Doctor] = 7 })
    AutoPilot_Telemetry.logTick(p, "exercise", "training")
    -- The engine grants XP; the mock's store is mutable exactly for this.
    p._xp[Perks.Strength] = 1430.5
    p._xp[Perks.Fitness]  = 265
    AutoPilot_Telemetry.logTick(p, "exercise", "training")

    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("session baseline is the first tick's XP",
        hist[1].str_xp_start, 1000)
    assert_eq("session end tracks the latest XP", hist[1].str_xp_end, 1430.5)
    assert_eq("strength gain is visible through Telemetry",
        hist[1].dstrXp, 430.5)
    assert_eq("fitness gain is visible through Telemetry",
        hist[1].dfitXp, 45)
    assert_eq("an untrained perk reports no gain", hist[1].ddocXp, 0)
    assert_eq("the doctor XP baseline still came from the engine",
        hist[1].doc_xp_start, 7)

    -- The run log is a different file with its own schema and must NOT have
    -- moved: this fix is confined to the session summary.
    local runLog = MockFiles["auto_pilot_run.log"]
    local runLine = runLog and runLog.lines and runLog.lines[#runLog.lines]
    assert_true("run log still declares schema_version=5",
        tostring(runLine):find("schema_version=5,", 1, true) ~= nil)
    assert_false("run log carries no XP fields",
        tostring(runLine):find("str_xp", 1, true) ~= nil)
end

-- ── Test 5: files already on disk keep working ───────────────────────────────
print("\n=== SessionXP Test 5: schema 1/2 lines still parse and degrade ===")
do
    local P = AutoPilot_SessionHistory.parseLine
    local old = P("schema=2,session=4,player=0,ticks=900,"
        .. "str_start=5,str_end=5,fit_start=3,fit_end=4,"
        .. "doc_start=0,doc_end=0,ended=timeout")
    assert_true("a real pre-XP line still parses", old ~= nil)
    assert_eq("its level fields are intact", old.fit_end, 4)
    assert_eq("it carries no XP field", old.str_xp_start, nil)

    freshInstall()
    MockFiles[SESSIONS_FILE] = {
        lines = {
            "# auto_pilot_sessions schema=2",
            "schema=2,session=4,player=0,ticks=900,"
            .. "str_start=5,str_end=5,fit_start=3,fit_end=4,"
            .. "doc_start=0,doc_end=0,ended=timeout",
        },
        appends = 0, truncates = 0,
    }
    local p = makePlayer()
    local hist = AutoPilot_SessionHistory.getHistory(p)
    assert_eq("the legacy session is served", #hist, 1)
    assert_eq("its missing XP delta is nil, not zero", hist[1].dstrXp, nil)
    assert_true("its panel row degrades to ? rather than lying",
        AutoPilot_SessionHistory.formatSummary(hist[1])
            :find("S?(+0)", 1, true) ~= nil)
end

-- ── Test 6: the trend line is no longer flat by construction ─────────────────
print("\n=== SessionXP Test 6: trend reflects XP when levels never move ===")
do
    freshInstall()
    local p = makePlayer()
    -- Three sessions, no level ever crossed, rising XP: 100, 200, 400.
    recordSession(p, stats(5, 3, 0, 0,   0, 0), stats(5, 3, 0, 100, 0, 0))
    recordSession(p, stats(5, 3, 0, 100, 0, 0), stats(5, 3, 0, 300, 0, 0))
    recordSession(p, stats(5, 3, 0, 300, 0, 0), stats(5, 3, 0, 700, 0, 0))

    local lines = AutoPilot_SessionHistory.getPanelLines(p, 5)
    local trend = lines[#lines]
    -- Gains 100/200/400 scale RELATIVE to the best (400) onto the 0..7 ramp
    -- as 2/4/7, i.e. ":", "=", "#".  Under the old level-only total every
    -- one of these sessions scored 0 and the line read "trend: ___".
    assert_eq("trend rises with XP", trend, "trend: :=#")
    assert_false("trend is not the all-floor line",
        trend == "trend: ___")

    -- A window where genuinely nothing was earned still reads all-floor, so
    -- the relative scale cannot manufacture progress out of nothing.
    freshInstall()
    local q = makePlayer()
    recordSession(q, stats(5, 3, 0, 0, 0, 0), stats(5, 3, 0, 0, 0, 0))
    recordSession(q, stats(5, 3, 0, 0, 0, 0), stats(5, 3, 0, 0, 0, 0))
    local idleLines = AutoPilot_SessionHistory.getPanelLines(q, 5)
    assert_eq("an idle window stays on the floor",
        idleLines[#idleLines], "trend: __")
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== SessionXP: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
