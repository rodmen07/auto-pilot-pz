-- AutoPilot_UI.lua
-- F11 leveler panel: pick the exercise focus — Auto / Strength / Fitness —
-- watch live XP metrics for both exercise perks plus the V4.1 action perk
-- (Doctor, from wound treatment), see
-- exactly what the trainer is doing right now (current exercise, resting
-- reasons, sets today), arm or disarm the mod, review the death-learning
-- adjustments, and (V4.2) scan the session-history block: the last few
-- sessions' ticks, per-perk level deltas, end reason, and a trend
-- sparkline, all pre-formatted by AutoPilot_SessionHistory (the UI renders
-- strings only; the data layer owns the logic and the tests).  V4.3 adds
-- the training-program day line ("today: STR day (program: ...)"), also
-- pre-formatted, by AutoPilot_Leveler.getProgramStatus.  V5.3 puts the
-- loaded mod version in the window title ("AutoPilot Leveler  v5.1"), which
-- is the only in-game answer to "which build is this server running".
--
-- Built on vanilla ISUI widgets (ISCollapsableWindow + ISButton), standard
-- :new -> :initialise -> :addToUIManager pattern.  Configures the LOCAL
-- player only (in MP each client has its own panel).  Panel position is
-- remembered per character via ModData.

require "ISUI/ISCollapsableWindow"

AutoPilot_UI = ISCollapsableWindow:derive("AutoPilot_UI")
AutoPilot_UI.instance = nil

local PANEL_W = 380
local ROW_H   = 20
local PAD     = 10
local BTN_H   = 20

local POS_MODDATA_KEY = "AutoPilot_UIPos"

-- ── Construction ─────────────────────────────────────────────────────────────

function AutoPilot_UI:createChildren()
    ISCollapsableWindow.createChildren(self)
    local y = self:titleBarHeight() + PAD

    -- Arm/disarm row.
    self.armButton = ISButton:new(PAD, y, PANEL_W - PAD * 2, BTN_H,
        "Arm AutoPilot (F10)", self, AutoPilot_UI.onToggleArm)
    self.armButton:initialise()
    self:addChild(self.armButton)
    y = y + BTN_H + PAD

    -- Focus buttons: Auto / Strength / Fitness.
    self.skillButtons = {}
    local fbW = math.floor((PANEL_W - PAD * 2 - 16) / 3)
    local x = PAD
    for _, def in ipairs(AutoPilot_Leveler.SKILLS) do
        local btn = ISButton:new(x, y, fbW, BTN_H,
            def.name, self, AutoPilot_UI.onSelectSkill)
        btn.internal = def.id
        btn.tooltip = def.note
        btn:initialise()
        self:addChild(btn)
        self.skillButtons[def.id] = btn
        x = x + fbW + 8
    end
    y = y + BTN_H + PAD

    self.metricsY = y
    -- Metrics + status + adaptive list drawn in render().
    -- V4.1: +2 rows for the Doctor visibility block (V5.0 removed the
    -- Woodwork block, so the panel is 2 rows shorter than in V4.x).
    -- V4.2: +7 rows for the session-history block (title + up to
    -- SESSION_HISTORY_PANEL_ROWS sessions + trend sparkline).
    -- V4.3: +1 row for the training-program day line.
    self:setHeight(self.metricsY + ROW_H * 23 + PAD)
end

-- ── Button handlers ──────────────────────────────────────────────────────────

function AutoPilot_UI:_player()
    local ok, p = pcall(function() return getSpecificPlayer(0) end)
    if ok and p then return p end
    local ok2, p0 = pcall(getPlayer)
    return ok2 and p0 or nil
end

function AutoPilot_UI:onSelectSkill(button)
    local player = self:_player()
    if not player then return end
    AutoPilot_Leveler.setTargetSkill(player, button.internal)
end

function AutoPilot_UI:onToggleArm(_button)
    if AutoPilot and AutoPilot.toggle then
        pcall(AutoPilot.toggle)
    end
end

-- ── Rendering ────────────────────────────────────────────────────────────────

