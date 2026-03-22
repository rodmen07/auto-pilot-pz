-- AutoPilot_Main.lua
-- Entry point. Registers the OnTick event and orchestrates all sub-modules.
--
-- SPLITSCREEN NOTE: Module-level variables (mode, tickCounter, actionCooldown)
-- are shared across all local players.  Splitscreen is NOT supported — the mod
-- targets a single local player (getPlayer() / player index 0) only.
--
-- Modes:
--   EXERCISE (F7) — autonomous: survival needs + exercise when idle
--   PILOT    (F8) — survival needs + LLM commands when idle (no exercise)
--
-- Both modes share identical survival logic (Needs.check).
-- The only difference: exercise mode exercises when idle, pilot mode
-- waits for LLM commands instead.
--
-- Execution order each cycle:
--   1. LLM tick     — write state file, read any pending command
--   2. Threat       — highest priority; interrupts queue if zombies nearby
--   3. Survival     — needs check (both modes, skip exercise in pilot)
--   4. LLM cmd      — apply any pending command (both modes)

AutoPilot = {}

-- How often the main loop runs (in game ticks).
-- PZ runs at ~20 ticks/second; 15 ticks ≈ 0.75s between evaluations.
local TICK_INTERVAL = 15
local tickCounter   = 0

-- Modes: "off", "exercise", "pilot"
local mode = "off"
local actionCooldown = 0
local ACTION_COOLDOWN_CYCLES = 4  -- ~3s at default tick rate

-- ── LLM command executor ──────────────────────────────────────────────────────

