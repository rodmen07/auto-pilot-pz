-- tests/test_dry_off.lua
-- Behavioural tests for AutoPilot_Comfort, the dry-off arm (the Wet moodle).
--
-- The behaviour difference these cases exist to prove: before this arm, the mod
-- had NO wetness surface at all.  A whole-mod grep over 42/media/lua/client and
-- tests/ for "wetness|towel|dishcloth|drymyself|isWet" returned exactly one hit,
-- and it was tests/test_engine_symbols.lua naming CharacterStat.WETNESS as an
-- example of a stat the mock deliberately does not model.  A character soaked by
-- rain stayed soaked while carrying the bath towel that clears it outright.
--
-- Every engine rule asserted here was read live from the 42.19 install:
--   * the action is ISDryMyself:new(character, item)
--                          (shared/TimedActions/ISDryMyself.lua:112)
--   * it is only valid while the cloth is carried, has uses left and
--     getStats():get(CharacterStat.WETNESS) > 0                    (:5-15)
--   * :complete() clears wetness outright, decreaseBodyWetness(WETNESS) (:65)
--   * the cloths are exactly DishCloth and BathTowel
--                          (client/ISUI/ISInventoryPaneContextMenu.lua:190)
--   * the engine's own path transfers the cloth to the main inventory BEFORE
--     queueing                                                     (:2758)
--   * WETNESS is a 0-100 stat: ISStatsAndBody.lua:75 registers it with an
--     EXPLICIT slider step of 1 (as PAIN/PANIC/BOREDOM/UNHAPPINESS do), while
--     the 0.0-1.0 stats take addSliderOptionEnum's default 0.01 (:153-164).
--     Test 3 is the case that fails if that division is ever dropped.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_dry_off.lua

-- ── Load mocks and modules ────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")
dofile("42/media/lua/client/AutoPilot_Utils.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")
dofile("42/media/lua/client/AutoPilot_Comfort.lua")

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

-- ── Suite-local engine stub ───────────────────────────────────────────────────
-- ISInventoryTransferAction is an [S] surface in lua_mock_pz.lua's coverage
-- legend: documented there, mocked per-suite.  Declared up here because the
-- transfer-then-use path (Test 9) needs it long before the check() section.
ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}

-- ── Builders ──────────────────────────────────────────────────────────────────

--- A drying cloth as the mod sees it.  `uses` is getCurrentUsesFloat().
local function cloth(itemType, uses, name)
    return {
        getType             = function(_self) return itemType end,
        getName             = function(_self) return name or itemType end,
        getCurrentUsesFloat = function(_self) return uses end,
    }
end

--- An item that is not a cloth at all.
local function junk(itemType)
    return {
        getType             = function(_self) return itemType end,
        getName             = function(_self) return itemType end,
        getCurrentUsesFloat = function(_self) return 1 end,
    }
end

--- Wetness is set in ENGINE UNITS (0-100), exactly as the game reports it.
--- carried = array of items in the main inventory.
local function wetPlayer(wetness100, carried, opts)
    opts = opts or {}
    local p = MockPlayer.new({ stats = { WETNESS = wetness100 } })
    MockContainer.attach(p, MockContainer.new(carried or {}))
    if opts.outside ~= nil then
        p.getCurrentSquare = function(_self)
            return { isOutside = function(_s) return opts.outside end }
        end
    end
    return p
end

local function reset()
    ISTimedActionQueue_calls = {}
end

local function queuedTypes()
    local out = {}
    for _, a in ipairs(ISTimedActionQueue_calls) do
        table.insert(out, a.type or "?")
    end
    return table.concat(out, ",")
end

print("== AutoPilot_Comfort: dry-off arm ==")

