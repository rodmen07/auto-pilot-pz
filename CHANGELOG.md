# Changelog

All notable changes to AutoPilot are documented here.

## [V5.0] - 2026-07-19 - SCOPE REMOVAL: BARRICADING AND WOODWORKING

User directive: "Let's remove the barricading/woodworking functionality,
that is more of an artifact of the broader scoped auto-survival and is now
out of scope"

A scope removal earns the major bump. This is the same kind of change as
V3.1 (which deleted the Skills, Foraging, Combat, Vehicles, Explore and
Actions modules): the mod is an auto-EXERCISE leveler with a survival
fail-safe, and construction work was a leftover from the broad
auto-survival identity it stopped pursuing.

Medical is explicitly UNAFFECTED. The Doctor perk, its V4.1 C6 XP
visibility block, the `doc=` telemetry field, and all wound-treatment
logic remain exactly as they were. Only woodworking went.

### Removed

- `42/media/lua/client/AutoPilot_Barricade.lua` deleted (periodic window
  barricade maintenance, the immediate `doBarricade` pass, and the
  Woodwork XP sample that rode on it).
- The priority chain's tenth slot. `AutoPilot_Needs` no longer has a base
  maintenance step: `doBaseMaintenance` and the
  `setDecision("barricade", "maintenance")` tag are gone, and proactive
  scavenging is now the final slot.
- `AutoPilot_Main` no longer queues an initial barricade pass on the
  first active cycle or on re-arm, and dropped the `barricade =
  "Barricading"` HUD intention label.
- The F11 panel's Woodwork block, and `woodwork` as a tracked
  `METRIC_PERKS` id in `AutoPilot_Leveler`. The panel is two rows
  shorter. `getMetricsFor(player, "woodwork")` now falls back to
  Strength like any other unknown id.
- Constants `BARRICADE_RECHECK_INTERVAL`, `BARRICADE_SEARCH_RADIUS` and
  `BARRICADE_RECHECK_CYCLES`.
- `ISBarricadeAction` and `AutoPilot_Barricade` from `.luacheckrc`
  globals; `walkAdjWindowOrDoor` and `ISBarricadeAction` from the mock's
  verified-surface record.
- `barricade` from the Lua `REASON_CLASS` table AND from
  `benchmark.py`'s `_ACTION_CLASS_MAP`, in this same commit. The CI sync
  guard (`tests/test_automation_metrics.py`) enforces exact key-set
  equality both ways, so a one-sided edit is a build failure.

### Changed - telemetry schema v3 -> v4

The run-log line dropped `wood=` and `SCHEMA_VERSION` became 4. This is
the schema's first non-additive change, so it was made on evidence rather
than convenience:

- Both offline parsers are key=value readers. `parse_run_log` requires
  only `action` and an integer `run_tick`, and coerces `wood` when present
  but never consumes it. `benchmark.py` never listed `wood` among its
  integer fields at all.
- Verified empirically against the user's real ~2.6MB v3 log at
  `~/Zomboid/Lua/auto_pilot_run.log` (read-only): `triage_run_log.py`
  produced byte-identical output before and after the change, 13,867
  ticks across 8 sessions, 0 malformed lines.
- v2, v3 and v4 lines therefore all parse, including a single file that
  spans the upgrade. Existing run logs stay fully readable; no tombstone
  field was needed.

`triage_run_log.py` deliberately KEEPS `barricade` in its
`ACTION_CATEGORY` map. That tool reads historical logs, and dropping the
label would silently reclassify pre-V5.0 base-upkeep ticks as idle. It is
not sync-guarded against the Lua table, precisely so it can retain retired
labels.

The session-history file (`auto_pilot_sessions.log`) went to schema 2 for
the same reason: its `wood_start`/`wood_end` pair could only ever report a
perk the mod no longer touches, and the F11 history rows lost the dead
`W+0` column. Existing schema-1 lines still parse (the parser keys off
whatever fields a line carries and renders an absent pair as "?"), and
rotation rewrites retained lines as verbatim raw text, so real files on
disk survive untouched.

### Tests

- `tests/test_home_map_barricade.lua` renamed to `tests/test_home_map.lua`.
  Its seven Barricade cases were deleted; every Home (9) and Map (5) case
  was KEPT verbatim, because that behavior survives and Inventory, Threat,
  Needs and DeathLog all still depend on it.
