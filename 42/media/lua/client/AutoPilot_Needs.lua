-- AutoPilot_Needs.lua
-- Handles survival needs and idle behaviour.
--
-- luacheck: globals getClimateManager
-- SPLITSCREEN NOTE: Module-level variables (restCooldownMs, exerciseWaitLogMs)
-- are shared across all local players. Splitscreen is NOT supported.
-- (Corrected 2026-07-20: sleepCooldownMs moved to AutoPilot_Sleep.lua in the
-- code-health split, and drinkCooldownMs moved to AutoPilot_Consumption.lua
-- in the prior slice; "exerciseCycle" never existed as an actual variable in
-- this file — found stale while fixing this comment for the same reason.)
--
-- Priority order (highest -> lowest):
--   1. Bleeding      -> bandage immediately (fatal if untreated)
--   2. Thirst        -> drink from tap/sink, then inventory, then loot
--   3. Hunger        -> eat
--   4. Wounds        -> treat non-bleeding wounds (scratches, bites, etc.)
--   5. Tired         -> sleep (recovers both fatigue AND endurance)
--   6. Exhausted     -> rest in place (endurance critically low, but not sleepy)
--   7. Scavenge      -> proactive supply top-up before stats drop
--   8. Explore       -> frontier scouting and supply runs
--   9. Bored/Sad     -> read literature, then go outside
--  10. Idle          -> exercise (strength/fitness alternating by level)

AutoPilot_Needs = {}

local function _apNoop(...) end
local print = _apNoop

-- Phase 2: daily exercise tracking (resets on day rollover).
-- V5.7 (BUG FIX): also resets when the PLAYER CHANGES.  The count used to key
-- off the in-game day alone, so starting a new character in the same Lua
-- session inherited the dead character's total and the F11 panel opened on
-- "Sets today: 150 (no cap)" for a survivor who had not done a single set.
-- Identity is the player OBJECT, the same signal the V4.5 `who` guards use on
-- _pendingSet / _exSetStart: a respawn is a new IsoPlayer even at the same
-- player number, which is exactly what an object comparison catches and what
-- getPlayerNum() alone cannot.
local _exerciseSetsToday = 0
local _lastTrackedDay    = -1
local _setsOwner         = nil   -- the player the count above belongs to
-- In-game day of the last equipment-fetch attempt (one trip per day).
local _equipFetchDay     = -1

-- ── Thresholds ────────────────────────────────────────────────────────────────
-- All policy numbers are defined in AutoPilot_Constants.  The local aliases
-- below exist purely for readability inside this module; changing the policy
-- means updating AutoPilot_Constants, not this file.

-- B42 Stats: player:getStats():get(CharacterStat.HUNGER), etc.
-- Hunger/Thirst/Fatigue: 0.0 = fine, ~1.0 = critical
-- Boredom: 0-100 scale
-- Endurance: 1.0 = full, 0.0 = empty
-- NOTE: hunger/thirst trigger thresholds are read LIVE from
-- AutoPilot_Constants at each use site (not cached here): the Adaptive layer
-- lowers them after starvation/dehydration deaths at runtime.
local FATIGUE_STAT_THRESHOLD = AutoPilot_Constants.FATIGUE_THRESHOLD
local BOREDOM_STAT_THRESHOLD = AutoPilot_Constants.BOREDOM_THRESHOLD
local ENDURANCE_REST_MIN     = AutoPilot_Constants.ENDURANCE_REST_MIN
local EXERCISE_MINUTES       = AutoPilot_Constants.EXERCISE_MINUTES
local OUTDOOR_SEARCH_DIST    = AutoPilot_Constants.OUTDOOR_SEARCH_DIST

-- ── V5.7: the exercise endurance HYSTERESIS PAIR ────────────────────────────
--
-- Until V5.7 there were two constants with transposed names and both gated
-- exercise inside doExercise, one immediately after the other:
--   * AutoPilot_Constants.ENDURANCE_EXERCISE_MIN (0.50), copied into a
--     FILE-LOCAL right here at load time -- so an options change could never
--     move it, no matter what the slider wrote;
--   * AutoPilot_Constants.EXERCISE_ENDURANCE_MIN (0.30), live-read, and the
--     one the endurance slider actually writes.
-- The effective gate was max(0.30, 0.50) = 0.50, so the untunable constant
-- silently floored the tunable one and the slider's entire 10-50% range was
-- inert.  That much was just a bug factory.
--
-- The DEEPER problem was that whatever survived was a SINGLE threshold doing
-- two incompatible jobs: deciding when to start training AND when to stop it.
-- The user hit the consequence directly: "The old setting of 50 made it so
-- that only a single rep would be completed after a period of resting."  Rest
-- to 50, start a set, one rep drops endurance under 50, stop, rest again.
-- Raising the number makes it worse, not better.
--
-- So the resolution is a PAIR, not a merge:
--   _exerciseEnduranceResume()  START a run at or above this   (high, 0.90)
--   _exerciseEnduranceFloor()   STOP an active run below this  (low,  0.30)
-- Which one applies depends on whether a run is currently active, which is
-- why the module has to track that (see _runActive below).  A stateless
-- `endurance >= X` test cannot express "keep going until the floor".
--
-- Both are functions, not load-time copies, so they re-read their constant at
-- every call: the V3.3 live-read pattern the options page depends on.
local function _exerciseEnduranceFloor()
    return tonumber(AutoPilot_Constants.EXERCISE_ENDURANCE_MIN) or 0.30
end

local function _exerciseEnduranceResume()
    return tonumber(AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME) or 0.90
end

-- Is a training run in progress right now?  Set when a set is actually
-- queued, cleared by EVERY path that ends training for any reason (see
-- AutoPilot_Needs.endTrainingRun).  Owner-guarded the same way the _pendingSet /
-- _exSetStart records are: a run belongs to one character, and a death or a
-- respawn must never leave the new one believing it is mid-run.
local _runActive = false
local _runOwner  = nil

--- End the current training run, if any.  Idempotent and argument-light.
--- Being generous about calling this is the safe direction: a spurious call
--- costs one extra rest cycle, whereas a MISSED call leaves the character
--- believing a run is in progress and training down to the floor when it
--- should have been recovering to the resume gate.
function AutoPilot_Needs.endTrainingRun()
    _runActive = false
    _runOwner  = nil
end

--- Is the given player mid-run?  Ownership makes a stale flag from a dead
--- character read as "not running" for the new one.
local function _inTrainingRun(player)
    return _runActive and _runOwner == player
end

-- ── V5.8: ONE activity string for the whole needs layer ─────────────────────
--
-- User report (with a screenshot of the running v5.7 build): the F11 panel
-- read "Status: training: burpees" at the same moment the V4.4 on-screen HUD
-- read "Action: Resting".  Both were drawn from the same module and they
-- disagreed, because this string was written ONLY by doExercise.  When the
-- chain stopped training and started resting, nothing overwrote it, so the
-- panel kept displaying the last training outcome indefinitely.
--
-- The fix is not "add a second field for resting": two fields that can
-- disagree IS the bug.  This one string is now the single answer to "what is
-- the needs layer doing", written by every path that claims the cycle -- the
-- trainer below AND doRest above -- and read by getExerciseStatus, which is
-- what both the panel and the HUD already call.
--
-- It is declared HERE, above doRest, rather than next to the trainer state,
-- purely because Lua locals are only visible below their declaration and
-- doRest is defined first.
local _activityOutcome = "idle"

local function _setActivity(text)
    _activityOutcome = text
end

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- Safe moodle level getter — returns 0 if the moodle type doesn't exist or isn't active.
-- B42 stores moodles in a Map; missing entries cause a Java NPE, so we pcall.
local function safeMoodleLevel(player, moodleType)
    if not moodleType then return 0 end
    local ok, level = pcall(function()
        return player:getMoodles():getMoodleLevel(moodleType)
    end)
    if ok and type(level) == "number" then
        return level
    end
    return 0
end

-- Returns current perk level (0-10) for the given PerkList entry.
local function getPerkLevel(player, perk)
    return player:getPerkLevel(perk)
end

-- ── Actions ─────────────────────────────────────────────────────────────────
-- doEat/doDrink/trackEmptyLootCycle moved to AutoPilot_Consumption.lua
-- (code-health split, 2026-07-20); see that file's header for why.

