-- tests/test_reason_line.lua
-- V6.0-3 (C2): decision-reason visibility on the F11 panel and the HUD.
--
-- Covers, in order:
--   1. AutoPilot.reasonLine as a PURE formatter, pinned against the reason
--      vocabulary docs/triage.md documents (including the fail_reason cases
--      pain_block/panic that answer "why is it doing nothing").
--   2. The fallback contract: an unknown, empty, or deliberately-unmapped
--      reason renders as the plain action string, so a new token can never
--      blank the panel.
--   3. The L-003 drift guard: every mapped token in AutoPilot._REASON_LABELS
--      is read back against the emitting Lua sources, so a renamed or
--      deleted reason cannot leave a dead mapping.
--   4. Integration in the shape test_main_logic.lua uses for
--      getActionIntention: the F11 panel and the action HUD render the SAME
--      formatted value from the same source (AutoPilot.getActionLine).
--   5. The REAL AutoPilot_Telemetry read side: getDecisionReason survives
--      logTick's pending-state clear, fail_reason wins, and the literal
--      idle/no_action gate still surfaces a blocked sleep's fail label.
--
-- Run from the project root with standard Lua 5.1:
--   lua5.1 tests/test_reason_line.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Events mock — capture registered handlers ─────────────────────────────────
local _registeredHandlers = {
    OnTick              = {},
    OnKeyPressed        = {},
    OnJoypadButtonPress = {},
    OnMainMenuEnter     = {},
    OnQueueNewGame      = {},
}

Events = {}
for name, list in pairs(_registeredHandlers) do
    Events[name] = {
        Add = function(handler)
            table.insert(list, handler)
        end,
    }
end

local function fireEvent(name, ...)
    for _, h in ipairs(_registeredHandlers[name]) do
        h(...)
    end
end

-- ── Load constants ────────────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Keyboard key mock ─────────────────────────────────────────────────────────
Keyboard = { KEY_F10 = 87 }

-- ── Stub dependency modules (the test_main_logic.lua harness shape) ───────────
AutoPilot_Medical = {
    _bleeding = false,
    hasCriticalWound = function(_player) return AutoPilot_Medical._bleeding end,
    check            = function(_player, _bleedOnly) return false end,
    getWoundSnapshot = function(_player) return { bleeding = 0 } end,
}

AutoPilot_Inventory = {
    adjustClothing        = function(_) return false end,
    checkAndSwapWeapon    = function(_) end,
    getBestWeapon         = function(_) return nil end,
    equipBestExerciseItem = function(_) return "none" end,
    findWaterSource       = function(_) return nil end,
    getBestDrink          = function(_) return nil end,
    getBestFood           = function(_) return nil end,
    lootNearbyFood        = function(_) return false end,
    lootNearbyDrink       = function(_) return false end,
    supplyRunLoot         = function(_) end,
    getReadable           = function(_) return nil end,
    lootNearbyReadable    = function(_) return false end,
    refillWaterContainer  = function(_) end,
    drinkFromSource       = function(_) return false end,
    preferTastyFood       = function(_) return nil end,
    bodyTemperature       = function(_) return 0 end,
    selectFoodByWeight    = function(_) return nil end,
    getBestFoodForHunger  = function(_) return nil end,
}

dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.iterateNearbySquares = function(...) end
AutoPilot_Utils.findNearestSquare    = function(...) return nil end

AutoPilot_Home = {
    isSet      = function(_player) return true end,
    isInside   = function(_sq, _pnum) return true end,
    set        = function(_player) end,
    getState   = function(_player) return 0, 0, 0, 150 end,
    clampSq    = function(sq, _) return sq end,
    getNearestInside = function(...) return nil end,
}

AutoPilot_Threat = {
    getNearbyZombies      = function(_player) return {} end,
    countNegativeMoodles  = function(_player) return 0 end,
    check                 = function(_player) return false end,
    forceFlee             = function(_) end,
}

AutoPilot_Map = {
    isDepleted    = function(_sq) return false end,
    markDepleted  = function(_sq) end,
    resetDepleted = function() end,
}

