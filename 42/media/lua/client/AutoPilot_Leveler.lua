-- AutoPilot_Leveler.lua
-- Exercise-focused auto-leveler (V3.1 scope): the player picks a training
-- focus per character — Auto (balance the lower of STR/FIT), Strength, or
-- Fitness — and the mod runs exercise sets whenever the character is idle,
-- while the survival layer keeps them alive.
--
-- Selection persists in player ModData (MP-safe via transmitModData) and
-- survives save/reload.  Exercise itself (endurance gates, daily set cap,
-- equipment preference) lives in AutoPilot_Needs.trainExercise; this module
-- adds focus selection and XP metrics tracking.
--
-- NOTE: no skill books exist for Strength/Fitness in B42, so there is no
-- book-reading step here.

AutoPilot_Leveler = {}

local function _apNoop(...) end
local print = _apNoop

local MODDATA_KEY = "AutoPilot_Leveler"

-- ── Focus registry ────────────────────────────────────────────────────────────
AutoPilot_Leveler.SKILLS = {
    { id = "auto",     name = "Auto (both)", perk = nil,
      note = "burpees: train Strength and Fitness together" },
    { id = "strength", name = "Strength",    perk = "Strength",
      note = "push-ups" },
    { id = "fitness",  name = "Fitness",     perk = "Fitness",
      note = "squats; sit-ups while the legs are stiff" },
}

local _byId = {}
for _, def in ipairs(AutoPilot_Leveler.SKILLS) do _byId[def.id] = def end

-- ── Per-player state (cached from ModData) ────────────────────────────────────
-- _state[pnum] = { target = "auto"|"strength"|"fitness" }
local _state = {}

local function _pnum(player)
    local ok, n = pcall(function() return player:getPlayerNum() end)
    return (ok and type(n) == "number") and n or 0
end

local function _load(player)
    local pnum = _pnum(player)
    if _state[pnum] then return _state[pnum] end
    local s = { target = "auto" }
    pcall(function()
        local md = player:getModData()[MODDATA_KEY]
        if type(md) == "table" and _byId[md.target] then
            s.target = md.target
        end
    end)
    _state[pnum] = s
    return s
end

local function _save(player)
    local s = _state[_pnum(player)]
    if not s then return end
    pcall(function()
        player:getModData()[MODDATA_KEY] = { target = s.target }
        player:transmitModData()
    end)
end

-- ── Selection API ─────────────────────────────────────────────────────────────

function AutoPilot_Leveler.getSkillDef(id)
    return _byId[id]
end

--- Current focus id ("auto" | "strength" | "fitness"); never nil.
function AutoPilot_Leveler.getTargetSkillId(player)
    return _load(player).target
end

function AutoPilot_Leveler.getTargetSkillName(player)
    local def = _byId[_load(player).target]
    return def and def.name or "Auto (balance)"
end

--- Set the training focus.  Unknown ids are rejected.
function AutoPilot_Leveler.setTargetSkill(player, id)
    if not _byId[id] then return false end
    _load(player).target = id
    _save(player)
    print("[Leveler] Focus: " .. tostring(id))
    return true
end

-- ── Main entry ────────────────────────────────────────────────────────────────

--- Run one exercise step honoring the selected focus.  Called from the
--- survival chain's idle slot.  Returns true when an action was queued.
function AutoPilot_Leveler.check(player)
    local s = _load(player)

    -- Track metrics for both exercise perks every cycle (cheap reads) so the
    -- F11 panel always has fresh numbers regardless of focus.
    if AutoPilot_XP and AutoPilot_XP.sample then
        pcall(function()
            AutoPilot_XP.sample(player, Perks.Strength)
            AutoPilot_XP.sample(player, Perks.Fitness)
        end)
    end

    local focus = nil  -- nil = auto-balance inside doExercise
    if s.target == "strength" or s.target == "fitness" then
        focus = s.target
    end

    if AutoPilot_Needs and AutoPilot_Needs.trainExercise then
        local ok, queued = pcall(AutoPilot_Needs.trainExercise, player, focus)
        return ok and queued == true
    end
    return false
end

--- Metrics for one exercise perk ("strength" | "fitness") for the UI.
function AutoPilot_Leveler.getMetricsFor(player, id)
    if not AutoPilot_XP then return nil end
    local perkKey = (id == "fitness") and "Fitness" or "Strength"
    local ok, perk = pcall(function() return Perks[perkKey] end)
    if not ok or not perk then return nil end
    return AutoPilot_XP.getMetrics(player, perk)
end

--- Reset cached per-player state (tests).
function AutoPilot_Leveler.resetForTest()
    _state = {}
end
