--- AutoPilot_Map.lua
--- Tracks visited buildings and depleted containers to avoid wasted re-loot trips.
-- SPLITSCREEN-UNSAFE: single-player only.

AutoPilot_Map = {}

local function _apNoop(...) end
local print = _apNoop

-- Set of "x,y,z" string keys for squares whose containers were found empty.
local _depletedSquares = {}
-- Max depleted entries before oldest are pruned (memory cap).
local DEPLETED_CAP = 500

local function _squareKey(sq)
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
end

--- Mark a square's container as depleted (empty after a loot attempt).
function AutoPilot_Map.markDepleted(sq)
    local key = _squareKey(sq)
    _depletedSquares[key] = true
    -- Prune if over cap (remove arbitrary entries)
    local count = 0
    for _ in pairs(_depletedSquares) do count = count + 1 end
    if count > DEPLETED_CAP then
        local pruned = 0
        for k in pairs(_depletedSquares) do
            _depletedSquares[k] = nil
            pruned = pruned + 1
            if pruned >= 50 then break end
        end
    end
end

--- Return true if the square's container has been marked depleted.
function AutoPilot_Map.isDepleted(sq)
    return _depletedSquares[_squareKey(sq)] == true
end

--- Clear all depletion tracking (e.g. after an in-game day passes — containers respawn).
function AutoPilot_Map.resetDepleted()
    _depletedSquares = {}
    print("[Map] Depletion cache cleared.")
end

--- Return counts for state reporting.
function AutoPilot_Map.getStats()
    local depleted = 0
    for _ in pairs(_depletedSquares) do depleted = depleted + 1 end
    return { depleted_squares = depleted }
end

return AutoPilot_Map