--- V5.3: panel title carrying the version of the code that is ACTUALLY
--- loaded, e.g. "AutoPilot Leveler  v5.1".
---
--- Pure string formatting, deliberately factored out of :new so it can be
--- unit-tested: no suite instantiates the panel (it needs the live ISUI
--- widgets), but tests/test_version_constant.lua stubs only the two
--- load-time widget calls and then exercises this function for real.
---
--- The title bar is the chosen home for the version because it costs the
--- panel no extra row (the height arithmetic in createChildren is
--- unchanged) and it stays readable even when the window is collapsed.
--- @param version string|nil  AutoPilot_Constants.VERSION
--- @return string
function AutoPilot_UI.formatTitle(version)
    if type(version) ~= "string" or version == "" then
        -- Constants missing or malformed: degrade to the pre-V5.3 title
        -- rather than drawing "v nil" at the top of the panel.
        return "AutoPilot Leveler"
    end
    return "AutoPilot Leveler  v" .. version
end

--- V5.5: the panel's honest answer to "where are the settings?".
---
--- Returns nil in the normal case so the panel gains no clutter, and a single
--- line when AutoPilot_Options could not register its page with
--- PZAPI.ModOptions, in which case there IS no in-game settings entry to find
--- and every option is on its compiled-in default.  Pure string formatting,
--- factored out like formatTitle so it can be unit-tested without live ISUI
--- widgets.
--- @param registered boolean|nil  AutoPilot_Options.isRegistered()
--- @return string|nil
function AutoPilot_UI.optionsWarningLine(registered)
    if registered then return nil end
    return "mod options unavailable (using defaults)"
end

--- V5.8: what the panel's "Status:" line says, taken from the SAME source the
--- V4.4 on-screen action HUD draws.
---
--- The reported defect was the two of them disagreeing: the HUD said
--- "Action: Resting" over a character who was resting, while this panel said
--- "Status: training: burpees", because the panel read a trainer-only field
--- that the rest path never wrote.  AutoPilot_Needs no longer leaves that
--- field stale, and this function closes the hole structurally: the panel is
--- now a second rendering of AutoPilot.getActionIntention, not a second
--- opinion.  Two views of one string cannot contradict each other.
---
--- `intention` is already the enriched, capitalized label (the HUD folds the
--- trainer status in for exercise and busy cycles, so "Training: squats"
--- still reaches the panel).  The trainer status is kept as the fallback for
--- the case where Main is unavailable, which is the pre-V5.8 behavior.
--- @param intention string|nil  AutoPilot.getActionIntention(player)
--- @param status    table|nil   AutoPilot_Needs.getExerciseStatus()
--- @return string
function AutoPilot_UI.statusText(intention, status)
    if type(intention) == "string" and intention ~= "" then
        return intention
    end
    if type(status) == "table" and type(status.outcome) == "string"
        and status.outcome ~= "" then
        return status.outcome
    end
    return "idle"
end

--- The full "Status: <what>   <sets>" row.  The sets fragment stays
--- pre-formatted by AutoPilot_Needs (V4.6), with the raw-number fallback for
--- an older or partial status table.
--- @return string
function AutoPilot_UI.statusLine(intention, status)
    local sets = (type(status) == "table" and status.setsLine)
        or string.format("Sets today: %d",
            (type(status) == "table" and status.setsToday) or 0)
    return string.format("Status: %s   %s",
        AutoPilot_UI.statusText(intention, status), sets)
end

--- The exercise whose long-term regularity the panel should show, or nil.
---
--- Read off the SAME status text that is drawn above it, so the regularity row
--- cannot outlive the training state that justified it: a resting character
--- no longer has "burpees regularity: 41" sitting under a rest line.  Matches
--- both the raw data-layer form ("training: squats") and the capitalized HUD
--- form ("Training: squats").
--- @param statusText string|nil
--- @return string|nil
function AutoPilot_UI.trainedExerciseFrom(statusText)
    if type(statusText) ~= "string" then return nil end
    return statusText:match("^[Tt]raining: (%S+)")
end

--- Resolve the registration state defensively: a missing AutoPilot_Options
--- (its file failed to load) is itself a "no settings page" state, and must
--- report as such rather than erroring inside render().
local function _optionsRegistered()
    if not (AutoPilot_Options
            and type(AutoPilot_Options.isRegistered) == "function") then
        return false
    end
    local ok, v = pcall(AutoPilot_Options.isRegistered)
    return ok and v or false