- New `tests/test_priority_logic.lua` Scope Test 1: plants a
  booby-trapped `AutoPilot_Barricade` global and a recording telemetry
  stub, drives a fully idle cycle so evaluation walks the whole chain,
  and asserts nothing touches the module, no cycle is tagged
  `barricade`, and the chain's final decision is now `scavenge`.
- New `tests/test_leveler_metrics.lua` Leveler Test 5: `"woodwork"` must
  behave as an unknown id even though the engine still defines
  `Perks.Woodwork`.
- New `tests/test_telemetry_schema.lua` Test 9: a retired `barricade`
  label falls through to `class=idle`, guarding the sync-guard invariant
  from the Lua side.
- New `tests/test_triage_run_log.py::TestSchemaV4NoWood`: a v3 line WITH
  `wood=` and a v4 line WITHOUT it parse in the same file, and the
  retired `barricade` label still categorizes as survival.
- XP Test 5 was re-keyed from Woodwork to Doctor so the perk-generic XP
  engine keeps its non-exercise coverage.
- Suite: 12 Lua files, 658 assertions, all green (was 666 across 12 files
  before: 14 barricade assertions left, 6 scope-guard assertions arrived).
  luacheck 0 warnings / 0 errors. Python: 83 passed, up from 80.

### Docs

`README.md`, `ROADMAP.md` (barricading added to the standing non-goals),
`TESTING.md`, `WORKSHOP.md`, `docs/architecture.md`, `docs/baseline.md`,
`docs/triage.md` and the embedded Workshop description in
`sync_workshop.sh` all updated. `docs/EXPANSION_PROPOSAL_V4.md` is marked
HISTORICAL with a V5.0 supersession banner on candidate C2; C6 (Doctor)
is called out as still in scope.

## [V4.9] - 2026-07-19 - TRANSFER, THEN USE

User directive: "It should be transfer then bandage".

### Fixed - a found item was still not a usable item

V4.8 fixed the search SCOPE: a bandage in a fanny pack is now found. It
did not fix reachability. Project Zomboid actions (bandage, eat, drink,
take pill, read, equip, wear) act on the character's MAIN inventory, so
an item still nested in a backpack was selected and then quietly did
nothing. This was the open risk V4.8 flagged, and it applied to the whole
class of consumables, not just bandages.

- Every use site now queues an `ISInventoryTransferAction` moving the
  selected item into the main inventory FIRST, then queues the use action
  right behind it. `ISTimedActionQueue` runs them in that order, so the
  fix completes within a single cycle. This mirrors the vanilla inventory
  UI, and it is the same chaining shape the mod already used for
  walk-then-transfer (`AutoPilot_Inventory._queueTransfer`, `placeItem`)
  and equip-then-walk (`AutoPilot_Threat.doFight`).
- An item already in the main inventory queues NO transfer, so nothing
  redundant is added to the queue.
- If the engine refuses the transfer (the MP-unsafe path), the use action
  is skipped instead of firing on an unreachable item, matching the
  existing degradation in `AutoPilot_Medical.lootNearbyBandage`.

### Added - `AutoPilot_Utils.queueItemToMainInventory`

`queueItemToMainInventory(player, item, holdingContainer)` returns
`queued, usable`: whether a transfer was queued, and whether the caller
may now act on the item. A nil container (caller does not know) and a
container that IS the main inventory both mean "already usable, queue
nothing". The engine call is pcall-guarded.

### Changed - selectors report their holding container

These selectors now return `item, container` (an additive second return
value; callers that want only the item are unaffected):
`AutoPilot_Inventory.getBestFood`, `getBestFoodForHunger`,
`selectFoodByWeight`, `getBestDrink`, `getBestWeapon`, `getReadable`,
`preferTastyFood`, `bestMeleeWeapon`, `findClothing`, and
`AutoPilot_Medical.findBandage` (module-local).

### Converted use sites

`AutoPilot_Medical.doTreatWound` (ISApplyBandage), `AutoPilot_Needs`
doEat / doDrink / the painkiller path in doSleep / doRead / the unhappy
tasty-food path, `AutoPilot_Inventory.checkAndSwapWeapon`
(ISEquipWeaponAction) and `adjustClothing` (ISWearClothing), and
`AutoPilot_Threat.doFight` (ISEquipWeaponAction).

