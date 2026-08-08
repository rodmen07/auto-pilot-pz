-- tests/test_flee_stall.lua
-- The escape walk that moved nobody: an escape is only over when the character
-- actually went somewhere.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- `FLEE_COOLDOWN_CYCLES` is a POST-ARRIVAL buffer: four evaluation cycles of
-- deliberate silence after an escape walk finishes, so the mod does not
-- instantly re-flee the moment it arrives.  Nothing ever checked the assumption
-- underneath it -- that the walk it follows MOVED the character.  So an escape
-- walk that ended without the character taking a step bought the same four
-- cycles of silence, and the mod stood still beside a zombie for four cycles out
-- of every five, re-aiming each time at the destination that had just failed.
--
-- Live evidence, `auto_pilot_run.log` session 4, run_tick 3523-3555 (33 unbroken
-- `action=combat` ticks at `speed=1`, `zombies=1` throughout):
--
--     3523 flee_default | 3524-3527 evade_cooldown x4
--     3528 flee_default | 3529-3532 evade_cooldown x4
--     3533 flee_default | 3534-3537 evade_cooldown x4
--     3538 flee_default | 3539-3542 evade_cooldown x4
--     3543 flee_default | 3544-3547 evade_cooldown x4
--     3548 flee_default | 3549-3552 evade_cooldown x4
--     3553 flee_default | 3554-3555 evade_cooldown x2  (the zombie left at 3556)
--
-- Seven flee decisions on a stride of exactly FLEE_COOLDOWN_CYCLES + 1 = 5, and
-- ZERO `evade_running` ticks anywhere -- meaning no queued walk ever survived to
-- the next evaluation, 0.75 s later.  Endurance moved 98 -> 94 across the whole
-- episode; the two HEALTHY pursuits in the same session moved it 100 -> 76.  The
-- character was not running.  It was standing there.
--
-- This is NOT the fast-forward defect that `tests/test_walk_speed_gate.lua`
-- covers.  That one is the engine refusing to RUN a queued walk above game-speed
-- index 2, and it cannot explain this episode: `speed=1` passes that gate.  The
-- engine has several ways to end a queued walk without moving anyone (an
-- unreachable destination fails pathfinding on the first update and force-stops;
-- a destination that resolves adjacent completes at once) and the mod cannot see
-- WHICH -- but it can always see that it did not move, which is the only fact the
-- response depends on.
--
-- The fix has two halves and this suite pins both:
--   1. A stalled escape pays NO cooldown, so the retry comes on the next cycle
--      instead of the fifth (the observed stride goes 5 -> 2).
--   2. The retry aims somewhere ELSE.  `FLEE_DISTANCE_FRACTIONS` only ever
--      SHORTENS the same bearing, so when the bearing itself is the thing that
--      does not work every rung fails identically; the escape vector is now
--      rotated by a ladder indexed on the consecutive-stall count.  The ladder
--      stops at +/-90 degrees because this mod must never walk a character
--      toward a zombie -- there is no B42 AI-attack API.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_flee_stall.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- ── Stub dependency modules (mirrors tests/test_walk_speed_gate.lua) ──────────
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
    hasCriticalWound = function(_player) return false end,
    getWoundSnapshot = function(_player)
        return { bleeding = 0, scratched = 0, deep_wounded = 0,
                 bitten = false, burnt = 0 }
    end,
    check = function(_player, _isCritical) return false end,
}

