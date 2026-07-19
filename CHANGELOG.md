# Changelog

All notable changes to AutoPilot are documented here.

## [V4.1] - 2026-07-19 - ACTION-PERK XP VISIBILITY (WOODWORK + DOCTOR)

Implements the two approved V4.0 expansion candidates C2 and C6
(docs/EXPANSION_PROPOSAL_V4.md): read-only XP visibility for the two perks
the mod already trains through real queued actions. No new engine APIs, no
new actions, and no XP grants (the standing no-addXp rule holds); everything
rides the verified `getXp():getXP` / `getPerkLevel` /
`PerkFactory.getPerk():getTotalXpForLevel` surfaces and the verified 42.19
perk naming (Carpentry=Woodwork, FirstAid=Doctor).

### Added - Woodwork visibility (C2)

- When a barricade maintenance pass queues real `ISBarricadeAction` work,
  the Woodwork perk is sampled into the XP metrics window (session baseline
  plus rolling rate), so the safehouse upkeep the mod already performs shows
  up as leveling progress. Sampling is event-driven (only when actions
  queue), and deliberate de-barricade grind loops remain out of scope.
- F11 panel: a Woodwork block (level, XP to next, session gain, XP/h, ETA)
  in the same style as the Strength/Fitness blocks.

### Added - Doctor visibility (C6)

- When Medical queues a real treatment action (`ISApplyBandage`), the Doctor
  perk is sampled the same way; First Aid trains passively from exactly that
  treatment. Purely observational: no behavior change to Medical.
- F11 panel: a matching Doctor block.

### Changed - telemetry schema v3

- Run-log lines now end `...,str=N,fit=N,wood=N,doc=N`: the Woodwork and
  Doctor perk levels append after `fit` and `schema_version` bumps to 3.
  Additive-only as always: old parsers ignore unknown keys and v2 (and
  older) logs still parse. `triage_run_log.py` coerces the new fields
  tolerantly (absent in old logs is fine).

### Testing

- Suite: 9 Lua files, 225 assertions (was 194), all green: Woodwork/Doctor
  metrics cases in `test_leveler_metrics.lua`, sampling-callsite assertions
  via suite-local AutoPilot_XP recording stubs in
  `test_home_map_barricade.lua` and `test_medical_logic.lua`, a schema-v3
  line-format check in `test_telemetry_schema.lua`, and v2/v3 tolerance
  tests in `tests/test_triage_run_log.py` (45 pytest tests). No new mock
  surface; the mock header records the V4.1 perk callsites. luacheck stays
  0 warnings / 0 errors across 17 modules.

## [V3.3] — 2026-07-18 — EQUIPMENT TRAINING, PANEL STATUS, MOD OPTIONS

### Added — deeper training

- **Equipment exercises join the rotation** (verified against 42.19's
  definitions + the vanilla `inventory:contains(item, true)` gate): the
  Strength pool is now dumbbell press / biceps curl (1.8x) -> barbell curl
  (1.2x) -> push-ups, using whichever gear is carried; Auto inserts dumbbell
  press after burpees. Items are equipped per the exercise's `prop`
  (twohands/switch) exactly like the vanilla fitness UI does.
- **Daily equipment fetch**: once per day (strength/auto focus) the bot pulls
  a dumbbell/barbell from home containers when none is carried, unlocking the
  higher-XP exercises.
- The pre-3.3 "tier multiplier" logic is gone — merely HOLDING gear grants
  nothing; the xpMod belongs to the equipment exercise type.

### Added — F11 panel

- Live trainer status line ("training: squats", "resting (endurance
  recovering)", "resting (exercises fatigued)", "fetching exercise
  equipment") + sets today N/cap.
- Long-term `getRegularity` shown for the exercise currently training.
- Arm/disarm button (same path as F10) with live state.
- Panel position remembered per character (ModData).
- Applied adaptive tweaks listed (up to 4) under the death summary.

### Added — mod options (PZAPI.ModOptions, verified in 42.19)

- Options > Mods > AutoPilot Leveler: sliders for daily set cap, endurance
  minimum, XP-fatigue recovery hours, food/drink stockpile minimums,
  proactive loot radius, detection radius, close-danger radius; rebindable
  arm/panel keys. Values apply once per session (before Adaptive's deltas,
  so both tuning layers compose) and live on options-save.

