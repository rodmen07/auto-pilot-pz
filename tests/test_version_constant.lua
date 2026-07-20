-- tests/test_version_constant.lua
-- V5.3: covers the in-game half of "which version is actually loaded?".
--
-- Run from the project root with standard Lua 5.1+:
--   lua tests/test_version_constant.lua
--
-- Two things are verified here:
--   1. AutoPilot_Constants.VERSION exists and has the shape a modversion
--      has (digits, a dot, digits), so the panel can never render "v nil"
--      or "v <table>".
--   2. AutoPilot_UI.formatTitle composes the window title from it.
--
-- Loading AutoPilot_UI at all is new for this suite.  tests/lua_mock_pz.lua
-- records "[G] ISCollapsableWindow / ISButton / UIFont / require(ISUI/...):
-- NO suite loads AutoPilot_UI (vanilla-widget F11 panel). DOCUMENTED GAP."
-- That gap is NOT closed here and is deliberately left open: the panel's
-- createChildren/render still need live ISUI widgets and stay playtest-only.
-- What this suite stubs, suite-locally ([S]), is ONLY the module's LOAD-time
-- surface, which is exactly two calls: require("ISUI/ISCollapsableWindow")
-- and ISCollapsableWindow:derive(name).  Nothing is instantiated and no
-- drawing function is invoked, so no new engine surface is claimed.
--
-- The drift half of the guard (this constant vs modversion= in both
-- mod.info files and the README) lives in tests/test_version_sync.py, which
-- can read all four files without a Lua interpreter.

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Suite-local [S] stubs for AutoPilot_UI's load-time surface only ──────────
local _realRequire = require
require = function(name)
    if type(name) == "string" and name:match("^ISUI/") then return true end
    return _realRequire(name)
end

ISCollapsableWindow = {
    -- PZ's ISBaseObject:derive(name) returns a fresh table whose metatable
    -- chain reaches the parent.  The module under test only needs a table it
    -- can hang functions on at load time.
    derive = function(self, _name)
        local t = {}
        t.__index = t
        setmetatable(t, { __index = self })
        return t
    end,
}

dofile("42/media/lua/client/AutoPilot_UI.lua")

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

print("=== AutoPilot Version Visibility Tests (V5.3) ===")

print("\n-- Test 1: the version constant itself")
do
    assert_eq("VERSION is a string",
        type(AutoPilot_Constants.VERSION), "string")
    assert_true("VERSION is not empty",
        (AutoPilot_Constants.VERSION or "") ~= "")
    assert_true("VERSION looks like a modversion (digits.digits)",
        tostring(AutoPilot_Constants.VERSION):match("^%d+%.%d+$") ~= nil)
    assert_true("VERSION carries no stray whitespace",
        tostring(AutoPilot_Constants.VERSION):match("%s") == nil)
end

print("\n-- Test 2: the panel title reports the loaded version")
do
    assert_eq("formatTitle is exposed by AutoPilot_UI",
        type(AutoPilot_UI.formatTitle), "function")
    assert_eq("a version string is appended as 'v<version>'",
        AutoPilot_UI.formatTitle("5.3"), "AutoPilot Leveler  v5.3")
    assert_eq("the real constant is renderable",
        AutoPilot_UI.formatTitle(AutoPilot_Constants.VERSION),
        "AutoPilot Leveler  v" .. AutoPilot_Constants.VERSION)
    assert_true("the title contains the version substring",
        AutoPilot_UI.formatTitle(AutoPilot_Constants.VERSION)
            :find(AutoPilot_Constants.VERSION, 1, true) ~= nil)
end

print("\n-- Test 3: a missing or malformed constant degrades, never crashes")
do
    -- If AutoPilot_Constants somehow failed to load first, the panel must
    -- still open with its pre-V5.3 title rather than drawing "v nil".
    assert_eq("nil version falls back to the plain title",
        AutoPilot_UI.formatTitle(nil), "AutoPilot Leveler")
    assert_eq("empty version falls back to the plain title",
        AutoPilot_UI.formatTitle(""), "AutoPilot Leveler")
    assert_eq("a non-string version falls back to the plain title",
        AutoPilot_UI.formatTitle(53), "AutoPilot Leveler")
    assert_eq("a table version falls back to the plain title",
        AutoPilot_UI.formatTitle({}), "AutoPilot Leveler")
end

print("\n-- Test 4: VERSION is presentation only, never a tunable")
do
    -- AutoPilot_Options writes numeric sliders into AutoPilot_Constants; a
    -- string version key must never be one of them, or an options-save
    -- would silently rewrite what the panel reports.
    local text = io.open("42/media/lua/client/AutoPilot_Options.lua", "r")
    local src = text and text:read("*a") or ""
    if text then text:close() end
    assert_true("AutoPilot_Options never references VERSION",
        src ~= "" and src:find("VERSION", 1, true) == nil)
end

-- ── Summary ──────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
