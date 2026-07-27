-- AutoPilot_Media.lua
-- Boredom / unhappiness relief from a switched-on television or radio.
--
-- WHY THIS EXISTS.  The user's 2026-07-24 in-game report ("negative moodles
-- accumulate over long autopilot runs, vitals healthy") listed three causes;
-- the third was THIN RELIEF: "doRead needs a book in inventory, and there is a
-- TV/radio in the room the mod never uses for boredom relief".  Verified
-- before writing this file, whole-mod grep over 42/media/lua/client for
-- "IsoWaveSignal|IsoRadio|getDeviceData|ISRadioAction|DeviceData" -> ZERO
-- hits, so the mod had no media surface at all.  Reading and walking outdoors
-- were its only two boredom answers, and both can be unavailable (no book, and
-- outdoors is where the zombies are).
--
-- THE RELIEF IS REAL, NOT ASSUMED.  It is the engine's own broadcast-code
-- system, verified live against the 42.19 install:
--
--   Events.OnDeviceText -> ISRadioInteractions.OnDeviceText
--     (shared/RadioCom/ISRadioInteractions.lua:341) fires per broadcast line;
--   it forwards to checkPlayer ONLY when playerInRange (line 173) holds, which
--     is: math.floor(playerZ) == math.floor(deviceZ), and the player within
--     +/- 5 tiles of the device on BOTH axes -- a square box, not a radius;
--   checkPlayer (line 182) then runs the line's codes, and
--     Interactions.BOR (line 93) -> applyBoredom -> stats:add(
--     CharacterStat.BOREDOM, amount * 5).
--
--   media/radio/RadioData.xml carries 3729 LineEntry elements with a BOR-1
--   (boredom-reducing) code, plus 802+ UHP-1 (unhappiness) and 402+ STS-1
--   (stress) lines.  Counted live with
--     grep -c 'codes="BOR' media/radio/RadioData.xml
--   So a switched-on device in range really does drain the two moodles this
--   mod's relief arm exists to treat.  (Checking this FIRST is the lesson of
--   PRs #77 and #78, where two relief arms turned out to have been dead in-game
--   since the B42 port because nobody checked the engine surface they read.)
--
-- HONEST LIMITS, recorded here rather than discovered later:
--   * checkPlayer skips a line the character already heard
--     (player:isKnownMediaLine(guid), line 194), so a single device gives
--     DIMINISHING returns over a long run -- it is a relief source, not an
--     infinite one.  The stall backoff below exists for exactly this: when a
--     tuned stretch runs a full MEDIA_STALL_WINDOW_MS without boredom falling,
--     the arm stops claiming relief for MEDIA_STALL_BACKOFF_MS so the outdoor
--     walk can run instead of being suppressed by a device that has gone dry.
--   * checkPlayer returns early when the device square and the player square
--     disagree on isOutside() (line 186), which is exactly why the caller
--     refuses to walk outdoors while a live device is in range.
--   * A device that is on but tuned to a dead channel broadcasts nothing.  The
--     mod does not tune channels: SetChannel needs a frequency the mod has no
--     verified way to choose, so it leaves whatever the world or the user set.
--   * Whether a playing device attracts zombies is a JAVA-side question with no
--     Lua evidence either way (grep for WorldSound/addSound under
--     client/RadioCom and shared/RadioCom finds only ISSLSounds' own audio
--     bookkeeping).  Not claimed in either direction; filed as a follow-up.
--
-- SPLITSCREEN NOTE: _mediaCooldownMs is module-level and therefore shared
-- across local players, the same accepted limitation as every other cooldown in
-- this mod (see AutoPilot_Sleep.sleepCooldownMs).  Splitscreen is NOT supported.

local function _apNoop(...) end
local print = _apNoop

AutoPilot_Media = {}

local MEDIA_SEARCH_DIST      = AutoPilot_Constants.MEDIA_SEARCH_DIST
local MEDIA_BROADCAST_RANGE  = AutoPilot_Constants.MEDIA_BROADCAST_RANGE
local MEDIA_COOLDOWN_MS      = AutoPilot_Constants.MEDIA_COOLDOWN_MS
local MEDIA_STALL_WINDOW_MS  = AutoPilot_Constants.MEDIA_STALL_WINDOW_MS
local MEDIA_STALL_BACKOFF_MS = AutoPilot_Constants.MEDIA_STALL_BACKOFF_MS
local MEDIA_STALL_MIN_OBS    = AutoPilot_Constants.MEDIA_STALL_MIN_OBS