-- Rest on nearby furniture to recover endurance.
-- Searches for bed > sofa/couch/armchair > chair/bench/stool/pew.
-- Falls back to sitting on the ground if nothing is found.
local restCooldownMs = 0
local REST_SEARCH_DIST = AutoPilot_Constants.REST_SEARCH_DIST

-- V5.4: sittable-furniture sprite patterns.  Before V5.4 only sofa, couch and
-- chair were matched, so the outdoor bench the user asked about was never
-- recognised as seating at all.  Priority 2 = upholstered (best recovery
-- posture), 3 = plain seating.  Patterns are deliberately conservative: only
-- words that name a seat on their own are listed.  "seat" is NOT matched
-- because it is a substring of too many non-seat sprites.
local SEAT_PATTERNS = {
    { pattern = "sofa",     priority = 2 },
    { pattern = "couch",    priority = 2 },
    { pattern = "loveseat", priority = 2 },
    { pattern = "armchair", priority = 2 },
    { pattern = "chair",    priority = 3 },
    -- "bench" also names WORKbenches and carpentry benches, which are not
    -- seating; the reject list below drops those.
    { pattern = "bench",    priority = 3, reject = { "work", "carpentry", "saw" } },
    { pattern = "stool",    priority = 3 },
    { pattern = "pew",      priority = 3 },
    -- B42's own tilesheet category word for seats: park benches and picnic
    -- seating ship as furniture_seating_outdoor_* and never spell out "bench",
    -- so without this the most common outdoor seat stays invisible.  Matched as
    -- the whole word "seating", not "seat", which is a substring of too much.
    { pattern = "seating",  priority = 3 },
}

--- Classify a lowercased sprite name as seating.
--- Returns a priority number (2 or 3) or nil.  Pure: unit-tested directly.
function AutoPilot_Needs.seatPriorityForSprite(spriteName)
    if type(spriteName) ~= "string" then return nil end
    local lower = spriteName:lower()
    local best = nil
    for _, entry in ipairs(SEAT_PATTERNS) do
        if lower:find(entry.pattern, 1, true) then
            local rejected = false
            if entry.reject then
                for _, bad in ipairs(entry.reject) do
                    if lower:find(bad, 1, true) then rejected = true end
                end
            end
            if not rejected and (best == nil or entry.priority < best) then
                best = entry.priority
            end
        end
    end
    return best
end

--- Find the best rest furniture near the player.
--- @param player      the character
--- @param sitOnly     when true, beds are IGNORED.  The 30% critical path wants
---                    a bed (it hands off to sleep); the V5.4 sit-to-recover
---                    path must not, or a merely winded character would be put
---                    to sleep in the middle of the day.
local function findRestFurniture(player, sitOnly)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local bestObj  = nil
    local bestDist = math.huge
    local bestPriority = 99  -- lower = better (bed=1, sofa=2, chair/bench=3)
    -- V5.4: 0 = inside the home circle, 1 = outside it.  Compared BEFORE
    -- furniture quality, so home seating always wins: the tiles inside home
    -- are the ones the mod already treats as safe to walk.
    local bestZone = 99
    local outsideDist = AutoPilot_Constants.REST_OUTSIDE_SEARCH_DIST
        or REST_SEARCH_DIST
    local outsideDist2 = outsideDist * outsideDist

    AutoPilot_Utils.iterateNearbySquares(px, py, pz, REST_SEARCH_DIST, function(sq, dx, dy)
        local dist = dx * dx + dy * dy
        -- V5.4: outside-home furniture is eligible, but only within the
        -- tighter REST_OUTSIDE_SEARCH_DIST.  Before V5.4 this was a hard
        -- `return false`, which hid every bench, picnic table and porch chair
        -- outside the safehouse circle.  Note isInside() returns true when no
        -- home is set, so an unconfigured game keeps the full radius.
        local inside = AutoPilot_Home.isInside(sq)
        if not inside and dist > outsideDist2 then return false end
        local zone = inside and 0 or 1

        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            local priority = nil

            -- Check for bed
            if not sitOnly then
                local okB, isBed = pcall(function()
                    return obj:getSprite()
                        and obj:getSprite():getProperties()
                            :has(IsoFlagType.bed)
                end)
                if okB and isBed then
                    priority = 1
                end
            end

            -- Check for sittable furniture by sprite name
            if not priority then
                local okN, spName = pcall(function()
                    return obj:getSprite()
                        and obj:getSprite():getName() or ""
                end)
                if okN and spName then
                    priority = AutoPilot_Needs.seatPriorityForSprite(spName)
                end
            end

            if priority then
                -- Rank lexicographically: home zone, then furniture quality,
                -- then distance.
                if zone < bestZone
                    or (zone == bestZone and priority < bestPriority)
                    or (zone == bestZone and priority == bestPriority
                        and dist < bestDist)
                then
                    bestZone = zone
                    bestPriority = priority
                    bestDist = dist
                    bestObj = obj
                end
            end
        end
        return false  -- always continue: want best furniture, not first
    end)

    return bestObj
end

-- V5.4: how long a queued rest is held before the cycle is handed back.
-- This is a wedge guard, not the intended length: AutoPilot_Needs.check
-- releases the hold as soon as endurance reaches ENDURANCE_REST_TARGET.
-- Read live from constants so the options slider applies without a reload.
local function restHoldFrom(ms)
    local hold = tonumber(AutoPilot_Constants.REST_HOLD_MS) or 0
    if hold <= 0 then hold = 60000 end
    return ms + hold
end

