-- tests/test_rest_recovery.lua
-- V5.4 rest-band suite: endurance recovery in the 30-50% dead zone -- the
-- sit-instead-of-idling headline, seating recognition and eligibility, the
-- rest hold with its release and preemption rules, and the live-read sit
-- threshold (V5.4-1..17).
--
-- Moved VERBATIM out of tests/test_priority_logic.lua (code-health split,
-- 2026-08-07, second slice; the V5.7 block moved first): that file was still
-- 2,218 lines after the first slice.  Test bodies are unchanged; only this
-- header, and the bootstrap/helpers each standalone suite carries by repo
-- convention (mock loads, stubs, mini-framework, and the furniture helpers),
-- are copied alongside.  drivenPlayer/repAt stay behind: they are V5.7-era
-- helpers the V5.4 cases never call.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_rest_recovery.lua

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

-- ── V5.4: endurance recovery (the 30-50% dead zone) ─────────────────────────
-- User report: "the PC does not rest for long enough or utilize things like
-- chairs or benches to recover endurance.  They should at least sit on the
-- ground to improve the efficiency of recovering."
--
-- The live run log backed every part of that: no action=rest entries at all
-- across ~16,000 ticks, idle streaks of 403 / 118 / 116 / 115 ticks tagged
-- reason=no_action, and an endurance floor of 40% that never reached the 30%
-- rest gate.  Training was gated at 50%, so the band between the two gates was
-- spent idling.  These cases pin the fix.

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

print("\n-- Test V5.4-1 (HEADLINE): 40% endurance sits instead of idling")
do
    resetRest()
    -- 0.40 is the exact floor the live log recorded: above the 30% rest gate,
    -- below the 50% training gate.  Before V5.4 this cycle produced NO action.
    local player = windedPlayer(0.40)
    local decisions = {}
    local origSetDecision = AutoPilot_Telemetry.setDecision
    AutoPilot_Telemetry.setDecision = function(action, reason, ...)
        table.insert(decisions, tostring(action) .. ":" .. tostring(reason))
        return origSetDecision(action, reason, ...)
    end
    local result = AutoPilot_Needs.check(player)
    AutoPilot_Telemetry.setDecision = origSetDecision

    assert_true("check() claims the cycle at 40% endurance", result)
    assert_eq("the dead zone now queues a rest, not nothing",
        last_action_type(), "rest")
    local sawSit = false
    for _, d in ipairs(decisions) do
        if d == "rest:sit_recover" then sawSit = true end
    end
    assert_true("telemetry records action=rest reason=sit_recover", sawSit)
end

print("\n-- Test V5.4-2: the dead zone spans the whole 30-50% band")
do
    for _, e in ipairs({ 0.31, 0.35, 0.45, 0.49 }) do
        resetRest()
        local player = windedPlayer(e)
        assert_true(("endurance %.0f%% claims the cycle"):format(e * 100),
            AutoPilot_Needs.check(player))
        assert_eq(("endurance %.0f%% queues a rest"):format(e * 100),
            last_action_type(), "rest")
    end
end

print("\n-- Test V5.4-3: at the training gate and above it trains, never sits")
do
    resetRest()
    -- The sit threshold tracks the exercise threshold: at or above it the
    -- character must go back to its actual job.  V5.7 moved both to 0.90, so
    -- this reads the gate rather than hardcoding the number.
    -- V5.7: with no run in progress, the threshold that matters is the
    -- RESUME gate, not the floor.
    AutoPilot_Needs.endTrainingRun()
    local player = windedPlayer(AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME)
    AutoPilot_Needs.check(player)
    assert_eq("at exactly the resume gate it trains, not rests",
        last_action_type(), "exercise")
    resetRest()
    AutoPilot_Needs.check(windedPlayer(1.00))
    assert_eq("at full endurance it trains, not rests",
        last_action_type(), "exercise")
end

