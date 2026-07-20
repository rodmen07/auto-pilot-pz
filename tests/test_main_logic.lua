-- tests/test_main_logic.lua
-- Unit tests for AutoPilot_Main.lua: per-player mode toggle, cooldown, death
-- logging, sleep-skip, and shouldInterrupt-triggered queue clear.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_main_logic.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Events mock — capture registered handlers ─────────────────────────────────
-- AutoPilot_Main.lua registers handlers via Events.OnTick.Add(),
-- Events.OnKeyPressed.Add(), etc.  We capture them so tests can call them
-- directly to simulate gameplay cycles.
local _registeredHandlers = {
    OnTick             = {},
    OnKeyPressed       = {},
    OnJoypadButtonPress = {},
    OnMainMenuEnter    = {},
    OnQueueNewGame     = {},
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

-- ── Stub dependency modules ───────────────────────────────────────────────────
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

-- Real Utils (V4.5: Main's identity checks read the ownership registry, so
-- the suite must use the same tagging the production queue sites use);
-- square scans are no-op'd, same behavior as the old hand-rolled stub.
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
    forceFight            = function(_) end,
    forceFlee             = function(_) end,
}

AutoPilot_Map = {
    isDepleted    = function(_sq) return false end,
    markDepleted  = function(_sq) end,
    resetDepleted = function() end,
}

-- Override telemetry so tests can inspect calls.
local _telemLog  = {}
local _telemDead = {}
local _telemShut = {}

AutoPilot_Telemetry = {
    setDecision = function(_action, _reason, _player) end,
    -- Real signature already relied on by AutoPilot_Main (the V4.4 intention
    -- label reads _lastActionLabel, which the Needs.check branch sets from
    -- this call); configurable per test via _pendingLabel, default "idle".
    getPendingAction = function(_player)
        return AutoPilot_Telemetry._pendingLabel or "idle"
    end,
    _pendingLabel = nil,
    logTick     = function(player, action, reason)
        table.insert(_telemLog, { action = action, reason = reason })
    end,
    onDeath = function(player)
        local pnum = player and (pcall(function() return player:getPlayerNum() end) and player:getPlayerNum()) or 0
        _telemDead[pnum] = (_telemDead[pnum] or 0) + 1
    end,
    onShutdown = function(player)
        local pnum = 0
        if player then pcall(function() pnum = player:getPlayerNum() end) end
        _telemShut[pnum] = (_telemShut[pnum] or 0) + 1
    end,
    getRunTick = function() return 0 end,
}

-- HaloTextHelper mock: captures every halo line so the V4.4 on-screen
-- action/intention text can be asserted.  Signature matches Main.lua's
-- existing hudAddText/hudAddGood/hudAddBad wrappers, the only real
-- callsites for this global in the mod.
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

-- Extend the ISTimedActionQueue mock with methods required by AutoPilot_Main.
ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end

-- Override Needs to be controllable per test.  The V4.5 intervention
-- notifications are recorders so tests can assert Main calls them at the
-- right moments (the real implementations live in AutoPilot_Needs and are
-- covered by test_priority_logic).
AutoPilot_Needs = {
    _returnVal    = false,
    _foreignNotes = 0,
    _modClearNotes = 0,
    _panicNotes   = 0,
    check = function(_player, _skip)
        return AutoPilot_Needs._returnVal
    end,
    shouldInterrupt = function(_player) return false end,
    trySleep        = function(_player) return false end,
    tryGoOutside    = function(_player) return false end,
    preferredExerciseType = function(_player) return "either" end,
    -- Real signature already relied on by AutoPilot_UI (F11 panel); the
    -- V4.4 intention accessor reads the same call.  Configurable per test.
    getExerciseStatus = function()
        return { outcome = "idle", setsToday = 0, cap = 20 }
    end,
    noteForeignExercise = function(_player)
        AutoPilot_Needs._foreignNotes = AutoPilot_Needs._foreignNotes + 1
    end,
    noteModExerciseCleared = function()
        AutoPilot_Needs._modClearNotes = AutoPilot_Needs._modClearNotes + 1
    end,
    notePanicStop = function()
        AutoPilot_Needs._panicNotes = AutoPilot_Needs._panicNotes + 1
    end,
}