--- Queue a rest.
--- @param player   the character
--- @param sitOnly  when true, beds are skipped: this is the V5.4
---                 sit-to-recover path, which must not put a merely winded
---                 character to sleep.
local function doRest(player, sitOnly)
    local ok, now = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms = ok and now or 0

    if ms < restCooldownMs then
        -- Still inside the hold from an earlier rest: nothing new is queued,
        -- but the cycle IS a rest, so the reported activity has to say so.
        -- Without this write the panel could still be showing whatever the
        -- trainer last set before the rest began (the V5.8 report).
        _setActivity("resting (recovering endurance)")
        return true  -- still resting, skip silently
    end

    local function queueGroundRest()
        if not ISSitOnGround or not ISSitOnGround.new then
            return false
        end
        local okSit, sitAction = pcall(function()
            local sq = player and player.getCurrentSquare and player:getCurrentSquare() or nil
            return ISSitOnGround:new(player, sq)
        end)
        if okSit and sitAction then
            print("[Needs] Exhausted — no furniture found; sitting on ground to recover.")
            AutoPilot_Utils.queueModAction(sitAction)
            _setActivity("resting (sitting on the ground)")
            return true
        end
        return false
    end

    local target = findRestFurniture(player, sitOnly)
    if not target then
        -- V5.4: the ground is ALWAYS an option.  The user's report asked for
        -- exactly this ("they should at least sit on the ground"), and before
        -- V5.4 the inside-home-only furniture filter plus the 30% gate meant
        -- this fallback was almost never reached.
        if queueGroundRest() then
            restCooldownMs = restHoldFrom(ms)
            return true
        end
        print("[Needs] Exhausted but no valid rest furniture found; skipping rest.")
        return false
    end

    local targetSq = target:getSquare()
    if not targetSq then
        print("[Needs] Rest target has no square; skipping rest.")
        return false
    end

    ISTimedActionQueue.clear(player)

    local queued = false

    local okBed, isBed = pcall(function()
        return target:getSprite()
            and target:getSprite():getProperties()
                :has(IsoFlagType.bed)
    end)

    if okBed and isBed then
        print("[Needs] Exhausted — using nearby bed to recover.")
        -- B42 sleep goes through ISWorldObjectContextMenu.onSleepWalkToComplete,
        -- which takes the 0-based player index (not the player object) and handles
        -- the walk-to + setAsleep, including MP SleepAllowed checks.
        local pnum = player:getPlayerNum()
        if AdjacentFreeTileFinder.isTileOrAdjacent(player:getCurrentSquare(), targetSq) then
            ISWorldObjectContextMenu.onSleepWalkToComplete(pnum, target)
            queued = true
        else
            local adjacent = AdjacentFreeTileFinder.Find(targetSq, player)
            if adjacent then
                local walkAction = ISWalkToTimedAction:new(player, adjacent)
                walkAction:setOnComplete(ISWorldObjectContextMenu.onSleepWalkToComplete, pnum, target)
                AutoPilot_Utils.queueModAction(walkAction)
                queued = true
            end
        end
        if queued then _setActivity("resting (using a bed)") end
    else
        print("[Needs] Exhausted — resting using nearby furniture.")

        -- ── V5.8: queue ONE action, and let it be the one that SEATS ────────
        --
        -- User report, with a screenshot: "Text says resting, but character is
        -- not sitting in the chair as expected" -- standing in the middle of
        -- the room, an empty chair right beside her, HUD reading "Resting".
        --
        -- Through V5.7 this branch queued BOTH of the calls below, back to
        -- back, and that is self-defeating:
        --
        --   * ISPathFindAction:pathToSitOnFurniture(character, furniture, cb)
        --     is the only one of the two whose recorded semantics include
        --     both halves of what this branch wants: it WALKS the character
        --     to the furniture and SEATS them on it.  It is the same call
        --     shape the mock has recorded since the V3.2 API audit.
        --
        --   * ISRestAction:new(character, bed, useAnimations) does no
        --     pathing at all.  Queued behind the seat action it is at best
        --     redundant, and a second timed action behind a sit is exactly
        --     the situation the mod's own exercise path uses
        --     ISTimedActionQueue.addGetUpAndThen for ("stands the character
        --     up from any furniture before..."), i.e. the engine's own way
        --     of running a follow-up action is to STAND UP first.  A
        --     standing character reading "Resting" is precisely what was
        --     reported.
        --
        -- The `useAnimations` argument compounded it: the mod passed nil,
        -- which is falsy, so even the rest action itself ran with its
        -- animations suppressed.  It is only reachable now as the fallback
        -- below, and it passes `true` there.
        --
        -- The ground fallback settles the design question: it queues
        -- ISSitOnGround ALONE, with no rest action chaser, and that is the
        -- path V5.4 shipped as the guaranteed recovery floor.  The mod's
        -- model of resting is "be seated"; the furniture branch now matches
        -- it instead of contradicting it.
        if ISPathFindAction and ISPathFindAction.pathToSitOnFurniture then
            local okPath, pathAction = pcall(function()
                return ISPathFindAction:pathToSitOnFurniture(player, target, nil)
            end)
            if okPath and pathAction then
                AutoPilot_Utils.queueModAction(pathAction)
                queued = true
            end
        end

        if not queued and ISRestAction and ISRestAction.new then
            -- Fallback only: reached when the seat action is unavailable or
            -- refused the furniture.  Real 42.19 signature
            -- (shared/TimedActions/ISRestAction.lua:245):
            -- ISRestAction:new(character, bed, useAnimations).  The 3rd
            -- argument is passed `true` now: nil is falsy, and a rest with
            -- its animations disabled is a rest performed standing up.
            local okRest, restAction = pcall(function()
                return ISRestAction:new(player, target, true)
            end)
            if okRest and restAction then
                AutoPilot_Utils.queueModAction(restAction)
                queued = true
            end
        end

        if queued then _setActivity("resting (seated on furniture)") end
    end

    if not queued then
        if queueGroundRest() then
            restCooldownMs = restHoldFrom(ms)
            return true
        end
        print("[Needs] Unable to queue a safe rest action.")
        return false
    end

    -- V5.4: was `ms + 60000`, i.e. sixty IN-GAME seconds (the clock is
    -- getGameTime():getCalender()), so the character stood back up after about
    -- one game minute and recovered nothing.  Now it holds up to
    -- REST_HOLD_MS and check() releases early at ENDURANCE_REST_TARGET.
    restCooldownMs = restHoldFrom(ms)
    return true
end

-- getBedObjectOnSquare/_findBedNearby/doSleep moved to AutoPilot_Sleep.lua
-- (code-health split, 2026-07-20, second slice); see that file's header.

-- Walk to the nearest outdoor square to relieve boredom.
local function doGoOutside(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local cell = getCell()
    if not cell then return false end
    local curSq = cell:getGridSquare(px, py, pz)
    if curSq and curSq:isOutside() then
        print("[Needs] Already outside — boredom will decrease naturally.")
        return false
    end

    print("[Needs] Bored — finding outdoor square.")

    -- Home set: only search within home bounds
    if AutoPilot_Home.isSet(player) then
        local outsideSq = AutoPilot_Home.getNearestInside(player, function(sq)
            return sq:isOutside() and sq:isFree(false)
        end)
        if outsideSq then
            AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, outsideSq))
            return true
        end
        print("[Needs] No outdoor square found inside home bounds — skipping.")
        return false
    end

    -- No home set: skip outdoor walk for safety (containment guard)
    print("[Needs] No home set — skipping outdoor walk.")
    return false
end

-- ── Weather/shelter helpers ─────────────────────────────────────────────────

local function isRaining()
    local ok, raining = pcall(function()
        local cm = getClimateManager and getClimateManager()
        if cm and cm.getIsRaining then return cm:getIsRaining() end
        if cm and cm.getCurrentWeather and cm:getCurrentWeather() and cm:getCurrentWeather().isRaining then
            return cm:getCurrentWeather():isRaining()
        end
        return false
    end)
    return ok and raining
end

local function doSeekShelter(player)
    if not player then return false end

    local sq = player:getCurrentSquare()
    if not sq or not sq:isOutside() then
        return false
    end

    if AutoPilot_Home.isSet(player) then
        local inside = AutoPilot_Home.getNearestInside(player, function(s)
            return s and s:isFree(false)
        end)
        if inside then
            print("[Needs] Seeking shelter inside home.")
            AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, inside))
            return true
        end
    end

    print("[Needs] No home shelter available; resting in place while outside.")
    return doRest(player)
end

-- ── Reading (boredom/unhappiness relief) ────────────────────────────────────

local function doRead(player)
    local literate = false
    local ok, lvlOrErr = pcall(function() return player:getPerkLevel(Perks.Literacy) end)
    if ok and type(lvlOrErr) == "number" then
        literate = lvlOrErr > 0
    else
        print("[Needs] literacy check pcall failed: " .. tostring(lvlOrErr))
    end
    if not literate then
        print(("[Needs] Cannot read: player considered illiterate. PerkCheck ok=%s value=%s")
            :format(tostring(ok), tostring(lvlOrErr)))
        -- Fallback debug checks (safe): query trait presence if possible
        local traitOk, hasIll = pcall(function()
            if player and player.HasTrait then return player:HasTrait("Illiterate") end
            if player and player.getDescriptor and player:getDescriptor().hasTrait then
                return player:getDescriptor():hasTrait("Illiterate")
            end
            return false
        end)
        print(("[Needs] literacy fallback checks: HasTrait ok=%s value=%s")
            :format(tostring(traitOk), tostring(hasIll)))
        return false
    end

    local book, bookCont = AutoPilot_Inventory.getReadable(player)
    if not book then
        -- No readable in inventory — try looting one from nearby containers
        return AutoPilot_Inventory.lootNearbyReadable(player)
    end

    -- Check if too dark to read
    local darkOk, tooDark = pcall(function() return player:tooDarkToRead() end)
    if darkOk and tooDark then
        print("[Needs] Too dark to read.")
        return false
    end

    print("[Needs] Reading: " .. tostring(book:getName()))
    -- V4.9: a book in a bag must reach the main inventory before ISReadABook.
    local _, usable = AutoPilot_Utils.queueItemToMainInventory(player, book, bookCont)
    if not usable then
        print("[Needs] Book transfer refused: not reading this cycle.")
        return false
    end
    local readOk, _ = pcall(function()
        AutoPilot_Utils.queueModAction(ISReadABook:new(player, book))
    end)
    return readOk
end

-- ── Proactive / AFK idle behaviours ────────────────────────────────────────

