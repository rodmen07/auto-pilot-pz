-- tests/test_threat_logic.lua
-- Behavioral tests for AutoPilot_Threat.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_threat_logic.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants ────────────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- CharacterStat.PANIC / .SICKNESS / .STRESS (Threat's NEGATIVE_STAT_CHECKS) used
-- to be added here, suite-locally.  They now live in lua_mock_pz.lua: a
-- suite-local enum key is invisible to tests/test_engine_symbols.lua, which is
-- the guard that a member production reads actually exists in B42, so any key
-- defined only in one suite is a member the guard cannot see.

-- Additional timed-action stubs required by Threat
ISEquipWeaponAction = {
    new = function(_, player, weapon, _time, _primary)
        return { type = "equip_weapon", weapon = weapon }
    end,
}
-- checkAndSwapWeapon moves a bagged weapon into the main inventory before
-- equipping; the stub is retained for modules loaded below that reference it.
ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}

-- ── Stub dependency modules ───────────────────────────────────────────────────
-- Real Utils (V4.5: provides the mod-action ownership registry that the
-- production queue sites now route through); square scans are no-op'd for
-- the suite, same behavior as the old hand-rolled stub.
dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.findNearestSquare    = function(_cx, _cy, _cz, _r, _pred) return nil end
AutoPilot_Utils.iterateNearbySquares = function(...) end

AutoPilot_Home = {
    _homeSet = false,
    isSet    = function(_player) return AutoPilot_Home._homeSet end,
    isInside = function(_sq)     return true end,
    getState = function()        return 0, 0, 0, 150 end,
    clampSq  = function(sq, _)   return sq end,
}

AutoPilot_Medical = {
    _bleeding = false,
    hasCriticalWound = function(_player)
        return AutoPilot_Medical._bleeding
    end,
}

AutoPilot_Inventory = {
    _weapon = nil,
    -- V4.9: the real selector returns (item, holdingContainer); _weaponCont
    -- stays nil unless a case models a weapon stashed in a bag.
    _weaponCont = nil,
    getBestWeapon      = function(_player)
        return AutoPilot_Inventory._weapon, AutoPilot_Inventory._weaponCont
    end,
    checkAndSwapWeapon = function(_player) return false end,
}

-- ── Load module under test ────────────────────────────────────────────────────
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

local function reset()
    ISTimedActionQueue_calls = {}
    AutoPilot_Medical._bleeding = false
    AutoPilot_Inventory._weapon = nil
    AutoPilot_Inventory._weaponCont = nil
    AutoPilot_Home._homeSet     = false
    -- V5.6 engage state is module-level; a leftover guard would make the next
    -- case return early before it ever reaches a decision.
    AutoPilot_Threat._engageActive = false
    AutoPilot_Threat._fleeActive   = false
    AutoPilot_Threat._fleeCooldown = 0
    AutoPilot_Threat._engageReason = "threat"
end

-- ── World helpers ─────────────────────────────────────────────────────────────

-- Build a zombie stub at world position (x, y).
local function makeZombie(x, y)
    return {
        isDead    = function(self) return false end,
        getX      = function(self) return x end,
        getY      = function(self) return y end,
        getZ      = function(self) return 0 end,
        getSquare = function(self) return nil end,
    }
end

-- Override getCell() to return a zombie list and a zero-size grid.
local function setZombies(zombieList)
    _G.getCell = function()
        return {
            getGridSquare = function() return nil end,
            getZombieList = function()
                return {
                    size = function(self) return #zombieList end,
                    get  = function(self, i) return zombieList[i + 1] end,
                }
            end,
            getWidth  = function() return 300 end,
            getHeight = function() return 300 end,
        }
    end
end

-- Restore the no-zombie default cell.
local function clearZombies()
    _G.getCell = function()
        return {
            getGridSquare = function() return nil end,
            getZombieList = function()
                return {
                    size = function(self) return 0 end,
                    get  = function(self, _i) return nil end,
                }
            end,
            getWidth  = function() return 300 end,
            getHeight = function() return 300 end,
        }
    end