Not converted, deliberately: `refillWaterContainer` fills a bottle in
place and vanilla does not transfer for it, and world-container looting
already transfers into the main inventory by construction.

### Unchanged

Selection semantics, thresholds and priority order are untouched, as are
the V4.5 ownership registry / intervention backoff / F10 panic stop, the
V4.6 XP-gated cap and the V4.7 configurable thresholds. Every transfer is
queued through `AutoPilot_Utils.queueModAction`, so it is tagged as
mod-owned like every other action this mod queues.

### Tests

Lua assertions 575 -> 666. New V4.9 coverage: the user's exact scenario
(a fanny-pack bandage produces a transfer and THEN the bandage action, in
that order), depth-2 nesting, a main-inventory item queueing no transfer,
food and drink and painkillers in a bag, a bagged weapon and a bagged
garment, and a refused transfer degrading with no use action queued. All
new cases verified failing against the pre-fix code.

## [V4.8] - 2026-07-19 - CARRIED CONTAINERS ARE SEARCHED (BANDAGE FIX)

User-reported (HIGH): "I see the problem with healing as well. I was
scratched but not bleeding. Character should still attempt to bandage
with something in inventory (including fannypacks, backpacks, or
containers)."

### Fixed - item search scope, not wound detection

Wound detection was already correct: `AutoPilot_Medical.check(player,
false)` collects `scratched()` parts and `AutoPilot_Needs` calls it at
priority 4 for non-bleeding wounds. The bug was where the mod LOOKED for
the bandage.

- `player:getInventory():getItems()` returns only the TOP-LEVEL items of
  the main inventory; it does not descend into worn or carried
  sub-containers. A bandage in a fanny pack was therefore invisible,
  `findBandage` returned nil, and the character never treated a wound it
  had correctly detected.
- This was never bandage-specific. Every selector that scanned that flat
  list had the same blind spot, so food, drink, weapons, clothing, water
  containers and painkillers stashed in a bag were equally unreachable.

### Added - `AutoPilot_Utils.iteratePlayerItems` / `findPlayerItem`

- One shared walk over the player's carried inventory tree, depth-first
  with the main inventory visited first (so first-match selectors keep
  their old preference for a top-level item).
- Sub-containers are detected via `item:getItemContainer()`, pcall-guarded:
  on a build without that surface the walk degrades to exactly the old
  top-level-only behavior instead of erroring.
- Bounded by `PLAYER_ITEM_MAX_DEPTH` (3) plus a visited-container identity
  guard, so nested and even self-referential bags terminate.
- Player inventory only: no world scan, no square iteration.

### Fixed - bandage ranking

`findBandage` set its unlisted-item fallback INSIDE the scan loop, so the
first `isCanBandage()` item seen could lock itself in and outrank a better
bandage found later. A listed item now always beats an unlisted one, and
among listed items the lowest `BANDAGE_PRIORITY` index wins.

### Changed - selectors converted to the shared walk

`AutoPilot_Medical.findBandage`; `AutoPilot_Inventory.getBestFood`,
`getBestFoodForHunger`, `selectFoodByWeight`, `getBestDrink`,
`getBestWeapon`, `getReadable`, `getSupplyCounts`, `refillWaterContainer`,
`placeItem`, `preferTastyFood`, `bestMeleeWeapon`, `findClothing`,
`getInventorySummary`; and the painkiller lookup in
`AutoPilot_Needs`. `placeItem` additionally now passes the container that
actually holds the item as the transfer source instead of always naming
the main inventory.

Search SCOPE only: no threshold, priority order, or safety guarantee
changed. The V4.5 ownership registry / intervention backoff / F10 panic
stop, the V4.6 XP-gated cap, and world-container looting are untouched.

### Tests

- New `tests/test_container_search.lua` (36 assertions): depth reporting,
  early stop, depth guard, self-referential container, missing-surface
  degradation, and the converted food/drink/summary selectors.
- `tests/test_medical_logic.lua` grows the user's exact scenario (scratched
  with the only bandage in a worn backpack), a depth-2 fanny pack, and the
  ranking-fix regressions.
