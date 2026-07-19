-- tests/test_leveler_metrics.lua
-- Tests for the V3.0 auto-leveler support modules:
--   AutoPilot_XP        — metrics engine (xp, rate, ETA)
--   AutoPilot_DeathLog  — decision ring + death snapshot + parse round-trip
--   AutoPilot_Adaptive  — aggregation + bounded rule application
--   AutoPilot_Leveler   -  focus selection/dispatch plus (V4.3, expansion
--                          candidate C3) the weekly training-program
--                          scheduler (program table, weekday resolution,
--                          rest-day yield, live-read program selection)
--
-- Run from the project root with standard Lua 5.1+:
--   lua tests/test_leveler_metrics.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Stub dependency modules (function-body references only) ──────────────────
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

AutoPilot_Home = {
    isSet    = function(_p) return false end,
    getState = function(_p) return nil end,
}

AutoPilot_Medical = {
    getWoundSnapshot = function(_p)
        return { bleeding = 0, deep_wounded = 0, bitten = false }
    end,
}

AutoPilot_Threat = {
    getNearbyZombies = function(_p) return {} end,
}

-- Leveler dependency: the exercise seam in Needs.
-- Calls are recorded as { focus_or_false } (false stands in for nil focus so
-- table.insert keeps the entry).
AutoPilot_Needs = {
    _trainCalls = {},
    trainExercise = function(player, focus)
        table.insert(AutoPilot_Needs._trainCalls, focus or false)
        return true
    end,
}

-- ── Load modules under test ──────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_XP.lua")
dofile("42/media/lua/client/AutoPilot_DeathLog.lua")
dofile("42/media/lua/client/AutoPilot_Adaptive.lua")
dofile("42/media/lua/client/AutoPilot_Leveler.lua")

-- ── Minimal test framework ───────────────────────────────────────────────────
local PASS, FAIL = 0, 0

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

local function assert_near(desc, got, expected, eps)
    eps = eps or 0.001
    if type(got) == "number" and math.abs(got - expected) <= eps then
        print(("  PASS  %s"):format(desc))
        PASS = PASS + 1
    else
        io.stderr:write(("  FAIL  %s  (got=%s, expected=%s)\n"):format(
            desc, tostring(got), tostring(expected)))
        FAIL = FAIL + 1
    end
end

-- ══ AutoPilot_XP ═════════════════════════════════════════════════════════════
print("=== XP Test 1: metrics shape and session gain ===")
do
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    local p = MockPlayer.new({ perks = { Carpentry = 2 } })
    p._xp.Carpentry = 210

    AutoPilot_XP.sample(p, "Carpentry")          -- baseline at 210
    MockRealTime.advance(60000)                   -- +1 min
    p._xp.Carpentry = 270                         -- +60 xp
    AutoPilot_XP.sample(p, "Carpentry")

    local m = AutoPilot_XP.getMetrics(p, "Carpentry")
    assert_eq("level read from perk level", m.level, 2)
    assert_eq("xp read from Xp store", m.xp, 270)
    -- Mock PerkFactory: level 3 threshold = 300 total XP.
    assert_eq("xpToNext = 300 - 270", m.xpToNext, 30)
    assert_eq("session gain since baseline", m.sessionGain, 60)
end

print("\n=== XP Test 2: XP/hour rate over the rolling window ===")
do
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    local p = MockPlayer.new({})
    p._xp.Strength = 0
    AutoPilot_XP.sample(p, "Strength")
    MockRealTime.advance(6 * 60 * 1000)           -- 6 real minutes (inside window)
    p._xp.Strength = 10                            -- +10 xp in 6 min
    AutoPilot_XP.sample(p, "Strength")

    assert_near("rate = 100 XP/hour", AutoPilot_XP.ratePerHour(p, "Strength"), 100, 0.01)

    local m = AutoPilot_XP.getMetrics(p, "Strength")
    -- level 0 -> next threshold 100 total; 90 remaining at 100/hr = 0.9 h
    assert_near("etaHours = 0.9", m.etaHours, 0.9, 0.01)

    -- Samples older than the window are pruned -> rate resets to unknown.
    MockRealTime.advance(30 * 60 * 1000)
    AutoPilot_XP.sample(p, "Strength")
    assert_eq("stale window prunes to zero rate",
        AutoPilot_XP.ratePerHour(p, "Strength"), 0)