end

clearZombies()

-- ── Test cases ────────────────────────────────────────────────────────────────
print("=== AutoPilot_Threat Logic Tests ===")

-- 1. No zombies → check returns false, no actions queued.
print("\n-- Test 1: No zombies → check returns false")
do
    reset(); clearZombies()
    local player = MockPlayer.new({})
    local result = AutoPilot_Threat.check(player)
    assert_false("check() returns false with no zombies", result)
    assert_eq("no actions queued when no zombies", #ISTimedActionQueue_calls, 0)
end

-- 2. getNearbyZombies returns zombie within DETECTION_RADIUS.
print("\n-- Test 2: getNearbyZombies detects zombie within radius")
do
    reset()
    setZombies({ makeZombie(0, 5) })  -- 5 tiles away; DETECTION_RADIUS = 10
    local player = MockPlayer.new({})
    local result = AutoPilot_Threat.getNearbyZombies(player)
    assert_eq("one zombie detected within radius", #result, 1)
end

-- 3. getNearbyZombies ignores zombie beyond DETECTION_RADIUS.
print("\n-- Test 3: getNearbyZombies ignores zombie outside radius")
do
    reset()
    setZombies({ makeZombie(0, 999) })  -- far away
    local player = MockPlayer.new({})
    local result = AutoPilot_Threat.getNearbyZombies(player)
    assert_eq("zombie beyond radius not detected", #result, 0)
end

-- 4. Bleeding + zombie nearby → check returns true (flee path entered).
print("\n-- Test 4: Bleeding + zombie → check returns true")
do
    reset()
    AutoPilot_Medical._bleeding = true
    setZombies({ makeZombie(3, 3) })
    local player = MockPlayer.new({ stats = { ENDURANCE = 0.90 } })
    local result = AutoPilot_Threat.check(player)
    assert_true("check() returns true when bleeding + zombie", result)
end

-- 5. Unarmed + multiple zombies → check returns true (flee path).
print("\n-- Test 5: Unarmed + multiple zombies → check returns true")
do
    reset()
    AutoPilot_Inventory._weapon = nil
    setZombies({ makeZombie(2, 2), makeZombie(4, 4) })
    local player = MockPlayer.new({ stats = { ENDURANCE = 0.90 } })
    local result = AutoPilot_Threat.check(player)
    assert_true("check() returns true when unarmed + outnumbered", result)
end

-- 6. Many negative moodles → check returns true (flee path).
print("\n-- Test 6: Many negative moodles → check returns true")
do
    reset()
    setZombies({ makeZombie(2, 2) })
    -- Stats deliberately above all relevant thresholds (see NEGATIVE_STAT_CHECKS).
    local player = MockPlayer.new({
        stats = {
            HUNGER  = 0.50,   -- ≥ 0.40
            THIRST  = 0.50,   -- ≥ 0.40
            FATIGUE = 0.70,   -- ≥ 0.60
            PANIC   = 50,     -- ≥ 40
        },
    })
    local result = AutoPilot_Threat.check(player)
    assert_true("check() returns true with many negative moodles", result)
end

-- 7. countNegativeMoodles counts only elevated stats.
print("\n-- Test 7: countNegativeMoodles counts elevated stats correctly")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            HUNGER  = 0.50,   -- ≥ 0.40 → counts
            THIRST  = 0.10,   -- < 0.40 → skipped
            FATIGUE = 0.80,   -- ≥ 0.60 → counts
        },
    })
    local count = AutoPilot_Threat.countNegativeMoodles(player)
    assert_eq("countNegativeMoodles returns 2", count, 2)
end

