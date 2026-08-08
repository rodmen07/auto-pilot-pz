-- tests/test_sleep_comfort.lua
-- Behavioural tests for the V0.2 sleep-comfort rule.
--
-- Product decision (user, 2026-07-24, recorded in the backlog's rest/sleep
-- furniture entry): for SLEEPING, prioritise by COMFORT (bed quality); for
-- RESTING, all seating is equal and nearest wins.  The resting half shipped in
-- PR #69; this suite pins the sleeping half — AutoPilot_Sleep.bedComfort and the
-- comfort-first ordering inside _findBedNearby.
--
-- The behaviour difference these cases exist to prove: before V0.2 doSleep took
-- the NEAREST bed, so a mattress on the floor one tile away beat a proper bed
-- ten tiles away.  Test 4 is the headline: reverting _findBedNearby to
-- nearest-wins flips it to the bad bed.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_sleep_comfort.lua

-- ── Load mocks and modules ────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")
dofile("42/media/lua/client/AutoPilot_Utils.lua")

-- doSleep's no-bed branch asks whether a home is anchored; its pain branch asks
-- Medical for a treatment.  Neither is under test here, so both are stubbed to
-- the "nothing available" answer.
AutoPilot_Home    = { isSet = function(_player) return false end }
AutoPilot_Medical = { check = function(_player, _force) return false end }

dofile("42/media/lua/client/AutoPilot_Sleep.lua")

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

