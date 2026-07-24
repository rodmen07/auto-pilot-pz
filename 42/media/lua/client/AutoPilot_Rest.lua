-- AutoPilot_Rest.lua
-- Rest-in-place behaviour (furniture/ground, not sleep) and seating
-- classification, extracted from AutoPilot_Needs.lua (code-health split,
-- 2026-07-20, third slice -- see AutoPilot_Consumption.lua and
-- AutoPilot_Sleep.lua for the first two). Unlike those two, doRest was NOT
-- a clean move on its own: restCooldownMs was read and written directly by
-- AutoPilot_Needs.check()'s own V5.4 rest-hold gate. A prior increment
-- (same day) built the seam first -- isRestHoldActive/extendRestHold/
-- clearRestHold, moved here now genuinely public since check() calls them
-- across the module boundary -- so this move is a real verbatim relocation,
-- not a redesign. seatPriorityForSprite was public
-- (AutoPilot_Needs.seatPriorityForSprite) and stays reachable there via a
-- one-line delegation. Moved verbatim; behavior is unchanged.

local function _apNoop(...) end
local print = _apNoop

AutoPilot_Rest = {}

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
function AutoPilot_Rest.seatPriorityForSprite(spriteName)
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

--- Classify an object as rest furniture and whether the character can SIT on it.
--- Per the user's 2026-07-24 design, RESTING treats all furniture TYPES equally
--- (chair = sofa = bench = bed); the only ranking preference is furniture the
--- character can actually sit on, i.e. the engine has SeatingManager tile
--- positions for it (mirrors ISRestAction.furnitureHasSittingData).  A dining
--- chair with no sit data still rests the character, but standing, so a sittable
--- seat is preferred when one is in range.
--- @return isFurniture, hasSeatingData
local function _restFurnitureInfo(obj)
    local okB, isBed = pcall(function()
        return obj:getSprite()
            and obj:getSprite():getProperties():has(IsoFlagType.bed)
    end)
    local isFurniture = (okB and isBed) or false
    if not isFurniture then
        local okN, spName = pcall(function()
            return obj:getSprite() and obj:getSprite():getName() or ""
        end)
        if okN and spName and AutoPilot_Rest.seatPriorityForSprite(spName) then
            isFurniture = true
        end
    end
    if not isFurniture then return false, false end
    local hasData = false
    pcall(function()
        hasData = SeatingManager.getInstance():getTilePositionCount(obj) > 0
    end)
    return true, hasData
end

--- Find the best rest furniture near the player.
--- @param player   the character
--- @param sitOnly  retained for signature compatibility; it NO LONGER excludes
---                 beds.  Per the user's 2026-07-24 design a bed is valid rest
---                 furniture -- the character SITS on it via ISRestAction and
---                 doRest never sleeps -- so the sit-to-recover path uses a bed
---                 when it is the nearest furniture.
local function findRestFurniture(player, sitOnly)   -- luacheck: ignore sitOnly
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local bestObj  = nil
    local bestZone = 99      -- 0 = inside the home circle (safe), 1 = outside
    local bestData = -1      -- 1 = has SeatingManager sit data, 0 = none; higher wins
    local bestDist = math.huge
    local outsideDist = AutoPilot_Constants.REST_OUTSIDE_SEARCH_DIST
        or REST_SEARCH_DIST
    local outsideDist2 = outsideDist * outsideDist

    AutoPilot_Utils.iterateNearbySquares(px, py, pz, REST_SEARCH_DIST, function(sq, dx, dy)
        local dist = dx * dx + dy * dy
        -- Outside-home furniture stays eligible only within the tighter
        -- REST_OUTSIDE_SEARCH_DIST -- a safety clamp on crossing unsecured
        -- ground.  isInside() returns true when no home is set, so an
        -- unconfigured game keeps the full radius.  The clamp applies to ALL
        -- rest furniture equally, beds included: a far bed is a long unsecured
        -- walk, so the ground stays the safer choice, exactly as for a far bench.
        local inside = AutoPilot_Home.isInside(sq)
        if not inside and dist > outsideDist2 then return false end
        local zone = inside and 0 or 1

        for i = 0, sq:getObjects():size() - 1 do
            local obj = sq:getObjects():get(i)
            local isFurniture, hasData = _restFurnitureInfo(obj)
            if isFurniture then
                local dataRank = hasData and 1 or 0
                -- Rank: safe zone first, then furniture the character can
                -- actually sit on, then nearest.  All furniture TYPES are equal.
                if zone < bestZone
                    or (zone == bestZone and dataRank > bestData)
                    or (zone == bestZone and dataRank == bestData and dist < bestDist)
                then
                    bestZone = zone
                    bestData = dataRank
                    bestDist = dist
                    bestObj  = obj
                end
            end
        end
        return false  -- always continue: want the best furniture, not the first
    end)

    return bestObj
