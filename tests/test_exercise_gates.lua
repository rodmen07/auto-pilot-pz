-- tests/test_exercise_gates.lua
-- V5.7 trainer-state suite: the per-character daily sets counter (V5.7-1..3)
-- and the two live-read endurance gates with the sit/resume boundary
-- (V5.7-4..6).
--
-- Moved VERBATIM out of tests/test_priority_logic.lua (code-health split,
-- 2026-08-07): that file had grown to 2,626 lines, and the V5.7 block was a
-- self-contained 407-line unit.  Test bodies are unchanged; only this header,
-- and the bootstrap/helpers each standalone suite carries by repo convention
-- (mock loads, stubs, mini-framework, and the furniture/endurance helpers),
-- are copied alongside.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_exercise_gates.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants (no PZ deps; 'C' sorts first so safe to load stand-alone) ─
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Stub dependency modules ───────────────────────────────────────────────────
-- These modules are used by AutoPilot_Needs.lua. We replace them with minimal
-- stubs that the tests can reconfigure per case.

-- V4.9: Needs moves an item out of a sub-container before using it.
ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}

-- Internal state flag; tests flip _bleeding to simulate wounds.
AutoPilot_Medical = {
    _bleeding = false,

    hasCriticalWound = function(player)
        return AutoPilot_Medical._bleeding
    end,

    check = function(player, _bleedingOnly)
        if AutoPilot_Medical._bleeding then
            -- Mirror the real module's side-effect: queue a bandage action.
            table.insert(ISTimedActionQueue_calls, { type = "bandage" })
            return true
        end
        return false
    end,
}

-- Inventory stubs — tests override individual functions per case.
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
}

-- Real Utils (V4.5: the intervention detector and the ownership registry
-- under test live there); square iteration is a no-op in tests (getCell()
-- returns a stub whose squares are all nil).
dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.iterateNearbySquares = function(_cx, _cy, _cz, _radius, _callback) end

AutoPilot_Home = {
    isSet        = function(_player) return false end,
    isInside     = function(_sq)     return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

-- Real Consumption (doEat/doDrink moved here in the 2026-07-20 code-health
-- split; AutoPilot_Needs.check/forceEat/forceDrink now call into it).
dofile("42/media/lua/client/AutoPilot_Consumption.lua")

-- Real Sleep (doSleep moved here in the same split's second slice;
-- AutoPilot_Needs.check/forceSleep now call into it).
dofile("42/media/lua/client/AutoPilot_Sleep.lua")

-- Real Rest (doRest moved here in the same split's third slice, after a
-- prior increment gave restCooldownMs a seam so check()'s V5.4 rest-hold
-- gate could call across the module boundary; AutoPilot_Needs.check/
-- forceRest/seatPriorityForSprite now call into it).
dofile("42/media/lua/client/AutoPilot_Rest.lua")

-- AutoPilot_Exercise.lua: doExercise and the trainer state (code-health
-- split, 2026-07-20, fourth slice). Unlike doRest, no separate seam PR was
-- needed -- check()'s three touch points (syncSetsCounter, isInTrainingRun,
-- enduranceResumeGate) were already named functions before the move, not
-- bare variable reads.
dofile("42/media/lua/client/AutoPilot_Exercise.lua")

-- ── Load the module under test ────────────────────────────────────────────────
-- Loader plumbing only (code-health split, 2026-08-01): doMoodRelief and its
-- two private arms moved out of AutoPilot_Needs into AutoPilot_Mood.  No test
-- case, stub or assertion below changed.
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

local function assert_true(desc, val)
    assert_eq(desc, not not val, true)
end

local function assert_false(desc, val)
    assert_eq(desc, not not val, false)
end

