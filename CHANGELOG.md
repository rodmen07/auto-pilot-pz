# Changelog

All notable changes to AutoPilot are documented here.

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