### Fixed

- **Load-time constant caching made runtime tuning partially inert**:
  DETECTION_RADIUS / FLEE_HORDE_SIZE (Threat), MEDICAL_LOOT_RADIUS (Medical),
  and the hunger/thirst triggers (Needs) were captured into file-locals at
  load, so the Adaptive death-learning rules that adjust them never took
  effect — and mod options would have had the same problem. All tunable
  constants are now read live at their use sites.

### Housekeeping

- Telemetry run log rotates once per session past 20k lines (keeps newest
  5k) — closes the "grows unbounded" Workshop limitation.
- README rewritten for the V3.3 leveler; TESTING.md gains V3.3 checks and a
  multi-hour soak-test section.

### Testing

- Suite: 9 files, 194 assertions, all green (equipment-gating tests added);
  luacheck 0 warnings / 0 errors across 17 modules.

## [V3.2] — 2026-07-18 — SPLITSCREEN REMOVED

Splitscreen support is removed entirely (it could not be made to work
reliably); multiplayer compatibility is kept — in MP each client automates
its own character.

### Removed

- The per-player tick loop (`getPlayerCount`/index iteration): Main now
  drives only the local player via `getSpecificPlayer(0)`.
- The controller Back/Select double-tap toggle (OnJoypadButtonPress handler)
  and the `JOYPAD_*` constants.
- The F11 panel's P1-P4 player selector: the panel configures the local
  player only.
- `tests/test_splitscreen.lua` (15 assertions) and all splitscreen items in
  TESTING.md / MULTIPLAYER.md; the "Splitscreen" Workshop tag.

### Changed

- Main's per-player state tables simplified to plain locals (mode, cooldown,
  streak, init/death flags).
- HUD hint is now "F10 Toggle, F11 Panel".
- Internal per-player keying in Home/Map/Telemetry/Leveler/XP remains (it is
  harmless plumbing and always keys 0 now); the MP Lua-reload hardening from
  the dry-run fix is unchanged.
- modversion 3.2.

### Fixed — second MP dry-run finding

- **Launch error + dead F11 panel**: `Events.OnQueueNewGame` does not exist
  during the 42.19 server-connect Lua reload; the unguarded `.Add` on the
  last line of AutoPilot_Main crashed that file's load — and PZ then skipped
  every alphabetically-later module (Needs, Threat, Telemetry, UI...), which
  is why F11 silently did nothing. Both session-end registrations are now
  existence-guarded. F11 failures are also no longer silent: panel errors
  print to the console (via the real print, not the debug noop) and flash a
  HUD warning, and pressing F11 while the UI module is missing says exactly
  that instead of doing nothing.

### Fixed — third MP dry-run finding (exercise never started)

- **`ISFitnessAction:new` args**: the real 42.19 signature is
  `(character, exercise, timeToExe, exeData, exeDataType)` — data table 4th,
  type STRING 5th (feeds the String-typed `setCurrentExercise` at line 217,
  which is exactly where the live stack trace pointed). The V2.1 "fix" that
  swapped these was based on a stale phantom copy of the file; the ORIGINAL
  mod call was correct and is restored. Same story for
  `ISTimedActionQueue.addGetUpAndThen` (it exists; restored — stands the
  character up before exercising) and `ISRestAction:new(character, bed,
  useAnimations)` (3-arg restored).
- Re-verified every other V2.1 signature change against the live install via
  shell: barricade (equip hammer+plank, 4-arg), water actions, equip action,
  walk helpers, `isPlayerDoingAction` (and `isAllDone` truly does not exist),
  and the sleep flow (`onSleepWalkToComplete(playerIndex, bed)`) are all
  correct as shipped.
- Test mocks updated to the runtime-verified signatures (type-asserting
  table-4th/string-5th on the fitness constructor).

### Fixed — fourth MP dry-run finding (aimless wandering, still no exercise)

