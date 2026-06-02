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

AutoPilot_Utils = {
    EPSILON = 0.001,
    safeStat = function(player, charStat)
        local ok, val = pcall(function() return player:getStats():get(charStat) end)
        if ok and type(val) == "number" then return val end
        return 0
    end,
    iterateNearbySquares = function(...) end,
    findNearestSquare    = function(...) return nil end,
}

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

AutoPilot_Barricade = {
    doBarricade = function(_player) return 0 end,
    isDone      = function(_player) return true end,
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

-- Extend the ISTimedActionQueue mock with methods required by AutoPilot_Main.
ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end

-- Override Needs to be controllable per test.
AutoPilot_Needs = {
    _returnVal = false,
    check = function(_player, _skip)
        return AutoPilot_Needs._returnVal
    end,
    shouldInterrupt = function(_player) return false end,
    trySleep        = function(_player) return false end,
    tryGoOutside    = function(_player) return false end,
    preferredExerciseType = function(_player) return "either" end,
}

-- getPlayer mock — returns a configurable player table.
local _mockPlayers = {}

function getPlayer(idx)
    idx = idx or 0
    return _mockPlayers[idx]
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
    AutoPilot_Needs.shouldInterrupt = function(_player) return false end
    AutoPilot_Threat.check = function(_player) return false end
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
    ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end
    -- Advance mock clock to expire any active cooldowns.
    MockTime.advance(120000)
end

-- Simulate enough OnTick calls to pass the TICK_INTERVAL gate.
-- TICK_INTERVAL is defined in AutoPilot_Constants.
local function tickN(n)
    for _ = 1, (n or 1) * AutoPilot_Constants.TICK_INTERVAL do
        fireEvent("OnTick")
    end
end

-- ── Test cases ────────────────────────────────────────────────────────────────
print("=== AutoPilot_Main Logic Tests ===")

-- 1. Default mode is "autopilot" — no toggle needed.
print("\n-- Test 1: Default player mode is 'autopilot'")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    -- The first tick should log something (not "off").
    tickN(1)
    -- If autopilot mode is active, logTick should have been called.
    assert_true("logTick called on first tick (autopilot is on by default)",
        #_telemLog > 0)
end

-- 2. F10 toggles player 0 off then back on.
print("\n-- Test 2: F10 key toggles player 0 mode off and back on")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    -- Tick once to register player in init state.
    tickN(1)
    local before = #_telemLog

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
    AutoPilot_Needs._returnVal = true  -- Needs.check() returns true → action taken
    tickN(1)
    -- Reset returnVal so the next tick won't queue another action.
    AutoPilot_Needs._returnVal = false
    -- Next tick should be cooldown.
    _telemLog = {}
    -- Tick once more — should be "cooldown".
    for _ = 1, AutoPilot_Constants.TICK_INTERVAL do
        fireEvent("OnTick")
    end
    local cooldownSeen = false
    for _, entry in ipairs(_telemLog) do
        if entry.action == "cooldown" then cooldownSeen = true end
    end
    assert_true("cooldown tick recorded after an action", cooldownSeen)
end

-- 6. shouldInterrupt clears queue and re-evaluates.
print("\n-- Test 6: shouldInterrupt causes queue clear and re-evaluation")
do
    reset()
    -- Use pnum=1 to avoid cooldown state left by Test 5 (which used pnum=0).
    local player = makePlayer(1)
    _mockPlayers[1] = player
    -- Simulate an exercise action already running: isPlayerDoingAction returns true,
    -- and the current action is ISFitnessAction.
    local queueCleared = false
    local origClear = ISTimedActionQueue.clear
    ISTimedActionQueue.clear = function(_p)
        queueCleared = true
    end
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return true end
    ISTimedActionQueue.getTimedActionQueue = function(_p)
        return {
            queue = {
                { Type = "ISFitnessAction" },
            }
        }
    end
    -- Make shouldInterrupt return true.
    AutoPilot_Needs.shouldInterrupt = function(_player) return true end
    AutoPilot_Needs._returnVal = false
    tickN(1)
    assert_true("ISTimedActionQueue.clear called when shouldInterrupt is true",
        queueCleared)
    -- Restore.
    ISTimedActionQueue.clear = origClear
    ISTimedActionQueue.isPlayerDoingAction = function(_p) return false end
    ISTimedActionQueue.getTimedActionQueue = function(_p) return nil end
    _mockPlayers[1] = nil
end

-- 7. Session-end handler writes shutdown telemetry.
print("\n-- Test 7: OnMainMenuEnter fires onShutdown for active players")
do
    reset()
    local player = makePlayer(0)
    _mockPlayers[0] = player
    -- Ensure player is in autopilot mode (default).
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
    -- Toggle player 0 off.
    fireEvent("OnKeyPressed", Keyboard.KEY_F10)
    _telemShut = {}
    fireEvent("OnMainMenuEnter")
    -- Player mode is "off", so onShutdown should NOT be called.
    assert_eq("onShutdown not called for toggled-off player on session end",
        _telemShut[0] or 0, 0)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
