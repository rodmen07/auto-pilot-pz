-- AutoPilot_Combat.lua
-- Extended combat system: zombie type detection, tactical retreat, trap placement.
--
-- Phase 1 expansion: replaces simple fight/flee with adaptive tactics based on
-- threat type (runners vs walkers), environmental hazards, and group composition.

AutoPilot_Combat = {}

local function _apNoop(...) end
local print = _apNoop

-- ── Zombie Type Classification ──────────────────────────────────────────────

local ZOMBIE_TYPE = {
    WALKER = "walker",      -- slow, low threat individually
    RUNNER = "runner",      -- fast, high threat
    UNKNOWN = "unknown",
}

local function classifyZombie(zombie)
    if not zombie then return ZOMBIE_TYPE.UNKNOWN end

    -- B42: use zombie trait inspection
    local ok, isRunner = pcall(function()
        if zombie.isRunner then
            return zombie:isRunner()
        end
        return false
    end)

    if ok and isRunner then
        return ZOMBIE_TYPE.RUNNER
    end

    -- Fallback: check speed heuristic
    local okSpeed, speed = pcall(function()
        return zombie:getCurrentSpeed() or 0
    end)
    if okSpeed and speed > 0.5 then
        return ZOMBIE_TYPE.RUNNER
    end

    return ZOMBIE_TYPE.WALKER
end

-- ── Tactical Analysis ──────────────────────────────────────────────────────

--- Analyze threat composition and recommend tactic.
--- Returns: { tactic, escape_dist, hold_position_sq }
--- tactic: "fight", "flee", "hold_and_retreat", "ambush"
function AutoPilot_Combat.analyzeThreat(player, zombies)
    if not player or not zombies or #zombies == 0 then
        return {tactic = "idle"}
    end

    local runnerCount = 0
    local walkerCount = 0
    local totalCount = #zombies

    for _, z in ipairs(zombies) do
        if classifyZombie(z) == ZOMBIE_TYPE.RUNNER then
            runnerCount = runnerCount + 1
        else
            walkerCount = walkerCount + 1
        end
    end

    -- Decision tree based on composition
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local weapon = AutoPilot_Inventory and AutoPilot_Inventory.getBestWeapon(player) or nil
    local weaponUsable = weapon and weapon:getCondition() and weapon:getCondition() / (weapon:getConditionMax() or 1) >= 0.25

    -- Horde: always flee (regardless of composition)
    if totalCount >= 6 then
        return {tactic = "flee", reason = "horde"}
    end

    -- Heavy runner composition: flee
    if runnerCount >= 2 and not weaponUsable then
        return {tactic = "flee", reason = "runners_no_weapon"}
    end

    -- Pure walkers with weapon: hold and fight
    if runnerCount == 0 and weaponUsable and totalCount <= 3 then
        return {tactic = "fight", reason = "walkers_armed"}
    end

    -- Mixed with few runners and good weapon: tactical retreat
    if runnerCount <= 2 and weaponUsable then
        return {tactic = "hold_and_retreat", reason = "mixed_threat"}
    end

    -- Default to conservative flee
    return {tactic = "flee", reason = "default"}
end

--- Suggest a defensive position: nearby furniture/cover.
--- Returns a square, or nil if no good position found.
function AutoPilot_Combat.findDefensivePosition(player, radius)
    if not player then return nil end

    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local cell = getCell()
    if not cell then return nil end

    local bestSq = nil
    local bestScore = 0

    -- Prefer: indoors, narrow passages, furniture nearby
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            if sq and sq:getRoom() then  -- indoors
                local score = 10  -- base indoor bonus

                -- Bonus for walls on multiple sides
                local walls = 0
                for ddx = -1, 1 do
                    for ddy = -1, 1 do
                        local adj = cell:getGridSquare(px + dx + ddx, py + dy + ddy, pz)
                        if not adj or not adj:isFree(false) then
                            walls = walls + 1
                        end
                    end
                end
                score = score + walls

                -- Bonus for furniture (can use for cover)
                local hasObj = sq:getObjects():size() > 0
                if hasObj then score = score + 5 end

                if score > bestScore then
                    bestScore = score
                    bestSq = sq
                end
            end
        end
    end

    return bestSq
end

--- Get zombie type distribution (for telemetry).
function AutoPilot_Combat.getThreatsStats(zombies)
    local runners = 0
    local walkers = 0

    for _, z in ipairs(zombies or {}) do
        if classifyZombie(z) == ZOMBIE_TYPE.RUNNER then
            runners = runners + 1
        else
            walkers = walkers + 1
        end
    end

    return {
        total = runners + walkers,
        runners = runners,
        walkers = walkers,
    }
end

--- Estimate threat level (0.0-1.0).
function AutoPilot_Combat.getThreatLevel(zombies, player)
    if not zombies or #zombies == 0 then return 0.0 end

    local count = #zombies
    local runners = 0

    for _, z in ipairs(zombies) do
        if classifyZombie(z) == ZOMBIE_TYPE.RUNNER then
            runners = runners + 1
        end
    end

    -- Threat increases with count and runner ratio
    local countFactor = math.min(1.0, count / 6)
    local runnerFactor = runners / math.max(1, count)
    local threat = (countFactor * 0.5 + runnerFactor * 0.5)

    -- Apply player state modifiers
    if player then
        local health = player:getHealth() or 1.0
        if health < 0.5 then
            threat = threat * 1.5  -- weakened state increases threat
        end

        local endurance = AutoPilot_Utils and AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE) or 1.0
        if endurance < 0.3 then
            threat = threat * 1.3
        end
    end

    return math.min(1.0, threat)
end

print("[Combat] AutoPilot_Combat module loaded.")
