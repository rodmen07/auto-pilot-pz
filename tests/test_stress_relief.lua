-- tests/test_stress_relief.lua
-- V6.3 C2-D4: the Stress moodle is a third trigger for the mood arm, and it
-- unlocks the READ path only.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- Stress was the mod's longest-standing "read but never acted on" signal:
-- AutoPilot_Threat.NEGATIVE_STAT_CHECKS has carried
-- `{ stat = CharacterStat.STRESS, threshold = 0.40 }` since V4, and
-- AutoPilot_Comfort's header states outright that the comfort arm "never
-- references Stress".  The V6.3 audit (PR #117) found the reason the gap looked
-- unfixable was a one-directory search: relief is declared in the ITEM layer,
-- not in Lua.  Re-verified live against the 42.19 install for this increment:
--
--   * 301 vanilla entries carry a negative StressChange across media/scripts,
--     259 of them in scripts/generated/items/literature.txt
--     (`item ComicBook`, literature.txt:1720 -> BoredomChange = -30,
--      StressChange = -20, UnhappyChange = -20).
--   * Literature is consumed by ISReadABook, which AutoPilot_Mood already
--     queues for boredom, and ISReadABook:165 reads CharacterStat.STRESS at
--     action start.
--   * MoodleType.STRESS is a real member: MoodlesUI.getInstance():wiggle(
--     MoodleType.STRESS) at shared/TimedActions/ISReloadWeaponAction.lua:476.
--
-- So the missing piece was a TRIGGER inside an arm the mod already owns, and
-- this suite is the behaviour-difference proof for it:
--
--   ON  (Stress >= STRESS_MOODLE_THRESHOLD, nothing else firing) -> a book is
--       queued where the same character queued NOTHING before this change.
--   OFF (Stress one level below) -> element-for-element what it did before.
--
-- The confinement half matters as much as the trigger, and it is asserted
-- rather than described: a stress-only cycle must not spend food (whose
-- selector ranks by getUnhappyChange, a happiness ranking that says nothing
-- about stress), must not walk to a television (a broadcast relieves stress
-- only when its script happens to carry an Interactions.STS op,
-- shared/RadioCom/ISRadioInteractions.lua:99 -- a property of the programme,
-- not of the device), and must not walk outdoors (that arm is gated on and
-- relieves boredom).  Ranking BY stress magnitude stays deferred (V6.3 D5):
-- item:getStressChange() has zero call sites in the whole 42.19 Lua tree, so
-- mocking it would violate the verified-surface discipline.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_stress_relief.lua

-- ── Load mocks and modules ────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")
dofile("42/media/lua/client/AutoPilot_Utils.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")