-- Reset shared state between test cases.
local function reset()
    ISTimedActionQueue_calls = {}
    AutoPilot_Medical._bleeding = false
    -- Advance the mock clock well past any active cooldowns (rest: 60 s,
    -- sleep: 15 s) so a stale cooldownMs from a previous test cannot block
    -- the next one.  restCooldownMs / sleepCooldownMs are locals in
    -- AutoPilot_Needs.lua; they are bounded by the mock clock value.
    MockTime.advance(120000)
    -- Restore inventory stubs that individual tests may have replaced.
    AutoPilot_Inventory.findWaterSource    = function(_player) return nil end
    AutoPilot_Inventory.getBestDrink       = function(_player) return nil end
    AutoPilot_Inventory.lootNearbyDrink    = function(_player) return false end
    AutoPilot_Inventory.getBestFoodForHunger = function(_player, _hunger) return nil end
    AutoPilot_Inventory.selectFoodByWeight = function(_player) return nil end
    AutoPilot_Inventory.getBestFood        = function(_player) return nil end
    AutoPilot_Inventory.lootNearbyFood     = function(_player) return false end
    AutoPilot_Inventory.bodyTemperature    = function(_player) return 0 end
end

local function makeArray(items)
    return {
        size = function(self) return #items end,
        get = function(self, i) return items[i + 1] end,
    }
end

-- Return the action-type string of the last item queued, or nil.
local function last_action_type()
    local c = ISTimedActionQueue_calls
    if #c == 0 then return nil end
    return c[#c].type
end

local FULL_SET_MS = AutoPilot_Constants.EXERCISE_MINUTES * 60000

local function exercisePlayer()
    return MockPlayer.new({
        stats   = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
                    ENDURANCE = 0.90 },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
    })
end

--- Run one productive set: a full-length set that actually gained XP, which
--- is what the XP-productivity gate wants to see before allowing the next.
local function productiveSet(p, gain)
    MockTime.advance(FULL_SET_MS)
    p._xp.Fitness = (p._xp.Fitness or 0) + (gain or 12)
    return AutoPilot_Needs.trainExercise(p, "fitness")
end

-- Restore the suite's default no-op iteration after a furniture case.
local function noFurniture()
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, _callback) end
end

-- Clear any rest hold left by an earlier case.  reset() only advances two
-- game minutes, which no longer clears the V5.4 hold.
local function resetRest()
    reset()
    MockTime.advance((AutoPilot_Constants.REST_HOLD_MS or 60000) + 60000)
    noFurniture()
    AutoPilot_Home.isInside = function(_sq) return false end
end

-- A world object whose sprite carries a name and, optionally, the bed flag.
local function mockFurniture(spriteName, isBed, sq, seatData)
    local sprite = {
        getName = function(_self) return spriteName end,
        getProperties = function(_self)
            return {
                has = function(_p, flag)
                    return isBed == true and flag == IsoFlagType.bed
                end,
            }
        end,
    }
    return {
        getSprite = function(_self) return sprite end,
        getSquare = function(_self) return sq end,
        -- SeatingManager sit-position count (see the SeatingManager mock).
        -- Default 1 (sittable); a test passes seatData=false for a dining chair
        -- the engine has no sit data for, so the character would rest standing.
        _seatData = (seatData == false) and 0 or 1,
    }
end

-- Publish one square holding the named furniture at offset (dx, dy).
local function placeFurniture(specs)
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, cb)
            for _, spec in ipairs(specs) do
                local sq = {}
                local obj = mockFurniture(spec.sprite, spec.bed, sq, spec.seatData)
                sq.getObjects = function(_self) return makeArray({ obj }) end
                sq.getX = function(_self) return spec.dx or 0 end
                sq.getY = function(_self) return spec.dy or 0 end
                sq.getZ = function(_self) return 0 end
                sq.isOutside = function(_self) return false end
                if cb(sq, spec.dx or 0, spec.dy or 0) then return end
            end
        end
end

