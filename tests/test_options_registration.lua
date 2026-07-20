-- tests/test_options_registration.lua
-- V5.5: covers WHETHER the mod options page ever reaches the game at all.
--
-- Run from the project root with standard Lua 5.1+:
--   lua tests/test_options_registration.lua
--
-- Why this suite exists: tests/test_options_mapping.lua was fully green while
-- the feature was 100% broken in game.  That suite loads AutoPilot_Options
-- with PZAPI already sitting in _G, so it only ever exercised the happy path,
-- and it asserts the DEFS -> AutoPilot_Constants mapping, not registration.
-- On a real 42.19 client PZAPI.ModOptions was NOT there when the file loaded
-- (console.txt: 'require("pzapi/ui/ui") failed'), the pre-V5.5 load-time
-- registration silently returned, ~/Zomboid/Lua/ModOptions.ini stayed 0 bytes,
-- mods_options.ini never grew an [AutoPilot] section, and the user reported
-- "I don't see where the settings are configurable in-game".
--
-- So the case under test here is precisely the one nobody was testing:
-- PZAPI ABSENT AT LOAD, PRESENT LATER.
--
-- Mock surface: nothing new.  PZAPI.ModOptions (create / addTitle / addSlider
-- / addKeyBind / getOption:getValue / apply / load) and Events.OnTick /
-- OnMainMenuEnter .Add are both already in the tests/lua_mock_pz.lua record as
-- suite-local [S]; getFileWriter is the shared [MA] mock.  The widgets stay
-- playtest-only as always.

dofile("tests/lua_mock_pz.lua")   -- getFileWriter/MockFiles ([MA])
dofile("42/media/lua/client/AutoPilot_Constants.lua")

Keyboard = { KEY_F10 = 67, KEY_F11 = 68 }

-- ── Minimal test framework (same shape as the other suites) ──────────────────
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

local function assert_true(desc, val) assert_eq(desc, not not val, true) end
local function assert_false(desc, val) assert_eq(desc, not not val, false) end

-- ── Rebuildable world ────────────────────────────────────────────────────────
-- Each scenario gets a fresh Events capture, a fresh PZAPI recorder and a
-- fresh dofile of the module (the module's registration state lives in file
-- locals, so a re-dofile is a clean reload, exactly like the game's Lua
-- reload on an MP server connect).

local EV, MO

--- Fresh Events table that captures handlers instead of firing them.
local function newEvents()
    local ev = { handlers = { OnTick = {}, OnMainMenuEnter = {} } }
    Events = {}
    for name, list in pairs(ev.handlers) do
        Events[name] = { Add = function(h) table.insert(list, h) end }
    end
    ev.fire = function(name, ...)
        for _, h in ipairs(ev.handlers[name]) do h(...) end
    end
    ev.count = function(name) return #ev.handlers[name] end
    return ev
end

--- Fresh PZAPI.ModOptions recorder.  Counts :create calls (the idempotence
--- probe) and every control registered.
local function newModOptions()
    local mo = { creates = 0, loads = 0, controls = {}, options = {} }
    local page = {}
    local function mk(id, value)
        local o = { _value = value }
        function o:getValue() return self._value end
        function o:setValue(v) self._value = v end
        mo.options[id] = o
    end
    function page:addTitle(t)
        table.insert(mo.controls, { kind = "title", name = t })
    end
    function page:addSlider(id, name, mn, mx, st, def)
        table.insert(mo.controls,
            { kind = "slider", id = id, name = name, min = mn, max = mx,
              step = st, default = def })
        mk(id, def)
    end
    function page:addKeyBind(id, name, def)
        table.insert(mo.controls, { kind = "keybind", id = id, name = name })
        mk(id, def)
    end
    function page:getOption(id) return mo.options[id] end
    mo.page = page
    mo.api = {
        create = function(_self, _id, _name) mo.creates = mo.creates + 1
            return page end,
        load   = function(_self) mo.loads = mo.loads + 1 end,
    }
    return mo
end

--- Count registered controls of a kind (sliders, keybinds, ...).
local function countKind(mo, kind)
    local n = 0
    for _, c in ipairs(mo.controls) do
        if c.kind == kind then n = n + 1 end
    end
    return n
end

--- Load AutoPilot_Options into a fresh world.
--- @param pzapiPresent boolean  whether PZAPI exists AT LOAD TIME
local function loadModule(pzapiPresent)
    EV = newEvents()
    MO = newModOptions()
    MockFiles = {}
    PZAPI = pzapiPresent and { ModOptions = MO.api } or nil
    dofile("42/media/lua/client/AutoPilot_Options.lua")
end

--- Make PZAPI appear, as the vanilla client Lua would once it finishes.
local function pzapiArrives()
    PZAPI = { ModOptions = MO.api }
end