-- Mood relief reaches these three; each is a stub so the only variable in a
-- case is the moodle state under test.
AutoPilot_Home = {
    isSet            = function(_player) return false end,
    isInside         = function(_sq) return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

local MEDIA_CALLS = 0
AutoPilot_Media = {
    doMediaRelief = function(_player)
        MEDIA_CALLS = MEDIA_CALLS + 1
        return false, "none"
    end,
}

local LOOT_CALLS = 0
AutoPilot_Inventory = {
    getReadable        = function(_player) return nil end,
    lootNearbyReadable = function(_player) LOOT_CALLS = LOOT_CALLS + 1; return false end,
    preferTastyFood    = function(_player) return nil end,
}

dofile("42/media/lua/client/AutoPilot_Mood.lua")

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

-- ── Fixtures ──────────────────────────────────────────────────────────────────

local STRESS_LEVEL   = AutoPilot_Constants.STRESS_MOODLE_THRESHOLD
local LOW_THRESHOLD  = AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD
local FOOD_PRIORITY  = AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY
local BOREDOM_LIMIT  = AutoPilot_Constants.BOREDOM_THRESHOLD

-- A character whose ONLY mood signal is the one a case sets: boredom sits
-- below its threshold and the Unhappy moodle is clear, so any relief below is
-- attributable to the stress arm and to nothing else.
local function moodPlayer(cfg)
    cfg = cfg or {}
    return MockPlayer.new({
        stats   = { BOREDOM = cfg.boredom or 0 },
        moodles = {
            UNHAPPY = cfg.unhappy or 0,
            STRESS  = cfg.stress  or 0,
        },
        traits  = cfg.traits,
        tooDark = cfg.tooDark,
    })
end

local function book(name)
    return {
        getName             = function(_self) return name end,
        getNumberOfPages    = function(_self) return 100 end,
        getAlreadyReadPages = function(_self) return 0 end,
    }
end

local function cake()
    return {
        getName     = function(_self) return "Cake" end,
        getCalories = function(_self) return 500 end,
    }
end

-- Both relief arms are always AVAILABLE, so which one fires is decided by the
-- gate under test rather than by what the character happens to carry.
local CAPTURED
local function armRelief()
    ISTimedActionQueue_calls = {}
    MEDIA_CALLS = 0
    LOOT_CALLS  = 0
    CAPTURED    = {}
    AutoPilot_Inventory.getReadable     = function(_player) return book("Novel"), nil end
    AutoPilot_Inventory.preferTastyFood = function(_player) return cake(), nil end
    AutoPilot_Telemetry.setDecision =
        function(action, reason, _player, _stage, _fail, _retry)
            table.insert(CAPTURED, { action = action, reason = reason })
        end
end

local function queuedTypes()
    local out = {}
    for _, a in ipairs(ISTimedActionQueue_calls) do
        table.insert(out, a.type or "?")
    end
    return table.concat(out, ",")
end

local function reasonFor(action)
    for _, d in ipairs(CAPTURED) do
        if d.action == action then return d.reason end
    end
    return nil
end

-- ═════════════════════════════════════════════════════════════════════════════
-- Part 1: the behaviour difference, on and off
-- ═════════════════════════════════════════════════════════════════════════════

print("=== Part 1: the stress trigger, on and off ===")

-- ── 1. ON ────────────────────────────────────────────────────────────────────
print("\n-- Test 1: Stress at the threshold queues a read, with nothing else firing")
do
    armRelief()
    local relieved, label = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL }), false)
    assert_true("relief is claimed for a stressed character", relieved)
    assert_eq("the label is the reading one", label, "reading")
    assert_eq("exactly one read action is queued", queuedTypes(), "read")
end

-- ── 2. OFF: the same fixture one level below ─────────────────────────────────
-- This is the control the ON case is meaningless without: the ONLY difference
-- between Test 1 and Test 2 is the moodle level.
print("\n-- Test 2: one level below the threshold, the same character queues nothing")
do
    armRelief()
    local relieved = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL - 1 }), false)
    assert_false("no relief is claimed", relieved)
    assert_eq("nothing at all is queued", queuedTypes(), "")
    assert_eq("no decision is recorded either", #CAPTURED, 0)
end

-- ── 3. The threshold is a real tunable, not a hardcoded 2 ────────────────────
-- Raising the constant must move the gate; if it does not, the constant is
-- decoration and Test 1 proved nothing about it.
print("\n-- Test 3: raising STRESS_MOODLE_THRESHOLD withholds the same relief")
do
    armRelief()
    AutoPilot_Constants.STRESS_MOODLE_THRESHOLD = STRESS_LEVEL + 1
    local relieved = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL }), false)
    AutoPilot_Constants.STRESS_MOODLE_THRESHOLD = STRESS_LEVEL
    assert_false("the level that fired in Test 1 no longer fires", relieved)
    assert_eq("nothing is queued", queuedTypes(), "")
    assert_eq("the constant was restored",
        AutoPilot_Constants.STRESS_MOODLE_THRESHOLD, STRESS_LEVEL)
end

-- ── 4. Above the threshold, not merely at it ─────────────────────────────────
print("\n-- Test 4: a level ABOVE the threshold fires too (>=, not ==)")
do
    armRelief()
    local relieved = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL + 1 }), false)
    assert_true("the higher band still reads", relieved)
    assert_eq("a read is queued", queuedTypes(), "read")
