-- tests/test_options_mapping.lua
-- V4.7: covers the AutoPilot_Options slider -> AutoPilot_Constants mapping.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_options_mapping.lua
--
-- Until V4.7 no suite loaded AutoPilot_Options at all (a DOCUMENTED GAP in
-- tests/lua_mock_pz.lua).  The widgets themselves stay playtest-only: what is
-- verified here is the pure data half of the page, namely that every DEFS
-- entry registers a slider seeded from the compiled-in default and that a
-- saved value lands in the right constant through the right scale.  The mock
-- below is suite-local ([S]) and covers ONLY the already-verified 42.19
-- surface AutoPilot_Options calls: create / addTitle / addSlider / addKeyBind
-- / getOption(id):getValue() / per-instance apply() / load.  No new engine
-- surface is introduced.

-- ── Suite-local PZAPI.ModOptions mock ─────────────────────────────────────────
-- Records registration order (titles included) so grouping can be asserted,
-- and lets a test write an option value the way the options screen would.
local REGISTERED = {}   -- ordered: { kind = "title"|"slider"|"keybind", ... }
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

PZAPI = {
    ModOptions = {
        create = function(_self, _id, _name) return page end,
        load   = function(_self) end,
    },
}

Keyboard = { KEY_F10 = 67, KEY_F11 = 68 }

-- ── Load constants, then the module under test ────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")
dofile("42/media/lua/client/AutoPilot_Options.lua")

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

-- Find the registered slider record for an id.
local function slider(id)
    for _, r in ipairs(REGISTERED) do
        if r.kind == "slider" and r.id == id then return r end
    end
    return nil
end

-- The title text that most recently preceded the given slider id.
local function groupOf(id)
    local title = nil
    for _, r in ipairs(REGISTERED) do
        if r.kind == "title" then title = r.name end
        if r.kind == "slider" and r.id == id then return title end
    end
    return nil
end

-- Write an options value and save the page, exactly as the screen does.
local function saveOption(id, value)
    OPTIONS[id]:setValue(value)
    page:apply()
end

print("=== AutoPilot_Options Mapping Tests (V4.7) ===")