-- ── World builder ─────────────────────────────────────────────────────────────
-- A bed object as the mod sees it: the sprite carries IsoFlagType.bed (what
-- getBedObjectOnSquare tests for) and the object carries the BedType property
-- (what the engine's getBedQuality reads, ISWorldObjectContextMenu.lua:2958).
local function mockBed(label, bedType, pillow)
    local props = {
        has = function(_self, flag) return flag == IsoFlagType.bed end,
        get = function(_self, key)
            if key == "BedType" then return bedType end
            return nil
        end,
    }
    return {
        label        = label,
        _pillow      = pillow == true,
        getSprite    = function(_self) return { getProperties = function(_s) return props end } end,
        getProperties = function(_self) return props end,
        getSquare    = function(self) return self._square end,
    }
end

-- Publish a world of beds at (dx, dy, dz) offsets from the player at 0,0,0.
-- Every other grid square is empty, exactly as the default mock cell behaves.
local function placeBeds(beds)
    local grid = {}
    for _, spec in ipairs(beds) do
        local bed = mockBed(spec.label, spec.bedType, spec.pillow)
        local sq = {
            getObjects = function(_self)
                return {
                    size = function(_s) return 1 end,
                    get  = function(_s, _i) return bed end,
                }
            end,
        }
        bed._square = sq
        spec.obj = bed
        grid[("%d,%d,%d"):format(spec.dx or 0, spec.dy or 0, spec.dz or 0)] = sq
    end
    getCell = function()
        return {
            getGridSquare = function(_self, x, y, z)
                return grid[("%d,%d,%d"):format(x, y, z)]
            end,
        }
    end
    return beds
end

local function noBeds()
    getCell = function()
        return { getGridSquare = function(_self, _x, _y, _z) return nil end }
    end
end

-- A character whose only problem is fatigue.
local function sleepyPlayer()
    return MockPlayer.new({
        stats = { HUNGER = 0.02, THIRST = 0.02, FATIGUE = 0.80, ENDURANCE = 0.90,
                  PAIN = 0 },
        moodles = { PAIN = 0, PANIC = 0 },
    })
end

-- doSleep debounces re-queues on the GAME calendar; step past that deadline
-- and clear the recorded queue so each case observes only its own decision.
-- 2026-08-08: this advance was a flat 60000 chosen to clear a hard-coded
-- `ms + 15000`.  That 15 GAME seconds was SHORTER than one evaluation cycle
-- (~18000 game ms at the default day length), i.e. the guard had always
-- expired before doSleep next ran and could never gate anything.  The deadline
-- is now AutoPilot_Constants.SLEEP_RETRY_COOLDOWN_MS and this helper is
-- derived from it rather than from a literal, so the fixture cannot silently
-- fall back under the deadline the next time the constant moves.
local function reset()
    MockTime.advance(AutoPilot_Constants.SLEEP_RETRY_COOLDOWN_MS + 1)
    ISTimedActionQueue_calls = {}
    -- The bed is chosen only when the character can reach it; asserting on the
    -- CHOICE means taking the adjacent branch, which passes the bed straight to
    -- onSleepWalkToComplete (the mock records it).
    AdjacentFreeTileFinder.isTileOrAdjacent = function(_a, _b) return true end
end

-- The bed the mod actually decided to sleep in, or nil.
local function chosenBed()
    for i = #ISTimedActionQueue_calls, 1, -1 do
        local call = ISTimedActionQueue_calls[i]
        if call.type == "sleep" then return call.bed end
    end
    return nil
end

print("=== AutoPilot_Sleep comfort tests (V0.2) ===")

-- ── bedComfort ranking ────────────────────────────────────────────────────────

print("\n-- Test 1: the engine's bed grades rank good > average > bad > floor")
do
    local player  = sleepyPlayer()
    local good    = mockBed("good",    "goodBed")
    local average = mockBed("average", "averageBed")
    local bad     = mockBed("bad",     "badBed")

    local rGood    = AutoPilot_Sleep.bedComfort(player, good)
    local rAverage = AutoPilot_Sleep.bedComfort(player, average)
    local rBad     = AutoPilot_Sleep.bedComfort(player, bad)
    local rFloor   = AutoPilot_Sleep.bedComfort(player, nil)

    assert_true("goodBed outranks averageBed",  rGood > rAverage)
    assert_true("averageBed outranks badBed",   rAverage > rBad)
    assert_true("badBed outranks the floor",    rBad > rFloor)
end

print("\n-- Test 2: a pillow improves the same bed but never promotes its grade")
do
    local player     = sleepyPlayer()
    local bad        = mockBed("bad",        "badBed")
    local badPillow  = mockBed("badPillow",  "badBed", true)
    local average    = mockBed("average",    "averageBed")

    local rBad       = AutoPilot_Sleep.bedComfort(player, bad)
    local rBadPillow = AutoPilot_Sleep.bedComfort(player, badPillow)
    local rAverage   = AutoPilot_Sleep.bedComfort(player, average)

    assert_true("a pillow raises the rank of the same bed", rBadPillow > rBad)
    assert_true("a pillowed bad bed still loses to an average bed",
        rBadPillow < rAverage)
end

print("\n-- Test 3: an unknown/modded bed type ranks as average, never as bad")
do
    local player  = sleepyPlayer()
    local modded  = mockBed("modded",  "SuperDeluxeBunk")
    local average = mockBed("average", "averageBed")
    local bad     = mockBed("bad",     "badBed")

    local rModded = AutoPilot_Sleep.bedComfort(player, modded)
    assert_eq("an unrecognised bed type ranks exactly as average",
        rModded, AutoPilot_Sleep.bedComfort(player, average))
    assert_true("an unrecognised bed type outranks a bad bed",
        rModded > AutoPilot_Sleep.bedComfort(player, bad))
end

-- ── Selection behaviour (the V0.2 difference) ─────────────────────────────────

print("\n-- Test 4 (HEADLINE): a better bed 10 tiles away beats a bad bed next door")
do
    reset()
    local beds = placeBeds({
        { label = "bad_near",  bedType = "badBed",  dx = 1,  dy = 0 },
        { label = "good_far",  bedType = "goodBed", dx = 10, dy = 0 },
    })
    local queued = AutoPilot_Sleep.doSleep(sleepyPlayer())
    assert_true("doSleep queues a sleep when a bed is reachable", queued)
    -- Before V0.2 this returned the bad bed: selection was nearest-wins.
    assert_eq("the GOOD bed is chosen over the nearer BAD one",
        chosenBed(), beds[2].obj)
end

print("\n-- Test 5: equal comfort still falls back to nearest (V0.1 behaviour kept)")
do
    reset()
    local beds = placeBeds({
        { label = "far",  bedType = "averageBed", dx = 12, dy = 0 },
        { label = "near", bedType = "averageBed", dx = 2,  dy = 0 },
    })
    AutoPilot_Sleep.doSleep(sleepyPlayer())
    assert_eq("with equal quality the nearest bed wins", chosenBed(), beds[2].obj)
end

print("\n-- Test 6: comfort outranks the floor penalty (a good bed upstairs wins)")
do
    reset()
    local beds = placeBeds({
        { label = "bad_here",     bedType = "badBed",  dx = 1, dy = 0, dz = 0 },
        { label = "good_upstair", bedType = "goodBed", dx = 1, dy = 0, dz = 1 },
    })
    AutoPilot_Sleep.doSleep(sleepyPlayer())
    assert_eq("a good bed one floor up beats a bad bed on this floor",
        chosenBed(), beds[2].obj)
end

print("\n-- Test 7: same comfort on two floors still prefers this floor")
do
    reset()
    local beds = placeBeds({
        { label = "up",   bedType = "averageBed", dx = 1, dy = 0, dz = 1 },
        { label = "here", bedType = "averageBed", dx = 4, dy = 0, dz = 0 },
    })
    AutoPilot_Sleep.doSleep(sleepyPlayer())
    assert_eq("the floor penalty still breaks a comfort tie",
        chosenBed(), beds[2].obj)
end

-- ── Degradation when the engine surface moves ────────────────────────────────

print("\n-- Test 8: getBedQuality absent → falls back to the BedType property")
do
    reset()
    local saved = ISWorldObjectContextMenu.getBedQuality
    ISWorldObjectContextMenu.getBedQuality = nil
    local beds = placeBeds({
        { label = "bad_near", bedType = "badBed",  dx = 1, dy = 0 },
        { label = "good_far", bedType = "goodBed", dx = 9, dy = 0 },
    })
    AutoPilot_Sleep.doSleep(sleepyPlayer())
    assert_eq("comfort still ranks through the raw BedType property",
        chosenBed(), beds[2].obj)
    ISWorldObjectContextMenu.getBedQuality = saved
end

print("\n-- Test 9: no quality signal at all → nearest wins, nothing errors")
do
    reset()
    local saved = ISWorldObjectContextMenu.getBedQuality
    ISWorldObjectContextMenu.getBedQuality = nil
    local beds = placeBeds({
        { label = "far",  bedType = nil, dx = 11, dy = 0 },
        { label = "near", bedType = nil, dx = 3,  dy = 0 },
    })
    local queued = AutoPilot_Sleep.doSleep(sleepyPlayer())
    assert_true("doSleep still queues a sleep with no quality signal", queued)
    assert_eq("with no signal every bed ties and the nearest wins",
        chosenBed(), beds[2].obj)
    ISWorldObjectContextMenu.getBedQuality = saved
end

print("\n-- Test 10: no bed at all is still 'no sleep', not a crash")
do
    reset()
    noBeds()
    local queued = AutoPilot_Sleep.doSleep(sleepyPlayer())
    assert_false("doSleep returns false when no bed is in range", queued)
    assert_eq("nothing is queued when no bed is in range", chosenBed(), nil)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