- **Proactive scavenging starved the trainer**: telemetry showed an endless
  `scavenge -> cooldown -> busy(walking)` loop — with under 3 food / 2 drink
  carried, the character toured an 80-tile radius looting every idle cycle,
  and exercise (bottom of the priority chain) never ran.
  - **Priority reorder**: exercise/leveler now sits directly above the
    background chores (survival needs still win; endurance gates hand cycles
    to the chores while recovering between sets).
  - **Scavenge is now a bounded background chore**: 25-tile radius, ~1 min
    cooldown between trips, and a give-up backoff (~15 min) after 3 trips
    with no supply-count improvement. Reactive hunger/thirst still search the
    full radius.
  - **Predicate alignment**: lootNearbyFood now only picks calorie-positive,
    non-drink items — the same definition getSupplyCounts uses — so each loot
    trip actually raises the counter it is trying to satisfy.

### Fixed — fifth MP dry-run finding (permanent combat mode, still no exercise)

- **Radius presence treated as danger**: telemetry showed every cycle stuck on
  `combat:threat, zombies=3` — zombies milling outside the safehouse walls
  kept the threat branch claiming every cycle (and with home set, fight
  redirects to flee-toward-home, i.e. standing still). Threat.check now has
  an ENGAGEMENT GATE: it only responds when the engine's own threat counters
  fire (`getNumChasingZombies` / `getNumVeryCloseZombies` /
  `getNumVisibleZombies` — the same signals vanilla uses to gate sleeping) or
  when a zombie is within the new `CLOSE_DANGER_RADIUS` (6 tiles, catches
  approaches from behind). Distant/unseen zombies no longer block training.

### Changed — opt-in activation + exercise mapping (dry-run feedback)

- **Inactive on spawn**: the mod now starts OFF. Intended flow: reach a
  stable state first (vicinity cleared, supplies stocked), then press F10 to
  start grinding — the survival layer is a FAIL-SAFE while training, not a
  comprehensive autopilot. Home anchors on the first ACTIVE cycle instead of
  the first tick. New `AutoPilot.isActive()` accessor.
- **Exercise mapping** (player design; the old lists alternated
  push-ups/squats under a Strength focus even though squats train Fitness):
  - Strength -> push-ups only.
  - Fitness -> squats; automatically switches to sit-ups while any leg
    part's stiffness is at/above `SQUAT_STIFFNESS_MAX` (20).
  - Auto -> burpees (train Strength AND Fitness together).
  Verified against shared/Definitions/FitnessExercises.lua (squats=legs,
  pushups=arms/chest, situp=abs, burpees=all) and the real
  `bodyPart:getStiffness()` API.

### Added — XP-fatigue detection (sixth dry-run finding)

- **PZ applies per-exercise diminishing returns**: repeat one exercise long
  enough and its XP silently drops to ~zero while the animation continues
  (observed live: character kept exercising, session gain flatlined). The
  engine exposes no short-term fatigue to Lua (only long-term
  `getRegularity`), so the mod measures the XP each completed set actually
  produced:
  - a set gaining under `EXERCISE_MIN_XP_PER_SET` (0.5) marks that exercise
    fatigued for `EXERCISE_FATIGUE_RECOVERY_MS` (3 in-game hours);
  - the focus pool rotates (fitness: squats -> sit-ups; auto: burpees ->
    push-ups/squats/sit-ups); a fully fatigued pool PAUSES training instead
    of burning food and endurance for zero XP;
  - interrupted sets (under 80% of set length) are never judged;
  - snapshots are guarded by character identity so a death/respawn can never
    false-fatigue an exercise against the old character's XP.

### Testing

- Suite: 9 files, 190 assertions, all green (4 new fatigue-detection tests);
  luacheck 0 warnings / 0 errors across 16 modules.

## [V3.1] — 2026-07-18 — SCOPE REFOCUS: AUTO-EXERCISE LEVELER

Deliberate scope-down from V3.0's broad skill registry to a focused identity:
**auto-exercise leveler (Strength/Fitness) with full survival mechanics**.
MP + splitscreen support and the death-learning layer are kept; survival is
always on (the life-support toggle is removed).

### Removed (aggressive trim — 6 modules deleted)

- `AutoPilot_Skills` (daily skill rotation), `AutoPilot_Foraging` (zone
  learning), `AutoPilot_Vehicles` (registry/boarding), `AutoPilot_Combat`
  (walker/runner advisory), `AutoPilot_Explore` (frontier exploration), and
  `AutoPilot_Actions` (legacy LLM command registry), plus all their wiring in
  Threat/Needs/Main/Inventory and the EXPLORE_* constants.