-- getPlayer mock — returns a configurable player table.
local _mockPlayers = {}

function getPlayer(idx)
    idx = idx or 0
    return _mockPlayers[idx]
end

-- getSpecificPlayer mock — the real B42 splitscreen accessor used by
-- _getPlayerByIndex; overrides the registry stub from lua_mock_pz.lua.
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

-- ── Load the module under test ────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Main.lua")

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
local function assert_false(desc, val) assert_eq(desc, not not val, false) end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function makePlayer(pnum, cfg)
    cfg = cfg or {}
    local stats   = cfg.stats   or {}
    local moodles = cfg.moodles or {}
    local player = {
        getStats     = function(self)
            return { get = function(_, k) return stats[k] or 0 end }
        end,
        getMoodles   = function(self)
            return { getMoodleLevel = function(_, k) return moodles[k] or 0 end }
        end,
        getPlayerNum = function(self) return pnum end,
        getX = function(self) return 0 end,
        getY = function(self) return 0 end,
        getZ = function(self) return 0 end,
        isDead   = function(self) return cfg.dead   or false end,
        isAsleep = function(self) return cfg.asleep or false end,
        getPerkLevel = function(self, _) return 5 end,
        getCurrentSquare = function(self) return nil end,
        getBodyDamage = function(self)
            return {
                getBodyParts = function(self_)
                    return { size = function() return 0 end, get = function() return nil end }
                end
            }
        end,
        getInventory = function(self)
            return { getItems = function() return { size=function() return 0 end, get=function() return nil end } end }
        end,
    }
    return player
end

local function reset()
    _telemLog  = {}
    _telemDead = {}
    _telemShut = {}
    _mockPlayers = {}
    AutoPilot_Medical._bleeding = false
    AutoPilot_Needs._returnVal  = false
    AutoPilot_Needs._foreignNotes  = 0
    AutoPilot_Needs._modClearNotes = 0
    AutoPilot_Needs._panicNotes    = 0
    AutoPilot_Needs.shouldInterrupt = function(_player) return false end
    AutoPilot_Needs.getExerciseStatus = function()
        return { outcome = "idle", setsToday = 0, cap = 20 }
    end
    AutoPilot_Telemetry._pendingLabel = nil
    AutoPilot_Threat.check = function(_player) return false end
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
    ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end
    -- V4.4: clear captured halo lines and restore the HUD toggle default
    -- between tests.
    _haloLines = {}
    AutoPilot_Constants.HUD_SHOW_ACTION = 1
    -- Advance mock clock to expire any active cooldowns.
    MockTime.advance(120000)
end

-- Build a fake running action and install it as the current queue head.
-- kind="mod" tags it through the real ownership registry (exactly like the
-- production queue sites do); kind="foreign" leaves it untagged, i.e. a
-- player-initiated or vanilla-queued action.
local function installRunningAction(actionType, kind)
    local action = { Type = actionType }
    if kind == "mod" then
        AutoPilot_Utils.tagModAction(action)
    end
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return true end
    ISTimedActionQueue.getTimedActionQueue = function(_p)
        return { queue = { action } }
    end
    return action
end

-- Count busy-cycle telemetry entries with the given reason.
local function countBusyReason(reason)
    local n = 0
    for _, entry in ipairs(_telemLog) do
        if entry.action == "busy" and entry.reason == reason then
            n = n + 1
        end
    end
    return n
end

-- Simulate enough OnTick calls to pass the TICK_INTERVAL gate.
-- TICK_INTERVAL is defined in AutoPilot_Constants.
-- The real clock advances per fired tick: onTick dedupes duplicate handler
-- registrations by frame timestamp, so a frozen clock would skip every tick
-- after the first.
local function tickN(n)
    for _ = 1, (n or 1) * AutoPilot_Constants.TICK_INTERVAL do
        MockRealTime.advance(16)   -- ~one 60fps frame per engine tick
        fireEvent("OnTick")
    end
