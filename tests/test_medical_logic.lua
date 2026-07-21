-- tests/test_medical_logic.lua
-- Behavioral tests for AutoPilot_Medical.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_medical_logic.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")

-- ── Load constants ────────────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Constants.lua")

-- Additional PZ stubs needed by Medical
ISInventoryTransferAction = {
    new = function(_, _player, item, _src, _dst)
        return { type = "transfer", item = item }
    end,
}

-- BodyPartType: Medical uses getDisplayName for debug printing; mock it.
BodyPartType.getDisplayName = function(_) return "MockBodyPart" end

-- ── Stub dependency modules ───────────────────────────────────────────────────
-- Real Utils (V4.5: provides the mod-action ownership registry that the
-- production queue sites now route through); square scans are no-op'd for
-- the suite, same behavior as the old hand-rolled stub.
dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.findNearestSquare    = function(_cx, _cy, _cz, _r, _pred) return nil end
AutoPilot_Utils.iterateNearbySquares = function(...) end

-- ── Load module under test ────────────────────────────────────────────────────
dofile("42/media/lua/client/AutoPilot_Medical.lua")

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
end

-- ── Player builder helpers ────────────────────────────────────────────────────

-- Add a usable bandage item to the player's inventory.
local function addBandageToInventory(player)
    local bandageItem = {
        getType      = function(self) return "Bandage" end,
        getName      = function(self) return "Bandage" end,
        isCanBandage = function(self) return true end,
    }
    local itemsArr = { bandageItem }
    local items = {
        size = function(self) return #itemsArr end,
        get  = function(self, i) return itemsArr[i + 1] end,
    }
    -- One STABLE container table: the real player:getInventory() returns the
    -- same ItemContainer every call, and V4.9 compares the holding container
    -- against it by identity to decide whether a transfer is needed.  A fresh
    -- table per call would look like a foreign container and fake a transfer.
    local inv = { getItems = function() return items end }
    player.getInventory = function(self) return inv end
    return player
end

-- ── Test cases ────────────────────────────────────────────────────────────────
print("=== AutoPilot_Medical Logic Tests ===")

