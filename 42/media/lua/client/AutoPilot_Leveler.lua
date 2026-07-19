-- AutoPilot_Leveler.lua
-- Exercise-focused auto-leveler (V3.1 scope): the player picks a training
-- focus per character — Auto (balance the lower of STR/FIT), Strength, or
-- Fitness — and the mod runs exercise sets whenever the character is idle,
-- while the survival layer keeps them alive.
--
-- Selection persists in player ModData (MP-safe via transmitModData) and
-- survives save/reload.  Exercise itself (endurance gates, daily set cap,
-- equipment preference) lives in AutoPilot_Needs.trainExercise; this module
-- adds focus selection, XP metrics tracking, and (V4.3, expansion
-- candidate C3) the weekly training-program scheduler: a pure table that
-- maps the in-game weekday to that day's focus (auto/strength/fitness/rest).
-- The scheduler only refines this slot's focus-or-rest decision; it never
-- reorders the priority chain, and a rest day simply yields the exercise
-- slot so the survival chores own the cycle (the V3.2 starvation lesson).
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

-- ── Training programs (V4.3, expansion candidate C3) ──────────────────────────
-- Weekly splits: days[1..7] = Sunday..Saturday, each entry one of
-- "auto" (defer to the F11 focus selection, i.e. pre-V4.3 behavior),
-- "strength", "fitness" (program override for the day), or "rest" (the
-- exercise slot yields; survival chores continue, no training that day).
-- Order matters: the Options selector maps its 1-based value to this list.
-- "balanced" (index 1, the compiled-in default via
-- AutoPilot_Constants.TRAINING_PROGRAM) is all-auto with no rest days, so
-- behavior is identical to pre-V4.3 whenever Options never loads.
AutoPilot_Leveler.PROGRAMS = {
    { id = "balanced",    name = "Balanced",
      note = "every day follows the F11 focus selection (default)",
      days = { "auto", "auto", "auto", "auto", "auto", "auto", "auto" } },
    { id = "strength",    name = "Strength emphasis",
      note = "5 strength days, 2 fitness days",
      days = { "fitness", "strength", "strength", "fitness",
               "strength", "strength", "strength" } },
    { id = "fitness",     name = "Fitness emphasis",
      note = "5 fitness days, 2 strength days",
      days = { "strength", "fitness", "fitness", "strength",
               "fitness", "fitness", "fitness" } },
    { id = "alternating", name = "Alternating days",
      note = "strength and fitness on alternating days",
      days = { "strength", "fitness", "strength", "fitness",
               "strength", "fitness", "strength" } },
    { id = "restsplit",   name = "Rest-day split",
      note = "alternating split with Sunday off",
      days = { "rest", "strength", "fitness", "strength",
               "fitness", "strength", "fitness" } },
}

local _programById = {}
for _, prog in ipairs(AutoPilot_Leveler.PROGRAMS) do
    _programById[prog.id] = prog
end

local MS_PER_DAY = 24 * 60 * 60 * 1000

-- Panel labels for the day focus values.
local DAY_LABEL = {
    auto = "auto", strength = "STR", fitness = "FIT", rest = "rest",
}

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

-- ── Training-program scheduler (V4.3) ─────────────────────────────────────────

--- Program definition for an id, or nil for unknown ids.
function AutoPilot_Leveler.getProgramDef(id)
    return _programById[id]
end

--- Selected program id, read LIVE from AutoPilot_Constants.TRAINING_PROGRAM
--- at every call site (the V3.3 pattern: Options writes the selector value
--- there, once per session and again on options-save, so mid-session
--- changes take effect immediately).  Unknown or missing values validate
--- to "balanced" (the compiled-in, identical-to-pre-V4.3 default).
function AutoPilot_Leveler.getProgramId()
    local id = AutoPilot_Constants and AutoPilot_Constants.TRAINING_PROGRAM
    if _programById[id] then return id end
    return "balanced"
end

--- In-game weekday, 0 = Sunday .. 6 = Saturday, or nil when the calendar
--- is unavailable.  Derived ONLY from the verified
--- getGameTime():getCalender():getTimeInMillis() surface (epoch millis;
--- epoch day zero, 1970-01-01, was a Thursday, hence the +4).  No other
--- calendar API is in the verified record, so no other one is used.
function AutoPilot_Leveler.getWeekday()
    local ok, ms = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if not ok or type(ms) ~= "number" then return nil end
    return (math.floor(ms / MS_PER_DAY) + 4) % 7
end

