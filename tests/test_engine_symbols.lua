-- tests/test_engine_symbols.lua
-- Enum-drift guard: every engine enum MEMBER that production code reads must be
-- a member the mock models, and the mock models only names verified against the
-- live Build 42 install.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- Project Zomboid's enum globals (MoodleType, CharacterStat, Perks,
-- CharacterTrait) are Java-bound.  Reading a member that does not exist yields
-- nil rather than an error, and every one of this mod's readers degrades a nil
-- to a harmless zero -- AutoPilot_Needs.safeMoodleLevel returns 0 for a nil
-- moodle type, AutoPilot_Utils.safeStat returns 0 for a nil stat.  So a
-- misspelled member does not crash, does not lint, and does not fail a test.
-- It silently disables whatever gate reads it, forever.
--
-- This mod has now shipped that exact defect twice:
--
--   * doRead gated on player:getPerkLevel(Perks.Literacy).  There is no
--     Literacy skill in 42.19, so the gate never opened and reading -- the
--     mod's main boredom relief -- never fired in-game.  Found 2026-07-25,
--     fixed in PR #77.
--   * doMoodRelief and getMoodleSnapshot read MoodleType.Unhappy.  B42 spells
--     the constant MoodleType.UNHAPPY (engine callsite:
--     shared/TimedActions/ISBaseTimedAction.lua:102), so the unhappy arm of
--     mood relief could never run -- an unhappy-but-not-bored character got no
--     relief at all, and the tasty-food-for-unhappiness path was unreachable.
--     Found 2026-07-25 by the sweep this suite generalises.
--
-- Both were invisible to the existing suites for the SAME reason: the mock
-- defined the wrong name too, so the tests exercised a member that only the
-- tests had.  The fix is not another one-off correction, it is this guard --
-- the mock's enum tables are the repo's record of the verified 42.19 surface,
-- and production may not read a member that record does not contain.
--
-- Adding a member therefore has one cost: verify it against the live install
-- and add it to lua_mock_pz.lua with the engine citation.  Defining it
-- suite-locally instead hides it from this guard, which is why
-- CharacterStat.PANIC/.SICKNESS/.STRESS were moved out of test_threat_logic.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_engine_symbols.lua

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

-- ── The guarded enums ─────────────────────────────────────────────────────────
-- Only value-lookup enums whose members drive a DECISION belong here, and only
-- ones the shared mock models in full.  Fluid / ItemType / ItemTag / UIFont /
-- Keyboard are deliberately absent: they are modelled suite-locally or not at
-- all because their production callsites are pcall-guarded, so the shared mock
-- is not a complete record of them and this guard would report noise.
local GUARDED = { "MoodleType", "CharacterStat", "Perks", "CharacterTrait" }

