-- tests/test_moodle_triggers.lua
-- V6.2 C1: moodle-aligned hunger/thirst triggers (approved with defaults
-- 2026-08-01, docs/EXPANSION_PROPOSAL_V6_2.md).
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- Before this change the mod reacted to raw HUNGER/THIRST stats only, so its
-- eat/drink timing needed explaining ("why is it not eating? the slider says
-- 0.15") and was welded to a hidden stat scale — the exact defect class that
-- killed the original V6 C1 (a threshold on a scale the author assumed wrong).
-- Now the game's own Hungry/Thirsty moodle (level >= 1) ALSO fires the
-- trigger: the mod reacts to the same signal the player sees on screen.
--
-- The defaults under test, from the proposal:
--   D1  moodle >= 1 OR the tunable stat threshold — a pure widening.  The
--       moodle arm can never make the mod eat/drink LATER than today, and the
--       stat arm keeps precedence AND its reason token.
--   D2  both check() and shouldInterrupt() carry the widening.
--   D3  telemetry honesty: "hunger_moodle"/"thirst_moodle" are recorded ONLY
--       when the moodle arm fired and the stat arm alone would not have.
--
-- MoodleType.HUNGRY and MoodleType.THIRST were verified in the 42.19 jar's
-- constant pool (zombie/scripting/objects/MoodleType.class — neither name
-- exists anywhere in the install's Lua); see the mock's MoodleType note.
--
-- New test logic lives in its own file rather than growing
-- tests/test_priority_logic.lua (preflight C10 flags it at 2600+ lines).
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_moodle_triggers.lua

-- ── Load mocks (same harness shape as tests/test_endurance_band.lua) ──────────
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}

AutoPilot_Medical = {
    hasCriticalWound = function(_player) return false end,
    check            = function(_player, _bleedingOnly) return false end,
}

AutoPilot_Inventory = {
    findWaterSource       = function(_player) return nil end,
    getBestDrink          = function(_player) return nil end,
    lootNearbyDrink       = function(_player) return false end,
    supplyRunLoot         = function(_player, _pred) end,
    getBestFoodForHunger  = function(_player, _hunger) return nil end,
    selectFoodByWeight    = function(_player) return nil end,
    getBestFood           = function(_player) return nil end,
    lootNearbyFood        = function(_player) return false end,
    getReadable           = function(_player) return nil end,
    lootNearbyReadable    = function(_player) return false end,
    adjustClothing        = function(_player) return false end,
    preferTastyFood       = function(_player) return nil end,
    refillWaterContainer  = function(_player, _src) end,
    drinkFromSource       = function(_player, _src) return true end,
    equipBestExerciseItem = function(_player) return "none" end,
    bodyTemperature       = function(_player) return 0 end,
}

dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.iterateNearbySquares = function(_cx, _cy, _cz, _radius, _cb) end

AutoPilot_Home = {
    isSet            = function(_player) return false end,
    isInside         = function(_sq)     return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

dofile("42/media/lua/client/AutoPilot_Consumption.lua")
dofile("42/media/lua/client/AutoPilot_Sleep.lua")
dofile("42/media/lua/client/AutoPilot_Rest.lua")
dofile("42/media/lua/client/AutoPilot_Exercise.lua")
dofile("42/media/lua/client/AutoPilot_Mood.lua")
dofile("42/media/lua/client/AutoPilot_Needs.lua")

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

-- Capture every setDecision call (the stock mock stub discards them).
local captured
local function captureDecisions()
    captured = {}
    AutoPilot_Telemetry.setDecision =
        function(action, reason, _player, stage, fail_reason, _retry)
            table.insert(captured, {
                action = action, reason = reason,
                stage = stage, fail_reason = fail_reason,
            })
        end
end

-- The reason recorded for a given action, or nil when that action never
-- reached setDecision this cycle.  check() records speculative decisions for
-- branches that then decline (wound, clothing, ...), so lookups are by action.
local function reasonFor(action)
    for _, d in ipairs(captured) do
        if d.action == action then return d.reason end
    end
    return nil
end

-- A character whose hunger/thirst state is the ONLY variable: everything else
-- in check()'s chain declines, so any drink/eat decision below is the trigger
-- under test and nothing else.
local function player(cfg)
    return MockPlayer.new({
        stats = {
            HUNGER    = cfg.hunger or 0.02,
            THIRST    = cfg.thirst or 0.02,
            FATIGUE   = 0.02,
            BOREDOM   = 0,
            SANITY    = 0,
            ENDURANCE = 0.95,
        },
        moodles = {
            ENDURANCE = 0,
            UNHAPPY   = 0,
            HUNGRY    = cfg.hungryMoodle or 0,
            THIRST    = cfg.thirstMoodle or 0,
        },
    })
end

local function reset()
    ISTimedActionQueue_calls = {}
    MockTime.advance((AutoPilot_Constants.REST_HOLD_MS or 60000) + 120000)
    AutoPilot_Rest.clearRestHold()
    AutoPilot_Needs.endTrainingRun()
    captureDecisions()
end

print("=== V6.2 C1: moodle-aligned hunger/thirst triggers ===")

-- ── 1. HEADLINE: the moodle alone now triggers, where it used to be ignored ──
print("\n-- Test 1 (HEADLINE): Thirsty moodle 1, stat under the slider ->"
    .. " the mod drinks, and says why")
do
    reset()
    AutoPilot_Needs.check(player({ thirst = 0.02, thirstMoodle = 1 }))
    assert_eq("the drink decision carries the new honest reason",
        reasonFor("drink"), "thirst_moodle")

    -- Pre-change behaviour, for the difference: same character, moodle 0.
    reset()
    AutoPilot_Needs.check(player({ thirst = 0.02, thirstMoodle = 0 }))
    assert_eq("without the moodle the same stats never reach the drink branch",
        reasonFor("drink"), nil)
end

print("\n-- Test 2 (HEADLINE): Hungry moodle 1, stat under the slider ->"
    .. " the mod eats, and says why")
do
    reset()
    AutoPilot_Needs.check(player({ hunger = 0.02, hungryMoodle = 1 }))
    assert_eq("the eat decision carries the new honest reason",
        reasonFor("eat"), "hunger_moodle")

    reset()
    AutoPilot_Needs.check(player({ hunger = 0.02, hungryMoodle = 0 }))
    assert_eq("without the moodle the same stats never reach the eat branch",
        reasonFor("eat"), nil)
end

-- ── 2. The stat arm is untouched: same trigger, same reason as before ────────
print("\n-- Test 3: at or above the slider nothing changed — same reason"
    .. " token, moodle or not")
do
    reset()
    AutoPilot_Needs.check(player({ thirst = 0.50, thirstMoodle = 0 }))
    assert_eq("stat-triggered drink keeps thirst_thresh (moodle absent)",
        reasonFor("drink"), "thirst_thresh")

    -- D3 honesty in the other direction: when the stat arm fired anyway, the
    -- moodle must NOT relabel the decision — "thirst_moodle" is reserved for
    -- cycles the stat alone would have missed.
    reset()
    AutoPilot_Needs.check(player({ thirst = 0.50, thirstMoodle = 3 }))
    assert_eq("stat-triggered drink keeps thirst_thresh (moodle present)",
        reasonFor("drink"), "thirst_thresh")

    reset()
    AutoPilot_Needs.check(player({ hunger = 0.50, hungryMoodle = 3 }))
    assert_eq("stat-triggered eat keeps hunger_thresh (moodle present)",
        reasonFor("eat"), "hunger_thresh")
end

-- ── 3. D2: shouldInterrupt carries the same widening ─────────────────────────
print("\n-- Test 4: the moodle interrupts an in-progress action, level 0"
    .. " does not")
do
    assert_true("Thirsty moodle 1 interrupts (stat under the slider)",
        AutoPilot_Needs.shouldInterrupt(player({ thirstMoodle = 1 })))
    assert_true("Hungry moodle 1 interrupts (stat under the slider)",
        AutoPilot_Needs.shouldInterrupt(player({ hungryMoodle = 1 })))
    assert_false("neither moodle, stats under the sliders: no interrupt",
        AutoPilot_Needs.shouldInterrupt(player({})))
    assert_true("the stat arm still interrupts on its own (thirst 0.50)",
        AutoPilot_Needs.shouldInterrupt(player({ thirst = 0.50 })))
end

-- ── 4. D1 is a pure widening: moodle 0 changes nothing anywhere ──────────────
print("\n-- Test 5: with both moodles at 0 the calm chain is untouched")
do
    reset()
    local p = player({})
    AutoPilot_Needs.check(p)
    assert_eq("no drink decision on a calm cycle", reasonFor("drink"), nil)
    assert_eq("no eat decision on a calm cycle", reasonFor("eat"), nil)
    -- The cycle still resolves to the chain tail (training), proving the new
    -- arms declined by returning nothing rather than by breaking the chain.
    local last = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_eq("the calm cycle still falls through to training",
        last and last.type, "exercise")
end

-- ── 5. Precedence: the thirst trigger LOSES to a sleepable fatigue ───────────
-- Behavioral pin for the sleep-above-thirst precedence (backlog follow-up
-- opened 2026-08-08 by PR #141).  test_priority_logic.lua Test 4 stages thirst
-- at 0.05, so it proves the sleep path is ENTERED, never that sleep WINS a
-- live contest; test_priority_chain_truth.py binds the PROSE to the source
-- order, so a reorder that also updates the prose ships as "documented".
-- This case stages BOTH needs above their thresholds with canSleepNow true
-- (PAIN and PANIC moodles default to 0), so the sleep branch is TERMINAL —
-- doSleep's result is returned even though the mock cell has no bed — and a
-- regression that moves the fatigue gate below the thirst trigger fails HERE
-- on the CODE, whatever the prose says.  It lives in this suite rather than
-- growing test_priority_logic.lua back over the 1000-line C10 threshold six
-- code-health slices just got it under; the thirst trigger under contest is
-- this suite's subject.
print("\n-- Test 6: fatigue and thirst both live -> sleep wins the contest")
do
    reset()
    -- A drink IS available, so if the thirst branch were reached it would act.
    AutoPilot_Inventory.getBestDrink = function(_player)
        return { getName = function() return "WaterBottle" end }
    end
    local p = MockPlayer.new({
        stats = {
            HUNGER    = 0.02,
            THIRST    = 0.30,   -- above THIRST_THRESHOLD (0.15): a real contest
            FATIGUE   = 0.80,   -- above FATIGUE_THRESHOLD (0.70)
            BOREDOM   = 0,
            SANITY    = 0,
            ENDURANCE = 0.95,
        },
        moodles = { ENDURANCE = 0, UNHAPPY = 0, HUNGRY = 0, THIRST = 0 },
    })
    AutoPilot_Needs.check(p)

    assert_eq("the contested cycle decides sleep for the fatigue reason",
        reasonFor("sleep"), "fatigue_thresh")
    -- Discriminate the WIN from the pain-blocked fall-through, which records
    -- the same action+reason plus a fail_reason and then reaches thirst.
    local sleepFail
    for _, d in ipairs(captured) do
        if d.action == "sleep" then sleepFail = d.fail_reason end
    end
    assert_eq("the sleep decision carries no engine-block fail_reason",
        sleepFail, nil)
    assert_eq("the thirst branch is never reached: no drink decision",
        reasonFor("drink"), nil)
    assert_eq("no action was queued for the drinkable thirst",
        #ISTimedActionQueue_calls, 0)

    -- Restore the stock stub for any case added after this one.
    AutoPilot_Inventory.getBestDrink = function(_player) return nil end
end

-- ── Discomfort coverage (V6.3 C2-D6) ─────────────────────────────────────────
--
-- WHAT THIS PINS.  `docs/architecture.md`'s "Moodle Coverage" section and the
-- README's "The one moodle AutoPilot leaves to you" note both state that the
-- mod does not manage Discomfort.  That is a claim about THIS CODE, and it is
-- the exact shape that went stale before: the identical sentence used to name
-- Stress too, and it stayed in two documents for a day after V6.3 C2-D4 (PR
-- #153) shipped stress relief, because nothing was watching.  The day a
-- Discomfort arm lands, this guard reddens and names the documents to update.
--
-- WHY IT IS LEXED AND NOT GREPPED.  `AutoPilot_Comfort.lua` mentions the token
-- in TWO comments today (the debug-slider step-size table, and the line saying
-- that module is the seam a future Discomfort arm would grow in).  A text scan
-- cannot tell those from an arm, so the naive form of this guard would be red
-- from birth and would then be weakened into uselessness.  Reading the token
-- STREAM from tests/lua_source_scan.lua removes comments and string literals by
-- construction (L-031: a guard that reports garbage gets deleted, so a false
-- positive is as fatal as a false negative).
dofile("tests/lua_source_scan.lua")

--- Client modules, glob-discovered.  A hand list would silently stop covering
-- the next module added, which is precisely when this claim can go wrong.
local function clientModules()
    local files = {}
    -- No `2>/dev/null`: that is shell syntax io.popen's Windows host does not
    -- understand, and an empty list must fail loudly rather than pass quietly.
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

--- Every CODE-position occurrence of `DISCOMFORT` in one source.
-- Comments and strings are gone before this looks, so a hit is a real
-- reference: `CharacterStat.DISCOMFORT` lexes to name/op/name and the trailing
-- name is what matches.
local function discomfortCodeRefs(text, label)
    local hits = {}
    for _, t in ipairs(LuaSourceScan.tokenize(text)) do
        if t.type == "name" and t.value == "DISCOMFORT" then
            hits[#hits + 1] = ("%s:%d"):format(label, t.line)
        end
    end
    return hits
end

do
    local modules = clientModules()

    -- Clause 1: the corpus exists.  Zero matches means the module tree moved
    -- and every clause below would pass by seeing nothing.
    assert_true("the client-module glob finds modules at all (zero = blind guard)",
        #modules > 0)

    -- Clause 2: the load-bearing claim.  Its own case, because clause 3's red
    -- must never stand in for this one (L-072).
    local codeRefs, rawFiles = {}, {}
    for _, path in ipairs(modules) do
        local text = readFile(path)
        if text then
            local base = path:match("[^/]+$") or path
            for _, hit in ipairs(discomfortCodeRefs(text, base)) do
                codeRefs[#codeRefs + 1] = hit
            end
            if text:find("DISCOMFORT", 1, true) then
                rawFiles[#rawFiles + 1] = base
            end
        end
    end
    assert_eq("no client module references DISCOMFORT in code -- if this is red, "
        .. "a Discomfort arm shipped: update docs/architecture.md 'Moodle Coverage' "
        .. "and README.md's 'The one moodle AutoPilot leaves to you' in the same PR",
        table.concat(codeRefs, ","), "")

    -- Clause 3: the committed control (L-033 shape).  The CHEAP claim -- "grep
    -- finds no DISCOMFORT in the client tree" -- is FALSE today, and that is
    -- the point: a text-matching guard would be satisfied by prose, so the
    -- lexer is what makes clause 2 mean anything.  If this ever goes red the
    -- comments were removed and clause 2 is no longer proving the lexer earns
    -- its place; re-point this control at whatever prose replaced them, or
    -- retire both together.
    assert_true("the RAW text still contains DISCOMFORT somewhere (the phantom that "
        .. "makes clause 2 non-trivial), got: " .. table.concat(rawFiles, ","),
        #rawFiles > 0)
end

-- The detector proved against synthetic input, one case per shape the language
-- allows (L-069/L-072), so a failure names the shape that broke.  Only the last
-- of these is a reference; the first four are the phantoms a regex would take.
do
    local shapes = {
        { name = "a -- line comment naming CharacterStat.DISCOMFORT",
          src  = "-- CharacterStat.DISCOMFORT is only a debug slider\nlocal x = 1\n",
          want = 0 },
        { name = "a --[[ block ]] comment naming it",
          src  = "--[[ reads CharacterStat.DISCOMFORT ]] local x = 1\n",
          want = 0 },
        { name = "a --[==[ long ]==] comment naming it",
          src  = "--[==[ DISCOMFORT ]] still inside ]==] local x = 1\n",
          want = 0 },
        { name = "a string literal containing it",
          src  = "local label = \"DISCOMFORT\"\nlocal other = 'DISCOMFORT'\n",
          want = 0 },
        { name = "a real reference in code",
          src  = "local v = getStat(CharacterStat.DISCOMFORT)\n",
          want = 1 },
    }
    for _, s in ipairs(shapes) do
        assert_eq("Discomfort detector: " .. s.name,
            #discomfortCodeRefs(s.src, "synthetic"), s.want)
    end
end

-- ── Summary ──────────────────────────────────────────────────────────────────
print(("\n=== MoodleTriggers: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