-- V5.7: ONE character whose endurance can be driven up and down.
--
-- A training run belongs to a player OBJECT (same ownership rule as the V4.5
-- `who` guards), so a test that builds a fresh MockPlayer for every endurance
-- level is testing a fresh CHARACTER every time and can never observe a run
-- continuing.  MockPlayer closes over the stats table it is given, so writing
-- through that table moves the live stat.
local function drivenPlayer(endurance, moodle)
    local stats = { HUNGER = 0.02, THIRST = 0.02, FATIGUE = 0.02,
                    ENDURANCE = endurance }
    local p = MockPlayer.new({
        stats   = stats,
        moodles = { ENDURANCE = moodle or 0, UNHAPPY = 0 },
    })
    p.setEndurance = function(_self, e) stats.ENDURANCE = e end
    return p
end

-- One COMPLETED, productive set at a given endurance, on the same character:
-- the shape of a real training run.  Advancing a full set length matters for
-- two reasons beyond realism -- an instant re-queue reads as a player cancel
-- (V4.5) and would trigger the backoff, and a set that gains no XP reads as
-- diminishing returns (V3.2) and would fatigue the exercise.
local function repAt(p, endurance)
    MockTime.advance(AutoPilot_Constants.EXERCISE_MINUTES * 60000)
    p._xp.Fitness = (p._xp.Fitness or 0) + 12
    p:setEndurance(endurance)
    return AutoPilot_Needs.trainExercise(p, "fitness")
end

-- A character whose only problem is endurance.
local function windedPlayer(endurance, moodle)
    return MockPlayer.new({
        stats = {
            HUNGER    = 0.02,
            THIRST    = 0.02,
            FATIGUE   = 0.02,
            ENDURANCE = endurance,
        },
        moodles = { ENDURANCE = moodle or 0, UNHAPPY = 0 },
    })
end

-- ══ V5.7 ═════════════════════════════════════════════════════════════════════

print("\n-- Test V5.7-1: the set counter resets for a NEW CHARACTER")
do
    -- User report: "when starting a new character, the number of sets
    -- completed should reset".  The F11 panel opened on "Sets today: 150 (no
    -- cap)" for a survivor who had never trained, because the count keyed off
    -- the in-game day alone and module state outlives a death.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0

    local dead = exercisePlayer()
    AutoPilot_Needs.syncSetsCounterForTest(dead)
    assert_eq("a fresh character starts on zero",
        AutoPilot_Needs.getExerciseSetsToday(), 0)

    -- Put a real, non-zero total on the board for this character.
    assert_true("first set queues", AutoPilot_Needs.trainExercise(dead, "fitness"))
    for _ = 1, 4 do productiveSet(dead) end
    local carried = AutoPilot_Needs.getExerciseSetsToday()
    assert_eq("five sets counted for the first character", carried, 5)

    -- SAME character, SAME day, another cycle: the count must NOT reset, or
    -- the daily cap and the panel become meaningless.
    AutoPilot_Needs.syncSetsCounterForTest(dead)
    assert_eq("a same-character mid-day tick does not reset the count",
        AutoPilot_Needs.getExerciseSetsToday(), carried)
    AutoPilot_Needs.check(dead)
    assert_true("...not even through the full check() chain",
        AutoPilot_Needs.getExerciseSetsToday() >= carried)

    -- The character dies and the player starts a new one.  Same Lua session,
    -- same in-game day, same player number: a NEW player object is the only
    -- signal that anything changed, and it is the same signal the V4.5 `who`
    -- guards already key off.
    local reborn = exercisePlayer()
    assert_true("the respawn really is a different player object",
        reborn ~= dead)
    AutoPilot_Needs.syncSetsCounterForTest(reborn)
    assert_eq("a new character starts on zero sets, same day or not",
        AutoPilot_Needs.getExerciseSetsToday(), 0)
    assert_eq("the F11 panel agrees",
        AutoPilot_Needs.getExerciseStatus().setsToday, 0)
    assert_eq("...and says so in words, with no carried-over total",
        AutoPilot_Needs.getExerciseStatus().setsLine, "Sets today: 0 (no cap)")
