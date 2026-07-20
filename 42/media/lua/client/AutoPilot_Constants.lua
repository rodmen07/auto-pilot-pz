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

-- Mod version (V5.3) --------------------------------------------------------
-- The version string the RUNNING code reports, surfaced in the F11 panel
-- title so a player can tell at a glance which build is actually loaded.
--
-- Why a compiled-in constant and not a runtime read of mod.info: Kahlua is
-- sandboxed and this mod has no verified engine surface for reading its own
-- mod.info (getFileReader only reaches ~/Zomboid, not the mod folder, and
-- nothing in the verified 42.19 surface exposes the mod metadata table).  So
-- the value is duplicated here on purpose, and the duplication is guarded:
-- tests/test_version_sync.py fails the build unless this string equals
-- `modversion=` in BOTH mod.info files and the README's "Current modversion:"
-- line.  A release commit must therefore bump all four together.
--
-- This exists because of a real incident: the Workshop copy cached on the
-- user's machine was modversion 3.2 while the source tree was 4.3, and the
-- mismatch was invisible in game until it was dug out by hand.
--
-- NOT a tunable: never written by AutoPilot_Options, never read by any
-- decision path.  Presentation only.
AutoPilot_Constants.VERSION = "5.8"

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

-- Radius for rest-furniture search (beds > sofas > chairs/benches).
-- Capped at 80: iterateNearbySquares visits (2r+1)^2 squares per scan and its
-- own docs warn r > 80 risks frame hitches on the ~0.75 s eval cycle.
AutoPilot_Constants.REST_SEARCH_DIST = 80

-- V5.4: rest furniture OUTSIDE the home circle is eligible, but only this
-- close.  The full REST_SEARCH_DIST applies inside home (known-safe ground the
-- mod already walks freely); outside it the character would be crossing
-- unsecured tiles to sit down, so the reach is cut to a single street's width.
-- Benches, picnic tables and porch chairs sit just outside most safehouses,
-- which is exactly the seating the old inside-only filter made invisible.
AutoPilot_Constants.REST_OUTSIDE_SEARCH_DIST = 20

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

-- Trigger eating when hunger >= 15%.  Gives enough lead time to find food before
-- the moodle escalates from "Hungry" to "Very Hungry".
-- V4.7: player-tunable ("Eat when hunger reaches (%)", Survival Fail-Safe group).
-- Live-read constant (V3.3 pattern: AutoPilot_Needs.check re-reads it at every
-- decision, so an options-save applies on the very next cycle).  A character who
-- never crosses this simply never triggers the eat branch: lower it to eat
-- sooner.
-- V5.7: default lowered 0.20 -> 0.15.  This is the value the user dialled in on
-- the (finally working, see V5.5) in-game options page during live play and then
-- asked for as the shipped default: "I adjusted the settings, set these as the
-- defaults".  Eating earlier costs nothing when food is stocked and buys more
-- lead time to go find some when it is not.
AutoPilot_Constants.HUNGER_THRESHOLD = 0.15

-- Matched to hunger sensitivity; thirst escalates faster but same logic applies.
-- V4.7: player-tunable ("Drink when thirst reaches (%)"); same live-read seam.
-- V5.7: default lowered 0.20 -> 0.15 alongside hunger (same user request).
AutoPilot_Constants.THIRST_THRESHOLD = 0.15

-- Trigger sleep at 70% fatigue -- early enough to reach a bed before the
-- "Exhausted" moodle fires and impairs movement.
AutoPilot_Constants.FATIGUE_THRESHOLD = 0.70

-- Boredom and sadness use the 0-100 integer scale.
AutoPilot_Constants.BOREDOM_THRESHOLD = 30
AutoPilot_Constants.SADNESS_THRESHOLD = 20

-- Begin rest when endurance drops to 30%.  This is the CRITICAL floor: it may
-- walk to a bed and hand off to sleep.  Unchanged since V1.
AutoPilot_Constants.ENDURANCE_REST_MIN = 0.30

-- V5.7 (CONSOLIDATION): ENDURANCE_EXERCISE_MIN used to live here at 0.50.  It
-- was one of TWO transposed-name constants that BOTH gated exercise:
--   ENDURANCE_EXERCISE_MIN = 0.50  (this one; copied into a FILE-LOCAL in
--                                   AutoPilot_Needs, so it was NOT live-read
--                                   and no options change could ever move it)
--   EXERCISE_ENDURANCE_MIN = 0.30  (live-read, and the one the slider writes)
-- Both were tested in doExercise, one immediately after the other, so the
-- effective gate was max(0.30, 0.50) = 0.50: the untunable constant silently
-- floored the tunable one, and the "Min endurance to start a set" slider did
-- nothing at all below 50%.  Worse, that surviving single gate was ALSO the
-- resume gate, which is the single-rep thrash the user reported.
--
-- The transposed pair is gone.  What replaced it is NOT one gate but the
-- explicit hysteresis pair EXERCISE_ENDURANCE_MIN (floor) /
-- EXERCISE_ENDURANCE_RESUME (start gate), documented in the Phase 2 block
-- further down.  Both are live-read and both are slider-backed.