-- Guards against re-walking to the same device every cycle when the toggle does
-- not take (no power at this spot, an interrupted walk, a device someone else
-- switches back off).  Only the QUEUEING path takes the cooldown; detection is
-- never cooled down, so the caller's "do not walk outdoors" answer stays true
-- while the cooldown runs.
local _mediaCooldownMs = 0

local function _nowMs()
    local ok, ms = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    return (ok and ms) or 0
end

--- Reset the queue cooldown.  Tests only; production never needs it.
function AutoPilot_Media.resetCooldownForTest()
    _mediaCooldownMs = 0
end

-- ── Stall detection ("this device stopped helping") ──────────────────────────
-- Module-level like _mediaCooldownMs, with the same accepted splitscreen
-- limitation.  The state is device-agnostic on purpose: the arm as a whole is
-- what the priority chain consults, and a world with several devices in one
-- broadcast-heard pool stalls together anyway (isKnownMediaLine is per
-- character, not per device).
local _stallSinceMs    = 0   -- window start (0 = no window open)
local _stallLastSeenMs = 0   -- last tuned observation, for streak-break detection
local _stallBaseline   = 0   -- normalised boredom at window start
local _stallObs        = 0   -- tuned observations inside the current window
local _stallUntilMs    = 0   -- backoff active until this game time

--- Reset the stall state.  Tests only; production never needs it.
function AutoPilot_Media.resetStallForTest()
    _stallSinceMs, _stallLastSeenMs, _stallBaseline = 0, 0, 0
    _stallObs, _stallUntilMs = 0, 0
end

-- Scale-agnostic malus reading (the V6.0 hard requirement).  BOREDOM is 0-100
-- in 42.19 (CharacterStatScale in tests/lua_mock_pz.lua), but every threshold
-- here normalises defensively so an engine rescale can neither kill the gate
-- nor make it permanent.
local function _norm01(v)
    if v > 1 then v = v / 100 end
    return v
end

-- The smallest boredom fall that counts as "the device is helping": half a
-- point on the 0-100 scale.  A single BOR-coded line applies amount * 5
-- (ISRadioInteractions.Interactions.BOR), so real relief clears this easily;
-- the epsilon only filters float noise.
local STALL_EPSILON = 0.005

--- One tuned observation.  Returns "stalled" on the cycle that declares a
--- stall (and arms the backoff), nil otherwise.
local function _noteTuned(player, ms)
    local b = _norm01(AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM))

    -- Below the boredom threshold there is nothing for this arm to relieve on
    -- the axis it measures, so tuned time is not evidence in either direction
    -- (the unhappy-only path lands here: UHP lines may still be helping).
    if b < _norm01(AutoPilot_Constants.BOREDOM_THRESHOLD) then
        _stallSinceMs, _stallObs = 0, 0
        _stallLastSeenMs = ms
        return nil
    end

    -- No window open, or the tuned streak broke (the character walked away,
    -- the device lost power, boredom dipped below threshold for a while):
    -- start measuring fresh rather than judging a stale baseline.
    if _stallSinceMs == 0 or (ms - _stallLastSeenMs) > MEDIA_STALL_WINDOW_MS then
        _stallSinceMs, _stallBaseline, _stallObs = ms, b, 1
        _stallLastSeenMs = ms
        return nil
    end

    _stallLastSeenMs = ms
    _stallObs = _stallObs + 1

    if b <= _stallBaseline - STALL_EPSILON then
        -- Boredom is falling: the device is helping.  Re-baseline so the next
        -- stall verdict measures from here, and keep watching.
        _stallSinceMs, _stallBaseline, _stallObs = ms, b, 1
        return nil
    end

    if (ms - _stallSinceMs) >= MEDIA_STALL_WINDOW_MS
        and _stallObs >= MEDIA_STALL_MIN_OBS then
        -- A full window of tuned game time, enough decision cycles to trust
        -- it, and boredom never fell: exhausted lines or a dead channel.
        _stallSinceMs, _stallObs = 0, 0
        _stallUntilMs = ms + MEDIA_STALL_BACKOFF_MS
        return "stalled"
    end

    return nil
end

--- The device-data handle for a world object, or nil.
local function _deviceData(obj)
    local ok, dd = pcall(function() return obj:getDeviceData() end)
    if ok then return dd end
    return nil
end

