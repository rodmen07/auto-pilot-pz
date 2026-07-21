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
                    priority = AutoPilot_Rest.seatPriorityForSprite(spName)
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
        if queued then AutoPilot_Needs.setActivity("resting (using a bed)") end
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

        if queued then AutoPilot_Needs.setActivity("resting (seated on furniture)") end
    end

    if not queued then
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