-- 1. No wounds → check returns false, no actions queued.
print("\n-- Test 1: No wounds → check returns false")
do
    reset()
    local player = MockPlayer.new({})
    local result = AutoPilot_Medical.check(player, false)
    assert_false("check() returns false when no wounds", result)
    assert_eq("no bandage actions queued", #ISTimedActionQueue_calls, 0)
end

-- 2. hasCriticalWound: no bleeding → returns false.
print("\n-- Test 2: hasCriticalWound with no bleeding")
do
    local player = MockPlayer.new({ bleeding = false })
    assert_false("hasCriticalWound returns false when not bleeding",
        AutoPilot_Medical.hasCriticalWound(player))
end

-- 3. hasCriticalWound: actively bleeding → returns true.
print("\n-- Test 3: hasCriticalWound with bleeding")
do
    local player = MockPlayer.new({ bleeding = true })
    assert_true("hasCriticalWound returns true when bleeding",
        AutoPilot_Medical.hasCriticalWound(player))
end

-- 4. Bleeding wound + bandage in inventory → bandage action queued.
print("\n-- Test 4: Bleeding + bandage in inventory → bandage action queued")
do
    reset()
    local player = addBandageToInventory(MockPlayer.new({ bleeding = true }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check() returns true when bleeding + bandage available", result)
    local hasBandage = false
    local bandageAction = nil
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == "bandage" then hasBandage = true; bandageAction = a end
    end
    assert_true("bandage action was queued", hasBandage)
    -- 2026-07-20 mock-surface drift audit: doIt=true APPLIES the bandage;
    -- doIt=false/nil REMOVES it (real ISApplyBandage.lua behavior). AutoPilot
    -- must never queue a removal on a real wound -- this is the assertion
    -- the pre-audit mock could not express because it silently dropped the
    -- 5th constructor argument instead of asserting it.
    assert_true("bandage action APPLIES (doIt=true), never removes",
        bandageAction ~= nil and bandageAction.doIt == true)
end

-- 5. bleedingOnly=true with scratch-only wound → no treatment.
print("\n-- Test 5: bleedingOnly=true + scratch-only wound → no treatment")
do
    reset()
    local player = addBandageToInventory(MockPlayer.new({ scratched = true, bleeding = false }))
    local result = AutoPilot_Medical.check(player, true)
    assert_false("check(bleedingOnly=true) returns false for scratch-only wound", result)
end

-- 6. bleedingOnly=false with scratch wound → bandage queued.
print("\n-- Test 6: bleedingOnly=false + scratch wound → bandage queued")
do
    reset()
    local player = addBandageToInventory(MockPlayer.new({ scratched = true, bleeding = false }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check(bleedingOnly=false) returns true for scratch wound", result)
end

-- 7. getWoundSnapshot: no wounds → all zeroes / false.
print("\n-- Test 7: getWoundSnapshot with no wounds")
do
    local player = MockPlayer.new({})
    local snap = AutoPilot_Medical.getWoundSnapshot(player)
    assert_eq("bleeding count is 0",  snap.bleeding, 0)
    assert_eq("scratched count is 0", snap.scratched, 0)
    assert_false("bitten is false", snap.bitten)
    assert_eq("burnt count is 0", snap.burnt, 0)
end

-- 8. getWoundSnapshot: bleeding wound → bleeding = 1.
print("\n-- Test 8: getWoundSnapshot with bleeding wound")
do
    local player = MockPlayer.new({ bleeding = true })
    local snap = AutoPilot_Medical.getWoundSnapshot(player)
    assert_eq("bleeding count is 1", snap.bleeding, 1)
end

-- 9. getWoundSnapshot: bitten wound → bitten = true.
print("\n-- Test 9: getWoundSnapshot with bitten wound")
do
    local player = MockPlayer.new({ bitten = true })
    local snap = AutoPilot_Medical.getWoundSnapshot(player)
    assert_true("bitten is true", snap.bitten)
end

-- 10. Bleeding + no bandage anywhere → check returns false.
print("\n-- Test 10: Bleeding + no bandage → check returns false (loot needed)")
do
    reset()
    -- Empty inventory, iterateNearbySquares is a no-op in tests.
    local player = MockPlayer.new({ bleeding = true })
    local result = AutoPilot_Medical.check(player, false)
    assert_false("check() returns false when bleeding but no bandage available", result)
end

-- 11. check(): deepWounded wound treated before scratched when both present.
print("\n-- Test 11: deepWounded takes priority over scratched")
do
    reset()
    -- Both deepWounded and scratched; the mock only supports one wound type per
    -- player, but we verify that deepWounded alone is treated (no crash).
    local player = addBandageToInventory(MockPlayer.new({ deepWounded = true }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check() returns true for deepWounded wound", result)
end

-- 12. check(): burnt wound is treated when no higher-priority wound exists.
print("\n-- Test 12: Burnt wound treated when no bleed/deep/bite/scratch")
do
    reset()
    local player = addBandageToInventory(MockPlayer.new({ burnt = true }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check() returns true for burnt wound", result)
end

-- 13. V4.1 (C6): a queued treatment action samples the Doctor perk (read-only
-- XP visibility; Medical resolves AutoPilot_XP at call time, so a suite-local
-- recording stub is enough).
print("\n-- Test 13 (V4.1 C6): queued treatment samples the Doctor perk")
do
    reset()
    AutoPilot_XP = {
        _samples = {},
        sample = function(_player, perk)
            table.insert(AutoPilot_XP._samples, perk)
        end,
    }
    local player = addBandageToInventory(MockPlayer.new({ bleeding = true }))
    local result = AutoPilot_Medical.check(player, false)
    assert_true("check() queues treatment", result)
    assert_eq("exactly one Doctor sample recorded", #AutoPilot_XP._samples, 1)
    assert_eq("sample uses the verified 42.19 perk name",
        AutoPilot_XP._samples[1], Perks.Doctor)
end

-- 14. V4.1 (C6): no treatment queued -> no Doctor sample (event-driven, not
-- per-cycle; also covers the no-bandage failure path).
print("\n-- Test 14 (V4.1 C6): no queued treatment, no Doctor sample")
do
    reset()
    AutoPilot_XP._samples = {}
    local healthy = MockPlayer.new({})
    assert_false("no wounds queues nothing",
        AutoPilot_Medical.check(healthy, false))
    assert_eq("healthy check records no sample", #AutoPilot_XP._samples, 0)

    -- Wounded but no bandage anywhere: doTreatWound fails, still no sample.
    local unbandaged = MockPlayer.new({ bleeding = true })
    assert_false("bleeding without bandage queues nothing",
        AutoPilot_Medical.check(unbandaged, false))
    assert_eq("failed treatment records no sample", #AutoPilot_XP._samples, 0)
end

-- ── V4.8: bandages inside worn/carried containers ─────────────────────────────
-- User report: "I was scratched but not bleeding. Character should still
-- attempt to bandage with something in inventory (including fannypacks,
-- backpacks, or containers)."  Wound DETECTION was already correct; the bug
-- was search SCOPE, since getInventory():getItems() lists only top-level items.

-- Build a bandage-capable item of a given type.
local function bandageItem(itemType)
    return {
        getType      = function(self) return itemType end,
        getName      = function(self) return itemType end,
        isCanBandage = function(self) return true end,
    }
end

-- Count queued bandage actions.
local function bandageActions()
    local n = 0
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == "bandage" then n = n + 1 end
    end
    return n
end

-- 15. THE USER'S EXACT SCENARIO: scratched (not bleeding), and the only
-- bandage in the world is inside a worn backpack.
print("\n-- Test 15 (V4.8): scratched + bandage ONLY in a worn backpack")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    MockContainer.attach(player, MockContainer.new({
        MockContainer.bag("Backpack", { bandageItem("Bandage") }),
    }))

    local result = AutoPilot_Medical.check(player, false)
    assert_true("scratch is treated with a bandage stashed in a backpack", result)
    assert_eq("exactly one bandage action queued", bandageActions(), 1)
end

-- 16. Depth 2: fanny pack nested inside a backpack (the user named fanny packs
-- specifically, and PZ lets a bag sit inside another bag).
print("\n-- Test 16 (V4.8): bandage in a fanny pack nested inside a backpack")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    local fannyPack = MockContainer.bag("FannyPack", { bandageItem("Bandage") })
    MockContainer.attach(player, MockContainer.new({
        MockContainer.bag("Backpack", { fannyPack }),
    }))

    assert_true("depth-2 bandage is found and applied",
        AutoPilot_Medical.check(player, false))
    assert_eq("exactly one bandage action queued", bandageActions(), 1)
end

-- 17. Scope and ranking compose: an AlcoholBandage (priority 1) buried in a
-- nested bag must still beat RippedSheets (priority 4) sitting in the main
-- inventory.  Pre-V4.8 the deep item was invisible AND the flat fallback could
-- lock in whichever eligible item was seen first.
print("\n-- Test 17 (V4.8): deep AlcoholBandage outranks top-level RippedSheets")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    MockContainer.attach(player, MockContainer.new({
        bandageItem("RippedSheets"),
        MockContainer.bag("Backpack", {
            MockContainer.bag("FannyPack", { bandageItem("AlcoholBandage") }),
        }),
    }))

    assert_true("treatment queued", AutoPilot_Medical.check(player, false))
    local used = nil
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == "bandage" then used = a.bandage end
    end
    assert_eq("the higher-priority AlcoholBandage is chosen",
        used and used:getType(), "AlcoholBandage")
end

-- 18. Ranking bug regression (scope-independent): a listed bandage must beat an
-- unlisted eligible item even when the unlisted one is encountered FIRST.  The
-- pre-V4.8 loop set the unlisted fallback inside the scan, so the first
-- eligible item could win over a better one found later.
print("\n-- Test 18 (V4.8): listed bandage beats an unlisted item seen first")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    MockContainer.attach(player, MockContainer.new({
        bandageItem("ImprovisedRag"),   -- eligible, NOT in BANDAGE_PRIORITY
        bandageItem("Bandage"),         -- priority 2, seen second
    }))

    assert_true("treatment queued", AutoPilot_Medical.check(player, false))
    local used = nil
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == "bandage" then used = a.bandage end
    end
    assert_eq("listed Bandage wins over the unlisted item seen first",
        used and used:getType(), "Bandage")
end

-- 19. Priority order among listed items is still lowest-index-wins regardless
-- of encounter order (BandageDirty seen before AlcoholBandage).
print("\n-- Test 19 (V4.8): lowest priority index wins among listed bandages")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    MockContainer.attach(player, MockContainer.new({
        bandageItem("BandageDirty"),     -- priority 3
        bandageItem("AlcoholBandage"),   -- priority 1
        bandageItem("RippedSheetsDirty") -- priority 5
    }))

    assert_true("treatment queued", AutoPilot_Medical.check(player, false))
    local used = nil
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == "bandage" then used = a.bandage end
    end
    assert_eq("AlcoholBandage (index 1) wins", used and used:getType(), "AlcoholBandage")
end

-- 20. An unlisted-but-eligible item is still used when nothing listed exists
-- (the fallback must survive the ranking fix).
print("\n-- Test 20 (V4.8): unlisted eligible item still used as fallback")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    MockContainer.attach(player, MockContainer.new({
        MockContainer.bag("Backpack", { bandageItem("ImprovisedRag") }),
    }))

    assert_true("unlisted eligible bandage in a bag is still used",
        AutoPilot_Medical.check(player, false))
end

-- 21. Scope change must not invent treatment: a bag holding no bandage still
-- yields no action (guards against the walk matching everything).
print("\n-- Test 21 (V4.8): bag with no bandage queues nothing")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    MockContainer.attach(player, MockContainer.new({
        MockContainer.bag("Backpack", {
            { getType = function() return "Rock" end,
              getName = function() return "Rock" end,
              isCanBandage = function() return false end },
        }),
    }))

    assert_false("no bandage anywhere in the tree queues nothing",
        AutoPilot_Medical.check(player, false))
    assert_eq("no bandage action queued", bandageActions(), 0)
end

-- ── V4.9: transfer to the main inventory BEFORE bandaging ─────────────────────
-- User directive: "It should be transfer then bandage".  V4.8 made the bandage
-- FINDABLE inside a fanny pack; the engine still applies bandages from the MAIN
-- inventory only, so the move must be queued first and the ISApplyBandage right
-- behind it (ISTimedActionQueue runs them in that order).

-- Type of the Nth queued action, or nil.
local function actionTypeAt(n)
    local a = ISTimedActionQueue_calls[n]
    return a and a.type or nil
end

local function countType(t)
    local n = 0
    for _, a in ipairs(ISTimedActionQueue_calls) do
        if a.type == t then n = n + 1 end
    end
    return n
end

-- 22. THE USER'S SCENARIO, END TO END: bandage in a fanny pack must produce a
-- TRANSFER first, then the bandage action, in that order.
print("\n-- Test 22 (V4.9): fanny-pack bandage transfers THEN bandages, in order")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    local bandage = bandageItem("Bandage")
    local mainInv = MockContainer.new({
        MockContainer.bag("FannyPack", { bandage }),
    })
    MockContainer.attach(player, mainInv)

    assert_true("treatment is queued", AutoPilot_Medical.check(player, false))
    assert_eq("exactly two actions queued", #ISTimedActionQueue_calls, 2)
    assert_eq("action 1 is the transfer", actionTypeAt(1), "transfer")
    assert_eq("action 2 is the bandage", actionTypeAt(2), "bandage")
    assert_eq("the transfer moves the bandage item",
        ISTimedActionQueue_calls[1].item, bandage)
    assert_eq("the bandage action uses the same item",
        ISTimedActionQueue_calls[2].bandage, bandage)
end

-- 23. No redundant work: a bandage already in the main inventory must NOT
-- produce a transfer.
print("\n-- Test 23 (V4.9): a main-inventory bandage queues NO transfer")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    MockContainer.attach(player, MockContainer.new({ bandageItem("Bandage") }))

    assert_true("treatment is queued", AutoPilot_Medical.check(player, false))
    assert_eq("no transfer action queued", countType("transfer"), 0)
    assert_eq("exactly one bandage action queued", countType("bandage"), 1)
    assert_eq("the bandage is the only queued action", #ISTimedActionQueue_calls, 1)
end

-- 24. Depth 2 still transfers exactly once (the fanny pack inside a backpack:
-- the bandage moves straight to the main inventory, not one hop per level).
print("\n-- Test 24 (V4.9): depth-2 bandage transfers once, then bandages")
do
    reset()
    local player = MockPlayer.new({ scratched = true, bleeding = false })
    local bandage = bandageItem("Bandage")
    MockContainer.attach(player, MockContainer.new({
        MockContainer.bag("Backpack", {
            MockContainer.bag("FannyPack", { bandage }),
        }),
    }))

    assert_true("depth-2 bandage is treated", AutoPilot_Medical.check(player, false))
    assert_eq("exactly one transfer queued", countType("transfer"), 1)
    assert_eq("action 1 is the transfer", actionTypeAt(1), "transfer")
    assert_eq("action 2 is the bandage", actionTypeAt(2), "bandage")
end

-- 25. A refused transfer (the MP-unsafe path) must degrade quietly and must NOT
-- queue a bandage action on an item the character cannot reach.
print("\n-- Test 25 (V4.9): a refused transfer queues nothing and does not error")
do
    reset()
    local savedTransfer = ISInventoryTransferAction
    ISInventoryTransferAction = {
        new = function() error("PZ refused the transfer") end,
    }

    local player = MockPlayer.new({ scratched = true, bleeding = false })
    MockContainer.attach(player, MockContainer.new({
        MockContainer.bag("FannyPack", { bandageItem("Bandage") }),
    }))

    local ok, result = pcall(function()
        return AutoPilot_Medical.check(player, false)
    end)
    ISInventoryTransferAction = savedTransfer

    assert_true("a refused transfer does not raise", ok)
    assert_false("no treatment is reported", result)
    assert_eq("nothing at all is queued", #ISTimedActionQueue_calls, 0)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
