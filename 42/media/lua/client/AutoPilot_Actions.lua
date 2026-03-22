-- AutoPilot_Actions.lua
-- Chainable action registry for the AutoPilot LLM system.
--
-- Chain wire format (written by sidecar, read by LLM.lua):
--   {"action":"chain","steps":"walk_to:north 30|loot_item:axe|eat","reason":"..."}
--
-- Steps are pipe-delimited. Each step is "actionName:param" or just "actionName".
-- Param is a single string (same semantics as the reason field for single actions).
--
-- Exposes:
--   AutoPilot_Actions.execute(player, name, param)   — run one registered action
--   AutoPilot_Actions.executeChain(player, stepsStr) — run a pipe-delimited chain
--   AutoPilot_Actions.getSchemaNames()               — list of "name:param" for state JSON

AutoPilot_Actions = {}

-- ── Schema ────────────────────────────────────────────────────────────────────
-- Sent to Claude in every state snapshot so it knows what chain steps exist.
-- Format: {name, param (empty = no param needed), desc}
AutoPilot_Actions.SCHEMA = {
    { name = "walk_to",     param = "direction [distance]",
      desc = "Walk toward a compass direction. E.g. 'north 30'" },
    { name = "loot_item",   param = "keyword",
      desc = "Pick up nearest item matching keyword from container" },
    { name = "search_item", param = "keyword",
      desc = "Search nearby containers; results in next snapshot" },
    { name = "place_item",  param = "keyword",
      desc = "Move item from inventory into the nearest container" },
    { name = "eat",         param = "",
      desc = "Eat the best available food from inventory" },
    { name = "drink",       param = "",
      desc = "Drink from nearby water source or best drink" },
    { name = "sleep",       param = "",
      desc = "Find a bed and sleep to restore fatigue" },
    { name = "rest",        param = "",
      desc = "Clear the action queue (interrupt current task)" },
    { name = "read",        param = "",
      desc = "Read a book or magazine to reduce boredom" },
    { name = "outside",     param = "",
      desc = "Walk to nearest outdoor square to reduce boredom" },
    { name = "bandage",     param = "",
      desc = "Apply bandages or treat wounds from inventory" },
    { name = "stop",        param = "",
      desc = "Clear the action queue" },
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Parse a "direction [distance]" param string (e.g. "north 30" or "ne").
-- Returns direction (lowercase), distance (number), or nil, nil on failure.
local function _parseDirection(param)
    local dir, dist = param:match("^(%a+)%s+(%d+)$")
    if dir then return dir:lower(), tonumber(dist) end
    dir = param:match("^(%a+)$")
    if dir then return dir:lower(), 20 end  -- 20-tile default when no range given
    return nil, nil
end

-- Translate a lowercase direction name and distance into a world (dx, dy) offset.
-- Returns dx, dy, or nil, nil if the direction string is not recognised.
local function _dirToOffset(dir, dist)
    if     dir == "north" or dir == "n"      then return 0,    -dist
    elseif dir == "south" or dir == "s"      then return 0,     dist
    elseif dir == "east"  or dir == "e"      then return  dist,  0
    elseif dir == "west"  or dir == "w"      then return -dist,  0
    elseif dir == "ne" or dir == "northeast" then return  dist, -dist
    elseif dir == "nw" or dir == "northwest" then return -dist, -dist
    elseif dir == "se" or dir == "southeast" then return  dist,  dist
    elseif dir == "sw" or dir == "southwest" then return -dist,  dist
    end
    return nil, nil
end

-- ── Handlers ──────────────────────────────────────────────────────────────────

local function handleWalkTo(player, param)
    -- Guard: if home is not set, block all walking (exercise in-place only)
    if not AutoPilot_Home.isSet(player) then
        AutoPilot_LLM.log("[Actions] walk_to: blocked — home not set.")
        return false
    end

    local dir, dist = _parseDirection(param)
    if not dir then
        AutoPilot_LLM.log("[Actions] walk_to: cannot parse '" .. tostring(param) .. "'")
        return false
    end

    local dx, dy = _dirToOffset(dir, dist)
    if not dx then
        AutoPilot_LLM.log("[Actions] walk_to: unknown direction '" .. dir .. "'")
        return false
    end

    local px = player:getX() + dx
    local py = player:getY() + dy
    local pz = player:getZ()

    local cell = getCell()
    if not cell then
        AutoPilot_LLM.log("[Actions] walk_to: cell not loaded yet — skipping.")
        return false
    end

    -- Find a walkable square near the target (avoid walls)
    local targetSq = nil
    for r = 0, 5 do
        for ddx = -r, r do
            for ddy = -r, r do
                local sq = cell:getGridSquare(px + ddx, py + ddy, pz)
                if sq and sq:isFree(false) then
                    targetSq = sq
                    break
                end
            end
            if targetSq then break end
        end
        if targetSq then break end
    end

    if not targetSq then
        AutoPilot_LLM.log("[Actions] walk_to: no walkable square near target.")
        return false
    end

    -- Clamp through home bounds; log a warning if the target was adjusted
    local clampedSq = AutoPilot_Home.clampSq(targetSq, player)
    if clampedSq == nil then
        AutoPilot_LLM.log("[Actions] walk_to: target outside home bounds — no in-bounds square found.")
        return false
    end
    if clampedSq ~= targetSq then
        AutoPilot_LLM.log(string.format(
            "[Actions] walk_to: clamped to home bounds (%d,%d → %d,%d).",
            targetSq:getX(), targetSq:getY(), clampedSq:getX(), clampedSq:getY()))
        targetSq = clampedSq
    end

    -- Let ISWalkToTimedAction handle movement speed internally (MP-safe).
    ISTimedActionQueue.add(ISWalkToTimedAction:new(player, targetSq))
    return true
end

local HANDLERS = {
    walk_to = handleWalkTo,

    loot_item = function(player, param)
        return AutoPilot_Inventory.lootItem(player, param)
    end,

    search_item = function(player, param)
        AutoPilot_Inventory.searchItem(player, param)
        return true
    end,

    place_item = function(player, param)
        return AutoPilot_Inventory.placeItem(player, param)
    end,

    eat = function(player, _)
        local food = AutoPilot_Inventory.getBestFood(player)
        if food then
            ISTimedActionQueue.add(ISEatFoodAction:new(player, food, 1))
            return true
        end
        AutoPilot_Inventory.lootNearbyFood(player)
        return false
    end,

    drink = function(player, _)
        local waterObj = AutoPilot_Inventory.findWaterSource(player)
        if waterObj then
            AutoPilot_Inventory.refillWaterContainer(player, waterObj)
            return AutoPilot_Inventory.drinkFromSource(player, waterObj)
        end
        local drink = AutoPilot_Inventory.getBestDrink(player)
        if drink then
            ISTimedActionQueue.add(ISEatFoodAction:new(player, drink, 1))
            return true
        end
        AutoPilot_Inventory.lootNearbyDrink(player)
        return false
    end,

    -- Delegate to the Needs module's full bed-search + sleep logic.
    -- AutoPilot_Needs.trySleep is exposed at the bottom of AutoPilot_Needs.lua.
    sleep = function(player, _)
        return AutoPilot_Needs.trySleep(player)
    end,

    rest = function(player, _)
        ISTimedActionQueue.clear(player)
        return true
    end,

    read = function(player, _)
        local book = AutoPilot_Inventory.getReadable(player)
        if not book then return false end
        local ok, _ = pcall(function()
            ISTimedActionQueue.add(ISReadABook:new(player, book))
        end)
        return ok
    end,

    -- Delegate to Needs.tryGoOutside for the outdoor-square-search logic.
    outside = function(player, _)
        return AutoPilot_Needs.tryGoOutside(player)
    end,

    bandage = function(player, _)
        return AutoPilot_Medical.check(player, false)
    end,

    stop = function(player, _)
        ISTimedActionQueue.clear(player)
        return true
    end,
}

-- ── Public API ────────────────────────────────────────────────────────────────

--- Run a single registered action.
--- @param player  IsoPlayer
--- @param name    string   action key from HANDLERS
--- @param param   string   single parameter string (may be empty)
--- @return boolean  true if the action was dispatched without error
function AutoPilot_Actions.execute(player, name, param)
    local fn = HANDLERS[name]
    if not fn then
        AutoPilot_LLM.log("[Actions] Unknown action: " .. tostring(name))
        return false
    end
    local ok, result = pcall(fn, player, param or "")
    if not ok then
        AutoPilot_LLM.log("[Actions] Error in '" .. tostring(name)
            .. "': " .. tostring(result))
        return false
    end
    return result == true
end

--- Execute a pipe-delimited chain of steps by queueing them all at once.
--- PZ's ISTimedActionQueue runs queued actions sequentially, so adding them
--- in a loop produces exactly the intended ordered sequence.
---
--- @param player    IsoPlayer
--- @param stepsStr  string  e.g. "walk_to:north 30|loot_item:axe|eat"
function AutoPilot_Actions.executeChain(player, stepsStr)
    if not stepsStr or stepsStr == "" then
        AutoPilot_LLM.log("[Actions] executeChain: empty steps string.")
        return
    end

    local count = 0
    -- Append trailing pipe so the last token is captured by the gmatch.
    for step in (stepsStr .. "|"):gmatch("([^|]*)|") do
        step = step:match("^%s*(.-)%s*$")   -- trim whitespace
        if step ~= "" then
            -- Split on the first colon only.
            local name, param = step:match("^([^:]+):?(.*)$")
            name  = name  and name:match("^%s*(.-)%s*$") or ""
            param = param and param:match("^%s*(.-)%s*$") or ""

            if name ~= "" then
                AutoPilot_LLM.log("[Actions] Chain[" .. (count + 1) .. "]: "
                    .. name .. (param ~= "" and (":" .. param) or ""))
                AutoPilot_Actions.execute(player, name, param)
                count = count + 1
            end
        end
    end

    AutoPilot_LLM.log("[Actions] Chain complete: " .. count .. " step(s) queued.")
end

--- Returns a list of "name:param" strings for the state JSON.
--- Actions with no param omit the colon.
function AutoPilot_Actions.getSchemaNames()
    local names = {}
    for _, entry in ipairs(AutoPilot_Actions.SCHEMA) do
        if entry.param ~= "" then
            table.insert(names, entry.name .. ":" .. entry.param)
        else
            table.insert(names, entry.name)
        end
    end
    return names
end