-- 8. countNegativeMoodles returns 0 when all stats are fine.
--
-- NOTE (2026-07-26 scale audit): this fixture used to be the whole reason the
-- SICKNESS/STRESS scale bug survived.  Setting a stat to 0 passes under EITHER
-- scale, so a fixture built only from healthy zeroes can never distinguish a
-- reachable entry from an unreachable one.  Test 8b below is the other half:
-- every entry elevated, each in its own engine units.
print("\n-- Test 8: countNegativeMoodles with all stats fine → 0")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            -- 0.0-1.0 stats
            HUNGER   = 0.05, THIRST = 0.05, FATIGUE = 0.10,
            SICKNESS = 0.00, STRESS = 0.00,
            -- 0-100 stats
            PANIC    = 0,    PAIN   = 0,
        },
    })
    local count = AutoPilot_Threat.countNegativeMoodles(player)
    assert_eq("countNegativeMoodles returns 0 when all fine", count, 0)
end

-- 8b. EVERY entry in NEGATIVE_STAT_CHECKS must be reachable.
--
-- Each stat is set just above its threshold in the units the ENGINE uses for
-- that stat (CharacterStatScale in lua_mock_pz.lua records which is which), so
-- an entry flagged with the wrong scale cannot reach its threshold and the
-- count comes up short.  Before the 2026-07-26 fix this returned 5, not 7:
-- SICKNESS and STRESS are 0.0-1.0 stats that were flagged 0-100, so
-- countNegativeMoodles divided them by 100 a second time (0.25 → 0.0025 against
-- a 0.20 threshold; 0.50 → 0.005 against 0.40) and neither could ever count.
print("\n-- Test 8b: every NEGATIVE_STAT_CHECKS entry is reachable on its real scale")
do
    reset()
    local player = MockPlayer.new({
        stats = {
            -- 0.0-1.0 stats, each just over its threshold
            HUNGER   = 0.50,  -- ≥ 0.40
            THIRST   = 0.50,  -- ≥ 0.40
            FATIGUE  = 0.70,  -- ≥ 0.60
            SICKNESS = 0.25,  -- ≥ 0.20  (was unreachable: 0.25/100 = 0.0025)
            STRESS   = 0.50,  -- ≥ 0.40  (was unreachable: 0.50/100 = 0.005)
            -- 0-100 stats, each just over its threshold after the /100
            PANIC    = 50,    -- 50/100 = 0.50 ≥ 0.40
            PAIN     = 40,    -- 40/100 = 0.40 ≥ 0.30
        },
    })
    local count = AutoPilot_Threat.countNegativeMoodles(player)
    assert_eq("all seven entries count when every stat is elevated", count, 7)
end

-- 8c. The two rescaled entries each count on their own.
--
-- 8b would still pass at 7 if some other entry double-counted, so each repaired
-- entry gets an isolating case: a character whose ONLY elevated stat is the one
-- under test must score exactly 1.  These are the assertions that fail if
-- either isNormalized flag is flipped back to false.
print("\n-- Test 8c: SICKNESS and STRESS each count in isolation")
do
    reset()
    local sick = MockPlayer.new({
        stats = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10,
                  SICKNESS = 0.35, STRESS = 0.00, PANIC = 0, PAIN = 0 },
    })
    assert_eq("a sick-but-otherwise-fine character scores 1",
        AutoPilot_Threat.countNegativeMoodles(sick), 1)

    local stressed = MockPlayer.new({
        stats = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10,
                  SICKNESS = 0.00, STRESS = 0.60, PANIC = 0, PAIN = 0 },
    })
    assert_eq("a stressed-but-otherwise-fine character scores 1",
        AutoPilot_Threat.countNegativeMoodles(stressed), 1)

    -- And the boundary the old code could never cross: a stat below its
    -- threshold but well above 0 must still NOT count, so the fix did not
    -- simply make everything count.
    local mildlySick = MockPlayer.new({
        stats = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10,
                  SICKNESS = 0.15, STRESS = 0.30, PANIC = 0, PAIN = 0 },
    })
    assert_eq("sub-threshold sickness and stress still score 0",
        AutoPilot_Threat.countNegativeMoodles(mildlySick), 0)
