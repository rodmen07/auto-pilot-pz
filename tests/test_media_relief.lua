-- tests/test_media_relief.lua
-- Behavioural tests for AutoPilot_Media, the television/radio arm of boredom
-- and unhappiness relief.
--
-- The behaviour difference these cases exist to prove: before this arm, a bored
-- character with no book had exactly one answer, walking outdoors.  A working
-- television two rooms away was invisible to the mod (whole-mod grep for
-- IsoWaveSignal / getDeviceData / ISRadioAction returned zero hits).
--
-- Every engine rule asserted here was read live from the 42.19 install:
--   * a world device is `instanceof(obj, "IsoWaveSignal")` with a sprite and no
--     RadioItemID          (client/ISUI/ISRadioAndTvMenu.lua:7)
--   * it can be switched on when battery-powered with charge, or when it
--     canBePoweredHere()   (client/RadioCom/ISRadioAction.lua:39)
--   * it relieves only within +/- 5 tiles on both axes and on the same floor
--                          (shared/RadioCom/ISRadioInteractions.lua:173)
--   * the power button is ISRadioAction:new("ToggleOnOff", char, device)
--                          (client/RadioCom/ISRadioAction.lua:173, RWMPower.lua:58)
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_media_relief.lua

-- ── Load mocks and modules ────────────────────────────────────────────────────
dofile("tests/lua_mock_pz.lua")
dofile("42/media/lua/client/AutoPilot_Constants.lua")
dofile("42/media/lua/client/AutoPilot_Utils.lua")
dofile("42/media/lua/client/AutoPilot_Telemetry.lua")
dofile("42/media/lua/client/AutoPilot_Media.lua")

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
-- A device as the mod sees it.  `_isWaveSignal` is what the shared mock's
-- instanceof keys on, mirroring the engine's IsoWaveSignal parent class that
-- covers both televisions and radios.
local function mockDevice(spec)
    local data = {
        getIsTurnedOn      = function(_self) return spec.on == true end,
        getIsBatteryPowered = function(_self) return spec.battery == true end,
        getPower           = function(_self) return spec.power or 0 end,
        canBePoweredHere   = function(_self) return spec.mains == true end,
        getIsTelevision    = function(_self) return spec.tv == true end,
    }
    return {
        label          = spec.label,
        _isWaveSignal  = spec.notADevice ~= true,
        -- NOT `spec.noSprite and nil or {}`: in Lua that idiom collapses to
        -- {} for every input, because `true and nil` is nil and `nil or {}` is
        -- {}.  Written as a branch so the spriteless case is really spriteless.
        getSprite      = function(_self)
            if spec.noSprite then return nil end
            return {}
        end,
        getModData     = function(_self)
            if spec.radioItemId then return { RadioItemID = 7 } end
            return {}
        end,
        getDeviceData  = function(_self) return data end,
        getSquare      = function(self) return self._square end,
    }
end

-- Publish a world of devices at (dx, dy, dz) offsets from a player at 0,0,0.
local function placeDevices(specs)
    local grid = {}
    for _, spec in ipairs(specs) do
        local dev = mockDevice(spec)
        local sq
        sq = {
            getX = function(_self) return spec.dx or 0 end,
            getY = function(_self) return spec.dy or 0 end,
            getZ = function(_self) return spec.dz or 0 end,
            getObjects = function(_self)
                return {
                    size = function(_s) return 1 end,
                    get  = function(_s, _i) return dev end,
                }
            end,
        }
        dev._square = sq
        spec.obj = dev
        grid[("%d,%d,%d"):format(spec.dx or 0, spec.dy or 0, spec.dz or 0)] = sq
    end
    getCell = function()
        return {
            getGridSquare = function(_self, x, y, z)
                return grid[("%d,%d,%d"):format(x, y, z)]
            end,
        }
    end
    return specs
end