- Shared mocks gain `MockContainer` (nested containers matching the real
  `getItems` / `getItemContainer` signatures).
- Lua assertions 526 -> 575 across 12 files, all passing, luacheck clean.
## [V4.7] - 2026-07-19 - CONFIGURABLE HUNGER AND THIRST TRIGGERS

User-reported: "eating and healing don't appear to work", and separately
that "the character is able to retrieve food but doesn't eat it".

Investigation of roughly 11,900 ticks in `auto_pilot_run.log` found no
defect. `HUNGER_THRESHOLD` is 0.20 and the character's hunger never
exceeded 18% anywhere in that log, so the eat branch was correctly never
entered: there was nothing to eat about. The food in inventory came from
the separate proactive stockpile scavenge, which is supposed to stock up
BEFORE hunger bites. The eat mechanism itself is provably intact because
drinking runs the identical code path
(`AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, item, 1))`)
and fired 4 times in the same log once thirst crossed its own 20%
threshold. Healing showed zero bandage events for the same reason:
`bleeding` was 0 for nearly the whole log, so there was no wound to treat.

The real gap was that the trigger point was not adjustable in game, so a
player seeing "it never eats" had no way to test that theory. V4.7 makes
it adjustable.

### Added - Options

- Two sliders in the **Survival Fail-Safe** group of Options > Mods >
  AutoPilot Leveler:
  - "Eat when hunger reaches (%)" -> `HUNGER_THRESHOLD`
  - "Drink when thirst reaches (%)" -> `THIRST_THRESHOLD`
- Both are 5 to 50 in steps of 5, mapping through `scale = 0.01` exactly
  like the existing "Min endurance to start a set (%)" slider. Thirst is
  included because it is the same branch with the same pattern; making one
  tunable and not the other would be arbitrary.

### Unchanged - the defaults

- `HUNGER_THRESHOLD` and `THIRST_THRESHOLD` **remain 0.20**. Nothing about
  the shipped behavior changes for a player who never opens the options
  screen. The user did not ask for a retune and the telemetry did not
  justify one, so none was applied; the sliders exist so the player can
  make that call themselves.
- No V4.5 safety guarantee (ownership registry, intervention backoff, F10
  panic stop) and no V4.6 XP-gated cap semantics were touched.

### Notes - why no reload is needed

`AutoPilot_Needs.check` re-reads `AutoPilot_Constants.THIRST_THRESHOLD`
and `.HUNGER_THRESHOLD` at every decision (`AutoPilot_Needs.lua:1219` and
`:1245`, and `shouldInterrupt` at `:1175` and `:1179`), which is the V3.3
live-read pattern. `Options.applyToConstants` writes those same fields on
options-save, so a change applies on the very next cycle: no reload, no
re-init. Once-per-session application still happens BEFORE `Adaptive.init`,
so a player setting and a death-learning delta still compose in the same
stable order as before.

### Testing

- `test_priority_logic`: 102 -> 116 assertions. Two new cases drive
  `check()` with a mock player parked at 25% hunger (and 25% thirst) while
  the threshold is moved above and below him, proving the value is honored
  live rather than hardcoded: no eat action at a raised threshold, an eat
  action at a lowered one, the `>=` boundary inclusive, and
  `shouldInterrupt` following the same constant. Both cases assert the
  shipped default is still 0.20.
- New suite `test_options_mapping`: 33 assertions. First suite to load
  `AutoPilot_Options`, against a suite-local mock of only the already
  verified `PZAPI.ModOptions` calls. It asserts both new sliders register
  with the right name, range and step, land in the Survival Fail-Safe group
  rather than Training, open seeded at 20 (the unchanged default), and map
  a saved value through the 0.01 scale (15 -> 0.15, 35 -> 0.35, floor and
  ceiling, and back). An unscaled neighbour (`foodMin`, `drinkMin`,
  `detRadius`) is checked to stay a raw count so a scale cannot leak across
  entries, and a no-op re-save is verified to change nothing.
- Lua suite total: 479 -> 526 assertions across 11 files, 0 failures.
- `tests/lua_mock_pz.lua`: the `PZAPI.ModOptions` coverage record moves
  from `[G]` DOCUMENTED GAP to `[S]` PARTIAL GAP. The widgets themselves
  are still playtest-only; a mock cannot prove the real page draws.
