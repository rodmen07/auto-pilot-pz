-- tests/test_exercise_pool.lua
-- V6.3 C1: the AUTO exercise pool is DISCOVERED from the engine's exercise
-- table instead of being a hardcoded list of the seven exercises vanilla
-- B42.19 happens to ship.
--
-- Approved 2026-08-10 by the owner ("approve defaults for D1-D8"),
-- docs/EXPANSION_PROPOSAL_V6_3.md section 2.  The three decisions this suite
-- pins:
--
--   D1  the vanilla seven must come out of the generic path in EXACTLY the
--       order the V5.2 literal list produced, so the change is invisible
--       until the exercise table itself changes;
--   D2  an exercise the mod does not know joins the AUTO pool by its xpMod and
--       never the focused pools (its perk is unknowable from Lua);
--   D3  no new tunables -- the table is the configuration.
--
-- WHY THE ORDER IS WORTH A SUITE OF ITS OWN.  Two of the vanilla seven pay the
-- same xpMod as another (dumbbellpress and bicepscurl both 1.8; squats,
-- pushups and situp all 1.0), and pairs() iteration order is undefined in Lua
-- while table.sort is not stable -- so a derivation without a TOTAL order
-- would hand the trainer a different pool on different runs of the same game
-- and nothing would notice.  Burpees are the sharper case: they pay 0.8, LESS
-- than the bodyweight trio, and lead them anyway because they are the one
-- exercise that levels Strength and Fitness together (V5.2).  Test 2 is the
-- behaviour-difference control for exactly that: it shows the position burpees
-- occupy cannot be explained by xpMod ordering, so the promotion is doing work
-- rather than the sort happening to agree with it.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_exercise_pool.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants (no PZ deps; 'C' sorts first so safe to load stand-alone) ─
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- Real Utils: AutoPilot_Exercise references it at call time (clearModAction,
-- the ownership registry).  The pool derivation itself touches neither, but
-- the module is loaded whole, so its dependency is loaded whole too.
dofile("42/media/lua/client/AutoPilot_Utils.lua")

-- ── Load the module under test ────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Exercise.lua")

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

-- ── Helpers ───────────────────────────────────────────────────────────────────

local PLAYER = MockPlayer.new({})

--- The pool the trainer would actually walk, run through the shipped code.
local function pool(focus)
    return AutoPilot_Exercise.exerciseCandidatesForTest(PLAYER, focus)
end

local function joined(list)
    return table.concat(list, ",")
end

-- The V5.2 order, written out here as a LITERAL rather than read back out of
-- the module: a guard whose expectation comes from the source it is guarding
-- follows that source wherever it goes.
local V5_2_AUTO = "dumbbellpress,bicepscurl,barbellcurl,burpees,squats,pushups,situp"
local STRENGTH  = "dumbbellpress,bicepscurl,barbellcurl,pushups"
local FITNESS   = "squats,situp"

-- The vanilla mirror, kept so every test can put it back after perturbing it.
local VANILLA = FitnessExercises.exercisesType

local function restoreVanilla()
    FitnessExercises = { exercisesType = VANILLA }
end

--- Run `fn` with `name` temporarily added to the exercise table.
local function withExercise(name, data, fn)
    local copy = {}
    for k, v in pairs(VANILLA) do copy[k] = v end
    copy[name] = data
    FitnessExercises = { exercisesType = copy }
    fn()
    restoreVanilla()
end

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 1 (D1): the vanilla seven come out exactly as the V5.2 list")
-- ═══════════════════════════════════════════════════════════════════════════