- Leveler: non-exercise skills, skill-book reading (no STR/FIT books exist in
  B42), and the life-support toggle.
- Kept from the vehicle work: sleeping in a vehicle you are ALREADY seated in
  still counts as a bed (uses only vanilla APIs, no module needed).

### Changed

- Leveler focus options are now **Auto (balance) / Strength / Fitness**;
  default Auto preserves the classic train-the-lower-stat behavior. Focus
  persists per player in ModData.
- F11 panel shows BOTH exercise perks' metrics (level, XP-to-next, session
  gain, XP/hour, ETA), highlighting the focused one; P1-P4 selector kept for
  splitscreen.
- The exercise step remains the lowest survival priority (idle slot), now
  routed through the leveler for focus + metrics.
- Adaptive away-death rule retargets `LOOT_RADIUS_SUPPLY` (floor 80) since
  the explore frontier no longer exists.
- modversion 3.1; description refocused.

### Survival core retained (always on)

Eat/drink/sleep/rest, medical + auto-bandage, threat fight-or-flee, looting +
supply runs + depletion memory, proactive water refill + supply top-up, home
anchor + barricade maintenance, temperature clothing, boredom reading.

### Fixed — MP dry-run finding (live 42.19 server)

- **Error spam ("__add not defined") every engine tick in multiplayer**:
  joining a server makes PZ re-execute all mod Lua, and a previously
  registered OnTick closure can survive with dead upvalues — the first
  statement (`tickCounter + 1`) then throws every tick, which also blocked
  ALL evaluation (no exercise, frozen metrics). Tick state now lives on the
  shared global `AutoPilot` table (resolved at call time, immune to stale
  upvalues), self-heals via coercion, and duplicate handler registrations
  dedupe by frame timestamp. Keyboard/joypad handlers got matching
  stale-closure guards. Found via the in-game error counter (2671 and
  climbing) + console.txt stack traces.

### Testing

- Suite adjusted to the trimmed surface: 10 files, 188 assertions, all green;
  luacheck 0 warnings / 0 errors across the 16 remaining modules.

## [V3.0] — 2026-07-18 — AUTO-LEVELER PIVOT

The mod's identity pivots from "AFK survival autopilot" to "auto-leveler with
optional life support". Target: Build **42.19.0 Unstable** (the current public
unstable; 42.20 is still internal, and 42.19 saves will not carry into it).

### Added — auto-leveler core

- **`AutoPilot_Leveler`**: per-player target-skill selection (persisted in
  ModData, MP-safe via transmitModData). Skill registry with honest status per
  skill:
  - *ready*: Strength, Fitness (exercise), Carpentry (barricading).
  - *passive*: First Aid (trains when treating real wounds).
  - *planned* (greyed out with the reason): Tailoring, Mechanics, Cooking,
    Fishing, Foraging — 42.19 verification found no clean queueable action
    path yet (crafting rework / minigame / UI-bound systems). Direct addXp()
    grants are deliberately NOT used: they bypass real actions, desync in MP,
    and amount to cheating rather than automation.
- **Skill-book reading**: before training, the leveler reads a matching,
  unfinished skill book covering the current level band (XP multiplier prep;
  `SkillBook` table + `ISReadABook`, verified).
- **`AutoPilot_XP`**: metrics engine — level, XP, XP-to-next
  (`PerkFactory...getTotalXpForLevel`), session gain, XP/hour over a rolling
  10-minute real-time window, and ETA to next level.
- **F11 panel (`AutoPilot_UI`)**: skill selector (per player, with a P1-P4
  selector so the keyboard user can configure splitscreen players), live
  metrics, book-multiplier indicator, deaths + adaptive-tweaks summary.
- **Life-support toggle** (per player, persisted): ON = survival layer keeps
  the character alive while training; OFF = pure leveler, the player handles
  eating/drinking/sleeping/combat manually. Combat response is part of the
  toggle.

### Added — death learning layer

