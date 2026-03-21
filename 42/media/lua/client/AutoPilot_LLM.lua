-- AutoPilot_LLM.lua
-- File-based IPC with the Python LLM sidecar.
--
-- Flow:
--   1. Every LLM_WRITE_INTERVAL ticks, Lua writes state → Zomboid/Lua/auto_pilot_state.json
--   2. Python sidecar detects the change, calls Claude, writes → Zomboid/Lua/auto_pilot_cmd.json
--   3. Next tick, Lua reads the command file and stores the pending override.
--   4. AutoPilot_Main applies the override on the next idle cycle.

AutoPilot_LLM = {}

local LLM_WRITE_INTERVAL = 200  -- ticks between state writes (~10s at 20 ticks/s)
local llmTickCounter     = 0
local pendingCommand     = nil   -- {action=string, reason=string}

-- ── Logging ──────────────────────────────────────────────────────────────────

function AutoPilot_LLM.log(msg)
    print("[AutoPilot] " .. tostring(msg))
end

-- ── Minimal JSON encoder (no external deps) ──────────────────────────────────

local function jsonVal(v)
    local t = type(v)
    if t == "string"  then return '"' .. v:gsub('"', '\\"') .. '"' end
    if t == "number"  then return tostring(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "nil"     then return "null" end
    if t == "table" then
        -- detect array vs object by first key
        if #v > 0 then
            local parts = {}
            for _, item in ipairs(v) do table.insert(parts, jsonVal(item)) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                table.insert(parts, '"' .. tostring(k) .. '":' .. jsonVal(val))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return '"[unsupported]"'
end

-- ── State writer ──────────────────────────────────────────────────────────────

local function writeState(player)
    local moodles   = AutoPilot_Needs.getMoodleSnapshot(player)
    local negCount  = AutoPilot_Threat.countNegativeMoodles(player)
    local zombies   = AutoPilot_Threat.getNearbyZombies(player)
    local foodCnt, drinkCnt = AutoPilot_Inventory.getSupplyCounts(player)

    local wounds = AutoPilot_Medical.getWoundSnapshot(player)
    local hasWater = AutoPilot_Inventory.hasNearbyWaterSource(player)

    local invSummary    = AutoPilot_Inventory.getInventorySummary(player)
    local searchResults = AutoPilot_Inventory.getLastSearchResults()

    local hx, hy, hz, hr = AutoPilot_Home.getState()
    local homeSet = AutoPilot_Home.isSet()

    local state = {
        health              = math.floor((player:getHealth() or 1) * 100),
        endurance           = math.floor((player:getStats():get(CharacterStat.ENDURANCE) or 0) * 100),
        negative_moodles    = negCount,
        zombie_count_nearby = #zombies,
        has_food            = foodCnt > 0,
        has_drink           = drinkCnt > 0,
        has_weapon          = AutoPilot_Inventory.getBestWeapon(player) ~= nil,
        has_readable        = AutoPilot_Inventory.getReadable(player) ~= nil,
        has_water_source    = hasWater,
        strength_level      = player:getPerkLevel(Perks.Strength),
        fitness_level       = player:getPerkLevel(Perks.Fitness),
        is_outside          = player:getSquare():isOutside(),
        home_set            = homeSet,
        home_x              = hx or 0,
        home_y              = hy or 0,
        home_r              = hr or 0,
        moodles             = moodles,
        wounds              = wounds,
        inventory_summary   = invSummary,
        search_results      = searchResults,
        available_actions   = AutoPilot_Actions.getSchemaNames(),
    }

    local json = jsonVal(state)

    -- getFileWriter(path, append) — false = overwrite each time
    local fw = getFileWriter("auto_pilot_state.json", false, false)
    if fw then
        fw:write(json)
        fw:close()
    else
        AutoPilot_LLM.log("[LLM] Failed to open state file for writing.")
    end
end

-- ── Command reader ────────────────────────────────────────────────────────────

-- Minimal JSON string/bool extractor — only needs to parse {"action":"...","reason":"..."}
local function parseSimpleJson(s)
    local result = {}
    for key, val in s:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
        result[key] = val
    end
    for key, val in s:gmatch('"([^"]+)"%s*:%s*(true|false)') do
        result[key] = val == "true"
    end
    return result
end

local function readCommand()
    local fr = getFileReader("auto_pilot_cmd.json", false)
    if not fr then return nil end

    local line = fr:readLine()
    fr:close()

    if not line or line == "" then return nil end

    local cmd = parseSimpleJson(line)
    if cmd.action and cmd.action ~= "" then
        return cmd
    end
    return nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Returns the last LLM command (or nil). Clears it after reading.
function AutoPilot_LLM.consumeCommand()
    local cmd = pendingCommand
    pendingCommand = nil
    return cmd
end

-- Called every tick from AutoPilot_Main.
function AutoPilot_LLM.tick(player)
    llmTickCounter = llmTickCounter + 1
    if llmTickCounter < LLM_WRITE_INTERVAL then return end
    llmTickCounter = 0

    writeState(player)

    local cmd = readCommand()
    if cmd then
        AutoPilot_LLM.log("[LLM] Received command: " .. cmd.action ..
            " — " .. tostring(cmd.reason))
        pendingCommand = cmd
    end
end