-- Telemetry stub with BOTH configurable read sides: the decision label
-- (test_main_logic's _pendingLabel pattern) and the V6.0-3 reason.
local _telemLog = {}

AutoPilot_Telemetry = {
    setDecision = function(_action, _reason, _player) end,
    getPendingAction = function(_player)
        return AutoPilot_Telemetry._pendingLabel or "idle"
    end,
    _pendingLabel = nil,
    getDecisionReason = function(_player)
        return AutoPilot_Telemetry._reasonLabel or ""
    end,
    _reasonLabel = nil,
    logTick = function(player, action, reason)
        table.insert(_telemLog, { action = action, reason = reason })
    end,
    onDeath    = function(_player) end,
    onShutdown = function(_player) end,
    getRunTick = function() return 0 end,
}

-- HaloTextHelper mock: captures halo lines so the HUD action line can be
-- asserted.
local _haloLines = {}
HaloTextHelper = {
    addText     = function(_player, text) table.insert(_haloLines, text) end,
    addGoodText = function(_player, text) table.insert(_haloLines, text) end,
    addBadText  = function(_player, text) table.insert(_haloLines, text) end,
}

--- Most recent "Action: ..." halo line, or nil if none was emitted.
local function lastActionLine()
    for i = #_haloLines, 1, -1 do
        local line = _haloLines[i]
        if type(line) == "string" and line:match("^Action: ") then
            return line
        end
    end
    return nil
end

ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end

AutoPilot_Needs = {
    _returnVal = false,
    check = function(_player, _skip)
        return AutoPilot_Needs._returnVal
    end,
    shouldInterrupt = function(_player) return false end,
    preferredExerciseType = function(_player) return "either" end,
    getExerciseStatus = function()
        return { outcome = "idle", setsToday = 0, cap = 20 }
    end,
    noteForeignExercise    = function(_player) end,
    noteModExerciseCleared = function() end,
    notePanicStop          = function() end,
}

local _mockPlayers = {}

function getPlayer(idx)
    idx = idx or 0
    return _mockPlayers[idx]
end

function getSpecificPlayer(idx)
    return _mockPlayers[idx or 0]
end

function getPlayerCount()
    local n = 0
    for k, _ in pairs(_mockPlayers) do
        if k >= n then n = k + 1 end
    end
    return math.max(n, 1)
end

-- ── Load the modules under test ───────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Main.lua")

-- AutoPilot_UI is loaded the same way tests/test_main_logic.lua loads it:
-- suite-local stubs for its two LOAD-time widget calls only.  Nothing is
-- instantiated and no drawing function runs; the pure string functions the
-- panel composes its status row from are exercised for real.
do
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
end

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

local function assert_true(desc, val)  assert_eq(desc, not not val, true)  end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function makePlayer(pnum, cfg)
    cfg = cfg or {}
    local stats   = cfg.stats   or {}
    local moodles = cfg.moodles or {}
    return {
        getStats = function(_self)
            return { get = function(_, k) return stats[k] or 0 end }
        end,
        getMoodles = function(_self)
            return { getMoodleLevel = function(_, k) return moodles[k] or 0 end }
        end,
        getPlayerNum = function(_self) return pnum end,
        getX = function(_self) return 0 end,
        getY = function(_self) return 0 end,
        getZ = function(_self) return 0 end,
        isDead   = function(_self) return cfg.dead   or false end,
        isAsleep = function(_self) return cfg.asleep or false end,
        getPerkLevel = function(_self, _) return 5 end,
        getCurrentSquare = function(_self) return nil end,
        getBodyDamage = function(_self)
            return {
                getBodyParts = function(_s)
                    return { size = function() return 0 end,
                             get  = function() return nil end }
                end,
            }
        end,
        getInventory = function(_self)
            return { getItems = function()
                return { size = function() return 0 end,
                         get  = function() return nil end }
            end }
        end,
    }
end

local function reset()
    _telemLog    = {}
    _mockPlayers = {}
    AutoPilot_Needs._returnVal        = false
    AutoPilot_Telemetry._pendingLabel = nil
    AutoPilot_Telemetry._reasonLabel  = nil
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
    ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end
    _haloLines = {}
    AutoPilot_Constants.HUD_SHOW_ACTION = 1
    MockTime.advance(120000)
end

local function tickN(n)
    for _ = 1, (n or 1) * AutoPilot_Constants.TICK_INTERVAL do
        MockRealTime.advance(16)
        fireEvent("OnTick")
    end
end

local function arm()
    if not AutoPilot.isActive() then
        fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    end
end

local function disarm()
    if AutoPilot.isActive() then
        fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    end
end

print("=== V6.0-3 decision-reason visibility tests ===")

-- 1. The pure formatter, pinned against the documented vocabulary.
print("\n-- Test 1: reasonLine maps every informative documented token")
do
    local cases = {
        -- decision reasons (docs/triage.md "Decision pairs" inventory)
        { "Treating wound",       "bleeding",       "Treating wound (bleeding)" },
        { "Sleeping",             "fatigue_thresh", "Sleeping (tired)" },
        { "Resting",              "low_endurance",  "Resting (worn out)" },
        { "Resting",              "rest_cooldown",  "Resting (catching breath)" },
        { "Resting",              "sit_recover",    "Resting (recovering)" },
        { "Drinking",             "thirst_thresh",  "Drinking (thirsty)" },
        { "Eating",               "hunger_thresh",  "Eating (hungry)" },
        { "Eating",               "unhappy",        "Eating (low mood)" },
        { "Taking shelter",       "weather",        "Taking shelter (bad weather)" },
        { "Adjusting clothing",   "temperature",    "Adjusting clothing (body temperature)" },
        { "Reading",              "boredom",        "Reading (bored)" },
        { "Scavenging supplies",  "low_supplies",   "Scavenging supplies (supplies low)" },
        { "Drying off",           "wet",            "Drying off (soaked)" },
        { "Drying off",           "no_towel",       "Drying off (wet, no towel)" },
        -- fail reasons: why it is doing nothing
        { "Idle, evaluating",     "pain_block",
          "Idle, evaluating (sleep blocked by pain)" },
        { "Idle, evaluating",     "panic",
          "Idle, evaluating (sleep blocked by panic)" },
        { "Idle, evaluating",     "carry_full",
          "Idle, evaluating (carrying too much)" },
    }
    for _, c in ipairs(cases) do
        assert_eq(("%s + %s"):format(c[1], c[2]),
            AutoPilot.reasonLine(c[1], c[2]), c[3])
    end
end

-- 2. Deliberately-plain tokens: persistent states and redundant reasons.
print("\n-- Test 2: persistent/redundant tokens render the plain action string")
do
    local plain = {
        -- persistent states (the literal logTick gates in Main)
        { "Sleeping",               "asleep" },
        { "Idle, evaluating",       "no_action" },
        { "Cooldown",               "post_action" },
        { "Busy (player action in progress)", "foreign_action" },
        { "Busy (action in progress)",        "action_running" },
        { "Dead",                   "player_died" },
        -- documented tokens whose action label already says it
        { "Treating wound",         "wound" },
        { "Training",               "training" },
        { "Fighting/fleeing zombies", "threat" },
    }
    for _, c in ipairs(plain) do
        assert_eq(("%s + %s stays plain"):format(c[1], c[2]),
            AutoPilot.reasonLine(c[1], c[2]), c[1])
    end
end

-- 3. The fallback contract: unknown/empty/nil can never blank the line.
print("\n-- Test 3: unknown or empty reason renders the plain action string")
do
    assert_eq("unknown token stays plain",
        AutoPilot.reasonLine("Eating", "some_future_reason"), "Eating")
    assert_eq("empty reason stays plain",
        AutoPilot.reasonLine("Eating", ""), "Eating")
    assert_eq("nil reason stays plain",
        AutoPilot.reasonLine("Eating", nil), "Eating")
    assert_eq("non-string reason stays plain",
        AutoPilot.reasonLine("Eating", { bad = true }), "Eating")
    assert_eq("empty action falls back to the idle label",
        AutoPilot.reasonLine("", "hunger_thresh"),
        "Idle, evaluating (hungry)")
    assert_eq("nil action falls back to the idle label",
        AutoPilot.reasonLine(nil, nil), "Idle, evaluating")
end

-- 4. L-003 drift guard: every mapped token is emitted by the mod's sources.
--    Source A: AutoPilot._REASON_LABELS (the formatter's mapping table).
--    Source B: the setDecision literals in AutoPilot_Needs.lua plus the
--    fail labels AutoPilot_Sleep.canSleepNow returns.  A mapping whose token
--    no source emits is dead weight and fails here.
print("\n-- Test 4: no dead mappings (drift guard over the emitting sources)")
do
    local emitted = {}

    local needsSrc = assert(
        io.open("42/media/lua/client/AutoPilot_Needs.lua", "r"),
        "AutoPilot_Needs.lua must be readable from the project root")
    local needsText = needsSrc:read("*a")
    needsSrc:close()
    for reason in needsText:gmatch('setDecision%(%s*"[%w_]+"%s*,%s*"([%w_]+)"') do
        emitted[reason] = true
    end

    local sleepSrc = assert(
        io.open("42/media/lua/client/AutoPilot_Sleep.lua", "r"),
        "AutoPilot_Sleep.lua must be readable from the project root")
    local sleepText = sleepSrc:read("*a")
    sleepSrc:close()
    for fail in sleepText:gmatch('return%s+false%s*,%s*"([%w_]+)"') do
        emitted[fail] = true
    end

    -- Source C (2026-07-26): the fail labels AutoPilot_Inventory's carry gate
    -- returns (`return false, "carry_full"` in _queueTransfer), same shape as
    -- the Sleep fail labels above.  These reach setDecision's fail_reason via
    -- doProactiveScavenge in Needs, so the literal lives in Inventory.
    local invSrc = assert(
        io.open("42/media/lua/client/AutoPilot_Inventory.lua", "r"),
        "AutoPilot_Inventory.lua must be readable from the project root")
    local invText = invSrc:read("*a")
    invSrc:close()
    for fail in invText:gmatch('return%s+false%s*,%s*"([%w_]+)"') do
        emitted[fail] = true
    end

    -- Source D (2026-07-27): the setDecision literals in AutoPilot_Media.lua.
    -- The media arm emits its own decisions ("media"/"boredom" on an approach,
    -- "media"/"stalled" when the stall backoff fires), and those literals live
    -- in Media, which none of the scans above can see.
    local mediaSrc = assert(
        io.open("42/media/lua/client/AutoPilot_Media.lua", "r"),
        "AutoPilot_Media.lua must be readable from the project root")
    local mediaText = mediaSrc:read("*a")
    mediaSrc:close()
    for reason in mediaText:gmatch('setDecision%(%s*"[%w_]+"%s*,%s*"([%w_]+)"') do
        emitted[reason] = true
    end

    -- Negative control for the extraction itself: if any pattern went
    -- blind, these six sentinels disappear and the guard fails loudly
    -- instead of passing vacuously.
    assert_true("extraction sees a Needs decision reason (hunger_thresh)",
        emitted["hunger_thresh"])
    assert_true("extraction sees the Sleep fail label pain_block",
        emitted["pain_block"])
    assert_true("extraction sees the Sleep fail label panic",
        emitted["panic"])
    assert_true("extraction sees the dry-off reason wet",
        emitted["wet"])
    assert_true("extraction sees the Inventory fail label carry_full",
        emitted["carry_full"])
    assert_true("extraction sees the Media stall reason stalled",
        emitted["stalled"])

    local mapped = AutoPilot._REASON_LABELS
    assert_true("the formatter's mapping table is exposed",
        type(mapped) == "table")
    for token, _ in pairs(mapped) do
        assert_true(("mapped token '%s' is emitted by a source"):format(token),
            emitted[token] == true)
    end
end

-- 5. Integration: the HUD renders the reason (test_main_logic shape).
print("\n-- Test 5: the action HUD carries the decision reason")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)  -- drain residual cooldown
    AutoPilot_Needs._returnVal        = true
    AutoPilot_Telemetry._pendingLabel = "eat"
    AutoPilot_Telemetry._reasonLabel  = "hunger_thresh"
    tickN(1)
    assert_eq("the HUD line carries the reason",
        lastActionLine(), "Action: Eating (hungry)")
    disarm()
end

-- 6. Integration: panel and HUD render the SAME formatted value from the
--    same source (the V5.8 agreement rule, extended to the reason).
print("\n-- Test 6: panel and HUD agree on the reason-carrying line")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)
    AutoPilot_Needs._returnVal        = true
    AutoPilot_Telemetry._pendingLabel = "eat"
    AutoPilot_Telemetry._reasonLabel  = "hunger_thresh"
    tickN(1)

    local line   = AutoPilot.getActionLine(player)
    local status = AutoPilot_Needs.getExerciseStatus()
    assert_eq("the composed line is the reason-carrying string",
        line, "Eating (hungry)")
    assert_eq("the HUD renders exactly the composed line",
        lastActionLine(), "Action: " .. line)
    assert_eq("the panel status text is literally the composed line",
        AutoPilot_UI.statusText(line, status), line)
    assert_eq("the full panel row renders the same value",
        AutoPilot_UI.statusLine(line, status),
        "Status: Eating (hungry)   Sets today: 0")
    disarm()
