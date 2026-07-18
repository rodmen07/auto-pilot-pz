-- AutoPilot_Options.lua
-- In-game configurability via 42.19's PZAPI.ModOptions
-- (client/PZAPI/ModOptions.lua — verified: create/addSlider/addKeyBind/
-- getOptions/getOption:getValue, plus per-instance apply()).
--
-- Values are copied into AutoPilot_Constants once per session (BEFORE the
-- Adaptive layer applies its death-learning deltas, so tuning composes) and
-- again whenever the player saves the options screen mid-game.

AutoPilot_Options = {}

local function _apNoop(...) end
local print = _apNoop

local _opts      = nil
local _appliedOnce = false

-- Slider definitions: option value * scale -> AutoPilot_Constants[key].
local DEFS = {
    { id = "dailyCap",     name = "Daily exercise set cap",
      min = 5,  max = 50, step = 1, key = "EXERCISE_DAILY_CAP" },
    { id = "endMin",       name = "Min endurance to start a set (%)",
      min = 10, max = 90, step = 5, key = "EXERCISE_ENDURANCE_MIN", scale = 0.01 },
    { id = "fatigueRec",   name = "Exercise XP-fatigue recovery (game hours)",
      min = 1,  max = 8,  step = 1, key = "EXERCISE_FATIGUE_RECOVERY_MS",
      scale = 3600000 },
    { id = "foodMin",      name = "Food stockpile minimum",
      min = 0,  max = 8,  step = 1, key = "SUPPLY_FOOD_MIN" },
    { id = "drinkMin",     name = "Drink stockpile minimum",
      min = 0,  max = 8,  step = 1, key = "SUPPLY_DRINK_MIN" },
    { id = "lootRadius",   name = "Proactive loot radius (tiles)",
      min = 10, max = 60, step = 5, key = "PROACTIVE_LOOT_RADIUS" },
    { id = "detRadius",    name = "Zombie detection radius (tiles)",
      min = 10, max = 40, step = 2, key = "DETECTION_RADIUS" },
    { id = "dangerRadius", name = "Close-danger radius (tiles)",
      min = 3,  max = 12, step = 1, key = "CLOSE_DANGER_RADIUS" },
}

--- Copy saved option values into AutoPilot_Constants.
function AutoPilot_Options.applyToConstants()
    if not _opts then return end
    pcall(function()
        for _, d in ipairs(DEFS) do
            local opt = _opts:getOption(d.id)
            if opt then
                local v = tonumber(opt:getValue())
                if v then
                    AutoPilot_Constants[d.key] = d.scale and (v * d.scale) or v
                end
            end
        end
    end)
    print("[Options] Applied to constants.")
end

--- Once-per-session apply; called from Main's tick before Adaptive.init.
function AutoPilot_Options.applyOnce()
    if _appliedOnce then return end
    _appliedOnce = true
    AutoPilot_Options.applyToConstants()
end

--- Rebindable keys with hard fallbacks (used by Main's key handler).
function AutoPilot_Options.getKey(id, default)
    if not _opts then return default end
    local ok, v = pcall(function() return _opts:getOption(id):getValue() end)
    v = ok and tonumber(v) or nil
    return v or default
end

-- ── Registration (at load; PZAPI is vanilla client lua, loads before mods) ───

pcall(function()
    if not (PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.create) then
        print("[Options] PZAPI.ModOptions unavailable; using defaults.")
        return
    end

    local o = PZAPI.ModOptions:create("AutoPilot", "AutoPilot Leveler")

    o:addTitle("Training")
    for i = 1, 3 do
        local d = DEFS[i]
        local cur = AutoPilot_Constants[d.key] or d.min
        if d.scale then cur = cur / d.scale end
        o:addSlider(d.id, d.name, d.min, d.max, d.step, cur)
    end

    o:addTitle("Survival Fail-Safe")
    for i = 4, #DEFS do
        local d = DEFS[i]
        local cur = AutoPilot_Constants[d.key] or d.min
        if d.scale then cur = cur / d.scale end
        o:addSlider(d.id, d.name, d.min, d.max, d.step, cur)
    end

    o:addTitle("Keys")
    o:addKeyBind("armKey",   "Arm / disarm", Keyboard.KEY_F10)
    o:addKeyBind("panelKey", "Leveler panel", Keyboard.KEY_F11)

    -- Saving the options screen re-applies live.
    function o:apply()
        AutoPilot_Options.applyToConstants()
    end

    _opts = o

    -- MP-join reload: the fresh registration starts with defaults; re-read
    -- the saved options file so values survive the reload (idempotent).
    pcall(function() PZAPI.ModOptions:load() end)
end)
