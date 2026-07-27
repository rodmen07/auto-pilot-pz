-- tests/test_carry_capacity.lua
-- Carry-capacity gate: discretionary looting must stop before the character is
-- overloaded, and emergency medical looting must NOT.
--
-- WHY THIS SUITE EXISTS
-- ---------------------
-- Until this gate shipped the mod had no weight sense at all.  A whole-mod grep
-- for getMaxWeight / getCapacityWeight / getEffectiveCapacity / HEAVY_LOAD over
-- 42/media/lua/client returned exactly one hit, and it was a COMMENT in
-- AutoPilot_Comfort listing moodles the mod does not manage.  Every loot path
-- queued its ISInventoryTransferAction regardless of what the character was
-- already carrying, so the mod's own proactive scavenging (a background chore
-- that runs on a cooldown forever) could pile weight on indefinitely.
--
-- That is a named half of the 2026-07-24 user report "negative moodles /
-- status effects accumulate over long autopilot runs": Heavy Load is on that
-- report's unmanaged-moodle list.  It is also worse than cosmetic here,
-- because vanilla REFUSES to let an overloaded character exercise -- the
-- fitness OK button is disabled with Tooltip_TooHeavyFitness whenever
-- MoodleType.HEAVY_LOAD > 2 (client/ISUI/ISFitnessUI.lua:219, verified live in
-- the 42.19 install).  An unbounded looter can therefore loot itself out of
-- the mod's own training loop.
--
-- The gate refuses a PICKUP.  It never drops, moves, or destroys anything the
-- character already carries, so the worst case is that the mod stops taking
-- more, which is exactly the vanilla answer to a full pack.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_carry_capacity.lua

dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.findNearestSquare    = function(_cx, _cy, _cz, _r, _pred) return nil end
AutoPilot_Utils.iterateNearbySquares = function(...) end

dofile("42/media/lua/client/AutoPilot_Map.lua")
dofile("42/media/lua/client/AutoPilot_Home.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")

ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}
luautils = { walkAdj = function(_player, _sq, _) end }

dofile("42/media/lua/client/AutoPilot_Inventory.lua")

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

local LIMIT = AutoPilot_Constants.HEAVY_LOAD_LOOT_LIMIT

-- ── Builders ──────────────────────────────────────────────────────────────────

-- A food item heavy enough to matter.  getActualWeight is the engine's own
-- item-weight getter (client/Foraging/ISSearchManager.lua:510,
-- client/TimedActions/ISInventoryTransferAction.lua:883).
local function makeFood(name, weight)
    return {
        getName         = function(_self) return name end,
        getType         = function(_self) return name end,
        isFood          = function(_self) return true end,
        isRotten        = function(_self) return false end,
        getCalories     = function(_self) return 300 end,
        getThirstChange = function(_self) return 0 end,
        getActualWeight = function(_self) return weight or 1 end,
        isCanBandage    = function(_self) return false end,
    }
end

local function makeDrink(name, weight)
    local d = makeFood(name, weight)
    d.getCalories     = function(_self) return 0 end
    d.getThirstChange = function(_self) return -20 end
    return d
end

local function makeBandage(weight)
    local b = makeFood("Bandage", weight or 0.1)
    b.isFood          = function(_self) return false end
    b.isCanBandage    = function(_self) return true end
    return b
end

-- Publish one world container on the player's own square holding `items`.
local function placeContainer(items)
    local container = MockContainer.new(items)
    AutoPilot_Utils.iterateNearbySquares =
        function(_cx, _cy, _cz, _radius, cb)
            local sq = {}
            local obj = {
                getContainer = function(_self) return container end,
                getSquare    = function(_self) return sq end,
            }
            sq.getObjects = function(_self)
                return { size = function(_s) return 1 end,
                         get  = function(_s, _i) return obj end }
            end
            sq.getX = function(_self) return 0 end
            sq.getY = function(_self) return 0 end
            sq.getZ = function(_self) return 0 end
            cb(sq, 0, 0)
        end
    return container
end

local function resetQueue() ISTimedActionQueue_calls = {} end

-- ── 1. hasCarryRoom: the unencumbered default is unchanged ────────────────────
print("=== Test 1: an unencumbered character may pick anything up ===")
do
    local p = MockPlayer.new({})
    assert_true("empty-handed character has room for a 1kg item",
        AutoPilot_Utils.hasCarryRoom(p, makeFood("Beans", 1)))
end

-- ── 2-3. The HEAVY_LOAD moodle is the gate ────────────────────────────────────
print("\n=== Test 2: the HEAVY_LOAD moodle at the limit refuses a pickup ===")
do
    local p = MockPlayer.new({ moodles = { [MoodleType.HEAVY_LOAD] = LIMIT } })
    assert_false("HEAVY_LOAD at the limit refuses",
        AutoPilot_Utils.hasCarryRoom(p, makeFood("Beans", 1)))