end

-- 7. The C2 core case: "why is it doing nothing" — an idle cycle whose
--    blocked sleep left a fail_reason renders the explanation.
print("\n-- Test 7: an idle cycle surfaces the blocked-sleep fail reason")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)
    AutoPilot_Needs._returnVal       = false          -- nothing claims the cycle
    AutoPilot_Telemetry._reasonLabel = "pain_block"   -- the logged fail label
    tickN(1)
    assert_eq("the HUD explains the refusal instead of a bare Idle",
        lastActionLine(), "Action: Idle, evaluating (sleep blocked by pain)")
    local line = AutoPilot.getActionLine(player)
    assert_eq("the panel gets the same explanation",
        AutoPilot_UI.statusText(line, AutoPilot_Needs.getExerciseStatus()),
        "Idle, evaluating (sleep blocked by pain)")
    disarm()
end

-- 8. Disarmed never carries a reason: the last logged reason is stale.
print("\n-- Test 8: disarmed renders plain, whatever the last reason was")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    disarm()
    AutoPilot_Telemetry._reasonLabel = "hunger_thresh"
    assert_eq("no stale parenthetical on a disarmed mod",
        AutoPilot.getActionLine(player), "Disarmed (no monitoring)")
end

-- 9. The two decision labels that had no display label render honestly now.
print("\n-- Test 9: dry and media cycles no longer render as Idle")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)
    AutoPilot_Needs._returnVal        = true
    AutoPilot_Telemetry._pendingLabel = "dry"
    AutoPilot_Telemetry._reasonLabel  = "wet"
    tickN(1)
    assert_eq("a drying-off cycle names itself, with the reason",
        lastActionLine(), "Action: Drying off (soaked)")

    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)
    AutoPilot_Telemetry._pendingLabel = "media"
    AutoPilot_Telemetry._reasonLabel  = "boredom"
    tickN(1)
    assert_eq("a media cycle names itself, with the reason",
        lastActionLine(), "Action: Enjoying media (bored)")
    disarm()