end

print("\n=== XP Test 3: max level yields nil xpToNext and eta ===")
do
    AutoPilot_XP.resetAll()
    local p = MockPlayer.new({ perks = { Fitness = 10 } })
    p._xp.Fitness = 99999
    AutoPilot_XP.sample(p, "Fitness")
    local m = AutoPilot_XP.getMetrics(p, "Fitness")
    assert_eq("xpToNext nil at max level", m.xpToNext, nil)
    assert_eq("etaHours nil at max level", m.etaHours, nil)
end

print("\n=== XP Test 4: zero/negative XP delta yields zero rate ===")
do
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    local p = MockPlayer.new({})
    p._xp.Cooking = 500
    AutoPilot_XP.sample(p, "Cooking")
    MockRealTime.advance(60000)
    AutoPilot_XP.sample(p, "Cooking")             -- no gain
    assert_eq("no-gain rate is 0", AutoPilot_XP.ratePerHour(p, "Cooking"), 0)
end

-- V4.1 (C2): the engine is perk-generic, so Woodwork rides the same paths
-- the STR/FIT tests above exercise; these are the near-copies the proposal
-- calls for, keyed by the verified 42.19 perk name (Perks.Woodwork).
print("\n=== XP Test 5 (V4.1 C2): Woodwork metrics and session gain ===")
do
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    local p = MockPlayer.new({ perks = { Woodwork = 2 } })
    p._xp.Woodwork = 210

    AutoPilot_XP.sample(p, Perks.Woodwork)        -- baseline at 210
    MockRealTime.advance(60000)                   -- +1 min
    p._xp.Woodwork = 270                          -- +60 xp (game-granted)
    AutoPilot_XP.sample(p, Perks.Woodwork)

    local m = AutoPilot_XP.getMetrics(p, Perks.Woodwork)
    assert_eq("Woodwork level read from perk level", m.level, 2)
    assert_eq("Woodwork xp read from Xp store", m.xp, 270)
    -- Mock PerkFactory: level 3 threshold = 300 total XP.
    assert_eq("Woodwork xpToNext = 300 - 270", m.xpToNext, 30)
    assert_eq("Woodwork session gain since baseline", m.sessionGain, 60)
end

print("\n=== XP Test 6 (V4.1 C6): Doctor rate and ETA ===")
do
    AutoPilot_XP.resetAll()
    MockRealTime.set(0)
    local p = MockPlayer.new({})
    p._xp.Doctor = 0
    AutoPilot_XP.sample(p, Perks.Doctor)
    MockRealTime.advance(6 * 60 * 1000)           -- 6 real minutes (inside window)
    p._xp.Doctor = 10                             -- +10 xp in 6 min
    AutoPilot_XP.sample(p, Perks.Doctor)

    assert_near("Doctor rate = 100 XP/hour",
        AutoPilot_XP.ratePerHour(p, Perks.Doctor), 100, 0.01)

    local m = AutoPilot_XP.getMetrics(p, Perks.Doctor)
    -- level 0 -> next threshold 100 total; 90 remaining at 100/hr = 0.9 h
    assert_near("Doctor etaHours = 0.9", m.etaHours, 0.9, 0.01)
end

