-- tests/test_walk_speed_gate.lua
-- Fast-forward walk gate: a queued escape walk must be RUNNABLE at the current
-- game speed, not merely queued.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- The engine refuses to run a queued walk above game-speed index 2.  Verified
-- live in the 42.19 install, media/lua/client/TimedActions/WalkToTimedAction.lua
-- lines 5-8, in full:
--
--     function ISWalkToTimedAction:isValid()
--         if self.character:getVehicle() then return false end
--         return getGameSpeed() <= 2;
--     end
--
-- (the identical `return getGameSpeed() <= 2;` is WalkToTimedActionF.lua:7).
-- getGameSpeed() is the speed INDEX -- 0 paused, 1 normal, 2/3/4 the three
-- fast-forward steps -- and is a DIFFERENT number from
-- getGameTime():getMultiplier(), the time multiplier the run log's `speed`
-- field carries as 1 / 5 / 20 / 40.  Reading the multiplier tells you nothing
-- about this gate, which is why an FF investigation that only looked at the
-- multiplier could not see it.
--
-- The mod queued flee walks with no awareness of that gate, so at index 3 or 4
-- the action queue discarded every escape walk on the tick it started it.  The
-- mod then saw the queue empty on the next evaluation, waited out
-- FLEE_COOLDOWN_CYCLES, re-queued, and repeated forever.  That is exactly the
-- shape recorded live in auto_pilot_run.log session 4, run_tick 6101-6317: 217
-- unbroken combat ticks, 44 flee decisions, 173 evade_cooldown and ZERO
-- evade_running, all at speed=11-21 (multiplier ramping toward x20, i.e. index
-- 3) -- 41 game-minutes of a character standing still while a zombie followed.
--
-- Fleeing is the one thing this mod must be able to do, so the flee path now
-- lowers the speed to WALK_MAX_GAME_SPEED before it queues.  Index 2 is still
-- fast-forward (x5), so an unattended run keeps most of its speed-up.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_walk_speed_gate.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Stub dependency modules (mirrors tests/test_combat_policy.lua) ────────────
ISEquipWeaponAction = {
    new = function(_, player, weapon, _time, _primary)
        return { type = "equip_weapon", weapon = weapon }
    end,
}

dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.iterateNearbySquares = function(...) end

dofile("42/media/lua/client/AutoPilot_Map.lua")
dofile("42/media/lua/client/AutoPilot_Home.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")

AutoPilot_Medical = {
    hasCriticalWound = function(player) return player._bleeding or false end,
    getWoundSnapshot = function(_player)
        return { bleeding = 0, scratched = 0, deep_wounded = 0,
                 bitten = false, burnt = 0 }
    end,
    check = function(_player, _isCritical) return false end,
}

AutoPilot_Inventory = {
    _bestWeapon = nil,
    getBestWeapon      = function(_player) return AutoPilot_Inventory._bestWeapon end,
    checkAndSwapWeapon = function(_player) end,
}

dofile("42/media/lua/client/AutoPilot_Threat.lua")

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
local MAX_WALK_SPEED = AutoPilot_Constants.WALK_MAX_GAME_SPEED

local function makeSquare(x, y, z)
    return {
        getX      = function(self) return x end,
        getY      = function(self) return y end,
        getZ      = function(self) return z or 0 end,
        isFree    = function(self) return true end,
        isOutside = function(self) return true end,
    }
end

local function makeZombie(x, y)
    local sq = makeSquare(x, y, 0)
    return {
        getX      = function(self) return x end,
        getY      = function(self) return y end,
        getZ      = function(self) return 0 end,
        getSquare = function(self) return sq end,
        isDead    = function(self) return false end,
    }
end

local function makePlayer()
    local p = MockPlayer.new({ playerNum = 0, stats = {}, moodles = {} })
    p._bleeding = false
    p.getCurrentSquare = function(self)
        return makeSquare(self:getX(), self:getY(), self:getZ())
    end
    p.isAsleep = function(self) return false end
    p.isDead   = function(self) return false end
    return p
end

-- Reset the flee state machine so each case starts from a fresh decision tick
-- (otherwise _fleeCooldown from a previous case short-circuits check()).
local function resetThreat()
    AutoPilot_Threat._engageActive = false
    AutoPilot_Threat._fleeActive   = false
    AutoPilot_Threat._fleeCooldown = 0
    ISTimedActionQueue_calls = {}