end

print("\n=== Test 3: one level below the limit still loots ===")
do
    local p = MockPlayer.new({ moodles = { [MoodleType.HEAVY_LOAD] = LIMIT - 1 } })
    assert_true("HEAVY_LOAD below the limit still allows a pickup",
        AutoPilot_Utils.hasCarryRoom(p, makeFood("Beans", 1)))
end

-- ── 4. The engine's own per-item test refuses ─────────────────────────────────
print("\n=== Test 4: hasRoomFor(false) refuses even with no moodle ===")
do
    local p = MockPlayer.new({ hasRoom = false })
    assert_eq("sanity: the moodle is clear", 0,
        p:getMoodles():getMoodleLevel(MoodleType.HEAVY_LOAD))
    assert_false("the engine's hasRoomFor veto is honoured",
        AutoPilot_Utils.hasCarryRoom(p, makeFood("Beans", 1)))
end

-- ── 5-6. Arithmetic fallback when hasRoomFor is unavailable ───────────────────
-- Mirrors shared/ActionManager.lua:11, where the engine drops a picked-up item
-- on the ground once getCapacityWeight() exceeds getEffectiveCapacity(chr).
print("\n=== Test 5: without hasRoomFor, weight arithmetic still refuses ===")
do
    local p = MockPlayer.new({ carriedWeight = 9.5, carryCapacity = 10 })
    p:getInventory().hasRoomFor = nil
    assert_false("9.5 carried + 1.0 item over a capacity of 10 refuses",
        AutoPilot_Utils.hasCarryRoom(p, makeFood("Beans", 1)))
end

print("\n=== Test 6: the same arithmetic allows a pickup that fits ===")
do
    local p = MockPlayer.new({ carriedWeight = 8, carryCapacity = 10 })
    p:getInventory().hasRoomFor = nil
    assert_true("8 carried + 1.0 item under a capacity of 10 allows",
        AutoPilot_Utils.hasCarryRoom(p, makeFood("Beans", 1)))
end

-- ── 7-9. Fail-open: a missing engine surface never stalls the loop ────────────
print("\n=== Test 7: an inventory with no capacity surface fails OPEN ===")
do
    local p = MockContainer.attach(MockPlayer.new({}), {
        getItems = function(_self)
            return { size = function(_s) return 0 end, get = function(_s) return nil end }
        end,
    })
    assert_true("no capacity methods at all still loots (pre-gate behaviour)",
        AutoPilot_Utils.hasCarryRoom(p, makeFood("Beans", 1)))
end

print("\n=== Test 8: a nil inventory fails OPEN ===")
do
    local p = MockPlayer.new({})
    p.getInventory = function(_self) return nil end
    assert_true("nil inventory still loots", AutoPilot_Utils.hasCarryRoom(p, makeFood("X", 1)))
end

print("\n=== Test 9: a nil player fails OPEN ===")
do
    assert_true("nil player still loots", AutoPilot_Utils.hasCarryRoom(nil, makeFood("X", 1)))
end