--- Is this world object a television or radio the mod may operate?
---
--- Mirrors the engine's own world-device test in
--- ISRadioAndTvMenu.createMenu (client/ISUI/ISRadioAndTvMenu.lua:7):
---   instanceof(object, "IsoWaveSignal") and object:getSprite()
---     and not object:getModData().RadioItemID
--- IsoWaveSignal is the parent class covering both radios and televisions, and
--- the RadioItemID exclusion skips the world proxy of a PLACED radio ITEM,
--- which the engine drives through a different path.
function AutoPilot_Media.isDeviceObject(obj)
    if not obj then return false end
    local ok, isDevice = pcall(function()
        return instanceof(obj, "IsoWaveSignal")
            and obj:getSprite() ~= nil
            and not obj:getModData().RadioItemID
    end)
    return ok and isDevice == true
end

--- Is the device currently switched on?
function AutoPilot_Media.isTurnedOn(deviceData)
    if not deviceData then return false end
    local ok, on = pcall(function() return deviceData:getIsTurnedOn() end)
    return ok and on == true
end

--- Can this device be switched on where it stands?
---
--- Mirrors ISRadioAction:isValidToggleOnOff verbatim
--- (client/RadioCom/ISRadioAction.lua:39):
---   deviceData:getIsBatteryPowered() and deviceData:getPower() > 0
---     or deviceData:canBePoweredHere()
--- so the mod never queues a toggle the engine's own action would refuse: a
--- battery device needs charge, a mains device needs grid or generator power.
function AutoPilot_Media.canPowerOn(deviceData)
    if not deviceData then return false end
    local ok, usable = pcall(function()
        return (deviceData:getIsBatteryPowered() and deviceData:getPower() > 0)
            or deviceData:canBePoweredHere() == true
    end)
    return ok and usable == true
end

--- Would the character receive this device's broadcasts right now?
---
--- Mirrors ISRadioInteractions.playerInRange
--- (shared/RadioCom/ISRadioInteractions.lua:173): same floor after math.floor,
--- and within MEDIA_BROADCAST_RANGE on BOTH axes independently.  It is a square
--- box in the engine, so it is a square box here; approximating it with a
--- radius would claim relief on corners the engine excludes.
function AutoPilot_Media.inBroadcastRange(player, obj)
    if not (player and obj) then return false end
    local ok, inRange = pcall(function()
        local sq = obj:getSquare()
        if not sq then return false end
        if math.floor(player:getZ()) ~= math.floor(sq:getZ()) then return false end
        local px, py = player:getX(), player:getY()
        local dx, dy = sq:getX(), sq:getY()
        return px >= dx - MEDIA_BROADCAST_RANGE and px <= dx + MEDIA_BROADCAST_RANGE
           and py >= dy - MEDIA_BROADCAST_RANGE and py <= dy + MEDIA_BROADCAST_RANGE
    end)
    return ok and inRange == true
end

--- Find the most useful television or radio near the character.
---
--- Scans the character's OWN FLOOR only, bounded by MEDIA_SEARCH_DIST.  That is
--- not a scan-cost shortcut: playerInRange requires the same floor, so a device
--- one storey up relieves nothing until the character is already up there, and
--- a multi-floor scan would only produce walks to devices that cannot help.
---
--- Preference order: a device already PLAYING first (no toggle needed, and it
--- is already broadcasting), then the nearest.  Returns (object, isOn) or nil.
function AutoPilot_Media.findNearbyDevice(player)
    local okPos, px, py, pz = pcall(function()
        return player:getX(), player:getY(), player:getZ()
    end)
    if not okPos then return nil end

    local best, bestOn, bestDist = nil, false, math.huge
    for dx = -MEDIA_SEARCH_DIST, MEDIA_SEARCH_DIST do
        for dy = -MEDIA_SEARCH_DIST, MEDIA_SEARCH_DIST do
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            if sq then
                local okObjs, objs = pcall(function() return sq:getObjects() end)
                local count = 0
                if okObjs and objs then
                    local okSize, size = pcall(function() return objs:size() end)
                    count = (okSize and size) or 0
                end
                for i = 0, count - 1 do
                    local okGet, obj = pcall(function() return objs:get(i) end)
                    if okGet and AutoPilot_Media.isDeviceObject(obj) then
                        local dd = _deviceData(obj)
                        local on = AutoPilot_Media.isTurnedOn(dd)
                        if dd and (on or AutoPilot_Media.canPowerOn(dd)) then
                            local dist = dx * dx + dy * dy
                            if (on and not bestOn)
                                or (on == bestOn and dist < bestDist) then
                                best, bestOn, bestDist = obj, on, dist
                            end
                        end
                    end
                end
            end
        end
    end
    return best, bestOn
