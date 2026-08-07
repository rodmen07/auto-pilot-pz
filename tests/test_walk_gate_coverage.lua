-- tests/test_walk_gate_coverage.lua
-- Every walk this mod dispatches must pass the engine's game-speed gate first.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- ISWalkToTimedAction:isValid() ends `return getGameSpeed() <= 2` (42.19
-- media/lua/client/TimedActions/WalkToTimedAction.lua:5-8, and the identical
-- line in WalkToTimedActionF.lua:7).  Above index 2 the action queue discards
-- EVERY walk this mod queues on the tick it starts it, so the mod believes it
-- acted, sees the queue empty next cycle, re-decides, re-queues, and repeats.
-- PR #120 fixed that for the flee path only and recorded the remaining sites as
-- a follow-up.  This suite is what makes site N+1 impossible to miss.
--
-- TWO THINGS THIS GUARD KNOWS THAT A GREP DOES NOT
-- ------------------------------------------------
-- 1. luautils.walkAdj IS a walk dispatch.  It ends in
--    ISTimedActionQueue.add(ISWalkToTimedAction:new(playerObj, adjacent))
--    (42.19 shared/luautils.lua:147), the very action the engine invalidates.
--    The follow-up item that seeded this increment listed only the seven
--    ISWalkToTimedAction lines, which MISSED four walkAdj sites -- and at three
--    of those, walkAdj is the PRIMARY path whose ISWalkToTimedAction sibling
--    runs only when walkAdj raises.  Gating the recorded list alone would have
--    left the code that actually executes un-gated in the normal case.
-- 2. Coverage is per FUNCTION BLOCK, not per file and not per line number.  A
--    file-level "does the token appear anywhere" check is satisfied by one
--    call that guards nothing (and by a comment); line numbers shift on every
--    edit.  A block must contain a prepareWalk call STRICTLY BEFORE its first
--    dispatch, which is the property that actually has to hold.
--
-- NOT AFFECTED, checked against the engine source rather than assumed:
-- ISPathFindAction:isValid() is `return true` with no getGameSpeed reference
-- anywhere in the file (42.19 client/Vehicles/TimedActions/ISPathFindAction.lua
-- lines 5-7), so AutoPilot_Rest's pathToSitOnFurniture seating is genuinely
-- outside this gate and is deliberately not required to clamp.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_walk_gate_coverage.lua

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

local function assert_true(desc, val) assert_eq(desc, not not val, true) end

