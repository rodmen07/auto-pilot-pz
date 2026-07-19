-- tests/test_leveler_metrics.lua
-- Tests for the V3.0 auto-leveler support modules:
--   AutoPilot_XP        — metrics engine (xp, rate, ETA)
--   AutoPilot_DeathLog  — decision ring + death snapshot + parse round-trip
--   AutoPilot_Adaptive  — aggregation + bounded rule application
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

-- ── Summary ──────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
