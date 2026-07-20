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
--
-- V4.4: also registers the on-screen action/intention HUD toggle, landing
-- in AutoPilot_Constants.HUD_SHOW_ACTION (read live by AutoPilot_Main's
-- status-HUD line; default on).
--
-- V5.4: three endurance-recovery sliders join the Survival Fail-Safe group
-- (sit threshold, stand-up target, maximum time seated).  Same live-read seam
-- as the V4.7 pair below; defaults reproduce the shipped behaviour.
--
-- V4.7: the hunger and thirst trigger points join the Survival Fail-Safe
-- group as percentage sliders (same scale = 0.01 style as the endurance
-- minimum).  Both write constants AutoPilot_Needs.check re-reads at every
-- decision, so an options-save retunes eating and drinking mid-session with
-- no reload.  Defaults stay at 20%.
--
-- V5.5 (BUG FIX): registration is no longer a bare file-load side effect.
-- The pre-V5.5 file asserted "PZAPI is vanilla client lua, loads before
-- mods" and registered inline; on a real 42.19 client that assumption is
-- false (console.txt: 'require("pzapi/ui/ui") failed'), so
-- PZAPI.ModOptions was nil when this file ran and NOTHING registered.  The
-- user-visible result was "I don't see where the settings are configurable
-- in-game": ~/Zomboid/Lua/ModOptions.ini stayed 0 bytes and mods_options.ini
-- never grew an [AutoPilot] section, while other mods' sections were there.
-- Every option this project ever shipped was inert (V4.3 program selector,
-- V4.4 HUD toggle, V4.5 backoff, V4.6 daily cap, V4.7 hunger/thirst, V5.4
-- rest sliders, both keybinds).  Registration now retries on events and the
-- failure is recorded loudly instead of being swallowed by the debug-print
-- shadow below.  No default, range or DEFS entry changed.

AutoPilot_Options = {}

local function _apNoop(...) end
local print = _apNoop

local _opts      = nil
local _appliedOnce = false

-- ── V5.5 registration state ─────────────────────────────────────────────────
-- _registered flips exactly once, and every entry point funnels through
-- _register(), so PZAPI.ModOptions:create is called at most once per Lua
-- load no matter how many retries fire.  That is the idempotence guarantee:
-- no duplicate page, no duplicate sliders, no duplicate keybinds.
local _registered   = false
local _failureNoted = false
-- OnTick runs per frame, so this is a few seconds of grace for a slow or
-- out-of-order PZAPI load before the failure is written to the run log.
-- Retrying continues past it (the check is one nil test per tick); only the
-- diagnostic is one-shot.
local RETRY_TICKS = 200
local _ticks      = 0