- **`AutoPilot_DeathLog`**: per-player ring buffer of recent decisions; on
  death writes a full context snapshot (stats, wounds, zombie count, position,
  distance from home, hours survived, active skill, recent decisions,
  classified cause) to `Zomboid/Lua/auto_pilot_deaths.log`.
- **`AutoPilot_Adaptive`**: at session start, reads the death log and applies
  BOUNDED, transparent threshold adjustments (each rule has a hard floor/cap;
  only the last 25 deaths count). Examples: horde deaths lower the flee
  threshold and widen detection; starvation deaths lower the hunger trigger
  and raise the food stockpile minimum; far-from-home deaths shrink the
  explore frontier. All applied tweaks are listed in the F11 panel.

### Changed

- `pzversion` targets **42.19.0** (was mistakenly aimed at the unreleased
  42.20); modversion 3.0; mod renamed "AutoPilot Leveler" with pivoted
  description.
- Priority chain: the selected target skill replaces the legacy daily skill
  rotation and the idle STR/FIT exercise default (both still apply when no
  target is selected, preserving pre-3.0 behavior).
- Exercise seam `AutoPilot_Needs.trainExercise(player, focus)` exposes
  focused STR-vs-FIT training to the leveler.
- CI now runs ALL Lua test files (previously only 5 of 9, letting the others
  rot unnoticed).

### Multiplayer

- B42 MP shipped to unstable in Dec 2025; 42.19 improves MP stability. The mod
  stays client-side only; see the new **MULTIPLAYER.md** for dedicated-server
  setup (Mods=/WorkshopItems=, RAM sizing, SleepAllowed) and splitscreen notes
  (players 2-4 need controllers; F11 panel configures all players).

### Testing

- New `tests/test_leveler_metrics.lua`: 46 assertions across XP metrics,
  death-log round-trip + cause classification, adaptive rule bounds and
  idempotence, leveler selection persistence, trainer dispatch, and book
  reading. Full suite: 188 assertions, 10 files, all green.

## [V2.1] — 2026-07-18

Build 42.20 stable compatibility pass. Every timed-action call was verified
against the installed B42 Lua API; several core loops silently called classes
or signatures that do not exist in B42 (hidden by blanket `pcall`s and by test
mocks that mirrored the wrong assumptions).

### Fixed — compatibility (load-blocking)

- **Missing `common/` folder**: B42 requires both `42/` and `common/` at the mod
  root; without `common/` the mod can fail to appear in the mod list at all.
- **`pzversion`**: `42.x` (non-numeric placeholder) → `42.20.0`.

### Fixed — broken core loops (silent API failures)

- **Sleep/bed-rest**: `ISGetOnBedAction` does not exist in B42. Sleep now uses
  the vanilla flow: `ISWorldObjectContextMenu.onSleepWalkToComplete(playerIndex,
  bed)` (takes the 0-based player index), with `setOnComplete` on the walk-to.
  Fatigue previously climbed unbounded because every bed sleep errored.
- **Exercise**: `ISFitnessAction:new` args were in the wrong slots (real
  signature: `character, exercise, timeToExe, fitnessUI, exeData`), and
  `ISTimedActionQueue.addGetUpAndThen` does not exist (now `add`). Exercise
  never started before.
- **Telemetry**: `getFileWriter(..., append=false)` truncated the run log on
  every line — the log only ever held one line. Now appends; end-marker file is
  now created on first run.
- **Barricading**: real signature is `ISBarricadeAction:new(character,
  windowObj, isMetal, isMetalBar)` and materials must be EQUIPPED (hammer
  primary + plank secondary, 2+ nails carried). Previous call passed the hammer
  and nails items as the boolean/time args; windows were never barricaded.
- **Splitscreen**: `getPlayer(n)` ignores its argument (always player 0); the
  real accessor is `getSpecificPlayer(n)`. Players 1-3 previously all resolved
  to player 0.
- **Vehicles**: `ISEnterVehicleAction` → real class `ISEnterVehicle:new(
  character, vehicle, seat)`.

### Fixed — logic

- **Boredom/sadness**: `CharacterStat.SANITY` reads HIGH when healthy; using it
  as "sadness" made the bored branch fire nearly every idle cycle. Now driven by
  the Unhappy moodle.
