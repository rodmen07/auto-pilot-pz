-- tests/test_stat_scales.lua
-- Scale-drift guard: every production comparison or report of a CharacterStat
-- must use the SCALE that stat is actually measured on in Build 42.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- tests/test_engine_symbols.lua guards that a stat member EXISTS.  This is the
-- other half of the same class, and it is the half that shipped the bug.
--
-- B42 mixes two scales inside one enum.  HUNGER, THIRST, FATIGUE, ENDURANCE,
-- SICKNESS, STRESS and SANITY are 0.0-1.0 fractions; PAIN, PANIC, BOREDOM and
-- WETNESS are 0-100 integers.  player:getStats():get() returns whichever the
-- engine holds, with nothing in the value to say which it was, and
-- AutoPilot_Utils.safeStat passes it straight through.  So a stat read on the
-- wrong scale produces:
--
--   * a gate that can NEVER fire (0-1 value compared to a 0-100 threshold), or
--   * a gate that ALWAYS fires (0-100 value compared to a 0-1 threshold), or
--   * a report that reads 0 forever (math.floor of a 0-1 value).
--
-- None of those crashes, none lints, and none fails a suite whose fixture
-- leaves the stat at 0 -- which is what every fixture did.  Two live instances
-- were found by the 2026-07-26 QA audit and both had been wrong since the B42
-- port:
--
--   * AutoPilot_Threat.NEGATIVE_STAT_CHECKS flagged SICKNESS and STRESS as
--     0-100, so countNegativeMoodles divided an already-fractional value by 100
--     again.  A character at SICKNESS=0.8 scored 0.008 against a 0.20
--     threshold.  Both entries were unreachable; the count could never exceed
--     5 of its 8 entries.  (A third, SANITY, was unreachable for a different
--     reason: it is polarity-inverted, high when healthy, so no >= threshold
--     can express "this is bad".  It was removed, not rescaled.)
--   * AutoPilot_Needs.getMoodleSnapshot reported `sick` and `stressed` as
--     math.floor(value) with no * 100, so both keys read 0 for any character
--     short of the maximum.
--
-- Test 8 of test_threat_logic is the reason this went unseen for so long: its
-- "all stats fine" fixture set SICKNESS/STRESS/SANITY to 0, which passes under
-- either scale.  A fixture that cannot distinguish the two cannot fail on
-- either.  So the guard here is STATIC -- it reads the production source and
-- the recorded scales together -- rather than another fixture.
--
-- The record of scales, with a live-install citation for every entry, is
-- CharacterStatScale in tests/lua_mock_pz.lua.  Adding a CharacterStat member
-- means recording its scale there; this suite fails if a member is modelled
-- without one, so the record cannot quietly fall behind the enum.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_stat_scales.lua

dofile("tests/lua_mock_pz.lua")

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