-- Proactive scavenge: loot when carried supply counts are low, even when
-- hunger/thirst stats have not yet reached their reactive thresholds.
-- RATE-LIMITED (V3.2): a background chore, not the mod's purpose.  It stays
-- within PROACTIVE_LOOT_RADIUS of the character, waits SCAVENGE_COOLDOWN
-- cycles between trips, and after SCAVENGE_STUCK_LIMIT trips with no supply
-- improvement it backs off for SCAVENGE_BACKOFF_CYCLES (the area is looted
-- out; reactive hunger/thirst paths still search the full radius when it
-- actually matters).
local _scavengeCooldown  = 0
local _scavengeStuck     = 0
local _scavengeLastTotal = -1

local function doProactiveScavenge(player)
    if not (AutoPilot_Inventory and AutoPilot_Inventory.getSupplyCounts) then
        return false
    end
    if _scavengeCooldown > 0 then
        _scavengeCooldown = _scavengeCooldown - 1
        return false
    end
    local ok, foodCount, drinkCount = pcall(function()
        return AutoPilot_Inventory.getSupplyCounts(player)
    end)
    if not ok then return false end
    foodCount  = foodCount  or 0
    drinkCount = drinkCount or 0

    local needFood  = foodCount  < AutoPilot_Constants.SUPPLY_FOOD_MIN
    local needDrink = drinkCount < AutoPilot_Constants.SUPPLY_DRINK_MIN
    if not needFood and not needDrink then
        _scavengeStuck     = 0
        _scavengeLastTotal = -1
        return false
    end

    -- Give-up detection: repeated trips without the counts improving mean the
    -- nearby area has nothing useful left.
    local total = foodCount + drinkCount
    if _scavengeLastTotal >= 0 and total <= _scavengeLastTotal then
        _scavengeStuck = _scavengeStuck + 1
    else
        _scavengeStuck = 0
    end
    _scavengeLastTotal = total
    if _scavengeStuck >= AutoPilot_Constants.SCAVENGE_STUCK_LIMIT then
        print(string.format(
            "[Needs] Proactive scavenge: no supply gain after %d trips -- backing off.",
            _scavengeStuck))
        _scavengeStuck    = 0
        _scavengeCooldown = AutoPilot_Constants.SCAVENGE_BACKOFF_CYCLES
        return false
    end

    _scavengeCooldown = AutoPilot_Constants.SCAVENGE_COOLDOWN_CYCLES
    local radius = AutoPilot_Constants.PROACTIVE_LOOT_RADIUS

    if needFood then
        print(string.format("[Needs] Proactive: food=%d < %d -- looting.",
            foodCount, AutoPilot_Constants.SUPPLY_FOOD_MIN))
        if AutoPilot_Inventory.lootNearbyFood(player, radius) then return true end
    end
    if needDrink then
        print(string.format("[Needs] Proactive: drink=%d < %d -- looting.",
            drinkCount, AutoPilot_Constants.SUPPLY_DRINK_MIN))
        if AutoPilot_Inventory.lootNearbyDrink(player, radius) then return true end
        -- No bottled drinks nearby: top up existing water containers from a
        -- source instead (only fires while thirst is still low).
        if AutoPilot_Inventory.proactiveWaterRefill
            and AutoPilot_Inventory.proactiveWaterRefill(player) then
            return true
        end
    end
    return false
end

-- ── Exercise ────────────────────────────────────────────────────────────────
-- B42: ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)
-- Exercise data comes from FitnessExercises.exercisesType
-- (shared/Definitions/FitnessExercises.lua): squats(legs), pushups(arms,chest),
-- situp(abs), burpees(legs,arms,chest).
--
-- Focus mapping (player design, V3.2):
--   strength -> push-ups (pure Strength work)
--   fitness  -> squats; sit-ups when the legs are too stiff for squats
--   auto     -> burpees (levels Strength AND Fitness together)

local LEG_PARTS = { "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R" }

-- True when any leg part's stiffness reaches the squat cutoff.
local function _legsTooStiffForSquats(player)
    local tooStiff = false
    pcall(function()
        local bd = player:getBodyDamage()
        for _, name in ipairs(LEG_PARTS) do
            local part = bd:getBodyPart(BodyPartType[name])
            if part and part:getStiffness()
                >= AutoPilot_Constants.SQUAT_STIFFNESS_MAX then
                tooStiff = true
                return
            end
        end
    end)
    return tooStiff
end

-- True when the exercise's required item (if any) is in the inventory.
-- Mirrors the vanilla gate (ISFitnessUI: inventory:contains(item, true)).
local function _hasExerciseItem(player, exeData)
    if not exeData.item then return true end
    local has = false
    pcall(function()
        has = player:getInventory():contains(exeData.item, true)
    end)
    return has
end

-- Ordered exercise candidates for the focus; the first one that has
-- definition data, whose required item is carried, and that is not
-- XP-fatigued is used.  Later entries are fallbacks for when the primary
-- exercise stops yielding XP (PZ diminishing returns).
--
-- Equipment exercises lead every pool that can use them: their xpMod
-- (dumbbell 1.8x, barbell 1.2x) belongs to the EXERCISE TYPE, so doing
-- dumbbellpress beats push-ups whenever a dumbbell is carried.  An
-- equipment entry whose item is NOT carried fails the _hasExerciseItem
-- gate and falls through silently to the next candidate, so a barehanded
-- character still trains normally.  No fitness equipment exists, so the
-- fitness pool stays bodyweight-only.
local function _exerciseCandidates(player, focus)
    if focus == "strength" then
        return { "dumbbellpress", "bicepscurl", "barbellcurl", "pushups" }
    elseif focus == "fitness" then
        if _legsTooStiffForSquats(player) then
            print("[Needs] Legs too stiff for squats — switching to sit-ups.")
            return { "situp" }
        end
        return { "squats", "situp" }
    end
    -- auto (V5.2): equipment first, then burpees (the one exercise that
    -- trains BOTH stats), then the bodyweight fallbacks.  Burpees used to
    -- lead here, so an auto day never touched the dumbbell the mod itself
    -- walks out to fetch (fetchExerciseEquipment, below): the 1.8x/1.2x
    -- equipment xpMod was fetched and then ignored.  With equipment
    -- leading, the XP-fatigue rotation still falls through to burpees and
    -- the bodyweight pool as each option stops paying, so Fitness keeps
    -- progressing across the day; since V4.6 dropped the daily set cap,
    -- that rotation runs long enough for every tier to get used.
    return { "dumbbellpress", "bicepscurl", "barbellcurl", "burpees",
             "squats", "pushups", "situp" }
end

-- ── Per-exercise XP-productivity tracking ───────────────────────────────────
-- PZ applies per-exercise diminishing returns: repeat one exercise long
-- enough and its XP drops to ~zero while the animation happily continues.
-- The engine does not expose that fatigue to Lua (only long-term
-- getRegularity), so it is detected the honest way: by measuring the actual
-- XP a completed set produced.

-- [exType] -> { str, fit, ms }  snapshot taken when the set was queued.
local _exSetStart     = {}
-- [exType] -> game-ms until which the exercise is considered fatigued.
local _exFatiguedUntil = {}
-- Human-readable state of the trainer: written through _setActivity, the
-- single activity string declared near the top of this file (V5.8).  The
-- trainer is no longer its only writer -- doRest writes it too -- which is
-- what stops the F11 panel reporting "training: burpees" at a character who
-- is sitting down.