-- V5.4: sit down to recover when endurance is below this.  Tracks the
-- exercise minimum, which CLOSES THE DEAD ZONE: before V5.4 training
-- was gated at 50% and resting at 30%, so a character between the two could
-- neither train nor rest and simply idled.  A live run log proved it: zero
-- rest actions across ~16,000 ticks, idle streaks up to 403 ticks with
-- reason=no_action, and endurance never dipping below 40% so the 30% rest
-- gate never fired at all.  Sitting is a SEPARATE constant rather than a
-- hardcoded alias of the training gate so a player can decouple the two.
-- V5.4: player-tunable ("Sit to recover when endurance falls below (%)").
-- Live-read: AutoPilot_Needs.check re-reads it every decision (V3.3 pattern).
-- V5.7: default lowered 0.50 -> 0.35, tied to the training FLOOR rather than
-- to the start gate.  Sitting should begin when training STOPS, and with the
-- hysteresis pair training now runs all the way down to
-- EXERCISE_ENDURANCE_MIN (0.30).  0.35 sits just above that floor so the
-- character goes and sits down rather than first dipping under the floor and
-- ending the run on the stat.
--
-- This value alone does NOT decide when to sit.  The use site raises it to
-- the RESUME gate whenever no training run is active (see AutoPilot_Needs
-- check 7b): a character who is not mid-run and is below the resume gate has
-- nothing else to do, so it sits and keeps recovering toward
-- ENDURANCE_REST_TARGET instead of idling.  That is what makes the idle dead
-- zone unreachable for ANY combination of these sliders.
AutoPilot_Constants.ENDURANCE_SIT_MIN = 0.35

-- V5.4: stay seated until endurance climbs back to this.  Set ABOVE
-- ENDURANCE_SIT_MIN on purpose: equal values would sit and stand at the same
-- number and reintroduce the sit-stand loop the 30% floor was built to avoid.
-- V5.4: player-tunable ("Stay seated until endurance reaches (%)"); live-read.
-- V5.7: raised 0.70 -> 0.95.  Directly from the user: "I want the character
-- to rest until endurance is nearly full."  It must also stand the character
-- up ABOVE EXERCISE_ENDURANCE_RESUME, or a completed rest ends in a band
-- where training is still refused and the cycle idles again; with resume at
-- 0.90, standing up at 0.70 would have meant every rest finished straight
-- back into that band.  0.95 clears resume with 5 points of margin rather
-- than matching it exactly, because equal values thrash at the boundary.
AutoPilot_Constants.ENDURANCE_REST_TARGET = 0.95

-- V5.4: maximum time held in a single rest, in GAME milliseconds.  This is a
-- wedge guard, not the intended duration: the rest normally ends when
-- ENDURANCE_REST_TARGET is reached.  It replaces the flat 60000 (sixty IN-GAME
-- seconds, roughly one game minute) that made every rest end almost as soon as
-- it began.  30 game minutes is long enough for endurance to move meaningfully
-- while still releasing the cycle if the stat never recovers.
-- V5.4: player-tunable ("Max time seated per rest (game minutes)").
AutoPilot_Constants.REST_HOLD_MS = 30 * 60 * 1000

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

-- Phase 2 / V5.7: the exercise endurance HYSTERESIS PAIR (0.0-1.0).
--
-- These are TWO DIFFERENT QUESTIONS and must never collapse into one number:
--   RESUME = "there is enough in the tank to START a training run"
--   MIN    = "an ALREADY-RUNNING training run has to stop"
--
-- One threshold cannot express both, and trying made the mod useless.  The
-- user found it live: "The old setting of 50 made it so that only a single rep
-- would be completed after a period of resting (I guess the fatigue cap for
-- exercise is just under 50)."  That is a textbook single-threshold thrash: at
-- a lone gate of X the character rests up to X, starts a set, the first rep
-- drops endurance below X, training stops, it rests again.  One rep per rest,
-- forever.  Raising the number does not help, it makes it worse -- at 90 the
-- very first rep falls out of the gate.  The user saw that too: "I see that
-- the minimum endurance default of 90 is too high, but at the same time, I
-- want the character to rest until endurance is nearly full."
--
-- With a gap between the two, the cycle is what was actually wanted:
--   rest to 95% -> resume at 90% -> train all the way down to 30% (many reps)
--   -> sit at 35% -> rest to 95% -> repeat.
--
-- Both are read LIVE (AutoPilot_Needs re-reads them at every decision, V3.3
-- pattern) and both are player-tunable, so the pair can be retuned in game
-- with no reload.  The invariant the use sites depend on is simply
-- MIN < RESUME < ENDURANCE_REST_TARGET.

-- The FLOOR: an active training run continues down to this and stops below
-- it.  Deliberately LOW.  This is what buys a long productive run out of each
-- rest instead of a single rep.
-- V5.7: player-tunable ("Keep training until endurance falls to (%)").
AutoPilot_Constants.EXERCISE_ENDURANCE_MIN = 0.30