- The stale note in `test_priority_logic` claiming `check()` takes a
  `skipExercise` argument was corrected: production `check(player)` takes
  the player only, so a case proving a need branch did NOT fire must assert
  on that branch's action type, not on an empty queue.

### In-game verification still required

Every control on the ModOptions page is playtest-only by design. Set "Eat
when hunger reaches (%)" to 5, Save, and confirm the bot eats on the next
cycle without a reload; see the new TESTING.md items under Survival Needs.

## [V4.6] - 2026-07-19 - XP GAIN GATES TRAINING; DAILY SET CAP IS OPT-IN

User-requested: the daily set cap was too restrictive because it counted
every exercise of the day against one shared budget, so training stopped
at an arbitrary number regardless of whether the sets were still paying
XP. Asked how it should be restructured, the user answered: "Exercise
should be capped by experience gain. Meaning only should stop when stop
gaining xp from doing a given exercise."

### Changed - XP productivity is now the primary limiter

- `AutoPilot_Constants.EXERCISE_DAILY_CAP` default 20 -> **0, and 0 now
  means UNLIMITED**. Any value > 0 still enforces a hard ceiling, so the
  old behavior remains available as an opt-in safety valve.
- `AutoPilot_Needs.doExercise` applies the daily-count gate only when the
  cap is > 0. With the default cap, training continues until something
  that actually knows the training is worthless stops it: the per-exercise
  XP-fatigue detector (a full-length set gaining under
  `EXERCISE_MIN_XP_PER_SET` fatigues that exercise for
  `EXERCISE_FATIGUE_RECOVERY_MS`, and a fully fatigued pool pauses
  training), the endurance gates, the V4.3 program rest day, or the V4.5
  intervention backoff. None of those were touched or weakened.
- The `_exerciseSetsToday` counter still runs and still resets on day
  rollover: it is useful information for the panel and the logs, it simply
  no longer halts training by itself. `getExerciseSetsToday` is unchanged.

### Changed - honest reporting with no cap

- `AutoPilot_Needs.getExerciseStatus` gains a pre-formatted `setsLine`
  field ("Sets today: 12 (no cap)" uncapped, "Sets today: 12/20" capped),
  following the same data-layer-formats-it convention as the V4.3 program
  line; `setsToday` and `cap` still carry the raw numbers.
- `AutoPilot_UI` (F11 panel) draws `setsLine` verbatim instead of building
  "%d/%d" itself, so an uncapped session can never render "12/0". A
  raw-count fallback covers an older/partial status table.
- The per-set console log reads "Exercise set 12 queued (no daily cap)."
  when uncapped and keeps the "12/20" form when a cap is set.

### Changed - Options

- The Training slider is now "Daily exercise set cap (0 = unlimited; XP
  gain is the real limiter)" with `min` 5 -> 0, so the new default is
  reachable from the options UI and a player who wants a ceiling can still
  dial one in (and back out to 0).

### Testing

- `test_priority_logic`: 83 -> 102 assertions. New V4.6 section: 50
  productive sets in a single in-game day all queue with the default cap
  (nothing blocked by a count, counter still increments); a configured cap
  > 0 still refuses the set at the ceiling with the "resting (daily set
  cap reached)" status and releases again when the ceiling is raised; with
  no cap an unproductive exercise still halts training with "resting
  (exercises fatigued)" and still recovers after the fatigue window
  (proving the new primary limiter was not broken); `getExerciseStatus`
  reports honestly in both modes. The V4.5 section now pins the cap to 0
  instead of 100. Total Lua assertions 460 -> 479; luacheck stays 0
  warnings / 0 errors across 18 modules; no telemetry schema change.

## [V4.4] - 2026-07-19 - ON-SCREEN ACTION/INTENTION DISPLAY

User-requested after the V4.3 smoke test: a way to see what the mod is
currently doing (or why it is doing nothing) without opening the F11 panel.

### Added - read-only HUD line

- `AutoPilot_Main.lua` gains a second halo-text line, `Action: <label>`,
  drawn every evaluation cycle right under the existing status line
  (same `HaloTextHelper.addText` mechanism, font, and once-per-cycle
  cadence). It is emitted right AFTER the per-cycle evaluation (not from
  inside it) specifically so the label reflects THIS cycle's decision
  instead of the previous one.