print("\n-- Test 1: the page registered against the mocked PZAPI surface")
do
    assert_true("registration produced controls", #REGISTERED > 0)
    assert_true("arm key is registered", OPTIONS["armKey"] ~= nil)
    assert_true("panel key is registered", OPTIONS["panelKey"] ~= nil)
    assert_true("page exposes an apply() hook for options-save",
        type(page.apply) == "function")
end

print("\n-- Test 2 (V4.7): the hunger slider exists, in the survival group")
do
    local s = slider("hungerPct")
    assert_true("hungerPct slider registered", s ~= nil)
    assert_eq("player-facing name states the semantics",
        s.name, "Eat when hunger reaches (%)")
    assert_eq("min is 5%", s.min, 5)
    assert_eq("max is 50%", s.max, 50)
    assert_eq("step is 5%", s.step, 5)
    assert_eq("grouped under Survival Fail-Safe, not Training",
        groupOf("hungerPct"), "Survival Fail-Safe")
end

print("\n-- Test 3 (V4.7): the thirst slider mirrors it")
do
    local s = slider("thirstPct")
    assert_true("thirstPct slider registered", s ~= nil)
    assert_eq("player-facing name states the semantics",
        s.name, "Drink when thirst reaches (%)")
    assert_eq("same range as hunger (min)", s.min, slider("hungerPct").min)
    assert_eq("same range as hunger (max)", s.max, slider("hungerPct").max)
    assert_eq("same step as hunger", s.step, slider("hungerPct").step)
    assert_eq("grouped under Survival Fail-Safe",
        groupOf("thirstPct"), "Survival Fail-Safe")
end

print("\n-- Test 4 (V4.7): sliders are seeded from the UNCHANGED defaults")
do
    -- The point of V4.7 is tunability, not a retune: the shipped trigger
    -- points must still be 20% and the sliders must open showing that.
    assert_near("HUNGER_THRESHOLD default still 0.20",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.20, 1e-9)
    assert_near("THIRST_THRESHOLD default still 0.20",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.20, 1e-9)
    assert_near("hunger slider opens at 20", slider("hungerPct").default, 20, 1e-9)
    assert_near("thirst slider opens at 20", slider("thirstPct").default, 20, 1e-9)
end

print("\n-- Test 5 (V4.7): saving a value maps through the 0.01 scale")
do
    saveOption("hungerPct", 15)
    assert_near("slider 15 yields HUNGER_THRESHOLD 0.15",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.15, 1e-9)
    saveOption("thirstPct", 35)
    assert_near("slider 35 yields THIRST_THRESHOLD 0.35",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.35, 1e-9)

    -- Both ends of the range, and the round trip back to the default.
    saveOption("hungerPct", 5)
    assert_near("slider floor 5 yields 0.05",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.05, 1e-9)
    saveOption("hungerPct", 50)
    assert_near("slider ceiling 50 yields 0.50",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.50, 1e-9)
    saveOption("hungerPct", 20)
    assert_near("back to 20 restores the shipped 0.20",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.20, 1e-9)
    saveOption("thirstPct", 20)
    assert_near("thirst back to 20 restores the shipped 0.20",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.20, 1e-9)
end

print("\n-- Test 6: an unscaled neighbour is still copied verbatim")
do
    -- Guards against a scale leaking across DEFS entries.
    saveOption("foodMin", 4)
    assert_eq("foodMin is a raw count, not a fraction",
        AutoPilot_Constants.SUPPLY_FOOD_MIN, 4)
    saveOption("drinkMin", 3)
    assert_eq("drinkMin is a raw count", AutoPilot_Constants.SUPPLY_DRINK_MIN, 3)
    saveOption("detRadius", 16)
    assert_eq("detRadius is raw tiles", AutoPilot_Constants.DETECTION_RADIUS, 16)
end

print("\n-- Test 7: every registered slider round-trips its opening value")
do
    -- Re-saving the page without touching anything must be a no-op for every
    -- DEFS-backed constant, which is what proves each seed value and its
    -- scale are inverses (the seed is constant/scale, the apply is value*scale).
    local seeds = {}
    for _, r in ipairs(REGISTERED) do
        if r.kind == "slider" and r.id ~= "program" and r.id ~= "showActionHud" then
            seeds[r.id] = r.default
        end
    end
    for id, v in pairs(seeds) do OPTIONS[id]:setValue(v) end
    page:apply()
    assert_near("hunger unchanged by a no-op save",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.20, 1e-9)
    assert_near("thirst unchanged by a no-op save",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.20, 1e-9)
    assert_near("endurance minimum unchanged by a no-op save",
        AutoPilot_Constants.EXERCISE_ENDURANCE_MIN, 0.30, 1e-9)
    assert_eq("uncapped daily set cap (V4.6) survives a no-op save",
        AutoPilot_Constants.EXERCISE_DAILY_CAP, 0)
end

print("\n-- Test 8 (V5.4): the endurance-recovery sliders join the survival group")
do
    for _, id in ipairs({ "sitPct", "restTargetPct", "restHoldMin" }) do
        assert_true(id .. " slider registered", slider(id) ~= nil)
        assert_eq(id .. " grouped under Survival Fail-Safe",
            groupOf(id), "Survival Fail-Safe")
    end
    assert_eq("the sit slider names the behaviour it controls",
        slider("sitPct").name, "Sit to recover when endurance falls below (%)")
    assert_eq("the target slider names the behaviour it controls",
        slider("restTargetPct").name, "Stay seated until endurance reaches (%)")
    assert_eq("the hold slider is in GAME minutes, not real seconds",
        slider("restHoldMin").name, "Max time seated per rest (game minutes)")
end

print("\n-- Test 9 (V5.4): the sliders open on the shipped defaults")
do
    assert_near("ENDURANCE_SIT_MIN defaults to the exercise threshold",
        AutoPilot_Constants.ENDURANCE_SIT_MIN, 0.50, 1e-9)
    assert_near("ENDURANCE_REST_TARGET defaults to 0.70",
        AutoPilot_Constants.ENDURANCE_REST_TARGET, 0.70, 1e-9)
    assert_eq("REST_HOLD_MS defaults to 30 game minutes",
        AutoPilot_Constants.REST_HOLD_MS, 30 * 60 * 1000)
    assert_near("sit slider opens at 50",  slider("sitPct").default, 50, 1e-9)
    assert_near("target slider opens at 70",
        slider("restTargetPct").default, 70, 1e-9)
    assert_near("hold slider opens at 30", slider("restHoldMin").default, 30, 1e-9)
    -- The stand-up target must sit ABOVE the sit-down threshold or the
    -- character oscillates on one number.
    assert_true("the shipped target is above the shipped sit threshold",
        AutoPilot_Constants.ENDURANCE_REST_TARGET
            > AutoPilot_Constants.ENDURANCE_SIT_MIN)
end

print("\n-- Test 10 (V5.4): saving maps through the right scales")
do
    saveOption("sitPct", 65)
    assert_near("slider 65 yields ENDURANCE_SIT_MIN 0.65",
        AutoPilot_Constants.ENDURANCE_SIT_MIN, 0.65, 1e-9)
    saveOption("restTargetPct", 85)
    assert_near("slider 85 yields ENDURANCE_REST_TARGET 0.85",
        AutoPilot_Constants.ENDURANCE_REST_TARGET, 0.85, 1e-9)
    saveOption("restHoldMin", 45)
    assert_eq("slider 45 yields 45 game minutes in ms",
        AutoPilot_Constants.REST_HOLD_MS, 45 * 60000)
    saveOption("restHoldMin", 5)
    assert_eq("the floor is 5 game minutes, still far past the old 60000 ms",
        AutoPilot_Constants.REST_HOLD_MS, 5 * 60000)
    assert_true("even the floor outlasts the pre-V5.4 one-minute hold",
        AutoPilot_Constants.REST_HOLD_MS > 60000)

    -- Restore the shipped defaults for the no-op round-trip below.
    saveOption("sitPct", 50)
    saveOption("restTargetPct", 70)
    saveOption("restHoldMin", 30)
    assert_near("back to the shipped sit threshold",
        AutoPilot_Constants.ENDURANCE_SIT_MIN, 0.50, 1e-9)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