-- The START GATE: training RESUMES here after a rest.  Deliberately HIGH.
-- This is where the user's 90 belongs: they asked for "90" against the only
-- endurance slider the page had, and the value was right -- it was attached to
-- the wrong gate.  Restored in V5.7 (it briefly had zero readers, which is how
-- the single-threshold design got shipped in the first place).
-- V5.7: player-tunable ("Resume training when endurance reaches (%)").
AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME = 0.90

-- V4.6: optional hard ceiling on exercise sets per in-game day.
-- 0 (the default) means UNLIMITED: training is limited by XP PRODUCTIVITY
-- instead, via the per-exercise diminishing-returns detector above
-- (EXERCISE_MIN_XP_PER_SET / EXERCISE_FATIGUE_RECOVERY_MS), plus the
-- endurance gates, the training program's rest days and the intervention
-- backoff.  A counted ceiling cannot tell a productive set from a wasted
-- one, so it is no longer the thing that stops training; it is kept only
-- as an opt-in safety valve.  Any value > 0 restores a hard daily ceiling.
AutoPilot_Constants.EXERCISE_DAILY_CAP = 0

-- Phase 3: Weight management thresholds (in-game weight units)
AutoPilot_Constants.WEIGHT_UNDERWEIGHT = 65    -- below this: prioritize high-calorie food
AutoPilot_Constants.WEIGHT_OVERWEIGHT  = 85    -- above this: prefer low-calorie food

-- Phase 3: Happiness / boredom thresholds
AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD  = 40   -- MoodleType.Unhappy level to trigger boredom action
-- HAPPINESS_FOOD_PRIORITY: tasty-food path fires at or above this Unhappy moodle level,
-- before reading. Set to a value ≤ HAPPINESS_LOW_THRESHOLD to always prefer food first.
-- Default 40 = same as HAPPINESS_LOW_THRESHOLD (food preferred whenever unhappy block fires).
AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY  = 40

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

-- Training backoff after manual intervention (V4.5), in GAME minutes.
-- When the player intervenes in training (cancels a mod-queued set before
-- it ran to length, exercises manually while armed, or hits the F10 panic
-- stop), the trainer holds off re-queuing for this long instead of
-- bulldozing the cancel ~0.75 s later (the user-reported "can't cancel"
-- lockup).  Converted to game-ms at the use site (x 60000, same clock as
-- EXERCISE_FATIGUE_RECOVERY_MS).  0 disables the backoff.
AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES = 10

-- Session history (V4.2, expansion candidate C5) -----------------------------
-- AutoPilot_SessionHistory keeps one compact summary line per session in
-- auto_pilot_sessions.log: written at session end (death or shutdown) and
-- refreshed by periodic "open" checkpoints so a crash still leaves a
-- recent summary (the latest line per session wins at read time).
--
-- Checkpoint interval in evaluation cycles.
-- 400 cycles * 0.75 s/cycle = ~5 min of real time between checkpoint lines.
AutoPilot_Constants.SESSION_HISTORY_CHECKPOINT_CYCLES = 400
-- Retention bound: once per session the file is collapsed (one line per
-- session) and only the newest KEEP summaries survive (V3.3 rotation
-- pattern; keeps the file bounded by design).
AutoPilot_Constants.SESSION_HISTORY_KEEP = 30
-- Sessions shown in the F11 panel's history block (newest first).
AutoPilot_Constants.SESSION_HISTORY_PANEL_ROWS = 5

-- Training program (V4.3, expansion candidate C3) -----------------------------
-- Weekly split for the exercise slot.  The program table and all day
-- resolution live in AutoPilot_Leveler (pure, unit-tested); this is the
-- live-read selection seam the Options selector writes into (V3.3 pattern:
-- read at the use site every cycle, so options-save applies immediately).
-- STRING program id, not a numeric tunable: one of "balanced", "strength",
-- "fitness", "alternating", "restsplit" (unknown values validate to
-- "balanced").  The compiled-in default "balanced" has no rest days and
-- defers every day to the F11 focus selection, i.e. it is exactly the
-- pre-V4.3 behavior whenever Options never loads.
AutoPilot_Constants.TRAINING_PROGRAM = "balanced"

-- On-screen action/intention display (V4.4) ----------------------------------
-- Toggle for the read-only HUD line showing what the mod is currently doing
-- (or "Disarmed" when off). Live-read constant (V3.3 pattern: Options writes
-- here, so a mid-session options-save takes effect on the very next cycle).
-- 1 = show (default: this directly answers the feature request that
-- prompted V4.4), 0 = hide. Presentation only; never read by any decision
-- path, only by AutoPilot_Main's HUD line.
AutoPilot_Constants.HUD_SHOW_ACTION = 1
-- format `AutoPilot_Constants.FIELD = <number>` with no leading whitespace.
-- Do not introduce leading spaces or multi-line assignments for tunable lines.
