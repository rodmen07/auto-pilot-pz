-- AutoPilot_Utils.lua
-- Shared utility functions used across multiple AutoPilot modules.
--
-- Load note: this file sorts last alphabetically ('U' > all peers).  All
-- functions here are referenced inside function bodies only, never at module
-- load time, so load order is irrelevant — every global is resolved when the
-- function is first *called*, not when the file is loaded.

AutoPilot_Utils = {}

-- Zero-length vector guard.  Used when normalising (dx, dy) to avoid
-- divide-by-zero when the target point coincides with the reference point.
AutoPilot_Utils.EPSILON = 0.001

-- ── Stat access ───────────────────────────────────────────────────────────────

--- Safe B42 stat getter.
-- B42 replaced all direct getters (:getHunger, :getThirst, …) with
-- player:getStats():get(CharacterStat.XXX).  The Stats object may be nil
-- during cell loading, so every access is wrapped in pcall.
-- @param player   IsoPlayer
-- @param charStat CharacterStat enum value
-- @return number  Stat value on success; 0 on any error.
function AutoPilot_Utils.safeStat(player, charStat)
    local ok, val = pcall(function()
        return player:getStats():get(charStat)
    end)
    if ok and type(val) == "number" then return val end
    return 0
end

-- ── Mod-action ownership registry (V4.5) ──────────────────────────────────────
-- Identity tracking for every timed action THIS MOD queues, so the safety
-- paths in Main (urgent-need interrupt, queue-thrash guard, F10 panic stop)
-- can distinguish mod-queued actions from actions the PLAYER queued (e.g. a
-- manual exercise from the vanilla fitness UI).  The registry is weak-keyed:
-- when the engine drops an action from the queue (completion or cancel) and
-- Lua collects it, its entry vanishes on its own, so the registry can never
-- leak and never permanently mark the queue as mod-owned.  A Lua reload
-- (e.g. MP server join) re-executes this file and starts an EMPTY registry;
-- anything still queued from before the reload then reads as foreign, which
-- fails safe: the mod refuses to touch actions it cannot prove are its own.
local _modActions = setmetatable({}, { __mode = "k" })

--- Mark an action table as queued by this mod.  Returns the action so call
--- sites can decorate in place.  Non-table values are ignored (nil-safe).
function AutoPilot_Utils.tagModAction(action)
    if type(action) == "table" then
        _modActions[action] = true
    end
    return action
end

--- True only for actions this mod queued (and has not untagged).
function AutoPilot_Utils.isModAction(action)
    return action ~= nil and _modActions[action] == true
end

--- Explicitly untag an action (used when the mod resolves a tracked
--- exercise set as completed or cancelled; GC would get there eventually,
--- the explicit clear just keeps the bookkeeping deterministic).
function AutoPilot_Utils.clearModAction(action)
    if action ~= nil then
        _modActions[action] = nil
    end
end

--- Tag + queue in one step: the standard path for every mod-queued action.
--- (ISTimedActionQueue.add is an already-verified 42.19 static; this helper
--- only decorates the action with ownership before the same call.)
function AutoPilot_Utils.queueModAction(action)
    AutoPilot_Utils.tagModAction(action)
    ISTimedActionQueue.add(action)
end

-- ── Square iterators ──────────────────────────────────────────────────────────

--- Iterate all squares within `radius` tiles of (cx, cy, cz) in a flat
-- dx/dy grid scan (row by row, left-to-right).  Calls callback(sq, dx, dy)
-- for every non-nil square returned by the cell.  If the callback returns
-- true, iteration stops early — use this for first-match searches.
--
-- Performance note: visits (2r+1)^2 squares.  Fine for r ≤ 80 in PZ because
-- most tiles outside the loaded cell chunk return nil and are skipped
-- cheaply.  For very tight inner loops prefer findNearestSquare.
--
-- @param cx, cy, cz  integer   world coordinates of the centre
-- @param radius      integer   inclusive tile radius to scan
-- @param callback    function(sq, dx, dy) → boolean?
function AutoPilot_Utils.iterateNearbySquares(cx, cy, cz, radius, callback)
    local cell = getCell()
    if not cell then return end
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(cx + dx, cy + dy, cz)
            if sq then
                if callback(sq, dx, dy) then return end
            end
        end
    end
end

--- Spiral outward from (cx, cy, cz) and return the first IsoGridSquare for
-- which predicate(sq) returns true, or nil if none is found within maxRadius.
-- Checks the centre first (r=0), then the ring at r=1, r=2, …, so the result
-- is guaranteed to be the nearest matching tile in Manhattan distance.
-- Appropriate for "find nearest free tile" use cases; NOT for large radii
-- (runtime is O(r³) — keep maxRadius ≤ 10).
--
-- @param cx, cy, cz  integer
-- @param maxRadius   integer   (recommend ≤ 10)
-- @param predicate   function(sq) → boolean
-- @return IsoGridSquare|nil
function AutoPilot_Utils.findNearestSquare(cx, cy, cz, maxRadius, predicate)
    local cell = getCell()
    if not cell then return nil end
    for r = 0, maxRadius do
        for ddx = -r, r do
            for ddy = -r, r do
                local sq = cell:getGridSquare(cx + ddx, cy + ddy, cz)
                if sq then
                    local ok, match = pcall(predicate, sq)
                    if ok and match then return sq end
                end
            end
        end
    end
    return nil
end