end

-- Drive one full threat evaluation with a lone zombie 4 tiles away (inside
-- CLOSE_DANGER_RADIUS, so the V3.2 engagement gate opens) and a reachable
-- escape square.  Returns the game-speed index observed at the moment the walk
-- action was CONSTRUCTED, which is the moment the engine's isValid() gate
-- decides whether the walk survives, plus whether a walk was queued at all.
local function fleeOnce()
    resetThreat()
    local p = makePlayer()
    local zombie = makeZombie(4, 4)

    local speedAtWalk, walked = nil, false
    local origWalk   = ISWalkToTimedAction.new
    local origSnap   = AutoPilot_Utils.findNearestSquare
    local origZombie = AutoPilot_Threat.getNearbyZombies

    ISWalkToTimedAction.new = function(self, player, sq)
        speedAtWalk = getGameSpeed()
        walked = true
        return origWalk(self, player, sq)
    end
    -- A reachable escape square that is NOT the player's own tile (the flee
    -- path rejects a walk to where you already stand).
    AutoPilot_Utils.findNearestSquare = function(cx, cy, cz, _r, _pred)
        return makeSquare(cx, cy, cz)
    end
    AutoPilot_Threat.getNearbyZombies = function(_) return { zombie } end

    AutoPilot_Threat.check(p)

    ISWalkToTimedAction.new           = origWalk
    AutoPilot_Utils.findNearestSquare = origSnap
    AutoPilot_Threat.getNearbyZombies = origZombie
    return speedAtWalk, walked
end

-- ── Test 1: the helper reads the speed INDEX, not the multiplier ─────────────
print("=== Walk gate 1: getGameSpeedIndex reads the engine speed index ===")
do
    MockGameSpeed.setIndex(3)
    MockGameSpeed.set(20)  -- multiplier; must not be what the helper returns
    assert_eq("index 3 is reported as 3, not as the x20 multiplier",
        AutoPilot_Utils.getGameSpeedIndex(), 3)

    MockGameSpeed.setIndex(1)
    MockGameSpeed.set(1)
    assert_eq("index 1 is reported as 1", AutoPilot_Utils.getGameSpeedIndex(), 1)
end

-- ── Test 2: the clamp is a no-op at every speed the engine already walks at ──
print("\n=== Walk gate 2: no clamp at or below the engine's walk ceiling ===")
do
    for _, idx in ipairs({ 0, 1, 2 }) do
        MockGameSpeed.setIndex(idx)
        assert_false(("index %d needs no clamp"):format(idx),
            AutoPilot_Utils.clampGameSpeedForWalk())
        assert_eq(("index %d is left exactly as it was"):format(idx),
            MockGameSpeed.getIndex(), idx)
    end
end

-- ── Test 3: a PAUSED game is never resumed by the mod ────────────────────────
-- Index 0 is below the ceiling so test 2 already covers the arithmetic, but
-- this is the case with a safety consequence rather than a numeric one: the
-- mod unpausing the game on its own initiative would take control away from a
-- player who deliberately paused it.
print("\n=== Walk gate 3: a paused game stays paused, even mid-flee ===")
do
    MockGameSpeed.setIndex(0)
    local _, walked = fleeOnce()
    assert_eq("the game is still paused after a flee decision",
        MockGameSpeed.getIndex(), 0)
    assert_true("and the flee still queued its walk", walked)
end

-- ── Test 4: the clamp lowers exactly the two speeds the engine will not walk ─
print("\n=== Walk gate 4: index 3 and 4 are lowered to the walk ceiling ===")
do
    for _, idx in ipairs({ 3, 4 }) do
        MockGameSpeed.setIndex(idx)
        assert_true(("index %d reports that it clamped"):format(idx),
            AutoPilot_Utils.clampGameSpeedForWalk())
        assert_eq(("index %d ends at the walk ceiling"):format(idx),
            MockGameSpeed.getIndex(), MAX_WALK_SPEED)
    end

    -- Idempotent: a second call has nothing left to do.
    assert_false("a second clamp at the ceiling reports no change",
        AutoPilot_Utils.clampGameSpeedForWalk())
end