-- ── 1. The arm fires: soaked character carrying a towel ───────────────────────
print("\n-- Test 1: a soaked character with a towel queues ISDryMyself")
reset()
local p1 = wetPlayer(60, { cloth("BathTowel", 1.0) })
local queued1, state1 = AutoPilot_Comfort.doDryOff(p1, false)
assert_true("relief is queued", queued1)
assert_eq("...and reports the drying state", state1, "drying")
assert_eq("...by queueing exactly one action", #ISTimedActionQueue_calls, 1)
assert_eq("...and that action is the engine's dry action", queuedTypes(), "dry")
assert_eq("...carrying the cloth the engine consumes",
    ISTimedActionQueue_calls[1].item and ISTimedActionQueue_calls[1].item:getType(),
    "BathTowel")

-- ── 2. A dry character is left alone ──────────────────────────────────────────
print("\n-- Test 2: a dry character is not dried")
reset()
local p2 = wetPlayer(0, { cloth("BathTowel", 1.0) })
local queued2, state2 = AutoPilot_Comfort.doDryOff(p2, false)
assert_false("nothing is queued", queued2)
assert_eq("...and the state says there is nothing to do", state2, "dry")
assert_eq("...literally nothing queued", #ISTimedActionQueue_calls, 0)

-- ── 3. THE SCALE CASE ─────────────────────────────────────────────────────────
-- WETNESS is 0-100.  A barely-damp character reads 5 in engine units, which is
-- 0.05 as a fraction and well under the 0.30 threshold.  If AutoPilot_Comfort
-- ever stops dividing by 100, 5 > 0.30 and this character is towelled off for
-- being 5 percent damp -- the "gate is permanently on" half of the unit-mismatch
-- class that kept the unhappy arm dead through PRs #68/#77/#78 (that one was the
-- other half: a threshold nothing could reach).
print("\n-- Test 3: engine units are 0-100, so 5 is damp, not soaked")
reset()
local p3 = wetPlayer(5, { cloth("BathTowel", 1.0) })
local queued3, state3 = AutoPilot_Comfort.doDryOff(p3, false)
assert_false("a 5-percent-damp character is not towelled off", queued3)
assert_eq("...and the reason is the threshold, not a missing towel", state3, "dry")
assert_eq("wetness() converts engine units to a fraction",
    AutoPilot_Comfort.wetness(p3), 0.05)
-- ...and the threshold really is reachable in those units, so the gate is not
-- dead in the other direction either.
assert_eq("a soaked character reads as a fraction too",
    AutoPilot_Comfort.wetness(wetPlayer(60, {})), 0.6)

-- ── 4. Soaked with no cloth ───────────────────────────────────────────────────
print("\n-- Test 4: soaked with nothing to dry with is reported, not silent")
reset()
local p4 = wetPlayer(80, { junk("Hammer") })
local queued4, state4 = AutoPilot_Comfort.doDryOff(p4, false)
assert_false("nothing is queued", queued4)
assert_eq("...and the state distinguishes this from being dry", state4, "no_cloth")
assert_eq("...with no stray actions", #ISTimedActionQueue_calls, 0)

-- ── 5. A spent cloth is not a cloth ───────────────────────────────────────────
-- ISDryMyself:isValid requires getCurrentUsesFloat() > 0, so queueing a spent
-- towel produces an action the engine drops on its first validity check.
print("\n-- Test 5: a cloth with no uses left is skipped")
reset()
local p5 = wetPlayer(80, { cloth("BathTowel", 0) })
local queued5, state5 = AutoPilot_Comfort.doDryOff(p5, false)
assert_false("a spent towel does not queue an action", queued5)
assert_eq("...and reads as no cloth at all", state5, "no_cloth")

-- ── 6. Both engine cloth types are accepted ───────────────────────────────────
print("\n-- Test 6: a dishcloth works too (the engine accepts both)")
reset()
local p6 = wetPlayer(60, { cloth("DishCloth", 0.5) })
local queued6 = AutoPilot_Comfort.doDryOff(p6, false)
assert_true("a dishcloth is a valid drying cloth", queued6)
assert_eq("...and it is the item queued",
    ISTimedActionQueue_calls[1].item:getType(), "DishCloth")

-- ── 7. The fullest cloth wins ─────────────────────────────────────────────────
-- ISDryMyself:update force-stops when the cloth runs out mid-action, so a
-- nearly-spent towel gives a partial dry.  Order in the container is
-- deliberately worst-first so a first-match implementation fails here.
print("\n-- Test 7: the cloth with the most uses left is chosen")
reset()
local p7 = wetPlayer(70, {
    cloth("DishCloth", 0.1, "nearly-spent"),
    cloth("BathTowel", 0.9, "fresh"),
    cloth("DishCloth", 0.4, "half"),
})
AutoPilot_Comfort.doDryOff(p7, false)
assert_eq("the fullest cloth is the one queued",
    ISTimedActionQueue_calls[1].item:getName(), "fresh")

-- ── 8. Standing in the rain ───────────────────────────────────────────────────
-- Drying outdoors while it rains is undone as fast as it happens; the existing
-- shelter step in AutoPilot_Needs.check already moves the character indoors on
-- rain, so this arm yields to it rather than burning a towel.
print("\n-- Test 8: soaked outdoors in the rain refuses and defers to shelter")
reset()
local p8 = wetPlayer(90, { cloth("BathTowel", 1.0) }, { outside = true })
local queued8, state8 = AutoPilot_Comfort.doDryOff(p8, true)
assert_false("no towel is spent while standing in the rain", queued8)
assert_eq("...and the state names the reason", state8, "exposed")
assert_eq("...with nothing queued", #ISTimedActionQueue_calls, 0)

print("\n-- Test 8b: the same character INDOORS while it rains does dry")
reset()
local p8b = wetPlayer(90, { cloth("BathTowel", 1.0) }, { outside = false })
assert_true("rain alone does not block drying", AutoPilot_Comfort.doDryOff(p8b, true))

print("\n-- Test 8c: outdoors without rain also dries")
reset()
local p8c = wetPlayer(90, { cloth("BathTowel", 1.0) }, { outside = true })
assert_true("being outside only matters while it rains",
    AutoPilot_Comfort.doDryOff(p8c, false))

-- ── 9. Transfer-then-use (V4.9) ───────────────────────────────────────────────
-- ISDryMyself:isValid requires the cloth to be in the character's inventory, and
-- the engine's own menu path calls transferIfNeeded before queueing.
print("\n-- Test 9: a towel inside a bag is moved to the main inventory first")
reset()
local bagged = cloth("BathTowel", 1.0, "in-a-bag")
local bag = MockContainer.bag("Bag_Schoolbag", { bagged })
local p9 = wetPlayer(70, { bag })
local queued9, state9 = AutoPilot_Comfort.doDryOff(p9, false)
assert_true("the bagged towel is still used", queued9)
assert_eq("...and the state is drying", state9, "drying")
assert_eq("...transfer first, then dry", queuedTypes(), "transfer,dry")

-- ── 10. Degenerate inputs ─────────────────────────────────────────────────────
print("\n-- Test 10: degenerate inputs do not throw")
reset()
local qNil, sNil = AutoPilot_Comfort.doDryOff(nil, false)
assert_false("a nil player queues nothing", qNil)
assert_eq("...and reports dry", sNil, "dry")
assert_eq("wetness(nil) is 0", AutoPilot_Comfort.wetness(nil), 0)
assert_false("isExposedToRain is false when it is not raining",
    AutoPilot_Comfort.isExposedToRain(wetPlayer(50, {}, { outside = true }), false))

-- ── 11. The CALLER actually reaches the arm ───────────────────────────────────
-- Unit-testing a module without proving check() routes to it is exactly how a
-- dead arm ships green in this project (PRs #77, #78, #80 were each an arm the
-- suites exercised directly while the game never reached it).  This section
-- loads the real AutoPilot_Needs over minimal stubs and drives check().
print("\n-- Test 11: AutoPilot_Needs.check() routes a soaked character here")

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
    getSupplyCounts       = function(_player) return { food = 9, drink = 9 } end,
    bodyTemperature       = function(_player) return 0 end,
}

AutoPilot_Home = {
    isSet            = function(_player) return false end,
    isInside         = function(_sq)     return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

-- The media arm is a sibling of the one under test; stubbing it keeps this
-- suite's subject unambiguous.
AutoPilot_Media = {
    doMediaRelief = function(_player) return false, "none" end,
}

dofile("42/media/lua/client/AutoPilot_Consumption.lua")
dofile("42/media/lua/client/AutoPilot_Sleep.lua")
dofile("42/media/lua/client/AutoPilot_Rest.lua")
dofile("42/media/lua/client/AutoPilot_Exercise.lua")
-- Loader plumbing only (code-health split, 2026-08-01): doMoodRelief and its
-- two private arms moved out of AutoPilot_Needs into AutoPilot_Mood.  No test
-- case, stub or assertion below changed.
dofile("42/media/lua/client/AutoPilot_Mood.lua")
dofile("42/media/lua/client/AutoPilot_Needs.lua")
AutoPilot_Utils.iterateNearbySquares = function(_cx, _cy, _cz, _r, _cb) end

--- A healthy character who is only wet: every step above 6c must decline so the
--- chain reaches the dry-off arm.
local function healthyButWet(wetness100, carried)
    local p = MockPlayer.new({
        stats = {
            HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.05,
            ENDURANCE = 0.95, WETNESS = wetness100,
        },
        moodles = { ENDURANCE = 0, UNHAPPY = 0, PAIN = 0, PANIC = 0 },
    })
    MockContainer.attach(p, MockContainer.new(carried or {}))
    p.getCurrentSquare = function(_self)
        return { isOutside = function(_s) return false end }
    end
    return p
end

reset()
AutoPilot_Rest.clearRestHold()
local soaked = healthyButWet(75, { cloth("BathTowel", 1.0) })
local c1 = AutoPilot_Needs.check(soaked)
assert_true("check() claims the cycle", c1)
assert_eq("...by queueing the dry action and nothing else", queuedTypes(), "dry")
-- The telemetry decision is the assertion that fails if the arm is unwired:
-- without it the chain falls through to exercise, which also returns true, so
-- truthiness alone proves nothing here.
assert_eq("...and the run log records the decision as a dry",
    AutoPilot_Telemetry.getPendingAction(soaked), "dry")

reset()
AutoPilot_Rest.clearRestHold()
local damp = healthyButWet(5, { cloth("BathTowel", 1.0) })
local c2 = AutoPilot_Needs.check(damp)
assert_eq("a damp character is NOT dried by check()",
    queuedTypes():find("dry") ~= nil, false)
assert_eq("...and the arm is skipped rather than erroring", type(c2), "boolean")

-- Soaked, no towel: the chain must NOT stop here (drying is not available), but
-- the run log must still say so, which is what makes the gap visible in triage.
reset()
AutoPilot_Rest.clearRestHold()
local soakedNoTowel = healthyButWet(75, { junk("Hammer") })
AutoPilot_Needs.check(soakedNoTowel)
assert_eq("no dry action is queued without a cloth",
    queuedTypes():find("dry") ~= nil, false)

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n== %d passed, %d failed =="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