print("\n-- Test V5.4-4: bench and friends are recognised as seating")
do
    local seat = AutoPilot_Needs.seatPriorityForSprite
    assert_eq("B42's outdoor seating sheet is seating",
        seat("furniture_seating_outdoor_01_16"), 3)
    assert_eq("a named bench is seating",      seat("location_park_bench_01"), 3)
    assert_eq("a stool is seating",            seat("furniture_barstool_02"), 3)
    assert_eq("a church pew is seating",       seat("church_pew_01"), 3)
    assert_eq("a chair is seating",            seat("furniture_seating_indoor_chair_04"), 3)
    assert_eq("a sofa outranks a chair",       seat("furniture_seating_indoor_sofa_01"), 2)
    assert_eq("a couch outranks a chair",      seat("couch_green_02"), 2)
    assert_eq("a loveseat outranks a chair",   seat("loveseat_red_01"), 2)
    assert_eq("an armchair outranks a chair",  seat("armchair_blue_03"), 2)
    -- Guard against the obvious false positives.
    assert_eq("a workbench is NOT seating",    seat("carpentry_workbench_01"), nil)
    assert_eq("a carpentry bench is NOT seating", seat("crafted_carpentry_bench"), nil)
    assert_eq("a bench saw is NOT seating",    seat("industry_benchsaw_01"), nil)
    assert_eq("a fridge is NOT seating",       seat("appliances_refrigeration_01"), nil)
    assert_eq("a non-string is NOT seating",   seat(nil), nil)
end

print("\n-- Test V5.4-5: a bench OUTSIDE the home is now eligible")
do
    resetRest()
    -- isInside() is false for every square in this suite, which is exactly the
    -- pre-V5.4 blind spot: the old code bailed on the first line of the scan.
    placeFurniture({ { sprite = "location_park_bench_01", dx = 5, dy = 0 } })
    local player = windedPlayer(0.40)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(player))
    -- V5.8: the furniture path queues the SEAT action (pathToSitOnFurniture),
    -- so the recorded type is "sit_furniture" rather than "rest_furniture".
    assert_eq("the outdoor bench is used, not the ground",
        last_action_type(), "sit_furniture")
    noFurniture()
end

print("\n-- Test V5.4-6: outside-home seating beyond the tighter radius is refused")
do
    resetRest()
    local far = AutoPilot_Constants.REST_OUTSIDE_SEARCH_DIST + 5
    placeFurniture({ { sprite = "location_park_bench_01", dx = far, dy = 0 } })
    local player = windedPlayer(0.40)
    assert_true("check() still claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("a bench across town is ignored; it sits on the ground instead",
        last_action_type(), "rest")
    noFurniture()
end

