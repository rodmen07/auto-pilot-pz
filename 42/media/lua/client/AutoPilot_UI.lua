-- AutoPilot_UI.lua
-- F11 leveler panel: pick the exercise focus — Auto / Strength / Fitness —
-- and watch live XP metrics for both exercise perks (level, XP to next,
-- session gain, XP/hour, ETA).  Also shows the death-learning summary
-- (deaths on record, adaptive tweaks applied).
--
-- Built on vanilla ISUI widgets (ISCollapsableWindow + ISButton), standard
-- :new -> :initialise -> :addToUIManager pattern.  Configures the LOCAL
-- player only (splitscreen is not supported; in MP each client has its own
-- panel).

require "ISUI/ISCollapsableWindow"

AutoPilot_UI = ISCollapsableWindow:derive("AutoPilot_UI")
AutoPilot_UI.instance = nil

local PANEL_W = 380
local ROW_H   = 20
local PAD     = 10
local BTN_H   = 20

-- ── Construction ─────────────────────────────────────────────────────────────

function AutoPilot_UI:createChildren()
    ISCollapsableWindow.createChildren(self)
    local y = self:titleBarHeight() + PAD

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
    -- Metrics area drawn in render(): 2 perk blocks + summary line.
    self:setHeight(self.metricsY + ROW_H * 10 + PAD)
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

-- ── Rendering ────────────────────────────────────────────────────────────────

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

    -- Highlight the current focus.
    local target = player and AutoPilot_Leveler.getTargetSkillId(player) or "auto"
    for id, btn in pairs(self.skillButtons or {}) do
        local def = AutoPilot_Leveler.getSkillDef(id)
        local base = def and def.name or id
        btn:setTitle(id == target and ("> " .. base) or base)
    end

    if not player then
        self:drawText("No player found.", PAD, y, 1, 1, 1, 1, UIFont.Small)
        return
    end

    self:drawText("Focus: " .. AutoPilot_Leveler.getTargetSkillName(player),
        PAD, y, 0.4, 1, 0.4, 1, UIFont.Small)
    y = y + ROW_H + 4

    local mStr = AutoPilot_Leveler.getMetricsFor(player, "strength")
    local mFit = AutoPilot_Leveler.getMetricsFor(player, "fitness")
    y = self:_drawPerkBlock("Strength", mStr, y, target == "strength")
    y = y + 4
    y = self:_drawPerkBlock("Fitness", mFit, y, target == "fitness")
    y = y + ROW_H

    -- Death-learning summary.
    local deaths = 0
    pcall(function() deaths = AutoPilot_DeathLog.getDeathCount() end)
    local adjusted = 0
    pcall(function() adjusted = #AutoPilot_Adaptive.getApplied() end)
    self:drawText(string.format("Deaths on record: %d   Adaptive tweaks: %d",
        deaths, adjusted), PAD, y, 0.8, 0.6, 0.6, 1, UIFont.Small)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function AutoPilot_UI:close()
    self:setVisible(false)
    self:removeFromUIManager()
    AutoPilot_UI.instance = nil
end

function AutoPilot_UI:new(x, y)
    local o = ISCollapsableWindow:new(x, y, PANEL_W, 300)
    setmetatable(o, self)
    self.__index = self
    o:setResizable(false)
    o.title = "AutoPilot Leveler"
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
    AutoPilot_UI.instance = panel
end