-- ── Player-intervention backoff (V4.5) ──────────────────────────────────────
-- The user-reported lockup: cancel an exercise and the armed trainer
-- re-queues a new set ~0.75 s later, bulldozing the cancel.  Fix: track the
-- one exercise action the mod itself queues; when it vanishes from the
-- queue before running ~a full set AND the mod did not clear it itself
-- (urgent-need interrupt, threat response, thrash guard), the player
-- intervened, and training backs off for EXERCISE_BACKOFF_MINUTES (game
-- minutes, live-read so the Options slider applies immediately).  A
-- FOREIGN exercise observed running (Main's busy cycle) refreshes the same
-- window every cycle, so training also stays away while, and shortly
-- after, the player exercises manually.  Movement input has no verified
-- read surface in this mod; in PZ movement cancels the queued action, so
-- it lands in the vanished-uncompleted path and is covered the same way.
--
-- All state is module-local: a Lua reload (MP join) starts clean, and the
-- `who` field guards against judging a dead character's set against the
-- respawned character (same pattern as _exSetStart.who).
local _pendingSet    = nil   -- { action, exType, ms, who } last mod-queued set
local _backoffUntilMs = 0    -- game-ms; training yields while now < this

local function _backoffWindowMs()
    local mins = tonumber(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES) or 0
    if mins <= 0 then return 0 end
    return mins * 60000
end

local function _setBackoff(nowMs, why)
    local windowMs = _backoffWindowMs()
    if windowMs <= 0 then return end
    _backoffUntilMs = nowMs + windowMs
    _setActivity("backing off (" .. why .. ")")
    print("[Needs] Training backoff (" .. why .. ") for "
        .. tostring(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES)
        .. " game minutes.")
end

-- Resolve the tracked mod-queued set: still running, completed normally, or
-- vanished uncompleted (= player intervention -> backoff).  Called at the
-- top of doExercise, before any gate, so the record can never go stale.
local function _updateInterventionState(player, nowMs)
    local ps = _pendingSet
    if not ps then return end
    -- Never judge a snapshot from a different character (death/respawn).
    if ps.who ~= player then
        _pendingSet = nil
        AutoPilot_Utils.clearModAction(ps.action)
        return
    end
    local stillQueued = false
    pcall(function()
        local q   = ISTimedActionQueue.getTimedActionQueue(player)
        local arr = q and q.queue
        if type(arr) == "table" then
            for i = 1, #arr do
                if arr[i] == ps.action then
                    stillQueued = true
                    break
                end
            end
        end
    end)
    if stillQueued then return end
    -- The set left the queue: resolve the record either way.
    _pendingSet = nil
    AutoPilot_Utils.clearModAction(ps.action)
    local fullSetMs = AutoPilot_Constants.EXERCISE_MINUTES * 60000
    if (nowMs - ps.ms) < fullSetMs * 0.8 then
        -- Vanished well short of a full set and the mod did not clear it
        -- itself (those paths consume the record via noteModExerciseCleared):
        -- the player cancelled it.  Do not judge the aborted set as
        -- XP-fatigue, and back off instead of re-queuing over player intent.
        _exSetStart[ps.exType] = nil
        _setBackoff(nowMs, "manual cancel")
    end
end

local function _perkXp(player, perk)
    local ok, xp = pcall(function() return player:getXp():getXP(perk) end)
    return (ok and type(xp) == "number") and xp or 0
end

-- Judge the previous set of exType (if one ran to roughly full length):
-- returns false when the exercise is now fatigued and should be skipped.
local function _exerciseStillProductive(player, exType, nowMs)
    local fatiguedUntil = _exFatiguedUntil[exType]
    if fatiguedUntil and nowMs < fatiguedUntil then
        return false
    end
    local s = _exSetStart[exType]
    if not s then return true end
    -- A snapshot from a DIFFERENT character (death/respawn) must never be
    -- judged: the new character's lower XP would read as negative gain and
    -- falsely fatigue the exercise.
    if s.who ~= player then
        _exSetStart[exType] = nil
        return true
    end
    -- Only judge sets that ran most of their duration (an interrupted set
    -- legitimately gains nothing).
    local fullSetMs = AutoPilot_Constants.EXERCISE_MINUTES * 60000
    if (nowMs - s.ms) < fullSetMs * 0.8 then return true end
    local gain = (_perkXp(player, Perks.Strength) - s.str)
               + (_perkXp(player, Perks.Fitness)  - s.fit)
    if gain < AutoPilot_Constants.EXERCISE_MIN_XP_PER_SET then
        print(string.format(
            "[Needs] %s produced %.1f XP last set — fatigued; resting it.",
            exType, gain))
        _exFatiguedUntil[exType] = nowMs
            + AutoPilot_Constants.EXERCISE_FATIGUE_RECOVERY_MS
        _exSetStart[exType] = nil
        return false
    end
    return true
end

-- Log cooldown for "waiting for endurance" to prevent spam
local exerciseWaitLogMs = 0

--- V5.7: bring the daily set counter into agreement with WHO and WHEN.
---
--- Two things invalidate the count, and before V5.7 only the first was
--- checked: the in-game day rolling over, and the count belonging to a
--- DIFFERENT character.  The second is the user-reported bug ("when starting
--- a new character, the number of sets completed should reset"): a fresh
--- survivor opened the F11 panel on the previous character's total because
--- module state outlives a death and a new game inside one Lua session.
---
--- Called from BOTH doExercise and the top of check(), so the reset lands on
--- the very first evaluation cycle after a respawn even when some other need
--- (thirst, wounds, a threat) wins that cycle and exercise is never reached.
--- @param player IsoPlayer
--- @return number today  the in-game day this counter is now tracking
local function _syncSetsCounter(player)
    local gt    = GameTime.getInstance()
    local today = gt and gt:getDay() or 0
    if _setsOwner ~= player then
        -- New character (or the first sync of the session): nothing this
        -- counter holds belongs to them.  Scope note: _equipFetchDay is keyed
        -- off the day alone and has the same theoretical staleness, but it is
        -- deliberately NOT reset here.  The user asked for the SET COUNT to
        -- reset; a new character being denied one dumbbell-fetch trip until
        -- the next in-game day is cosmetic, self-healing, and outside what
        -- was requested.
        _exerciseSetsToday = 0
        _lastTrackedDay    = today
        _setsOwner         = player
        -- V5.7: a run belongs to a character.  The new one is not mid-run.
        AutoPilot_Needs.endTrainingRun()
    elseif today ~= _lastTrackedDay then
        -- Same character, new day: the original Phase 2 rollover, unchanged.
        _exerciseSetsToday = 0
        _lastTrackedDay    = today
    end
    return today
end

--- V5.7: test seam for the per-character reset (no engine surface involved).
function AutoPilot_Needs.syncSetsCounterForTest(player)
    return _syncSetsCounter(player)
end

-- focus: "strength" | "fitness" | nil (nil = auto-balance the lower of the two)
local function doExercise(player, focus)
    -- Phase 2 day rollover + V5.7 per-character reset.
    local _today = _syncSetsCounter(player)

    local okMs, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    nowMs = okMs and nowMs or 0

    -- V4.5: resolve the last mod-queued set (completed vs player-cancelled)
    -- BEFORE any gate, then honor the intervention backoff window.
    _updateInterventionState(player, nowMs)
    if nowMs < _backoffUntilMs then
        local minsLeft = math.ceil((_backoffUntilMs - nowMs) / 60000)
        _setActivity("backing off (player intervened; "
            .. minsLeft .. "m left)")
        -- V5.7: the run is over.  Whatever resumes after the backoff window
        -- is a NEW run and must clear the resume gate on its own merits.
        AutoPilot_Needs.endTrainingRun()
        return false
    end

    -- V4.6: optional daily-cap gate.  The PRIMARY limiter is XP
    -- productivity (_exerciseStillProductive, below): training stops when an
    -- exercise stops paying XP, not at an arbitrary set count.  A cap of 0
    -- (the default) means unlimited, so this gate is skipped entirely; only
    -- a user-configured cap > 0 enforces a hard ceiling.
    local dailyCap = tonumber(AutoPilot_Constants.EXERCISE_DAILY_CAP) or 0
    if dailyCap > 0 and _exerciseSetsToday >= dailyCap then
        print(("[Needs] Daily exercise cap %d reached; resting."):format(
            dailyCap))
        _setActivity("resting (daily set cap reached)")
        AutoPilot_Needs.endTrainingRun()
        return false
    end

    -- ── V5.7: the endurance HYSTERESIS gate ─────────────────────────────────
    -- This used to be two consecutive gates built on two transposed constants
    -- that both asked "is there enough to START?" (see the pair of helpers at
    -- the top of this file).  Asking only that question is what produced the
    -- user's single-rep loop: rest to the gate, start a set, the first rep
    -- drops below the gate, stop, rest again.
    --
    -- Now the threshold DEPENDS ON WHETHER A RUN IS ALREADY GOING:
    --   not running -> must reach the high RESUME gate to start
    --   running     -> keep going all the way down to the low FLOOR
    -- so one rest buys a long run of reps instead of one.
    --
    -- The severe exertion-moodle test is preserved verbatim and stays
    -- unconditional: it is a genuinely different signal (moodle level, not
    -- stat value) and a level 3+ moodle ends a run no matter how it started.
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    local inRun     = _inTrainingRun(player)
    local endGate   = inRun and _exerciseEnduranceFloor()
                            or _exerciseEnduranceResume()
    if endurance < endGate or enduranceMoodle > 2 then
        -- Log once every 30s of game time, not every tick
        local ok, now = pcall(function()
            return getGameTime():getCalender():getTimeInMillis()
        end)
        local ms = ok and now or 0
        if ms >= exerciseWaitLogMs then
            print(string.format(
                "[Needs] Endurance %.0f%% under the %s gate %.0f%%;"
                .. " %s.",
                endurance * 100, inRun and "floor" or "resume",
                endGate * 100,
                inRun and "ending the training run" or "still recovering"))
            exerciseWaitLogMs = ms + 30000
        end
        -- Whether the run just ended on the floor or never started, the next
        -- attempt has to clear the RESUME gate: that is the hysteresis.
        AutoPilot_Needs.endTrainingRun()
        _setActivity("resting (endurance recovering)")
        return false  -- no action queued; the sit branch in check() recovers
    end

    -- Once per day (strength/auto focus): fetch a dumbbell/barbell from home
    -- storage so the higher-XP equipment exercises unlock.  The fetch trip is
    -- itself this cycle's action.
    if focus ~= "fitness" and _equipFetchDay ~= _today
        and AutoPilot_Inventory.fetchExerciseEquipment
        and not AutoPilot_Inventory.hasExerciseEquipment(player) then
        _equipFetchDay = _today
        local okF, fetching = pcall(AutoPilot_Inventory.fetchExerciseEquipment, player)
        if okF and fetching then
            _setActivity("fetching exercise equipment")
            return true
        end
    end

    local candidates = _exerciseCandidates(player, focus)
    local exType, exeData
    for _, cand in ipairs(candidates) do
        local data = FitnessExercises and FitnessExercises.exercisesType
            and FitnessExercises.exercisesType[cand] or nil
        if data and _hasExerciseItem(player, data)
            and _exerciseStillProductive(player, cand, nowMs) then
            exType, exeData = cand, data
            break
        end
    end

    if not exeData then
        print("[Needs] All exercises for focus '" .. tostring(focus or "auto")
            .. "' are XP-fatigued — pausing training while they recover.")
        _setActivity("resting (exercises fatigued)")
        -- V5.7: XP fatigue ends the run too.  Without this the character
        -- would keep "being mid-run" while queueing nothing, and would then
        -- resume off the low floor instead of recovering to the resume gate.
        AutoPilot_Needs.endTrainingRun()
        return false
    end
    print("[Needs] Exercise — focus: " .. tostring(focus or "auto")
        .. " -> " .. exType)

    -- Pre-initialize the Java Fitness object so currentExe is set before
    -- the action lifecycle starts (prevents exerciseRepeat NPE).
    pcall(function()
        local fitness = player:getFitness()
        fitness:init()
    end)

    -- 42.19 signature (shared/TimedActions/ISFitnessAction.lua:200, verified
    -- against the RUNNING game's stack trace):
    --   ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)
    -- The 5th arg feeds fitness:setCurrentExercise(exeDataType) — a String-typed
    -- Java call — so it must be the TYPE STRING, with the data table 4th.
    local ok, action = pcall(function()
        return ISFitnessAction:new(player, exType, EXERCISE_MINUTES, exeData, exeData.type)
    end)

    if ok and action then
        -- Equipment exercises: put the item in hand the same way vanilla's
        -- fitness UI does before starting (ISFitnessUI.lua:245-262) — prop
        -- "twohands" equips two-handed, "primary"/"switch" one-handed.
        if exeData.item then
            pcall(function()
                local twoHands = exeData.prop == "twohands"
                ISWorldObjectContextMenu.equip(player,
                    player:getPrimaryHandItem(), exeData.item, true, twoHands)
            end)
        end
        -- addGetUpAndThen (real 42.19 static, ISTimedActionQueue.lua:219):
        -- stands the character up from any furniture before exercising.
        -- V4.5: tag ownership BEFORE queueing, and remember the action so
        -- the intervention detector can tell a completed set from a
        -- player-cancelled one.
        AutoPilot_Utils.tagModAction(action)
        ISTimedActionQueue.addGetUpAndThen(player, action)
        _pendingSet = { action = action, exType = exType, ms = nowMs, who = player }
        -- Snapshot XP at set start so the NEXT attempt can judge whether this
        -- set actually produced XP (diminishing-returns detection).
        _exSetStart[exType] = {
            str = _perkXp(player, Perks.Strength),
            fit = _perkXp(player, Perks.Fitness),
            ms  = nowMs,
            who = player,
        }
        -- V5.7: a set is really queued, so a training RUN is now in progress.
        -- From here the low floor applies instead of the high resume gate,
        -- which is what lets the run keep going rep after rep off one rest.
        _runActive = true
        _runOwner  = player
        -- The counter keeps running even when uncapped: the F11 panel and
        -- the logs report it, it just no longer halts training on its own.
        _exerciseSetsToday = _exerciseSetsToday + 1
        _setActivity("training: " .. exType)
        if dailyCap > 0 then
            print(("[Needs] Exercise set %d/%d queued."):format(
                _exerciseSetsToday, dailyCap))
        else
            print(("[Needs] Exercise set %d queued (no daily cap)."):format(
                _exerciseSetsToday))
        end
        return true
    else
        print("[Needs] ISFitnessAction failed for: " .. exType .. " — " .. tostring(action))
        _setActivity("error: could not start " .. tostring(exType))
        AutoPilot_Needs.endTrainingRun()
        return false
    end
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Trainer status for the F11 panel.
--- Returns { outcome = "training: squats" | "resting (...)" | "idle",
---           setsToday, cap, setsLine }.
--- V4.6: `cap` is 0 when training is uncapped (XP productivity is the
--- limiter), so the panel must never print "12/0".  `setsLine` is the
--- pre-formatted, honest rendering of the count and is what the UI draws
--- verbatim (same data-layer-formats-it convention as the program line);
--- `setsToday` and `cap` stay for callers that want the raw numbers.
--- V5.8: `outcome` is the module's SINGLE activity string (_activityOutcome),
--- so it now also reports the rest paths.  It can no longer say "training: x"
--- while the character is sitting down; the F11 panel and the V4.4 on-screen
--- action HUD read this same field through this same function.
function AutoPilot_Needs.getExerciseStatus()
    local cap = tonumber(AutoPilot_Constants.EXERCISE_DAILY_CAP) or 0
    local setsLine
    if cap > 0 then
        setsLine = ("Sets today: %d/%d"):format(_exerciseSetsToday, cap)
    else
        setsLine = ("Sets today: %d (no cap)"):format(_exerciseSetsToday)
    end
    return {
        outcome   = _activityOutcome,
        setsToday = _exerciseSetsToday,
        cap       = cap,
        setsLine  = setsLine,
    }
end

-- ── Player-intervention notifications (V4.5) ────────────────────────────────
-- Called by Main; all three are argument-light so no player object is ever
-- closed over across a Lua reload (the MP stale-closure lesson).

--- Main observed a FOREIGN exercise as the running action (player-initiated
--- or vanilla-queued; identity says it is not ours).  Refreshing the
--- backoff window every observed cycle keeps training away while the
--- manual exercise runs and for one full window after it ends, so the
--- trainer never re-queues over the player's own session.
function AutoPilot_Needs.noteForeignExercise(_player)
    local ok, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if not ok or type(nowMs) ~= "number" then return end
    local windowMs = _backoffWindowMs()
    if windowMs <= 0 then return end
    _backoffUntilMs = nowMs + windowMs
    _setActivity("waiting (manual exercise in progress)")
    -- V5.7: the player is training by hand; our run is over.
    AutoPilot_Needs.endTrainingRun()
end

--- The MOD itself cleared its own queued exercise (urgent-need interrupt,
--- threat response, or thrash guard).  Consume the pending record so the
--- vanish is NOT misread as a player cancel (no backoff: training may
--- resume as soon as the interrupting condition is handled).
function AutoPilot_Needs.noteModExerciseCleared()
    -- V5.7: end the run FIRST, and unconditionally.  An urgent need, a threat
    -- response or the thrash guard all mean training stopped, whether or not
    -- there was still a pending record to consume.  Training may resume as
    -- soon as the interrupting condition is handled -- but as a NEW run, off
    -- the resume gate, not off the floor.
    AutoPilot_Needs.endTrainingRun()
    local ps = _pendingSet
    if not ps then return end
    _pendingSet = nil
    AutoPilot_Utils.clearModAction(ps.action)
end

--- F10 panic stop: the player explicitly stopped a running exercise.
--- Consume the pending record (if the set was ours) and start the backoff
--- window immediately, so even a just-armed trainer cannot re-queue an
--- exercise right after the player asked for it to stop.
function AutoPilot_Needs.notePanicStop()
    -- V5.7: the player asked for training to STOP; the run ends here.
    AutoPilot_Needs.endTrainingRun()
    local ps = _pendingSet
    if ps then
        _pendingSet = nil
        AutoPilot_Utils.clearModAction(ps.action)
    end
    local ok, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if not ok or type(nowMs) ~= "number" then return end
    _setBackoff(nowMs, "F10 panic stop")
end

--- Reset intervention state (tests only; mirrors Leveler.resetForTest).
function AutoPilot_Needs.resetInterventionForTest()
    if _pendingSet then
        AutoPilot_Utils.clearModAction(_pendingSet.action)
    end
    _pendingSet     = nil
    _backoffUntilMs = 0
    AutoPilot_Needs.endTrainingRun()
end

--- Returns true if an urgent need should interrupt the current action (e.g. exercise).
--- Called by Main before the isPlayerDoingAction guard.
function AutoPilot_Needs.shouldInterrupt(player)
    -- Bleeding always interrupts
    if AutoPilot_Medical.hasCriticalWound(player) then return true end

    -- Thirst interrupts at threshold
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    if thirst >= AutoPilot_Constants.THIRST_THRESHOLD then return true end

    -- Hunger interrupts
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    if hunger >= AutoPilot_Constants.HUNGER_THRESHOLD then return true end

    -- Exhaustion interrupts (stat threshold OR severe moodle — mirrors check())
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN then return true end
    if safeMoodleLevel(player, MoodleType.ENDURANCE) >= 3 then return true end

    return false
end

--- Main survival needs check.
function AutoPilot_Needs.check(player)
    -- V5.7: keep the daily set counter honest about WHO it belongs to before
    -- anything can return early.  doExercise syncs too, but it is at the
    -- bottom of the chain and a new character with an urgent need would show
    -- the dead character's set total in the F11 panel until they got there.
    _syncSetsCounter(player)

    -- 1. Bleeding — treat immediately (fatal if untreated)
    if AutoPilot_Medical.hasCriticalWound(player) then
        AutoPilot_Telemetry.setDecision("bandage", "bleeding")
        if AutoPilot_Medical.check(player, true) then return true end
    end

    -- Sleep overrides rest cooldown — fatigue is checked before the cooldown gate
    -- so the character can transition from resting to sleeping when tired enough.
    local fatigue = AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE)
    if fatigue >= FATIGUE_STAT_THRESHOLD then
        AutoPilot_Telemetry.setDecision("sleep", "fatigue_thresh")
        return AutoPilot_Sleep.doSleep(player)
    end

    -- 2. Thirst (0.0=hydrated, ~1.0=dying)
    local thirst = AutoPilot_Utils.safeStat(player, CharacterStat.THIRST)
    if thirst >= AutoPilot_Constants.THIRST_THRESHOLD then
        AutoPilot_Telemetry.setDecision("drink", "thirst_thresh")
        return AutoPilot_Consumption.doDrink(player)
    end

    -- Environmental comfort guard: seek shelter if outside in bad conditions.
    local currentSq = player:getCurrentSquare()
    local tempDelta = 0
    if AutoPilot_Inventory and AutoPilot_Inventory.bodyTemperature then
        local okTemp, t = pcall(function()
            return AutoPilot_Inventory.bodyTemperature(player)
        end)
        if okTemp and type(t) == "number" then
            tempDelta = t
        end
    end
    if currentSq and currentSq:isOutside() then
        if isRaining() or tempDelta < AutoPilot_Constants.TEMP_TOO_COLD then
            print("[Needs] Outdoors bad comfort (rain/cold) — seeking shelter.")
            AutoPilot_Telemetry.setDecision("shelter", "weather")
            if doSeekShelter(player) then return true end
        end
    end

    -- 3. Hunger (0.0=full, ~1.0=starving)
    local hunger = AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER)
    if hunger >= AutoPilot_Constants.HUNGER_THRESHOLD then
        print(string.format(
            "[Needs] Hunger triggered (%.0f%%). Attempting to eat.", hunger * 100))
        AutoPilot_Telemetry.setDecision("eat", "hunger_thresh")
        local ate = AutoPilot_Consumption.doEat(player)
        if ate then return true end
        print("[Needs] doEat returned false — no food available, continuing.")
    end

    -- 4. Wounds — treat non-bleeding wounds (scratches, bites, deep wounds)
    AutoPilot_Telemetry.setDecision("bandage", "wound")
    if AutoPilot_Medical.check(player, false) then return true end

    -- Phase 4: temperature comfort check
    AutoPilot_Telemetry.setDecision("clothing", "temperature")
    if AutoPilot_Inventory.adjustClothing(player) then return true end

    -- 5. Tired: already checked above (fatigue -> sleep)

    -- 6. Exhausted: rest when endurance is critically low (stat ≤ 30%) or the
    -- exertion moodle is severe (level 3+).  This is the path that may walk to
    -- a bed and hand off to sleep; V5.4 left it untouched.
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    if endurance <= ENDURANCE_REST_MIN or enduranceMoodle >= 3 then
        AutoPilot_Telemetry.setDecision("rest", "low_endurance")
        return doRest(player)
    end

    -- 6b. V5.4: hold an in-progress rest so the character actually stays
    -- seated.  This gate used to sit at the TOP of check() where it outranked
    -- thirst, hunger and wounds; that was safe only because the hold was a
    -- single game minute.  Now that a rest lasts until endurance recovers, the
    -- gate lives HERE, below every real survival need, so drinking, eating and
    -- wound care still preempt it (threat is handled by Main before check()
    -- runs at all).  The hold releases the moment endurance reaches
    -- ENDURANCE_REST_TARGET, so it is a recovery condition, not a timer.
    local okNow, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if okNow and nowMs < restCooldownMs then
        local restTarget = tonumber(AutoPilot_Constants.ENDURANCE_REST_TARGET) or 0
        if endurance < restTarget then
            AutoPilot_Telemetry.setDecision("rest", "rest_cooldown")
            -- V5.8: the cycle is a rest, so the reported activity says rest.
            -- This branch queues nothing, which is exactly why it used to
            -- leave the panel showing the last training outcome.
            _setActivity("resting (recovering endurance)")
            return true  -- still resting; keep recovering
        end
        -- Recovered ahead of the maximum hold: stand up and resume the chain.
        restCooldownMs = 0
        print(string.format(
            "[Needs] Endurance recovered to %.0f%%; ending rest.", endurance * 100))
    end

    -- 7. Bored or Unhappy -> prefer tasty food, then read, then go outside.
    -- Kept above exercise: unhappiness slows every action (worse XP/hour) and
    -- these are quick one-shot fixes.
    -- NOTE: CharacterStat.SANITY reads HIGH when healthy, so it must not be used
    -- as a "sadness" signal (it made this branch fire nearly every idle cycle).
    -- The Unhappy moodle level is the correct low-mood source.
    local boredom     = AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM)
    local unhappyLvl  = safeMoodleLevel(player, MoodleType.Unhappy)
    if boredom >= BOREDOM_STAT_THRESHOLD
        or unhappyLvl >= AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD then
        -- Phase 3: when unhappy, prefer food that reduces boredom first
        if unhappyLvl >= AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD then
            local tastyFood, tastyCont = AutoPilot_Inventory.preferTastyFood(player)
            if tastyFood then
                AutoPilot_Telemetry.setDecision("eat", "unhappy")
                print("[Needs] Unhappy — eating tasty food: "
                    .. tostring(tastyFood:getName()))
                -- V4.9: transfer out of a bag first, then eat.
                local _, usable = AutoPilot_Utils.queueItemToMainInventory(
                    player, tastyFood, tastyCont)
                if usable then
                    AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, tastyFood, 1))
                    return true
                end
                print("[Needs] Tasty-food transfer refused: falling through to reading.")
            end
        end
        AutoPilot_Telemetry.setDecision("read", "boredom")
        if doRead(player) then return true end
        if boredom >= BOREDOM_STAT_THRESHOLD then
            AutoPilot_Telemetry.setDecision("outside", "boredom")
            local went = doGoOutside(player)
            if went then return true end
        end
    end

    -- 7b. V5.4: SIT TO RECOVER, closing the endurance dead zone.
    -- Training is gated at the exercise endurance minimum and the critical
    -- rest above at ENDURANCE_REST_MIN (30%).  Between those two numbers the old
    -- chain did neither: doExercise returned false with the comment "no action
    -- queued; endurance recovers passively while idle", and the cycle fell
    -- through to scavenging or to nothing.  A live run log showed the result:
    -- ZERO rest actions in ~16,000 ticks, idle streaks of 403 / 118 / 116 /
    -- 115 ticks logged as reason=no_action, and an observed endurance floor of
    -- 40% that never reached the 30% gate.  Sitting down recovers endurance
    -- far faster than standing idle, so the band is now spent recovering.
    -- Placed BELOW every survival and wellness need and ABOVE exercise: it
    -- replaces the idle that the exercise endurance gate was producing, and
    -- yields to anything more urgent.  sitOnly=true keeps beds (and therefore
    -- sleep) out of this path.
    --
    -- V5.7: the sit threshold is RUN-AWARE, and that is what keeps the dead
    -- zone shut under hysteresis.  The dead zone is not a property of any one
    -- number: it is the band between "will not sit" and "will not train", so
    -- it opens wherever those two disagree.
    --
    --   MID-RUN: sit only near the floor (ENDURANCE_SIT_MIN, 0.35).  Training
    --     is still allowed all the way down to EXERCISE_ENDURANCE_MIN (0.30),
    --     and sitting at 80% would cut short exactly the long productive run
    --     the hysteresis exists to produce.  The small gap above the floor is
    --     deliberate: the character goes and sits down rather than first
    --     dipping under the floor and ending the run on the stat.
    --
    --   NOT MID-RUN: sit all the way up to the RESUME gate.  A character who
    --     is not training and is below the resume gate has nothing else to
    --     do; standing there idle is strictly worse than sitting, which
    --     recovers endurance faster and moves it toward
    --     ENDURANCE_REST_TARGET.  This is the branch that catches the whole
    --     band the old single-gate code left idle, including a rest that hit
    --     its maximum hold before endurance recovered.
    --
    -- Because the not-mid-run threshold IS the resume gate, there is no value
    -- of endurance at which the character neither sits nor trains, for ANY
    -- combination of these sliders.
    local sitMin = tonumber(AutoPilot_Constants.ENDURANCE_SIT_MIN) or 0.35
    if not _inTrainingRun(player) then
        sitMin = math.max(sitMin, _exerciseEnduranceResume())
    end
    if endurance < sitMin then
        -- Sitting down is the end of any run that was still nominally open.
        AutoPilot_Needs.endTrainingRun()
        AutoPilot_Telemetry.setDecision("rest", "sit_recover")
        print(string.format(
            "[Needs] Endurance %.0f%% below sit threshold %.0f%%; sitting to recover.",
            endurance * 100, sitMin * 100))
        if doRest(player, true) then return true end
        -- Could not sit at all (no furniture, no ground square): fall through
        -- rather than burn the cycle.
    end

    -- 8. EXERCISE — the mod's primary purpose (V3.2 reorder: this sat at the
    -- bottom and proactive scavenging claimed every idle cycle, so training
    -- never ran).  Survival needs above always win; the endurance gates inside
    -- doExercise hand the cycle to the background chores below while
    -- recovering between sets.
    AutoPilot_Telemetry.setDecision("exercise", "training")
    local trained
    if AutoPilot_Leveler and AutoPilot_Leveler.check then
        trained = AutoPilot_Leveler.check(player)
    else
        trained = doExercise(player)
    end
    if trained then return true end

    -- 9. Proactive supply scavenge (rate-limited background chore)
    AutoPilot_Telemetry.setDecision("scavenge", "low_supplies")
    if doProactiveScavenge(player) then return true end

    -- V5.0: the priority chain used to end with a base-maintenance slot that
    -- ran a barricade re-check.  Barricading and woodworking left the mod's
    -- scope (an artifact of the broader auto-survival design), so the chain
    -- now ends at proactive scavenging.
    return false
