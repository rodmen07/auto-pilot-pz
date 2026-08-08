-- tests/test_death_cause_coverage.lua
-- Every death cause the classifier can EMIT is either learned from or
-- explicitly declared un-ruled, and every learning rule is keyed on a cause
-- something actually produces.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- The death-learning layer has two halves that must agree and had no guard
-- holding them together:
--
--   AutoPilot_DeathLog's classifier turns the state at death into ONE cause
--   string; AutoPilot_Adaptive.RULES is a table keyed on those strings.
--
-- A cause with no rule is INERT -- the death is recorded, parsed, aggregated,
-- and then teaches the mod nothing.  On 2026-08-08 three of the classifier's
-- eight causes were inert (`infection`, `zombies`, `unknown`) and nothing in
-- either file said whether that was deliberate, so a reader could not tell an
-- omission from a decision.  Two of the three were omissions: a character who
-- died bitten, or who was killed by a group below FLEE_HORDE_SIZE, taught the
-- mod nothing at all, which is precisely the death the mod most needs to learn
-- from since it cannot fight.
--
-- Fixing the two instances does not fix the CLASS: the ninth cause someone
-- adds to the classifier would go inert exactly as quietly.  So the agreement
-- is bound here, in both directions:
--
--   1. every cause the classifier can emit is consumed by a RULES entry, or
--      named in AutoPilot_Adaptive.UNRULED_CAUSES with a reason;
--   2. every cause a RULES entry is keyed on is one the classifier emits, or
--      is declared in AutoPilot_Adaptive.SYNTHETIC_CAUSES (only `away`, which
--      aggregate() derives).  A rule keyed on a cause nothing produces is dead
--      code that reads as coverage.
--
-- HOW THE VOCABULARY IS OBTAINED, and why it is BOTH ways
-- ------------------------------------------------------
-- Test 1 RUNS the classifier over a crafted context per cause, so each cause
-- is proven REACHABLE rather than merely present in the source.  Running alone
-- cannot prove the list is COMPLETE, though -- a cause nobody wrote a probe
-- for is invisible to it, which is the same blindness this suite exists to
-- remove.  So Test 2 reads the classifier's own body and asserts the set of
-- `return "<literal>"` values is exactly the set Test 1 exercised.  Adding a
-- return without a probe fails Test 2; adding a probe for a cause the
-- classifier cannot emit fails it too.  A body that cannot be located at all
-- is a HARD failure (the guard has gone blind), never a silent pass.
--
-- Run from the project root with standard Lua 5.1+:
--   lua tests/test_death_cause_coverage.lua

local DEATHLOG_SRC = "42/media/lua/client/AutoPilot_DeathLog.lua"

-- ── Load constants, then the modules under test ───────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")
dofile("42/media/lua/client/AutoPilot_DeathLog.lua")
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

local function assert_true(desc, val) assert_eq(desc, not not val, true) end

-- A guard that cannot see its input must not report a pass.  Print the summary
-- so the run is still readable, then exit non-zero.
local function hard_fail(msg)
    io.stderr:write("\n  BLIND  " .. msg .. "\n")
    print(("\n=== Results: %d passed, %d failed (GUARD BLIND) ==="):format(
        PASS, FAIL + 1))
    os.exit(1)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function sortedKeys(set)
    local out = {}
    for k in pairs(set) do table.insert(out, k) end
    table.sort(out)
    return out
end

