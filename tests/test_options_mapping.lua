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

-- V5.7: model the REAL 42.19 client, where addComboBox EXISTS on the page and
-- calling it SUCCEEDS.  That combination is precisely why the pre-V5.7 guard
-- (`type(o.addComboBox) == "function" and pcall(...)`) was satisfied while the
-- widget still drew with no items in it, and why no suite could catch the bug:
-- the old mock simply had no addComboBox, so every test run took the fallback
-- path that the live client never took.  This one accepts the call happily and
-- records it, so a test can assert the module does not go anywhere near it.
local COMBO_CALLS = {}
function page:addComboBox(id, name, items, default)
    table.insert(COMBO_CALLS, {
        id = id, name = name, items = items, default = default,
    })
    -- Deliberately returns nothing and populates nothing: the observed
    -- in-game behaviour of this call shape.
end

PZAPI = {
    ModOptions = {
        create = function(_self, _id, _name) return page end,
        load   = function(_self) end,
    },
}

Keyboard = { KEY_F10 = 67, KEY_F11 = 68 }

-- ── Load constants, then the module under test ────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")
-- V5.7: the REAL program table, not a stub.  AutoPilot_Options builds the
-- training-program control from AutoPilot_Leveler.PROGRAMS, so without this
-- the control was never registered at all in this suite and the empty-dropdown
-- bug had nowhere to show up.  The Leveler loads cleanly against nothing but
-- Constants (it is a pure data + scheduling module).
dofile("42/media/lua/client/AutoPilot_Leveler.lua")
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

