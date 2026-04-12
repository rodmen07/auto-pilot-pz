-- AutoPilot_Constants.lua
-- Central registry of named constants for the AutoPilot mod.
--
-- Centralising magic numbers here means:
--   • every value has a documented unit and rationale,
--   • tuning one number in one place propagates everywhere, and
--   • luacheck can catch typos in constant names.
--
-- Load note: 'C' sorts before 'H','I','L','M','N','T','U', so this file loads
-- before all other AutoPilot modules.  Constants are plain values — no
-- dependencies on any other AutoPilot global.

AutoPilot_Constants = {}

-- ── Search radii (in tiles) ───────────────────────────────────────────────────

-- Spiral-snap radius when resolving a walk target to the nearest free square.
-- 5 tiles ≈ one small room; keeps pathfinding out of walls without drifting far.
AutoPilot_Constants.WALK_SNAP_RADIUS = 5

-- Default walk distance when walk_to receives a direction but no explicit range.
AutoPilot_Constants.WALK_DEFAULT_DIST = 20

-- Bandage-loot radius.  Kept at 30 so the character does not wander far
-- while actively bleeding; first-aid kits are usually within the same building.
AutoPilot_Constants.MEDICAL_LOOT_RADIUS = 30

-- Radius for placing an inventory item into the nearest container.
AutoPilot_Constants.PLACE_SEARCH_DIST = 50

-- Radius for rest-furniture search (beds > sofas > chairs).
-- 150 tiles = one full cell radius; covers entire neighbourhood.
AutoPilot_Constants.REST_SEARCH_DIST = 150

-- General container-loot radius used for food, drink, and readable items.
-- 150 tiles = one full cell radius.
AutoPilot_Constants.LOOT_SEARCH_RADIUS = 150

-- Water-source search radius (sinks, rain barrels, water dispensers).
AutoPilot_Constants.WATER_SEARCH_RADIUS = 150

-- Outdoor-square search for boredom relief.
AutoPilot_Constants.OUTDOOR_SEARCH_DIST = 150

-- ── Home / safehouse ──────────────────────────────────────────────────────────

-- Default containment circle radius when AutoPilot is first enabled.
-- 150 tiles = one full cell radius; covers a city block in all directions.
AutoPilot_Constants.HOME_DEFAULT_RADIUS = 150

-- Bed-search parameters.  150 tiles = one full cell radius.
AutoPilot_Constants.BED_SEARCH_DIST   = 150
AutoPilot_Constants.BED_SEARCH_FLOORS = 3   -- checks z, z+1, z-1

-- ── Threat detection ──────────────────────────────────────────────────────────

-- Zombie-detection circle.  10 tiles ≈ comfortable melee engagement range.
AutoPilot_Constants.DETECTION_RADIUS = 10

-- Flee if MORE THAN this many debuff stats are elevated at once.
-- 2 elevated = moderately compromised; > 2 = high-risk, better to run.
AutoPilot_Constants.FLEE_MOODLE_LIMIT = 2

-- Distance (in tiles) to run from the zombie centroid when fleeing.
AutoPilot_Constants.FLEE_DISTANCE = 20

-- ── Survival stat thresholds ─────────────────────────────────────────────────
-- B42 stat scale: 0.0 = fine, ~1.0 = critical (hunger, thirst, fatigue, …).
-- Endurance is inverted: 1.0 = full, 0.0 = empty.
-- Boredom / sanity / panic use an integer 0–100 scale in B42.

-- Trigger eating when hunger ≥ 20%.  Gives enough lead time to find food before
-- the moodle escalates from "Hungry" to "Very Hungry".
AutoPilot_Constants.HUNGER_THRESHOLD = 0.20

-- Matched to hunger sensitivity; thirst escalates faster but same logic applies.
AutoPilot_Constants.THIRST_THRESHOLD = 0.20

-- Trigger sleep at 70% fatigue — early enough to reach a bed before the
-- "Exhausted" moodle fires and impairs movement.
AutoPilot_Constants.FATIGUE_THRESHOLD = 0.70

-- Boredom and sadness use the 0–100 integer scale.
AutoPilot_Constants.BOREDOM_THRESHOLD = 30
AutoPilot_Constants.SADNESS_THRESHOLD = 20

-- Begin rest when endurance drops to 30%.  This threshold avoids the
-- sit-stand loop that fires at mild exertion (moodle level 1–2).
AutoPilot_Constants.ENDURANCE_REST_MIN = 0.30

-- Do not start a new exercise set below 50% endurance; let it recover passively.
AutoPilot_Constants.ENDURANCE_EXERCISE_MIN = 0.50

-- ── Timing ───────────────────────────────────────────────────────────────────
-- PZ runs at ~20 game ticks per real second.

-- Main AutoPilot evaluation interval (game ticks).
-- 15 ticks × (1 s / 20 ticks) = 0.75 s between evaluations.
AutoPilot_Constants.TICK_INTERVAL = 15

