-- tests/test_clock_discipline.lua
-- Clock-discipline guard: every time-source call in shipped client Lua must be
-- DELIBERATELY classified, because this mod runs on two clocks that disagree by
-- orders of magnitude and has shipped mixed-clock defects three times.
--
-- THE TWO CLOCKS
-- --------------
--   REAL  getTimestampMs()                          wall-clock epoch ms (2026)
--   GAME  getGameTime():getCalender():getTimeInMillis()
--                                                   in-game calendar epoch ms
--                                                   (July 1993, advances ~24x
--                                                   real at the default 1-hour
--                                                   day length, 5/20/40x more
--                                                   under fast-forward, and
--                                                   JUMPS ~8 hours on sleep)
--
-- A duration constant written against the wrong clock is not slightly wrong,
-- it is ~24x wrong at 1x speed and ~1000x wrong at 40x fast-forward.  This
-- repo's shipped instances of the class:
--
--   * FF-1 (fixed PR #70): the decision cadence counted real frames, so the
--     mod made 5-40x fewer decisions per unit of GAME time under fast-forward.
--   * FF-4 (fixed PR #109): the XP/hr window measured real ms, so the F11
--     rate and ETA inflated with game speed.
--   * V5.4 (fixed in AutoPilot_Rest): the rest hold was `ms + 60000` against
--     the GAME calendar -- sixty in-game seconds, ~2.5 real seconds -- so the
--     character stood back up having recovered nothing.
--
-- The 2026-07-24 fast-forward investigation confirmed FF-1..4 but its broad
-- clock-mix sweep errored out, leaving a recorded GAP ("timing issues beyond
-- FF-1..4 were not exhaustively swept").  The 2026-08-06 QA sweep closed that
-- gap: every time-source call site in 42/media/lua/client/ was read and
-- classified, and this suite pins the classification so the NEXT clock call
-- cannot land unclassified.  Adding a time-source call now has one cost:
-- decide which clock it needs, and record that decision in the table below.
--
-- Discovery is GLOB-DRIVEN with a zero-match hard failure, like
-- tests/test_engine_symbols.lua and test_reason_line.lua: a module that does
-- not exist yet is still discovered the day it lands, and an empty file list
-- fails loudly instead of passing quietly.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_clock_discipline.lua

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

local function assert_true(desc, val) assert_eq(desc, not not val, true) end

-- ── Discovery (glob-driven, zero-match hard failure) ──────────────────────────
local function productionFiles()
    local files = {}
    -- No stderr redirect: `2>/dev/null` is shell syntax that io.popen's Windows
    -- host (cmd.exe) does not understand, and swallowing the error would be the
    -- wrong trade anyway -- an empty list must fail loudly, not pass quietly.
    local pipe = io.popen("ls -1 42/media/lua/client/*.lua")
    if pipe then
        for line in pipe:lines() do
            line = line:gsub("%s+$", "")
            if line ~= "" then files[#files + 1] = line end
        end
        pipe:close()
    end
    table.sort(files)
    return files
end

local function readFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local text = fh:read("*a")
    fh:close()
    return text
end

-- Comments are not code (same discipline as test_engine_symbols.lua): several
-- modules NAME clock functions in prose (AutoPilot_XP's verified-surface
-- header, AutoPilot_Main's fast-forward note) without calling them there.
local function stripComments(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cut = line:find("%-%-")
        out[#out + 1] = cut and line:sub(1, cut - 1) or line
    end
    return table.concat(out, "\n")
end

-- ── The scanner ───────────────────────────────────────────────────────────────
-- Kinds a call site can be classified as.  MULTIPLIER covers BOTH
-- getGameTime():getMultiplier() (game speed) and player:getXp():getMultiplier()
-- (skill books): neither is a timestamp, and the discipline point for both is
-- the same -- a multiplier scales a duration, it never replaces a clock.
local KIND_PATTERNS = {
    REAL_MS     = "getTimestampMs",
    GAME_CAL_MS = "getCalender%s*%(%s*%)%s*:%s*getTimeInMillis",
    GAME_HOURS  = "getHoursSurvived",
    MULTIPLIER  = "getMultiplier",
}

-- os.time/os.clock/os.date are PROHIBITED in shipped client Lua outright: they
-- always read the real clock, they are invisible to the engine's pcall-guarded
-- availability pattern, and their arithmetic mixes silently with game-calendar
-- ms.  (Test files may use them freely; this suite scans 42/ only.)
local PROHIBITED_PATTERNS = {
    ["os.time"]  = "[^%w_%.]os%.time%s*%(",
    ["os.clock"] = "[^%w_%.]os%.clock%s*%(",
    ["os.date"]  = "[^%w_%.]os%.date%s*%(",
}

-- Returns (kinds, prohibited): kinds maps kind -> occurrence count in the
-- comment-stripped text; prohibited maps name -> count.
local function scanClocks(text)
    local code = "\n" .. stripComments(text)
    local kinds, prohibited = {}, {}
    for kind, pat in pairs(KIND_PATTERNS) do
        local n = 0
        for _ in code:gmatch(pat) do n = n + 1 end
        if n > 0 then kinds[kind] = n end
    end
    for name, pat in pairs(PROHIBITED_PATTERNS) do
        local n = 0
        for _ in code:gmatch(pat) do n = n + 1 end
        if n > 0 then prohibited[name] = n end
    end
    return kinds, prohibited
end

-- ── The classification (the 2026-08-06 sweep's verdict, one entry per module
--    that reads a clock; a module absent here must read no clock at all) ──────
-- Each entry records WHICH clock the module is allowed to read and WHY that
-- clock is the right one.  Findings the sweep filed (not fixed here -- this is
-- the record, the ## Bugs section holds the open items) are cited inline.
local CLASSIFICATION = {
    ["AutoPilot_Consumption.lua"] = {
        GAME_CAL_MS = "drinkCooldownMs re-queue guard; game-time by design "
            .. "(sweep finding: 8000/5000 game-ms expire faster than one "
            .. "decision cycle at default day length -- filed LOW)",
    },
    ["AutoPilot_DeathLog.lua"] = {
        GAME_HOURS = "death snapshots record survived GAME hours; real time "
            .. "would be meaningless across sessions",
    },
    ["AutoPilot_Exercise.lua"] = {
        GAME_CAL_MS = "V4.5 intervention backoff window + 30s-of-game-time "
            .. "log throttle; the manual exercise it defers to also runs on "
            .. "game time",
    },
    ["AutoPilot_Leveler.lua"] = {
        GAME_CAL_MS = "in-game weekday for the training program; the ONLY "
            .. "verified calendar surface (see getWeekday's doc block)",
    },
    ["AutoPilot_Main.lua"] = {
        REAL_MS = "same-frame duplicate-handler dedupe; real ms is correct "
            .. "here and the FF investigation REFUTED the false-skip "
            .. "hypothesis (2026-07-24 record)",
        MULTIPLIER = "FF-1 fix: tickCounter advances by game speed so the "
            .. "decision cadence tracks game time",
    },
    ["AutoPilot_Media.lua"] = {
        GAME_CAL_MS = "queue cooldown + stall backoff, documented as game "
            .. "time at the state declarations; media progress is game-time "
            .. "coupled",
    },
    ["AutoPilot_Needs.lua"] = {
        GAME_CAL_MS = "reads the rest-hold seam clock (same clock as "
            .. "AutoPilot_Rest, deliberately)",
    },
    ["AutoPilot_Rest.lua"] = {
        GAME_CAL_MS = "rest hold; the V5.4 comment documents the game-time "
            .. "choice and check() releases on recovery, not the timer",
    },
    ["AutoPilot_Sleep.lua"] = {
        GAME_CAL_MS = "pain-blocked sleep retry delay (sweep finding: the "
            .. "'delaying sleep for 60s' print means 60 GAME seconds, ~2.5 "
            .. "real seconds at default day length -- filed LOW)",
    },
    ["AutoPilot_Telemetry.lua"] = {
        GAME_CAL_MS = "end-marker timestamp field (sweep finding: same JSON "
            .. "field is written by automate.py from real time.time(), a "
            .. "1993-vs-2026 epoch mismatch no reader currently compares -- "
            .. "filed LOW)",
        MULTIPLIER = "FF-2 fix: the speed field records actual game speed",
    },
    ["AutoPilot_XP.lua"] = {
        REAL_MS = "rolling-window sample times; PR #109 scales elapsed real "
            .. "ms by game speed so the rate is game-time honest",
        GAME_CAL_MS = "last-resort _nowMs fallback (sweep finding: a "
            .. "mid-session flip would mix 1993-epoch and 2026-epoch samples "
            .. "until the window flushes -- filed LOW)",
        MULTIPLIER = "FF-4 fix (game speed) + the skill-book multiplier read, "
            .. "both scale durations and neither is a timestamp",
    },
}

-- ── 1. Discovery and scanner blindness guards ─────────────────────────────────
print("\n-- Test 1: discovery finds the modules and the scanner finds the clocks")
local files = productionFiles()
do
    -- Zero-match HARD FAILURE: an empty ls is a broken glob or a moved tree,
    -- never a clean result.
    assert_true(("glob discovery found modules (got %d, need >= 20)")
        :format(#files), #files >= 20)

    -- Aggregate token PRESENCE (no file pinned, per the L-031 discipline): if
    -- the scanner stops seeing clocks that provably exist, the guard has gone
    -- blind and must say so rather than reporting clean.
    local sawReal, sawGame = 0, 0
    for _, path in ipairs(files) do
        local text = readFile(path)
        if text then
            local kinds = scanClocks(text)
            sawReal = sawReal + (kinds.REAL_MS or 0)
            sawGame = sawGame + (kinds.GAME_CAL_MS or 0)
        end
    end
    assert_true("the scanner sees at least one REAL_MS site somewhere",
        sawReal >= 1)
    assert_true("the scanner sees at least one GAME_CAL_MS site somewhere",
        sawGame >= 1)
end

-- ── 2. Forward: every discovered clock call is classified ─────────────────────
print("\n-- Test 2: every time-source call site is deliberately classified")
do
    local unclassified = {}
    for _, path in ipairs(files) do
        local base = path:match("([^/]+)$") or path
        local text = readFile(path)
        if text then
            local kinds = scanClocks(text)
            for kind in pairs(kinds) do
                local entry = CLASSIFICATION[base]
                if not (entry and entry[kind]) then
                    unclassified[#unclassified + 1] = base .. " :: " .. kind
                end
            end
        end
    end
    table.sort(unclassified)
    assert_eq("no unclassified clock call sites (each new one must pick its "
        .. "clock in CLASSIFICATION, with the reason)",
        table.concat(unclassified, ", "), "")
end

-- ── 3. Reverse: every classification entry still matches real code ────────────
print("\n-- Test 3: no stale classification entries (the table cannot rot)")
do
    local discovered = {}
    for _, path in ipairs(files) do
        local base = path:match("([^/]+)$") or path
        local text = readFile(path)
        if text then
            local kinds = scanClocks(text)
            for kind in pairs(kinds) do
                discovered[base .. "::" .. kind] = true
            end
        end
    end
    local stale = {}
    for base, entry in pairs(CLASSIFICATION) do
        for kind in pairs(entry) do
            if not discovered[base .. "::" .. kind] then
                stale[#stale + 1] = base .. " :: " .. kind
            end
        end
    end
    table.sort(stale)
    assert_eq("no stale classification entries (delete the entry when the "
        .. "call site goes away)", table.concat(stale, ", "), "")
end

-- ── 4. Prohibition: os.time/os.clock/os.date never in shipped client Lua ──────
print("\n-- Test 4: os.time/os.clock/os.date appear nowhere in mod code")
do
    local hits = {}
    for _, path in ipairs(files) do
        local base = path:match("([^/]+)$") or path
        local text = readFile(path)
        if text then
            local _, prohibited = scanClocks(text)
            for name in pairs(prohibited) do
                hits[#hits + 1] = base .. " :: " .. name
            end
        end
    end
    table.sort(hits)
    assert_eq("no prohibited real-clock stdlib call in 42/media/lua/client/",
        table.concat(hits, ", "), "")
end

-- ── 5. Scanner self-controls (the guard can both fire and stay silent) ────────
print("\n-- Test 5: scanner controls on synthetic input")
do
    -- A comment naming a clock is not a call site.
    local kinds = scanClocks("-- getTimestampMs is documented here, not called")
    assert_eq("a comment-only mention yields no kind", next(kinds), nil)

    -- A real call is seen, and as the right kind.
    kinds = scanClocks("local ok, ms = pcall(getTimestampMs)")
    assert_eq("a REAL_MS call is seen", kinds.REAL_MS, 1)

    kinds = scanClocks("return getGameTime():getCalender():getTimeInMillis()")
    assert_eq("a GAME_CAL_MS call is seen", kinds.GAME_CAL_MS, 1)

    -- The prohibition fires on a call...
    local _, prohibited = scanClocks("local t = os.time()")
    assert_eq("os.time() is reported prohibited", prohibited["os.time"], 1)

    -- ...does not fire on a lookalike identifier...
    _, prohibited = scanClocks("local t = photos.time()")
    assert_eq("a lookalike (photos.time) is not reported",
        prohibited["os.time"], nil)

    -- ...and does not fire on a comment.
    _, prohibited = scanClocks("-- never use os.time() in mod code")
    assert_eq("a commented os.time() is not reported",
        prohibited["os.time"], nil)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