end

print("\n-- Test V5.7-2: check() performs the reset even when exercise never runs")
do
    -- doExercise is the LAST step in the chain.  A new character with an
    -- urgent need would never reach it, so the reset also rides the top of
    -- check() -- otherwise the panel keeps showing the dead character's total
    -- for as long as the new one stays busy.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    local trained = exercisePlayer()
    AutoPilot_Needs.syncSetsCounterForTest(trained)
    assert_true("a set queues", AutoPilot_Needs.trainExercise(trained, "fitness"))
    assert_true("the counter is non-zero before the death",
        AutoPilot_Needs.getExerciseSetsToday() > 0)

    -- The new character is parched: check() returns on the thirst branch long
    -- before it ever reaches training.
    local thirsty = MockPlayer.new({
        stats   = { HUNGER = 0.02, THIRST = 0.95, FATIGUE = 0.02,
                    ENDURANCE = 1.00 },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
    })
    AutoPilot_Needs.check(thirsty)
    assert_eq("the count resets on the very first cycle after a respawn",
        AutoPilot_Needs.getExerciseSetsToday(), 0)
end

print("\n-- Test V5.7-3: the day rollover still resets, for the SAME character")
do
    -- The original Phase 2 behaviour must survive the new guard.  getDay() is
    -- pinned at 1 in the mock, so the rollover is driven directly.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    local p = exercisePlayer()
    AutoPilot_Needs.syncSetsCounterForTest(p)
    assert_true("a set queues", AutoPilot_Needs.trainExercise(p, "fitness"))
    local before = AutoPilot_Needs.getExerciseSetsToday()
    assert_true("the counter moved", before > 0)

    local realGetDay = GameTime.getInstance().getDay
    GameTime.getInstance().getDay = function(_self) return 2 end
    AutoPilot_Needs.syncSetsCounterForTest(p)
    assert_eq("a new in-game day zeroes the same character's count",
        AutoPilot_Needs.getExerciseSetsToday(), 0)
    -- ...and the SAME day does not do it twice.
    AutoPilot_Needs.trainExercise(p, "fitness")
    local midDay = AutoPilot_Needs.getExerciseSetsToday()
    AutoPilot_Needs.syncSetsCounterForTest(p)
    assert_eq("a second tick on the same day leaves the count alone",
        AutoPilot_Needs.getExerciseSetsToday(), midDay)
    GameTime.getInstance().getDay = realGetDay
end

print("\n-- Test V5.7-4: TWO endurance gates, both LIVE-READ")
do
    -- Before V5.7 two constants gated exercise: a live-read one the slider
    -- wrote (0.30) and a FILE-LOCAL copy of a second, transposed-name one
    -- (0.50).  Being a load-time copy the second could not be moved by any
    -- options save, and being the larger it floored the first, so the
    -- slider's whole range did nothing.  Both halves of the replacement pair
    -- must be drivable at runtime with no reload.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    local savedR = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    local savedF = AutoPilot_Constants.EXERCISE_ENDURANCE_MIN

    -- 40% endurance, no run in progress: refused at the shipped 90% resume.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.90
    AutoPilot_Needs.endTrainingRun()
    assert_false("40% endurance cannot START a run at a 90% resume gate",
        AutoPilot_Needs.trainExercise(windedPlayer(0.40), "fitness"))

    -- An options save drops the resume gate to 30%.  No reload, no re-dofile:
    -- the very next call must honour it.  Under the old code this stayed
    -- refused, because the 0.50 file-local was still in the way.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.30
    AutoPilot_Needs.resetInterventionForTest()
    assert_true("the same 40% character starts once resume drops to 30%",
        AutoPilot_Needs.trainExercise(windedPlayer(0.40), "fitness"))

    -- And the FLOOR is live-read too, on the other side of the hysteresis.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.30
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = 0.10
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    local runner = drivenPlayer(0.50)
    assert_true("a run starts", AutoPilot_Needs.trainExercise(runner, "fitness"))
    assert_true("and it continues at 20%, above the 10% floor",
        repAt(runner, 0.20))
    -- Now raise the floor over the character's head mid-run, exactly as an
    -- options save would.  No reload: the very next decision must honour it.
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN = 0.60
    assert_false("raising the floor above the character ends the run at once",
        repAt(runner, 0.20))
    assert_eq("and the panel names endurance as the reason",
        AutoPilot_Needs.getExerciseStatus().outcome,
        "resting (endurance recovering)")

    -- The severe exertion moodle is a SEPARATE signal and survived the
    -- redesign: a level 3 moodle blocks a set even at full endurance, and
    -- even mid-run.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.30
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = 0.10
    AutoPilot_Needs.resetInterventionForTest()
    assert_false("a level 3 exertion moodle still blocks a set outright",
        AutoPilot_Needs.trainExercise(windedPlayer(1.00, 3), "fitness"))

    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = savedR
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = savedF
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
end