-- Post-action suppression window (evaluation cycles).
-- 4 cycles × 15 ticks × (1 s / 20 ticks) = 3 s cooldown after any action.
AutoPilot_Constants.ACTION_COOLDOWN_CYCLES = 4

-- State-write interval (evaluation cycles).
-- 14 cycles × 15 ticks × (1 s / 20 ticks) ≈ 10.5 s between state snapshots.
AutoPilot_Constants.STATE_WRITE_INTERVAL = 14

-- Exercise set duration sent to ISFitnessAction (game minutes).
AutoPilot_Constants.EXERCISE_MINUTES = 20

-- Max search results stored for state reporting after searchItem.
AutoPilot_Constants.SEARCH_RESULTS_MAX = 10

-- Max inventory item names included in the state snapshot.
AutoPilot_Constants.INVENTORY_SUMMARY_MAX = 20

-- ---------------------------------------------------------------------------
-- Phase 2: Exercise equipment
-- ---------------------------------------------------------------------------
-- XP multipliers are approximate relative values used for preference scoring.
-- keyword = substring to match against item:getType()
AutoPilot_Constants.EXERCISE_EQUIPMENT = {
    { keyword = "Dumbbells",  tier = "dumbbell", multiplier = 1.8 },
    { keyword = "Barbell",    tier = "barbell",  multiplier = 1.2 },
    { keyword = "WeightBar",  tier = "barbell",  multiplier = 1.2 },
}
AutoPilot_Constants.EXERCISE_EQUIP_SEARCH_RADIUS = 150  -- tiles (one full cell radius)

-- Phase 2: Endurance gating thresholds (0.0–1.0)
AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = 0.30    -- skip exercise below this
AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.70    -- resume exercise above this

-- Phase 2: Daily exercise cap (sets per in-game day)
AutoPilot_Constants.EXERCISE_DAILY_CAP = 20

-- ---------------------------------------------------------------------------
-- Phase 3: Weight management thresholds (in-game weight units)
AutoPilot_Constants.WEIGHT_UNDERWEIGHT = 65    -- below this: prioritize high-calorie food
AutoPilot_Constants.WEIGHT_OVERWEIGHT  = 85    -- above this: prefer low-calorie food

-- Phase 3: Happiness / boredom thresholds
AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD = 40   -- MoodleType.Unhappy level to trigger action

-- Phase 3: Foraging / supply run radii
-- ---------------------------------------------------------------------------
AutoPilot_Constants.LOOT_RADIUS_HOME   = 150   -- normal home-area loot radius (one cell)
AutoPilot_Constants.LOOT_RADIUS_SUPPLY = 300   -- expanded radius for supply runs (full cell diameter)
AutoPilot_Constants.SUPPLY_RUN_TRIGGER = 5     -- consecutive empty loot cycles before expanding radius

-- Phase 4: Combat weapon management
AutoPilot_Constants.WEAPON_CONDITION_MIN  = 0.25  -- swap weapon if condition drops below this (0.0–1.0)
AutoPilot_Constants.WEAPON_SEARCH_RADIUS  = 150   -- tiles to search for a replacement weapon

-- Phase 4: Temperature / clothing thresholds
-- BodyStats temperature is roughly -100 (freezing) to +100 (boiling), 0 = comfortable
AutoPilot_Constants.TEMP_TOO_COLD = -20   -- equip warmer clothing below this
AutoPilot_Constants.TEMP_TOO_HOT  =  20   -- equip lighter clothing above this
AutoPilot_Constants.CLOTHING_SEARCH_RADIUS = 150

-- Phase 4: Barricading
AutoPilot_Constants.BARRICADE_SEARCH_RADIUS = 15  -- only barricade windows/doors within home radius

-- ── Pain / sleep arbitration ─────────────────────────────────────────────────
-- Pain (0–100 integer scale) above this value blocks the sleep transition until
-- the character has taken a painkiller or received medical treatment.
AutoPilot_Constants.PAIN_SLEEP_THRESHOLD = 30

-- ── Map / container depletion cache ─────────────────────────────────────────
-- Maximum depleted-square entries before the oldest are pruned.
-- Keeps the table bounded in memory for long-running sessions.
AutoPilot_Constants.DEPLETED_CAP = 500

-- ── Main loop timing (aliases documented here for completeness) ───────────────
-- TICK_INTERVAL (line 99) and ACTION_COOLDOWN_CYCLES (line 103) govern the
-- main evaluation cadence:
--   OnTick fires ~20 times per real second.
--   TICK_INTERVAL = 15  →  evaluation every ~0.75 s
--   ACTION_COOLDOWN_CYCLES = 4  →  ~3 s suppression after any queued action
--
-- NOTE for auto_tune.py: the regex patterns that patch this file expect the
-- format `AutoPilot_Constants.FIELD = <number>` with no leading whitespace.
-- Do not introduce leading spaces or multi-line assignments for tunable lines.
