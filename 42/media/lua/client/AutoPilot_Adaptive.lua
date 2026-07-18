-- AutoPilot_Adaptive.lua
-- Death learning layer, part 2: adaptation.
--
-- At session start, reads the death log written by AutoPilot_DeathLog and
-- applies BOUNDED adjustments to AutoPilot_Constants so the mod avoids
-- repeating recorded failure conditions.  Every adjustment is:
--   data-driven  (RULES table below; unit-testable),
--   bounded      (hard floor/cap per rule — the mod can never tune itself
--                 into absurd behavior),
--   transparent  (recorded in AutoPilot_Adaptive.applied and shown in the
--                 F11 panel).
--
-- Only the most recent MAX_DEATHS_CONSIDERED deaths count, so one bad early
-- game does not dominate forever.

AutoPilot_Adaptive = {}

local function _apNoop(...) end
local print = _apNoop

-- Applied adjustments this session: { {key, from, to, cause, deaths}, ... }
AutoPilot_Adaptive.applied = {}

local _inited = false

local MAX_DEATHS_CONSIDERED = 25
-- A death further than this from home counts toward the "away" cause bucket.
local AWAY_DIST_THRESHOLD   = 60

-- ── Adjustment rules ─────────────────────────────────────────────────────────
-- cause:      death-cause bucket (from DeathLog classifier, plus "away").
-- min_deaths: bucket count needed before the rule fires.
-- key:        AutoPilot_Constants field to adjust.
-- per_death:  delta applied per counted death.
-- floor/cap:  hard bound the value can never pass.
local RULES = {
    -- Died to hordes -> flee sooner, see further.
    { cause = "horde", min_deaths = 2, key = "FLEE_HORDE_SIZE",
      per_death = -1,  floor = 3 },
    { cause = "horde", min_deaths = 2, key = "DETECTION_RADIUS",
      per_death = 2,   cap = 30 },

    -- Bled out (or died wounded among zombies) -> search wider for bandages.
    { cause = "bleed_out",      min_deaths = 1, key = "MEDICAL_LOOT_RADIUS",
      per_death = 10,  cap = 60 },
    { cause = "zombie_wounded", min_deaths = 1, key = "MEDICAL_LOOT_RADIUS",
      per_death = 10,  cap = 60 },

    -- Starved -> eat earlier, stockpile more food.
    { cause = "starvation", min_deaths = 1, key = "HUNGER_THRESHOLD",
      per_death = -0.03, floor = 0.10 },
    { cause = "starvation", min_deaths = 1, key = "SUPPLY_FOOD_MIN",
      per_death = 1,   cap = 6 },

    -- Dehydrated -> drink earlier, stockpile more drinks.
    { cause = "dehydration", min_deaths = 1, key = "THIRST_THRESHOLD",
      per_death = -0.03, floor = 0.10 },
    { cause = "dehydration", min_deaths = 1, key = "SUPPLY_DRINK_MIN",
      per_death = 1,   cap = 5 },

    -- Died far from home -> shrink the supply-run radius (the remaining
    -- away-from-home driver now that frontier exploration is out of scope).
    { cause = "away", min_deaths = 1, key = "LOOT_RADIUS_SUPPLY",
      per_death = -20, floor = 80 },
}

-- ── Aggregation ──────────────────────────────────────────────────────────────

--- Count deaths per cause bucket from parsed death tables.
--- Exposed for tests.
function AutoPilot_Adaptive.aggregate(deaths)
    local counts = {}
    local firstIdx = math.max(1, #deaths - MAX_DEATHS_CONSIDERED + 1)
    for i = firstIdx, #deaths do
        local d = deaths[i]
        if d and d.cause then
            counts[d.cause] = (counts[d.cause] or 0) + 1
            local dist = tonumber(d.dist_home) or 0
            if (tonumber(d.home_set) or 0) == 1 and dist > AWAY_DIST_THRESHOLD then
                counts.away = (counts.away or 0) + 1
            end
        end
    end
    return counts
end

--- Apply RULES against cause counts, mutating AutoPilot_Constants.
--- Returns the list of applied adjustments.  Exposed for tests.
function AutoPilot_Adaptive.applyRules(counts)
    local applied = {}
    for _, rule in ipairs(RULES) do
        local n = counts[rule.cause] or 0
        if n >= (rule.min_deaths or 1) then
            local from = AutoPilot_Constants[rule.key]
            if type(from) == "number" then
                local to = from + rule.per_death * n
                if rule.floor then to = math.max(rule.floor, to) end
                if rule.cap   then to = math.min(rule.cap,   to) end
                if to ~= from then
                    AutoPilot_Constants[rule.key] = to
                    table.insert(applied, {
                        key = rule.key, from = from, to = to,
                        cause = rule.cause, deaths = n,
                    })
                    print(string.format(
                        "[Adaptive] %s: %s -> %s (%d %s death(s))",
                        rule.key, tostring(from), tostring(to), n, rule.cause))
                end
            end
        end
    end
    return applied
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Run once per session (guarded); called from Main's tick loop.
function AutoPilot_Adaptive.init()
    if _inited then return end
    _inited = true

    local ok = pcall(function()
        local deaths = {}
        for _, line in ipairs(AutoPilot_DeathLog.readLines()) do
            local d = AutoPilot_DeathLog.parseLine(line)
            if d then table.insert(deaths, d) end
        end
        if #deaths == 0 then
            print("[Adaptive] No recorded deaths; using default thresholds.")
            return
        end
        local counts = AutoPilot_Adaptive.aggregate(deaths)
        AutoPilot_Adaptive.applied = AutoPilot_Adaptive.applyRules(counts)
        print(string.format("[Adaptive] %d death(s) on record, %d adjustment(s) applied.",
            #deaths, #AutoPilot_Adaptive.applied))
    end)
    if not ok then
        print("[Adaptive] init failed; defaults kept.")
    end
end

--- Adjustments applied this session (for the F11 panel).
function AutoPilot_Adaptive.getApplied()
    return AutoPilot_Adaptive.applied
end

--- Reset (tests only).
function AutoPilot_Adaptive.resetForTest()
    _inited = false
    AutoPilot_Adaptive.applied = {}
end