print("\n-- Test 4 (V5.7): sliders are seeded from the shipped defaults")
do
    -- V5.7 adopts the values the user dialled in during live play as the
    -- shipped defaults ("I adjusted the settings, set these as the
    -- defaults"): hunger and thirst moved 0.20 -> 0.15.  The seam is
    -- unchanged; only the numbers moved, and the sliders must open on them.
    assert_near("HUNGER_THRESHOLD default is the user's 0.15",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.15, 1e-9)
    assert_near("THIRST_THRESHOLD default is the user's 0.15",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.15, 1e-9)
    assert_near("hunger slider opens at 15", slider("hungerPct").default, 15, 1e-9)
    assert_near("thirst slider opens at 15", slider("thirstPct").default, 15, 1e-9)
    -- Both are representable on their own slider (min 5, max 50, step 5), so
    -- the shipped default is a value the player can actually return to.
    for _, id in ipairs({ "hungerPct", "thirstPct" }) do
        local s = slider(id)
        assert_true(id .. " default is on a step boundary",
            math.abs((s.default - s.min) % s.step) < 1e-9)
        assert_true(id .. " default is inside its range",
            s.default >= s.min and s.default <= s.max)
    end
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
    saveOption("hungerPct", 15)
    assert_near("back to 15 restores the shipped 0.15",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.15, 1e-9)
    saveOption("thirstPct", 15)
    assert_near("thirst back to 15 restores the shipped 0.15",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.15, 1e-9)
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
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.15, 1e-9)
    assert_near("thirst unchanged by a no-op save",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.15, 1e-9)
    assert_near("endurance resume gate unchanged by a no-op save",
        AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME, 0.90, 1e-9)
    assert_near("endurance floor unchanged by a no-op save",
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

print("\n-- Test 9 (V5.7): the sliders open on the shipped defaults")
do
    assert_near("ENDURANCE_SIT_MIN sits just above the training floor",
        AutoPilot_Constants.ENDURANCE_SIT_MIN, 0.35, 1e-9)
    assert_near("ENDURANCE_REST_TARGET defaults to 0.95",
        AutoPilot_Constants.ENDURANCE_REST_TARGET, 0.95, 1e-9)
    assert_eq("REST_HOLD_MS defaults to 30 game minutes",
        AutoPilot_Constants.REST_HOLD_MS, 30 * 60 * 1000)
    assert_near("sit slider opens at 35",  slider("sitPct").default, 35, 1e-9)
    assert_near("target slider opens at 95",
        slider("restTargetPct").default, 95, 1e-9)
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
    saveOption("sitPct", 35)
    saveOption("restTargetPct", 95)
    saveOption("restHoldMin", 30)
    assert_near("back to the shipped sit threshold",
        AutoPilot_Constants.ENDURANCE_SIT_MIN, 0.35, 1e-9)
end

-- ══ V5.7 ═════════════════════════════════════════════════════════════════════

print("\n-- Test 11 (V5.7): the user's tuned values ARE the shipped defaults")
do
    -- Verbatim from live play: "I adjusted the settings, set these as the
    -- defaults", and for the endurance slider "I set it to 90, keep it as
    -- default".  Hunger and thirst land exactly as asked.
    assert_near("Eat when hunger reaches = 15%",
        AutoPilot_Constants.HUNGER_THRESHOLD, 0.15, 1e-9)
    assert_near("Drink when thirst reaches = 15%",
        AutoPilot_Constants.THIRST_THRESHOLD, 0.15, 1e-9)

    -- The endurance 90 belongs to the RESUME gate.  It was given against the
    -- only endurance slider the page had, and that slider was doing two jobs
    -- at once; as a start-a-run gate 90 is exactly right, as a stop-training
    -- gate it was the single-rep bug.  The user worked this out live: "I see
    -- that the minimum endurance default of 90 is too high, but at the same
    -- time, I want the character to rest until endurance is nearly full."
    assert_near("Resume training when endurance reaches = 90%",
        AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME, 0.90, 1e-9)
    assert_near("Keep training until endurance falls to = 30%",
        AutoPilot_Constants.EXERCISE_ENDURANCE_MIN, 0.30, 1e-9)
    -- "rest until endurance is nearly full", verbatim.
    assert_near("Stay seated until endurance reaches = 95%",
        AutoPilot_Constants.ENDURANCE_REST_TARGET, 0.95, 1e-9)
    -- Sitting begins where training stops, just above the floor.
    assert_near("Sit to recover below = 35%",
        AutoPilot_Constants.ENDURANCE_SIT_MIN, 0.35, 1e-9)

    -- Every one of them must open its slider on that exact value, be inside
    -- its range, and land on a step boundary, or the "default" is a number
    -- the player can look at but never return to.
    local expect = {
        endMin        = 90,
        endFloor      = 30,
        hungerPct     = 15,
        thirstPct     = 15,
        restTargetPct = 95,
        sitPct        = 35,
    }
    for id, want in pairs(expect) do
        local sl = slider(id)
        assert_true(id .. " is registered", sl ~= nil)
        assert_near(id .. " opens on the shipped default", sl.default, want, 1e-9)
        assert_true(id .. " default is within range",
            sl.default >= sl.min and sl.default <= sl.max)
        assert_true(id .. " default sits on a step boundary",
            math.abs((sl.default - sl.min) % sl.step) < 1e-9)
    end
end

print("\n-- Test 12 (V5.7): the hysteresis and dead-zone invariants hold")
do
    -- The whole design rests on one ordering.  Assert it directly, so a
    -- future default tweak cannot quietly collapse the pair back into a
    -- single number (the single-rep bug) or reopen the idle band.
    assert_true("the training floor is BELOW the resume gate (hysteresis)",
        AutoPilot_Constants.EXERCISE_ENDURANCE_MIN
            < AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME)
    assert_true("...with a wide gap, so one rest buys many reps",
        AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
            - AutoPilot_Constants.EXERCISE_ENDURANCE_MIN >= 0.25)
    assert_true("the stand-up target clears the resume gate",
        AutoPilot_Constants.ENDURANCE_REST_TARGET
            > AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME)
    assert_true("the sit threshold is above the training floor",
        AutoPilot_Constants.ENDURANCE_SIT_MIN
            > AutoPilot_Constants.EXERCISE_ENDURANCE_MIN)
    assert_true("the sit threshold is below the resume gate",
        AutoPilot_Constants.ENDURANCE_SIT_MIN
            < AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME)
    assert_true("the stand-up target is above the sit threshold (no thrash)",
        AutoPilot_Constants.ENDURANCE_REST_TARGET
            > AutoPilot_Constants.ENDURANCE_SIT_MIN)
end


print("\n-- Test 13 (V5.7): the training program is a POPULATED slider,"
    .. " never an unverified combo box")
do
    -- The bug: on a real client addComboBox exists and the call succeeds, so
    -- the old `type(...) == "function" and pcall(...)` guard passed and the
    -- fallback never fired, yet the dropdown drew with zero items in it.  The
    -- mock above reproduces exactly that surface.
    assert_eq("addComboBox is available on the mocked page, as in game",
        type(page.addComboBox), "function")
    assert_eq("...and the module still does not call it", #COMBO_CALLS, 0)

    local s = slider("program")
    assert_true("the program control is registered as a slider", s ~= nil)
    assert_eq("it spans every program, starting at 1", s.min, 1)
    assert_eq("...and ending at the last program",
        s.max, #AutoPilot_Leveler.PROGRAMS)
    assert_eq("one program per step", s.step, 1)
    assert_true("more than one program is actually offered", s.max > 1)
    assert_eq("it opens on the shipped program (balanced = 1)", s.default, 1)
    assert_eq("it is grouped with Training, not the survival sliders",
        groupOf("program"), "Training")
    -- The label has to carry the legend the dropdown would have shown, or the
    -- numbers on the slider mean nothing to the player.
    for i, prog in ipairs(AutoPilot_Leveler.PROGRAMS) do
        assert_true(("the label names program %d (%s)"):format(i, prog.name),
            s.name:find(i .. " " .. prog.name, 1, true) ~= nil)
    end
end

print("\n-- Test 14 (V5.7): every program index selects the right program")
do
    local saved = AutoPilot_Constants.TRAINING_PROGRAM
    for i, prog in ipairs(AutoPilot_Leveler.PROGRAMS) do
        saveOption("program", i)
        assert_eq(("slider %d selects %s"):format(i, prog.id),
            AutoPilot_Constants.TRAINING_PROGRAM, prog.id)
    end
    -- Out-of-range values must leave the constant alone rather than guess.
    saveOption("program", #AutoPilot_Leveler.PROGRAMS + 1)
    assert_eq("an index past the last program changes nothing",
        AutoPilot_Constants.TRAINING_PROGRAM,
        AutoPilot_Leveler.PROGRAMS[#AutoPilot_Leveler.PROGRAMS].id)
    saveOption("program", 1)
    assert_eq("back to the first program", AutoPilot_Constants.TRAINING_PROGRAM,
        AutoPilot_Leveler.PROGRAMS[1].id)
    AutoPilot_Constants.TRAINING_PROGRAM = saved
end

print("\n-- Test 15 (V5.7): the endurance PAIR, both live-read and slider-backed")
do
    -- The consolidation: ENDURANCE_EXERCISE_MIN (0.50, an untunable
    -- file-local copy) and EXERCISE_ENDURANCE_MIN (0.30, tunable) both gated
    -- exercise, one typo apart, and the untunable one silently floored the
    -- tunable one.  What replaced them is NOT one gate: a single threshold
    -- serving as both "start" and "stop" is what produced the user's
    -- one-rep-per-rest loop.
    assert_eq("the transposed twin ENDURANCE_EXERCISE_MIN is gone",
        AutoPilot_Constants.ENDURANCE_EXERCISE_MIN, nil)
    assert_true("EXERCISE_ENDURANCE_RESUME is a REAL constant again",
        type(AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME) == "number")

    -- Both halves of the pair are on the page, adjacent, under Training, with
    -- labels that say which is which.
    assert_eq("the resume gate has a start-shaped label",
        slider("endMin").name, "Resume training when endurance reaches (%)")
    assert_eq("the floor has a stop-shaped label",
        slider("endFloor").name, "Keep training until endurance falls to (%)")
    assert_eq("the resume gate is in the Training group",
        groupOf("endMin"), "Training")
    assert_eq("the floor is in the Training group too",
        groupOf("endFloor"), "Training")
    do
        local iResume, iFloor
        for i, r in ipairs(REGISTERED) do
            if r.id == "endMin"   then iResume = i end
            if r.id == "endFloor" then iFloor  = i end
        end
        assert_eq("they are registered adjacently, floor right after resume",
            iFloor, iResume + 1)
    end

    -- Each slider writes its OWN constant, across the range, with no leakage
    -- between the two.  The floor deliberately carries a NEW option id: an
    -- existing ModOptions.ini holds 90 under "endMin", and that 90 has to
    -- land on RESUME, never on the floor, or the upgrade would recreate the
    -- single-rep bug on the user's own saved settings.
    local savedR = AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME
    local savedF = AutoPilot_Constants.EXERCISE_ENDURANCE_MIN
    saveOption("endMin", 75)
    assert_near("resume slider 75 yields a 0.75 resume gate",
        AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME, 0.75, 1e-9)
    assert_near("...and the floor did not move",
        AutoPilot_Constants.EXERCISE_ENDURANCE_MIN, savedF, 1e-9)
    saveOption("endFloor", 15)
    assert_near("floor slider 15 yields a 0.15 floor",
        AutoPilot_Constants.EXERCISE_ENDURANCE_MIN, 0.15, 1e-9)
    assert_near("...and the resume gate did not move",
        AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME, 0.75, 1e-9)
    saveOption("endMin", 90)
    saveOption("endFloor", 30)
    assert_near("back to the shipped resume gate",
        AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME, 0.90, 1e-9)
    assert_near("back to the shipped floor",
        AutoPilot_Constants.EXERCISE_ENDURANCE_MIN, 0.30, 1e-9)
    AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = savedR
    AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = savedF
end


-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