do
    local auto = pool(nil)
    assert_eq("the auto pool has seven entries", #auto, 7)
    assert_eq("the derived auto pool IS the V5.2 order", joined(auto), V5_2_AUTO)

    -- Element-for-element as well as joined, so a single misplacement names
    -- itself instead of reporting one long mismatched string.
    local expected = { "dumbbellpress", "bicepscurl", "barbellcurl", "burpees",
                       "squats", "pushups", "situp" }
    for i = 1, #expected do
        assert_eq(("auto[%d] is %s"):format(i, expected[i]), auto[i], expected[i])
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 2 (D1 control): burpees' position is NOT explained by xpMod")
-- ═══════════════════════════════════════════════════════════════════════════
-- The behaviour difference the both-stats promotion makes.  Without it the
-- pool is pure xpMod-descending and burpees, the cheapest exercise in the
-- table, sort LAST.  With it they sit fourth, ahead of three exercises that
-- each pay more.  If the promotion were deleted, this test is what goes red.

do
    local auto  = pool(nil)
    local types = FitnessExercises.exercisesType

    assert_eq("burpees are fourth", auto[4], "burpees")

    local burpeeXp = types.burpees.xpMod
    assert_eq("burpees pay 0.8", burpeeXp, 0.8)

    -- Every exercise burpees are placed AHEAD of pays strictly more.
    for i = 5, #auto do
        local xp = types[auto[i]].xpMod
        assert_true(("%s (%s) pays more than burpees, yet ranks below them")
            :format(auto[i], tostring(xp)), xp > burpeeXp)
    end

    -- ...and nothing in the table pays less, so "burpees are last on xpMod"
    -- is the ordering this promotion overrides, not a hypothetical.
    local lowest = true
    for _, data in pairs(types) do
        if (tonumber(data.xpMod) or 0) < burpeeXp then lowest = false end
    end
    assert_true("burpees carry the LOWEST xpMod in the whole table", lowest)
end

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 3: an unreadable exercise table falls back, it does not empty")
-- ═══════════════════════════════════════════════════════════════════════════
-- A trainer that returns no candidates stops training silently, so the
-- derivation keeps the V5.2 list as its fallback.  Driving the fallback here
-- (rather than reading the constant) is also what stops it drifting away from
-- the derivation it stands in for.

do
    FitnessExercises = nil
    local auto = pool(nil)
    assert_eq("a nil FitnessExercises still yields the V5.2 pool",
        joined(auto), V5_2_AUTO)

    FitnessExercises = { exercisesType = {} }
    auto = pool(nil)
    assert_eq("an EMPTY exercise table still yields the V5.2 pool",
        joined(auto), V5_2_AUTO)

    FitnessExercises = { exercisesType = "not a table" }
    auto = pool(nil)
    assert_eq("a non-table exercisesType still yields the V5.2 pool",
        joined(auto), V5_2_AUTO)

    restoreVanilla()
    assert_eq("the vanilla mirror is back", joined(pool(nil)), V5_2_AUTO)
end

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 4 (D2): an EQUIPMENT newcomer slots in at its xpMod")
-- ═══════════════════════════════════════════════════════════════════════════
-- The point of the whole candidate: an exercise this mod has never heard of --
-- another mod's, or a future Build's -- is trained the moment the engine
-- declares it, at the rank its own xpMod earns.

withExercise("kettlebellswing", {
    type = "kettlebellswing", item = "Base.KettleBell", prop = "primary",
    xpMod = 1.5,
}, function()
    local auto = pool(nil)
    assert_eq("the pool grew to eight", #auto, 8)
    assert_eq("the 1.8 pair still leads", auto[1] .. "," .. auto[2],
        "dumbbellpress,bicepscurl")
    assert_eq("the 1.5 newcomer is third", auto[3], "kettlebellswing")
    assert_eq("...ahead of barbellcurl, which pays 1.2", auto[4], "barbellcurl")
    assert_eq("...and the rest of the V5.2 order is intact",
        joined(auto), "dumbbellpress,bicepscurl,kettlebellswing,barbellcurl,"
            .. "burpees,squats,pushups,situp")
end)

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 5 (D1, documented consequence): a BODYWEIGHT newcomer")
-- ═══════════════════════════════════════════════════════════════════════════
-- The promotion is defined as the V5.2 sentence verbatim -- burpees sit ahead
-- of the bodyweight fallbacks -- so a bodyweight newcomer that outpays an
-- equipment exercise pushes burpees above that equipment exercise too.  No
-- such exercise exists in vanilla (every bodyweight entry pays 1.0 or less and
-- every equipment entry pays 1.2 or more), so this is a shape nothing ships
-- today; it is pinned here so the behaviour is a decision on the record rather
-- than a surprise the first mod to add one discovers in-game.

withExercise("shadowboxing", { type = "shadowboxing", xpMod = 1.5 }, function()
    local auto = pool(nil)
    assert_eq("the pool grew to eight", #auto, 8)
    assert_eq("the newcomer leads the bodyweight tier, burpees lead it",
        joined(auto), "dumbbellpress,bicepscurl,burpees,shadowboxing,"
            .. "barbellcurl,squats,pushups,situp")
end)

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 6: an entry with no xpMod is still trained, ranked last")
-- ═══════════════════════════════════════════════════════════════════════════
-- xpMod is not a required field as far as this mod is concerned: a mod author
-- may simply omit it.  Reading it as 0 keeps the exercise reachable instead of
-- erroring the whole derivation on one malformed neighbour.

withExercise("mysteryflex", { type = "mysteryflex" }, function()
    local auto = pool(nil)
    assert_eq("the pool grew to eight", #auto, 8)
    assert_eq("the xpMod-less entry sorts last", auto[#auto], "mysteryflex")
    assert_eq("...and everything above it is unchanged",
        joined({ auto[1], auto[2], auto[3], auto[4], auto[5], auto[6], auto[7] }),
        V5_2_AUTO)
end)

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 7 (D2): the FOCUSED pools never see a newcomer")
-- ═══════════════════════════════════════════════════════════════════════════
-- A focused pool promises a specific stat, and which perk an unknown exercise
-- trains cannot be read from the vanilla table (it carries no perk field), so
-- strength and fitness stay the mod-side V3.2 map.

do
    assert_eq("strength pool, vanilla mirror", joined(pool("strength")), STRENGTH)
    assert_eq("fitness pool, vanilla mirror", joined(pool("fitness")), FITNESS)
end

withExercise("kettlebellswing", {
    type = "kettlebellswing", item = "Base.KettleBell", prop = "primary",
    xpMod = 1.5,
}, function()
    assert_eq("strength pool is byte-identical with a newcomer present",
        joined(pool("strength")), STRENGTH)
    assert_eq("fitness pool is byte-identical with a newcomer present",
        joined(pool("fitness")), FITNESS)
    assert_true("the newcomer is nowhere in the strength pool",
        not joined(pool("strength")):find("kettlebellswing", 1, true))
    assert_true("the newcomer is nowhere in the fitness pool",
        not joined(pool("fitness")):find("kettlebellswing", 1, true))
end)

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 8: the order does not depend on pairs() iteration order")
-- ═══════════════════════════════════════════════════════════════════════════
-- The reason KNOWN_RANK and the name tie-break exist.  Two exercises paying
-- the same xpMod must not swap places because the engine's table happened to
-- be built in a different order -- an auto day would silently start on a
-- different exercise.

do
    -- Same seven entries, inserted in the reverse of the mirror's own order.
    local names = {}
    for name in pairs(VANILLA) do names[#names + 1] = name end
    table.sort(names)
    local reversed = {}
    for i = #names, 1, -1 do reversed[names[i]] = VANILLA[names[i]] end
    FitnessExercises = { exercisesType = reversed }

    assert_eq("a table built in the opposite order yields the same pool",
        joined(pool(nil)), V5_2_AUTO)
    restoreVanilla()
end

-- ═══════════════════════════════════════════════════════════════════════════
print("\n-- Test 9: malformed neighbours are skipped, not fatal")
-- ═══════════════════════════════════════════════════════════════════════════
-- The table is other people's data.  A non-table value, or a numeric key from
-- an array-style append, must not take the trainer down with it.

do
    local copy = {}
    for k, v in pairs(VANILLA) do copy[k] = v end
    copy.broken = "not a table"
    copy[1] = { type = "arrayish", xpMod = 99 }
    FitnessExercises = { exercisesType = copy }

    local auto = pool(nil)
    assert_eq("the malformed entries are dropped", #auto, 7)
    assert_eq("...and the vanilla order survives them", joined(auto), V5_2_AUTO)
    restoreVanilla()
end

-- ── Results ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