--- Pure day resolution: (programId, weekday 0..6) -> "auto" | "strength" |
--- "fitness" | "rest".  Unknown program ids resolve as "balanced"; a nil
--- or out-of-range weekday (calendar absent) resolves to "auto", i.e. the
--- pre-V4.3 always-on focus behavior.
function AutoPilot_Leveler.resolveFocus(programId, weekday)
    local prog = _programById[programId] or _programById.balanced
    if type(weekday) ~= "number" then return "auto" end
    weekday = math.floor(weekday)
    if weekday < 0 or weekday > 6 then return "auto" end
    return prog.days[weekday + 1] or "auto"
end

--- Program status for the F11 panel: { program, programName, weekday,
--- day, line }.  day is nil when the calendar is unavailable; line is the
--- pre-formatted string the panel renders verbatim (rest days say so, per
--- the C3 proposal).
function AutoPilot_Leveler.getProgramStatus()
    local id   = AutoPilot_Leveler.getProgramId()
    local prog = _programById[id]
    local wd   = AutoPilot_Leveler.getWeekday()
    local st   = { program = id, programName = prog.name, weekday = wd }
    if wd == nil then
        st.line = "program: " .. prog.name .. " (no calendar, focus always on)"
        return st
    end
    st.day = AutoPilot_Leveler.resolveFocus(id, wd)
    if st.day == "rest" then
        st.line = "today: rest day (program: " .. prog.name
            .. "), survival chores only"
    else
        st.line = "today: " .. (DAY_LABEL[st.day] or "auto")
            .. " day (program: " .. prog.name .. ")"
    end
    return st
end

-- ── Main entry ────────────────────────────────────────────────────────────────

--- Run one exercise step honoring the selected focus and (V4.3) the weekly
--- training program.  Called from the survival chain's idle slot.  Returns
--- true when an action was queued; on program rest days it returns false
--- WITHOUT training so the cycle falls through to the survival chores
--- (rest only ever yields this one slot; the priority chain is untouched).
function AutoPilot_Leveler.check(player)
    local s = _load(player)

    -- Track metrics for both exercise perks every cycle (cheap reads) so the
    -- F11 panel always has fresh numbers regardless of focus, rest days
    -- included.
    if AutoPilot_XP and AutoPilot_XP.sample then
        pcall(function()
            AutoPilot_XP.sample(player, Perks.Strength)
            AutoPilot_XP.sample(player, Perks.Fitness)
        end)
    end

    -- V4.3 (C3): resolve today's program day.  Calendar absence resolves to
    -- "auto" (the always-on focus behavior), so the scheduler can only ever
    -- narrow this slot's decision, never break it.
    local dayFocus = AutoPilot_Leveler.resolveFocus(
        AutoPilot_Leveler.getProgramId(), AutoPilot_Leveler.getWeekday())
    if dayFocus == "rest" then
        return false  -- rest day: yield the slot; chores own the cycle
    end

    local focus = nil  -- nil = auto-balance inside doExercise
    if dayFocus == "strength" or dayFocus == "fitness" then
        focus = dayFocus                      -- program override for today
    elseif s.target == "strength" or s.target == "fitness" then
        focus = s.target                      -- "auto" day: player's focus
    end

    if AutoPilot_Needs and AutoPilot_Needs.trainExercise then
        local ok, queued = pcall(AutoPilot_Needs.trainExercise, player, focus)
        return ok and queued == true
    end
    return false
end

-- Perks the metrics engine tracks for the F11 panel.  Exercise perks are
-- sampled every Leveler.check; the V4.1 action perks (C2/C6) are sampled at
-- their action sites (Barricade maintenance / Medical treatment) and are
-- read-only visibility of XP the game itself grants for real queued actions.
local METRIC_PERKS = {
    strength = "Strength",
    fitness  = "Fitness",
    woodwork = "Woodwork",   -- V4.1 C2: barricade maintenance pass
    doctor   = "Doctor",     -- V4.1 C6: wound treatment
}

--- Metrics for one tracked perk ("strength" | "fitness" | "woodwork" |
--- "doctor") for the UI.  Unknown ids fall back to Strength.
function AutoPilot_Leveler.getMetricsFor(player, id)
    if not AutoPilot_XP then return nil end
    local perkKey = METRIC_PERKS[id] or "Strength"
    local ok, perk = pcall(function() return Perks[perkKey] end)
    if not ok or not perk then return nil end
    return AutoPilot_XP.getMetrics(player, perk)
end

--- Reset cached per-player state (tests).
function AutoPilot_Leveler.resetForTest()
    _state = {}
end