end

-- 8d. SANITY is no longer counted at all.
--
-- It was removed rather than rescaled because it is polarity-inverted: it reads
-- HIGH when the character is healthy, so a `value >= threshold` entry scores a
-- perfectly sane character as negative (or, on the 0.0-1.0 scale it is actually
-- kept on, never scores anybody).  A healthy character at full sanity must
-- score 0 here.
--
-- HONEST LIMIT, measured: reinstating the old entry does NOT fail this case.
-- Putting `{ SANITY, 0.40, isNormalized = false }` back leaves this suite at
-- 57/0, because the old entry was unreachable -- 1.00/100 = 0.01 is under any
-- threshold, which is the whole point.  A behavioural fixture cannot detect a
-- gate that never fires; that is why the guard for this one is STATIC, in
-- test_stat_scales Test 4 ("SANITY is not a >= threshold entry"), which does
-- fail on reinstatement.  This case documents the intended behaviour and
-- covers the OTHER direction: a future rescale to `isNormalized = true` would
-- score a fully sane character 1 and fail here.
print("\n-- Test 8d: SANITY does not contribute to the negative count")
do
    reset()
    local player = MockPlayer.new({
        stats = { HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10,
                  SICKNESS = 0.00, STRESS = 0.00, PANIC = 0, PAIN = 0,
                  SANITY = 1.00 },  -- fully sane
    })
    assert_eq("full sanity does not count as a negative stat",
        AutoPilot_Threat.countNegativeMoodles(player), 0)
end

-- 9. forceFlee does not crash even when no walkable square is found.
print("\n-- Test 9: forceFlee does not crash with zombie and no walkable square")
do
    reset()
    setZombies({ makeZombie(2, 2) })
    local player = MockPlayer.new({})
    local ok = pcall(function() AutoPilot_Threat.forceFlee(player) end)
    assert_true("forceFlee does not crash", ok)
end

-- 10. (Removed in 0.1.0 with AutoPilot_Threat.forceFight -- the mod no longer
-- fights; there is no B42 AI-attack API.  forceFlee is covered by Test 9.)

-- 11. Healthy player with weapon + one zombie → flee path, check returns true.
print("\n-- Test 11: Healthy + weapon + one zombie → flee path")
do
    reset()
    AutoPilot_Inventory._weapon = { getMaxDamage = function(self) return 5 end }
    setZombies({ makeZombie(3, 3) })
    local player = MockPlayer.new({
        stats = {
            HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10,
            PANIC  = 0,    PAIN   = 0,    SICKNESS = 0,
            STRESS = 0,    SANITY = 0,
        },
    })
    player.getPrimaryHandItem = function(self) return nil end
    local result = AutoPilot_Threat.check(player)
    assert_true("check() returns true with zombie present", result)
end

