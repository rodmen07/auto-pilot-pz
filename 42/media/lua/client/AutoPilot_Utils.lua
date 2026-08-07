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

-- ── Carry capacity ────────────────────────────────────────────────────────────

--- Safe B42 moodle-level getter (0 when the moodle type or the Moodles object
--- is unavailable, matching the per-module readers in Needs and Exercise).
-- @return number  0-4 moodle level; 0 on any error.
local function safeMoodleLevel(player, moodleType)
    local ok, lvl = pcall(function()
        return player:getMoodles():getMoodleLevel(moodleType)
    end)
    if ok and type(lvl) == "number" then return lvl end
    return 0
end

--- True when `item` can be picked up without overloading the character.
--
-- Until this existed the mod had NO weight sense at all: every loot transfer
-- was queued regardless of what the character was already carrying, so its own
-- proactive scavenging could pile on Heavy Load — one of the unmanaged moodles
-- in the 2026-07-24 "negative moodles accumulate" report — and vanilla refuses
-- to let a heavily loaded character exercise at all
-- (client/ISUI/ISFitnessUI.lua:219), which is the mod's main job.
--
-- Two independent verified-surface checks, either of which refuses:
--
--   1. MoodleType.HEAVY_LOAD level >= AutoPilot_Constants.HEAVY_LOAD_LOOT_LIMIT.
--      The engine's own verdict on "too heavy"; the weight-to-moodle mapping is
--      Java-side, so this is read rather than recomputed.
--   2. ItemContainer:hasRoomFor(character, item) — the engine's per-item
--      capacity test, exactly as the foraging pickup menu uses it
--      (client/Foraging/ISBaseIcon.lua:127), backed by the same overload line
--      the engine drops items on: getCapacityWeight() + weight must stay within
--      getEffectiveCapacity(character) (shared/ActionManager.lua:11,
--      client/Foraging/ISBaseIcon.lua:105).
--
-- FAILS OPEN by design: if the engine gives no usable capacity reading, this
-- returns true and the mod loots exactly as it did before.  A missing or
-- renamed API must never stall the survival loop — the same reasoning as
-- safeStat degrading to 0.
--
-- @param player IsoPlayer
-- @param item   InventoryItem being considered for pickup (may be nil)
-- @return boolean true when the pickup is allowed.
function AutoPilot_Utils.hasCarryRoom(player, item)
    if player == nil then return true end

    local limit = AutoPilot_Constants and AutoPilot_Constants.HEAVY_LOAD_LOOT_LIMIT
    if type(limit) == "number"
        and safeMoodleLevel(player, MoodleType and MoodleType.HEAVY_LOAD) >= limit then
        return false
    end

    local inv
    local okInv = pcall(function() inv = player:getInventory() end)
    if not okInv or inv == nil then return true end

    -- Engine per-item test first: it knows about container rules this mod does
    -- not model.  Only an explicit false refuses; nil (method absent) falls
    -- through to the arithmetic below.
    local room
    local okRoom = pcall(function() room = inv:hasRoomFor(player, item) end)
    if okRoom and room == false then return false end

    -- Arithmetic fallback, for an engine build where hasRoomFor is unavailable.
    local carried, capacity, weight
    pcall(function() carried  = inv:getCapacityWeight() end)
    pcall(function() capacity = inv:getEffectiveCapacity(player) end)
    pcall(function() weight   = item:getActualWeight() end)
    if type(carried) ~= "number" or type(capacity) ~= "number" or capacity <= 0 then
        return true
    end
    if type(weight) ~= "number" then weight = 0 end
    return (carried + weight) <= capacity
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

-- ── Game-speed gate for queued walks ─────────────────────────────────────────
-- The engine refuses to RUN a queued walk above a fixed game-speed index:
-- ISWalkToTimedAction:isValid() ends `return getGameSpeed() <= 2`.  A mod that
-- does not know this queues a walk, the queue invalidates it on the same tick,
-- and the mod sees a "successful" flee that moved nobody -- forever, because
-- nothing about the situation changed.  See WALK_MAX_GAME_SPEED for the live
-- citation and the run-log evidence.

--- Current game-speed INDEX (0 paused, 1 normal, 2/3/4 fast-forward), or nil
--- when the engine global is unavailable (tests without the stub, and any
--- build that ever drops it).  Never raises.
---
--- Verified-surface note: getGameSpeed() is a real 42.19 client global -- the
--- engine's own code calls it bare at WalkToTimedAction.lua:7,
--- ISVehicleDashboard.lua:503 and ISReadABook.lua:382.
function AutoPilot_Utils.getGameSpeedIndex()
    local ok, idx = pcall(function() return getGameSpeed() end)
    if ok and type(idx) == "number" then return idx end
    return nil
end