end

local function _fmtHours(h)
    if not h then return "?" end
    if h < 1 then return string.format("%d min", math.max(1, math.floor(h * 60))) end
    return string.format("%.1f h", h)
end

function AutoPilot_UI:_drawPerkBlock(label, m, y, highlight)
    local r, g, b = 1, 1, 1
    if highlight then r, g, b = 0.4, 1, 0.4 end
    if not m then
        self:drawText(label .. ": no data yet", PAD, y, r, g, b, 1, UIFont.Small)
        return y + ROW_H
    end
    self:drawText(string.format("%s  —  level %d", label, m.level),
        PAD, y, r, g, b, 1, UIFont.Small)
    y = y + ROW_H
    local next_ = m.xpToNext and string.format("%.0f XP to next", m.xpToNext)
        or "max level"
    self:drawText(string.format("  %s | +%.0f this session | %.0f XP/h | ETA %s",
        next_, m.sessionGain, m.ratePerHour, _fmtHours(m.etaHours)),
        PAD, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
    return y + ROW_H
end

function AutoPilot_UI:render()
    ISCollapsableWindow.render(self)
    local player = self:_player()
    local y = self.metricsY

    -- Arm button reflects live state.
    local armed = AutoPilot and AutoPilot.isActive and AutoPilot.isActive()
    if self.armButton then
        self.armButton:setTitle(armed
            and "ARMED — training  (click or F10 to stop)"
            or "OFF — click or press F10 to start training")
    end

    -- Highlight the current focus.
    local target = player and AutoPilot_Leveler.getTargetSkillId(player) or "auto"
    for id, btn in pairs(self.skillButtons or {}) do
        local def = AutoPilot_Leveler.getSkillDef(id)
        local base = def and def.name or id
        btn:setTitle(id == target and ("> " .. base) or base)
    end

    -- V5.5: only drawn when the mod options page failed to register.  In the
    -- normal case optionsWarningLine returns nil and the panel looks exactly
    -- as it did in V5.4.  Drawn before the no-player early-out so the answer
    -- is visible whenever the panel is open at all.
    local optWarn = AutoPilot_UI.optionsWarningLine(_optionsRegistered())
    if optWarn then
        self:drawText(optWarn, PAD, y, 1, 0.5, 0.4, 1, UIFont.Small)
        y = y + ROW_H
    end

    if not player then
        self:drawText("No player found.", PAD, y, 1, 1, 1, 1, UIFont.Small)
        return
    end

    -- Live trainer status.
    local status = nil
    pcall(function() status = AutoPilot_Needs.getExerciseStatus() end)
    if status then
        -- V5.8: one source of truth.  The status text comes from the same
        -- call the on-screen action HUD renders, so the panel and the HUD
        -- cannot disagree the way the user's screenshot caught them doing.
        local intention = nil
        pcall(function()
            if AutoPilot and AutoPilot.getActionIntention then
                intention = AutoPilot.getActionIntention(player)
            end
        end)
        local what = AutoPilot_UI.statusText(intention, status)
        self:drawText(AutoPilot_UI.statusLine(intention, status),
            PAD, y, 1, 0.9, 0.5, 1, UIFont.Small)
        y = y + ROW_H
        -- Long-term regularity of the exercise currently being trained.
        local exType = AutoPilot_UI.trainedExerciseFrom(what)
        if exType then
            local reg = nil
            pcall(function()
                reg = player:getFitness():getRegularity(exType)
            end)
            if type(reg) == "number" then
                self:drawText(string.format("  %s regularity: %.0f", exType, reg),
                    PAD, y, 0.7, 0.7, 0.9, 1, UIFont.Small)
                y = y + ROW_H
            end
        end
    end

    -- V4.3 training program (C3): today's program day, pre-formatted by
    -- the Leveler (the scheduler and this string live in the unit-tested
    -- data layer; the panel renders it verbatim).  Rest days say so here,
    -- since on a rest day the trainer status above never updates.
    local progLine = nil
    pcall(function()
        local ps = AutoPilot_Leveler.getProgramStatus()
        progLine = ps and ps.line or nil
    end)
    if progLine then
        self:drawText(tostring(progLine), PAD, y, 0.6, 0.9, 0.9, 1, UIFont.Small)
        y = y + ROW_H
    end
    y = y + 4

    local mStr = AutoPilot_Leveler.getMetricsFor(player, "strength")
    local mFit = AutoPilot_Leveler.getMetricsFor(player, "fitness")
    y = self:_drawPerkBlock("Strength", mStr, y, target == "strength")
    y = y + 4
    y = self:_drawPerkBlock("Fitness", mFit, y, target == "fitness")
    y = y + 4

    -- V4.1 action-perk visibility (C6): XP the game grants for the real
    -- action the mod already queues (wound treatment), shown in the same
    -- block style.  Never a focus target.  (V5.0 dropped the Woodwork block
    -- along with the barricade pass that fed it.)
    local mDoc = AutoPilot_Leveler.getMetricsFor(player, "doctor")
    y = self:_drawPerkBlock("Doctor", mDoc, y, false)
    y = y + ROW_H

    -- V4.2 session history (C5): the longitudinal view.  Every string is
    -- pre-formatted by the AutoPilot_SessionHistory data layer (which owns
    -- all parsing/aggregation logic and is unit-tested); this block only
    -- draws what it is handed.
    local histLines = nil
    pcall(function()
        histLines = AutoPilot_SessionHistory.getPanelLines(player,
            AutoPilot_Constants.SESSION_HISTORY_PANEL_ROWS)
    end)
    if type(histLines) == "table" and #histLines > 0 then
        self:drawText("Session history (newest first):",
            PAD, y, 0.6, 0.8, 1, 1, UIFont.Small)
        y = y + ROW_H
        for i = 1, #histLines do
            self:drawText("  " .. tostring(histLines[i]),
                PAD, y, 0.75, 0.75, 0.85, 1, UIFont.Small)
            y = y + ROW_H
        end
        y = y + 4
    end

    -- Death-learning summary + applied adjustments.
    local deaths = 0
    pcall(function() deaths = AutoPilot_DeathLog.getDeathCount() end)
    local applied = {}
    pcall(function() applied = AutoPilot_Adaptive.getApplied() or {} end)
    self:drawText(string.format("Deaths on record: %d   Adaptive tweaks: %d",
        deaths, #applied), PAD, y, 0.8, 0.6, 0.6, 1, UIFont.Small)
    y = y + ROW_H
    for i = 1, math.min(#applied, 4) do
        local a = applied[i]
        self:drawText(string.format("  %s: %s -> %s (%s x%d)",
            tostring(a.key), tostring(a.from), tostring(a.to),
            tostring(a.cause), a.deaths or 0),
            PAD, y, 0.7, 0.55, 0.55, 1, UIFont.Small)
        y = y + ROW_H
    end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

local function _savePosition(panel)
    pcall(function()
        local player = panel:_player()
        if not player then return end
        player:getModData()[POS_MODDATA_KEY] = {
            x = panel:getX(), y = panel:getY(),
        }
    end)
end

local function _loadPosition(panel)
    pcall(function()
        local player = panel:_player()
        if not player then return end
        local pos = player:getModData()[POS_MODDATA_KEY]
        if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.y) then
            panel:setX(pos.x)
            panel:setY(pos.y)
        end
    end)
end

function AutoPilot_UI:close()
    _savePosition(self)
    self:setVisible(false)
    self:removeFromUIManager()
    AutoPilot_UI.instance = nil
end

function AutoPilot_UI:new(x, y)
    local o = ISCollapsableWindow:new(x, y, PANEL_W, 320)
    setmetatable(o, self)
    self.__index = self
    o:setResizable(false)
    -- V5.3: the title reports the loaded version, so "which build is this
    -- server actually running" is answerable with one keypress (F11).
    o.title = AutoPilot_UI.formatTitle(
        AutoPilot_Constants and AutoPilot_Constants.VERSION or nil)
    return o
end

--- Toggle the panel (F11).
function AutoPilot_UI.toggle()
    if AutoPilot_UI.instance then
        AutoPilot_UI.instance:close()
        return
    end
    local panel = AutoPilot_UI:new(120, 120)
    panel:initialise()
    panel:addToUIManager()
    _loadPosition(panel)
    AutoPilot_UI.instance = panel
end