end

-- ═════════════════════════════════════════════════════════════════════════════
-- Part 2: the change is CONFINED to the read arm
-- ═════════════════════════════════════════════════════════════════════════════

print("\n=== Part 2: a stress-only cycle reaches the read arm and nothing else ===")

-- ── 5. No food is spent on stress ────────────────────────────────────────────
-- The teeth are in the configuration: with HAPPINESS_FOOD_PRIORITY lowered
-- below HAPPINESS_LOW_THRESHOLD, an Unhappy level of 1 clears the food gate but
-- not the arm's own entry gate.  Before the `boredOrSad and` guard this cycle
-- would have eaten, which is a food spend keyed on a happiness ranking
-- (preferTastyFood sorts by getUnhappyChange) for a stress problem.
print("\n-- Test 5: a stress-only cycle never spends mood food, even at a lowered food gate")
do
    armRelief()
    AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY = 1
    local relieved, label = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL, unhappy = 1 }), false)
    AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY = FOOD_PRIORITY
    assert_true("relief still happens", relieved)
    assert_eq("it is reading, not eating", label, "reading")
    assert_eq("no eat action was queued", queuedTypes(), "read")
    assert_eq("the constant was restored",
        AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY, FOOD_PRIORITY)
end

-- ── 6. No television, no walk outdoors ───────────────────────────────────────
print("\n-- Test 6: with no book to read, a stress-only cycle stops -- no media, no outdoors")
do
    armRelief()
    AutoPilot_Inventory.getReadable = function(_player) return nil end
    local relieved = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL }), false)
    assert_false("no relief is claimed", relieved)
    assert_eq("the media arm was never consulted", MEDIA_CALLS, 0)
    assert_eq("nothing was queued", queuedTypes(), "")
end

-- ── 7. Looting a book IS allowed (the read arm's own fallback) ───────────────
-- The confinement above is about OTHER arms.  Reading's own walking fallback is
-- part of the arm, so a standing stress-only cycle may still loot one.
print("\n-- Test 7: the read arm's own loot fallback is still reachable on stress")
do
    armRelief()
    AutoPilot_Inventory.getReadable = function(_player) return nil end
    AutoPilot_Mood.doMoodRelief(moodPlayer({ stress = STRESS_LEVEL }), false)
    assert_eq("lootNearbyReadable was reached exactly once", LOOT_CALLS, 1)
end

-- ── 8. Seated (the V5.4 rest hold) ───────────────────────────────────────────
-- The engine sanctions reading while seated (ISRestAction:update, "we can still
-- passively regain endurance and read at the same time"), so a stressed
-- character mid-rest reads a CARRIED book and never stands up to loot one.
print("\n-- Test 8: seated, stress reads a carried book and never loots")
do
    armRelief()
    local relieved, label = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL }), true)
    assert_true("the seated stress cycle reads", relieved)
    assert_eq("the seated label is returned for the HUD", label, "reading")
    assert_eq("a read is queued", queuedTypes(), "read")

    armRelief()
    AutoPilot_Inventory.getReadable = function(_player) return nil end
    local seated = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL }), true)
    assert_false("with nothing carried, the seated cycle declines", seated)
    assert_eq("the sit is never broken to loot a book", LOOT_CALLS, 0)
end

-- ── 9. The illiterate gate still governs ─────────────────────────────────────
print("\n-- Test 9: an illiterate character is not made to read by stress")
do
    armRelief()
    local relieved = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ stress = STRESS_LEVEL, traits = { Illiterate = true } }), false)
    assert_false("no relief is claimed", relieved)
    assert_eq("no read is queued", queuedTypes(), "")
end

-- ═════════════════════════════════════════════════════════════════════════════
-- Part 3: nothing that fired before fires differently now
-- ═════════════════════════════════════════════════════════════════════════════

print("\n=== Part 3: the pre-existing arms are untouched ===")