-- 12. getNearbyZombies: dead zombies are not counted.
print("\n-- Test 12: getNearbyZombies ignores dead zombies")
do
    reset()
    local dead = {
        isDead    = function(self) return true end,
        getX      = function(self) return 1 end,
        getY      = function(self) return 1 end,
    }
    setZombies({ dead })
    local player = MockPlayer.new({})
    local result = AutoPilot_Threat.getNearbyZombies(player)
    assert_eq("dead zombie not counted", #result, 0)
end

-- ── Weapon in fighting condition (used by the flee-decision cases below) ──────

-- A weapon whose condition ratio clears WEAPON_FIGHT_COND_MIN, so the threat
-- module treats the character as "armed" when choosing a flee reason.
local function makeUsableWeapon()
    return {
        getMaxDamage    = function(self) return 5 end,
        getCondition    = function(self) return 10 end,
        getConditionMax = function(self) return 10 end,
    }
end

-- Tests 13 & 14 (the transfer-before-equip that the removed doFight performed)
-- are gone as of 0.1.0: combat is flee-only, so the threat module never equips a
-- weapon itself.  Keeping the best weapon in hand is checkAndSwapWeapon's job and
-- is covered by test_container_search Test 29 ("a bagged weapon transfers THEN is
-- equipped").

-- ══ Flee must EXECUTE, and combat must NEVER walk into zombies ════════════════
-- Regression cover for the user-reported HIGH severity bug ("the fight/flee
-- mechanic is not working as expected").  Two live failures are pinned here:
--   * A 175-tick combat streak with zombies=7 and endurance=52 FROZEN, ending
--     in action=dead: check() cleared the queue every tick, so whatever it
--     queued 0.75 s earlier was destroyed before it could run.  The queue model
--     below reproduces that; Test 17 proves a live flee now survives the tick.
--   * A healthy, armed character killed while "fighting" 4 zombies.  B42 exposes
--     no AI-attack API, so the old fight path only ever walked the character to
--     its death.  0.1.0 makes combat FLEE-ONLY; Tests 15/16/22 prove a trapped
--     engage now HOLDS instead of walking into the horde.

-- A queue model faithful enough to reproduce the spin: clear() really empties
-- the queue, and isPlayerDoingAction() reports whether anything is left (the
-- real B42 helper the engage guard checks; isAllDone does not exist).
local ISTQ_clears = 0

local function installQueueModel()
    ISTQ_clears = 0
    ISTimedActionQueue_calls = {}
    ISTimedActionQueue.clear = function(_p)
        ISTQ_clears = ISTQ_clears + 1
        ISTimedActionQueue_calls = {}
    end
    ISTimedActionQueue.isPlayerDoingAction = function(_p)
        return #ISTimedActionQueue_calls > 0
    end
    ISTimedActionQueue.getTimedActionQueue = function(_p)
        return { queue = { ISTimedActionQueue_calls[1] } }
    end
end

local function makeSquareAt(x, y, z)
    return {
        getX   = function(_self) return x end,
        getY   = function(_self) return y end,
        getZ   = function(_self) return z or 0 end,
        isFree = function(_self, _ignore) return true end,
    }
end

-- A zombie that owns a square, so the engage logic has a real position to
-- reason about (spread analysis, escape vector).
local function makeZombieAt(x, y)
    local z  = makeZombie(x, y)
    local sq = makeSquareAt(x, y, 0)
    z.getSquare = function(_self) return sq end
    return z
end

-- n zombies evenly spaced on a ring of the given radius around (0, 0).
local function makeRing(n, radius)
    local list = {}
    for i = 1, n do
        local a = (i - 1) * (2 * math.pi / n)
        table.insert(list, makeZombieAt(math.cos(a) * radius, math.sin(a) * radius))
    end
    return list
end

local function healthyPlayer()
    local p = MockPlayer.new({
        stats = {
            HUNGER = 0.05, THIRST = 0.05, FATIGUE = 0.10, ENDURANCE = 0.90,
            PANIC  = 0,    PAIN   = 0,    SICKNESS = 0,
            STRESS = 0,    SANITY = 0,
        },
    })
    p.getPrimaryHandItem = function(_self) return nil end
    return p
end

local function engageReason()
    if AutoPilot_Threat.getEngageReason then
        return AutoPilot_Threat.getEngageReason()
    end
    return "threat"
end

-- 15. THE TRAP (flee-only).  7 zombies, no escape square reachable anywhere.
-- Pre-0.1.0 the mod fell back to walking INTO the horde (a "fight" that could
-- never land a hit).  Now it must queue NOTHING -- standing still is strictly
-- safer than walking into the zombies -- and report flee_blocked, this tick and
-- the next.
print("\n-- Test 15 (0.1.0): a trapped flee holds, it never fights")
do
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(7, 4))          -- 7 >= FLEE_HORDE_SIZE
    local player = healthyPlayer()

    assert_true("tick 1: check() returns true", AutoPilot_Threat.check(player))
    assert_eq("tick 1: nothing queued (no walk toward the horde)",
        #ISTimedActionQueue_calls, 0)
    assert_eq("tick 1: reported as flee_blocked", engageReason(), "flee_blocked")

    assert_true("tick 2: check() returns true", AutoPilot_Threat.check(player))
    assert_eq("tick 2: still nothing queued", #ISTimedActionQueue_calls, 0)
    assert_eq("tick 2: still flee_blocked", engageReason(), "flee_blocked")
end

-- 16. The same trap with HOME SET (the LIVE configuration: Main auto-anchors
-- home on the first armed cycle).  As of 0.1.0 home no longer changes the flee
-- destination -- flee always runs AWAY from the zombies, never toward a home
-- anchor that usually sits on top of the player -- so a home-set trap holds
-- exactly like Test 15 and still never fights.
print("\n-- Test 16 (0.1.0): home set + no escape square holds, never fights")
do
    reset(); installQueueModel()
    AutoPilot_Home._homeSet     = true
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(7, 4))
    local player = healthyPlayer()

    assert_true("check() returns true", AutoPilot_Threat.check(player))
    assert_eq("nothing queued despite safehouse mode",
        #ISTimedActionQueue_calls, 0)
    assert_eq("reported as flee_blocked", engageReason(), "flee_blocked")
end

-- 17. A SUCCESSFUL flee still sets its guard and is not re-cleared.
print("\n-- Test 17 (V5.6): a successful flee is left alone on the next tick")
do
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(7, 4))
    local player = healthyPlayer()

    local escapeSq = makeSquareAt(20, 20, 0)
    local origFind = AutoPilot_Utils.findNearestSquare
    AutoPilot_Utils.findNearestSquare = function(_cx, _cy, _cz, _r, _pred)
        return escapeSq
    end

    assert_true("tick 1: check() returns true", AutoPilot_Threat.check(player))
    assert_eq("tick 1: one walk queued", #ISTimedActionQueue_calls, 1)
    assert_eq("tick 1: it walks to the escape square",
        ISTimedActionQueue_calls[1].sq, escapeSq)
    assert_eq("tick 1: reported as flee_horde", engageReason(), "flee_horde")
    assert_true("tick 1: the flee guard is set", AutoPilot_Threat._fleeActive)

    local clearsAfterTick1 = ISTQ_clears
    assert_true("tick 2: check() returns true", AutoPilot_Threat.check(player))
    assert_eq("tick 2: the flee walk was not cleared", ISTQ_clears, clearsAfterTick1)
    assert_eq("tick 2: the flee walk is still queued",
        ISTimedActionQueue_calls[1].sq, escapeSq)

    AutoPilot_Utils.findNearestSquare = origFind
end

-- 18. V4.5 OWNERSHIP: a foreign (non-mod-queued) action is never cleared,
-- not even in combat.
print("\n-- Test 18 (V5.6/V4.5): combat never clears a foreign action")
do
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(7, 4))
    local player = healthyPlayer()

    -- A player-queued action: present in the queue, NOT in the ownership
    -- registry (AutoPilot_Utils.tagModAction was never called on it).
    local foreign = { type = "foreign_action" }
    table.insert(ISTimedActionQueue_calls, foreign)
    assert_false("sanity: the foreign action is not a mod action",
        AutoPilot_Utils.isModAction(foreign))

    assert_true("check() returns true", AutoPilot_Threat.check(player))
    assert_eq("clear() was never called on a foreign action", ISTQ_clears, 0)
    assert_eq("the foreign action is still at the head of the queue",
        ISTimedActionQueue_calls[1], foreign)
end

-- 19. A mod-queued NON-engage action (e.g. an exercise set) may still be
-- cleared to make room for the flee response, which then replaces it.  An
-- escape square is provided so the flee actually queues a walk (with none
-- reachable the mod would clear the exercise and then hold -- see Test 15).
print("\n-- Test 19 (0.1.0): the mod's own non-combat action is cleared to flee")
do
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(7, 4))
    local player = healthyPlayer()

    local escapeSq = makeSquareAt(20, 20, 0)
    local origFind = AutoPilot_Utils.findNearestSquare
    AutoPilot_Utils.findNearestSquare = function(_cx, _cy, _cz, _r, _pred)
        return escapeSq
    end

    local ownAction = AutoPilot_Utils.tagModAction({ type = "exercise" })
    table.insert(ISTimedActionQueue_calls, ownAction)

    assert_true("check() returns true", AutoPilot_Threat.check(player))
    assert_eq("the mod's own exercise was cleared once", ISTQ_clears, 1)
    assert_true("a flee walk replaced it", #ISTimedActionQueue_calls > 0)
    assert_false("the exercise is gone",
        ISTimedActionQueue_calls[1] == ownAction)

    AutoPilot_Utils.findNearestSquare = origFind
end

-- 20. Every priority branch still selects the right intent, and now says so.
print("\n-- Test 20 (V5.6): each priority branch emits its own telemetry reason")
do
    -- An escape square IS available throughout this case, so each flee branch
    -- reports its own decision rather than the flee_blocked trap fallback.
    local escapeSq = makeSquareAt(20, 20, 0)
    local origFind = AutoPilot_Utils.findNearestSquare
    AutoPilot_Utils.findNearestSquare = function(_cx, _cy, _cz, _r, _pred)
        return escapeSq
    end

    -- Priority 1: bleeding always flees.
    reset(); installQueueModel()
    AutoPilot_Medical._bleeding = true
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies({ makeZombieAt(3, 3) })
    AutoPilot_Threat.check(healthyPlayer())
    assert_eq("bleeding → flee_wounded", engageReason(), "flee_wounded")

    -- Priority 2: horde.
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(AutoPilot_Constants.FLEE_HORDE_SIZE, 4))
    AutoPilot_Threat.check(healthyPlayer())
    assert_eq("horde → flee_horde", engageReason(), "flee_horde")

    -- Priority 3: no usable weapon and outnumbered.
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = nil
    setZombies({ makeZombieAt(2, 2), makeZombieAt(4, 4) })
    AutoPilot_Threat.check(healthyPlayer())
    assert_eq("unarmed and outnumbered → flee_unarmed", engageReason(),
        "flee_unarmed")

    -- Priority 4: encircled (5 zombies at 72 degrees apart, all gaps < 90).
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(5, 4))
    AutoPilot_Threat.check(healthyPlayer())
    assert_eq("encircled → flee_encircled", engageReason(), "flee_encircled")

    -- Priority 5a: too many negative moodles.
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies({ makeZombieAt(3, 3) })
    AutoPilot_Threat.check(MockPlayer.new({
        stats = { HUNGER = 0.50, THIRST = 0.50, FATIGUE = 0.70, PANIC = 50 },
    }))
    assert_eq("moodle limit exceeded → flee_moodles", engageReason(),
        "flee_moodles")

    -- Priority 5b: healthy, armed, one zombie → the default flee.
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies({ makeZombieAt(3, 3) })
    AutoPilot_Threat.check(healthyPlayer())
    assert_eq("healthy and armed → flee_default", engageReason(),
        "flee_default")

    -- And when the escape square disappears, the flee reports the trapped
    -- fallback (flee_blocked) instead of silently doing nothing.
    AutoPilot_Utils.findNearestSquare = function(_cx, _cy, _cz, _r, _pred)
        return nil
    end
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(AutoPilot_Constants.FLEE_HORDE_SIZE, 4))
    AutoPilot_Threat.check(healthyPlayer())
    assert_eq("horde with no escape → flee_blocked", engageReason(),
        "flee_blocked")

    AutoPilot_Utils.findNearestSquare = origFind