local LLM_ACTION_MAP = {
    eat      = function(p) AutoPilot_Needs.check(p) end,
    drink    = function(p) AutoPilot_Needs.check(p) end,
    sleep    = function(p) AutoPilot_Needs.check(p) end,
    rest     = function(p)
        ISTimedActionQueue.clear(p)
    end,
    exercise = function(p) AutoPilot_Needs.check(p) end,
    outside  = function(p) AutoPilot_Needs.check(p) end,
    fight    = function(p) AutoPilot_Threat.forceFight(p) end,
    flee     = function(p) AutoPilot_Threat.forceFlee(p) end,
    bandage  = function(p) AutoPilot_Medical.check(p, false) end,
    idle     = function(p) AutoPilot_Needs.check(p) end,
    search_item = function(p, cmd)
        local keyword = cmd.reason or ""
        if keyword == "" then
            AutoPilot_LLM.log("[Main] search_item: no keyword in reason field.")
            return
        end
        local results = AutoPilot_Inventory.searchItem(p, keyword)
        if results and #results > 0 then
            AutoPilot_LLM.log("[Main] search_item: found " .. #results .. " result(s) for '" .. keyword .. "'.")
        else
            AutoPilot_LLM.log("[Main] search_item: nothing found for '" .. keyword .. "'.")
        end
    end,
    loot_item = function(p, cmd)
        local keyword = cmd.reason or ""
        if keyword == "" then
            AutoPilot_LLM.log("[Main] loot_item: no keyword in reason field.")
            return
        end
        if AutoPilot_Inventory.lootItem(p, keyword) then
            AutoPilot_LLM.log("[Main] loot_item: looting '" .. keyword .. "'.")
        else
            AutoPilot_LLM.log("[Main] loot_item: could not find '" .. keyword .. "' nearby.")
        end
    end,
    place_item = function(p, cmd)
        local keyword = cmd.reason or ""
        if keyword == "" then
            AutoPilot_LLM.log("[Main] place_item: no keyword in reason field.")
            return
        end
        if AutoPilot_Inventory.placeItem(p, keyword) then
            AutoPilot_LLM.log("[Main] place_item: placing '" .. keyword .. "'.")
        else
            AutoPilot_LLM.log("[Main] place_item: failed for '" .. keyword .. "'.")
        end
    end,
    -- Delegate to AutoPilot_Actions — all walk_to logic lives there.
    walk_to = function(p, cmd)
        AutoPilot_Actions.execute(p, "walk_to", cmd.reason or "")
    end,
    stop     = function(p)
        ISTimedActionQueue.clear(p)
        AutoPilot_LLM.log("[Main] Stopped — queue cleared.")
    end,
    chain    = function(p, cmd)
        local steps = cmd.steps or ""
        AutoPilot_LLM.log("[Main] Chain received: " .. steps)
        AutoPilot_Actions.executeChain(p, steps)
    end,
    status   = function(p)
        local snap = AutoPilot_Needs.getMoodleSnapshot(p)
        local parts = {}
        for k, v in pairs(snap) do
            table.insert(parts, k .. "=" .. tostring(v))
        end
        AutoPilot_LLM.log("[Main] Status: " .. table.concat(parts, " "))
    end,
}

local function applyLLMCommand(player, cmd)
    local fn = LLM_ACTION_MAP[cmd.action]
    if fn then
        AutoPilot_LLM.log("[Main] Command: " .. cmd.action
            .. (cmd.reason and (" — " .. cmd.reason) or ""))
        fn(player, cmd)
    else
        AutoPilot_LLM.log("[Main] Unknown action: " .. tostring(cmd.action))
    end
end

-- ── Main tick ─────────────────────────────────────────────────────────────────

local function onTick()
    if mode == "off" then return end

    -- Safety: all files live in /client/, but guard defensively in case any
    -- code is ever loaded from /shared/.  getPlayer() returns nil server-side.
    if not isClient() then return end

    -- Guard: module state is not splitscreen-safe; disable in splitscreen.
    if getPlayerCount and getPlayerCount() > 1 then return end

    tickCounter = tickCounter + 1
    if tickCounter < TICK_INTERVAL then return end
    tickCounter = 0

    -- getPlayer() returns player index 0 only; splitscreen player 1+ is not
    -- supported.  All automation targets the single local player.
    local player = getPlayer()
    if not player or player:isDead() then return end

    -- Don't act while the character is asleep — PZ handles waking automatically
    local asleepOk, isAsleep = pcall(function() return player:isAsleep() end)
    if asleepOk and isAsleep then return end

    -- 1. LLM housekeeping (write state, read command) — always runs in both modes
    AutoPilot_LLM.tick(player)

    -- 2. Threat check — always runs in both modes (survival trumps everything)
    if AutoPilot_Threat.check(player) then
        actionCooldown = ACTION_COOLDOWN_CYCLES
        return
    end

    -- 3. Action cooldown
    if actionCooldown > 0 then
        actionCooldown = actionCooldown - 1
        return
    end

    -- 4. Let running actions complete; only interrupt exercise for urgent needs
    if ISTimedActionQueue.isPlayerDoingAction(player) then
        local actionQueue = ISTimedActionQueue.getTimedActionQueue(player)
        local currentAction = actionQueue and actionQueue.queue and actionQueue.queue[1]
        local isExercise = currentAction and currentAction.Type == "ISFitnessAction"
        if isExercise and AutoPilot_Needs.shouldInterrupt(player) then
            AutoPilot_LLM.log("[Main] Interrupting exercise for urgent need.")
            ISTimedActionQueue.clear(player)
        else
            return
        end
    end

    -- 5. Survival needs — runs in BOTH modes (identical logic).
    --    In pilot mode, skipExercise=true so idle falls through to LLM commands.
    local skipExercise = (mode == "pilot")
    if AutoPilot_Needs.check(player, skipExercise) then
        actionCooldown = ACTION_COOLDOWN_CYCLES
        return
    end

    -- 6. LLM/piped command — runs in BOTH modes
    local cmd = AutoPilot_LLM.consumeCommand()
    if cmd then
        applyLLMCommand(player, cmd)
        actionCooldown = ACTION_COOLDOWN_CYCLES
        return
    end
end

-- ── Keybindings ──────────────────────────────────────────────────────────────
-- F7: cycle off → exercise → off
-- F8: cycle off → pilot → off   (or switch between exercise/pilot if already on)

local function sayMode(_player)
    local label = mode:upper()
    -- Use print() only — player:Say() is world-visible in MP and reveals AFK status.
    AutoPilot_LLM.log("[Main] Mode: " .. label)
end

local function onKeyPressed(key)
    local player = getPlayer()

    if key == Keyboard.KEY_F7 then
        if mode == "exercise" then
            mode = "off"
        else
            mode = "exercise"
            -- Auto-set home on first enable if not already set
            if not AutoPilot_Home.isSet(player) then
                AutoPilot_Home.set(player)
                AutoPilot_LLM.log("[Main] AutoPilot enabled — home auto-set to current position.")
            end
        end
        sayMode(player)

    elseif key == Keyboard.KEY_F8 then
        if mode == "pilot" then
            mode = "off"
        else
            mode = "pilot"
            -- Auto-set home on first enable if not already set
            if not AutoPilot_Home.isSet(player) then
                AutoPilot_Home.set(player)
                AutoPilot_LLM.log("[Main] AutoPilot enabled — home auto-set to current position.")
            end
        end
        sayMode(player)

    elseif key == Keyboard.KEY_H then
        -- Set/reset home position while AutoPilot is active
        if mode ~= "off" and player then
            AutoPilot_Home.set(player)
        end
    end
end

-- ── Event registration ────────────────────────────────────────────────────────

Events.OnTick.Add(onTick)
Events.OnKeyPressed.Add(onKeyPressed)

AutoPilot_LLM.log("[Main] AutoPilot loaded. F7 = Exercise mode, F8 = Pilot mode.")
