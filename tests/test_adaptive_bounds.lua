-- tests/test_adaptive_bounds.lua
-- QA (2026-08-08): the death-learning layer's bounds are DIRECTIONAL, not
-- absolute -- an adjustment may never move a constant BACKWARDS past where it
-- started.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- AutoPilot_Adaptive reads the death log at session start and nudges tuning
-- constants so the mod stops repeating a recorded death.  Every rule carries a
-- `floor` or a `cap` so the mod can never tune itself into absurd behaviour.
--
-- Those floors and caps were written against the SHIPPED DEFAULTS in
-- AutoPilot_Constants.  They are APPLIED on top of whatever the player
-- configured, because AutoPilot_Main runs AutoPilot_Options.applyOnce first
-- and AutoPilot_Adaptive.init second (Main.lua, "Player-configured options
-- first, THEN the death-learning deltas on top").  For any player value that
-- already sits outside a rule's bound, `math.max(floor, to)` / `math.min(cap,
-- to)` therefore moved the constant in the direction OPPOSITE to the rule's
-- own stated purpose, and recorded the move in AutoPilot_Adaptive.applied so
-- the F11 panel advertised it as an improvement.  Five of the eight rules are
-- reachable this way through the shipped options screen:
--
--   HUNGER_THRESHOLD   player 5%  + 1 starvation death  -> raised to 10%
--                      ("Starved -> eat earlier" made it eat LATER)
--   THIRST_THRESHOLD   player 5%  + 1 dehydration death -> raised to 10%
--   SUPPLY_FOOD_MIN    player 8   + 1 starvation death  -> lowered to 6
--                      ("stockpile more food" stockpiled LESS)
--   SUPPLY_DRINK_MIN   player 8   + 1 dehydration death -> lowered to 5
--   DETECTION_RADIUS   player 40  + 2 horde deaths      -> shrunk to 30
--                      ("see further" saw LESS far)
--
-- The four pre-existing Adaptive tests in tests/test_leveler_metrics.lua could
-- not catch any of it: every one of them starts from the compiled-in default,
-- which is inside every bound by construction.  That is the general shape --
-- a guard whose two sides are each produced from CONFIG must be run across the
-- option space the user can actually reach, not at the shipped point.
--
-- So this suite derives the option space by REGISTERING THE REAL OPTIONS PAGE
-- against a recording mock and reading each slider's own min/max back out,
-- then drives every AutoPilot_Adaptive.RULES entry across it.  Neither side is
-- hand-transcribed: a new slider, a widened range, or a new rule is picked up
-- automatically, and a range that stops overlapping a bound stops being tested
-- for free.
--
-- The mock below is suite-local ([S]) and models ONLY the already-verified
-- 42.19 surface AutoPilot_Options calls -- the same surface, and the same
-- shape, as tests/test_options_mapping.lua.  No new engine surface is
-- introduced.
--
-- Run from the project root with standard Lua 5.1+:
--   lua tests/test_adaptive_bounds.lua

-- ── Suite-local PZAPI.ModOptions mock ─────────────────────────────────────────
local REGISTERED = {}   -- ordered: { kind = "slider"|"title"|"keybind", ... }
local OPTIONS    = {}   -- id -> option object

local function _mkOption(id, value)
    local o = { id = id, _value = value }
    function o:getValue() return self._value end
    function o:setValue(v) self._value = v end
    OPTIONS[id] = o
    return o
end

local page = {}
function page:addTitle(text)
    table.insert(REGISTERED, { kind = "title", name = text })
end
function page:addSlider(id, name, min, max, step, default)
    table.insert(REGISTERED, {
        kind = "slider", id = id, name = name,
        min = min, max = max, step = step, default = default,
    })
    _mkOption(id, default)
end
function page:addKeyBind(id, name, default)
    table.insert(REGISTERED, { kind = "keybind", id = id, name = name })
    _mkOption(id, default)
end
function page:getOption(id) return OPTIONS[id] end
-- Present and callable, populating nothing: the observed 42.19 behaviour, kept
-- so this suite exercises the same registration path the live client takes.
function page:addComboBox(_id, _name, _items, _default) end

PZAPI = {
    ModOptions = {
        create = function(_self, _id, _name) return page end,
        load   = function(_self) end,
    },
}

Keyboard = { KEY_F10 = 67, KEY_F11 = 68 }

-- ── Load constants, then the modules under test ───────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")
dofile("42/media/lua/client/AutoPilot_Leveler.lua")
dofile("42/media/lua/client/AutoPilot_Options.lua")
dofile("42/media/lua/client/AutoPilot_Adaptive.lua")

-- ── Minimal test framework (same shape as the other suites) ───────────────────
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

local function assert_near(desc, got, expected, tol)
    if type(got) == "number" and math.abs(got - expected) <= (tol or 1e-9) then
        print(("  PASS  %s"):format(desc))
        PASS = PASS + 1
    else
        io.stderr:write(("  FAIL  %s  (got=%s, expected=%s)\n"):format(
            desc, tostring(got), tostring(expected)))
        FAIL = FAIL + 1
    end
end

local function assert_true(desc, val) assert_eq(desc, not not val, true) end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Snapshot every numeric top-level field of AutoPilot_Constants.
local function snapshotConstants()
    local snap = {}
    for k, v in pairs(AutoPilot_Constants) do
        if type(v) == "number" then snap[k] = v end
    end
    return snap
end

local function restoreConstants(snap)
    for k, v in pairs(snap) do AutoPilot_Constants[k] = v end
end

-- Set one option value and save the page, exactly as the options screen does.
local function saveOption(id, value)
    OPTIONS[id]:setValue(value)
    page:apply()
end

-- Which numeric constants moved between two snapshots.
local function movedKeys(before)
    local moved = {}
    for k, v in pairs(AutoPilot_Constants) do
        if type(v) == "number" and before[k] ~= v then
            table.insert(moved, k)
        end
    end
    table.sort(moved)
    return moved
end

-- ── Derive the reachable option space, by RUNNING the real page ───────────────
-- OPTION_SPACE[constantKey] = { id = <sliderId>, lo = <value at slider min>,
--                               hi = <value at slider max> }, in CONSTANT units
-- (so the per-slider `scale` is applied by the production code, never guessed
-- here).  Discovery is behavioural: move one slider, see which constant moves.
local OPTION_SPACE = {}
local SLIDERS      = {}

do
    page:apply()  -- sync every constant to its registered default first
    for _, r in ipairs(REGISTERED) do
        if r.kind == "slider" then
            table.insert(SLIDERS, r)
            local orig  = OPTIONS[r.id]:getValue()
            local probe = (orig == r.max) and r.min or r.max
            local before = snapshotConstants()
            saveOption(r.id, probe)
            local moved = movedKeys(before)
            if #moved == 1 then
                local key = moved[1]
                saveOption(r.id, r.min)
                local lo = AutoPilot_Constants[key]
                saveOption(r.id, r.max)
                local hi = AutoPilot_Constants[key]
                OPTION_SPACE[key] = { id = r.id, lo = lo, hi = hi }
            end
            saveOption(r.id, orig)
        end
    end
end

print("=== AutoPilot_Adaptive directional-bounds tests (QA 2026-08-08) ===")

print("\n-- Test 1: both sides of the guard were discovered, not transcribed")
do
    assert_true("the options page registered sliders", #SLIDERS > 0)
    assert_true("AutoPilot_Adaptive exposes its rule table",
        type(AutoPilot_Adaptive.RULES) == "table")
    assert_true("the rule table is non-empty", #AutoPilot_Adaptive.RULES > 0)

    -- Zero overlap would make every case below vacuous, so it is a hard
    -- failure rather than a quiet skip (a rule key that no slider reaches is
    -- fine; ALL of them being unreachable means discovery broke).
    local shared, keys = 0, {}
    for _, rule in ipairs(AutoPilot_Adaptive.RULES) do
        if OPTION_SPACE[rule.key] and not keys[rule.key] then
            keys[rule.key] = true
            shared = shared + 1
        end
    end
    assert_true("at least one rule key is player-configurable", shared > 0)
    print(("  (info) %d rule(s), %d player-configurable rule key(s)"):format(
        #AutoPilot_Adaptive.RULES, shared))
end

print("\n-- Test 2: no rule moves a constant against its own per_death sign,")
print("           anywhere in the reachable option range")
do
    local saved = snapshotConstants()
    local cases = 0
    for _, rule in ipairs(AutoPilot_Adaptive.RULES) do
        -- Start values: the shipped default, plus both ends of the slider
        -- range when the key is player-configurable.
        local starts = { saved[rule.key] }
        local space  = OPTION_SPACE[rule.key]
        if space then
            table.insert(starts, space.lo)
            table.insert(starts, space.hi)
        end
        for _, from in ipairs(starts) do
            for _, n in ipairs({ rule.min_deaths or 1, (rule.min_deaths or 1) + 1, 50 }) do
                restoreConstants(saved)
                AutoPilot_Constants[rule.key] = from
                AutoPilot_Adaptive.applyRules({ [rule.cause] = n })
                local to    = AutoPilot_Constants[rule.key]
                local delta = to - from
                cases = cases + 1
                assert_true(("%s from %s, %d %s death(s): moved %s, never against %s")
                    :format(rule.key, tostring(from), n, rule.cause,
                            tostring(delta), tostring(rule.per_death)),
                    delta * rule.per_death >= 0)
            end
        end
    end
    assert_true("the sweep ran a non-trivial number of cases", cases >= 24)
    restoreConstants(saved)
end

print("\n-- Test 3: a no-op adjustment is not RECORDED as an adjustment")
print("           (the F11 panel must not advertise a move that did not happen)")
do
    local saved = snapshotConstants()
    for _, rule in ipairs(AutoPilot_Adaptive.RULES) do
        local space = OPTION_SPACE[rule.key]
        if space then
            -- The end of the slider range that sits PAST this rule's bound.
            local from = (rule.per_death < 0) and space.lo or space.hi
            local bound = (rule.per_death < 0) and rule.floor or rule.cap
            if bound and ((rule.per_death < 0 and from < bound)
                       or (rule.per_death > 0 and from > bound)) then
                restoreConstants(saved)
                AutoPilot_Constants[rule.key] = from
                local applied = AutoPilot_Adaptive.applyRules(
                    { [rule.cause] = (rule.min_deaths or 1) })
                local recorded = false
                for _, a in ipairs(applied) do
                    if a.key == rule.key then recorded = true end
                end
                assert_true(("%s at the player value %s is left alone")
                    :format(rule.key, tostring(from)),
                    AutoPilot_Constants[rule.key] == from)
                assert_true(("...and nothing is recorded for %s"):format(rule.key),
                    not recorded)
            end
        end
    end
    restoreConstants(saved)
end

print("\n-- Test 4: the five reachable inversions, stated one by one")
do
    local saved = snapshotConstants()

    -- 4a. "Starved -> eat earlier" must not make the mod eat LATER.
    restoreConstants(saved)
    AutoPilot_Constants.HUNGER_THRESHOLD = 0.05   -- slider min, "Eat at 5%"
    AutoPilot_Adaptive.applyRules({ starvation = 1 })
    assert_near("hunger 5% + 1 starvation death stays at 5% (was raised to 10%)",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.05, 1e-9)

    -- 4b. Same for thirst.
    restoreConstants(saved)
    AutoPilot_Constants.THIRST_THRESHOLD = 0.05
    AutoPilot_Adaptive.applyRules({ dehydration = 1 })
    assert_near("thirst 5% + 1 dehydration death stays at 5% (was raised to 10%)",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.05, 1e-9)

    -- 4c. "Starved -> stockpile more food" must not stockpile LESS.
    restoreConstants(saved)
    AutoPilot_Constants.SUPPLY_FOOD_MIN = 8       -- slider max
    AutoPilot_Adaptive.applyRules({ starvation = 1 })
    assert_eq("food stockpile 8 + 1 starvation death stays 8 (was cut to 6)",
        AutoPilot_Constants.SUPPLY_FOOD_MIN, 8)

    -- 4d. Same for drinks.
    restoreConstants(saved)
    AutoPilot_Constants.SUPPLY_DRINK_MIN = 8
    AutoPilot_Adaptive.applyRules({ dehydration = 1 })
    assert_eq("drink stockpile 8 + 1 dehydration death stays 8 (was cut to 5)",
        AutoPilot_Constants.SUPPLY_DRINK_MIN, 8)

    -- 4e. "Died to hordes -> see further" must not shrink the radius.
    restoreConstants(saved)
    AutoPilot_Constants.DETECTION_RADIUS = 40     -- slider max
    AutoPilot_Adaptive.applyRules({ horde = 2 })
    assert_eq("detection radius 40 + 2 horde deaths stays 40 (was shrunk to 30)",
        AutoPilot_Constants.DETECTION_RADIUS, 40)

    -- 4f. ...and the horde rule's OTHER key still adjusts on the same call,
    -- so 4e is a directional clamp and not a dead rule.
    assert_eq("the same horde call still lowers FLEE_HORDE_SIZE 6 -> 4",
        AutoPilot_Constants.FLEE_HORDE_SIZE, 4)

    restoreConstants(saved)
end

print("\n-- Test 5: behaviour at the shipped defaults is UNCHANGED")
print("           (the bounds still bind when the start value is inside them)")
do
    local saved = snapshotConstants()

    restoreConstants(saved)
    local applied = AutoPilot_Adaptive.applyRules({ horde = 10, starvation = 10 })
    assert_eq("FLEE_HORDE_SIZE still floors at 3", AutoPilot_Constants.FLEE_HORDE_SIZE, 3)
    assert_eq("DETECTION_RADIUS still caps at 30", AutoPilot_Constants.DETECTION_RADIUS, 30)
    assert_near("HUNGER_THRESHOLD still floors at 0.10",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.10, 1e-9)
    assert_eq("SUPPLY_FOOD_MIN still caps at 6", AutoPilot_Constants.SUPPLY_FOOD_MIN, 6)
    assert_true("all four are still recorded as applied", #applied >= 4)

    restoreConstants(saved)
    local one = AutoPilot_Adaptive.applyRules({ dehydration = 1 })
    assert_near("one dehydration death still lowers thirst by exactly 0.03",
        AutoPilot_Constants.THIRST_THRESHOLD, saved.THIRST_THRESHOLD - 0.03, 1e-9)
    assert_eq("...and still raises the drink stockpile by exactly 1",
        AutoPilot_Constants.SUPPLY_DRINK_MIN, saved.SUPPLY_DRINK_MIN + 1)
    assert_eq("both moves recorded", #one, 2)

    restoreConstants(saved)
    local none = AutoPilot_Adaptive.applyRules({ horde = 1 })  -- min_deaths is 2
    assert_eq("the min_deaths gate still holds", #none, 0)
    assert_eq("...and FLEE_HORDE_SIZE did not move",
        AutoPilot_Constants.FLEE_HORDE_SIZE, saved.FLEE_HORDE_SIZE)

    restoreConstants(saved)
end

print("\n-- Test 6: aggregate() -- first coverage of the window and the")
print("           away bucket, both derived rather than transcribed")
do
    -- Derive the window size by saturation: feeding more deaths than the
    -- window can hold must stop raising the count.
    local function nDeaths(n, cause)
        local t = {}
        for _ = 1, n do
            table.insert(t, { cause = cause, home_set = 0, dist_home = 0 })
        end
        return t
    end
    local at40  = AutoPilot_Adaptive.aggregate(nDeaths(40, "horde")).horde
    local at100 = AutoPilot_Adaptive.aggregate(nDeaths(100, "horde")).horde
    assert_eq("the window saturates (40 and 100 deaths agree)", at40, at100)
    assert_true("...below the number fed in", at40 < 40)

    -- The window keeps the NEWEST deaths: one extra old death of another
    -- cause must fall out entirely.
    local window = at40
    local deaths = { { cause = "starvation", home_set = 0, dist_home = 0 } }
    for _, d in ipairs(nDeaths(window, "horde")) do table.insert(deaths, d) end
    local counts = AutoPilot_Adaptive.aggregate(deaths)
    assert_eq("the oldest death outside the window is dropped", counts.starvation, nil)
    assert_eq("...and the window is full of the newest ones", counts.horde, window)

    -- The away bucket needs BOTH a set home and a distance past the threshold.
    local away = AutoPilot_Adaptive.aggregate({
        { cause = "horde", home_set = 1, dist_home = 1000 },  -- counts
        { cause = "horde", home_set = 0, dist_home = 1000 },  -- no home set
        { cause = "horde", home_set = 1, dist_home = 0 },     -- at home
    })
    assert_eq("only the far-from-a-set-home death is away", away.away, 1)
    assert_eq("...and all three still count toward their cause", away.horde, 3)

    -- A row with no cause is skipped rather than counted under nil.
    local skipped = AutoPilot_Adaptive.aggregate({
        { home_set = 1, dist_home = 1000 },
        { cause = "bleed_out", home_set = 0, dist_home = 0 },
    })
    assert_eq("a causeless row contributes nothing", skipped.away, nil)
    assert_eq("...and the valid row still counts", skipped.bleed_out, 1)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