- **Flee stutter / explore return**: `ISTimedActionQueue.isAllDone` does not
  exist (pcall default made both checks no-ops). Now
  `isPlayerDoingAction`-based.
- **Home radius**: a stray `math.min(..., 50)` cap on ModData reload shrank the
  containment circle from 150 to 50 after save/load.
- **Idle-streak counter**: compared a value it had just overwritten (always
  true); now compares the previous label.
- **Supply-run depletion reset** is now per-calling-player (splitscreen-safe).
- **Foraging categorizer**: literature magazines no longer classified as
  firearm AMMO.

### Added — feature wiring (previously scaffolded/dead)

- **Combat advisory wired into Threat**: walker/runner tactical analysis now
  decides the default fight/flee branch (unknown tactics resolve to flee;
  safety gates unchanged).
- **Weapon pre-equip at check** (V2.0 changelog claim, now actually
  implemented): best usable weapon is readied before the engage decision.
- **Skills**: carpentry day runs a real barricade pass (Carpentry XP); the
  daily slot is only consumed when a real action queues. Other skills are
  detection-only until their B42.20 action paths are verified.
- **Vehicles**: nearby vehicles register at init; with no bed available the bot
  boards a safe vehicle and sleeps in it (B42 treats a vehicle as
  "averageBed").
- **Foraging**: every successful world-container loot teaches the zone system;
  supply runs target the best learned zone before blind sweeps.
- **`AutoPilot_Inventory.proactiveWaterRefill`** (V2.0 claim, now implemented):
  tops up water containers while calm; wired into proactive scavenge.
- **`AutoPilot_Inventory.emergencyMedicalLoot`** (V2.0 claim, now implemented):
  expanded-radius bandage loot ignoring home bounds.

### Performance

- Scan radii capped at 80 tiles (was 150; supply runs 150, was 300) — the
  radius-150 scans visited ~90k squares per call on a 0.75 s cycle.
- Zombie scan now cached per evaluation cycle (was up to 3 scans per cycle for
  HUD, threat, telemetry).

### Testing

- `tests/lua_mock_pz.lua` now mirrors the REAL B42 API surface: fake helpers
  (`ISGetOnBedAction`, `addGetUpAndThen`, `isAllDone`) removed so production
  calls to them fail loudly; `ISFitnessAction` mock asserts argument types;
  `getSpecificPlayer`, `getFileWriter` (append-aware), and
  `ISWorldObjectContextMenu.onSleepWalkToComplete` added.
- All 9 Lua test files pass (142 assertions), including the two files that were
  broken before this pass (`test_combat_policy`, `test_resource_economy`).

## [V2.0] — 2026-04-12

### Added

**Architecture & Splitscreen (M2)**
- **Per-player `AutoPilot_Map` depletion** (`[playerNum]`-keyed): depleted-square cache is now
  fully isolated per splitscreen player; removes the last shared mutable singleton.
- **Queue-thrash guard**: per-player `_actionStreak` counter detects repeated identical-action
  ticks (default cap: 15); clears the action queue when triggered, ending stuck loops.
- **Unreachable target retry cap**: `doFlee` and `doFight` each maintain per-player retry
  counters (max 3) before logging a `blocked` telemetry label and giving up gracefully.
- **`pcall` audit sweep**: raw `getContainer()`, `getObjects():size()`, `getName()`, and
  `getModData()` calls in `AutoPilot_Barricade` and `AutoPilot_Actions` are now wrapped.

**Combat & Threat (M3.1)**
- **Weapon pre-equip at check**: `AutoPilot_Inventory.checkAndSwapWeapon` is now called at the
  top of `Threat.check` before the flee/fight decision; the best weapon is always readied.
- **Post-combat recovery tier**: after a fight, if `hasCriticalWound` is true, the bot enters
  a `"recover"` priority tier (bandage + rest) before returning to the normal priority chain.
- **Retreat path quality**: `doFlee` (safehouse mode) now prefers `!isOutside()` (roof-covered)
  tiles over open ground to reduce rain-exposure penalty during retreat.
- **`FLEE_DISTANCE` / `FLEE_MOODLE_LIMIT` documented**: header-comment rationale added to
  Constants.

