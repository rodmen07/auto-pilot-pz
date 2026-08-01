-- tests/test_mood_during_rest.lua
-- Behavioural tests for mood relief while a rest hold is in progress, and for
-- the literacy gate that kept the reading arm of that relief dead.
--
-- The user-reported bug these cases exist to pin (2026-07-24, "negative
-- moodles / status effects accumulate over long autopilot runs", vitals
-- observed healthy at H:11 T:12 F:18 while the negative-moodle stack grew past
-- six icons) had TWO independent causes, and either one alone is enough to
-- make boredom relief never happen:
--
--   1. WHEN relief is evaluated.  check()'s rest-hold gate (step 6b) returns
--      true without queueing anything, so every cycle spent recovering
--      endurance stopped ABOVE the mood step (step 7).  The V5.4 sit-to-recover
--      loop keeps re-engaging that hold up to ENDURANCE_REST_TARGET, so a
--      healthy, seated character never reached mood at all.
--
--   2. WHETHER reading could ever fire.  doRead gated on a Perks.Literacy
--      SKILL level.  There is no such skill in 42.19 (whole-install grep of
--      media/lua for "Literacy": zero hits), so the lookup was nil, the perk
--      level was never positive, and doRead returned false on EVERY call
--      in-game.  The engine's real gate is the ILLITERATE TRAIT:
--      playerObj:hasTrait(CharacterTrait.ILLITERATE), verified live at
--      client/ISUI/ISInventoryPaneContextMenu.lua:549.
--
-- Reading while seated is engine-sanctioned, not an assumption:
-- shared/TimedActions/ISRestAction.lua:44 carries the comment "Removed this as
-- being an action, this way we can still passively regain endurance and read
-- at the same time".
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_mood_during_rest.lua

-- ── Load mocks ────────────────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")

ISInventoryTransferAction = {
    new = function(_, _player, item, from, to)
        return { type = "transfer", item = item, from = from, to = to }
    end,
}

AutoPilot_Medical = {
    hasCriticalWound = function(_player) return false end,
    check            = function(_player, _bleedingOnly) return false end,
}

AutoPilot_Inventory = {
    findWaterSource       = function(_player) return nil end,
    getBestDrink          = function(_player) return nil end,
    lootNearbyDrink       = function(_player) return false end,
    supplyRunLoot         = function(_player, _pred) end,
    getBestFoodForHunger  = function(_player, _hunger) return nil end,
    selectFoodByWeight    = function(_player) return nil end,
    getBestFood           = function(_player) return nil end,
    lootNearbyFood        = function(_player) return false end,
    getReadable           = function(_player) return nil end,
    lootNearbyReadable    = function(_player) return false end,
    adjustClothing        = function(_player) return false end,
    preferTastyFood       = function(_player) return nil end,
    refillWaterContainer  = function(_player, _src) end,
    drinkFromSource       = function(_player, _src) return true end,
    equipBestExerciseItem = function(_player) return "none" end,
    bodyTemperature       = function(_player) return 0 end,
}

dofile("42/media/lua/client/AutoPilot_Utils.lua")
AutoPilot_Utils.iterateNearbySquares = function(_cx, _cy, _cz, _radius, _cb) end

AutoPilot_Home = {
    isSet            = function(_player) return false end,
    isInside         = function(_sq) return false end,
    getNearestInside = function(_player, _pred) return nil end,
}

dofile("42/media/lua/client/AutoPilot_Media.lua")
dofile("42/media/lua/client/AutoPilot_Consumption.lua")
dofile("42/media/lua/client/AutoPilot_Sleep.lua")
dofile("42/media/lua/client/AutoPilot_Rest.lua")
dofile("42/media/lua/client/AutoPilot_Exercise.lua")
-- Loader plumbing only (code-health split, 2026-08-01): doMoodRelief and its
-- two private arms moved out of AutoPilot_Needs into AutoPilot_Mood.  No test
-- case, stub or assertion below changed.
dofile("42/media/lua/client/AutoPilot_Mood.lua")
dofile("42/media/lua/client/AutoPilot_Needs.lua")

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
local function book(name)
    return {
        getName            = function(_self) return name end,
        getNumberOfPages   = function(_self) return 100 end,
        getAlreadyReadPages = function(_self) return 0 end,
    }