end

-- 10. The REAL telemetry read side (loaded exactly like
--     test_telemetry_schema.lua: real Map + Home first, then Telemetry).
--     This replaces the suite stubs, so it runs LAST.
print("\n-- Test 10: real getDecisionReason survives logTick's pending clear")
do
    dofile("42/media/lua/client/AutoPilot_Map.lua")
    dofile("42/media/lua/client/AutoPilot_Home.lua")
    dofile("42/media/lua/client/AutoPilot_Telemetry.lua")

    local player = makePlayer(0)

    assert_eq("a fresh player reads the empty default",
        AutoPilot_Telemetry.getDecisionReason(player), "")

    -- A normal decision cycle: the reason outlives the pending clear.
    AutoPilot_Telemetry.setDecision("eat", "hunger_thresh")
    AutoPilot_Telemetry.logTick(player)
    assert_eq("the decision reason is readable AFTER the cycle logged",
        AutoPilot_Telemetry.getDecisionReason(player), "hunger_thresh")
    assert_eq("the pending action store was still cleared as before",
        AutoPilot_Telemetry.getPendingAction(player), "idle")

    -- A blocked sleep that queued anyway (relievePain path): fail wins.
    AutoPilot_Telemetry.setDecision("sleep", "fatigue_thresh", nil, nil,
        "pain_block")
    AutoPilot_Telemetry.logTick(player)
    assert_eq("a non-empty fail_reason wins over the decision reason",
        AutoPilot_Telemetry.getDecisionReason(player), "pain_block")

    -- The Main gate shape: a blocked sleep FELL THROUGH to nothing, and the
    -- idle tick is logged with literal overrides.  The pending fail label
    -- still surfaces — the exact "why is it doing nothing" case.
    AutoPilot_Telemetry.setDecision("sleep", "fatigue_thresh", nil, nil,
        "panic")
    AutoPilot_Telemetry.logTick(player, "idle", "no_action")
    assert_eq("a literal-override idle tick still surfaces the fail label",
        AutoPilot_Telemetry.getDecisionReason(player), "panic")

    -- The next clean cycle replaces it: no reason sticks around forever.
    AutoPilot_Telemetry.setDecision("drink", "thirst_thresh")
    AutoPilot_Telemetry.logTick(player)
    assert_eq("the next clean cycle replaces the stale fail label",
        AutoPilot_Telemetry.getDecisionReason(player), "thirst_thresh")

    -- Purity: repeated reads never consume the value.
    local a = AutoPilot_Telemetry.getDecisionReason(player)
    local b = AutoPilot_Telemetry.getDecisionReason(player)
    assert_eq("repeated reads are stable (pure read)", a, b)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