-- ── Discovery (glob-driven, zero-match hard failure) ──────────────────────────
-- Mirrors tests/test_clock_discipline.lua deliberately: the file list is
-- DISCOVERED, never hand-enumerated, so a new module joins the audit by
-- existing.  No stderr redirect -- `2>/dev/null` is shell syntax io.popen's
-- Windows host does not understand, and an empty list must fail loudly.
local function productionFiles()
    local files = {}
    local pipe = io.popen("ls -1 42/media/lua/client/*.lua")
    if pipe then
        for line in pipe:lines() do
            line = line:gsub("%s+$", "")
            if line ~= "" then files[#files + 1] = line end
        end
        pipe:close()
    end
    table.sort(files)
    return files
end

local function readFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local text = fh:read("*a")
    fh:close()
    return text
end

local function basename(path) return (path:gsub(".*[/\\]", "")) end

-- ── The scanner ───────────────────────────────────────────────────────────────
-- A dispatch is either of the two ways this mod can put a walk in the queue.
local DISPATCH_PATTERNS = {
    "ISWalkToTimedAction%s*:%s*new",
    "luautils%s*%.%s*walkAdj",
}
-- The seam every dispatch must be preceded by.
local GATE_PATTERN = "AutoPilot_Utils%s*%.%s*prepareWalk%s*%("

-- Comments are not code: several modules NAME these symbols in prose (the
-- Media walk helper's header describes "luautils.walkAdj first", the Utils and
-- Constants headers quote the engine's isValid body) without calling them
-- there.  Same discipline as test_clock_discipline.lua / test_engine_symbols.lua.
local function stripComment(line)
    local cut = line:find("%-%-")
    return cut and line:sub(1, cut - 1) or line
end

local function isDispatch(code)
    for _, pat in ipairs(DISPATCH_PATTERNS) do
        if code:find(pat) then return true end
    end
    return false
end

-- A prepareWalk CALL, not its definition: `function AutoPilot_Utils.prepareWalk`
-- matches the call pattern too, and the seam obviously does not gate itself.
local function isGateCall(code)
    if not code:find(GATE_PATTERN) then return false end
    if code:find("^%s*function%s") then return false end
    return true
end

--- Split a module into its top-level function blocks and classify each.
--- This codebase declares every function at column 0 (`function X.y(` or
--- `local function y(`); the inline `pcall(function() ... end)` closures are
--- indented and therefore correctly stay part of their enclosing block, which
--- is what we want -- a clamp outside the pcall still guards the walk inside it.
--- Returns a list of { name, firstDispatchLine, firstGateLine }.
local function scanBlocks(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end

    local blocks = {}
    local current = { name = "<file scope>", firstDispatch = nil, firstGate = nil }
    for n, raw in ipairs(lines) do
        local name = raw:match("^local%s+function%s+([%w_%.:]+)")
            or raw:match("^function%s+([%w_%.:]+)")
        if name then
            blocks[#blocks + 1] = current
            current = { name = name, firstDispatch = nil, firstGate = nil }
        end
        local code = stripComment(raw)
        if isGateCall(code) and not current.firstGate then
            current.firstGate = n
        end
        if isDispatch(code) and not current.firstDispatch then
            current.firstDispatch = n
        end
    end
    blocks[#blocks + 1] = current
    return blocks
end

-- ── 1. Discovery is real and the scanner is not blind ─────────────────────────
print("\n-- Test 1: discovery and scanner-blindness guards")
local files = productionFiles()
local dispatchBlocks, gatedBlocks, ungated, orphanGates = 0, 0, {}, {}
do
    -- Zero-match HARD FAILURE: an empty ls is a broken glob or a moved tree,
    -- never a clean result.
    assert_true(("glob discovery found modules (got %d, need >= 20)")
        :format(#files), #files >= 20)

    for _, path in ipairs(files) do
        local text = readFile(path)
        if text then
            for _, b in ipairs(scanBlocks(text)) do
                if b.firstDispatch then
                    dispatchBlocks = dispatchBlocks + 1
                    if b.firstGate and b.firstGate < b.firstDispatch then
                        gatedBlocks = gatedBlocks + 1
                    else
                        ungated[#ungated + 1] = ("%s:%s (line %d)")
                            :format(basename(path), b.name, b.firstDispatch)
                    end
                elseif b.firstGate then
                    orphanGates[#orphanGates + 1] = ("%s:%s (line %d)")
                        :format(basename(path), b.name, b.firstGate)
                end
            end
        end
    end

    -- If the scanner stops seeing walks that provably exist, it has gone blind
    -- and must say so rather than reporting a clean tree.
    assert_true(("the scanner sees walk dispatches at all (found %d blocks)")
        :format(dispatchBlocks), dispatchBlocks >= 1)
end

-- ── 2. THE GUARD: every dispatching block clamps first ────────────────────────
print("\n-- Test 2: every walk dispatch is preceded by the game-speed gate")
do
    assert_eq(("no un-gated walk dispatch (offenders: %s)")
        :format(#ungated == 0 and "none" or table.concat(ungated, ", ")),
        #ungated, 0)
    assert_eq("every dispatching block is gated", gatedBlocks, dispatchBlocks)
end

-- ── 3. The known surface is PINNED in both directions ─────────────────────────
-- Not an existence search: the count is the whole walk surface of the mod, so
-- adding a tenth walk site (or deleting one) fails here and forces a deliberate
-- decision instead of a silent drift.  The four walkAdj sites are inside this
-- number precisely because the follow-up item's grep did not find them.
print("\n-- Test 3: the walk surface is exactly the nine known blocks")
do
    assert_eq("nine function blocks dispatch a walk", dispatchBlocks, 9)
    assert_eq(("no decorative prepareWalk call guarding nothing (%s)")
        :format(#orphanGates == 0 and "none" or table.concat(orphanGates, ", ")),
        #orphanGates, 0)
end

-- ── 4. Scanner self-controls (it can both fire and stay silent) ───────────────
-- A guard never observed failing is not trusted.
print("\n-- Test 4: scanner controls on synthetic input")
do
    local function classify(src)
        local blocks = scanBlocks(src)
        for _, b in ipairs(blocks) do
            if b.firstDispatch then
                return b.firstGate ~= nil and b.firstGate < b.firstDispatch
                    and "GATED" or "UNGATED"
            end
        end
        return "NO_DISPATCH"
    end

    -- It FIRES on an un-gated direct queue...
    assert_eq("an un-gated ISWalkToTimedAction block is UNGATED", classify(
        "local function go(p, sq)\n" ..
        "    AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(p, sq))\n" ..
        "end\n"), "UNGATED")

    -- ...and on an un-gated walkAdj, the shape the seeding item's grep missed.
    assert_eq("an un-gated luautils.walkAdj block is UNGATED", classify(
        "local function go(p, sq)\n" ..
        "    pcall(function() luautils.walkAdj(p, sq, true) end)\n" ..
        "end\n"), "UNGATED")

    -- It STAYS SILENT once the seam is in front of the dispatch.
    assert_eq("a gated block is GATED", classify(
        "local function go(p, sq)\n" ..
        "    AutoPilot_Utils.prepareWalk(\"test\")\n" ..
        "    AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(p, sq))\n" ..
        "end\n"), "GATED")

    -- ORDER is load-bearing: clamping after the walk is already queued is
    -- exactly the bug, so a trailing gate must still read as UNGATED.
    assert_eq("a gate AFTER the dispatch does not count", classify(
        "local function go(p, sq)\n" ..
        "    AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(p, sq))\n" ..
        "    AutoPilot_Utils.prepareWalk(\"too late\")\n" ..
        "end\n"), "UNGATED")

    -- A gate in a DIFFERENT block does not cover this one.
    assert_eq("a gate in a neighbouring block does not count", classify(
        "local function other(p)\n" ..
        "    AutoPilot_Utils.prepareWalk(\"elsewhere\")\n" ..
        "end\n" ..
        "local function go(p, sq)\n" ..
        "    AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(p, sq))\n" ..
        "end\n"), "UNGATED")

    -- Comments are not code, in either direction.
    assert_eq("a commented dispatch is not a dispatch", classify(
        "local function go(p, sq)\n" ..
        "    -- luautils.walkAdj(p, sq, true) is what we would call here\n" ..
        "end\n"), "NO_DISPATCH")

    assert_eq("a commented gate does not satisfy a real dispatch", classify(
        "local function go(p, sq)\n" ..
        "    -- AutoPilot_Utils.prepareWalk(\"pretend\")\n" ..
        "    AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(p, sq))\n" ..
        "end\n"), "UNGATED")

    -- The seam's own definition is not a call, so Utils is not self-gating.
    assert_eq("the prepareWalk definition is not counted as a call", classify(
        "function AutoPilot_Utils.prepareWalk(label)\n" ..
        "    return false\n" ..
        "end\n"), "NO_DISPATCH")
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