end

-- Arm/disarm helpers (V3.2: the mod starts OFF by design — the player reaches
-- a stable state first, then presses F10 to start the grind).
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

-- ── Test cases ────────────────────────────────────────────────────────────────
print("=== AutoPilot_Main Logic Tests ===")

-- 1. Default mode is "off" — arming with F10 starts evaluation.
print("\n-- Test 1: Default mode is OFF; F10 arms the mod")
do
    reset()
    disarm()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    tickN(1)
    assert_eq("no evaluation before arming (default OFF)", #_telemLog, 0)
    assert_false("isActive() false by default", AutoPilot.isActive())

    fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    assert_true("isActive() true after F10", AutoPilot.isActive())
    tickN(1)
    assert_true("logTick called once armed", #_telemLog > 0)
end

-- 2. F10 toggles off then back on.
print("\n-- Test 2: F10 key toggles mode off and back on")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    -- Tick once to register player in init state.
    tickN(1)

    -- Toggle off.
    fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    _telemLog = {}
    tickN(1)
    local afterOff = #_telemLog
    assert_eq("logTick not called when mode is off", afterOff, 0)

    -- Toggle back on.
    fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    _telemLog = {}
    tickN(1)
    assert_true("logTick called again after toggle-on", #_telemLog > 0)
end

-- 3. Death is logged exactly once.
print("\n-- Test 3: Death event logged exactly once")
do
    reset()
    local player = makePlayer(0, { dead = true })
    _mockPlayers[0] = player
    arm()
    tickN(3)
    local deaths = _telemDead[0] or 0
    assert_eq("onDeath called exactly once for repeated dead-ticks", deaths, 1)
end

-- 4. Sleep-skip: when player is asleep, logTick is called with "sleep".
print("\n-- Test 4: Asleep player causes sleep tick (no action queued)")
do
    reset()
    local player = makePlayer(0, { asleep = true })
    _mockPlayers[0] = player
    arm()
    tickN(1)
    local sleepLog = false
    for _, entry in ipairs(_telemLog) do
        if entry.action == "sleep" then sleepLog = true end
    end
    assert_true("logTick called with 'sleep' when player is asleep", sleepLog)
end

-- 5. Cooldown: after an action, subsequent ticks are in cooldown.
print("\n-- Test 5: Cooldown cycles after an action")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    AutoPilot_Needs._returnVal = true  -- Needs.check() returns true → action taken
    tickN(1)
    -- Reset returnVal so the next tick won't queue another action.
    AutoPilot_Needs._returnVal = false
    -- Next tick should be cooldown.
    _telemLog = {}
    -- Tick once more — should be "cooldown".  (Advance the frame clock per
    -- tick or the duplicate-handler dedupe skips the repeats.)
    for _ = 1, AutoPilot_Constants.TICK_INTERVAL do
        MockRealTime.advance(16)
        fireEvent("OnTick")
    end
    local cooldownSeen = false
    for _, entry in ipairs(_telemLog) do
        if entry.action == "cooldown" then cooldownSeen = true end
    end
    assert_true("cooldown tick recorded after an action", cooldownSeen)
end

-- 6. shouldInterrupt clears the MOD'S OWN queued exercise (fail-safe intact).
print("\n-- Test 6: urgent need clears a MOD-QUEUED exercise (V4.5 identity check)")
do
    reset()
    -- Splitscreen was removed (V3.2): only the local player (index 0) ticks.
    -- Test 5 left a post-action cooldown on that player, so drain it first.
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    AutoPilot_Needs._returnVal = false
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)   -- burn residual cooldown
    -- Simulate the mod's own exercise running: tagged through the real
    -- ownership registry, exactly like doExercise tags before queueing.
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p)
        queueCleared = true
    end
    installRunningAction("ISFitnessAction", "mod")
    -- Make shouldInterrupt return true.
    AutoPilot_Needs.shouldInterrupt = function(_player) return true end
    tickN(1)
    assert_true("ISTimedActionQueue.clear called when shouldInterrupt is true",
        queueCleared)
    assert_true("noteModExerciseCleared consumed the pending record",
        AutoPilot_Needs._modClearNotes >= 1)
    -- Restore.
    ISTimedActionQueue.clear = origClear
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
    ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end
    _mockPlayers[0] = nil
end

-- 7. Session-end handler writes shutdown telemetry.
print("\n-- Test 7: OnMainMenuEnter fires onShutdown for active players")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(1)
    _telemShut = {}
    -- Simulate returning to main menu.
    fireEvent("OnMainMenuEnter")
    assert_true("onShutdown called when returning to main menu",
        (_telemShut[0] or 0) >= 1)
end

-- 8. OnQueueNewGame fires onShutdown.
print("\n-- Test 8: OnQueueNewGame fires onShutdown for active players")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(1)
    _telemShut = {}
    fireEvent("OnQueueNewGame")
    assert_true("onShutdown called when new game is queued",
        (_telemShut[0] or 0) >= 1)
end

-- 9. Mode toggled off → onShutdown NOT triggered until session-end event.
print("\n-- Test 9: Toggled-off player does not trigger shutdown on session-end event")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    disarm()
    _telemShut = {}
    fireEvent("OnMainMenuEnter")
    -- Player mode is "off", so onShutdown should NOT be called.
    assert_eq("onShutdown not called for toggled-off player on session end",
        _telemShut[0] or 0, 0)
end

-- ── V4.5: never touch player-initiated actions + F10 panic stop ───────────────

-- 10. A FOREIGN (untagged) exercise is never cleared by the urgent-need
--     interrupt, even while armed with an urgent need pending.
print("\n-- Test 10: urgent need does NOT clear a FOREIGN (manual) exercise")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)   -- burn residual cooldown
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end
    installRunningAction("ISFitnessAction", "foreign")
    AutoPilot_Needs.shouldInterrupt = function(_player) return true end
    _telemLog = {}
    tickN(1)
    assert_false("foreign exercise NOT cleared despite urgent need", queueCleared)
    assert_true("cycle logged busy/foreign_action instead",
        countBusyReason("foreign_action") >= 1)
    assert_true("trainer notified of the foreign exercise (backoff hook)",
        AutoPilot_Needs._foreignNotes >= 1)
    ISTimedActionQueue.clear = origClear