end

-- 21. Encircled still FLEES -- through the widest gap.  Priority 4 points the
-- escape vector through the largest arc-gap in the ring, so the mod must report
-- flee_encircled and queue a walk to the resolved escape square.  (Pre-0.1.0
-- this branch "fought through the gap"; the mod no longer fights at all.)
print("\n-- Test 21 (0.1.0): encircled flees through the widest gap")
do
    reset(); installQueueModel()
    AutoPilot_Home._homeSet     = true
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(5, 4))
    local player = healthyPlayer()

    local escapeSq = makeSquareAt(0, 30, 0)
    local origFind = AutoPilot_Utils.findNearestSquare
    AutoPilot_Utils.findNearestSquare = function(_cx, _cy, _cz, _r, _pred)
        return escapeSq
    end

    assert_true("check() returns true", AutoPilot_Threat.check(player))
    assert_eq("reported as flee_encircled", engageReason(), "flee_encircled")
    local fledOut = false
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == "walk" and a.sq == escapeSq then fledOut = true end
    end
    assert_true("a walk toward the escape square was queued", fledOut)

    AutoPilot_Utils.findNearestSquare = origFind
end

-- 22. The escape destination must never be the tile the player already stands
-- on: a walk to your own square completes instantly and escapes nothing.  When
-- the only square the pathfinder offers IS the player's tile, the flee is
-- rejected and the mod HOLDS (flee_blocked) -- it does not walk in place, and it
-- does not fight.
print("\n-- Test 22 (0.1.0): the player's own square is not a flee destination")
do
    reset(); installQueueModel()
    AutoPilot_Home._homeSet     = true
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies(makeRing(7, 4))
    local player = healthyPlayer()   -- MockPlayer sits at (0, 0, 0)

    local ownSq    = makeSquareAt(0, 0, 0)
    local origFind = AutoPilot_Utils.findNearestSquare
    AutoPilot_Utils.findNearestSquare = function(_cx, _cy, _cz, _r, _pred)
        return ownSq
    end

    assert_true("check() returns true", AutoPilot_Threat.check(player))
    local walkedInPlace = false
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == "walk" and a.sq == ownSq then walkedInPlace = true end
    end
    assert_false("no zero-length walk was queued", walkedInPlace)
    assert_eq("holds instead (flee_blocked), never fights", engageReason(),
        "flee_blocked")

    AutoPilot_Utils.findNearestSquare = origFind
