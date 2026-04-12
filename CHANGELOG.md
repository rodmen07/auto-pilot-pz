# Changelog

All notable changes to AutoPilot are documented here.

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