end

-- 11. Disarmed: the evaluation cycle never runs, so a manual exercise is
--     untouchable regardless of identity or urgent needs.
print("\n-- Test 11: disarmed cycle never touches a manual exercise")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    disarm()
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end
    installRunningAction("ISFitnessAction", "foreign")
    AutoPilot_Needs.shouldInterrupt = function(_player) return true end
    _telemLog = {}
    tickN(2)
    assert_false("no queue clear while disarmed", queueCleared)
    assert_eq("no evaluation telemetry while disarmed", #_telemLog, 0)
    ISTimedActionQueue.clear = origClear
end

-- 12. The queue-thrash guard ignores FOREIGN actions entirely: a
--     long-running manual action never accumulates a busy streak.
print("\n-- Test 12: thrash guard never clears a FOREIGN action")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end
    installRunningAction("ISReadABook", "foreign")
    _telemLog = {}
    tickN(AutoPilot_Constants.MAX_ACTION_STREAK + 3)
    assert_false("foreign action never thrash-cleared", queueCleared)
    assert_true("every busy cycle logged as foreign_action",
        countBusyReason("foreign_action")
            >= AutoPilot_Constants.MAX_ACTION_STREAK + 3)
    assert_eq("no foreign-exercise note for a non-exercise action",
        AutoPilot_Needs._foreignNotes, 0)
    ISTimedActionQueue.clear = origClear
end

-- 13. The thrash guard STILL clears the mod's own stuck action (the
--     original protection is intact for mod-queued work).
print("\n-- Test 13: thrash guard still clears a stuck MOD-QUEUED action")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end
    installRunningAction("ISWalkToTimedAction", "mod")
    tickN(AutoPilot_Constants.MAX_ACTION_STREAK + 1)
    assert_true("stuck mod-queued action IS thrash-cleared", queueCleared)
    assert_true("thrash clear consumed the pending-set record",
        AutoPilot_Needs._modClearNotes >= 1)
    ISTimedActionQueue.clear = origClear