end

-- 23. The escape-arc target is passed to the square lookup as ABSOLUTE world
-- coordinates.  Pre-V5.6 it was clamped against cell:getWidth()/getHeight()
-- (loaded-cell dimensions, a few hundred tiles), which squashed any real map
-- position into a square that does not exist, so every non-home flee failed.
print("\n-- Test 23 (V5.6): flee targets use unclamped world coordinates")
do
    reset(); installQueueModel()
    AutoPilot_Inventory._weapon = makeUsableWeapon()
    setZombies({ makeZombieAt(10600, 9200) })

    -- A player standing at a REAL Muldraugh-scale world position.
    local player = healthyPlayer()
    player.getX = function(_self) return 10604 end
    player.getY = function(_self) return 9204 end
    AutoPilot_Medical._bleeding = true   -- priority 1 → flee

    local seenX, seenY = nil, nil
    local origFind = AutoPilot_Utils.findNearestSquare
    AutoPilot_Utils.findNearestSquare = function(cx, cy, _cz, _r, _pred)
        seenX, seenY = cx, cy
        return nil
    end

    AutoPilot_Threat.check(player)
    AutoPilot_Utils.findNearestSquare = origFind

    assert_true("the flee target keeps world-scale X",
        seenX ~= nil and seenX > 10000)
    assert_true("the flee target keeps world-scale Y",
        seenY ~= nil and seenY > 9000)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