--- The V5.5 diagnostic lines written into the telemetry run log.
local function diagnosticLines()
    local f = MockFiles["auto_pilot_run.log"]
    local out = {}
    if not f then return out end
    for _, line in ipairs(f.lines or {}) do
        if tostring(line):find("^#") then table.insert(out, line) end
    end
    return out
end

-- The tick budget the module gives PZAPI before it gives up and complains.
-- Kept generous here so the test does not encode the exact constant beyond
-- "some bounded number of ticks".
local RETRY_TICKS = 200

print("=== AutoPilot Options Registration Tests (V5.5) ===")

print("\n-- Test 1: PZAPI present at load registers immediately")
do
    loadModule(true)
    assert_true("isRegistered() is exposed",
        type(AutoPilot_Options.isRegistered) == "function")
    assert_true("registered at load", AutoPilot_Options.isRegistered())
    assert_eq("the page was created exactly once", MO.creates, 1)
    assert_true("sliders were registered", countKind(MO, "slider") > 0)
    assert_eq("both keybinds registered", countKind(MO, "keybind"), 2)
    assert_eq("saved values were re-read", MO.loads, 1)
    -- A healthy client must pay nothing for the retry machinery.
    assert_eq("no main-menu retry is wired when load succeeded",
        EV.count("OnMainMenuEnter"), 0)
    assert_eq("no per-tick retry is wired when load succeeded",
        EV.count("OnTick"), 0)
    assert_eq("no diagnostic written on the happy path",
        #diagnosticLines(), 0)
end

print("\n-- Test 2: PZAPI ABSENT at load is the reported bug, and is retried")
do
    -- This is the exact live-client state: the file loads, PZAPI is nil.
    loadModule(false)
    assert_false("nothing registered at load", AutoPilot_Options.isRegistered())
    assert_eq("no page was created", MO.creates, 0)
    -- Pre-V5.5 the story ended here and every option was inert forever.
    assert_true("a main-menu retry is wired", EV.count("OnMainMenuEnter") >= 1)
    assert_true("a per-tick retry is wired", EV.count("OnTick") >= 1)
end

print("\n-- Test 3: the main-menu retry registers once PZAPI shows up")
do
    loadModule(false)
    assert_false("still unregistered before the event",
        AutoPilot_Options.isRegistered())
    pzapiArrives()
    EV.fire("OnMainMenuEnter")
    assert_true("registered by the main-menu retry",
        AutoPilot_Options.isRegistered())
    assert_eq("the page was created exactly once", MO.creates, 1)
    assert_true("the full slider set is present", countKind(MO, "slider") > 10)
    assert_eq("both keybinds registered", countKind(MO, "keybind"), 2)
    assert_eq("no failure diagnostic on a successful retry",
        #diagnosticLines(), 0)
end

print("\n-- Test 4: the tick retry covers the MP-join / already-running case")
do
    -- OnMainMenuEnter cannot fire for a mod loaded into a running game (the
    -- 42.19 server-connect Lua reload leaves the main menu behind), so the
    -- OnTick path has to be able to register on its own.
    loadModule(false)
    EV.fire("OnTick")
    assert_false("a tick with no PZAPI still registers nothing",
        AutoPilot_Options.isRegistered())
    pzapiArrives()
    EV.fire("OnTick")
    assert_true("registered by the tick retry", AutoPilot_Options.isRegistered())
    assert_eq("the page was created exactly once", MO.creates, 1)
end

print("\n-- Test 5: registration is idempotent under repeated retries")
do
    loadModule(false)
    pzapiArrives()
    EV.fire("OnMainMenuEnter")
    local slidersAfterFirst  = countKind(MO, "slider")
    local keybindsAfterFirst = countKind(MO, "keybind")
    local titlesAfterFirst   = countKind(MO, "title")

    -- Every retry surface fires again, repeatedly.
    EV.fire("OnMainMenuEnter")
    EV.fire("OnMainMenuEnter")
    for _ = 1, 50 do EV.fire("OnTick") end

    assert_eq("still exactly one page", MO.creates, 1)
    assert_eq("no duplicate sliders", countKind(MO, "slider"), slidersAfterFirst)
    assert_eq("no duplicate keybinds",
        countKind(MO, "keybind"), keybindsAfterFirst)
    assert_eq("no duplicate group titles",
        countKind(MO, "title"), titlesAfterFirst)
    assert_eq("the saved options file was re-read once, not once per retry",
        MO.loads, 1)
    assert_true("still registered", AutoPilot_Options.isRegistered())
end

print("\n-- Test 6: PZAPI never arrives -> isRegistered() stays false")
do
    loadModule(false)
    for _ = 1, RETRY_TICKS + 20 do EV.fire("OnTick") end
    EV.fire("OnMainMenuEnter")
    assert_false("never registered", AutoPilot_Options.isRegistered())
    assert_eq("no page was ever created", MO.creates, 0)
end

print("\n-- Test 7: the failure is LOUD, and said exactly once")
do
    -- The pre-V5.5 diagnostic was a print() that this file shadows with a
    -- noop, so the only evidence of total breakage was invisible.  The
    -- replacement must actually land somewhere a user or triage tool sees.
    loadModule(false)
    for _ = 1, RETRY_TICKS - 1 do EV.fire("OnTick") end
    assert_eq("silent during the grace window (a slow load is not a failure)",
        #diagnosticLines(), 0)

    for _ = 1, 5 do EV.fire("OnTick") end
    local lines = diagnosticLines()
    assert_eq("exactly one diagnostic line once the grace window closes",
        #lines, 1)
    assert_true("it names the missing API",
        tostring(lines[1]):find("PZAPI.ModOptions", 1, true) ~= nil)
    assert_true("it says the options page did not register",
        tostring(lines[1]):lower():find("did not register", 1, true) ~= nil)
    assert_true("it tells the reader defaults are in force",
        tostring(lines[1]):lower():find("default", 1, true) ~= nil)

    -- Never spam: hundreds more ticks must not grow the log.
    for _ = 1, 500 do EV.fire("OnTick") end
    assert_eq("still exactly one diagnostic after 500 more ticks",
        #diagnosticLines(), 1)
end

print("\n-- Test 8: the diagnostic APPENDS, never truncating the run log")
do
    loadModule(false)
    for _ = 1, RETRY_TICKS + 1 do EV.fire("OnTick") end
    local f = MockFiles["auto_pilot_run.log"]
    assert_true("the run log was written", f ~= nil)
    assert_eq("one append", f.appends, 1)
    assert_eq("zero truncates (the V2.1 one-line-log bug must not return)",
        f.truncates, 0)
end

print("\n-- Test 9: a late PZAPI is still picked up after the complaint")
do
    -- Retrying does not stop when the diagnostic is written; giving up
    -- permanently would turn a slow load into a dead options page.
    loadModule(false)
    for _ = 1, RETRY_TICKS + 1 do EV.fire("OnTick") end
    assert_eq("complained once", #diagnosticLines(), 1)
    pzapiArrives()
    EV.fire("OnTick")
    assert_true("a very late PZAPI still registers",
        AutoPilot_Options.isRegistered())
    assert_eq("and only one page results", MO.creates, 1)
end

print("\n-- Test 10 (V5.5): the F11 panel line, in both states")
do
    -- Same load-time-only [S] stubs test_version_constant uses; nothing is
    -- instantiated and no drawing function is invoked.
    local _realRequire = require
    require = function(name)
        if type(name) == "string" and name:match("^ISUI/") then return true end
        return _realRequire(name)
    end
    ISCollapsableWindow = {
        derive = function(self, _name)
            local t = {}
            t.__index = t
            setmetatable(t, { __index = self })
            return t
        end,
    }
    dofile("42/media/lua/client/AutoPilot_UI.lua")
    require = _realRequire

    assert_eq("optionsWarningLine is exposed",
        type(AutoPilot_UI.optionsWarningLine), "function")
    assert_eq("registered -> the panel gains NOTHING (no clutter)",
        AutoPilot_UI.optionsWarningLine(true), nil)
    assert_eq("not registered -> one honest line",
        AutoPilot_UI.optionsWarningLine(false),
        "mod options unavailable (using defaults)")
    assert_eq("a missing state reads as unavailable, not as fine",
        AutoPilot_UI.optionsWarningLine(nil),
        "mod options unavailable (using defaults)")
end

print("\n-- Test 11 (V5.5): the panel line tracks the real registration state")
do
    loadModule(false)
    assert_eq("failed registration -> the warning shows",
        AutoPilot_UI.optionsWarningLine(AutoPilot_Options.isRegistered()),
        "mod options unavailable (using defaults)")
    pzapiArrives()
    EV.fire("OnMainMenuEnter")
    assert_eq("after the retry succeeds -> the warning is gone",
        AutoPilot_UI.optionsWarningLine(AutoPilot_Options.isRegistered()), nil)
end

print("\n-- Test 12: the retry did not change any default, range or step")
do
    -- V5.5 is purely about registration reaching the game.  The controls
    -- built through the retry path must be byte-identical to the ones the
    -- load path builds.
    loadModule(true)
    local direct = MO.controls
    loadModule(false)
    pzapiArrives()
    EV.fire("OnMainMenuEnter")
    local retried = MO.controls

    assert_eq("same number of controls", #retried, #direct)
    local mismatches = 0
    for i = 1, math.min(#direct, #retried) do
        local a, b = direct[i], retried[i]
        if a.kind ~= b.kind or a.id ~= b.id or a.name ~= b.name
                or a.min ~= b.min or a.max ~= b.max or a.step ~= b.step
                or a.default ~= b.default then
            mismatches = mismatches + 1
        end
    end
    assert_eq("every control matches the load-path control exactly",
        mismatches, 0)
end

-- ── Summary ──────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