**Resource & Loot Economy (M3.2)**
- **Container scoring**: `_lootNearbyByPredicate` now picks the highest-score container
  (item_count / (distance² + 1)) instead of the first match, reducing unnecessary travel.
- **Emergency medical loot path**: when `hasCriticalWound` and no bandage is found locally,
  `AutoPilot_Inventory.emergencyMedicalLoot` triggers an immediate expanded-radius supply run
  for bandage items rather than silently returning false.
- **Tightened supply-run trigger**: if hunger > 40% and the current food loot cycle fails,
  a supply run fires immediately (no longer waits for `SUPPLY_RUN_TRIGGER` cycles).
- **Proactive water pre-fill**: `AutoPilot_Inventory.proactiveWaterRefill` refills empty water
  containers when near a water source and thirst < 10%.

**Needs / Priority Policy (M3.3)**
- **`recover` priority tier (P1.5)**: between `bandage` (P0) and `sleep` (P2); active while
  `_recoverUntilMs` has not expired after combat.
- **`HAPPINESS_FOOD_PRIORITY` constant**: makes the tasty-food-before-reading ordering
  explicit and configurable (was implicit through position in boredom block).
- **Outdoor walk for boredom**: if reading fails and boredom is above threshold, the bot
  queues a short outdoor walk rather than falling through to exercise silently.
- **Real-time exercise cap**: `EXERCISE_REAL_TIME_CAP_MS` (default 10 min) prevents
  exercise-spam at high game speeds when the in-game day rolls over quickly.

**Home & Safehouse (M3.4)**
- **Multi-shelter fallback**: `AutoPilot_Home.addFallback` / `getNearestFallback` store up to
  3 candidate shelter squares; used when the primary home square is obstructed.
- **Barricade maintenance mode**: `AutoPilot_Barricade.doBarricade` re-checks the home perimeter
  every `BARRICADE_RECHECK_INTERVAL` (default 3) in-game days for newly broken windows.
- **Home-set edge case**: on ModData load, if the home coordinate is inside a wall (`isFree`
  false), the bot shifts to the nearest free square within 5 tiles.

**Telemetry Schema v2 (M4.1)**
- `schema_version=2` field on every log line (additive — old parsers silently ignore it).
- `stage` field: which priority tier fired (`medical`, `survival`, `wellness`, `exercise`,
  `recover`, `idle`).
- `fail_reason` field: why an action returned false (`no_item`, `no_square`, `cooldown`,
  `blocked`, `cap_reached`).
- `retry_count` field: per-player retry counter value at decision time.
- `blocked` action label added to `REASON_CLASS` (maps to `"idle"` class).
- `recover` action label added to `REASON_CLASS` (maps to `"recover"` class).

**Benchmark / Python (M4.1)**
- `BenchmarkResult` gains: `schema_version`, `stage_counts`, `fail_reason_counts`,
  `blocked_ticks`.
- `_ACTION_CLASS_MAP` updated with `blocked` and `recover`.
- `parse_telemetry` handles `schema_version`, `retry_count` integer fields; backward-compat
  with v1 logs (missing v2 fields silently absent in entry dict).

**Test suites (M4.2)**
- `tests/test_splitscreen.lua`: 6 tests verifying per-player isolation for Map depletion,
  Home anchors, Telemetry tick counters, and fallback shelters.
- `tests/test_combat_policy.lua`: 4 tests for weapon pre-equip order, fight/flee path,
  retry cap, and safehouse redirection.
- `tests/test_resource_economy.lua`: 9 tests for container scoring, emergency medical loot,
  proactive water pre-fill, supply-run cache reset, and supply count separation.
- `tests/test_telemetry_schema.lua`: 7 tests for v2 field acceptance, backward compat,
  `blocked`/`recover` labels, and per-player tick counters.

**CI (M4.3)**
- `check.sh` line-count guard: warns (non-blocking) if any Lua module exceeds 1000 lines.
- `check.sh` test-file list updated to include all 4 new test files.
- `check.sh` pytest ignore list updated to exclude new Lua test files from Python discovery.