-- ── Scanner ───────────────────────────────────────────────────────────────────
-- Strips line comments before matching, so the many `-- MoodleType.Unhappy`
-- explanations in the production files (and in this header) are not read as
-- references.  A `--` inside a string literal truncates the rest of that line,
-- which can only LOSE a reference, never invent one: the guard errs toward
-- silence, never toward a false failure.
local function stripComments(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cut = line:find("%-%-")
        out[#out + 1] = cut and line:sub(1, cut - 1) or line
    end
    return table.concat(out, "\n")
end

-- Returns a list of { enum=, member= } for every ENUM.MEMBER reference found.
local function scanReferences(text)
    local found = {}
    local code = stripComments(text)
    for _, enum in ipairs(GUARDED) do
        for member in code:gmatch(enum .. "%.([A-Za-z_][A-Za-z_0-9]*)") do
            found[#found + 1] = { enum = enum, member = member }
        end
    end
    return found
end

-- Returns a list of { enum=, member= } for references the mock does not model.
local function violationsIn(text)
    local bad = {}
    for _, ref in ipairs(scanReferences(text)) do
        if _G[ref.enum][ref.member] == nil then bad[#bad + 1] = ref end
    end
    return bad
end

-- ── Production file discovery ─────────────────────────────────────────────────
-- Glob-driven, exactly like ci.yml's Lua-test discovery, so a new module is
-- covered the moment it is added.  Zero matches is a HARD FAILURE: a guard that
-- passes on an empty input set has gone blind.
local function productionFiles()
    local files = {}
    -- No stderr redirect: `2>/dev/null` is shell syntax that io.popen's Windows
    -- host (cmd.exe) does not understand, and swallowing the error would be the
    -- wrong trade anyway.  If the listing fails the file list comes back empty
    -- and Test 1 fails loudly, which is exactly what a blind guard should do.
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

local function readFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local text = fh:read("*a")
    fh:close()
    return text
end

-- ── 1. The guard can see the code it guards ──────────────────────────────────
print("\n-- Test 1: production modules are discovered")
local files = productionFiles()
assert_true(("at least one production module found (got %d)"):format(#files),
    #files > 0)

local unreadable = {}
local totalRefs = 0
local refsByEnum = {}
for _, enum in ipairs(GUARDED) do refsByEnum[enum] = 0 end

local allViolations = {}
for _, path in ipairs(files) do
    local text = readFile(path)
    if not text then
        unreadable[#unreadable + 1] = path
    else
        for _, ref in ipairs(scanReferences(text)) do
            totalRefs = totalRefs + 1
            refsByEnum[ref.enum] = refsByEnum[ref.enum] + 1
        end
        for _, ref in ipairs(violationsIn(text)) do
            allViolations[#allViolations + 1] =
                ("%s: %s.%s"):format(path, ref.enum, ref.member)
        end
    end
end

assert_eq("every discovered module is readable", #unreadable, 0)
assert_true(("enum references found across the mod (got %d)"):format(totalRefs),
    totalRefs > 0)

-- ── 2. Each guarded enum is actually exercised ───────────────────────────────
-- If production stops referencing a guarded enum entirely, that enum's entry in
-- GUARDED is dead weight and must be removed deliberately rather than left
-- silently checking nothing.
print("\n-- Test 2: every guarded enum is still read by production code")
for _, enum in ipairs(GUARDED) do
    assert_true(("%s is referenced (%d time(s))"):format(enum, refsByEnum[enum]),
        refsByEnum[enum] > 0)
end

-- ── 3. The finding itself: no production read resolves to nil ────────────────
print("\n-- Test 3: no production code reads an enum member the mock does not model")
if #allViolations > 0 then
    for _, v in ipairs(allViolations) do
        io.stderr:write(("    unmodelled member: %s\n"):format(v))
    end
    io.stderr:write(
        "    A member missing from lua_mock_pz.lua is a member this mod has\n" ..
        "    NOT verified against the live 42.19 install.  In-game the lookup\n" ..
        "    yields nil and the gate reading it silently never fires.  Verify\n" ..
        "    the real constant name in the install, then add it to the mock\n" ..
        "    with its engine citation -- do not define it suite-locally.\n")
end
assert_eq("zero unmodelled enum members in production code", #allViolations, 0)

-- ── 4. The scanner is not vacuous ────────────────────────────────────────────
-- A guard nobody has watched fail is not a guard.  These cases prove the
-- scanner both fires on a bad member and stays silent on a good one, in CI, on
-- every run -- so the checks above can never pass merely because the scanner
-- stopped matching anything.
print("\n-- Test 4: the scanner fires on a bad member and only on a bad member")
do
    local bad = violationsIn("local lvl = safeMoodleLevel(p, MoodleType.Unhappy)")
    assert_eq("the pre-fix spelling MoodleType.Unhappy is reported", #bad, 1)
    assert_eq("...and is reported as the member it is", bad[1] and bad[1].member,
        "Unhappy")

    local good = violationsIn("local lvl = safeMoodleLevel(p, MoodleType.UNHAPPY)")
    assert_eq("the engine spelling MoodleType.UNHAPPY is accepted", #good, 0)

    local perk = violationsIn("player:getPerkLevel(Perks.Literacy)")
    assert_eq("the PR #77 defect Perks.Literacy would also be reported", #perk, 1)

    local trait = violationsIn("player:hasTrait(CharacterTrait.ILLITERATE)")
    assert_eq("the real trait CharacterTrait.ILLITERATE is accepted", #trait, 0)

    -- A REAL engine stat the mod does not read, so the mock does not model it.
    -- CharacterStat.ANGER exists in 42.19 (ISStatsAndBody.lua:51) but no
    -- production line references it.  This example used to be
    -- CharacterStat.WETNESS, which stopped being unmodelled when
    -- AutoPilot_Comfort started reading it for the dry-off arm; the control is
    -- worthless unless the named member really is absent from the mock.
    local stat = violationsIn("safeStat(p, CharacterStat.ANGER)")
    assert_eq("an unmodelled stat (CharacterStat.ANGER) is reported", #stat, 1)

    -- ...and the newly-modelled one is now accepted, which is the other half of
    -- the same control: the scanner must not report a member the mock has.
    local wet = violationsIn("safeStat(p, CharacterStat.WETNESS)")
    assert_eq("the now-modelled CharacterStat.WETNESS is accepted", #wet, 0)
end

-- ── 5. Comments are not code ─────────────────────────────────────────────────
print("\n-- Test 5: enum names inside comments are not treated as references")
do
    local commented = violationsIn("-- MoodleType.Unhappy was the old spelling")
    assert_eq("a full-line comment yields no violation", #commented, 0)

    local trailing = violationsIn(
        "local lvl = safeMoodleLevel(p, MoodleType.UNHAPPY)  -- not Perks.Literacy")
    assert_eq("a trailing comment yields no violation", #trailing, 0)

    assert_eq("comment stripping keeps the code half of the line",
        stripComments("x = 1  -- y = MoodleType.Unhappy"), "x = 1  ")
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