-- ══ AutoPilot_DeathLog ═══════════════════════════════════════════════════════
print("\n=== DeathLog Test 1: decision ring collapses duplicates and caps ===")
do
    AutoPilot_DeathLog.resetRings()
    local p = MockPlayer.new({})
    for _ = 1, 5 do
        AutoPilot_DeathLog.recordDecision(p, "idle", "no_action")
    end
    assert_eq("5 identical decisions collapse to 1",
        #AutoPilot_DeathLog.getRecentDecisions(p), 1)

    for i = 1, 30 do
        AutoPilot_DeathLog.recordDecision(p, "eat", "hunger" .. i)
    end
    assert_true("ring capped at 15",
        #AutoPilot_DeathLog.getRecentDecisions(p) <= 15)
end

print("\n=== DeathLog Test 2: snapshot write + parse round-trip ===")
do
    AutoPilot_DeathLog.resetRings()
    MockFiles["auto_pilot_deaths.log"] = nil
    local p = MockPlayer.new({
        stats = { HUNGER = 0.95, THIRST = 0.20 },
        hoursSurvived = 42,
    })
    AutoPilot_DeathLog.recordDecision(p, "loot", "supplies")
    AutoPilot_DeathLog.recordDecision(p, "eat", "hunger")

    assert_true("writeSnapshot returns true", AutoPilot_DeathLog.writeSnapshot(p))

    local lines = AutoPilot_DeathLog.readLines()
    assert_eq("one death line recorded", #lines, 1)

    local d = AutoPilot_DeathLog.parseLine(lines[1])
    assert_true("parse returns a table", type(d) == "table")
    assert_eq("cause classified as starvation (hunger 0.95)", d.cause, "starvation")
    assert_eq("hours survived recorded", d.hours, 42)
    assert_true("decisions recorded",
        tostring(d.decisions):find("eat:hunger") ~= nil)
end

print("\n=== DeathLog Test 3: cause classifier priorities ===")
do
    local base = {
        zombies = 0, bleeding = 0, bitten = false,
        hunger = 0, thirst = 0,
    }
    local function ctxWith(over)
        local c = {}
        for k, v in pairs(base) do c[k] = v end
        for k, v in pairs(over) do c[k] = v end
        -- classifier is applied inside collectContext; test via parse shape:
        -- reuse the module's internal ordering through a synthetic collect.
        return c
    end
    -- Direct classification via a synthetic player is complex; instead verify
    -- through writeSnapshot with tailored stats/zombies.
    MockFiles["auto_pilot_deaths.log"] = nil
    AutoPilot_Threat.getNearbyZombies = function(_p)
        local z = {}
        for i = 1, AutoPilot_Constants.FLEE_HORDE_SIZE do z[i] = { id = i } end
        return z
    end
    local p = MockPlayer.new({})
    AutoPilot_DeathLog.writeSnapshot(p)
    local d = AutoPilot_DeathLog.parseLine(AutoPilot_DeathLog.readLines()[1])
    assert_eq("horde-sized zombie count classifies as horde", d.cause, "horde")
    AutoPilot_Threat.getNearbyZombies = function(_p) return {} end
    local _ = ctxWith  -- silence unused-local in older luacheck configs
end

-- ══ AutoPilot_Adaptive ═══════════════════════════════════════════════════════
print("\n=== Adaptive Test 1: aggregation counts causes and away bucket ===")
do
    local deaths = {
        { cause = "horde", home_set = 1, dist_home = 10 },
        { cause = "horde", home_set = 1, dist_home = 100 },
        { cause = "starvation", home_set = 0, dist_home = 999 },
    }
    local counts = AutoPilot_Adaptive.aggregate(deaths)
    assert_eq("2 horde deaths", counts.horde, 2)
    assert_eq("1 starvation death", counts.starvation, 1)
    -- away only counts when home_set=1 and dist > threshold (60)
    assert_eq("1 away death (home set, dist 100)", counts.away, 1)
end

print("\n=== Adaptive Test 2: rules apply with floors and caps ===")
do
    local baseHorde  = AutoPilot_Constants.FLEE_HORDE_SIZE
    local baseHunger = AutoPilot_Constants.HUNGER_THRESHOLD

    -- 10 horde deaths would push FLEE_HORDE_SIZE to -4 without the floor.
    local applied = AutoPilot_Adaptive.applyRules({ horde = 10, starvation = 10 })
    assert_eq("FLEE_HORDE_SIZE floored at 3", AutoPilot_Constants.FLEE_HORDE_SIZE, 3)
    assert_eq("DETECTION_RADIUS capped at 30", AutoPilot_Constants.DETECTION_RADIUS, 30)
    assert_eq("HUNGER_THRESHOLD floored at 0.10",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.10)
    assert_true("adjustments recorded", #applied >= 3)

    -- Restore for other tests.
    AutoPilot_Constants.FLEE_HORDE_SIZE  = baseHorde
    AutoPilot_Constants.DETECTION_RADIUS = 20
    AutoPilot_Constants.HUNGER_THRESHOLD = baseHunger
    AutoPilot_Constants.SUPPLY_FOOD_MIN  = 3
end

print("\n=== Adaptive Test 3: min_deaths gate holds ===")
do
    local base = AutoPilot_Constants.FLEE_HORDE_SIZE
    local applied = AutoPilot_Adaptive.applyRules({ horde = 1 })  -- needs 2
    assert_eq("single horde death does not adjust FLEE_HORDE_SIZE",
        AutoPilot_Constants.FLEE_HORDE_SIZE, base)
    assert_eq("no adjustments applied", #applied, 0)
end

print("\n=== Adaptive Test 4: init reads death log once and is idempotent ===")
do
    AutoPilot_Adaptive.resetForTest()
    MockFiles["auto_pilot_deaths.log"] = { lines = {
        "schema=1,player=0,cause=dehydration,hours=5,x=0,y=0,z=0,outside=1,"
        .. "home_set=0,dist_home=0,zombies=0,hunger=0.10,thirst=0.95,"
        .. "fatigue=0.10,endurance=0.90,bleeding=0,deep_wound=0,bitten=0,"
        .. "skill=none,decisions=drink:thirst\n",
    }, appends = 0, truncates = 0 }

    local baseThirst = AutoPilot_Constants.THIRST_THRESHOLD
    AutoPilot_Adaptive.init()
    assert_near("THIRST_THRESHOLD lowered by one dehydration death",
        AutoPilot_Constants.THIRST_THRESHOLD, baseThirst - 0.03, 0.0001)

    local afterFirst = AutoPilot_Constants.THIRST_THRESHOLD
    AutoPilot_Adaptive.init()  -- second call must be a no-op
    assert_eq("second init() is a no-op",
        AutoPilot_Constants.THIRST_THRESHOLD, afterFirst)

    -- Restore.
    AutoPilot_Constants.THIRST_THRESHOLD = baseThirst
    AutoPilot_Constants.SUPPLY_DRINK_MIN = 2
end

-- ══ AutoPilot_Leveler (V3.1 exercise-focused scope) ══════════════════════════
print("\n=== Leveler Test 1: focus selection persists to ModData ===")
do
    AutoPilot_Leveler.resetForTest()
    local p = MockPlayer.new({})
    assert_eq("default focus is auto", AutoPilot_Leveler.getTargetSkillId(p), "auto")

    assert_true("setTargetSkill accepts strength",
        AutoPilot_Leveler.setTargetSkill(p, "strength"))
    assert_false("setTargetSkill rejects unknown id",
        AutoPilot_Leveler.setTargetSkill(p, "carpentry"))
    assert_eq("focus readable", AutoPilot_Leveler.getTargetSkillId(p), "strength")
    assert_eq("ModData persisted",
        p:getModData().AutoPilot_Leveler.target, "strength")

    -- Fresh cache (reload simulation): state reloads from ModData.
    AutoPilot_Leveler.resetForTest()
    assert_eq("focus reloaded from ModData after cache reset",
        AutoPilot_Leveler.getTargetSkillId(p), "strength")
end

print("\n=== Leveler Test 2: focus dispatch into the exercise seam ===")
do
    AutoPilot_Leveler.resetForTest()
    AutoPilot_Needs._trainCalls = {}
    local p = MockPlayer.new({})

    -- Default auto focus -> nil focus (auto-balance) passed to trainExercise.
    assert_true("auto focus queues exercise", AutoPilot_Leveler.check(p))
    assert_eq("auto focus passes nil (recorded as false)",
        AutoPilot_Needs._trainCalls[1], false)

    AutoPilot_Leveler.setTargetSkill(p, "fitness")
    assert_true("fitness focus queues exercise", AutoPilot_Leveler.check(p))
    assert_eq("fitness focus forwarded",
        AutoPilot_Needs._trainCalls[2], "fitness")

    AutoPilot_Leveler.setTargetSkill(p, "strength")
    assert_true("strength focus queues exercise", AutoPilot_Leveler.check(p))
    assert_eq("strength focus forwarded",
        AutoPilot_Needs._trainCalls[3], "strength")
end

print("\n=== Leveler Test 3: check samples XP for both exercise perks ===")
do
    AutoPilot_Leveler.resetForTest()
    AutoPilot_XP.resetAll()
    local p = MockPlayer.new({ perks = { Strength = 1, Fitness = 2 } })
    p._xp.Strength = 150
    p._xp.Fitness  = 250
    AutoPilot_Leveler.check(p)

    local mStr = AutoPilot_Leveler.getMetricsFor(p, "strength")
    local mFit = AutoPilot_Leveler.getMetricsFor(p, "fitness")
    assert_eq("strength metrics available", mStr and mStr.xp, 150)
    assert_eq("fitness metrics available", mFit and mFit.xp, 250)
    -- Mock PerkFactory: level 2 threshold = 200; level 3 = 300.
    assert_eq("strength xpToNext from cumulative table",
        mStr and mStr.xpToNext, 50)
    assert_eq("fitness xpToNext from cumulative table",
        mFit and mFit.xpToNext, 50)
end

print("\n=== Leveler Test 4 (V4.1): getMetricsFor serves woodwork/doctor ids ===")
do
    AutoPilot_Leveler.resetForTest()
    AutoPilot_XP.resetAll()
    local p = MockPlayer.new({ perks = { Woodwork = 1, Doctor = 2 } })
    p._xp.Woodwork = 150
    p._xp.Doctor   = 250

    local mWood = AutoPilot_Leveler.getMetricsFor(p, "woodwork")
    local mDoc  = AutoPilot_Leveler.getMetricsFor(p, "doctor")
    assert_eq("woodwork metrics available", mWood and mWood.xp, 150)
    assert_eq("doctor metrics available", mDoc and mDoc.xp, 250)
    assert_eq("woodwork level surfaces", mWood and mWood.level, 1)
    assert_eq("doctor level surfaces", mDoc and mDoc.level, 2)
    -- Mock PerkFactory: level 2 threshold = 200; level 3 = 300.
    assert_eq("woodwork xpToNext from cumulative table",
        mWood and mWood.xpToNext, 50)
    assert_eq("doctor xpToNext from cumulative table",
        mDoc and mDoc.xpToNext, 50)

    -- Unknown ids keep the pre-V4.1 fallback (Strength).
    p._xp.Strength = 42
    local mUnknown = AutoPilot_Leveler.getMetricsFor(p, "carpentry")
    assert_eq("unknown id falls back to Strength metrics",
        mUnknown and mUnknown.xp, 42)
end

-- ══ AutoPilot_Leveler training programs (V4.3, expansion candidate C3) ═══════
-- The scheduler is pure and the calendar rides the mock's MockTime clock:
-- weekday = (floor(ms / day) + 4) % 7 because epoch day zero (1970-01-01)
-- was a Thursday.  Day 3 is therefore a Sunday and day 4 a Monday.
local MS_DAY = 24 * 60 * 60 * 1000
local SUNDAY, MONDAY = 3 * MS_DAY, 4 * MS_DAY

print("\n=== Program Test 1 (V4.3): program table completeness ===")
do
    local valid = { auto = true, strength = true, fitness = true, rest = true }
    local wantIds = { "balanced", "strength", "fitness", "alternating",
                      "restsplit" }
    assert_eq("five presets defined", #AutoPilot_Leveler.PROGRAMS, 5)
    for i, id in ipairs(wantIds) do
        assert_eq("preset order stable (Options index mapping): " .. id,
            AutoPilot_Leveler.PROGRAMS[i] and AutoPilot_Leveler.PROGRAMS[i].id,
            id)
    end
    for _, prog in ipairs(AutoPilot_Leveler.PROGRAMS) do
        assert_true(prog.id .. " has a display name",
            type(prog.name) == "string" and #prog.name > 0)
        assert_eq(prog.id .. " covers all 7 weekdays", #prog.days, 7)
        local allValid = true
        for d = 1, 7 do
            if not valid[prog.days[d]] then allValid = false end
        end
        assert_true(prog.id .. " days are all auto/strength/fitness/rest",
            allValid)
        assert_eq(prog.id .. " lookup by id works",
            AutoPilot_Leveler.getProgramDef(prog.id), prog)
    end

    local function countDays(prog, v)
        local n = 0
        for d = 1, 7 do if prog.days[d] == v then n = n + 1 end end
        return n
    end
    -- Only the opt-in rest preset may ever idle the trainer (the V3.2
    -- starvation lesson: no compiled-in default may rest).
    for _, prog in ipairs(AutoPilot_Leveler.PROGRAMS) do
        if prog.id == "restsplit" then
            assert_eq("restsplit has exactly one rest day",
                countDays(prog, "rest"), 1)
        else
            assert_eq(prog.id .. " has zero rest days",
                countDays(prog, "rest"), 0)
        end
    end
    -- Balanced is all-auto: identical to the pre-V4.3 behavior.
    local bal = AutoPilot_Leveler.getProgramDef("balanced")
    assert_eq("balanced defers every day to the focus selection",
        countDays(bal, "auto"), 7)
    -- Emphasis ratios from the proposal: 5/2 splits.
    local emph = AutoPilot_Leveler.getProgramDef("strength")
    assert_eq("strength emphasis: 5 STR days", countDays(emph, "strength"), 5)
    assert_eq("strength emphasis: 2 FIT days", countDays(emph, "fitness"), 2)
    emph = AutoPilot_Leveler.getProgramDef("fitness")
    assert_eq("fitness emphasis: 5 FIT days", countDays(emph, "fitness"), 5)
    assert_eq("fitness emphasis: 2 STR days", countDays(emph, "strength"), 2)
end

print("\n=== Program Test 2 (V4.3): weekday from the verified calendar ===")
do
    MockTime.set(0)                              -- epoch day 0 = Thursday
    assert_eq("epoch day zero resolves to Thursday (4)",
        AutoPilot_Leveler.getWeekday(), 4)
    MockTime.set(SUNDAY)
    assert_eq("day 3 resolves to Sunday (0)", AutoPilot_Leveler.getWeekday(), 0)
    MockTime.set(MONDAY + 12 * 60 * 60 * 1000)   -- Monday midday
    assert_eq("midday keeps the same weekday (Monday 1)",
        AutoPilot_Leveler.getWeekday(), 1)
    MockTime.set(MONDAY + 7 * MS_DAY)
    assert_eq("a full week later wraps to the same weekday",
        AutoPilot_Leveler.getWeekday(), 1)
    MockTime.set(0)
end

print("\n=== Program Test 3 (V4.3): 14-day sweep per preset ===")
do
    -- Expected weeks (Sun..Sat) written out independently of the module's
    -- table, so an accidental preset edit fails here.
    local expectedWeek = {
        balanced    = { "auto", "auto", "auto", "auto", "auto", "auto",
                        "auto" },
        strength    = { "fitness", "strength", "strength", "fitness",
                        "strength", "strength", "strength" },
        fitness     = { "strength", "fitness", "fitness", "strength",
                        "fitness", "fitness", "fitness" },
        alternating = { "strength", "fitness", "strength", "fitness",
                        "strength", "fitness", "strength" },
        restsplit   = { "rest", "strength", "fitness", "strength",
                        "fitness", "strength", "fitness" },
    }
    for _, prog in ipairs(AutoPilot_Leveler.PROGRAMS) do
        local week = expectedWeek[prog.id]
        local want, got = {}, {}
        for day = 0, 13 do
            MockTime.set(SUNDAY + day * MS_DAY)  -- sweep starts on a Sunday
            table.insert(want, week[(day % 7) + 1])
            table.insert(got, AutoPilot_Leveler.resolveFocus(prog.id,
                AutoPilot_Leveler.getWeekday()))
        end
        assert_eq(prog.id .. ": 14 consecutive days repeat the weekly pattern",
            table.concat(got, ","), table.concat(want, ","))
    end
    MockTime.set(0)
end

print("\n=== Program Test 4 (V4.3): rest day yields the exercise slot ===")
do
    AutoPilot_Leveler.resetForTest()
    AutoPilot_XP.resetAll()
    AutoPilot_Needs._trainCalls = {}
    local p = MockPlayer.new({ perks = { Strength = 1 } })
    p._xp.Strength = 150

    AutoPilot_Constants.TRAINING_PROGRAM = "restsplit"
    MockTime.set(SUNDAY)
    assert_false("rest day: check yields (returns false)",
        AutoPilot_Leveler.check(p))
    assert_eq("rest day: trainExercise never called",
        #AutoPilot_Needs._trainCalls, 0)
    -- The yield skips training ONLY: metrics still sample, so the panel
    -- stays fresh through rest days.
    local m = AutoPilot_Leveler.getMetricsFor(p, "strength")
    assert_eq("rest day still samples XP metrics", m and m.xp, 150)

    -- The same Sunday under the default program trains as always: the
    -- yield belongs to the opt-in program, not to the weekday.
    AutoPilot_Constants.TRAINING_PROGRAM = "balanced"
    assert_true("same day, balanced program: trains",
        AutoPilot_Leveler.check(p))
    assert_eq("balanced Sunday dispatches into the seam",
        #AutoPilot_Needs._trainCalls, 1)

    -- A non-rest restsplit day trains with the program's day focus.
    AutoPilot_Constants.TRAINING_PROGRAM = "restsplit"
    MockTime.set(MONDAY)
    assert_true("restsplit Monday trains", AutoPilot_Leveler.check(p))
    assert_eq("restsplit Monday forwards strength",
        AutoPilot_Needs._trainCalls[2], "strength")

    AutoPilot_Constants.TRAINING_PROGRAM = "balanced"
    MockTime.set(0)
end

print("\n=== Program Test 5 (V4.3): day focus overrides, auto days defer ===")
do
    AutoPilot_Leveler.resetForTest()
    AutoPilot_Needs._trainCalls = {}
    local p = MockPlayer.new({})

    -- A program day focus overrides the F11 selection for that day.
    AutoPilot_Leveler.setTargetSkill(p, "strength")
    AutoPilot_Constants.TRAINING_PROGRAM = "strength"
    MockTime.set(SUNDAY)   -- Sunday is a FIT day under strength emphasis
    assert_true("strength emphasis Sunday trains", AutoPilot_Leveler.check(p))
    assert_eq("Sunday under strength emphasis forwards fitness",
        AutoPilot_Needs._trainCalls[1], "fitness")
    MockTime.set(MONDAY)
    AutoPilot_Leveler.check(p)
    assert_eq("Monday under strength emphasis forwards strength",
        AutoPilot_Needs._trainCalls[2], "strength")

    -- Alternating flips between consecutive days.
    AutoPilot_Constants.TRAINING_PROGRAM = "alternating"
    MockTime.set(SUNDAY)
    AutoPilot_Leveler.check(p)
    MockTime.set(MONDAY)
    AutoPilot_Leveler.check(p)
    assert_eq("alternating Sunday forwards strength",
        AutoPilot_Needs._trainCalls[3], "strength")
    assert_eq("alternating Monday forwards fitness",
        AutoPilot_Needs._trainCalls[4], "fitness")

    -- Auto days defer to the player's selection (pre-V4.3 behavior).
    AutoPilot_Constants.TRAINING_PROGRAM = "balanced"
    AutoPilot_Leveler.setTargetSkill(p, "fitness")
    AutoPilot_Leveler.check(p)
    assert_eq("balanced day defers to the selected fitness focus",
        AutoPilot_Needs._trainCalls[5], "fitness")
    AutoPilot_Leveler.setTargetSkill(p, "auto")
    AutoPilot_Leveler.check(p)
    assert_eq("balanced day with auto focus passes nil (recorded as false)",
        AutoPilot_Needs._trainCalls[6], false)

    MockTime.set(0)
end

print("\n=== Program Test 6 (V4.3): calendar absence falls back gracefully ===")
do
    AutoPilot_Leveler.resetForTest()
    AutoPilot_Needs._trainCalls = {}
    local p = MockPlayer.new({})
    AutoPilot_Leveler.setTargetSkill(p, "fitness")
    AutoPilot_Constants.TRAINING_PROGRAM = "restsplit"

    local savedGetGameTime = getGameTime
    getGameTime = function() error("no calendar in this environment") end

    assert_eq("weekday is nil without a calendar",
        AutoPilot_Leveler.getWeekday(), nil)
    assert_eq("nil weekday resolves to auto even under restsplit",
        AutoPilot_Leveler.resolveFocus("restsplit", nil), "auto")
    assert_eq("out-of-range weekday resolves to auto",
        AutoPilot_Leveler.resolveFocus("restsplit", 7), "auto")
    assert_true("check still trains without a calendar",
        AutoPilot_Leveler.check(p))
    assert_eq("always-on focus behavior preserved (player's fitness)",
        AutoPilot_Needs._trainCalls[1], "fitness")

    getGameTime = savedGetGameTime
    AutoPilot_Constants.TRAINING_PROGRAM = "balanced"
end

print("\n=== Program Test 7 (V4.3): ModOptions value is read live ===")
do
    AutoPilot_Leveler.resetForTest()
    AutoPilot_Needs._trainCalls = {}
    local p = MockPlayer.new({})
    MockTime.set(SUNDAY)

    -- The Leveler reads AutoPilot_Constants.TRAINING_PROGRAM at every check
    -- (the V3.3 live-read pattern).  That constant is exactly the seam
    -- Options.applyToConstants writes on options-save, so a mid-session
    -- write changes the very next cycle: no reload, no re-init.
    AutoPilot_Constants.TRAINING_PROGRAM = "balanced"
    assert_true("cycle 1 (balanced): trains", AutoPilot_Leveler.check(p))
    AutoPilot_Constants.TRAINING_PROGRAM = "restsplit"
    assert_false("cycle 2 (switched to restsplit, Sunday): rests",
        AutoPilot_Leveler.check(p))
    AutoPilot_Constants.TRAINING_PROGRAM = "fitness"
    AutoPilot_Leveler.check(p)
    assert_eq("cycle 3 (switched to fitness emphasis): forwards strength",
        AutoPilot_Needs._trainCalls[2], "strength")

    -- Unknown and missing values validate to balanced instead of failing.
    AutoPilot_Constants.TRAINING_PROGRAM = "bogus"
    assert_eq("unknown id validates to balanced",
        AutoPilot_Leveler.getProgramId(), "balanced")
    assert_true("unknown id still trains (balanced behavior)",
        AutoPilot_Leveler.check(p))
    AutoPilot_Constants.TRAINING_PROGRAM = nil
    assert_eq("missing id validates to balanced",
        AutoPilot_Leveler.getProgramId(), "balanced")

    AutoPilot_Constants.TRAINING_PROGRAM = "balanced"
    MockTime.set(0)
end

print("\n=== Program Test 8 (V4.3): panel status lines ===")
do
    MockTime.set(MONDAY)
    AutoPilot_Constants.TRAINING_PROGRAM = "strength"
    local st = AutoPilot_Leveler.getProgramStatus()
    assert_eq("status carries the program id", st.program, "strength")
    assert_eq("status resolves the day", st.day, "strength")
    assert_eq("proposal-format line",
        st.line, "today: STR day (program: Strength emphasis)")

    AutoPilot_Constants.TRAINING_PROGRAM = "restsplit"
    MockTime.set(SUNDAY)
    st = AutoPilot_Leveler.getProgramStatus()
    assert_eq("rest day is announced on the panel line", st.line,
        "today: rest day (program: Rest-day split), survival chores only")

    AutoPilot_Constants.TRAINING_PROGRAM = "balanced"
    st = AutoPilot_Leveler.getProgramStatus()
    assert_eq("balanced auto day line",
        st.line, "today: auto day (program: Balanced)")

    local savedGetGameTime = getGameTime
    getGameTime = function() error("no calendar") end
    st = AutoPilot_Leveler.getProgramStatus()
    assert_eq("calendar-absent line names the program",
        st.line, "program: Balanced (no calendar, focus always on)")
    assert_eq("calendar-absent day is nil", st.day, nil)
    getGameTime = savedGetGameTime

    AutoPilot_Constants.TRAINING_PROGRAM = "balanced"
    MockTime.set(0)
end

-- ── Summary ──────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