-- ── 10. Bored, no stress: unchanged all the way down the arm ─────────────────
print("\n-- Test 10: a bored, unstressed character still reads, then media, then outdoors")
do
    armRelief()
    local relieved, label = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ boredom = BOREDOM_LIMIT }), false)
    assert_true("boredom still claims the cycle", relieved)
    assert_eq("it still reads", label, "reading")

    armRelief()
    AutoPilot_Inventory.getReadable = function(_player) return nil end
    AutoPilot_Mood.doMoodRelief(moodPlayer({ boredom = BOREDOM_LIMIT }), false)
    assert_eq("and with no book the media arm is still consulted", MEDIA_CALLS, 1)
end

-- ── 11. Unhappy, no stress: the food arm is untouched ────────────────────────
print("\n-- Test 11: the unhappy food arm behaves exactly as before")
do
    armRelief()
    local relieved, label = AutoPilot_Mood.doMoodRelief(
        moodPlayer({ unhappy = LOW_THRESHOLD }), false)
    assert_true("unhappiness still claims the cycle", relieved)
    assert_eq("mood food is still eaten first", label, "eating")
    assert_eq("the eat action is the one queued", queuedTypes(), "eat")
end

-- ── 12. A contented character is still left alone ────────────────────────────
print("\n-- Test 12: no boredom, no unhappiness, no stress -> the arm declines")
do
    armRelief()
    assert_false("nothing claims the cycle", AutoPilot_Mood.doMoodRelief(moodPlayer({}), false))
    assert_eq("nothing is queued", queuedTypes(), "")
    assert_eq("the media arm is not consulted either", MEDIA_CALLS, 0)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- Part 4: telemetry honesty (the V6.2 C1 rule, applied to stress)
-- ═════════════════════════════════════════════════════════════════════════════

print("\n=== Part 4: 'stress' is recorded only when the stress arm is what fired ===")

-- ── 13. Stress alone -> reason=stress ────────────────────────────────────────
print("\n-- Test 13: a stress-only read records reason=stress")
do
    armRelief()
    AutoPilot_Mood.doMoodRelief(moodPlayer({ stress = STRESS_LEVEL }), false)
    assert_eq("the run log names the trigger the player can see",
        reasonFor("read"), "stress")
end

-- ── 14. Bored AND stressed -> the existing token, unchanged ──────────────────
-- Otherwise this change would silently re-label log lines that already had a
-- correct reason, and every historical comparison over reason=boredom would
-- break for a reason that has nothing to do with stress.
print("\n-- Test 14: bored AND stressed still records reason=boredom")
do
    armRelief()
    AutoPilot_Mood.doMoodRelief(
        moodPlayer({ boredom = BOREDOM_LIMIT, stress = STRESS_LEVEL }), false)
    assert_eq("no existing log line changes meaning", reasonFor("read"), "boredom")
end

-- ── 15. Unhappy AND stressed -> also unchanged ───────────────────────────────
print("\n-- Test 15: unhappy AND stressed keeps the unhappy arm's own decisions")
do
    armRelief()
    AutoPilot_Mood.doMoodRelief(
        moodPlayer({ unhappy = LOW_THRESHOLD, stress = STRESS_LEVEL }), false)
    assert_eq("the eat decision still reads unhappy", reasonFor("eat"), "unhappy")
    assert_eq("no stress-labelled read was recorded", reasonFor("read"), nil)
end

-- ── 16. The label the F11 panel will show ────────────────────────────────────
-- AutoPilot_Main._REASON_LABELS is the panel's mapping table, and
-- tests/test_reason_line.lua's Test 4b fails any emitted reason that is neither
-- mapped there nor explicitly exempted.  This assertion is the local, readable
-- half of that contract: the token this file emits is the token that has a
-- human phrasing.
print("\n-- Test 16: the emitted token is the one the panel maps")
do
    armRelief()
    AutoPilot_Mood.doMoodRelief(moodPlayer({ stress = STRESS_LEVEL }), false)
    assert_eq("the emitted reason token is 'stress'", reasonFor("read"), "stress")
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
