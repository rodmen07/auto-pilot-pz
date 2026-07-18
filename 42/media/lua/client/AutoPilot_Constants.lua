-- AutoPilot_Constants.lua
-- Central registry of named constants for the AutoPilot mod.
--
-- Centralising magic numbers here means:
--   every value has a documented unit and rationale,
--   tuning one number in one place propagates everywhere, and
--   luacheck can catch typos in constant names.
--
-- Load note: 'C' sorts before 'H','I','L','M','N','T','U', so this file loads
-- before all other AutoPilot modules.  Constants are plain values -- no
-- dependencies on any other AutoPilot global.

AutoPilot_Constants = {}

-- Search radii (in tiles) --------------------------------------------------

-- Spiral-snap radius when resolving a walk target to the nearest free square.
-- 5 tiles is one small room; keeps pathfinding out of walls without drifting far.
AutoPilot_Constants.WALK_SNAP_RADIUS = 5

-- Default walk distance when walk_to receives a direction but no explicit range.
AutoPilot_Constants.WALK_DEFAULT_DIST = 20

-- Bandage-loot radius.  Kept at 30 so the character does not wander far
-- while actively bleeding; first-aid kits are usually within the same building.
AutoPilot_Constants.MEDICAL_LOOT_RADIUS = 30

-- Radius for placing an inventory item into the nearest container.
AutoPilot_Constants.PLACE_SEARCH_DIST = 50

-- Radius for rest-furniture search (beds > sofas > chairs).
-- Capped at 80: iterateNearbySquares visits (2r+1)^2 squares per scan and its
-- own docs warn r > 80 risks frame hitches on the ~0.75 s eval cycle.
AutoPilot_Constants.REST_SEARCH_DIST = 80

-- General container-loot radius used for food, drink, and readable items.
-- Capped at 80 (see REST_SEARCH_DIST rationale).
AutoPilot_Constants.LOOT_SEARCH_RADIUS = 80

-- Water-source search radius (sinks, rain barrels, water dispensers).
AutoPilot_Constants.WATER_SEARCH_RADIUS = 80

-- Outdoor-square search for boredom relief.
AutoPilot_Constants.OUTDOOR_SEARCH_DIST = 80

-- Home / safehouse ----------------------------------------------------------

-- Default containment circle radius when AutoPilot is first enabled.
-- 150 tiles = one full cell radius; covers a city block in all directions.
AutoPilot_Constants.HOME_DEFAULT_RADIUS = 150

-- Bed-search parameters.  Capped at 80: this scan multiplies (2r+1)^2 by
-- BED_SEARCH_FLOORS, so it is the single heaviest search in the mod.
AutoPilot_Constants.BED_SEARCH_DIST   = 80
AutoPilot_Constants.BED_SEARCH_FLOORS = 3   -- checks z, z+1, z-1

-- Threat detection ---------------------------------------------------------

-- Zombie-detection circle.  20 tiles gives ~6-7 s of lead time at normal walk
-- speed before a detected zombie reaches melee range -- enough for the action
-- queue to drain (eating, looting) before the fight/flee response fires.
AutoPilot_Constants.DETECTION_RADIUS = 20

-- Engagement override: a zombie within this many tiles is ALWAYS treated as
-- danger, even when the engine's visible/chasing counters have not flagged it
-- yet (e.g. approaching from behind).  Beyond it, mere radius presence is not
-- danger — zombies milling outside the safehouse walls must not lock the mod
-- into permanent combat mode (observed live).
AutoPilot_Constants.CLOSE_DANGER_RADIUS = 6

-- Flee if MORE THAN this many debuff stats are elevated at once.
-- 2 elevated = moderately compromised; > 2 = high-risk, better to run.
AutoPilot_Constants.FLEE_MOODLE_LIMIT = 2

-- Distance (in tiles) to run along the escape vector when fleeing.
AutoPilot_Constants.FLEE_DISTANCE = 20

-- Flee unconditionally when zombie count reaches this, regardless of weapon or moodles.
-- A group of 6 is a genuine horde that outweighs any fight advantage.
AutoPilot_Constants.FLEE_HORDE_SIZE = 6

-- Minimum angular gap (degrees) between zombies required to treat a direction as a
-- viable escape arc.  If no gap exceeds this, the player is considered encircled and
-- will fight through the weakest cluster instead of fleeing.
AutoPilot_Constants.FLEE_ESCAPE_ARC_MIN = 90

-- Post-flee suppression window (evaluation cycles).
-- Prevents the stutter-flee loop: once a flee walk is queued, the threat check
-- will not re-trigger while the walk is in progress, then holds off for this many
-- additional cycles after arrival before re-evaluating.
-- 4 cycles * 0.75 s = 3 s post-arrival buffer.
AutoPilot_Constants.FLEE_COOLDOWN_CYCLES = 4

-- Minimum weapon condition (0.0-1.0) for a weapon to count as usable in fight
-- decisions.  Below this the weapon is treated as absent (too degraded to rely on).
-- Distinct from WEAPON_CONDITION_MIN (0.25) which triggers a swap mid-fight.
AutoPilot_Constants.WEAPON_FIGHT_CONDITION_MIN = 0.15