-- ── 10-11. lootNearbyFood: the behaviour difference the gate buys ─────────────
print("\n=== Test 10: with room, food loot queues a transfer (control) ===")
do
    resetQueue()
    local p = MockPlayer.new({})
    placeContainer({ makeFood("Beans", 1) })
    assert_true("loot reported", AutoPilot_Inventory.lootNearbyFood(p))
    assert_eq("exactly one transfer queued", #ISTimedActionQueue_calls, 1)
    assert_eq("and it is a transfer", ISTimedActionQueue_calls[1].type, "transfer")
end

print("\n=== Test 11: overloaded, the SAME food loot queues nothing ===")
do
    resetQueue()
    local p = MockPlayer.new({ moodles = { [MoodleType.HEAVY_LOAD] = LIMIT } })
    placeContainer({ makeFood("Beans", 1) })
    assert_false("loot refused", AutoPilot_Inventory.lootNearbyFood(p))
    assert_eq("nothing was queued", #ISTimedActionQueue_calls, 0)
end

-- ── 12. The drink path is gated too (sibling sweep) ───────────────────────────
print("\n=== Test 12: the drink loot path is gated by the same seam ===")
do
    resetQueue()
    local pOk = MockPlayer.new({})
    placeContainer({ makeDrink("WaterBottle", 1) })
    assert_true("with room, drink loot queues", AutoPilot_Inventory.lootNearbyDrink(pOk))
    assert_eq("one transfer queued", #ISTimedActionQueue_calls, 1)

    resetQueue()
    local pFull = MockPlayer.new({ hasRoom = false })
    assert_false("with no room, drink loot refuses",
        AutoPilot_Inventory.lootNearbyDrink(pFull))
    assert_eq("nothing was queued", #ISTimedActionQueue_calls, 0)
end

-- ── 13. Emergency medical loot BYPASSES the gate, deliberately ────────────────
-- Bleeding out beats encumbrance: a bandage weighs almost nothing and the
-- alternative to carrying it is dying of blood loss.
print("\n=== Test 13: an emergency bandage is looted even while overloaded ===")
do
    resetQueue()
    local p = MockPlayer.new({
        moodles = { [MoodleType.HEAVY_LOAD] = LIMIT + 2 },
        hasRoom = false,
    })
    assert_false("the character is definitively overloaded",
        AutoPilot_Utils.hasCarryRoom(p, makeBandage()))
    placeContainer({ makeBandage() })
    assert_true("the bandage is still looted",
        AutoPilot_Inventory.emergencyMedicalLoot(p))
    assert_eq("one transfer queued", #ISTimedActionQueue_calls, 1)
    assert_eq("and it is the bandage",
        ISTimedActionQueue_calls[1].item:getName(), "Bandage")
end

-- ── 14. bulkLoot is gated per item ────────────────────────────────────────────
-- bulkLoot has no production caller today (a whole-mod grep finds only its
-- definition), but it is public and transfers a whole container in one pass,
-- which is the fastest way to overload a character.
print("\n=== Test 14: bulkLoot transfers with room and skips without ===")
do
    resetQueue()
    local container = MockContainer.new({ makeFood("dumbbell", 5), makeFood("dumbbell", 5) })
    local pOk = MockPlayer.new({})
    assert_eq("both matching items transferred",
        AutoPilot_Inventory.bulkLoot(pOk, container, { "dumbbell" }), 2)
    assert_eq("two transfers queued", #ISTimedActionQueue_calls, 2)

    resetQueue()
    local pFull = MockPlayer.new({ moodles = { [MoodleType.HEAVY_LOAD] = LIMIT } })
    assert_eq("overloaded, nothing is transferred",
        AutoPilot_Inventory.bulkLoot(pFull, container, { "dumbbell" }), 0)
    assert_eq("nothing was queued", #ISTimedActionQueue_calls, 0)
end

-- ── 15. The limit may not drift past the vanilla exercise cutoff ──────────────
-- Vanilla disables the fitness UI's start button at HEAVY_LOAD > 2
-- (client/ISUI/ISFitnessUI.lua:219).  A mod limit above that would let the
-- looter walk the character into a state where its own training cannot run.
print("\n=== Test 15: the loot limit stays at or below the vanilla fitness cutoff ===")
do
    assert_eq("HEAVY_LOAD_LOOT_LIMIT is a number", type(LIMIT), "number")
    assert_true("HEAVY_LOAD_LOOT_LIMIT <= 2 (ISFitnessUI.lua:219 refuses above 2)",
        LIMIT <= 2)
end

-- ── 16. A refusal is distinguishable from an empty container ──────────────────
-- 2026-07-26 follow-up to PR #85: from the scavenge stuck-counter's point of
-- view a refused pickup and a looted-out area were identical, so an overloaded
-- character's backoff logged as "no supply gain" with no hint the mod was
-- full.  The carry gate now returns the fail label "carry_full" as a second
-- value, which _queueTransfer's tail-call callers propagate unchanged.
print("\n=== Test 16: a carry-gate refusal reports carry_full; an empty area does not ===")
do
    resetQueue()
    local pFull = MockPlayer.new({ moodles = { [MoodleType.HEAVY_LOAD] = LIMIT } })
    placeContainer({ makeFood("Beans", 1) })
    local ok, why = AutoPilot_Inventory.lootNearbyFood(pFull)
    assert_false("food loot refused", ok)
    assert_eq("and the refusal names carry_full", why, "carry_full")

    placeContainer({ makeDrink("WaterBottle", 1) })
    local okD, whyD = AutoPilot_Inventory.lootNearbyDrink(
        MockPlayer.new({ hasRoom = false }))
    assert_false("drink loot refused", okD)
    assert_eq("and the drink refusal names carry_full", whyD, "carry_full")

    -- The behaviour difference: the SAME overloaded character over an EMPTY
    -- container reports no fail label at all — nothing was refused.
    placeContainer({})
    local okE, whyE = AutoPilot_Inventory.lootNearbyFood(pFull)
    assert_false("nothing to loot", okE)
    assert_eq("an empty area carries no fail label", whyE, nil)
    assert_eq("nothing was queued anywhere in this test", #ISTimedActionQueue_calls, 0)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== carry capacity: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
