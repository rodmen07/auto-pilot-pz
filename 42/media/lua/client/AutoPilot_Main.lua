-- AutoPilot_Main.lua
-- Entry point. Registers the OnTick event and orchestrates all sub-modules.
--
-- Execution order each cycle:
--   1. LLM tick     — write state file, read any pending command
--   2. Threat       — highest priority; interrupts queue if zombies nearby
--   3. LLM cmd      — apply any pending LLM override when idle
--   4. Needs        — thirst/hunger/exhausted/tired/bored/exercise (when queue empty)

AutoPilot = {}

-- How often the main loop runs (in game ticks).
-- PZ runs at ~20 ticks/second; 15 ticks ≈ 0.75s between evaluations.
local TICK_INTERVAL = 15
local tickCounter   = 0
local enabled       = false

-- ── LLM command executor ──────────────────────────────────────────────────────

local LLM_ACTION_MAP = {
    eat      = function(p) AutoPilot_Needs.check(p) end,
    drink    = function(p) AutoPilot_Needs.check(p) end,
    sleep    = function(p)
        -- B42: ISSleepAction does not exist. Find a bed nearby or fall asleep in place.
        local px, py, pz = p:getX(), p:getY(), p:getZ()
        for dx = -5, 5 do
            for dy = -5, 5 do
                local sq = getCell():getGridSquare(px + dx, py + dy, pz)
                if sq then
                    for i = 0, sq:getObjects():size() - 1 do
                        local obj = sq:getObjects():get(i)
                        if obj and obj:getProperties() and obj:getProperties():Is("IsBed") then
                            ISTimedActionQueue.add(ISGetOnBedAction:new(p, obj, sq))
                            return
                        end
                    end
                end
            end
        end
        p:setAsleep(true)
        p:setAsleepTime(0.0)
    end,
    rest     = function(p)
        -- Clear queue and let passive endurance recovery kick in
        ISTimedActionQueue.clear(p)
    end,
    exercise = function(p) AutoPilot_Needs.check(p) end,  -- falls through to exercise
    outside  = function(p) AutoPilot_Needs.check(p) end,  -- falls through to go-outside
    fight    = function(p) AutoPilot_Threat.forceFight(p) end,
    flee     = function(p) AutoPilot_Threat.forceFlee(p) end,
    idle  = function(p) AutoPilot_Needs.check(p) end,  -- idle → exercise
}

local function applyLLMCommand(player, cmd)
    local fn = LLM_ACTION_MAP[cmd.action]
    if fn then
        AutoPilot_LLM.log("[Main] Applying LLM command: " .. cmd.action)
        fn(player)
    else
        AutoPilot_LLM.log("[Main] Unknown LLM action: " .. tostring(cmd.action))
    end
end

-- ── Main tick ─────────────────────────────────────────────────────────────────

local function onTick()
    if not enabled then return end

    tickCounter = tickCounter + 1
    if tickCounter < TICK_INTERVAL then return end
    tickCounter = 0

    local player = getPlayer()
    if not player or player:isDead() then return end

    -- 1. LLM housekeeping (write state, read command) — always runs
    AutoPilot_LLM.tick(player)

    -- 2. Threat check — can interrupt the action queue
    if AutoPilot_Threat.check(player) then return end

    -- 3 & 4 only run when the player has no queued actions
    if ISTimedActionQueue.isPlayerDoingAction(player) then return end

    -- 3. LLM override
    local cmd = AutoPilot_LLM.consumeCommand()
    if cmd then
        applyLLMCommand(player, cmd)
        return
    end

    -- 4. Needs state machine
    AutoPilot_Needs.check(player)
end

-- ── Toggle keybinding (F7) ────────────────────────────────────────────────────
-- Chat commands don't work in singleplayer. Press F7 to toggle AutoPilot on/off.

local function onKeyPressed(key)
    if key ~= Keyboard.KEY_F7 then return end
    enabled = not enabled
    local status = enabled and "ENABLED" or "DISABLED"
    local player = getPlayer()
    if player then player:Say("AutoPilot " .. status) end
    AutoPilot_LLM.log("[Main] AutoPilot toggled: " .. status)
end

-- ── Event registration ────────────────────────────────────────────────────────

Events.OnTick.Add(onTick)
Events.OnKeyPressed.Add(onKeyPressed)

AutoPilot_LLM.log("[Main] AutoPilot mod loaded. Press F7 to toggle on/off.")