print("\n-- Test V5.4-7: inside-home seating wins over closer outside seating")
do
    resetRest()
    -- Mark only the far square as inside home.
    AutoPilot_Home.isInside = function(sq) return sq:getX() == 40 end
    placeFurniture({
        { sprite = "location_park_bench_01", dx = 2,  dy = 0 },
        { sprite = "furniture_seating_indoor_sofa_01", dx = 40, dy = 0 },
    })
    local player = windedPlayer(0.40)
    AutoPilot_Needs.check(player)
    assert_eq("furniture was used", last_action_type(), "sit_furniture")
    local chosen = ISTimedActionQueue_calls[#ISTimedActionQueue_calls]
    assert_eq("the far INSIDE sofa beat the near OUTSIDE bench",
        chosen.target:getSprite():getName(), "furniture_seating_indoor_sofa_01")
    AutoPilot_Home.isInside = function(_sq) return false end
    noFurniture()
end

print("\n-- Test V5.4-8: the ground-sit fallback fires when nothing qualifies")
do
    resetRest()
    -- No furniture anywhere: the user's "at least sit on the ground".
    local player = windedPlayer(0.40)
    assert_true("check() claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("ISSitOnGround is queued", last_action_type(), "rest")
end

print("\n-- Test V5.4-9: a rest outlasts one in-game minute")
do
    resetRest()
    local player = windedPlayer(0.40)
    assert_true("first cycle sits down", AutoPilot_Needs.check(player))
    local queuedAfterSit = #ISTimedActionQueue_calls

    -- The old code held the rest for exactly 60000 game ms and then stood the
    -- character back up.  Step past that and well beyond it.
    MockTime.advance(60000)
    assert_true("still resting one game minute later", AutoPilot_Needs.check(player))
    assert_eq("no second action was queued a minute in",
        #ISTimedActionQueue_calls, queuedAfterSit)

    MockTime.advance(10 * 60000)
    assert_true("still resting ten game minutes later",
        AutoPilot_Needs.check(player))
    assert_eq("still no second action ten minutes in",
        #ISTimedActionQueue_calls, queuedAfterSit)
end

print("\n-- Test V5.4-10: the rest ends when endurance reaches the target")
do
    resetRest()
    local player = windedPlayer(0.40)
    assert_true("sits down", AutoPilot_Needs.check(player))
    -- Endurance recovers past ENDURANCE_REST_TARGET (V5.7: 0.95) while seated.
    local recovered = windedPlayer(
        AutoPilot_Constants.ENDURANCE_REST_TARGET + 0.01)
    AutoPilot_Needs.check(recovered)
    -- The hold is released, so the chain runs on; a further cycle must not be
    -- swallowed by the rest gate.
    ISTimedActionQueue_calls = {}
    AutoPilot_Needs.check(recovered)
    assert_true("a recovered character is no longer held in the rest",
        last_action_type() ~= "rest")
end

print("\n-- Test V5.4-11: the maximum hold releases even if endurance never moves")
do
    resetRest()
    local player = windedPlayer(0.40)
    assert_true("sits down", AutoPilot_Needs.check(player))
    ISTimedActionQueue_calls = {}
    MockTime.advance((AutoPilot_Constants.REST_HOLD_MS or 60000) + 1000)
    -- Past the wedge guard: the chain re-evaluates and sits again rather than
    -- staying stuck in a hold forever.
    assert_true("the cycle is re-evaluated after the maximum hold",
        AutoPilot_Needs.check(player))
    assert_eq("a fresh rest is queued", last_action_type(), "rest")
end

print("\n-- Test V5.4-12: bleeding preempts an active rest")
do
    resetRest()
    local player = windedPlayer(0.40)
    assert_true("sits down", AutoPilot_Needs.check(player))
    ISTimedActionQueue_calls = {}
    AutoPilot_Medical._bleeding = true
    assert_true("bleeding still claims the cycle", AutoPilot_Needs.check(player))
    assert_eq("the bandage outranks the rest", last_action_type(), "bandage")
    AutoPilot_Medical._bleeding = false
end

print("\n-- Test V5.4-13: hunger and thirst preempt an active rest")
do
    resetRest()
    assert_true("sits down", AutoPilot_Needs.check(windedPlayer(0.40)))

    ISTimedActionQueue_calls = {}
    local foodItem = {
        getName     = function() return "Chips" end,
        getCalories = function() return 200 end,
    }
    AutoPilot_Inventory.getBestFood = function(_player) return foodItem end
    local hungry = MockPlayer.new({
        stats = { HUNGER = 0.25, THIRST = 0.02, FATIGUE = 0.02, ENDURANCE = 0.40 },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
    })
    assert_true("hunger claims the cycle mid-rest", AutoPilot_Needs.check(hungry))
    assert_eq("eating outranks the rest hold", last_action_type(), "eat")

    resetRest()
    assert_true("sits down again", AutoPilot_Needs.check(windedPlayer(0.40)))
    ISTimedActionQueue_calls = {}
    AutoPilot_Inventory.getBestDrink =
        function(_player) return { getName = function() return "WaterBottle" end } end
    local thirsty = MockPlayer.new({
        stats = { THIRST = 0.30, HUNGER = 0.02, FATIGUE = 0.02, ENDURANCE = 0.40 },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
    })
    assert_true("thirst claims the cycle mid-rest", AutoPilot_Needs.check(thirsty))
    assert_eq("drinking outranks the rest hold", last_action_type(), "eat")
    reset()
end

print("\n-- Test V5.4-14: high fatigue still overrides the rest hold")
do
    resetRest()
    assert_true("sits down", AutoPilot_Needs.check(windedPlayer(0.40)))
    ISTimedActionQueue_calls = {}
    local sleepy = MockPlayer.new({
        stats = { HUNGER = 0.02, THIRST = 0.02, FATIGUE = 0.80, ENDURANCE = 0.40 },
        moodles = { ENDURANCE = 0, UNHAPPY = 0 },
    })
    -- doSleep finds no bed here, so it returns false; what matters is that the
    -- rest hold did NOT swallow the cycle before the sleep branch ran.
    AutoPilot_Needs.check(sleepy)
    assert_eq("no rest action was queued on the fatigue path",
        last_action_type(), nil)
end

print("\n-- Test V5.4-15: the critical rest sits on the NEAREST furniture, never sleeps")
do
    resetRest()
    -- V6 (user design 2026-07-24): RESTING = sit on any furniture, all types
    -- equal, NEVER sleep.  With a bed at dx=3 and a bench at dx=1 the NEAREST
    -- furniture (the bench) is chosen, and the action is the seat path, not sleep.
    placeFurniture({
        { sprite = "furniture_bedding_01_20", bed = true, dx = 3, dy = 0 },
        { sprite = "location_park_bench_01",  dx = 1, dy = 0 },
    })
    local player = windedPlayer(0.20)
    assert_true("critically low endurance claims the cycle",
        AutoPilot_Needs.check(player))
    assert_eq("the nearest furniture is used, and it is a sit, not sleep",
        last_action_type(), "sit_furniture")
    noFurniture()
end

print("\n-- Test V5.4-16: the sit-to-recover path USES a bed as a seat, never sleeps")
do
    resetRest()
    -- V6 (user decision 2026-07-24, Q1): a merely-winded character USES a bed
    -- when it is the available furniture -- it SITS on it via the seat path, it
    -- does NOT sleep, and it does NOT sit on the floor next to it.
    placeFurniture({
        { sprite = "furniture_bedding_01_20", bed = true, dx = 1, dy = 0 },
    })
    local player = windedPlayer(0.40)
    AutoPilot_Needs.check(player)
    assert_eq("a bed is used as a seat (sit path), not sleep and not the ground",
        last_action_type(), "sit_furniture")
    noFurniture()
end

print("\n-- Test V5.4-17: the sit threshold is live-read from constants")
do
    resetRest()
    local saved     = AutoPilot_Constants.ENDURANCE_SIT_MIN
    local savedGate = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    -- V5.7: when NO run is in progress the sit threshold is raised to the
    -- RESUME gate, because a character who is not training and cannot start
    -- has nothing to do but recover.  Lowering the sit slider therefore only
    -- shows up once the resume gate is out of the way too, which is what a
    -- player lowering both sliders together would do.
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.30
    AutoPilot_Constants.ENDURANCE_SIT_MIN         = 0.35
    -- 40% is now ABOVE the tuned-down sit threshold: no rest.
    AutoPilot_Needs.check(windedPlayer(0.40))
    assert_true("a lowered slider stops the sit immediately",
        last_action_type() ~= "rest")
    resetRest()
    AutoPilot_Constants.ENDURANCE_SIT_MIN = 0.80
    assert_true("a raised slider sits at 70% endurance",
        AutoPilot_Needs.check(windedPlayer(0.70)))
    assert_eq("and it queues a rest", last_action_type(), "rest")
    AutoPilot_Constants.ENDURANCE_SIT_MIN         = saved
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = savedGate
    resetRest()
end


-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