- Sourced entirely from state the mod already tracks for other purposes:
  the queue-thrash guard's `_lastActionLabel`, `player:isDead()` /
  `isAsleep()` (already queried elsewhere in the same cycle), and, for
  exercise, `AutoPilot_Needs.getExerciseStatus()` (the same read the F11
  panel already performs, itself backed by the V4.5 ownership registry).
  No new decision data, no mutation: `AutoPilot.getActionIntention()` is a
  pure read, per the V4.5 player-agency guarantee that presentation must
  never gate or influence a decision.
- While armed: shows the current mod-queued action (e.g. "Training:
  barbellcurl", "Eating", "Fighting/fleeing zombies") or "Idle,
  evaluating" when nothing is queued.
- While disarmed: shows "Disarmed (no monitoring)". This intentionally
  does NOT claim a fail-safe is "active" while off: `_tickForPlayer`
  returns immediately when `_mode == "off"`, right after the status line,
  so no survival check of any kind runs until the player arms the mod; the
  display says so rather than implying otherwise.

### Added - Options toggle

- Options > Mods > AutoPilot Leveler > Display gains "Show current action
  on HUD" (0 off, 1 on; default on, since this directly answers the
  feature request). Lands in the live-read `AutoPilot_Constants.
  HUD_SHOW_ACTION`, same pattern as the V4.3 training-program selector.
  `addCheckBox` is not in the verified 42.19 record, so this reuses the
  already-verified `addSlider` surface as a 0/1 toggle.

### Testing

- `test_main_logic`: 37 -> 48 assertions. New V4.4 section covers: armed
  idle shows "Idle, evaluating"; armed with a mod-queued exercise decision
  shows the enriched, capitalized trainer status; disarmed shows the
  accurate no-monitoring label; `getActionIntention` is a pure read
  (repeated calls are stable and never touch mode, telemetry, or the
  action queue); and the Options toggle hides the line while leaving the
  status line untouched. Suite gains a `HaloTextHelper` mock (matches the
  signature Main.lua already relies on) plus `AutoPilot_Telemetry.
  getPendingAction` / `AutoPilot_Needs.getExerciseStatus` stubs (both real,
  already-relied-upon production signatures that were simply unstubbed
  until now). Total Lua assertions 449 -> 460; luacheck stays 0
  warnings / 0 errors across 18 modules; no telemetry schema change.

## [V4.5] - 2026-07-19 - NEVER TOUCH PLAYER ACTIONS + F10 PANIC STOP

Fixes the user-reported lockup "when manually initiating exercise, I can't
cancel or do anything else even with autopilot toggled off". Root cause in
the shipped code: while ARMED, the urgent-need interrupt and the
queue-thrash guard cleared ANY running exercise with no identity check
(manual ones included), and the trainer re-queued a new set ~0.75 s after
any cancel, bulldozing player intent; a vanilla 42.19 fitness-UI
input-capture quirk can compound the stuck feeling. Three guarantees ship
(see docs/architecture.md, "Player-Intervention Guarantees"):

### Fixed - the mod never touches player-initiated actions

- New mod-action ownership registry in `AutoPilot_Utils` (weak-keyed:
  entries self-clean via GC, and a Lua reload starts empty so pre-reload
  actions read as foreign, the safe direction). EVERY mod queue site
  (Needs, Inventory, Medical, Threat, Barricade) now tags its actions via
  `queueModAction`/`tagModAction`.
- The urgent-need exercise interrupt and the queue-thrash clear in Main now
  verify `Utils.isModAction` first: a FOREIGN running action (player-
  initiated, another mod, or a vanilla internal queue) is never cleared,
  never interrupted, and never accumulates a thrash streak. Its busy
  cycles log `busy`/`foreign_action` (new reason string only; no schema
  change, no new action label, so the benchmark class map is untouched).