end

-- 14. F10 PANIC STOP while armed: a running FOREIGN exercise is cleared on
--     the keypress, and the normal toggle still disarms.
print("\n-- Test 14: F10 panic stop clears a manual exercise (armed -> off)")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end
    installRunningAction("ISFitnessAction", "foreign")
    fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    assert_true("F10 cleared the running manual exercise", queueCleared)
    assert_true("panic-stop notification sent", AutoPilot_Needs._panicNotes >= 1)
    assert_false("toggle semantics preserved: now disarmed", AutoPilot.isActive())
    ISTimedActionQueue.clear = origClear
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
    ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end
end

-- 15. F10 PANIC STOP also clears the MOD'S OWN running exercise.
print("\n-- Test 15: F10 panic stop clears a mod-queued exercise")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end
    installRunningAction("ISFitnessAction", "mod")
    fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    assert_true("F10 cleared the running mod exercise", queueCleared)
    assert_true("panic-stop notification sent", AutoPilot_Needs._panicNotes >= 1)
    assert_false("now disarmed", AutoPilot.isActive())
    ISTimedActionQueue.clear = origClear
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
    ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end
end

-- 16. F10 PANIC STOP works while DISARMED too (the escape hatch for the
--     vanilla input-capture lockup): clears the exercise AND arms, because
--     the normal toggle semantics still apply on the same keypress.
print("\n-- Test 16: F10 while disarmed clears a manual exercise and arms")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    disarm()
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end
    installRunningAction("ISFitnessAction", "foreign")
    fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    assert_true("F10 cleared the manual exercise while disarmed", queueCleared)
    assert_true("panic-stop notification sent", AutoPilot_Needs._panicNotes >= 1)
    assert_true("toggle semantics preserved: now armed", AutoPilot.isActive())
    ISTimedActionQueue.clear = origClear
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
    ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end
    disarm()
end

-- 17. F10 with no exercise running: plain toggle, no queue interference.
print("\n-- Test 17: F10 without a running exercise only toggles")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    disarm()
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end
    fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    assert_false("no clear when nothing is running", queueCleared)
    assert_eq("no panic-stop notification", AutoPilot_Needs._panicNotes, 0)
    assert_true("toggle still works", AutoPilot.isActive())
    ISTimedActionQueue.clear = origClear
    disarm()
end

-- 18. The threat response consumes the pending-set record so a combat
--     interruption of the mod's own exercise is not misread as a cancel.
print("\n-- Test 18: threat branch consumes the pending exercise record")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)
    AutoPilot_Threat.check = function(_player) return true end
    tickN(1)
    assert_true("noteModExerciseCleared called on threat response",
        AutoPilot_Needs._modClearNotes >= 1)
    AutoPilot_Threat.check = function(_player) return false end
    disarm()
end

-- ── V4.4: on-screen action/intention display ───────────────────────────────

-- 19. Armed and idle: the HUD shows the generic idle/evaluating label.
print("\n-- Test 19: V4.4 armed idle shows 'Idle, evaluating' on the HUD")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    -- Drain any residual cooldown/label left by a prior test (shared module
    -- state), same pattern as every other test that needs a clean idle
    -- read; the cooldown branch intentionally does not relabel, so the
    -- PREVIOUS action's label (and its halo text) persists through the
    -- cooldown tail, which is accurate, not stale.
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)
    tickN(1)
    assert_eq("HUD shows idle intention when armed and idle",
        lastActionLine(), "Action: Idle, evaluating")
    disarm()
end