end

--- Human-readable activity label for a device.
local function _label(deviceData)
    local ok, isTv = pcall(function() return deviceData:getIsTelevision() end)
    if ok and isTv then return "watching tv" end
    return "listening to radio"
end

--- Walk the character to a device.  Mirrors the walk pattern used by every
--- other world-object approach in this mod (AutoPilot_Inventory:293, :495):
--- luautils.walkAdj first, falling back to a plain ISWalkToTimedAction when
--- walkAdj is unavailable or raises.
local function _walkToDevice(player, obj)
    local okSq, sq = pcall(function() return obj:getSquare() end)
    if not (okSq and sq) then return false end
    local walkOk = pcall(function()
        luautils.walkAdj(player, sq, true)
    end)
    if not walkOk then
        local okWalk = pcall(function()
            AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, sq))
        end)
        if not okWalk then return false end
    end
    return true
end

--- Boredom / unhappiness relief from a nearby television or radio.
---
--- Returns:
---   true,  <label>   an approach and/or a power toggle was queued this cycle
---   false, "tuned"   a device is already PLAYING within broadcast range, so
---                    relief is already accruing and there is nothing to queue
---   false, nil       no usable device, or the queue cooldown is still running
---
--- The "tuned" answer is what keeps this arm from starving the priority chain.
--- The obvious design -- return true while a device plays, so the character
--- stays parked in front of it -- is the same shape as the HIGH sleep-priority
--- bug (a terminal branch that queues nothing and blocks every lower need); a
--- broadcast with no BOR code would have parked the character indefinitely.  So
--- this arm only ever claims a cycle when it actually queued an action, and the
--- caller uses "tuned" for the one decision that genuinely depends on it:
--- whether to walk outdoors, which would forfeit the relief outright because
--- checkPlayer refuses to run codes across an inside/outside boundary.
---
--- The stall backoff closes the hole "tuned" left open: a device whose lines
--- are all heard, or tuned to a dead channel, kept answering "tuned" forever
--- and the outdoor walk stayed suppressed for the rest of the run.  When a
--- tuned stretch runs MEDIA_STALL_WINDOW_MS without boredom falling, the arm
--- answers (false, nil) -- a device-free world -- until the backoff expires,
--- and records the moment via setDecision("media", "stalled") so the run log
--- and the F11 reason line can say why the character walked away.
function AutoPilot_Media.doMediaRelief(player)
    if not player then return false, nil end

    local ms = _nowMs()
    if ms < _stallUntilMs then
        -- Backed off: the last tuned stretch provably was not helping.  No
        -- device scan, no tuned claim, no approach; the caller falls through
        -- to reading and the outdoor walk exactly as if no device existed.
        return false, nil
    end

    local obj, isOn = AutoPilot_Media.findNearbyDevice(player)
    if not obj then return false, nil end

    if isOn and AutoPilot_Media.inBroadcastRange(player, obj) then
        if _noteTuned(player, ms) == "stalled" then
            AutoPilot_Telemetry.setDecision("media", "stalled")
            print("[Media] Broadcasts stopped helping; backing off.")
            return false, nil
        end
        return false, "tuned"
    end

    if ms < _mediaCooldownMs then return false, nil end

    local dd = _deviceData(obj)
    if not dd then return false, nil end

    if not _walkToDevice(player, obj) then return false, nil end

    if not isOn then
        -- Real 42.19 signature (client/RadioCom/ISRadioAction.lua:173):
        --   ISRadioAction:new(mode, character, device, secondaryItem)
        -- "ToggleOnOff" is the engine's own mode string for the power button
        -- (RWMPower.lua:58 queues exactly this).
        local okToggle = pcall(function()
            AutoPilot_Utils.queueModAction(
                ISRadioAction:new("ToggleOnOff", player, obj))
        end)
        if not okToggle then
            print("[Media] Could not queue the power toggle; skipping.")
            return false, nil
        end
    end

    _mediaCooldownMs = ms + MEDIA_COOLDOWN_MS
    local label = _label(dd)
    AutoPilot_Telemetry.setDecision("media", "boredom")
    print("[Media] " .. label .. (isOn and " (already on)" or " (switching on)"))
    return true, label
end