-- Survival stat thresholds ------------------------------------------------
-- B42 stat scale: 0.0 = fine, ~1.0 = critical (hunger, thirst, fatigue, ...).
-- Endurance is inverted: 1.0 = full, 0.0 = empty.
-- Boredom / sanity / panic use an integer 0-100 scale in B42.

-- Trigger eating when hunger >= 20%.  Gives enough lead time to find food before
-- the moodle escalates from "Hungry" to "Very Hungry".
AutoPilot_Constants.HUNGER_THRESHOLD = 0.20

-- Matched to hunger sensitivity; thirst escalates faster but same logic applies.
AutoPilot_Constants.THIRST_THRESHOLD = 0.20

-- Trigger sleep at 70% fatigue -- early enough to reach a bed before the
-- "Exhausted" moodle fires and impairs movement.
AutoPilot_Constants.FATIGUE_THRESHOLD = 0.70

-- Boredom and sadness use the 0-100 integer scale.
AutoPilot_Constants.BOREDOM_THRESHOLD = 30
AutoPilot_Constants.SADNESS_THRESHOLD = 20

-- Begin rest when endurance drops to 30%.  This threshold avoids the
-- sit-stand loop that fires at mild exertion (moodle level 1-2).
AutoPilot_Constants.ENDURANCE_REST_MIN = 0.30

-- Do not start a new exercise set below 50% endurance; let it recover passively.
AutoPilot_Constants.ENDURANCE_EXERCISE_MIN = 0.50

-- Timing -------------------------------------------------------------------
-- PZ runs at ~20 game ticks per real second.

-- Main AutoPilot evaluation interval (game ticks).
-- 15 ticks * (1 s / 20 ticks) = 0.75 s between evaluations.
AutoPilot_Constants.TICK_INTERVAL = 15

-- Post-action suppression window (evaluation cycles).
-- 4 cycles * 15 ticks * (1 s / 20 ticks) = 3 s cooldown after any action.
AutoPilot_Constants.ACTION_COOLDOWN_CYCLES = 4

-- State-write interval (evaluation cycles).
-- 14 cycles * 15 ticks * (1 s / 20 ticks) = 10.5 s between state snapshots.
AutoPilot_Constants.STATE_WRITE_INTERVAL = 14

-- Exercise set duration sent to ISFitnessAction (game minutes).
AutoPilot_Constants.EXERCISE_MINUTES = 20

-- Fitness focus does squats until any leg part's stiffness reaches this,
-- then switches to sit-ups while the legs recover.  The health panel starts
-- showing stiffness above 5; 20 = clearly sore.
AutoPilot_Constants.SQUAT_STIFFNESS_MAX = 20

-- Per-exercise diminishing returns: PZ silently reduces an exercise's XP to
-- ~zero when it is repeated too long (observed live: character kept
-- exercising, XP flatlined).  A completed set that gains less than this much
-- XP marks the exercise "fatigued"...
AutoPilot_Constants.EXERCISE_MIN_XP_PER_SET = 0.5
-- ...for this long (game-time ms; 3 in-game hours), after which it is tried
-- again.  While every exercise in the focus pool is fatigued, training
-- pauses instead of burning food and endurance for nothing.
AutoPilot_Constants.EXERCISE_FATIGUE_RECOVERY_MS = 3 * 60 * 60 * 1000

-- Max search results stored for state reporting after searchItem.
AutoPilot_Constants.SEARCH_RESULTS_MAX = 10

-- Max inventory item names included in the state snapshot.
AutoPilot_Constants.INVENTORY_SUMMARY_MAX = 20

-- Exercise equipment fetch radius (home containers scanned for a dumbbell or
-- barbell so the higher-xpMod equipment exercises unlock).
AutoPilot_Constants.EXERCISE_EQUIP_SEARCH_RADIUS = 80  -- tiles (capped for scan cost)

-- Phase 2: Endurance gating thresholds (0.0-1.0)
AutoPilot_Constants.EXERCISE_ENDURANCE_MIN    = 0.30    -- skip exercise below this
AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.70    -- resume exercise above this

-- Phase 2: Daily exercise cap (sets per in-game day)
AutoPilot_Constants.EXERCISE_DAILY_CAP = 20

-- Phase 3: Weight management thresholds (in-game weight units)
AutoPilot_Constants.WEIGHT_UNDERWEIGHT = 65    -- below this: prioritize high-calorie food
AutoPilot_Constants.WEIGHT_OVERWEIGHT  = 85    -- above this: prefer low-calorie food

-- Phase 3: Happiness / boredom thresholds
AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD  = 40   -- MoodleType.Unhappy level to trigger boredom action
-- HAPPINESS_FOOD_PRIORITY: tasty-food path fires at or above this Unhappy moodle level,
-- before reading. Set to a value ≤ HAPPINESS_LOW_THRESHOLD to always prefer food first.
-- Default 40 = same as HAPPINESS_LOW_THRESHOLD (food preferred whenever unhappy block fires).
AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY  = 40

