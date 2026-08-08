-- tests/test_game_clock_debounce.lua
-- Every deadline this mod stores against the GAME CALENDAR must outlast one
-- evaluation cycle, and must be named rather than written as a raw literal.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- tests/test_clock_discipline.lua (2026-08-06) classifies every time-source
-- CALL SITE in shipped client Lua: which clock a module reads, and why.  It
-- says nothing about the DURATIONS added to those readings, and that is the
-- half where this repo's shipped defects actually live.  Its own docstring
-- names V5.4 -- "the rest hold was `ms + 60000` against the GAME calendar,
-- sixty in-game seconds, ~2.5 real seconds, so the character stood back up
-- having recovered nothing" -- as a fixed instance of the class, while its
-- CLASSIFICATION table carried two more instances as PROSE:
--
--   AutoPilot_Consumption.lua -> "sweep finding: 8000/5000 game-ms expire
--     faster than one decision cycle at default day length -- filed LOW"
--   AutoPilot_Sleep.lua       -> "sweep finding: the 'delaying sleep for 60s'
--     print means 60 GAME seconds, ~2.5 real seconds -- filed LOW"
--
-- A defect recorded inside the guard that exists to prevent it is a defect the
-- guard cannot fail on.  Both were fixed 2026-08-08 alongside a THIRD instance
-- neither entry mentioned (AutoPilot_Sleep's two `ms + 15000` re-queue
-- guards), and this suite is what makes a fourth impossible to land quietly.
--
-- THE ARITHMETIC, so it is not re-derived
-- ---------------------------------------
--   * One evaluation is TICK_INTERVAL (15) counter units, and OnTick fires at
--     ~20 per REAL second, so an evaluation is 0.75 s REAL.
--   * The game calendar advances ~24x real at the DEFAULT 1-hour day length,
--     so one evaluation is ~18000 GAME ms.
--   * That figure is INVARIANT under fast-forward -- the cadence counter
--     advances by the game-speed multiplier (FF-1, PR #70, remainder carried
--     by PR #129) -- and NOT invariant under the Day Length sandbox option,
--     which scales it directly.  See known_gap_ below: the floor asserted here
--     is a DEFAULT-day-length statement and is stated as one.
--   * A deadline shorter than one evaluation has therefore already expired by
--     the time the code holding it next runs.  It is unreachable, not short,
--     and no test that exercises the module can see the difference -- which is
--     exactly why three of them survived a dedicated clock sweep.
--
-- WHAT THIS SUITE ENFORCES
-- ------------------------
--   1. No raw numeric literal in game-clock deadline arithmetic.  Every
--      `<something>Ms = <clock> + <X>` names a constant, so the value has one
--      home and a reviewable comment.
--   2. Every such term resolves to a declared debounce constant (directly, via
--      a module-local alias, or via a listed derived term with its reason).
--   3. Every declared debounce constant is at least one evaluation cycle.
--   4. EVAL_CYCLE_GAME_MS is re-derived here from TICK_INTERVAL and the two
--      documented ratios, so changing the cadence without re-deriving the
--      floor fails instead of silently invalidating every value below it.
--
-- Discovery is GLOB-DRIVEN with a zero-match hard failure, like
-- tests/test_clock_discipline.lua and test_walk_gate_coverage.lua.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_game_clock_debounce.lua

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
-- No stderr redirect: `2>/dev/null` is shell syntax io.popen's Windows host
-- (cmd.exe) does not understand, and an empty list must fail loudly rather
-- than pass quietly.
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

-- Comments are not code.  This matters more here than in the sibling guards:
-- the tree DELIBERATELY quotes the retired literals in prose (AutoPilot_Rest's
-- V5.4 note keeps "`ms + 60000`", and the 2026-08-08 fix left the same kind of
-- tombstone in AutoPilot_Consumption and AutoPilot_Sleep), so a scanner that
-- read comments would report the fixed defects forever.
local function stripComments(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cut = line:find("%-%-")
        out[#out + 1] = cut and line:sub(1, cut - 1) or line
    end
    return table.concat(out, "\n")
end

-- ── The scanner ───────────────────────────────────────────────────────────────
-- A deadline STORE is `<name ending in Ms> = <ident> + <term>`: the shape that
-- parks a future instant in module state.  Returns a list of
-- { name, base, term } and a list of module-local aliases (alias -> constant).
local function scanDeadlines(text)
    local stores, aliases = {}, {}
    for line in (stripComments(text) .. "\n"):gmatch("([^\n]*)\n") do
        local alias, const = line:match(
            "local%s+([%w_]+)%s*=%s*AutoPilot_Constants%.([%w_]+)")
        if alias then aliases[alias] = const end

        local name, base, term = line:match(
            "([%w_]*Ms)%s*=%s*([%w_]+)%s*%+%s*([%w_%.]+)")
        -- Require the stored name to genuinely END in "Ms" (the pattern above
        -- is greedy, so "windowMsX" cannot slip through) and to not be a field
        -- access, which would be another module's state, not a local deadline.
        if name and name:sub(-2) == "Ms" and #name > 2 then
            stores[#stores + 1] = { name = name, base = base, term = term }
        end
    end
    return stores, aliases
end

local function isNumericLiteral(term)
    return term:match("^%d+$") ~= nil
end

-- ── The declared debounce constants (one entry per named game-clock duration
--    stored as a deadline, with the reason that value is right) ──────────────
local DEBOUNCE_CONSTANTS = {
    DRINK_COOLDOWN_MS = "re-drink guard; was a raw 8000/5000 (8 and 5 GAME "
        .. "seconds), both under one evaluation cycle, so doDrink's `if ms < "
        .. "drinkCooldownMs` could never be true",
    SLEEP_RETRY_COOLDOWN_MS = "re-queue guard after a bed/vehicle sleep is "
        .. "dispatched; was a raw 15000 at both sites, under one cycle",
    SLEEP_PAIN_COOLDOWN_MS = "back-off when sleep is pain-blocked with no "
        .. "relief available; this branch queues NOTHING, so it never earns "
        .. "the post_action window and this deadline is the only guard",
    EXERCISE_WAIT_LOG_MS = "console throttle for the endurance-gate line; "
        .. "already above the floor, named so the raw-literal ban needs no "
        .. "exception",
    MEDIA_COOLDOWN_MS = "TV/radio re-queue cooldown; game-time coupled like "
        .. "the media progress it guards",
    MEDIA_STALL_BACKOFF_MS = "how long the media arm stops claiming relief "
        .. "after a stall",
    REST_HOLD_MS = "V5.4 rest hold -- the ORIGINAL instance of this class "
        .. "(was `ms + 60000`), fixed then and kept here so the floor covers "
        .. "it too; read live in AutoPilot_Rest so the options slider applies",
}

-- Terms that are computed rather than named, with the reason each is exempt
-- from the "must be a declared constant" rule.  Forward AND reverse checked,
-- so this list cannot grow silently or rot.
local DERIVED_TERMS = {
    windowMs = "AutoPilot_Exercise._backoffWindowMs(): "
        .. "EXERCISE_BACKOFF_MINUTES * 60000, a minutes->ms conversion of a "
        .. "player-tunable, and it early-returns on <= 0 so a zero window "
        .. "disables the backoff rather than storing a stale deadline",
}

-- ── Load the real engine mock, constants and the two fixed modules ────────────
-- The static arms (Tests 1-8) need only the constants; the behavioural arms
-- (Tests 9-10) drive the real doDrink and doSleep against the mock clock.
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")
local C = AutoPilot_Constants

dofile("42/media/lua/client/AutoPilot_Utils.lua")

-- doSleep's pain branch asks Medical for a treatment and Home whether an
-- anchor exists; neither is under test here, so both answer "nothing".
AutoPilot_Home    = { isSet = function(_player) return false end }
AutoPilot_Medical = { check = function(_player, _force) return false end }

-- doDrink's water-source branch is the shortest path to the debounce: it
-- touches AutoPilot_Inventory and the clock, and nothing else.
local DRANK = 0
AutoPilot_Inventory = {
    findWaterSource      = function(_player) return { tag = "sink" } end,
    refillWaterContainer = function(_player, _obj) return true end,
    drinkFromSource      = function(_player, _obj)
        DRANK = DRANK + 1
        return true
    end,
}

dofile("42/media/lua/client/AutoPilot_Consumption.lua")
dofile("42/media/lua/client/AutoPilot_Sleep.lua")

-- ── 1. Discovery and scanner-blindness controls ───────────────────────────────
print("\n-- Test 1: discovery finds the modules and the scanner finds deadlines")
local files = productionFiles()
local allStores = {}
do
    assert_true(("glob discovery found modules (got %d, need >= 20)")
        :format(#files), #files >= 20)

    for _, path in ipairs(files) do
        local text = readFile(path)
        if text then
            local stores, aliases = scanDeadlines(text)
            for _, s in ipairs(stores) do
                s.file    = path:match("([^/]+)$") or path
                s.aliases = aliases
                allStores[#allStores + 1] = s
            end
        end
    end

    -- Aggregate PRESENCE, no file pinned (the L-031 discipline): if the
    -- scanner stops seeing deadline stores that provably exist, the guard has
    -- gone blind and must say so rather than reporting clean.
    assert_true(("the scanner sees deadline stores in the real tree "
        .. "(got %d, need >= 6)"):format(#allStores), #allStores >= 6)
end

-- ── 2. No raw numeric literal in game-clock deadline arithmetic ───────────────
print("\n-- Test 2: every deadline names a constant, none writes a raw literal")
do
    local raw = {}
    for _, s in ipairs(allStores) do
        if isNumericLiteral(s.term) then
            raw[#raw + 1] = ("%s :: %s = %s + %s")
                :format(s.file, s.name, s.base, s.term)
        end
    end
    table.sort(raw)
    assert_eq("no raw-literal deadline (name it in AutoPilot_Constants so the "
        .. "value has one home and the floor below can check it)",
        table.concat(raw, ", "), "")
end

-- ── 3. Every deadline term resolves to a declared constant ────────────────────
print("\n-- Test 3: every deadline term is declared (constant, alias, derived)")
do
    local undeclared = {}
    for _, s in ipairs(allStores) do
        if not isNumericLiteral(s.term) then
            local const = s.term:match("^AutoPilot_Constants%.([%w_]+)$")
                or s.aliases[s.term]
            local ok = (const and DEBOUNCE_CONSTANTS[const] ~= nil)
                or DERIVED_TERMS[s.term] ~= nil
            if not ok then
                undeclared[#undeclared + 1] = s.file .. " :: " .. s.term
            end
        end
    end
    table.sort(undeclared)
    assert_eq("no undeclared deadline term (add it to DEBOUNCE_CONSTANTS with "
        .. "its reason, or to DERIVED_TERMS if it is computed)",
        table.concat(undeclared, ", "), "")
end

-- ── 4. The floor: every declared constant outlasts one evaluation cycle ───────
print("\n-- Test 4: every declared debounce is at least one evaluation cycle")
do
    local cycle = tonumber(C.EVAL_CYCLE_GAME_MS)
    assert_true("EVAL_CYCLE_GAME_MS is a positive number",
        cycle ~= nil and cycle > 0)

    local tooShort, missing = {}, {}
    for name in pairs(DEBOUNCE_CONSTANTS) do
        local v = tonumber(C[name])
        if v == nil then
            missing[#missing + 1] = name
        elseif v < cycle then
            tooShort[#tooShort + 1] = ("%s=%d < cycle=%d"):format(
                name, v, cycle)
        end
    end
    table.sort(tooShort)
    table.sort(missing)
    assert_eq("every declared debounce constant exists in AutoPilot_Constants",
        table.concat(missing, ", "), "")
    assert_eq("every declared debounce outlasts one evaluation cycle (a "
        .. "shorter one has already expired when its reader next runs)",
        table.concat(tooShort, ", "), "")
end

-- ── 5. Anti-rot: every declared constant is still referenced by shipped Lua ───
print("\n-- Test 5: no stale declaration (a deleted constant fails here)")
do
    local corpus = {}
    for _, path in ipairs(files) do
        corpus[#corpus + 1] = stripComments(readFile(path) or "")
    end
    local code = table.concat(corpus, "\n")

    local unused = {}
    for name in pairs(DEBOUNCE_CONSTANTS) do
        if not code:find(name, 1, true) then unused[#unused + 1] = name end
    end
    table.sort(unused)
    assert_eq("no declared debounce constant has lost its call site (delete "
        .. "the entry when the deadline goes away)",
        table.concat(unused, ", "), "")

    local unusedDerived = {}
    for term in pairs(DERIVED_TERMS) do
        if not code:find(term, 1, true) then
            unusedDerived[#unusedDerived + 1] = term
        end
    end
    table.sort(unusedDerived)
    assert_eq("no stale DERIVED_TERMS exemption",
        table.concat(unusedDerived, ", "), "")
end

-- ── 6. The floor is DERIVED, not asserted twice ───────────────────────────────
-- The two ratios below are the shipped documentation's own numbers, quoted
-- here so this test and AutoPilot_Constants are genuinely independent sources:
--   "PZ runs at ~20 game ticks per real second"  (AutoPilot_Constants.lua)
--   "advances ~24x real at the default 1-hour day length"
--                                        (tests/test_clock_discipline.lua)
-- Changing TICK_INTERVAL without re-deriving EVAL_CYCLE_GAME_MS silently
-- invalidates every value Test 4 checks, so it must fail here instead.
print("\n-- Test 6: EVAL_CYCLE_GAME_MS is re-derived from the cadence")
do
    local TICKS_PER_REAL_SECOND      = 20
    local GAME_MS_PER_REAL_SECOND    = 24000  -- 1000 ms * 24x day-length ratio
    local expected = (tonumber(C.TICK_INTERVAL) / TICKS_PER_REAL_SECOND)
        * GAME_MS_PER_REAL_SECOND
    assert_eq("EVAL_CYCLE_GAME_MS matches TICK_INTERVAL / 20 ticks-per-second "
        .. "* 24000 game-ms-per-real-second",
        tonumber(C.EVAL_CYCLE_GAME_MS), expected)

    assert_eq("GAME_DEBOUNCE_MIN_MS is ACTION_COOLDOWN_CYCLES evaluation "
        .. "cycles (the post_action window _tickForPlayer already enforces)",
        tonumber(C.GAME_DEBOUNCE_MIN_MS),
        tonumber(C.ACTION_COOLDOWN_CYCLES) * tonumber(C.EVAL_CYCLE_GAME_MS))
end

-- ── 7. known_gap_: the floor is a DEFAULT-day-length statement ────────────────
-- Pinned rather than filed as prose, so the residual cannot be mistaken for
-- coverage.  Day Length is a sandbox option: at the shortest setting (a
-- 15-minute day, ~96x real) one evaluation is FOUR times the floor asserted
-- above, and a constant sized to the default floor is unreachable again.  The
-- assertions below pin that this is TRUE TODAY of the one declared constant
-- that is not sized from GAME_DEBOUNCE_MIN_MS.  They fail if someone either
-- fixes the gap or widens it -- which is the point: this is the open item, not
-- a passing guarantee.
print("\n-- Test 7: known_gap_ the floor is default-day-length only")
do
    local SHORTEST_DAY_RATIO = 4   -- 15-minute day (~96x) vs the default ~24x
    local shortestCycle = tonumber(C.EVAL_CYCLE_GAME_MS) * SHORTEST_DAY_RATIO

    assert_true("known_gap_ every GAME_DEBOUNCE_MIN_MS-sized constant is "
        .. "EXACTLY one evaluation cycle at the shortest day length, i.e. the "
        .. "margin is gone rather than negative",
        tonumber(C.GAME_DEBOUNCE_MIN_MS) == shortestCycle)

    assert_true("known_gap_ EXERCISE_WAIT_LOG_MS (a console throttle, not a "
        .. "behaviour gate) falls BELOW one cycle at the shortest day length",
        tonumber(C.EXERCISE_WAIT_LOG_MS) < shortestCycle)
end

-- ── 8. Scanner self-controls (it can both fire and stay silent) ───────────────
print("\n-- Test 8: scanner controls on synthetic input")
do
    -- A raw literal deadline is SEEN, and seen as a literal.
    local stores = scanDeadlines("        fooCooldownMs = ms + 5000")
    assert_eq("a raw-literal deadline is seen", #stores, 1)
    assert_true("...and its term is classified as a numeric literal",
        stores[1] and isNumericLiteral(stores[1].term))

    -- The same line inside a comment is NOT seen (the tree keeps the retired
    -- literals as tombstones; a comment-reading scanner would never go green).
    stores = scanDeadlines("    -- V5.4: was `ms + 60000`, sixty GAME seconds")
    assert_eq("a commented-out deadline is not seen", #stores, 0)

    -- A named deadline is seen and is NOT a literal.
    stores = scanDeadlines("    barMs = ms + AutoPilot_Constants.REST_HOLD_MS")
    assert_eq("a named deadline is seen", #stores, 1)
    assert_true("...and its term is not a literal",
        stores[1] and not isNumericLiteral(stores[1].term))

    -- An alias declaration is captured so Test 3 can resolve it.
    local _, aliases = scanDeadlines(
        "local MEDIA_COOLDOWN_MS = AutoPilot_Constants.MEDIA_COOLDOWN_MS")
    assert_eq("a module-local alias resolves to its constant",
        aliases.MEDIA_COOLDOWN_MS, "MEDIA_COOLDOWN_MS")

    -- A non-deadline assignment is not a deadline: no `+`, so no store.
    stores = scanDeadlines("    local fullSetMs = EXERCISE_MINUTES * 60000")
    assert_eq("a minutes->ms conversion is not a deadline store", #stores, 0)

    -- A name that merely CONTAINS "Ms" but does not end in it is ignored.
    stores = scanDeadlines("    fooMsLeft = ms + 5000")
    assert_eq("a name not ending in Ms is ignored", #stores, 0)
end

-- ── 9. BEHAVIOUR: the drink debounce now actually gates ───────────────────────
-- The difference this proves, one evaluation cycle after a successful drink:
--   before  drinkCooldownMs = ms + 8000   -> 8000 < 18000, expired, drinks again
--   after   drinkCooldownMs = ms + 72000  -> still held, doDrink returns false
-- Reverting either literal in AutoPilot_Constants flips the second assertion.
print("\n-- Test 9: doDrink is debounced for a full evaluation cycle and more")
do
    MockTime.set(1000000)
    DRANK = 0
    local player = {}

    assert_true("first doDrink drinks from the water source",
        AutoPilot_Consumption.doDrink(player))
    assert_eq("...and the source was used exactly once", DRANK, 1)

    -- One evaluation cycle later: the OLD 8000/5000 deadlines had expired here.
    MockTime.advance(tonumber(C.EVAL_CYCLE_GAME_MS))
    assert_eq("one evaluation cycle later doDrink is still debounced",
        AutoPilot_Consumption.doDrink(player), false)
    assert_eq("...and did not drink again", DRANK, 1)

    -- Past the full deadline it releases, so the guard delays rather than bans.
    MockTime.advance(tonumber(C.DRINK_COOLDOWN_MS))
    assert_true("past DRINK_COOLDOWN_MS the guard releases",
        AutoPilot_Consumption.doDrink(player))
    assert_eq("...and the source was used a second time", DRANK, 2)
end

-- ── 10. BEHAVIOUR: the pain-blocked sleep back-off outlives its old value ─────
-- This branch queues NOTHING and returns false, so AutoPilot_Main never sets
-- the ACTION_COOLDOWN_CYCLES post_action window for it: the deadline is the
-- only thing standing between a pain-blocked character and one pass per cycle.
--   before  sleepCooldownMs = ms + 60000  -> released at exactly 60000
--   after   sleepCooldownMs = ms + 72000  -> still held there
print("\n-- Test 10: the pain-blocked sleep back-off holds past 60 game seconds")
do
    MockTime.set(2000000)
    -- "No relief available" is the precondition, not the subject: stub the
    -- module's own public relief entry point rather than building an inventory.
    AutoPilot_Sleep.relievePain = function(_player) return false end
    local achyPlayer = {
        getStats = function()
            return { get = function(_self, _stat) return 100 end }
        end,
    }

    assert_eq("pain-blocked sleep reports no action queued",
        AutoPilot_Sleep.doSleep(achyPlayer), false)

    -- One evaluation cycle later: held (true means "handled, do not fall
    -- through"), which the OLD 60000 also managed.
    MockTime.advance(tonumber(C.EVAL_CYCLE_GAME_MS))
    assert_true("one evaluation cycle later the back-off still holds",
        AutoPilot_Sleep.doSleep(achyPlayer))

    -- At exactly the OLD 60000 the previous code released; the new one holds.
    MockTime.set(2000000 + 60000)
    assert_true("at exactly 60 game seconds -- where the old literal expired "
        .. "-- the back-off still holds",
        AutoPilot_Sleep.doSleep(achyPlayer))

    -- And it does release, so this is a delay rather than a permanent block.
    MockTime.set(2000000 + tonumber(C.SLEEP_PAIN_COOLDOWN_MS) + 1)
    assert_eq("past SLEEP_PAIN_COOLDOWN_MS the pain branch runs again",
        AutoPilot_Sleep.doSleep(achyPlayer), false)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