-- 20. Armed with a mod-queued exercise decision: the HUD shows the enriched
--     trainer status (same data the F11 panel already reads), capitalized.
print("\n-- Test 20: V4.4 armed training shows the enriched exercise status")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)  -- drain residual cooldown
    AutoPilot_Needs._returnVal = true
    AutoPilot_Telemetry._pendingLabel = "exercise"
    AutoPilot_Needs.getExerciseStatus = function()
        return { outcome = "training: barbellcurl", setsToday = 1, cap = 20 }
    end
    tickN(1)
    assert_eq("HUD shows the enriched training outcome, capitalized",
        lastActionLine(), "Action: Training: barbellcurl")
    disarm()
end

-- 21. Disarmed: the HUD shows the honest "no monitoring" state, matching
--     the fact that _tickForPlayer returns immediately when mode is "off"
--     (verified above: no survival check of any kind runs while disarmed).
print("\n-- Test 21: V4.4 disarmed shows the accurate no-monitoring label")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    disarm()
    tickN(1)
    assert_eq("HUD shows disarmed/no-monitoring state",
        lastActionLine(), "Action: Disarmed (no monitoring)")
end

-- 22. getActionIntention is a pure read: repeated calls are stable and
--     never mutate mode, telemetry, or the action queue.
print("\n-- Test 22: V4.4 getActionIntention never mutates state (pure read)")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(1)
    local modeBefore  = AutoPilot.isActive()
    local telemBefore = #_telemLog
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p) queueCleared = true end

    local a = AutoPilot.getActionIntention(player)
    local b = AutoPilot.getActionIntention(player)
    local c = AutoPilot.getActionIntention(player)

    assert_eq("repeated reads return the identical label (1st/2nd)", a, b)
    assert_eq("repeated reads return the identical label (2nd/3rd)", b, c)
    assert_eq("mode unchanged after reading the intention",
        AutoPilot.isActive(), modeBefore)
    assert_eq("telemetry untouched by a pure read", #_telemLog, telemBefore)
    assert_false("queue never cleared by a pure read", queueCleared)

    ISTimedActionQueue.clear = origClear
    disarm()
end

-- 23. HUD_SHOW_ACTION = 0 hides the action line entirely (toggle off).
print("\n-- Test 23: V4.4 HUD_SHOW_ACTION=0 hides the action line")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(1)
    assert_true("sanity: action line present with the toggle on (default)",
        lastActionLine() ~= nil)

    AutoPilot_Constants.HUD_SHOW_ACTION = 0
    _haloLines = {}
    tickN(1)
    assert_eq("no Action: line emitted when the toggle is off",
        lastActionLine(), nil)
    assert_true("status line is unaffected by the toggle",
        #_haloLines > 0)

    AutoPilot_Constants.HUD_SHOW_ACTION = 1
    disarm()
end

-- 24 (V5.6). The combat tick logs the engage reason reported by Threat, not
-- the single undifferentiated "threat" label.  Across the reported run log all
-- 1889 combat ticks read reason=threat, which is exactly why a fight could not
-- be told apart from a flee (or from a decision that queued nothing at all).
print("\n-- Test 24: V5.6 combat telemetry carries the engage reason")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    arm()
    tickN(AutoPilot_Constants.ACTION_COOLDOWN_CYCLES)

    AutoPilot_Threat.check = function(_player) return true end
    AutoPilot_Threat.getEngageReason = function() return "flee_horde" end
    _telemLog = {}
    tickN(1)
    local last = _telemLog[#_telemLog]
    assert_eq("combat action still logged as 'combat'", last and last.action, "combat")
    assert_eq("the engage reason reaches telemetry", last and last.reason, "flee_horde")

    AutoPilot_Threat.getEngageReason = function() return "fight_encircled" end
    _telemLog = {}
    tickN(1)
    last = _telemLog[#_telemLog]
    assert_eq("a different branch logs a different reason",
        last and last.reason, "fight_encircled")

    -- Degraded surface: an older/absent accessor falls back to "threat"
    -- instead of erroring out of the survival cycle.
    AutoPilot_Threat.getEngageReason = nil
    _telemLog = {}
    tickN(1)
    last = _telemLog[#_telemLog]
    assert_eq("missing accessor falls back to the legacy reason",
        last and last.reason, "threat")

    AutoPilot_Threat.check = function(_player) return false end
    disarm()
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