-- ── Test 5: the behaviour difference the increment exists for ───────────────
-- ON: at x20 the flee walk is constructed only after the speed is inside the
-- engine's walkable range, so ISWalkToTimedAction:isValid() will pass.
-- OFF: with the clamp neutralised, the identical scenario constructs the walk
-- at index 3 -- the doomed action the engine discards, which is the live
-- 217-tick stall.
print("\n=== Walk gate 5: ON/OFF difference at the flee call site ===")
do
    MockGameSpeed.setIndex(3)
    local speedOn, walkedOn = fleeOnce()
    assert_true("ON: a walk was queued", walkedOn)
    assert_true("ON: the walk is constructed at a speed the engine will walk at",
        speedOn ~= nil and speedOn <= MAX_WALK_SPEED)

    local origClamp = AutoPilot_Utils.clampGameSpeedForWalk
    AutoPilot_Utils.clampGameSpeedForWalk = function() return false end
    MockGameSpeed.setIndex(3)
    local speedOff, walkedOff = fleeOnce()
    AutoPilot_Utils.clampGameSpeedForWalk = origClamp

    assert_true("OFF: a walk is still queued (the mod always thought it fled)",
        walkedOff)
    assert_eq("OFF: but it is constructed at index 3, which isValid() rejects",
        speedOff, 3)
end

-- ── Test 6: normal speed is never touched ────────────────────────────────────
print("\n=== Walk gate 6: a flee at normal speed changes nothing ===")
do
    MockGameSpeed.setIndex(1)
    local speedAt, walked = fleeOnce()
    assert_true("a walk was queued", walked)
    assert_eq("the walk is constructed at normal speed", speedAt, 1)
    assert_eq("and the game is left at normal speed", MockGameSpeed.getIndex(), 1)
end

-- ── Test 7: fail-open when the engine global is unavailable ─────────────────
-- Every other engine read in this mod degrades to a harmless no-op rather than
-- an error, and this one must too: a build (or a bare test harness) without
-- getGameSpeed must still get its escape walk, just without the clamp.
print("\n=== Walk gate 7: no getGameSpeed global -> fail open, still flees ===")
do
    local origGet, origSet = getGameSpeed, setGameSpeed
    getGameSpeed, setGameSpeed = nil, nil

    assert_eq("the index reads as nil rather than raising",
        AutoPilot_Utils.getGameSpeedIndex(), nil)
    assert_false("the clamp reports no change rather than raising",
        AutoPilot_Utils.clampGameSpeedForWalk())

    resetThreat()
    local p = makePlayer()
    local zombie = makeZombie(4, 4)
    local walked = false
    local origWalk   = ISWalkToTimedAction.new
    local origSnap   = AutoPilot_Utils.findNearestSquare
    local origZombie = AutoPilot_Threat.getNearbyZombies
    ISWalkToTimedAction.new = function(self, player, sq)
        walked = true
        return origWalk(self, player, sq)
    end
    AutoPilot_Utils.findNearestSquare = function(cx, cy, cz, _r, _pred)
        return makeSquare(cx, cy, cz)
    end
    AutoPilot_Threat.getNearbyZombies = function(_) return { zombie } end

    AutoPilot_Threat.check(p)

    ISWalkToTimedAction.new           = origWalk
    AutoPilot_Utils.findNearestSquare = origSnap
    AutoPilot_Threat.getNearbyZombies = origZombie
    getGameSpeed, setGameSpeed = origGet, origSet

    assert_true("the flee walk is queued anyway", walked)
    assert_eq("and the globals are restored for later suites",
        AutoPilot_Utils.getGameSpeedIndex(), MockGameSpeed.getIndex())
end

-- ── Test 8: the constant matches the engine's own threshold ─────────────────
-- The engine literal is `getGameSpeed() <= 2`, so the mod's ceiling must be 2.
-- The engine file lives in the Steam install and is not present on a CI runner,
-- so this pins the number the header quotes rather than re-reading the source:
-- if someone "tunes" WALK_MAX_GAME_SPEED, the walks silently stop running again
-- and this is the test that says so.
print("\n=== Walk gate 8: the ceiling is the engine's number, not a tunable ===")
do
    assert_eq("WALK_MAX_GAME_SPEED is the engine's isValid() threshold",
        AutoPilot_Constants.WALK_MAX_GAME_SPEED, 2)
end

-- Leave the shared mock at normal speed for any suite that follows.
MockGameSpeed.setIndex(1)

-- ── Summary ───────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