end

--- Return how many consecutive empty loot cycles have accumulated (Phase 3).
--- Delegates to AutoPilot_Consumption, which now owns the counter.
function AutoPilot_Needs.getEmptyLootCycles()
    return AutoPilot_Consumption.getEmptyLootCycles()
end

--- Return how many exercise sets have been performed today.
function AutoPilot_Needs.getExerciseSetsToday()
    return _exerciseSetsToday
end

--- Return preferred exercise type based on STR vs FIT perk level.
--- Returns "strength", "fitness", or "either".
function AutoPilot_Needs.preferredExerciseType(player)
    local ok, strLvl, fitLvl = pcall(function()
        return player:getPerkLevel(Perks.Strength),
               player:getPerkLevel(Perks.Fitness)
    end)
    if not ok or strLvl == nil or fitLvl == nil then return "either" end
    if strLvl < fitLvl then
        print(("[Needs] STR %d < FIT %d — preferring strength."):format(strLvl, fitLvl))
        return "strength"
    elseif fitLvl < strLvl then
        print(("[Needs] FIT %d < STR %d — preferring fitness."):format(fitLvl, strLvl))
        return "fitness"
    end
    return "either"
end

-- Returns a snapshot of current stat levels for state reporting.
-- B42: Uses player:getStats():get(CharacterStat.XXX) pattern.
function AutoPilot_Needs.getMoodleSnapshot(player)
    return {
        hungry   = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.HUNGER) * 100),
        thirsty  = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.THIRST) * 100),
        tired    = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.FATIGUE) * 100),
        panicked = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.PANIC)),
        injured  = safeMoodleLevel(player, MoodleType.PAIN),
        sick     = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.SICKNESS)),
        stressed = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.STRESS)),
        bored    = math.floor(AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM)),
        -- SANITY reads high when healthy; the Unhappy moodle (0-4) is the real
        -- low-mood signal. Keep the "sad" key for log-parser compatibility.
        sad      = safeMoodleLevel(player, MoodleType.Unhappy),
    }