-- Slider definitions: option value * scale -> AutoPilot_Constants[key].
local DEFS = {
    -- V4.6: 0 (the default) = unlimited.  XP gain is the real limiter:
    -- training stops when an exercise stops paying XP (see the XP-fatigue
    -- recovery slider below), so this is only an opt-in hard ceiling.
    { id = "dailyCap",     name = "Daily exercise set cap (0 = unlimited; XP gain is the real limiter)",
      min = 0,  max = 50, step = 1, key = "EXERCISE_DAILY_CAP" },
    { id = "endMin",       name = "Min endurance to start a set (%)",
      min = 10, max = 90, step = 5, key = "EXERCISE_ENDURANCE_MIN", scale = 0.01 },
    { id = "fatigueRec",   name = "Exercise XP-fatigue recovery (game hours)",
      min = 1,  max = 8,  step = 1, key = "EXERCISE_FATIGUE_RECOVERY_MS",
      scale = 3600000 },
    -- V4.5: how long training holds off after the player intervenes in an
    -- exercise (manual cancel, manual training, F10 panic stop).  0 = off.
    { id = "backoffMin",   name = "Training backoff after manual cancel (game minutes)",
      min = 0,  max = 60, step = 5, key = "EXERCISE_BACKOFF_MINUTES" },
    -- V4.7: when the survival fail-safe decides it is time to eat or drink.
    -- Both land in constants AutoPilot_Needs.check re-reads at every decision
    -- (the V3.3 live-read pattern), so a save takes effect on the next cycle.
    -- Defaults are unchanged at 20%: the sliders exist so a player who never
    -- sees the bot eat can lower the trigger instead of assuming it is broken.
    { id = "hungerPct",    name = "Eat when hunger reaches (%)",
      min = 5,  max = 50, step = 5, key = "HUNGER_THRESHOLD", scale = 0.01 },
    { id = "thirstPct",    name = "Drink when thirst reaches (%)",
      min = 5,  max = 50, step = 5, key = "THIRST_THRESHOLD", scale = 0.01 },
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
    -- V5.4: endurance recovery.  Same live-read seam as the V4.7 pair above:
    -- AutoPilot_Needs.check re-reads all three at every decision, so a save
    -- retunes resting mid-session with no reload.  sitPct is what closes the
    -- old dead zone (training gated at 50%, resting at 30%, nothing in
    -- between); restTargetPct must stay ABOVE it or the character sits and
    -- stands at the same number.
    { id = "sitPct",       name = "Sit to recover when endurance falls below (%)",
      min = 10, max = 90, step = 5, key = "ENDURANCE_SIT_MIN", scale = 0.01 },
    { id = "restTargetPct", name = "Stay seated until endurance reaches (%)",
      min = 20, max = 100, step = 5, key = "ENDURANCE_REST_TARGET", scale = 0.01 },
    { id = "restHoldMin",  name = "Max time seated per rest (game minutes)",
      min = 5,  max = 120, step = 5, key = "REST_HOLD_MS", scale = 60000 },
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
        -- V4.4: on-screen action/intention HUD toggle.  Same live-read
        -- pattern as the training program above.
        local hudOpt = _opts:getOption("showActionHud")
        if hudOpt then
            local v = tonumber(hudOpt:getValue())
            if v then AutoPilot_Constants.HUD_SHOW_ACTION = v end
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

--- V5.5: did the in-game mod options page actually come into existence?
--- False means every option above is sitting on its compiled-in default and
--- there is no settings entry to find in the menus.  Read by the F11 panel
--- (AutoPilot_UI.optionsWarningLine) and by tests.
--- @return boolean
function AutoPilot_Options.isRegistered()
    return _registered
end

-- ── V5.5 loud failure channel ───────────────────────────────────────────────
-- The pre-V5.5 diagnostic was a print(), and this file shadows print with a
-- noop on purpose (the other messages here are debug chatter), so the one
-- message that mattered never reached console.txt.  That single line of
-- shadowing is why a completely dead options page survived six releases.
-- The replacement writes ONE line to the telemetry run log, which is a file
-- the project already owns, already ships tooling for (triage_run_log.py),
-- and already asks users to attach to bug reports.  It is preferred over
-- HaloTextHelper here because a startup condition should not put text on a
-- player's screen every session; the F11 panel carries the on-screen half.
-- Written with a leading "#" so triage_run_log.py reads it as a comment
-- rather than counting it as a malformed telemetry line.
local function _noteUnavailable()
    if _failureNoted then return end
    _failureNoted = true
    if type(getFileWriter) ~= "function" then return end
    pcall(function()
        -- (name, createIfNotExist, append): append MUST be true or this
        -- truncates the whole run log (the V2.1 one-line-log bug).
        local w = getFileWriter("auto_pilot_run.log", true, true)
        if not w then return end
        w:write("# AutoPilot V5.5: PZAPI.ModOptions never became available;"
            .. " the in-game mod options page did NOT register."
            .. " Every AutoPilot option is using its compiled-in default"
            .. " and there is no settings entry to find in the menus.\n")
        w:close()
    end)
end

-- ── Registration ────────────────────────────────────────────────────────────
-- The page builder itself is unchanged from V5.4 (same controls, same order,
-- same seeds); only WHEN it runs changed.  It is a named function now so the
-- retry path below can call it more than once without duplicating anything.
local function _buildPage()
    local o = PZAPI.ModOptions:create("AutoPilot", "AutoPilot Leveler")

    o:addTitle("Training")
    -- First 4 DEFS are the Training group (V4.5 added backoffMin as #4).
    for i = 1, 4 do
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
    for i = 5, #DEFS do
        local d = DEFS[i]
        local cur = AutoPilot_Constants[d.key] or d.min
        if d.scale then cur = cur / d.scale end
        o:addSlider(d.id, d.name, d.min, d.max, d.step, cur)
    end

    o:addTitle("Display")
    -- V4.4: on-screen action/intention line (read-only presentation; see
    -- AutoPilot_Main.getActionIntention).  addCheckBox is not in the
    -- verified 42.19 record (same gap as addComboBox above), so this reuses
    -- the already-verified addSlider surface as a 0/1 toggle, same pattern
    -- as every other DEFS-style control on this page.
    do
        local cur = AutoPilot_Constants.HUD_SHOW_ACTION
        if cur == nil then cur = 1 end
        o:addSlider("showActionHud",
            "Show current action on HUD (0 off, 1 on)", 0, 1, 1, cur)
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
    if type(PZAPI.ModOptions.load) == "function" then
        pcall(function() PZAPI.ModOptions:load() end)
    end
end

--- Register the page if PZAPI is available; idempotent and safe to spam.
--- Type-checked rather than pcall-probed: pcall does NOT stop PZ logging a
--- Java exception, which is what the V5.1 hotfix was about.
--- @return boolean  true once the page exists
local function _register()
    if _registered then return true end
    if not (PZAPI and PZAPI.ModOptions
            and type(PZAPI.ModOptions.create) == "function") then
        return false
    end
    -- A partial failure mid-build must not kill this file's load: a Lua error
    -- escaping here would stop every alphabetically-later module (Session
    -- History, Telemetry, Threat, UI...) from loading at all, which is the
    -- exact failure mode documented at the bottom of AutoPilot_Main.
    local ok = pcall(_buildPage)
    if ok and _opts then _registered = true end
    return _registered
end

-- Attempt 1: at file load.  Free and correct when PZAPI really did load
-- first; this is the only path V5.4 and earlier had.
_register()

-- Attempts 2..n: events.  Only wired when attempt 1 failed, so a healthy
-- client pays nothing.
--
-- Event choice, and why these two:
--   * OnMainMenuEnter is already a verified surface in this mod (it carries
--     the session-end telemetry hook in AutoPilot_Main) and is the natural
--     "the client's vanilla Lua is fully up" moment, which is before the
--     player can ever open the options screen.  Registering there is what
--     makes the settings visible in the main menu's Mod Options.
--   * OnTick covers the case OnMainMenuEnter cannot: a mod loaded into an
--     ALREADY-RUNNING game, i.e. the 42.19 MP server-connect Lua reload,
--     where the main menu has long since been left behind and never fires
--     again.  It is the same event AutoPilot_Main already drives the whole
--     mod from, so it is guaranteed to fire wherever the mod does anything.
-- OnGameStart is deliberately NOT used: it is not in this project's verified
-- 42.19 record and is not modelled in tests/lua_mock_pz.lua, and the pair
-- above already covers both entry paths.
--
-- Events.X existence is checked before .Add (the project's standing rule):
-- OnQueueNewGame is ABSENT during the MP reload, and blindly indexing an
-- event killed this file's load once already.
if not _registered and Events then
    if Events.OnMainMenuEnter and Events.OnMainMenuEnter.Add then
        Events.OnMainMenuEnter.Add(function() _register() end)
    end
    if Events.OnTick and Events.OnTick.Add then
        Events.OnTick.Add(function()
            if _registered then return end
            _ticks = _ticks + 1
            if _register() then return end
            -- Keep retrying (one nil test per tick) in case PZAPI arrives
            -- very late, but say so once when the grace window is gone.
            if _ticks >= RETRY_TICKS then _noteUnavailable() end
        end)
    end
end