- The fight-or-flee threat response is the one deliberate exception and
  still clears the queue when zombies actually engage (fail-safe priority:
  the character's life outranks any exercise set).

### Added - armed training backs off after manual intervention

- A mod-queued set that vanishes from the queue well short of a full set
  without a mod-initiated clear is treated as a player cancel: training
  yields for `EXERCISE_BACKOFF_MINUTES` game minutes (new constant,
  default 10; Options slider "Training backoff after manual cancel", 0 to
  60 in steps of 5, 0 disables) instead of re-queuing ~0.75 s later.
- A FOREIGN exercise observed running refreshes the same hold every cycle,
  so training stays away while, and one window after, the player exercises
  manually. Mod-initiated clears (urgent need, threat, thrash) consume the
  pending record via `Needs.noteModExerciseCleared` and never back off.
- A cancelled set is no longer judged by the XP-fatigue detector (it never
  ran to length), and a pending set from a dead character is discarded
  (who-guard, same pattern as the XP snapshot guard).

### Added - F10 panic stop

- Pressing F10 while ANY exercise is running (mod-queued or manual, armed
  or disarmed) clears that exercise on the keypress, in addition to the
  normal arm/disarm toggle, and starts the backoff window. This is the
  guaranteed escape hatch even when the lockup is vanilla fitness-UI input
  capture rather than anything the mod did.

### Tests

- test_main_logic: 13 -> 37 assertions (foreign exercise + urgent need not
  cleared; disarmed cycle untouchable; thrash guard ignores foreign and
  still clears stuck mod actions; F10 panic stop mod/manual/armed/disarmed
  plus plain-toggle regression; threat consumes the pending record).
- test_priority_logic: 55 -> 83 assertions (backoff engage/hold/release;
  mod-initiated clears do not back off; panic-stop and foreign-exercise
  holds; tag lifecycle including untag-on-resolution, reload reset, and
  the cross-character who-guard; backoff 0 disables).
- Suites now load the real `AutoPilot_Utils` (square scans no-op'd) so the
  ownership registry under test is the production one. Total Lua
  assertions 397 -> 449; luacheck clean; no telemetry schema change.

## [V4.3] - 2026-07-19 - CONFIGURABLE TRAINING PROGRAMS

Implements approved V4.0 expansion candidate C3
(docs/EXPANSION_PROPOSAL_V4.md): weekly training programs with rest days.
A pure scheduler on top of the existing focus plumbing; zero new action
types and zero new engine APIs (the weekday derives from the verified
getGameTime():getCalender():getTimeInMillis() surface, and no day-of-week
calendar API is called because none is in the verified record).

### Added - weekly training programs (Leveler scheduler)

- `AutoPilot_Leveler.PROGRAMS`: five presets mapping the in-game weekday
  (Sun..Sat) to a day focus. Balanced (default: auto every day, identical
  to pre-V4.3 behavior), Strength emphasis (5 STR / 2 FIT days), Fitness
  emphasis (5 FIT / 2 STR), Alternating days, and Rest-day split
  (alternating STR/FIT with Sunday off).
- Day semantics: an "auto" day defers to the F11 focus selection (the
  existing behavior), a "strength"/"fitness" day overrides the selection
  for that day, and a "rest" day makes the exercise slot yield so the
  survival chores own the cycle (no training that day).
- V3.2 starvation guard by construction: the scheduler only refines the
  exercise slot's own focus-or-rest decision. It never reorders the
  priority chain, survival needs still win every cycle, rest days fall
  through to the chores exactly like the endurance gates do, and only the
  opt-in Rest-day split contains any rest day at all (the compiled-in
  default can never idle the trainer).
- Weekday resolution is pcall-guarded: when the calendar is unavailable it
  falls back to "auto", i.e. the always-on focus behavior, so the
  scheduler can only ever narrow the slot's decision, never break it.
- F11 panel: a program day line pre-formatted by
  `Leveler.getProgramStatus` ("today: STR day (program: Strength
  emphasis)"); rest days read "today: rest day (program: Rest-day split),
  survival chores only".

### Added - Options selector

- Options > Mods > AutoPilot Leveler gains a "Training program" selector.
  The pick is mapped to a program id and written to the new live-read
  `AutoPilot_Constants.TRAINING_PROGRAM` (the V3.3 pattern: the Leveler
  reads it at every exercise slot, so options-save applies on the next
  cycle; unknown values validate to "balanced").
- Placement per the proposal: the program table and ALL day-resolution
  logic live in `AutoPilot_Leveler` (pure, unit-tested), NOT in Options,
  preserving the mock's documented no-suite-loads-Options gap. Options
  only registers the control: addComboBox is not in the verified 42.19
  record, so it is existence-checked inside its own pcall with a slider
  over the 1-based program indices (verified surface) as the fallback;
  the widget itself stays playtest-only like every control on the page.

### Testing

- Suite: 10 Lua files, 397 assertions (was 320), all green: eight new
  V4.3 sections in `tests/test_leveler_metrics.lua` (+77 assertions)
  cover program-table completeness (7-day coverage, valid day values,
  stable Options index order, rest days confined to the opt-in preset,
  the 5/2 emphasis ratios), weekday derivation from the mock calendar,
  a 14-day resolution sweep per preset, rest-day yield (trainExercise
  never called, metrics still sampled, same-day balanced control case),
  program-over-selection focus mapping with auto-day deferral,
  calendar-absent fallback to the always-on behavior, live-read program
  selection (mid-session constant writes change the next cycle; unknown
  and missing ids validate to balanced), and the panel status lines.
  No new mock surface: the scheduler rides the already-mocked
  getTimeInMillis clock (MockTime), and the mock header records the V4.3
  weekday derivation plus the ModOptions-gap extension. luacheck stays
  0 warnings / 0 errors across 18 modules; run-log schema and
  triage_run_log.py untouched.

## [V4.2] - 2026-07-19 - F11 SESSION HISTORY AND TRENDS

Implements approved V4.0 expansion candidate C5
(docs/EXPANSION_PROPOSAL_V4.md): a longitudinal view of the grind. No new
engine APIs; everything rides the verified getFileWriter/getFileReader
surfaces already used by the run log and death log.

### Added - session summaries (data layer)

- New module `AutoPilot_SessionHistory` (loads before Telemetry
  alphabetically; registers no events): persists one compact key=value
  summary line per session to `~/Zomboid/Lua/auto_pilot_sessions.log` with
  ticks, STR/FIT/Woodwork/Doctor start/end levels, and the end reason
  (dead/timeout), reusing triage_run_log.py's per-session field
  conventions.
- Written at session end via the existing Telemetry.onDeath/onShutdown
  hooks (idempotent: a shutdown after a death changes nothing) and
  refreshed by an `ended=open` checkpoint line every
  SESSION_HISTORY_CHECKPOINT_CYCLES (400) evaluation cycles, so a crash
  still leaves a recent summary. At read time the latest line per session
  id wins.
- File format: versioned header line (`# auto_pilot_sessions schema=1`),
  additive-only fields, tolerant parser (comment/malformed lines and
  missing or unknown fields never abort a read). Bounded by design: once
  per session the file is collapsed to one line per session and only the
  newest SESSION_HISTORY_KEEP (30) summaries survive (the run-log rotation
  pattern; the collapse rewrite is the module's only non-append write).
- A death followed by a respawn in the same Lua state closes the old
  session and opens the next id.

### Added - F11 history block

- The panel gains a "Session history" block: the last
  SESSION_HISTORY_PANEL_ROWS (5) sessions, newest first, each row showing
  session number, ticks, per-perk level deltas, and end reason
  (`#3  812t  S+1 F+0 W+2 D+0  dead`), plus a trend sparkline of total
  level gains across the retained sessions (oldest to newest).
- The UI stays thin: every string is pre-formatted by
  AutoPilot_SessionHistory.getPanelLines, so all logic sits in the
  unit-tested data layer and the documented UI coverage gap does not
  widen.

### Testing

- Suite: 10 Lua files, 320 assertions (was 225), all green: new
  `tests/test_session_history.lua` (95 assertions) covers write/parse
  round-trips, checkpoint cadence and collapse, rotation/retention, parser
  tolerance, delta computation, panel formatting, the trend sparkline, and
  the Telemetry integration, asserting append-vs-truncate discipline
  through the mock's counting getFileWriter. No new mock surface (the
  writer/reader were already assertion-bearing); the mock header records
  the V4.2 callsites. Run-log schema is untouched (summaries are a
  separate file), so `triage_run_log.py` and its 45 pytest tests are
  unchanged. luacheck stays 0 warnings / 0 errors across 18 modules.

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