end

-- A character with nothing urgent wrong: not hungry, thirsty, tired, hurt or
-- exhausted enough for any earlier step to claim the cycle.  Endurance sits
-- BELOW ENDURANCE_REST_TARGET so the rest hold keeps holding, and ABOVE
-- ENDURANCE_REST_MIN so step 6 does not queue a fresh rest first.
local function restingPlayer(cfg)
    cfg = cfg or {}
    local target = AutoPilot_Constants.ENDURANCE_REST_TARGET
    return MockPlayer.new({
        stats = {
            HUNGER    = 0.05,
            THIRST    = 0.05,
            FATIGUE   = 0.05,
            ENDURANCE = cfg.endurance or (target - 0.10),
            BOREDOM   = cfg.boredom or 0,
            SANITY    = 0,
        },
        moodles = { ENDURANCE = 0, UNHAPPY = cfg.unhappy or 0 },
        traits  = cfg.traits,
        tooDark = cfg.tooDark,
    })
end

-- Put a rest hold in flight, exactly as doRest does, and return the check()
-- result for a player that is sitting it out.
local function checkWhileHolding(player)
    ISTimedActionQueue_calls = {}
    AutoPilot_Rest.clearRestHold()
    AutoPilot_Rest.extendRestHold(getGameTime():getCalender():getTimeInMillis())
    return AutoPilot_Needs.check(player)
end

