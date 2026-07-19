-- AutoPilot_Options.lua
-- In-game configurability via 42.19's PZAPI.ModOptions
-- (client/PZAPI/ModOptions.lua — verified: create/addSlider/addKeyBind/
-- getOptions/getOption:getValue, plus per-instance apply()).
--
-- Values are copied into AutoPilot_Constants once per session (BEFORE the
-- Adaptive layer applies its death-learning deltas, so tuning composes) and
-- again whenever the player saves the options screen mid-game.
--
-- V4.3 (C3): also registers the weekly training-program selector; the pick
-- lands in AutoPilot_Constants.TRAINING_PROGRAM, which AutoPilot_Leveler
-- reads live at the exercise slot (the scheduler logic itself lives there).

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

-- V4.3 (C3): map the training-program option value to a program id.  The
-- program table itself lives in AutoPilot_Leveler (pure, unit-tested);
-- this file only translates the widget value.  The value may arrive as a
-- 1-based index (slider fallback, and the combobox's numeric form) or as
-- the display text; anything unmappable returns nil so the constant keeps
-- its current value instead of guessing.
local function _programIdFromValue(v)
    if not (AutoPilot_Leveler and AutoPilot_Leveler.PROGRAMS) then return nil end
    local progs = AutoPilot_Leveler.PROGRAMS
    local n = tonumber(v)
    if n then
        local p = progs[math.floor(n)]
        return p and p.id or nil
    end
    if type(v) == "string" then
        for _, p in ipairs(progs) do
            if v == p.id or v == p.name then return p.id end
        end
    end
    return nil
end

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
        -- V4.3 (C3): training program.  Lands in the live-read constant the
        -- Leveler resolves at every exercise slot, so an options-save mid
        -- session takes effect on the very next cycle.
        local progOpt = _opts:getOption("program")
        if progOpt then
            local id = _programIdFromValue(progOpt:getValue())
            if id then AutoPilot_Constants.TRAINING_PROGRAM = id end
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

    -- V4.3 (C3): training-program selector.  The program table and every
    -- bit of day-resolution logic live in AutoPilot_Leveler; this block
    -- only registers the control.  addComboBox is NOT in the mock's
    -- verified 42.19 record, so it is existence-checked inside its OWN
    -- pcall (a failure there must not kill the sliders above) and a slider
    -- over the 1-based program indices (verified surface) is the fallback;
    -- either way the picked value flows through applyToConstants into the
    -- live-read AutoPilot_Constants.TRAINING_PROGRAM.  Playtest verifies
    -- the dropdown itself, same as every control on this page (the whole
    -- ModOptions surface is a documented coverage gap).
    local progNames, curIndex = {}, 1
    if AutoPilot_Leveler and AutoPilot_Leveler.PROGRAMS then
        for i, p in ipairs(AutoPilot_Leveler.PROGRAMS) do
            progNames[i] = p.name
            if AutoPilot_Constants.TRAINING_PROGRAM == p.id then
                curIndex = i
            end
        end
    end
    if #progNames > 0 then
        local okCombo = type(o.addComboBox) == "function" and pcall(function()
            o:addComboBox("program", "Training program", progNames, curIndex)
        end)
        if not okCombo then
            o:addSlider("program",
                "Training program (1 Balanced, 2 Strength emphasis,"
                .. " 3 Fitness emphasis, 4 Alternating, 5 Rest-day split)",
                1, #progNames, 1, curIndex)
        end
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