print("\n-- Test V5.7-4b: A RUN CONTINUES AT 0.80 (the single-rep bug is dead)")
do
    -- THE regression test for the user's report: "The old setting of 50 made
    -- it so that only a single rep would be completed after a period of
    -- resting."  Under a single threshold the first rep drops endurance below
    -- the very gate that started the set, and training stops dead.  With
    -- hysteresis, a run that STARTED above the resume gate must keep going
    -- well below it, all the way down to the floor.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()

    -- Start the run at 95%, comfortably above the 90% resume gate.
    local p = drivenPlayer(0.95)
    assert_true("a run starts at 95% endurance",
        AutoPilot_Needs.trainExercise(p, "fitness"))

    -- Now endurance falls as the reps go by.  Every level below is UNDER the
    -- resume gate that started the run, and every one must still train.
    -- 0.80 is the headline: under the old single-gate code this is the exact
    -- point at which training stopped after a single rep.
    for _, e in ipairs({ 0.80, 0.60, 0.40 }) do
        assert_true(
            ("the run CONTINUES at %.0f%% endurance, far below the resume gate")
                :format(e * 100),
            repAt(p, e))
        assert_eq(("...and the panel says training at %.0f%%"):format(e * 100),
            AutoPilot_Needs.getExerciseStatus().outcome:sub(1, 8), "training")
    end

    -- Below the floor the run finally stops.
    assert_false("the run STOPS below the 30% floor", repAt(p, 0.25))
    assert_eq("the panel reports endurance recovery, not a cap or fatigue",
        AutoPilot_Needs.getExerciseStatus().outcome,
        "resting (endurance recovering)")

    -- And having stopped, it must NOT restart just above the floor: the whole
    -- point of hysteresis is that the next run waits for the resume gate.
    assert_false("it does NOT restart at 40%, having ended the run",
        repAt(p, 0.40))
    -- V6.1-1: read the gate rather than hardcoding it.  These two lines held
    -- literal 0.85 / 0.90 and were the only reason a pure default change broke
    -- this case; the PROPERTY under test is "one step under the gate refuses,
    -- the gate itself resumes", which is true at any gate value.
    local resumeGate = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    assert_false(("nor at %.0f%%, one step under the resume gate")
        :format((resumeGate - 0.05) * 100), repAt(p, resumeGate - 0.05))
    assert_true(("but it DOES resume at exactly %.0f%%"):format(resumeGate * 100),
        repAt(p, resumeGate))
    AutoPilot_Needs.endTrainingRun()
end