end

--- onComplete chaser for the rest pathfind: SEAT the character with ISRestAction,
--- bound to the furniture the pathfinder actually resolved (goalFurnitureObject,
--- which for multi-tile sprite-grid furniture can differ from the selected one).
--- Mirrors ISWorldObjectContextMenu.onRestPathFound; useAnimations=true so the
--- sit-down animation plays when the furniture has SeatingManager sit data.
function AutoPilot_Rest._seatAfterPath(player, pathAction)
    if not (ISRestAction and ISRestAction.new) then return end
    local furniture = (pathAction and pathAction.goalFurnitureObject) or nil
    if not furniture then return end
    pcall(function()
        AutoPilot_Utils.queueModAction(ISRestAction:new(player, furniture, true))
    end)
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

-- Code-health seam (2026-07-20): restCooldownMs is read AND written from two
-- places that do not otherwise share any state -- doRest's own redundant
-- early-exit, and AutoPilot_Needs.check()'s V5.4 rest-hold gate, which reads
-- it to decide whether to keep holding, and clears it early when endurance
-- has recovered. Now that doRest has moved here, these three functions are
-- genuinely public: check() (still in AutoPilot_Needs.lua) calls them across
-- the module boundary they were built to bridge.
function AutoPilot_Rest.isRestHoldActive(nowMs)
    return nowMs < restCooldownMs
end

function AutoPilot_Rest.extendRestHold(nowMs)
    restCooldownMs = restHoldFrom(nowMs)
end

function AutoPilot_Rest.clearRestHold()
    restCooldownMs = 0
end

--- Queue a rest.
--- @param player   the character
--- @param sitOnly  when true, beds are skipped: this is the V5.4
---                 sit-to-recover path, which must not put a merely winded
---                 character to sleep.
function AutoPilot_Rest.doRest(player, sitOnly)
    local ok, now = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    local ms = ok and now or 0

    if AutoPilot_Rest.isRestHoldActive(ms) then
        -- Still inside the hold from an earlier rest: nothing new is queued,
        -- but the cycle IS a rest, so the reported activity has to say so.
        -- Without this write the panel could still be showing whatever the
        -- trainer last set before the rest began (the V5.8 report).
        AutoPilot_Needs.setActivity("resting (recovering endurance)")
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
            AutoPilot_Needs.setActivity("resting (sitting on the ground)")
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
            AutoPilot_Rest.extendRestHold(ms)
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

    -- V6 (2026-07-24, user design): RESTING = sit on ANY furniture (chair, sofa,
    -- bench, bed all equal), NEVER sleep.  Sleep is a separate, fatigue-driven
    -- action (AutoPilot_Sleep.doSleep).  Mirror the engine's own rest-on-furniture
    -- flow (ISWorldObjectContextMenu.onRest -> onRestPathFound): pathToSitOnFurniture
    -- WALKS to the furniture (it self-paths, so no AdjacentFreeTileFinder is needed
    -- and the old "no adjacent tile -> sit on the floor beside the bed" funnel is
    -- gone), then its onComplete queues ISRestAction(char, goalFurnitureObject, true)
    -- which actually SEATS the character.  V5.8 queued only pathToSitOnFurniture and
    -- dropped that chaser -- per the engine that seats nothing, which is why chairs
    -- read "Resting" while standing.  bAnySpriteGridObject=true matches the engine.
    if ISPathFindAction and ISPathFindAction.pathToSitOnFurniture then
        local okPath, pathAction = pcall(function()
            return ISPathFindAction:pathToSitOnFurniture(player, target, true)
        end)
        if okPath and pathAction then
            pcall(function()
                pathAction:setOnComplete(AutoPilot_Rest._seatAfterPath, player, pathAction)
            end)
            AutoPilot_Utils.queueModAction(pathAction)
            queued = true
        end
    end

    if queued then
        AutoPilot_Needs.setActivity("resting (seated on furniture)")
    else
        if queueGroundRest() then
            AutoPilot_Rest.extendRestHold(ms)
            return true
        end
        print("[Needs] Unable to queue a safe rest action.")
        return false
    end

    -- V5.4: was `ms + 60000`, i.e. sixty IN-GAME seconds (the clock is
    -- getGameTime():getCalender()), so the character stood back up after about
    -- one game minute and recovered nothing.  Now it holds up to
    -- REST_HOLD_MS and check() releases early at ENDURANCE_REST_TARGET.
    AutoPilot_Rest.extendRestHold(ms)
    return true
end
