-- AutoPilot_Threat.lua
-- Detects nearby zombies (same z-level only) and decides: fight, flee, or
-- encircled-fight.
--
-- Improvements vs. previous version:
--   * Detection radius 20 tiles (was 10) -- enough lead time for action queue to drain.
--   * Z-level filter -- zombies on a different floor are ignored.
--   * Horde threshold -- flee if >= FLEE_HORDE_SIZE zombies regardless of weapon/moodles.
--   * Directional spread analysis -- finds the largest angular gap in the zombie ring;
--     flee vector points through that gap instead of blindly away from centroid.
--   * Encirclement detection -- if no gap exceeds FLEE_ESCAPE_ARC_MIN degrees, the
--     player is surrounded; fight through the gap rather than attempting to flee.
--   * Flee stutter prevention -- ongoing flee walk is not interrupted; a short
--     post-arrival cooldown stops instant re-triggers after reaching the destination.
--   * Weapon condition gate -- weapon below WEAPON_FIGHT_CONDITION_MIN treated as absent.
--
-- V5.6 (user-reported HIGH severity: "the fight/flee mechanic is not working as
-- expected").  Live telemetry showed combat spinning without ever acting: a
-- 175-tick combat streak with zombies=7 and endurance=52 FROZEN throughout,
-- ending in action=dead while bleeding climbed 0 -> 5 -> 7.  A real fight drains
-- endurance and a real escape moves the character; neither happened, so nothing
-- was executing at all.  Three defects combined:
--
--   1. NO-OP FALLBACK.  Home is auto-anchored on the first armed cycle
--      (AutoPilot_Main._initPlayer), so AutoPilot_Home.isSet is true in every
--      real run.  doFight then unconditionally redirected to doFlee, which means
--      the horde/wounded fallback `if not doFlee(...) then doFight(...) end`
--      called the SAME failing doFlee a second time and queued nothing at all.
--   2. UNREACHABLE FLEE DESTINATION.  The escape-arc branch clamped ABSOLUTE
--      world coordinates against cell:getWidth()/getHeight(), which are the
--      loaded-cell dimensions (a few hundred tiles), not world bounds.  A real
--      map position (Muldraugh is around x=10600) was therefore squashed to a
--      coordinate no square exists at, getGridSquare returned nil, and doFlee
--      failed every time.  Every other getGridSquare call in this mod passes
--      unclamped absolute coordinates; this one site was the outlier.  There was
--      also no snap-to-free-square retry, so a wall or a fence on the exact
--      target tile was fatal to the whole decision.
--   3. QUEUE CLEARED EVERY TICK.  check() called ISTimedActionQueue.clear on
--      every engage tick, so anything queued 0.75 s earlier was destroyed before
--      it could run -- and clearing blindly also violated the V4.5 ownership
--      rule (an action the mod did not queue must never be cleared).
--
-- The fix: decide FIRST and mutate the queue only when the decision actually
-- changes; guard fight exactly like flee (shared _engageActive, checked with
-- the real ISTimedActionQueue.isPlayerDoingAction helper); resolve a flee
-- destination through a snap-and-retry ladder; and never let a failed retreat
-- leave the character standing still.  Priorities are unchanged.

AutoPilot_Threat = {}

local function _apNoop(...) end
local print = _apNoop

local DETECTION_RADIUS      = AutoPilot_Constants.DETECTION_RADIUS
local FLEE_MOODLE_LIMIT     = AutoPilot_Constants.FLEE_MOODLE_LIMIT
local FLEE_DISTANCE         = AutoPilot_Constants.FLEE_DISTANCE
local FLEE_HORDE_SIZE       = AutoPilot_Constants.FLEE_HORDE_SIZE
local FLEE_ESCAPE_ARC_MIN   = AutoPilot_Constants.FLEE_ESCAPE_ARC_MIN
local FLEE_COOLDOWN_CYCLES  = AutoPilot_Constants.FLEE_COOLDOWN_CYCLES
local WEAPON_FIGHT_COND_MIN = AutoPilot_Constants.WEAPON_FIGHT_CONDITION_MIN

local WALK_SNAP_RADIUS      = AutoPilot_Constants.WALK_SNAP_RADIUS

-- Flee stutter-prevention state.
-- _fleeActive:   true while a flee walk is still in the action queue.
-- _fleeCooldown: counts down (in eval cycles) after the walk completes.
AutoPilot_Threat._fleeActive   = false
AutoPilot_Threat._fleeCooldown = 0

-- V5.6 engage state.  _engageActive is the SHARED version of _fleeActive: it is
-- set by BOTH doFlee and doFight whenever they actually queue something, so a
-- queued fight survives the next cycle exactly like a queued flee always did.
-- _engageReason is the last engage decision label, surfaced to telemetry so a
-- future run log can tell fight from flee (every combat tick used to log the
-- single undifferentiated reason "threat", which is why this bug was invisible
-- across 1889 combat ticks).
AutoPilot_Threat._engageActive = false
AutoPilot_Threat._engageReason = "threat"

-- Escape-arc retry ladder: fractions of FLEE_DISTANCE tried in order.  A full
-- sprint is preferred, but a blocked or unloaded destination must fall back to
-- a shorter hop instead of abandoning the escape entirely.
local FLEE_DISTANCE_FRACTIONS = { 1.0, 0.6, 0.3 }

-- Stat thresholds that count as "negative" for the flee decision.
-- All thresholds are normalized to 0.0-1.0 scale for consistent comparison.
-- HUNGER/THIRST/FATIGUE: already 0.0-1.0 from B42
-- PANIC/PAIN/SICKNESS/STRESS/SANITY: 0-100 integer from B42; normalized by dividing by 100
local NEGATIVE_STAT_CHECKS = {
    { stat = CharacterStat.HUNGER,   threshold = 0.40, isNormalized = true  },
    { stat = CharacterStat.THIRST,   threshold = 0.40, isNormalized = true  },
    { stat = CharacterStat.FATIGUE,  threshold = 0.60, isNormalized = true  },
    { stat = CharacterStat.PANIC,    threshold = 0.40, isNormalized = false }, -- 40/100 = 0.40
    { stat = CharacterStat.PAIN,     threshold = 0.30, isNormalized = false }, -- 30/100 = 0.30
    { stat = CharacterStat.SICKNESS, threshold = 0.20, isNormalized = false }, -- 20/100 = 0.20
    { stat = CharacterStat.STRESS,   threshold = 0.40, isNormalized = false }, -- 40/100 = 0.40
    { stat = CharacterStat.SANITY,   threshold = 0.40, isNormalized = false }, -- 40/100 = 0.40
}

-- Returns condition ratio (0.0-1.0) for any weapon item.  Returns 0 on failure.
local function getWeaponCondition(weapon)
    if not weapon then return 0 end
    local ok, ratio = pcall(function()
        local max = weapon:getConditionMax()
        if not max or max == 0 then return 1.0 end
        return weapon:getCondition() / max
    end)
    return (ok and type(ratio) == "number") and ratio or 0
end

-- Analyzes the angular distribution of zombies around the player.
-- Returns:
--   escDx, escDy  -- unit vector through the largest angular gap
--                    (flee direction if clear; weakest-cluster direction if encircled)
--   encircled     -- true when no gap exceeds FLEE_ESCAPE_ARC_MIN degrees
local function analyzeSpread(player, zombies)
    if #zombies == 0 then return 1, 0, false end

    local px, py       = player:getX(), player:getY()
    local minEscapeRad = FLEE_ESCAPE_ARC_MIN * math.pi / 180

    local angles = {}
    for _, z in ipairs(zombies) do
        table.insert(angles, math.atan2(z:getY() - py, z:getX() - px))
    end
    table.sort(angles)

    if #angles == 1 then
        local away = angles[1] + math.pi
        return math.cos(away), math.sin(away), false
    end

    -- Find the largest angular gap (circular list).
    -- Wrap-around gap: last angle to first angle + 2*pi.
    local maxGap      = 0
    local gapMidAngle = angles[1] + math.pi
    local n = #angles

    for i = 1, n do
        local a1  = angles[i]
        local a2  = (i < n) and angles[i + 1] or (angles[1] + 2 * math.pi)
        local gap = a2 - a1
        if gap > maxGap then
            maxGap        = gap
            gapMidAngle   = a1 + gap / 2
        end
    end

    local encircled = maxGap < minEscapeRad
    return math.cos(gapMidAngle), math.sin(gapMidAngle), encircled
end

-- Per-cycle zombie-scan cache.  getNearbyZombies is called up to 3x per
-- evaluation cycle (HUD, threat check, telemetry); Main calls beginCycle once
-- per cycle, which clears AND arms the cache so the scan runs only once per
-- cycle.  Callers that never call beginCycle (tests, external users) always
-- get a live scan — caching only happens between beginCycle calls.
AutoPilot_Threat._zombieCache = {}
AutoPilot_Threat._cacheArmed  = {}

local function _cachePnum(player)
    local ok, pnum = pcall(function() return player:getPlayerNum() end)
    return ok and pnum or 0
end

--- Clear and arm the per-player zombie cache; called by Main at the start of
--- each evaluation cycle.
function AutoPilot_Threat.beginCycle(player)
    local pnum = _cachePnum(player)
    AutoPilot_Threat._zombieCache[pnum] = nil
    AutoPilot_Threat._cacheArmed[pnum]  = true
end

-- Returns living zombies within DETECTION_RADIUS tiles on the same z-level.
-- Z-level filter prevents zombies on different floors inflating threat counts.
function AutoPilot_Threat.getNearbyZombies(player)
    local pnum  = _cachePnum(player)
    local armed = AutoPilot_Threat._cacheArmed[pnum]
    if armed then
        local cached = AutoPilot_Threat._zombieCache[pnum]
        if cached then return cached end
    end

    local zombies = {}
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local ok, zombieList = pcall(function() return getCell():getZombieList() end)
    if not ok or not zombieList then return zombies end

    -- Read live (NOT the load-time local): Adaptive tuning and mod options
    -- adjust this at runtime.
    local r   = AutoPilot_Constants.DETECTION_RADIUS
    local rSq = r * r
    for i = 0, zombieList:size() - 1 do
        local z = zombieList:get(i)
        if z and not z:isDead() and z:getZ() == pz then
            local dx = z:getX() - px
            local dy = z:getY() - py
            if (dx * dx + dy * dy) <= rSq then
                table.insert(zombies, z)
            end
        end
    end
    if armed then
        AutoPilot_Threat._zombieCache[pnum] = zombies
    end
    return zombies
end

-- Counts how many negative stats are above their thresholds.
function AutoPilot_Threat.countNegativeMoodles(player)
    local count = 0
    for _, check in ipairs(NEGATIVE_STAT_CHECKS) do
        local val = AutoPilot_Utils.safeStat(player, check.stat)
        if not check.isNormalized then
            val = val / 100  -- normalize 0-100 integer scale to 0.0-1.0
        end
        if val >= check.threshold then
            count = count + 1
        end
    end
    return count
end

-- True when `sq` is the tile the player already stands on.  A walk to your own
-- square completes instantly and moves nobody, so it is not an escape: taking
-- it as a valid flee destination is one of the ways V5.6's spin stayed frozen
-- (the home anchor IS the player's tile whenever the mod was armed on the spot).
local function _isPlayerSquare(player, sq)
    if not sq then return false end
    local ok, same = pcall(function()
        return sq:getX() == math.floor(player:getX())
           and sq:getY() == math.floor(player:getY())
           and sq:getZ() == player:getZ()
    end)
    return ok and same == true
end

-- Nearest free square to (x, y, z), snapping outward up to WALK_SNAP_RADIUS.
-- Never returns the player's own tile.
local function _freeSquareNear(player, x, y, z)
    local sq = AutoPilot_Utils.findNearestSquare(x, y, z, WALK_SNAP_RADIUS, function(s)
        local ok, free = pcall(function() return s:isFree(false) end)
        return ok and free == true
    end)
    if sq and not _isPlayerSquare(player, sq) then return sq end
    return nil
end

-- Resolve where to run to.  Safehouse anchor first (unchanged preference), then
-- the escape arc at decreasing distances.  Returns nil only when NOTHING in
-- reach is walkable, which is now a genuine "cannot retreat" signal rather than
-- the everyday outcome it used to be.
local function _fleeDestination(player, zombies, escDx, escDy)
    if AutoPilot_Home.isSet(player) then
        local hx, hy, hz = AutoPilot_Home.getState()
        local homeZ = hz or player:getZ()
        local sq = AutoPilot_Utils.findNearestSquare(hx, hy, homeZ, WALK_SNAP_RADIUS, function(s)
            local ok, free = pcall(function() return s:isFree(false) end)
            return ok and free == true and AutoPilot_Home.isInside(s)
        end)
        if sq and not _isPlayerSquare(player, sq) then return sq end
    end

    if not escDx then
        escDx, escDy = analyzeSpread(player, zombies)
    end

    -- Absolute world coordinates, unclamped: getGridSquare takes world
    -- coordinates, and the pre-V5.6 clamp against the loaded-cell dimensions
    -- turned every real map position into a square that does not exist.
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    for _, fraction in ipairs(FLEE_DISTANCE_FRACTIONS) do
        local dist = FLEE_DISTANCE * fraction
        local sq = _freeSquareNear(player,
            math.floor(px + escDx * dist),
            math.floor(py + escDy * dist),
            pz)
        if sq then return sq end
    end

    return nil
end

-- Flee toward the escape arc (or the home anchor if safehouse mode is active).
-- escDx/escDy: optional pre-computed unit escape vector; computed internally if nil.
-- Returns true when a walk was actually queued.
local function doFlee(player, zombies, escDx, escDy)
    local destSq = _fleeDestination(player, zombies, escDx, escDy)

    if destSq then
        AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, destSq))
        AutoPilot_Threat._engageActive = true
        AutoPilot_Threat._fleeActive   = true
        AutoPilot_Threat._fleeCooldown = FLEE_COOLDOWN_CYCLES
        print("[Threat] FLEE -> " .. #zombies .. " zombie(s), " ..
            AutoPilot_Threat.countNegativeMoodles(player) .. " negative stats elevated.")
        return true
    end

    print("[Threat] FLEE failed -- no reachable square; falling back to fight.")
    return false