print("\n-- Test V5.7-4c: the full rest-train-rest cycle through check()")
do
    -- End to end, the cycle the user asked for: train down to the floor, sit,
    -- recover to nearly full, resume.  Driven through check() so the sit
    -- branch and the rest hold are exercised, not just the gates.
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()

    local p = drivenPlayer(0.95)
    AutoPilot_Needs.check(p)
    assert_eq("full: the chain trains", last_action_type(), "exercise")

    -- Mid-run, well under the resume gate: still training, not sitting.
    for _, e in ipairs({ 0.80, 0.60, 0.40 }) do
        MockTime.advance(AutoPilot_Constants.EXERCISE_MINUTES * 60000)
        p._xp.Fitness = (p._xp.Fitness or 0) + 12
        p:setEndurance(e)
        ISTimedActionQueue_calls = {}
        AutoPilot_Needs.check(p)
        assert_eq(("mid-run at %.0f%% the chain still trains"):format(e * 100),
            last_action_type(), "exercise")
    end

    -- Under the sit threshold: the run ends and the character sits down.
    MockTime.advance(AutoPilot_Constants.EXERCISE_MINUTES * 60000)
    p._xp.Fitness = (p._xp.Fitness or 0) + 12
    p:setEndurance(0.33)
    ISTimedActionQueue_calls = {}
    AutoPilot_Needs.check(p)
    assert_eq("under the sit threshold the character sits",
        last_action_type(), "rest")

    -- Seated and recovering, but not yet at the stand-up target: stay put,
    -- and queue nothing new while the hold is in force.
    p:setEndurance(0.70)
    ISTimedActionQueue_calls = {}
    assert_true("still seated at 70%, below the 95% target",
        AutoPilot_Needs.check(p))
    assert_eq("nothing else was queued while resting",
        #ISTimedActionQueue_calls, 0)

    -- Recovered to the stand-up target: the hold releases and training
    -- resumes, because the target clears the resume gate by design.
    p:setEndurance(AutoPilot_Constants.ENDURANCE_REST_TARGET)
    ISTimedActionQueue_calls = {}
    AutoPilot_Needs.check(p)
    assert_eq("at the stand-up target it resumes training",
        last_action_type(), "exercise")
    AutoPilot_Needs.endTrainingRun()
end

print("\n-- Test V5.7-4d: everything that must END a run, ends it")
do
    -- A missed clear is the dangerous direction: the character would believe
    -- it is mid-run and keep training off the LOW floor when it should have
    -- been recovering to the resume gate.  Each hook is driven for real and
    -- then probed at 40% -- below the resume gate, above the floor -- which
    -- can only train if the run is still considered open.
    --
    -- repAt advances a full set length, which also carries every probe past
    -- the 10 game-minute V4.5 backoff window, so what is measured here is the
    -- run flag itself and not a backoff timer sitting in front of it.
    local function startRun()
        resetRest()
        AutoPilot_Needs.resetInterventionForTest()
        AutoPilot_Needs.endTrainingRun()
        local p = drivenPlayer(0.95)
        assert_true("(a run is started)",
            AutoPilot_Needs.trainExercise(p, "fitness"))
        return p
    end

    -- CONTROL: with a run genuinely open, 40% DOES train.  Without this the
    -- assertions below would all pass even if training never ran at all.
    assert_true("CONTROL: an open run trains at 40%", repAt(startRun(), 0.40))

    local p = startRun()
    AutoPilot_Needs.endTrainingRun()
    assert_false("endTrainingRun() ends it", repAt(p, 0.40))

    p = startRun()
    AutoPilot_Needs.noteModExerciseCleared()
    assert_false("a mod-side clear (urgent need, threat, thrash guard) ends it",
        repAt(p, 0.40))

    p = startRun()
    AutoPilot_Needs.notePanicStop()
    assert_false("the F10 panic stop ends it", repAt(p, 0.40))

    p = startRun()
    AutoPilot_Needs.noteForeignExercise()
    assert_false("the player exercising manually ends it", repAt(p, 0.40))

    -- Sitting down ends it, so standing up again waits for the resume gate.
    p = startRun()
    p:setEndurance(0.33)
    AutoPilot_Needs.check(p)
    assert_false("sitting down to recover ends it", repAt(p, 0.40))

    -- A NEW CHARACTER never inherits a run: the same guarantee as the sets
    -- counter and the V4.5 `who` records.
    startRun()
    local reborn = drivenPlayer(0.40)
    AutoPilot_Needs.resetInterventionForTest()
    assert_false("a respawned character does not inherit the run",
        AutoPilot_Needs.trainExercise(reborn, "fitness"))

    -- The daily cap ends it, so the next day starts a fresh run off resume.
    p = startRun()
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 1
    assert_false("hitting the daily set cap ends it", repAt(p, 0.40))
    AutoPilot_Constants.EXERCISE_DAILY_CAP = 0

    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
end

print("\n-- Test V5.7-5: no idle dead zone anywhere below full endurance")
do
    -- The whole point of the V5.4 sit branch, re-verified against the V5.7
    -- defaults (gate 0.90, sit 0.90, stand-up target 0.95).  A rest target
    -- BELOW the gate would have been the regression: every completed rest
    -- would end straight back into a band where training is still refused.
    --
    -- The character is swept across the boundaries that matter -- the old
    -- 30/50/70 numbers, the new 90/95 ones, and points either side of each --
    -- and on every single one the cycle must be CLAIMED by something.  Idling
    -- is the failure this asserts against; "no_action" is what the live run
    -- log showed for 403 ticks at a time.
    local bands = {
        0.29, 0.30, 0.31, 0.40, 0.49, 0.50, 0.51, 0.60,
        0.69, 0.70, 0.71, 0.80, 0.89, 0.90, 0.91, 0.94, 0.95, 0.96, 1.00,
    }
    for _, e in ipairs(bands) do
        resetRest()
        AutoPilot_Needs.resetInterventionForTest()
        local p = windedPlayer(e)
        local claimed = AutoPilot_Needs.check(p)
        local act = last_action_type()
        assert_true(
            ("endurance %.0f%% is never left idle (action=%s)")
                :format(e * 100, tostring(act)),
            claimed == true)
        -- ...and what it did has to be resting or training, not busywork.
        -- windedPlayer has no other need, so anything else is a fall-through.
        assert_true(
            ("endurance %.0f%% either rests or trains, nothing else")
                :format(e * 100),
            act == "rest" or act == "sit_furniture"
                or act == "rest_furniture" or act == "exercise")
    end
end

print("\n-- Test V5.7-6: the sit/resume boundary is exact, and does not thrash")
do
    -- With no run open, below the resume gate the character sits and at or
    -- above it the character trains.  No gap, no overlap, nothing idle.
    local resume = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    AutoPilot_Needs.check(windedPlayer(resume - 0.01))
    assert_eq("one point below the resume gate the character sits",
        last_action_type(), "rest")

    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    AutoPilot_Needs.check(windedPlayer(resume))
    assert_eq("exactly at the resume gate the character trains",
        last_action_type(), "exercise")

    -- The stand-up target must clear the resume gate, or a finished rest
    -- lands back in a refused band and the character idles: the V5.4 bug,
    -- moved up the scale.
    assert_true("the stand-up target is strictly above the resume gate",
        AutoPilot_Constants.ENDURANCE_REST_TARGET > resume)

    -- The sit threshold is raised to the resume gate whenever no run is
    -- open, so even a player who drags the sit slider to its minimum cannot
    -- reopen the dead zone.
    local savedSit = AutoPilot_Constants.ENDURANCE_SIT_MIN
    AutoPilot_Constants.ENDURANCE_SIT_MIN = 0.10
    resetRest()
    AutoPilot_Needs.resetInterventionForTest()
    AutoPilot_Needs.endTrainingRun()
    AutoPilot_Needs.check(windedPlayer(resume - 0.05))
    assert_eq("a sit slider dragged under the gate still sits, not idles",
        last_action_type(), "rest")
    AutoPilot_Constants.ENDURANCE_SIT_MIN = savedSit
    resetRest()
    AutoPilot_Needs.endTrainingRun()
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