-- Phase 3: Barricade maintenance
-- Re-check home perimeter for newly broken windows every this many in-game days.
AutoPilot_Constants.BARRICADE_RECHECK_INTERVAL = 3  -- in-game days

-- Phase 3: Foraging / supply run radii
AutoPilot_Constants.LOOT_RADIUS_HOME   = 80    -- normal home-area loot radius (capped for scan cost)
AutoPilot_Constants.LOOT_RADIUS_SUPPLY = 150   -- expanded radius for supply runs (rare; hitch accepted)
AutoPilot_Constants.SUPPLY_RUN_TRIGGER = 5     -- consecutive empty loot cycles before expanding radius

-- Phase 4: Combat weapon management
AutoPilot_Constants.WEAPON_CONDITION_MIN  = 0.25  -- swap weapon if condition drops below this (0.0-1.0)
AutoPilot_Constants.WEAPON_SEARCH_RADIUS  = 80    -- tiles to search for a replacement weapon

-- Phase 4: Temperature / clothing thresholds
-- BodyStats temperature is roughly -100 (freezing) to +100 (boiling), 0 = comfortable
AutoPilot_Constants.TEMP_TOO_COLD = -20   -- equip warmer clothing below this
AutoPilot_Constants.TEMP_TOO_HOT  =  20   -- equip lighter clothing above this
AutoPilot_Constants.CLOTHING_SEARCH_RADIUS = 80

-- Phase 4: Barricading
AutoPilot_Constants.BARRICADE_SEARCH_RADIUS = 15  -- only barricade windows/doors within home radius

-- Pain / sleep arbitration ------------------------------------------------
-- Pain (0-100 integer scale) above this value blocks the sleep transition until
-- the character has taken a painkiller or received medical treatment.
AutoPilot_Constants.PAIN_SLEEP_THRESHOLD = 30

-- Telemetry log rotation -----------------------------------------------------
-- Once per session, if the run log exceeds MAX lines the oldest are dropped,
-- keeping the newest KEEP lines (the file previously grew unbounded).
AutoPilot_Constants.TELEMETRY_MAX_LINES  = 20000
AutoPilot_Constants.TELEMETRY_KEEP_LINES = 5000

-- Map / container depletion cache ----------------------------------------
-- Maximum depleted-square entries before the oldest are pruned.
-- Keeps the table bounded in memory for long-running sessions.
AutoPilot_Constants.DEPLETED_CAP = 500

-- Proactive supply management -----------------------------------------------
-- Trigger a proactive loot run when carried supply counts fall below these.
-- Applied when survival stats are still fine (prevents reactive-only looting).
AutoPilot_Constants.SUPPLY_FOOD_MIN  = 3  -- food items (non-rotten, caloric)
AutoPilot_Constants.SUPPLY_DRINK_MIN = 2  -- drink items (thirst-reducing)

-- Proactive water refill only runs while calm: thirst below this (0.0-1.0).
-- At/above it the normal doDrink path is about to handle hydration anyway.
AutoPilot_Constants.PROACTIVE_WATER_THIRST_MAX = 0.10

-- Proactive scavenging is a background chore, not the mod's purpose: keep it
-- near home, infrequent, and able to give up.  (Without these limits it
-- dragged the character across an 80-tile radius every idle cycle and
-- exercise never ran — observed live via telemetry.)
AutoPilot_Constants.PROACTIVE_LOOT_RADIUS     = 25    -- tiles, home-ish only
AutoPilot_Constants.SCAVENGE_COOLDOWN_CYCLES  = 80    -- ~1 min between trips
AutoPilot_Constants.SCAVENGE_STUCK_LIMIT      = 3     -- attempts w/o supply gain
AutoPilot_Constants.SCAVENGE_BACKOFF_CYCLES   = 1200  -- ~15 min after giving up

-- Base maintenance -----------------------------------------------------------
-- Eval cycles between barricade re-checks (~3 min at 0.75 s/cycle).
AutoPilot_Constants.BARRICADE_RECHECK_CYCLES = 240

-- Main loop timing (aliases) -----------------------------------------------
-- TICK_INTERVAL and ACTION_COOLDOWN_CYCLES govern the main evaluation cadence:
--   OnTick fires ~20 times per real second.
--   TICK_INTERVAL = 15  ->  evaluation every ~0.75 s
--   ACTION_COOLDOWN_CYCLES = 4  ->  ~3 s suppression after any queued action
--
-- Max consecutive identical-action ticks before the queue-thrash guard fires.
-- At TICK_INTERVAL=15 ticks/eval, 15 evals ≈ 11 s of identical action.
AutoPilot_Constants.MAX_ACTION_STREAK = 15

-- Maximum real-time milliseconds allowed per exercise session (wall-clock guard).
-- Prevents exercise-spam at high game speeds (e.g. 3× time warp).
-- 600 000 ms = 10 minutes of real time; the in-game day duration is ~28 minutes.
AutoPilot_Constants.EXERCISE_REAL_TIME_CAP_MS = 600000
-- format `AutoPilot_Constants.FIELD = <number>` with no leading whitespace.
-- Do not introduce leading spaces or multi-line assignments for tunable lines.