local function joined(set)
    local keys = sortedKeys(set)
    return (#keys == 0) and "<none>" or table.concat(keys, ", ")
end

local function countKeys(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

-- Snapshot / restore every numeric top-level field of AutoPilot_Constants,
-- because applyRules mutates them in place.
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

-- ── Test 1: every cause is REACHABLE (the classifier is RUN, not read) ────────
-- Ordered most-specific first, mirroring the classifier's own ordering, so a
-- reordering that shadows a branch shows up as a wrong cause here.
print("\n== Test 1: every death cause is reachable by running the classifier ==")

local HORDE = AutoPilot_Constants.FLEE_HORDE_SIZE

-- A context with every field the classifier reads, all inert.
local function ctx(over)
    local c = { zombies = 0, bleeding = 0, bitten = false, hunger = 0, thirst = 0 }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local PROBES = {
    { cause = "horde",          ctx = ctx({ zombies = HORDE }),
      why  = "at or above FLEE_HORDE_SIZE" },
    { cause = "zombie_wounded", ctx = ctx({ zombies = 1, bleeding = 1 }),
      why  = "bleeding with zombies present, below horde size" },
    { cause = "bleed_out",      ctx = ctx({ bleeding = 1 }),
      why  = "bleeding with no zombies left" },
    { cause = "infection",      ctx = ctx({ bitten = true }),
      why  = "bitten, not bleeding, no zombies at death" },
    { cause = "starvation",     ctx = ctx({ hunger = 0.95 }),
      why  = "hunger at or above 0.90" },
    { cause = "dehydration",    ctx = ctx({ thirst = 0.95 }),
      why  = "thirst at or above 0.90" },
    { cause = "zombies",        ctx = ctx({ zombies = 1 }),
      why  = "zombies present, below horde size, unbitten and unbled" },
    { cause = "unknown",        ctx = ctx(),
      why  = "no signal at all" },
}

assert_true("the classifier is exposed for tests",
    type(AutoPilot_DeathLog.classifyCause) == "function")

local REACHABLE = {}
for _, p in ipairs(PROBES) do
    local got = AutoPilot_DeathLog.classifyCause(p.ctx)
    assert_eq(("%-15s emitted for a death %s"):format(p.cause, p.why),
        got, p.cause)
    REACHABLE[p.cause] = true
end
assert_eq("every probe emitted a DISTINCT cause (no branch shadows another)",
    countKeys(REACHABLE), #PROBES)

-- ── Test 2: the probe set is COMPLETE against the classifier's own body ───────
print("\n== Test 2: the probed vocabulary is exactly the classifier's ==")

local fh = io.open(DEATHLOG_SRC, "r")
if not fh then
    hard_fail("cannot open " .. DEATHLOG_SRC .. " -- run this suite from the "
        .. "project root.")
end
local src = fh:read("*a")
fh:close()
-- Normalise line endings first: this repo stores LF but checks out CRLF on
-- Windows (core.autocrlf=true, .gitattributes `* text=auto`), and a `\nend\n`
-- anchor silently stops matching against `\r\n`.
src = src:gsub("\r\n", "\n")

local body = src:match("local function _classifyCause%b()(.-)\nend\n")
if not body then
    hard_fail("could not locate the body of _classifyCause in " .. DEATHLOG_SRC
        .. " -- the guard's anchor no longer matches, so it can no longer see "
        .. "the cause vocabulary. Fix the anchor in this suite in the SAME "
        .. "edit that renamed or reshaped the function.")
end

local DECLARED = {}
for lit in body:gmatch('return%s+"([%w_]+)"') do DECLARED[lit] = true end
if countKeys(DECLARED) == 0 then
    hard_fail("found the body of _classifyCause but ZERO `return \"<cause>\"` "
        .. "literals in it -- the guard would pass vacuously.")
end

assert_eq("the classifier's returns and the probed causes are the same set",
    joined(DECLARED), joined(REACHABLE))
assert_eq("...and there are the expected 8 of them",
    countKeys(DECLARED), 8)

-- ── Test 3: no cause is inert by accident, in EITHER direction ────────────────
print("\n== Test 3: every cause is ruled, or declared un-ruled, with a reason ==")

local RULED = {}
for _, rule in ipairs(AutoPilot_Adaptive.RULES) do RULED[rule.cause] = true end

local UNRULED   = AutoPilot_Adaptive.UNRULED_CAUSES or {}
local SYNTHETIC = AutoPilot_Adaptive.SYNTHETIC_CAUSES or {}

assert_true("AutoPilot_Adaptive declares its un-ruled causes as a table",
    type(AutoPilot_Adaptive.UNRULED_CAUSES) == "table")
assert_true("AutoPilot_Adaptive declares its synthesised causes as a table",
    type(AutoPilot_Adaptive.SYNTHETIC_CAUSES) == "table")

-- Direction 1: nothing the classifier emits may be silently inert.
for _, cause in ipairs(sortedKeys(REACHABLE)) do
    local ruled   = RULED[cause] == true
    local unruled = type(UNRULED[cause]) == "string" and #UNRULED[cause] > 0
    assert_true(("%-15s is consumed by a rule, or declared un-ruled with a reason")
        :format(cause), ruled or unruled)
    assert_true(("%-15s is not BOTH ruled and declared un-ruled"):format(cause),
        not (ruled and unruled))
end

-- Direction 2: no rule may be keyed on a cause nothing ever produces.
for _, rule in ipairs(AutoPilot_Adaptive.RULES) do
    local emitted   = REACHABLE[rule.cause] == true
    local synthetic = type(SYNTHETIC[rule.cause]) == "string"
                      and #SYNTHETIC[rule.cause] > 0
    assert_true(("rule on %-15s is keyed on a cause that is emitted or declared synthetic")
        :format(rule.cause), emitted or synthetic)
end

-- The declarations themselves must stay honest: a cause listed as un-ruled or
-- synthetic that the classifier no longer emits is stale prose in a table.
for _, cause in ipairs(sortedKeys(UNRULED)) do
    assert_true(("declared-un-ruled %-8s is still a cause the classifier emits")
        :format(cause), REACHABLE[cause] == true)
end
for _, cause in ipairs(sortedKeys(SYNTHETIC)) do
    assert_true(("declared-synthetic %-6s is NOT emitted by the classifier")
        :format(cause), REACHABLE[cause] ~= true)
    assert_true(("declared-synthetic %-6s is actually produced by aggregate()")
        :format(cause),
        (AutoPilot_Adaptive.aggregate({
            { cause = "unknown", dist_home = 9999, home_set = 1 },
        })[cause] or 0) > 0)
end

-- ── Test 4: the `infection` rule, on versus off ───────────────────────────────
print("\n== Test 4: an infection death widens detection; no infection death does not ==")

local saved = snapshotConstants()
local base  = AutoPilot_Constants.DETECTION_RADIUS

local applied = AutoPilot_Adaptive.applyRules({ infection = 1 })
assert_eq("ON:  one infection death widens DETECTION_RADIUS by 2",
    AutoPilot_Constants.DETECTION_RADIUS, base + 2)
assert_eq("ON:  ...and records exactly one adjustment", #applied, 1)
assert_eq("ON:  ...attributed to the infection cause", applied[1].cause, "infection")
assert_eq("ON:  ...on the DETECTION_RADIUS key", applied[1].key, "DETECTION_RADIUS")
assert_eq("ON:  ...recording where it came from", applied[1].from, base)
assert_eq("ON:  ...and where it went", applied[1].to, base + 2)
restoreConstants(saved)

-- Negative control: the identical call with the cause absent.
applied = AutoPilot_Adaptive.applyRules({})
assert_eq("OFF: no deaths at all leaves DETECTION_RADIUS where it was",
    AutoPilot_Constants.DETECTION_RADIUS, base)
assert_eq("OFF: ...and records no adjustment", #applied, 0)
restoreConstants(saved)

-- A cause that is NOT infection must not move this constant either, which is
-- what makes the ON result attributable to the rule rather than to any death.
applied = AutoPilot_Adaptive.applyRules({ bleed_out = 1 })
assert_eq("OFF: a bleed-out death leaves DETECTION_RADIUS where it was",
    AutoPilot_Constants.DETECTION_RADIUS, base)
assert_true("OFF: ...while still adjusting its own constant", #applied > 0)
restoreConstants(saved)

-- ── Test 5: the `zombies` rule, on versus off ─────────────────────────────────
print("\n== Test 5: a sub-horde zombie death widens detection; other causes do not ==")

applied = AutoPilot_Adaptive.applyRules({ zombies = 1 })
assert_eq("ON:  one `zombies` death widens DETECTION_RADIUS by 2",
    AutoPilot_Constants.DETECTION_RADIUS, base + 2)
assert_eq("ON:  ...attributed to the zombies cause", applied[1].cause, "zombies")
restoreConstants(saved)

applied = AutoPilot_Adaptive.applyRules({ dehydration = 1 })
assert_eq("OFF: a dehydration death leaves DETECTION_RADIUS where it was",
    AutoPilot_Constants.DETECTION_RADIUS, base)
restoreConstants(saved)

-- Both new causes at once compound, like the two MEDICAL_LOOT_RADIUS rules do.
applied = AutoPilot_Adaptive.applyRules({ infection = 1, zombies = 1 })
assert_eq("both causes together compound to +4",
    AutoPilot_Constants.DETECTION_RADIUS, base + 4)
assert_eq("...as two separately attributed adjustments", #applied, 2)
restoreConstants(saved)

-- ── Test 6: `unknown` is inert BY DECISION, and provably so ───────────────────
print("\n== Test 6: unknown deaths change nothing (the recorded decision) ==")

local before = snapshotConstants()
applied = AutoPilot_Adaptive.applyRules({ unknown = 9 })
assert_eq("nine unknown deaths record no adjustment", #applied, 0)
assert_eq("...and move no constant at all",
    table.concat(movedKeys(before), ", "), "")
restoreConstants(saved)

-- ── Test 7: the new rules obey the cap, and can never reverse a player value ──
-- The 2026-08-08 defect class (PR #133): a bound may STOP an adjustment, never
-- move the constant backwards past where the player set it.  tests/
-- test_adaptive_bounds.lua drives this generically across the whole option
-- range; these two pin it for the rules added here specifically.
print("\n== Test 7: the new rules are bounded, and never move a value backwards ==")

AutoPilot_Constants.DETECTION_RADIUS = 20
AutoPilot_Adaptive.applyRules({ infection = 20 })
assert_eq("20 infection deaths stop at the cap of 30 rather than reaching 60",
    AutoPilot_Constants.DETECTION_RADIUS, 30)
restoreConstants(saved)

-- 40 is the maximum the shipped options slider can set (min 10, max 40), so it
-- sits ABOVE the rule's cap of 30 and the cap must not drag it down.
AutoPilot_Constants.DETECTION_RADIUS = 40
applied = AutoPilot_Adaptive.applyRules({ infection = 1, zombies = 1 })
assert_eq("a player value above the cap is left alone, not shrunk to it",
    AutoPilot_Constants.DETECTION_RADIUS, 40)
assert_eq("...and no adjustment is advertised to the F11 panel", #applied, 0)
restoreConstants(saved)

assert_eq("the suite left every constant as it found it",
    table.concat(movedKeys(saved), ", "), "")

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