-- ── Source reading ────────────────────────────────────────────────────────────
-- Same comment-stripping contract as test_engine_symbols: a `--` truncates the
-- rest of its line, so an explanation naming a stat is never read as code.  The
-- worst case is losing a real reference, never inventing one, so this guard
-- errs toward silence rather than toward a false failure.
local function stripComments(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cut = line:find("%-%-")
        out[#out + 1] = cut and line:sub(1, cut - 1) or line
    end
    return table.concat(out, "\n")
end

local function readFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local text = fh:read("*a")
    fh:close()
    return text
end

-- Glob-driven discovery, exactly like ci.yml and test_engine_symbols, so a new
-- module is covered the moment it lands.  Zero matches is a HARD FAILURE below:
-- a guard that passes on an empty input set has gone blind.
local function productionFiles()
    local files = {}
    local pipe = io.popen("ls -1 42/media/lua/client/*.lua")
    if pipe then
        for line in pipe:lines() do
            line = line:gsub("%s+$", "")
            if line ~= "" then files[#files + 1] = line end
        end
        pipe:close()
    end
    return files
end

-- ── Finder 1: threshold-table entries ─────────────────────────────────────────
-- Matches the NEGATIVE_STAT_CHECKS entry shape:
--   { stat = CharacterStat.HUNGER, threshold = 0.40, isNormalized = true },
-- `isNormalized = true` asserts the raw stat is already 0.0-1.0;
-- `isNormalized = false` asserts it is 0-100 and will be divided by 100.
-- Either way the flag is a claim about the ENGINE's scale, so it must equal
-- what CharacterStatScale records.
local ENTRY_PATTERN =
    "{%s*stat%s*=%s*CharacterStat%.([%w_]+)%s*," ..
    "%s*threshold%s*=%s*[%d%.]+%s*," ..
    "%s*isNormalized%s*=%s*(%a+)"

local function findThresholdEntries(text)
    local entries = {}
    for stat, flag in stripComments(text):gmatch(ENTRY_PATTERN) do
        entries[#entries + 1] = { stat = stat, isNormalized = (flag == "true") }
    end
    return entries
end

-- ── Finder 2: percent-report expressions ─────────────────────────────────────
-- getMoodleSnapshot reports every stat as an integer percentage, in two shapes:
--   math.floor(safeStat(p, CharacterStat.X) * 100)  -- X must be 0.0-1.0
--   math.floor(safeStat(p, CharacterStat.X))        -- X must be 0-100
-- The unscaled pattern cannot match a scaled expression: it requires the
-- closing paren immediately after safeStat's, and `* 100` sits between them.
local SCALED_PATTERN =
    "math%.floor%(%s*AutoPilot_Utils%.safeStat%(%s*[%w_]+%s*," ..
    "%s*CharacterStat%.([%w_]+)%s*%)%s*%*%s*100%s*%)"
local UNSCALED_PATTERN =
    "math%.floor%(%s*AutoPilot_Utils%.safeStat%(%s*[%w_]+%s*," ..
    "%s*CharacterStat%.([%w_]+)%s*%)%s*%)"

local function findPercentReports(text)
    local reports = {}
    local code = stripComments(text)
    for stat in code:gmatch(SCALED_PATTERN) do
        reports[#reports + 1] = { stat = stat, scaledBy100 = true }
    end
    for stat in code:gmatch(UNSCALED_PATTERN) do
        reports[#reports + 1] = { stat = stat, scaledBy100 = false }
    end
    return reports
end

-- ── Violation reporting ───────────────────────────────────────────────────────
-- Returns a list of human-readable violation strings for one source text.  An
-- UNRECORDED stat is a violation in its own right: it means the member reached
-- production without anybody establishing which scale the engine keeps it on.
local function violationsIn(text)
    local bad = {}
    for _, e in ipairs(findThresholdEntries(text)) do
        local scale = CharacterStatScale[e.stat]
        if scale == nil then
            bad[#bad + 1] = ("threshold entry reads CharacterStat.%s, which has "
                .. "no recorded scale"):format(e.stat)
        elseif e.isNormalized ~= (scale == "0-1") then
            bad[#bad + 1] = ("threshold entry for CharacterStat.%s says "
                .. "isNormalized=%s but the engine scale is %s"):format(
                e.stat, tostring(e.isNormalized), scale)
        end
    end
    for _, r in ipairs(findPercentReports(text)) do
        local scale = CharacterStatScale[r.stat]
        if scale == nil then
            bad[#bad + 1] = ("percent report reads CharacterStat.%s, which has "
                .. "no recorded scale"):format(r.stat)
        elseif r.scaledBy100 ~= (scale == "0-1") then
            bad[#bad + 1] = ("percent report for CharacterStat.%s %s * 100 but "
                .. "the engine scale is %s"):format(
                r.stat, r.scaledBy100 and "applies" or "omits", scale)
        end
    end
    return bad
end

-- ── 1. The scale record covers the enum, in both directions ──────────────────
print("\n-- Test 1: every modelled CharacterStat member has a recorded scale")
do
    local members, scales = 0, 0
    local missingScale, orphanScale = {}, {}

    for name in pairs(CharacterStat) do
        members = members + 1
        if CharacterStatScale[name] == nil then
            missingScale[#missingScale + 1] = name
        end
    end
    for name, value in pairs(CharacterStatScale) do
        scales = scales + 1
        if CharacterStat[name] == nil then orphanScale[#orphanScale + 1] = name end
        if value ~= "0-1" and value ~= "0-100" then
            orphanScale[#orphanScale + 1] = name .. " (bad value " .. tostring(value) .. ")"
        end
    end

    assert_true(("CharacterStat models members (got %d)"):format(members),
        members > 0)
    assert_true(("CharacterStatScale records scales (got %d)"):format(scales),
        scales > 0)
    for _, name in ipairs(missingScale) do
        io.stderr:write(("    no scale recorded for CharacterStat.%s\n"):format(name))
    end
    assert_eq("every modelled member has a scale", #missingScale, 0)
    for _, name in ipairs(orphanScale) do
        io.stderr:write(("    bad scale record: %s\n"):format(name))
    end
    assert_eq("no scale record is orphaned or malformed", #orphanScale, 0)
end

-- ── 2. The guard can see the code it guards ──────────────────────────────────
print("\n-- Test 2: production sources are discovered and readable")
local files = productionFiles()
assert_true(("at least one production module found (got %d)"):format(#files),
    #files > 0)

local unreadable = {}
local entryCount, reportCount = 0, 0
local allViolations = {}
for _, path in ipairs(files) do
    local text = readFile(path)
    if not text then
        unreadable[#unreadable + 1] = path
    else
        entryCount = entryCount + #findThresholdEntries(text)
        reportCount = reportCount + #findPercentReports(text)
        for _, v in ipairs(violationsIn(text)) do
            allViolations[#allViolations + 1] = ("%s: %s"):format(path, v)
        end
    end
end
assert_eq("every discovered module is readable", #unreadable, 0)

-- Both finders must still match something.  If a refactor changes the shape of
-- either construct, this fails loudly instead of the guard silently checking an
-- empty set -- the failure mode that lets a dead guard look green forever.
assert_true(("threshold-table entries found (got %d)"):format(entryCount),
    entryCount > 0)
assert_true(("percent-report expressions found (got %d)"):format(reportCount),
    reportCount > 0)

-- ── 3. The finding: no production read uses the wrong scale ──────────────────
print("\n-- Test 3: no production code reads a stat on the wrong scale")
if #allViolations > 0 then
    for _, v in ipairs(allViolations) do
        io.stderr:write(("    %s\n"):format(v))
    end
    io.stderr:write(
        "    A stat read on the wrong scale yields a gate that can never fire\n" ..
        "    (0-1 value against a 0-100 threshold), one that always fires, or a\n" ..
        "    report stuck at 0.  It never crashes and never lints.  Check the\n" ..
        "    stat's real scale in the live install and reconcile the code with\n" ..
        "    CharacterStatScale in tests/lua_mock_pz.lua -- correct the SIDE\n" ..
        "    that is wrong, do not just make the two agree.\n")
end
assert_eq("zero wrong-scale stat reads in production code", #allViolations, 0)

-- ── 4. Every guarded construct really is guarded ─────────────────────────────
-- Named checks that the two constructs this suite exists for are present, so
-- deleting one is a deliberate act with a red build rather than a silent loss
-- of coverage.
print("\n-- Test 4: the two known constructs are still under the guard")
do
    local threat = readFile("42/media/lua/client/AutoPilot_Threat.lua")
    local needs  = readFile("42/media/lua/client/AutoPilot_Needs.lua")
    assert_true("AutoPilot_Threat.lua is readable", threat ~= nil)
    assert_true("AutoPilot_Needs.lua is readable", needs ~= nil)

    local entries = threat and findThresholdEntries(threat) or {}
    assert_true(("NEGATIVE_STAT_CHECKS entries are parsed (got %d)"):format(#entries),
        #entries > 0)

    local reports = needs and findPercentReports(needs) or {}
    assert_true(("getMoodleSnapshot percent reports are parsed (got %d)"):format(#reports),
        #reports > 0)

    -- The two stats whose entries were unreachable must now be present AND
    -- flagged as fractional.  This is the regression proof for the fix itself:
    -- it fails if either entry is dropped or flipped back.
    local seen = {}
    for _, e in ipairs(entries) do seen[e.stat] = e.isNormalized end
    assert_eq("SICKNESS is a threshold entry flagged 0-1", seen.SICKNESS, true)
    assert_eq("STRESS is a threshold entry flagged 0-1", seen.STRESS, true)
    assert_eq("PANIC is a threshold entry flagged 0-100", seen.PANIC, false)
    assert_eq("PAIN is a threshold entry flagged 0-100", seen.PAIN, false)
    -- SANITY is polarity-inverted and must NOT come back as a >= entry.  If a
    -- future change reinstates it, it needs a different entry shape and this
    -- assertion should be replaced deliberately, not quietly satisfied.
    assert_eq("SANITY is not a >= threshold entry", seen.SANITY, nil)
end

-- ── 5. The finders fire, and only on a real violation ────────────────────────
-- Always-on negative controls, in CI, on every run.  Both pre-fix spellings are
-- kept here verbatim so the checks above can never pass merely because a finder
-- stopped matching anything.
print("\n-- Test 5: the finders fire on wrong scales and stay silent on right ones")
do
    -- The exact pre-fix NEGATIVE_STAT_CHECKS lines.
    local preFixSick = violationsIn(
        "{ stat = CharacterStat.SICKNESS, threshold = 0.20, isNormalized = false },")
    assert_eq("the pre-fix SICKNESS entry is reported", #preFixSick, 1)

    local preFixStress = violationsIn(
        "{ stat = CharacterStat.STRESS, threshold = 0.40, isNormalized = false },")
    assert_eq("the pre-fix STRESS entry is reported", #preFixStress, 1)

    local fixedSick = violationsIn(
        "{ stat = CharacterStat.SICKNESS, threshold = 0.20, isNormalized = true },")
    assert_eq("the corrected SICKNESS entry is accepted", #fixedSick, 0)

    -- The other direction: a genuinely 0-100 stat mislabelled as fractional.
    local wrongPanic = violationsIn(
        "{ stat = CharacterStat.PANIC, threshold = 0.40, isNormalized = true },")
    assert_eq("a 0-100 stat mislabelled 0-1 is reported", #wrongPanic, 1)

    local rightPanic = violationsIn(
        "{ stat = CharacterStat.PANIC, threshold = 0.40, isNormalized = false },")
    assert_eq("the correct PANIC entry is accepted", #rightPanic, 0)

    -- An unrecorded member is a violation even when the flag looks plausible.
    local unrecorded = violationsIn(
        "{ stat = CharacterStat.MORALE, threshold = 0.40, isNormalized = true },")
    assert_eq("a stat with no recorded scale is reported", #unrecorded, 1)

    -- The exact pre-fix getMoodleSnapshot expressions.
    local preFixReport = violationsIn(
        "sick = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.SICKNESS)),")
    assert_eq("the pre-fix unscaled SICKNESS report is reported", #preFixReport, 1)

    local fixedReport = violationsIn(
        "sick = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.SICKNESS) * 100),")
    assert_eq("the corrected scaled SICKNESS report is accepted", #fixedReport, 0)

    -- And its mirror: a 0-100 stat must NOT be multiplied by 100.
    local overScaled = violationsIn(
        "bored = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM) * 100),")
    assert_eq("a 0-100 stat scaled by 100 is reported", #overScaled, 1)

    local rightReport = violationsIn(
        "bored = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM)),")
    assert_eq("the correct BOREDOM report is accepted", #rightReport, 0)
end

-- ── 6. Comments are not code ─────────────────────────────────────────────────
-- The production files explain these very scales in prose, including the wrong
-- spellings they used to carry.  If those explanations counted as code the
-- guard would fail on its own documentation.
print("\n-- Test 6: stat references inside comments are not treated as code")
do
    local commented = violationsIn(
        "-- { stat = CharacterStat.SICKNESS, threshold = 0.20, isNormalized = false },")
    assert_eq("a full-line comment yields no violation", #commented, 0)

    local trailing = violationsIn(
        "{ stat = CharacterStat.PANIC, threshold = 0.40, isNormalized = false }, " ..
        "-- was CharacterStat.SICKNESS, isNormalized = false")
    assert_eq("a trailing comment yields no violation", #trailing, 0)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