AutoPilot_Inventory = {
    getBestWeapon      = function(_player) return nil end,
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

-- ── World ─────────────────────────────────────────────────────────────────────
local PROGRESS_MIN    = AutoPilot_Constants.FLEE_PROGRESS_MIN
local COOLDOWN_CYCLES = AutoPilot_Constants.FLEE_COOLDOWN_CYCLES

-- The zombie sits due EAST of the origin, deliberately.  An axis-aligned threat
-- makes the safety property below ("the escape destination is never on the
-- zombie's side of the character") a plain comparison on one coordinate instead
-- of an angle with a tolerance, so a ladder rung that ever rotated past a right
-- angle fails it outright rather than by a few degrees.
local ZOMBIE_X, ZOMBIE_Y = 4, 0

local function makeSquare(x, y, z)
    return {
        getX      = function(_self) return x end,
        getY      = function(_self) return y end,
        getZ      = function(_self) return z or 0 end,
        isFree    = function(_self) return true end,
        isOutside = function(_self) return true end,
    }
end

local function makeZombie(x, y)
    local sq = makeSquare(x, y, 0)
    return {
        getX      = function(_self) return x end,
        getY      = function(_self) return y end,
        getZ      = function(_self) return 0 end,
        getSquare = function(_self) return sq end,
        isDead    = function(_self) return false end,
    }
end

-- A healthy, armed-enough character with a zombie chasing it, so the V3.2
-- engagement gate opens on the engine counters rather than on proximity -- the
-- cases below MOVE the character, and a proximity-only gate would silently
-- disengage half way through a lifecycle and prove nothing.
local function makePlayer()
    local p = MockPlayer.new({ playerNum = 0, numChasing = 1, stats = {} })
    p._x, p._y = 0, 0
    p.getX = function(self) return self._x end
    p.getY = function(self) return self._y end
    p.getZ = function(_self) return 0 end
    p.getPrimaryHandItem = function(_self) return nil end
    p.getCurrentSquare = function(self)
        return makeSquare(self:getX(), self:getY(), 0)
    end
    p.isAsleep = function(_self) return false end
    p.isDead   = function(_self) return false end
    return p
end

-- A queue model faithful enough to run the lifecycle: isPlayerDoingAction
-- reports whether anything is left, and clear() really empties it.
local function installQueueModel()
    ISTimedActionQueue_calls = {}
    ISTimedActionQueue.clear = function(_p) ISTimedActionQueue_calls = {} end
    ISTimedActionQueue.isPlayerDoingAction = function(_p)
        return #ISTimedActionQueue_calls > 0
    end
    ISTimedActionQueue.getTimedActionQueue = function(_p)
        return { queue = { ISTimedActionQueue_calls[1] } }
    end
end

-- Every escape destination the mod asks for, in order, as {x, y} pairs.
local destinations = {}

local function installWorld()
    installQueueModel()
    destinations = {}
    AutoPilot_Threat.resetFleeState()
    AutoPilot_Threat._engageReason = "threat"
    AutoPilot_Threat.getNearbyZombies = function(_p)
        return { makeZombie(ZOMBIE_X, ZOMBIE_Y) }
    end
    -- Every requested square is walkable, so a stall in these cases is never
    -- "nowhere to go" (that is the separate, self-labelled flee_blocked case).
    AutoPilot_Utils.findNearestSquare = function(cx, cy, cz, _r, _pred)
        table.insert(destinations, { x = cx, y = cy })
        return makeSquare(cx, cy, cz)
    end
    MockGameSpeed.setIndex(1)
end

local function reason()
    return AutoPilot_Threat.getEngageReason()
end

-- The engine ends the queued walk WITHOUT the character having moved: the queue
-- drains, the position does not change.  This is the whole defect in one line.
local function walkEndedInPlace()
    ISTimedActionQueue_calls = {}
end

-- The queued walk ran and arrived: the queue drains and the character is
-- `tiles` tiles away, straight down the escape bearing (west, away from the
-- zombie at +X).
local function walkArrived(player, tiles)
    ISTimedActionQueue_calls = {}
    player._x = player._x - tiles
end

local function queued()
    return #ISTimedActionQueue_calls
end

print("=== AutoPilot flee-stall tests ===")

-- ── 1: the progress threshold is a real, usable number ───────────────────────
print("\n-- Flee stall 1: FLEE_PROGRESS_MIN separates 'did not move' from 'escaped'")
do
    assert_true("FLEE_PROGRESS_MIN is a positive number",
        type(PROGRESS_MIN) == "number" and PROGRESS_MIN > 0)
    -- The shortest rung of FLEE_DISTANCE_FRACTIONS is 0.3, so the smallest
    -- escape the mod ever ASKS for is 0.3 * FLEE_DISTANCE tiles.  A threshold at
    -- or above that would classify the mod's own shortest legitimate escape as a
    -- stall, which is the crying-wolf direction of this fix.
    local shortestEscape = AutoPilot_Constants.FLEE_DISTANCE * 0.3
    assert_true("the threshold is below the shortest escape the mod ever asks for",
        PROGRESS_MIN < shortestEscape)
end

-- ── 2 (ON): a walk that moved nobody pays no cooldown and says so ────────────
print("\n-- Flee stall 2 (ON): an escape that moved nobody is labelled and retried at once")
do
    installWorld()
    local player = makePlayer()

    assert_true("cycle 1: check() acts", AutoPilot_Threat.check(player))
    assert_eq("cycle 1: one escape walk queued", queued(), 1)
    assert_eq("cycle 1: a fresh decision is a flee", reason(), "flee_default")
    assert_eq("cycle 1: the post-arrival buffer is armed",
        AutoPilot_Threat._fleeCooldown, COOLDOWN_CYCLES)

    walkEndedInPlace()

    assert_true("cycle 2: check() acts", AutoPilot_Threat.check(player))
    assert_eq("cycle 2: the stall is LABELLED, not hidden inside evade_cooldown",
        reason(), "evade_stalled")
    assert_eq("cycle 2: the unearned post-arrival buffer is dropped",
        AutoPilot_Threat._fleeCooldown, 0)
    assert_eq("cycle 2: the stall is counted", AutoPilot_Threat._fleeStalls, 1)
    assert_eq("cycle 2: the stall cycle itself queues nothing", queued(), 0)

    assert_true("cycle 3: check() acts", AutoPilot_Threat.check(player))
    assert_eq("cycle 3: the retry comes on the very next cycle", queued(), 1)
    assert_eq("cycle 3: and it is a fresh flee decision", reason(), "flee_default")
end

-- ── 3 (OFF): the identical lifecycle, with the character actually moved ──────
-- This is the behaviour-difference half.  Same code path, same queue drain, one
-- difference: the character is somewhere else.  Everything the ON case asserts
-- must invert, or the fix is firing on healthy escapes.
print("\n-- Flee stall 3 (OFF): an escape that WORKED still pays its cooldown")
do
    installWorld()
    local player = makePlayer()

    assert_true("cycle 1: check() acts", AutoPilot_Threat.check(player))
    assert_eq("cycle 1: one escape walk queued", queued(), 1)

    walkArrived(player, PROGRESS_MIN + 1)

    assert_true("cycle 2: check() acts", AutoPilot_Threat.check(player))
    assert_eq("cycle 2: a real escape reports evade_cooldown, not evade_stalled",
        reason(), "evade_cooldown")
    assert_eq("cycle 2: the earned buffer is paid, one cycle spent",
        AutoPilot_Threat._fleeCooldown, COOLDOWN_CYCLES - 1)
    assert_eq("cycle 2: no stall is recorded", AutoPilot_Threat._fleeStalls, 0)
    assert_eq("cycle 2: nothing is queued during the buffer", queued(), 0)

    -- The remaining buffer cycles stay silent: the fix must not shorten a
    -- cooldown that is doing its job.
    for i = 1, COOLDOWN_CYCLES - 1 do
        AutoPilot_Threat.check(player)
        assert_eq(("cycle %d: still in the earned buffer"):format(i + 2),
            reason(), "evade_cooldown")
        assert_eq(("cycle %d: still queues nothing"):format(i + 2), queued(), 0)
    end
end

-- ── 4: the measured stride, which is the whole user-visible difference ───────
print("\n-- Flee stall 4: the retry stride collapses from 5 cycles to 2")
do
    installWorld()
    local player = makePlayer()

    -- A world where every escape walk ends in place, forever: exactly the live
    -- session-4 episode.  Count the cycles between successive queued walks.
    local walkCycles = {}
    for cycle = 1, 12 do
        AutoPilot_Threat.check(player)
        if queued() > 0 then
            table.insert(walkCycles, cycle)
            walkEndedInPlace()
        end
    end

    assert_true("the mod keeps trying to escape (it never gives up)",
        #walkCycles >= 5)

    local stride = walkCycles[2] - walkCycles[1]
    local uniform = true
    for i = 2, #walkCycles do
        if walkCycles[i] - walkCycles[i - 1] ~= stride then uniform = false end
    end
    assert_true("the stride is uniform across every retry", uniform)
    assert_eq("one stall cycle plus one decision cycle: stride 2", stride, 2)

    -- The number this replaces, stated rather than implied: the pre-fix stride
    -- was one decision plus a full unearned buffer, and it is exactly the stride
    -- measured in the live log (flee_default at run_tick 3523, 3528, 3533, 3538,
    -- 3543, 3548, 3553).
    assert_eq("the pre-fix stride was decision + full buffer",
        COOLDOWN_CYCLES + 1, 5)
    assert_true("so the character now spends far less of an encounter standing still",
        stride < COOLDOWN_CYCLES + 1)
end

-- ── 5: the retry aims somewhere else, not at the destination that just failed ─
print("\n-- Flee stall 5: a retry after a stall changes BEARING, not just distance")
do
    installWorld()
    local player = makePlayer()

    AutoPilot_Threat.check(player)
    local first = destinations[1]
    walkEndedInPlace()
    AutoPilot_Threat.check(player)          -- the stall cycle
    AutoPilot_Threat.check(player)          -- the retry
    local retry = destinations[#destinations]

    assert_true("the first attempt aims straight away from the zombie",
        first ~= nil and first.x < 0 and math.abs(first.y) <= 1)
    assert_true("the retry does not aim at the destination that just failed",
        retry.x ~= first.x or retry.y ~= first.y)
    -- The distance ladder alone could only ever have SHORTENED the same bearing,
    -- which is what made one unreachable destination an unbounded loop.  Proving
    -- the bearing moved means proving the Y component changed: a pure shortening
    -- keeps y at 0 for a due-west escape.
    assert_true("the retry's bearing rotated (a pure shortening cannot do this)",
        math.abs(retry.y) > math.abs(first.y) + 1)
end

-- ── 6: the ladder never rotates the escape toward the threat ─────────────────
-- The safety property.  The mod cannot fight (no B42 AI-attack API), so an
-- escape vector rotated past a right angle would start CLOSING on the zombie the
-- vector was computed to open distance from.  The ladder is clamped at +/-90 and
-- keeps retrying there rather than escalating; this drives every stall count
-- well past the end of the ladder to prove the clamp holds.
print("\n-- Flee stall 6: no stall count ever aims the escape at the zombie")
do
    for stalls = 0, 8 do
        installWorld()
        local player = makePlayer()
        -- Set directly: the ladder rung is chosen by the stall count, and
        -- driving 8 real stalls per case would test the counter (case 2's job)
        -- rather than the clamp.
        AutoPilot_Threat._fleeStalls = stalls

        AutoPilot_Threat.check(player)
        local dest = destinations[1]
        assert_true(("stalls=%d: an escape destination was chosen"):format(stalls),
            dest ~= nil)
        -- The zombie is due east at +X, the character at x=0.  Any destination
        -- with x > 0 is on the zombie's side, i.e. the escape closed distance.
        assert_true(
            ("stalls=%d: the escape never crosses to the zombie's side"):format(stalls),
            dest.x <= player._x)
    end
end

-- ── 7: one escape that works clears the ladder ───────────────────────────────
print("\n-- Flee stall 7: a successful escape resets the stall counter")
do
    installWorld()
    local player = makePlayer()

    AutoPilot_Threat.check(player)
    walkEndedInPlace()
    AutoPilot_Threat.check(player)
    assert_eq("one stall recorded", AutoPilot_Threat._fleeStalls, 1)

    AutoPilot_Threat.check(player)                 -- rotated retry, queued
    walkArrived(player, PROGRESS_MIN + 1)          -- this one works
    AutoPilot_Threat.check(player)

    assert_eq("the escape that worked reports evade_cooldown",
        reason(), "evade_cooldown")
    assert_eq("the stall counter is cleared, so the ladder restarts straight away",
        AutoPilot_Threat._fleeStalls, 0)
end

-- ── 8: fail-open -- an unreadable position is never reported as a stall ──────
-- Reporting a stall that did not happen would delete a buffer that is doing its
-- job, so both unreadable directions (no recorded origin, a position that
-- raises) must fall back to the pre-fix behaviour.
print("\n-- Flee stall 8: an unreadable position is treated as progress, never as a stall")
do
    installWorld()
    local player = makePlayer()

    AutoPilot_Threat.check(player)
    assert_eq("cycle 1: one escape walk queued", queued(), 1)

    ISTimedActionQueue_calls = {}
    player.getX = function(_self) error("position unavailable") end

    AutoPilot_Threat.check(player)
    assert_eq("an unreadable position does not manufacture a stall",
        reason(), "evade_cooldown")
    assert_eq("and the buffer is left alone", AutoPilot_Threat._fleeStalls, 0)
end

-- ── 9: the reset seam clears every field of the state machine ───────────────
-- Five resets used to spell this field list out by hand (three in the module,
-- two in the suites).  A reset that misses a field does not fail -- it leaks
-- into the next case.  This pins the seam the suites now depend on.
print("\n-- Flee stall 9: resetFleeState clears the whole flee state machine")
do
    installWorld()
    local player = makePlayer()

    AutoPilot_Threat.check(player)
    walkEndedInPlace()
    AutoPilot_Threat.check(player)
    assert_true("state is genuinely dirty before the reset",
        AutoPilot_Threat._fleeStalls > 0)

    AutoPilot_Threat.check(player)          -- re-queue so _engageActive is set
    AutoPilot_Threat.resetFleeState()

    assert_false("_engageActive cleared", AutoPilot_Threat._engageActive)
    assert_false("_fleeActive cleared",   AutoPilot_Threat._fleeActive)
    assert_eq("_fleeCooldown cleared",     AutoPilot_Threat._fleeCooldown, 0)
    assert_eq("_fleeStalls cleared",       AutoPilot_Threat._fleeStalls, 0)
    assert_eq("_fleeOriginX cleared",      AutoPilot_Threat._fleeOriginX, nil)
    assert_eq("_fleeOriginY cleared",      AutoPilot_Threat._fleeOriginY, nil)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(string.format("\n=== Results: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