--- Lower the game speed just far enough that a queued walk will actually run,
--- and only when it is currently too high.  Returns true only when this call
--- changed the speed.
---
--- Deliberately NOT a drop to real time: WALK_MAX_GAME_SPEED is index 2, which
--- is still fast-forward (x5), so an unattended run keeps most of its speed-up
--- and only gives up the two steps the engine will not walk at.
---
--- Deliberately NOT restored afterwards.  The mod never fights the player for
--- the speed control: it lowers the ceiling once, when it is about to need a
--- walk, and the player's next input wins outright.  Restoring a remembered
--- speed would override a player who deliberately slowed the game down.
---
--- A PAUSED game (index 0) is already <= the ceiling, so it is never resumed
--- by this helper -- unpausing on the mod's own initiative would be exactly the
--- kind of hijack the paragraph above rules out.
function AutoPilot_Utils.clampGameSpeedForWalk()
    local idx = AutoPilot_Utils.getGameSpeedIndex()
    local maxIdx = AutoPilot_Constants.WALK_MAX_GAME_SPEED
    if not idx or idx <= maxIdx then return false end

    local ok = pcall(function() setGameSpeed(maxIdx) end)
    if not ok then return false end

    -- Confirm rather than assume: if the engine refused, say so, so callers
    -- (and the run log) never record a clamp that did not happen.
    local after = AutoPilot_Utils.getGameSpeedIndex()
    return after ~= nil and after <= maxIdx
end

--- THE seam every walk in this mod passes through before it is dispatched.
---
--- Call this immediately before any ISWalkToTimedAction:new or
--- luautils.walkAdj in the shipped tree.  tests/test_walk_gate_coverage.lua
--- enforces exactly that, by function block, so a new walk site cannot land
--- un-gated the way four walkAdj sites in Inventory and Media silently did.
---
--- Why a seam and not one clamp per call site.  The engine's gate is
--- cross-cutting: it applies to every walk the mod will ever dispatch, in six
--- modules, and the call sites are NOT interchangeable in shape (three are
--- luautils.walkAdj with an ISWalkToTimedAction fallback, four are a plain
--- queued walk, one decorates the action with setOnComplete first).  Gating
--- them individually would mean re-deriving the same engine fact nine times
--- and would leave site ten to be discovered by a player.  One named seam plus
--- one coverage guard costs a line per site and cannot silently rot.
---
--- CRITICALLY, luautils.walkAdj needs this just as much as a direct queue
--- does: walkAdj ends in ISTimedActionQueue.add(ISWalkToTimedAction:new(...))
--- (42.19 shared/luautils.lua:147), the very action the engine invalidates.
--- Three of this mod's walkAdj sites carry an ISWalkToTimedAction fallback
--- that runs ONLY when walkAdj raises, so gating the fallback alone would have
--- left the path that actually executes un-gated in the normal case.
---
--- `label` names the walk in the console line so a player reading the log can
--- tell which behaviour bought the speed step.  The line prints only on the
--- transition, because clampGameSpeedForWalk returns true only when it really
--- changed the speed; once at the ceiling every later call is a silent no-op.
function AutoPilot_Utils.prepareWalk(label)
    if not AutoPilot_Utils.clampGameSpeedForWalk() then return false end
    print("[AutoPilot] Game speed lowered to index "
        .. tostring(AutoPilot_Constants.WALK_MAX_GAME_SPEED)
        .. ", the highest the engine will walk at, so the "
        .. tostring(label) .. " walk can actually run.")
    return true
end

-- ── Carried-inventory iteration (V4.8) ────────────────────────────────────────
-- player:getInventory():getItems() returns ONLY the top-level items of the main
-- inventory; it does not descend into worn or carried sub-containers.  Every
-- selector that scanned that flat list was therefore blind to anything stashed
-- in a backpack, fanny pack, holster or bag-in-a-bag, which is why a bandage in
-- a fanny pack never got used.  These helpers walk the whole carried tree.
-- (The mod already relied on recursive lookups elsewhere: the exercise gate
-- uses inv:contains(fullType, true).  This is the same idea, generalised.)

-- Deepest sub-container nesting walked by iteratePlayerItems.  Depth 0 is the
-- main inventory, so 3 covers a bag inside a bag inside a bag.  The bound keeps
-- the walk cheap on the survival cycle and guarantees termination even if the
-- engine ever hands back a cyclic container graph.
AutoPilot_Utils.PLAYER_ITEM_MAX_DEPTH = 3