**Release (M5)**
- `modversion` bumped to `2.0` in both `42/mod.info` and `mod.info`.
- Release archive now includes `docs/` and `CHANGELOG.md`.
- Release archive verification checks `docs/architecture.md` and `CHANGELOG.md` presence.
- `docs/architecture.md` created: module ownership map, priority chain, telemetry schema,
  CI guards, and KPI targets.

### Changed
- `AutoPilot_Map.markDepleted` / `isDepleted` / `resetDepleted` / `getStats` now accept an
  optional `playerNum` argument (default `0`); single-player callers are unaffected.
- `AutoPilot_Telemetry.setDecision` extended with optional `stage`, `fail_reason`,
  `retry_count` parameters (backward-compatible: old 3-argument callers unaffected).
- `AutoPilot_Needs.check` `setDecision` calls all pass `stage` for telemetry.
- `AutoPilot_Threat.check` resets `_fleeRetries` on threat clearance (no zombies).
- `AutoPilot_Barricade.isDone` / `_markDone` wrapped in `pcall`.

### Constants Added
| Constant | Default | Description |
|---|---|---|
| `MAX_ACTION_STREAK` | `15` | Queue-thrash guard cap (ticks) |
| `EXERCISE_REAL_TIME_CAP_MS` | `600000` | Real-time exercise session cap (ms) |
| `HAPPINESS_FOOD_PRIORITY` | `40` | Unhappy moodle level to prefer tasty food first |
| `BARRICADE_RECHECK_INTERVAL` | `3` | In-game days between barricade maintenance checks |

---

## [V1.1] — 2026-04-12

### Added
- **Always-on by default**: AutoPilot starts enabled the moment a save is loaded. No manual
  F10 required to begin. Players may still toggle it off with F10 (keyboard) or Back/Select
  double-tap (controller).
- **Splitscreen support** (up to 4 local players): each player runs an independent autopilot
  instance with their own home anchor, inventory access, and telemetry log.
- **Joypad double-tap toggle**: controller players (joypad indices 1–3 in splitscreen) toggle
  autopilot by pressing Back/Select twice within the configured window.
- **Auto-home**: home anchor is set automatically to the player's spawn position on first
  enable. No manual "H" key or setup step needed.
- **One-time barricade**: on first enable, windows near home are queued for barricading if the
  player has nails and a hammer. The attempt is idempotent (ModData-backed) and never repeats.
- **Supply runs**: after `SUPPLY_RUN_TRIGGER` (default 5) consecutive empty loot cycles the
  search radius expands to 200 tiles and contracts again once supplies are found.
- **Temperature-aware clothing**: adjusts equipped clothing when body temperature drifts outside
  comfort range; seeks shelter when outside in rain or cold.
- **Per-player telemetry**: splitscreen players each write to their own log file
  (`auto_pilot_run_p1.log`, etc.). Run-end markers include player number.
- `AutoPilot_Telemetry.onShutdown()`: writes a `timeout`-status end marker when the game
  exits with autopilot still active, enabling benchmark analysis to distinguish death from
  session end.

### Changed
- **Supply-run counters separated**: food and drink empty-loot-cycle counters are now tracked
  independently (`_emptyFoodLootCycles`, `_emptyDrinkLootCycles`). Previously they shared a
  single counter, causing drink failures to inflate the food supply-run trigger (and vice versa).
- **`adjustClothing` return propagation fixed**: `AutoPilot_Needs.check()` now correctly
  returns `true` when clothing was adjusted, matching the contract expected by the main loop.
- WORKSHOP.md updated: compatibility section now reflects splitscreen support; Known Limitations
  section added.
- README.md updated: Telemetry section added; version references bumped to V1.1.

### Removed
- `anthropic>=0.50.0` dependency removed from `requirements.txt`. The Anthropic SDK was used
  by the deprecated sidecar architecture; no runtime code depends on it.

---

## [V1.0] — Initial public release

- Rule-based autonomous survivor: hunger, thirst, sleep, wounds, boredom, exercise.
- Threat check: fight/flee based on nearby zombies and negative moodle count.
- Home bounds: persistent home anchor via ModData; all non-combat movement stays in bounds.
- Depleted-container tracking via `AutoPilot_Map`.
- Structured telemetry log written to `~/Zomboid/Lua/`.
- CI: luacheck, deprecated-API guard, Lua unit tests, pytest.