end

-- Fight the nearest zombie: swap to best usable weapon, then walk toward it.
-- In safehouse mode (home set) this still PREFERS to retreat, but V5.6 makes
-- that a preference instead of an absolute: when the retreat cannot be
-- resolved, the character now fights rather than standing still.  Callers that
-- have already tried and failed to flee pass noRetreat=true so the redirect is
-- not attempted a second time (pre-V5.6 that second attempt failed identically
-- and queued NOTHING, which is how a horde could eat a motionless character).
-- escDx/escDy: passed through to doFlee on the safehouse redirect.
-- @return queued     true when something was actually queued.
-- @return retreated  true when the safehouse redirect handled it as a flee.
local function doFight(player, zombies, escDx, escDy, noRetreat)
    if not noRetreat and AutoPilot_Home.isSet(player) then
        print("[Threat] Safehouse mode -- redirecting FIGHT to FLEE.")
        if doFlee(player, zombies, escDx, escDy) then return true, true end
        print("[Threat] Safehouse retreat unavailable -- fighting instead.")
    end

    AutoPilot_Inventory.checkAndSwapWeapon(player)

    local px, py = player:getX(), player:getY()
    table.sort(zombies, function(a, b)
        return (a:getX()-px)^2 + (a:getY()-py)^2 < (b:getX()-px)^2 + (b:getY()-py)^2
    end)
    local target = zombies[1]

    local weapon, weaponCont = AutoPilot_Inventory.getBestWeapon(player)
    local weaponUsable = weapon and getWeaponCondition(weapon) >= WEAPON_FIGHT_COND_MIN

    local okPrimary, primary = pcall(function() return player:getPrimaryHandItem() end)
    if not okPrimary then primary = nil end

    local function safeMaxDamage(item)
        if not item then return nil end
        local ok, dmg = pcall(function() return item:getMaxDamage() end)
        return (ok and type(dmg) == "number") and dmg or nil
    end

    local primaryDamage = safeMaxDamage(primary)
    local weaponDamage  = safeMaxDamage(weapon)

    local shouldEquip = weaponUsable and not primary
    if not shouldEquip and weaponUsable and weaponDamage then
        shouldEquip = not primaryDamage or primaryDamage < weaponDamage
    end

    local queued = false

    if shouldEquip then
        -- V4.9: a weapon found in a backpack (V4.8) cannot be equipped from
        -- there; queue the move into the main inventory ahead of the equip.
        local _, usable = AutoPilot_Utils.queueItemToMainInventory(
            player, weapon, weaponCont)
        if usable then
            AutoPilot_Utils.queueModAction(ISEquipWeaponAction:new(player, weapon, 50, true))
            queued = true
        end
    end

    local targetSq = target and target:getSquare()
    if targetSq then
        AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, targetSq))
        queued = true
    end

    -- V5.6: the fight path is now guarded exactly like the flee path.  Without
    -- this the equip + walk it just queued were destroyed by the next cycle's
    -- clear before either could run, forever.
    if queued then
        AutoPilot_Threat._engageActive = true
    end

    print("[Threat] FIGHT -- " .. #zombies .. " zombie(s) nearby.")
    return queued, false
end

-- V5.6: clear ONLY to make room for a new engage decision, and ONLY when the
-- queue is holding an action THIS MOD queued.  A foreign action (started by the
-- player or another mod) is never cleared -- that is the V4.5 ownership rule,
-- which the old unconditional ISTimedActionQueue.clear(player) in check() broke
-- on every single combat tick.  Returns true when the queue is now free.
local function _clearOwnQueue(player)
    local busy = false
    pcall(function()
        busy = ISTimedActionQueue.isPlayerDoingAction(player) == true
    end)
    if not busy then return true end

    local current
    pcall(function()
        local q = ISTimedActionQueue.getTimedActionQueue(player)
        current = q and q.queue and q.queue[1]
    end)

    if AutoPilot_Utils.isModAction(current) then
        ISTimedActionQueue.clear(player)
        return true
    end

    -- Foreign action: untouched.  The engage action is still queued behind it
    -- (appending is not clearing), so the fail-safe acts without overriding the
    -- player, and the engage guard stops it queueing a second copy next cycle.
    print("[Threat] Foreign action in progress -- queue left alone (V4.5).")
    return false
end

-- Force fight regardless of moodle state (used by LLM commands).
function AutoPilot_Threat.forceFight(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)
    if #zombies == 0 then return end
    AutoPilot_Threat._engageActive = false
    AutoPilot_Threat._fleeActive   = false
    AutoPilot_Threat._fleeCooldown = 0
    _clearOwnQueue(player)
    AutoPilot_Threat._engageReason = "fight_forced"
    doFight(player, zombies, nil, nil, true)
end

-- Force flee regardless of moodle state (used by LLM commands).
function AutoPilot_Threat.forceFlee(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)
    if #zombies == 0 then return end
    AutoPilot_Threat._engageActive = false
    AutoPilot_Threat._fleeActive   = false
    AutoPilot_Threat._fleeCooldown = 0
    _clearOwnQueue(player)
    AutoPilot_Threat._engageReason = "flee_forced"
    doFlee(player, zombies)
end

--- Reason label for the most recent engage decision (V5.6 telemetry).
--- Read by AutoPilot_Main when it logs the "combat" action, replacing the
--- single undifferentiated "threat" reason that made fight indistinguishable
--- from flee across 1889 combat ticks in the reported run log.
function AutoPilot_Threat.getEngageReason()
    return AutoPilot_Threat._engageReason or "threat"
end

-- Pure decision function (V5.6): picks the engage intent WITHOUT touching the
-- action queue, so check() can compare the new decision against what is already
-- running before it mutates anything.  Priority order is unchanged from V3.2.
-- @return intent  "flee" | "fight"
-- @return reason  telemetry label for that branch
-- @return escDx, escDy  escape vector for the chosen branch
local function _decideEngagement(player, zombies)
    -- Priority 1: Critical wound (active bleeding) -- always flee.
    if AutoPilot_Medical.hasCriticalWound(player) then
        local dx, dy = analyzeSpread(player, zombies)
        return "flee", "flee_wounded", dx, dy
    end

    -- Pre-compute spread once; reused across all remaining priority checks.
    local escDx, escDy, encircled = analyzeSpread(player, zombies)

    -- Priority 2: Horde threshold -- flee regardless of weapon or moodles.
    if #zombies >= AutoPilot_Constants.FLEE_HORDE_SIZE then
        return "flee", "flee_horde", escDx, escDy
    end

    -- Priority 3: No usable weapon and outnumbered -- flee.
    local weapon       = AutoPilot_Inventory.getBestWeapon(player)
    local weaponUsable = weapon and getWeaponCondition(weapon) >= WEAPON_FIGHT_COND_MIN
    if not weaponUsable and #zombies > 1 then
        return "flee", "flee_unarmed", escDx, escDy
    end

    -- Priority 4: Encircled -- fight through the widest gap (fleeing is unsafe).
    if encircled then
        return "fight", "fight_encircled", escDx, escDy
    end

    -- Priority 5: Too many negative moodles -- flee; otherwise fight.
    if AutoPilot_Threat.countNegativeMoodles(player) > FLEE_MOODLE_LIMIT then
        return "flee", "flee_moodles", escDx, escDy
    end
    return "fight", "fight_default", escDx, escDy
end

-- Called every evaluation cycle.  Returns true if a threat was detected and an
-- action was queued (or an existing flee walk is still in progress).
function AutoPilot_Threat.check(player)
    local zombies = AutoPilot_Threat.getNearbyZombies(player)

    if #zombies == 0 then
        AutoPilot_Threat._engageActive = false
        AutoPilot_Threat._fleeActive   = false
        AutoPilot_Threat._fleeCooldown = 0
        return false
    end

    -- Engagement gate (V3.2): radius presence alone is not danger.  Zombies
    -- milling outside the safehouse walls locked the mod into permanent
    -- combat mode while the character stood safe indoors (telemetry: every
    -- cycle combat:threat, zombies=3, and training never ran).  Engage only
    -- when the ENGINE's threat counters say so — the same signals vanilla
    -- uses to gate sleeping — or when something is genuinely close.
    local engaged = false
    pcall(function()
        local s = player:getStats()
        engaged = s:getNumChasingZombies() > 0
            or s:getNumVeryCloseZombies() > 0
            or s:getNumVisibleZombies() > 0
    end)
    if not engaged then
        local px, py = player:getX(), player:getY()
        local closeSq = AutoPilot_Constants.CLOSE_DANGER_RADIUS
            * AutoPilot_Constants.CLOSE_DANGER_RADIUS
        for _, z in ipairs(zombies) do
            local dx, dy = z:getX() - px, z:getY() - py
            if dx * dx + dy * dy <= closeSq then
                engaged = true
                break
            end
        end
    end
    if not engaged then
        AutoPilot_Threat._engageActive = false
        AutoPilot_Threat._fleeActive   = false
        AutoPilot_Threat._fleeCooldown = 0
        return false
    end

    -- Engage stutter prevention (V5.6): if the fight OR flee queued on an
    -- earlier cycle is still executing, leave the queue completely alone.
    -- Pre-V5.6 only the flee path set this guard, so a queued fight was wiped
    -- by the clear below ~0.75 s later, every cycle, forever.
    -- (isPlayerDoingAction is the real B42 helper; isAllDone does not exist.)
    if AutoPilot_Threat._engageActive then
        if ISTimedActionQueue.isPlayerDoingAction(player) then
            AutoPilot_Threat._engageReason = "engage_running"
            return true
        end
        AutoPilot_Threat._engageActive = false
        AutoPilot_Threat._fleeActive   = false
    end

    if AutoPilot_Threat._fleeCooldown > 0 then
        AutoPilot_Threat._fleeCooldown = AutoPilot_Threat._fleeCooldown - 1
        AutoPilot_Threat._engageReason = "engage_cooldown"
        return true
    end

    -- Pre-equip: make sure the best usable weapon is in hand BEFORE the
    -- engage decision — a fleeing player can still be caught, and a fighting
    -- player must not start bare-handed.  Cheap when the current weapon is
    -- fine (the swap scan only runs on a degraded weapon).
    pcall(function() AutoPilot_Inventory.checkAndSwapWeapon(player) end)

    -- V5.6: decide FIRST, mutate the queue second.  Deciding before clearing is
    -- what makes it possible to leave an in-progress engage (and any foreign
    -- action) alone instead of clearing a queue we are about to refill with the
    -- same intent.
    local intent, reason, escDx, escDy = _decideEngagement(player, zombies)
    AutoPilot_Threat._engageReason = reason

    -- Make room only for a NEW decision, and only from the mod's own
    -- non-engage work (an exercise set, a loot walk...).  V4.5: a foreign
    -- action is never cleared.
    _clearOwnQueue(player)

    local acted, retreated
    if intent == "flee" then
        acted = doFlee(player, zombies, escDx, escDy)
        if not acted then
            -- The retreat could not be resolved anywhere in reach.  Stand and
            -- FIGHT rather than stand and die: noRetreat stops doFight bouncing
            -- straight back into the safehouse flee that just failed, which is
            -- exactly the no-op that left the character motionless while a
            -- horde killed it.
            AutoPilot_Threat._engageReason = "fight_no_escape"
            acted = doFight(player, zombies, escDx, escDy, true)
        end
    else
        -- Priority 4 (encircled) means fleeing is unsafe by definition, so it
        -- must not be redirected into a safehouse retreat.
        acted, retreated = doFight(player, zombies, escDx, escDy,
            reason == "fight_encircled")
        if retreated then
            AutoPilot_Threat._engageReason = "flee_safehouse"
        end
    end

    if not acted then
        -- Nothing could be queued at all (no reachable square, no target
        -- square, nothing to equip).  Distinct label so this shows up in the
        -- run log instead of hiding inside a generic combat tick.
        AutoPilot_Threat._engageReason = "engage_blocked"
    end

    return true
end
