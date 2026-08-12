-- tests/fixtures/reason_scan_shapes.lua
--
-- Committed corpus for the lexical reason scanner (tests/lua_source_scan.lua),
-- exercised by tests/test_reason_line.lua Tests 4c and 4d.
--
-- THIS FILE IS NEVER LOADED BY THE MOD.  It lives under tests/fixtures/ so
-- neither the production glob (42/media/lua/client/*.lua) nor the Lua suite
-- glob (tests/test_*.lua) discovers it.  It IS valid Lua 5.1 and the suite
-- proves that with loadfile(), because a fixture the language would reject is
-- a shape the real input can never take.
--
-- The shapes below are derived from the LUA 5.1 GRAMMAR -- every comment form,
-- every string form, and every expression form the language permits in an
-- argument position -- not from what the scanner happens to handle.  A fixture
-- authored from the parser's own assumptions agrees with the parser instead of
-- testing it (L-069).  Each block names the real-world shape it stands for.
--
-- Reason tokens are aviation words so a failure message says which shape broke.

local T = {}
local cond, reasonVar, suffix = false, "sierra", "x"
local REASONS = { golf = "golf" }
local function pickReason() return "india" end

-- ── PHANTOMS: text that LOOKS like an emitter and must never be discovered ───

-- P1. Plain line comment. Stands for any commented-out call left behind.
-- AutoPilot_Telemetry.setDecision("p1", "phantom_line")

--- P2. Doc comment describing the call. This is the LIVE shape that fooled the
--- raw-text scanner: AutoPilot_Media.lua:334 documents the stall emitter as
--- setDecision("media", "phantom_doc") and the guard counted it as an emitter.

--[[ P3. Long comment. Stands for a block-commented region during a refactor.
     AutoPilot_Telemetry.setDecision("p3", "phantom_long")
]]

--[==[ P4. Long comment with bracket levels, which a naive "]]" search ends at
      the wrong place: the body below contains a ]] on purpose.
      local notCode = [[ ]]
      AutoPilot_Telemetry.setDecision("p4", "phantom_level")
]==]

-- P5. Call text inside a SHORT string. Stands for an error/help message that
-- quotes the API, e.g. a usage line printed to console.
local usage = 'call AutoPilot_Telemetry.setDecision("p5", "phantom_squote")'

-- P6. Call text inside a LONG string. Stands for embedded documentation.
local helpText = [[
  AutoPilot_Telemetry.setDecision("p6", "phantom_longstr")
]]

-- P7. A comment quoting the DYNAMIC shape. Stands for AutoPilot_Mood.lua:257,
-- which documents WHY the ternary is not used:
--     setDecision("read", cond and "phantom_tern_a" or "phantom_tern_b")
-- A scanner that grew an and/or pattern would harvest both tokens from prose.

-- P8. The DEFINITION. Stands for AutoPilot_Telemetry.lua:280. Its second
-- parameter is a name, not a literal, so a raw-text completeness check reports
-- it as a violation -- a false positive on the one site that defines the API.
function T.setDecision(action, reason, player, stage, fail_reason)
    return action, reason, player, stage, fail_reason
end

-- P9. A `return false, "..."` inside a comment, the fail-label phantom:
--     return false, "phantom_fail"

-- P10. A `return false, "..."` inside a string.
local failDoc = 'return false, "phantom_fail_str"'

-- ── REAL LITERAL EMITTERS: must be discovered ───────────────────────────────

function T.realEmitters()
    -- R1. Bare call, double-quoted.
    setDecision("a", "alpha")

    -- R2. Qualified call through a receiver, the production shape.
    AutoPilot_Telemetry.setDecision("b", "bravo")

    -- R3. Single-quoted literal: Lua treats both quotes identically.
    AutoPilot_Telemetry.setDecision('c', 'charlie')

    -- R4. A string carrying an ESCAPED QUOTE immediately before a real call.
    -- If the lexer mishandled \" it would lose sync and swallow R5 entirely.
    local quoted = "he said \"stop\" loudly"

    -- R5. Multi-line call with trailing arguments. Stands for
    -- AutoPilot_Needs.lua:634, which wraps before its fail_reason argument.
    AutoPilot_Telemetry.setDecision("d", "delta", nil, nil,
        quoted)

    -- R6. A real fail label.
    if cond then return false, "lima" end
    return usage, helpText, failDoc
end

-- ── DYNAMIC REASON ARGUMENTS: must be REPORTED, never silently dropped ──────
-- Every one of these is legal Lua and every one emits a reason token that no
-- literal-shape scan can see. They are the class the completeness guard exists
-- to make loud.

function T.dynamicEmitters()
    -- D1. and/or ternary. The exact shape PR #153 wrote first and reverted.
    AutoPilot_Telemetry.setDecision("e", cond and "echo" or "foxtrot")

    -- D2. Bare variable.
    AutoPilot_Telemetry.setDecision("f", reasonVar)

    -- D3. Table index.
    AutoPilot_Telemetry.setDecision("g", REASONS.golf)

    -- D4. Concatenation.
    AutoPilot_Telemetry.setDecision("h", "hotel_" .. suffix)

    -- D5. Function call.
    AutoPilot_Telemetry.setDecision("i", pickReason())

    -- D6. Parenthesised literal. Legal, and NOT one string token, so it is
    -- reported rather than silently accepted -- the honest answer, because the
    -- scanner genuinely cannot fold expressions.
    AutoPilot_Telemetry.setDecision("j", ("juliett"))
end

return T
