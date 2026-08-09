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
--                 F11 panel),
--   accounted for(every cause AutoPilot_DeathLog can classify a death into is
--                 either consumed by a rule below or named in
--                 UNRULED_CAUSES with the reason it is not — an inert cause
--                 is a decision here, never an oversight).
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
    -- Died to hordes -> see further.
    --
    -- This rule's "flee sooner" half was RETIRED 2026-08-08.  Superseded rule,
    -- quoted verbatim where it stood:
    --   { cause = "horde", min_deaths = 2, key = "FLEE_HORDE_SIZE",
    --     per_death = -1,  floor = 3 },
    -- Two reasons, the same two that kept FLEE_HORDE_SIZE off the infection/
    -- zombies rules below: since the flee-only rewrite every branch of
    -- AutoPilot_Threat._decideEngagement resolves to a flee with the same
    -- escape vector, so lowering FLEE_HORDE_SIZE moved the telemetry label
    -- (flee_horde vs flee_default) and the F11 panel then advertised that
    -- label move as a behavioural improvement; and FLEE_HORDE_SIZE is the
    -- constant AutoPilot_DeathLog's classifier reads to split `horde` from
    -- `zombies`, so the rule was drifting the boundary of its own input
    -- bucket.  With no adaptive writer the classification is stable, and a
    -- death that would have migrated into `horde` lands in `zombies` instead,
    -- whose rule widens DETECTION_RADIUS by the same +2 -- nothing is learned
    -- less.  tests/test_death_cause_coverage.lua Test 8 pins both properties.
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

    -- Died bitten (infection), or killed by a group too small to count as a
    -- horde (zombies) -> in BOTH cases a zombie reached melee range, which
    -- since the flee-only rewrite means the mod saw it too late.  So see them
    -- sooner.
    --
    -- DETECTION_RADIUS is the lever with real behavioural reach here: it is
    -- what AutoPilot_Threat.getNearbyZombies filters on, so a zombie outside
    -- it is one the mod never flees from at all.  FLEE_HORDE_SIZE is not a
    -- target for ANY rule -- see the retired horde half above for why, and
    -- note the general form: a constant the death classifier READS may never
    -- be a constant a rule WRITES, or the layer feeds back into its own
    -- input.  Every zombie-contact cause (horde, infection, zombies) points
    -- at this one lever, which also makes bucket migration between them
    -- harmless.
    { cause = "infection", min_deaths = 1, key = "DETECTION_RADIUS",
      per_death = 2,   cap = 30 },
    { cause = "zombies",   min_deaths = 1, key = "DETECTION_RADIUS",
      per_death = 2,   cap = 30 },
}

-- Exposed for tests.  tests/test_adaptive_bounds.lua drives EVERY rule across
-- the player-configurable option range rather than at the shipped default, so
-- it has to read the real table: a hand-copied list would go stale the first
-- time a rule is added, and staleness there reads as coverage.
AutoPilot_Adaptive.RULES = RULES

-- ── Causes deliberately left un-ruled ────────────────────────────────────────
-- A cause with no RULES entry is INERT: a death classified into it teaches the
-- mod nothing at all.  Until 2026-08-08 three of the classifier's eight causes
-- were inert and the file said nothing about it, so a reader could not tell an
-- omission from a decision.  `infection` and `zombies` were the omissions and
-- got rules above; this table is the other half of the answer, and it is a
-- TABLE rather than a comment so a guard can read it.
--
-- tests/test_death_cause_coverage.lua fails if a cause the classifier can emit
-- appears in neither RULES nor here, so the next cause added cannot go inert
-- quietly the way these did.
AutoPilot_Adaptive.UNRULED_CAUSES = {
    unknown = "nothing observable at the moment of death identified a cause, "
           .. "so no bounded nudge is well-founded: any rule keyed here would "
           .. "tune the mod on noise. Deliberate, 2026-08-08.",
}

-- Causes SYNTHESISED by aggregate() from the death record rather than emitted
-- by AutoPilot_DeathLog's classifier.  Declared so the same guard can check the
-- OTHER direction: a rule keyed on a cause nothing ever produces is dead code
-- that reads as coverage.
AutoPilot_Adaptive.SYNTHETIC_CAUSES = {
    away = "derived below from dist_home and home_set, not from the death "
        .. "record's own cause field.",
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
                -- The floor/cap above are written against the SHIPPED
                -- defaults, but `from` is whatever the PLAYER configured:
                -- AutoPilot_Main applies AutoPilot_Options first and this
                -- module second.  Clamping a player value that already sits
                -- past the bound moved the constant the WRONG WAY and then
                -- recorded the move as an adjustment -- "starved -> eat
                -- earlier" raised a 5% hunger trigger to 10%, "see further"
                -- shrank a 40-tile detection radius to 30, and the two
                -- stockpile rules cut an 8-item minimum to 6 and 5.  So a
                -- bound may only ever STOP the adjustment, never reverse it:
                -- an adjustment can never move a constant backwards past
                -- where it started.  Proven both ways in
                -- tests/test_adaptive_bounds.lua (Tests 4 and 5).
                if rule.per_death < 0 then
                    to = math.min(to, from)
                elseif rule.per_death > 0 then
                    to = math.max(to, from)
                end
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
