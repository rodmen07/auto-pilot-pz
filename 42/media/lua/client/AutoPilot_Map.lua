--- AutoPilot_Map.lua
--- Tracks visited buildings and depleted containers to avoid wasted re-loot trips.
-- SPLITSCREEN: Per-player depletion tables keyed by playerNum.

AutoPilot_Map = {}

local function _apNoop(...) end
local print = _apNoop

-- Per-player tables of "x,y,z" string keys for squares whose containers were found empty.
-- Keyed by playerNum (0-based integer from player:getPlayerNum()).
local _depletedByPlayer = {}
-- Max depleted entries per player before oldest are pruned (memory cap).
local DEPLETED_CAP = AutoPilot_Constants.DEPLETED_CAP

local function _squareKey(sq)
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
end

local function _getPlayerTable(pnum)
    local pn = pnum or 0
    if not _depletedByPlayer[pn] then
        _depletedByPlayer[pn] = {}
    end
    return _depletedByPlayer[pn]
end

--- Mark a square's container as depleted (empty after a loot attempt).
-- @param sq     IsoGridSquare
-- @param pnum   number|nil  0-based player number; defaults to 0.
function AutoPilot_Map.markDepleted(sq, pnum)
    local t = _getPlayerTable(pnum)
    local key = _squareKey(sq)
    t[key] = true
    -- Prune if over cap (remove arbitrary entries)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    if count > DEPLETED_CAP then
        local pruned = 0
        for k in pairs(t) do
            t[k] = nil
            pruned = pruned + 1
            if pruned >= 50 then break end
        end
    end
end

--- Return true if the square's container has been marked depleted for this player.
-- @param sq     IsoGridSquare
-- @param pnum   number|nil  0-based player number; defaults to 0.
function AutoPilot_Map.isDepleted(sq, pnum)
    local t = _getPlayerTable(pnum)
    return t[_squareKey(sq)] == true
end

--- Clear all depletion tracking for a player (e.g. after an in-game day passes).
-- @param pnum   number|nil  0-based player number; defaults to 0.
function AutoPilot_Map.resetDepleted(pnum)
    local pn = pnum or 0
    _depletedByPlayer[pn] = {}
    print("[Map] Depletion cache cleared for player " .. tostring(pn))
end

--- Return counts for state reporting for a specific player.
-- @param pnum   number|nil  0-based player number; defaults to 0.
function AutoPilot_Map.getStats(pnum)
    local t = _getPlayerTable(pnum)
    local depleted = 0
    for _ in pairs(t) do depleted = depleted + 1 end
    return { depleted_squares = depleted }
end

return AutoPilot_Map