local function emptyWorld()
    getCell = function()
        return { getGridSquare = function(_self, _x, _y, _z) return nil end }
    end
end

-- A character standing at the origin.  AutoPilot_Media reads only position.
local function player()
    return MockPlayer.new({ stats = { BOREDOM = 60 } })
end

-- Each case observes only its own decision: clear the recorded queue, drop the
-- walkAdj stub, and clear the approach cooldown.
local function reset()
    ISTimedActionQueue_calls = {}
    luautils = nil
    AutoPilot_Media.resetCooldownForTest()
    MockTime.advance(120000)
end

local function queuedTypes()
    local types = {}
    for _, call in ipairs(ISTimedActionQueue_calls or {}) do
        local action = call.action or call
        types[#types + 1] = action.type
    end
    return table.concat(types, ",")
end

print("=== AutoPilot media relief (tv/radio) ===")

-- ── 1. Device recognition mirrors the engine's own world-device test ──────────
reset()
local devices = placeDevices({
    { label = "tv", dx = 3, dy = 0, mains = true, tv = true },
})
assert_true("a mains television is recognised as a device",
    AutoPilot_Media.isDeviceObject(devices[1].obj))
assert_false("a non-IsoWaveSignal object is not a device",
    AutoPilot_Media.isDeviceObject(mockDevice({ notADevice = true })))
assert_false("a spriteless object is not a device",
    AutoPilot_Media.isDeviceObject(mockDevice({ noSprite = true })))
assert_false("the world proxy of a placed radio ITEM is skipped",
    AutoPilot_Media.isDeviceObject(mockDevice({ radioItemId = true })))
assert_false("nil is not a device", AutoPilot_Media.isDeviceObject(nil))

-- ── 2. Power test mirrors ISRadioAction:isValidToggleOnOff ────────────────────
reset()
local function dataOf(spec) return mockDevice(spec):getDeviceData() end
assert_true("a mains device can be switched on",
    AutoPilot_Media.canPowerOn(dataOf({ mains = true })))
assert_true("a battery device with charge can be switched on",
    AutoPilot_Media.canPowerOn(dataOf({ battery = true, power = 0.5 })))
assert_false("a battery device with a flat battery cannot",
    AutoPilot_Media.canPowerOn(dataOf({ battery = true, power = 0 })))
assert_false("an unpowered device cannot", AutoPilot_Media.canPowerOn(dataOf({})))

-- ── 3. Broadcast range is the engine's square box, not a radius ───────────────
reset()
local ranged = placeDevices({
    { label = "corner", dx = 5, dy = 5, mains = true },
    { label = "far",    dx = 6, dy = 0, mains = true },
    { label = "upstairs", dx = 0, dy = 0, dz = 1, mains = true },
})
local p = player()
assert_true("a device 5 tiles away on BOTH axes is in range (square box)",
    AutoPilot_Media.inBroadcastRange(p, ranged[1].obj))
assert_false("a device 6 tiles away is out of range",
    AutoPilot_Media.inBroadcastRange(p, ranged[2].obj))
assert_false("a device one floor up is out of range",
    AutoPilot_Media.inBroadcastRange(p, ranged[3].obj))

-- ── 4. A playing device in range means relief is already accruing ────────────
-- The headline anti-starvation case: the arm reports "tuned" and queues
-- NOTHING, so the priority chain keeps running instead of parking the
-- character in front of a television that may be broadcasting no BOR line.
reset()
placeDevices({ { label = "tv", dx = 2, dy = 0, mains = true, on = true, tv = true } })
local queued, state = AutoPilot_Media.doMediaRelief(player())
assert_false("a playing device in range queues no action", queued)
assert_eq("...and reports the tuned state", state, "tuned")
assert_eq("...with an empty action queue", queuedTypes(), "")

-- ── 5. An off device in range is walked to and switched on ───────────────────
reset()
placeDevices({ { label = "tv", dx = 2, dy = 0, mains = true, tv = true } })
local queued5, label5 = AutoPilot_Media.doMediaRelief(player())
assert_true("an off device is acted on", queued5)
assert_eq("...labelled as watching tv", label5, "watching tv")
assert_eq("...queueing a walk then the power toggle", queuedTypes(), "walk,radio")
local toggle = ISTimedActionQueue_calls[2].action or ISTimedActionQueue_calls[2]
assert_eq("...with the engine's own ToggleOnOff mode", toggle.mode, "ToggleOnOff")
assert_eq("...and the media telemetry decision",
    AutoPilot_Telemetry.getPendingAction(), "media")

-- ── 6. A radio is labelled as a radio ────────────────────────────────────────
reset()
placeDevices({ { label = "radio", dx = 2, dy = 0, battery = true, power = 1 } })
local _, label6 = AutoPilot_Media.doMediaRelief(player())
assert_eq("a non-television device is labelled as a radio", label6,
    "listening to radio")

-- ── 7. A playing device OUT of range is approached, not toggled ──────────────
reset()
placeDevices({ { label = "tv", dx = 9, dy = 0, mains = true, on = true, tv = true } })
local queued7 = AutoPilot_Media.doMediaRelief(player())
assert_true("a playing device out of range is approached", queued7)
assert_eq("...with a walk only, never a second toggle", queuedTypes(), "walk")

-- ── 8. Unusable and absent devices are ignored ───────────────────────────────
reset()
emptyWorld()
local queued8, state8 = AutoPilot_Media.doMediaRelief(player())
assert_false("no device means no action", queued8)
assert_eq("...and no tuned claim", tostring(state8), "nil")

reset()
placeDevices({ { label = "dead", dx = 2, dy = 0, battery = true, power = 0 } })
assert_false("a device with no power source is ignored",
    (AutoPilot_Media.doMediaRelief(player())))

reset()
placeDevices({ { label = "tv", dx = 25, dy = 0, mains = true, tv = true } })
assert_false("a device beyond MEDIA_SEARCH_DIST is ignored",
    (AutoPilot_Media.doMediaRelief(player())))

-- ── 9. A playing device is preferred over a nearer switched-off one ──────────
reset()
placeDevices({
    { label = "off-near", dx = 1, dy = 0, mains = true, tv = true },
    { label = "on-far",   dx = 8, dy = 0, mains = true, on = true, tv = true },
})
local obj9, on9 = AutoPilot_Media.findNearbyDevice(player())
assert_true("the already-playing device wins", on9)
assert_eq("...even though it is further away", obj9.label, "on-far")

-- ── 10. walkAdj is preferred, ISWalkToTimedAction is the documented fallback ──
reset()
local walkAdjCalls = 0
luautils = { walkAdj = function(_char, _sq, _keep) walkAdjCalls = walkAdjCalls + 1 end }
placeDevices({ { label = "tv", dx = 3, dy = 0, mains = true, tv = true } })
AutoPilot_Media.doMediaRelief(player())
assert_eq("walkAdj is used when available", walkAdjCalls, 1)
assert_eq("...so no fallback walk action is queued", queuedTypes(), "radio")

-- ── 11. The approach cooldown prevents a walk loop ───────────────────────────
reset()
placeDevices({ { label = "tv", dx = 3, dy = 0, mains = true, tv = true } })
assert_true("the first approach is queued",
    (AutoPilot_Media.doMediaRelief(player())))
ISTimedActionQueue_calls = {}
assert_false("a second approach in the same window is refused",
    (AutoPilot_Media.doMediaRelief(player())))
assert_eq("...queueing nothing", queuedTypes(), "")
MockTime.advance(AutoPilot_Constants.MEDIA_COOLDOWN_MS + 1000)
assert_true("...and is allowed again once the cooldown expires",
    (AutoPilot_Media.doMediaRelief(player())))

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n%d passed, %d failed"):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