-- Returns the container an inventory item itself carries, or nil when the item
-- is not a container.
--
-- Verified-surface note: getItemContainer() is the B42 accessor for an
-- InventoryContainer item's contents, and it exists ONLY on container items.
--
-- V5.1 (hotfix): the item must be type-checked with instanceof FIRST.  V4.8
-- called getItemContainer() on every carried item behind a pcall, reasoning
-- that a missing method would read as "not a container".  Functionally that
-- held, but on a real 42.19 client the call raises a JAVA-level exception on
-- every ordinary item, and pcall does NOT stop PZ logging it: the console
-- filled with "Exception thrown" stack traces and the in-game ERROR badge
-- climbed on every tick of the survival cycle.
--
-- This is the same lesson already recorded at AutoPilot_Inventory getBestWeapon
-- ("B42: instanceof avoids Java-level exceptions that pcall(isWeapon) still
-- logs"), so this now follows that established precedent.  instanceof is a
-- verified PZ global (declared in .luacheckrc, used by getBestWeapon).
local function _subContainer(item)
    if not item then return nil end
    if not instanceof(item, "InventoryContainer") then return nil end
    local ok, cont = pcall(function() return item:getItemContainer() end)
    if ok and cont then return cont end
    return nil
end

--- Iterate every item the player is carrying, including items inside worn or
--- carried sub-containers.  Depth-first, main inventory first, so top-level
--- items are still visited before anything nested (selectors that keep the
--- FIRST match therefore keep their old preference for a top-level item).
---
--- Only the player's own inventory tree is walked: no world scan, no square
--- iteration.  Every engine call is pcall-guarded so a single hostile item
--- cannot break the survival cycle.
---
--- @param player    IsoPlayer
--- @param callback  function(item, container, depth) -> boolean?
---                  Return true to stop iteration early.
--- @return boolean  true when the callback stopped iteration early.
function AutoPilot_Utils.iteratePlayerItems(player, callback)
    if not player or type(callback) ~= "function" then return false end
    local okInv, inv = pcall(function() return player:getInventory() end)
    if not okInv or not inv then return false end

    local seen    = {}     -- identity guard: a self-referential bag visits once
    local stopped = false

    local function walk(container, depth)
        if stopped or not container or seen[container] then return end
        seen[container] = true

        local okItems, items = pcall(function() return container:getItems() end)
        if not okItems or not items then return end
        local okSize, size = pcall(function() return items:size() end)
        if not okSize or type(size) ~= "number" then return end

        for i = 0, size - 1 do
            if stopped then return end
            local okGet, item = pcall(function() return items:get(i) end)
            if okGet and item then
                if callback(item, container, depth) then
                    stopped = true
                    return
                end
                if depth < AutoPilot_Utils.PLAYER_ITEM_MAX_DEPTH then
                    local sub = _subContainer(item)
                    if sub then walk(sub, depth + 1) end
                end
            end
        end
    end

    walk(inv, 0)
    return stopped
end

--- First carried item (at any container depth) for which predicate(item) is
--- true.  Predicate errors are swallowed and read as "no match".
--- @return item|nil, container|nil  the item and the container holding it.
function AutoPilot_Utils.findPlayerItem(player, predicate)
    if type(predicate) ~= "function" then return nil, nil end
    local found, foundContainer = nil, nil
    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        local ok, match = pcall(predicate, item)
        if ok and match then
            found, foundContainer = item, container
            return true
        end
        return false
    end)
    return found, foundContainer
end

-- ── Transfer before use (V4.9) ────────────────────────────────────────────────
-- V4.8 taught every selector to see items inside worn and carried
-- sub-containers, but FINDING an item is not the same as being able to USE it.
-- Project Zomboid actions (bandage, eat, drink, take pill, read, equip, wear)
-- act on the MAIN inventory: an item still nested in a backpack is selected and
-- then quietly does nothing.  Vanilla solves this in the inventory UI by
-- queueing an ISInventoryTransferAction into the main inventory and then
-- queueing the use action right behind it, letting ISTimedActionQueue run the
-- pair in order (the same shape this mod already uses for walk-then-transfer in
-- AutoPilot_Inventory._queueTransfer / placeItem and equip-then-walk in
-- AutoPilot_Threat).  This helper is the transfer half.
--
-- Verified surface: ISInventoryTransferAction:new(character, item,
-- sourceContainer, destContainer) is already called in exactly this argument
-- order in AutoPilot_Inventory (_queueTransfer, placeItem, bulkLoot) and
-- AutoPilot_Medical.lootNearbyBandage.

--- Move `item` from `holdingContainer` into the player's main inventory, when
--- (and only when) it is not already there.  Nothing is queued for an item that
--- already sits in the main inventory, so no redundant action is created.
---
--- The engine call is pcall-guarded exactly like the existing transfer sites:
--- a refused transfer (the MP-unsafe path) must never raise out of the survival
--- cycle, and it must not leave the caller acting on an item it cannot reach.
---
--- @param player           IsoPlayer
--- @param item             InventoryItem selected from the player's own tree
--- @param holdingContainer ItemContainer|nil  container reported by the V4.8
---                         helpers; nil means "caller does not know", which is
---                         treated as "already usable" (pre-V4.9 behavior).
--- @return boolean queued  true when a transfer action was queued.
--- @return boolean usable  true when the item can be acted on after this call
---                         (already in the main inventory, or a transfer is now
---                         queued ahead of the use action).  false ONLY when the
---                         transfer was needed and the engine refused it: the
---                         caller must then skip the use action.
function AutoPilot_Utils.queueItemToMainInventory(player, item, holdingContainer)
    if not player or not item or not holdingContainer then return false, true end

    local okInv, inv = pcall(function() return player:getInventory() end)
    if not okInv or not inv then return false, true end
    if holdingContainer == inv then return false, true end

    local okXfer = pcall(function()
        AutoPilot_Utils.queueModAction(ISInventoryTransferAction:new(
            player, item, holdingContainer, inv))
    end)
    if not okXfer then
        return false, false
    end
    return true, true
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