local function last_action_type()
    local c = ISTimedActionQueue_calls
    if #c == 0 then return nil end
    return c[#c].type
end

local function count_type(t)
    local n = 0
    for _, call in ipairs(ISTimedActionQueue_calls or {}) do
        if call.type == t then n = n + 1 end
    end
    return n
end

local function reset()
    MockTime.advance(120000)
    AutoPilot_Inventory.getReadable        = function(_player) return nil end
    AutoPilot_Inventory.lootNearbyReadable = function(_player) return false end
    AutoPilot_Inventory.preferTastyFood    = function(_player) return nil end
end

print("=== Mood relief during a rest hold ===")

-- ── 1. HEADLINE: a bored, seated character reads instead of idling ───────────
print("\n-- Test 1: bored while holding a rest -> reads without standing up")
do
    reset()
    local b = book("Fishing Magazine")
    AutoPilot_Inventory.getReadable = function(_player) return b, nil end
    local player = restingPlayer({ boredom = AutoPilot_Constants.BOREDOM_THRESHOLD + 10 })

    local result = checkWhileHolding(player)
    assert_true("check() still returns true (the rest continues)", result)
    assert_eq("a read action is queued during the hold", last_action_type(), "read")
    assert_true("the rest hold is NOT cleared by reading",
        AutoPilot_Rest.isRestHoldActive(getGameTime():getCalender():getTimeInMillis()))
    assert_eq("the HUD says the character is resting AND reading",
        AutoPilot_Needs.getActivityOutcome(), "resting (reading)")
end

-- ── 2. Unhappy while seated -> tasty food, still without standing up ─────────
print("\n-- Test 2: unhappy while holding a rest -> eats tasty food")
do
    reset()
    local cake = { getName = function(_s) return "Cake" end,
                   getCalories = function(_s) return 500 end }
    AutoPilot_Inventory.preferTastyFood = function(_player) return cake, nil end
    local player = restingPlayer({ unhappy = AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD })

    local result = checkWhileHolding(player)
    assert_true("check() still returns true", result)
    assert_eq("an eat action is queued during the hold", last_action_type(), "eat")
    assert_eq("the HUD says resting (eating)",
        AutoPilot_Needs.getActivityOutcome(), "resting (eating)")
end

-- ── 3. A contented seated character still just rests ─────────────────────────
print("\n-- Test 3: no boredom, no unhappiness -> the hold behaves exactly as before")
do
    reset()
    AutoPilot_Inventory.getReadable = function(_player) return book("Novel"), nil end
    local player = restingPlayer({ boredom = 0, unhappy = 0 })

    local result = checkWhileHolding(player)
    assert_true("check() returns true (still resting)", result)
    assert_eq("nothing is queued", #ISTimedActionQueue_calls, 0)
    assert_eq("the HUD keeps the plain recovery text",
        AutoPilot_Needs.getActivityOutcome(), "resting (recovering endurance)")
end

-- ── 4. Seated relief must never WALK ─────────────────────────────────────────
print("\n-- Test 4: seated relief never loots and never walks outside")
do
    reset()
    local looted = false
    AutoPilot_Inventory.getReadable        = function(_player) return nil end
    AutoPilot_Inventory.lootNearbyReadable = function(_player)
        looted = true
        return true
    end
    local player = restingPlayer({ boredom = AutoPilot_Constants.BOREDOM_THRESHOLD + 10 })

    local result = checkWhileHolding(player)
    assert_true("check() returns true (the rest is held)", result)
    assert_false("lootNearbyReadable is NOT called while seated", looted)
    assert_eq("no walk action is queued", count_type("walk"), 0)
    assert_eq("the HUD falls back to the plain recovery text",
        AutoPilot_Needs.getActivityOutcome(), "resting (recovering endurance)")
end

-- ── 5. The standing path keeps its walking fallbacks ─────────────────────────
print("\n-- Test 5: with no rest hold, the mood step still loots a book")
do
    reset()
    local looted = false
    AutoPilot_Inventory.getReadable        = function(_player) return nil end
    AutoPilot_Inventory.lootNearbyReadable = function(_player)
        looted = true
        return true
    end
    ISTimedActionQueue_calls = {}
    AutoPilot_Rest.clearRestHold()
    local player = restingPlayer({
        endurance = 0.99,   -- above the rest target: no hold, no sit-to-recover
        boredom   = AutoPilot_Constants.BOREDOM_THRESHOLD + 10,
    })

    local result = AutoPilot_Needs.check(player)
    assert_true("check() returns true", result)
    assert_true("lootNearbyReadable IS called when standing", looted)
end

print("\n=== Literacy gate (the reading arm's second cause) ===")

-- ── 6. A character with no Illiterate trait can read ─────────────────────────
print("\n-- Test 6: default character is literate and reads")
do
    reset()
    AutoPilot_Inventory.getReadable = function(_player) return book("Novel"), nil end
    local player = restingPlayer({ boredom = AutoPilot_Constants.BOREDOM_THRESHOLD + 10 })

    checkWhileHolding(player)
    assert_eq("a read action is queued for a literate character",
        last_action_type(), "read")
end

-- ── 7. The Illiterate trait still blocks reading ─────────────────────────────
print("\n-- Test 7: the Illiterate trait blocks reading (negative control)")
do
    reset()
    AutoPilot_Inventory.getReadable = function(_player) return book("Novel"), nil end
    local player = restingPlayer({
        boredom = AutoPilot_Constants.BOREDOM_THRESHOLD + 10,
        traits  = { [CharacterTrait.ILLITERATE] = true },
    })

    local result = checkWhileHolding(player)
    assert_true("check() still returns true (rest continues)", result)
    assert_eq("no read action is queued", count_type("read"), 0)
end

-- ── 8. Darkness still blocks reading ─────────────────────────────────────────
print("\n-- Test 8: too dark to read blocks reading")
do
    reset()
    AutoPilot_Inventory.getReadable = function(_player) return book("Novel"), nil end
    local player = restingPlayer({
        boredom = AutoPilot_Constants.BOREDOM_THRESHOLD + 10,
        tooDark = true,
    })

    checkWhileHolding(player)
    assert_eq("no read action is queued in the dark", count_type("read"), 0)
end

-- ── 9. The literacy check fails OPEN ─────────────────────────────────────────
print("\n-- Test 9: an unreadable trait surface assumes literate, not illiterate")
do
    reset()
    AutoPilot_Inventory.getReadable = function(_player) return book("Novel"), nil end
    local player = restingPlayer({ boredom = AutoPilot_Constants.BOREDOM_THRESHOLD + 10 })
    -- Engine surface missing entirely (an older build, or a Java-side error):
    -- the pcall fails, and the mod must not conclude "illiterate" from that.
    player.hasTrait = nil

    checkWhileHolding(player)
    assert_eq("a read action is still queued when the trait cannot be read",
        last_action_type(), "read")
end

print("\n=== Media relief, the third arm (reached from check(), not just unit-tested) ===")

-- AutoPilot_Media's own rules are covered in tests/test_media_relief.lua.  What
-- these three cases exist to prove is the WIRING: that check() actually reaches
-- the arm when reading fails, and that a device already playing in range stops
-- the character walking outdoors (walking outdoors forfeits media relief
-- outright, because ISRadioInteractions.checkPlayer returns early when the
-- device square and the player square disagree on isOutside()).
local _decisions = {}
local function recordDecisions()
    _decisions = {}
    AutoPilot_Telemetry.setDecision = function(action, _reason)
        _decisions[#_decisions + 1] = action
    end
end
local function decided(action)
    for _, a in ipairs(_decisions) do
        if a == action then return true end
    end
    return false
end

-- A television at (dx, 0) that is either playing or switched off.  Every other
-- square stays empty, exactly as the default mock cell behaves.
local function placeTelevision(dx, isOn)
    local data = {
        getIsTurnedOn       = function(_self) return isOn == true end,
        getIsBatteryPowered = function(_self) return false end,
        getPower            = function(_self) return 0 end,
        canBePoweredHere    = function(_self) return true end,
        getIsTelevision     = function(_self) return true end,
    }
    local dev
    local sq = {
        getX = function(_self) return dx end,
        getY = function(_self) return 0 end,
        getZ = function(_self) return 0 end,
        getObjects = function(_self)
            return { size = function(_s) return 1 end,
                     get  = function(_s, _i) return dev end }
        end,
    }
    dev = {
        _isWaveSignal = true,
        getSprite     = function(_self) return {} end,
        getModData    = function(_self) return {} end,
        getDeviceData = function(_self) return data end,
        getSquare     = function(_self) return sq end,
    }
    getCell = function()
        return {
            getGridSquare = function(_self, x, y, z)
                if x == dx and y == 0 and z == 0 then return sq end
                return nil
            end,
        }
    end
end

local function noDevices()
    getCell = function()
        return { getGridSquare = function(_self, _x, _y, _z) return nil end }
    end
end

-- A bored character standing up (endurance above the rest target, so no hold
-- and no sit-to-recover) with nothing to read anywhere.
local function boredStandingPlayer()
    return restingPlayer({
        endurance = 0.99,
        boredom   = AutoPilot_Constants.BOREDOM_THRESHOLD + 10,
    })
end

-- ── 10. check() reaches the media arm when reading is unavailable ────────────
print("\n-- Test 10: bored, no book, a tv two tiles away -> switches it on")
do
    reset()
    recordDecisions()
    AutoPilot_Media.resetCooldownForTest()
    ISTimedActionQueue_calls = {}
    AutoPilot_Rest.clearRestHold()
    placeTelevision(2, false)

    AutoPilot_Needs.check(boredStandingPlayer())
    assert_true("the media decision is recorded", decided("media"))
    assert_eq("the power toggle is queued", count_type("radio"), 1)
    assert_false("and the character does not walk outdoors", decided("outside"))
end

-- ── 11. A playing device in range keeps the character indoors ────────────────
print("\n-- Test 11: a tv already playing in range suppresses going outdoors")
do
    reset()
    recordDecisions()
    AutoPilot_Media.resetCooldownForTest()
    ISTimedActionQueue_calls = {}
    AutoPilot_Rest.clearRestHold()
    placeTelevision(2, true)

    AutoPilot_Needs.check(boredStandingPlayer())
    assert_false("no outdoor decision is taken", decided("outside"))
    assert_eq("nothing is queued for the device it is already receiving",
        count_type("radio"), 0)
end

-- ── 12. Negative control: with no device, the mod still goes outdoors ────────
print("\n-- Test 12: no device -> the pre-existing outdoor arm still fires")
do
    reset()
    recordDecisions()
    AutoPilot_Media.resetCooldownForTest()
    ISTimedActionQueue_calls = {}
    AutoPilot_Rest.clearRestHold()
    noDevices()

    AutoPilot_Needs.check(boredStandingPlayer())
    assert_true("the outdoor decision is taken when there is no device",
        decided("outside"))
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