end

--- Force a single survival action if needed.
function AutoPilot_Needs.forceSurvival(player)
    return AutoPilot_Needs.check(player)
end

--- Public seam for the auto-leveler: run one exercise set with an explicit
--- focus ("strength" | "fitness").  Honors the endurance gates and the daily
--- set cap.  Returns true when an exercise action was queued.
function AutoPilot_Needs.trainExercise(player, focus)
    return doExercise(player, focus)
end

function AutoPilot_Needs.forceEat(player)
    return AutoPilot_Consumption.doEat(player)
end

function AutoPilot_Needs.forceDrink(player)
    return AutoPilot_Consumption.doDrink(player)
end

function AutoPilot_Needs.forceSleep(player)
    return AutoPilot_Sleep.doSleep(player)
end

--- @param sitOnly  V5.4: true to skip beds (sit-to-recover semantics).
function AutoPilot_Needs.forceRest(player, sitOnly)
    return doRest(player, sitOnly)
end

function AutoPilot_Needs.forceExercise(player)
    return doExercise(player)
end


function AutoPilot_Needs.printStatus(player)
    local moodles = AutoPilot_Needs.getMoodleSnapshot(player)
    print(string.format(
        "[Needs] Status: health=%.0f%% endurance=%.0f%% hungry=%d thirsty=%d tired=%d bored=%d",
        player:getHealth() * 100,
        AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE) * 100,
        moodles.hungry, moodles.thirsty, moodles.tired, moodles.bored
    ))
end
