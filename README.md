# AutoPilot Leveler for Project Zomboid Build 42

Auto-exercise leveler with a survival fail-safe. Reach a stable spot, press
F10, and your character grinds Strength/Fitness while you step away.

Status: V3.3 — Build 42.19.0 Unstable. Steam Workshop ID 3767254910.

See WORKSHOP.md for the Workshop description, MULTIPLAYER.md for server
setup, and TESTING.md for the pre-release checklist.

## Who This README Is For

This guide is for a technical user who wants to:
- Install and run the mod quickly
- Edit behavior in Lua
- Run checks/tests before pushing changes

## What AutoPilot Leveler Does

- Training: focus-based exercise (Auto and Strength=equipment lifts when a
  dumbbell/barbell is carried, else burpees (Auto) or push-ups (Strength),
  Fitness=squats with sit-up fallback), XP-fatigue detection with rotation
  and rest
- Metrics: F11 panel with level, XP-to-next, session gain, XP/hour, ETA,
  live trainer status, and sets-per-day counter; the panel title reports the
  loaded mod version (V5.3), so a stale Workshop copy on a server is visible
  at a glance
- Survival fail-safe: hunger, thirst, sleep, wounds, temperature; fight/flee
  only when zombies actually engage (chasing/visible/close)
- Player control guarantees (V4.5): the mod only ever interrupts or clears
  actions it queued itself; anything you start manually (like an exercise
  from the fitness UI) is never touched, armed or disarmed. If you cancel a
  set or exercise manually while armed, training backs off (default 10 game
  minutes, "Training backoff after manual cancel" slider, 0 disables)
  instead of instantly re-queuing. The fail-safe stays always-on while
  armed, but it can only act on the mod's own actions; the one exception is
  fight/flee, which still clears the queue when zombies actually engage.
- Death learning: context snapshots on death + bounded threshold self-tuning
- Configurable: sliders and rebindable keys under Options > Mods, listed as
  "AutoPilot Leveler". V5.5 fixed the registration bug that made this page
  fail to appear at all on some clients; if it is still missing, the F11
  panel now says "mod options unavailable (using defaults)" and a `#` line
  naming `PZAPI.ModOptions` is appended to `~/Zomboid/Lua/auto_pilot_run.log`,
  so a missing page is visible instead of silent.
- Off by default; splitscreen not supported; MP-safe (client-side only)

Control keys (rebindable in mod options):
- F10: arm/disarm (home anchor is set where you stand when first armed).
  V4.5: F10 is also a panic stop: if ANY exercise is running (yours or the
  mod's), pressing it stops that exercise on the spot, in addition to
  toggling. Use it if an exercise ever refuses to cancel.
- F11: leveler panel

## Install and Run (Fast Path)

1. Clone this repo into your live mods directory:

```bash
git clone https://github.com/rodmen07/auto-pilot-pz.git "$HOME/Zomboid/mods/auto_pilot"
```

2. Start Project Zomboid (Build 42), enable AutoPilot in Mods.
3. Load a save and press F10.
4. Watch console output for lines starting with [AutoPilot].

Windows console launcher: ProjectZomboid64ShowConsole.bat

## Dev Install (Repo Outside Game Folder)

If you keep this repo outside $HOME/Zomboid/mods/auto_pilot, deploy into the live mod path:

```bash
bash deploy.sh
```

If cloud/PR changes were merged and you want to sync locally on Windows:

```bat
sync_after_merge.bat
```

## Edit -> Test -> Iterate Loop

Recommended inner loop:

1. Edit Lua under 42/media/lua/client/
2. Run checks:

```bash
bash check.sh
```

3. Run focused tests when needed:

```bash
lua tests/test_priority_logic.lua
python -m pytest tests/test_game_logs.py -v
```

4. Launch game, toggle F10, validate behavior in console and in-world.

## Project Layout (What To Edit)

- `42/media/lua/client/` — **active Build 42 source of truth** (edit only this tree)
- `media/lua/client/` — **deprecated legacy mirror** (do not edit; kept as reference only)
- `tests/` — Lua and Python tests
- `check.sh` — lint + API guard + Lua tests + pytest
- `deploy.sh` — copy `42/` into live PZ mod folder
- `sync_after_merge.bat` — fetch/ff and optional deploy on Windows

## Core Runtime Modules (17 under 42/media/lua/client/)

Leveler:
- AutoPilot_Main.lua: orchestrator for the local player (eval loop, F10 arm/disarm, HUD/status)
- AutoPilot_Leveler.lua: training focus selection (Auto/Strength/Fitness) with ModData persistence
- AutoPilot_XP.lua: XP metrics engine (session gain, XP/hour, ETA to next level)
- AutoPilot_UI.lua: F11 leveler panel (focus, live metrics, trainer status, arm/disarm button)
- AutoPilot_Options.lua: PZAPI.ModOptions sliders and rebindable keys

Survival fail-safe:
- AutoPilot_Needs.lua: priority state machine for survival needs and exercise
- AutoPilot_Threat.lua: zombie detection and fight/flee
- AutoPilot_Inventory.lua: food/drink/loot/equipment helpers
- AutoPilot_Medical.lua: wound detection and treatment
- AutoPilot_Home.lua: home anchor persistence and bounds logic
- AutoPilot_Map.lua: depleted-square tracking

Learning and infrastructure:
- AutoPilot_DeathLog.lua: death context snapshots plus a recent-decision ring buffer
- AutoPilot_Adaptive.lua: bounded threshold self-tuning from the death log
- AutoPilot_Telemetry.lua: per-tick run log writer with session-start rotation
- AutoPilot_Constants.lua: tunable thresholds and constants
- AutoPilot_Utils.lua: safe wrappers and search helpers

## Priority Model (High to Low)

1. Bleeding
2. Thirst
3. Hunger
4. Non-bleeding wounds
5. Exhaustion/rest
6. Sleep
7. Boredom
8. Exercise

## Technical Constraints (Important)

Project Zomboid Lua (Kahlua) is sandboxed:
- No HTTP/socket access
- No arbitrary Java class loading
- File I/O only through game-safe APIs

So AutoPilot is fully local and rule-based by design.

## Versioning and Release Notes

- Current modversion: 5.3 (root mod.info and 42/mod.info, which must always match)
- Major release label style: V5.3
- Workshop publish assets/checklist live in WORKSHOP.md and TESTING.md

The version is stated in four places and `tests/test_version_sync.py` fails
the build unless all four agree. A release commit must change them together:

1. `mod.info` -> `modversion=X`
2. `42/mod.info` -> `modversion=X`
3. `42/media/lua/client/AutoPilot_Constants.lua` -> `AutoPilot_Constants.VERSION = "X"`
4. this README -> the "Current modversion:" line above

`sync_workshop.sh` reads `modversion` out of `mod.info` at run time and
rewrites the Workshop description's version line in place, so it needs no
edit. The reason the Lua constant is compiled in rather than read from
`mod.info` at runtime: Kahlua is sandboxed and the mod has no verified 42.19
API for reading its own mod metadata.

To check which build is actually loaded in a game (including on a server,
where the client runs the Steam-downloaded Workshop copy rather than your
source tree), press F11: the panel title reads `AutoPilot Leveler  v5.1`.
Compare it against the version stated in the Workshop description. They
diverging is exactly the cache mismatch this reporting exists to expose.

## Telemetry

AutoPilot writes structured telemetry to `~/Zomboid/Lua/` while running:

- `auto_pilot_run.log`: per-tick CSV for the local player
- `auto_pilot_run_end.json`: run-end marker (status: dead or timeout)
- `auto_pilot_deaths.log`: one context snapshot line per death (death learning)

Each log line records: player, action, reason, stat levels (hunger/thirst/fatigue/
endurance), zombie count, bleeding count, and Strength/Fitness levels.

To analyse a run offline:

```bash
python benchmark.py
```

Delete the log files between benchmark sessions to get clean per-run data.
Since V3.3 the run log rotates automatically: once per session, if it exceeds
20,000 lines the oldest lines are dropped and only the newest 5,000 are kept
(TELEMETRY_MAX_LINES / TELEMETRY_KEEP_LINES in AutoPilot_Constants.lua).

### Run-log triage

To turn a long run log into a quick health check:

```bash
python triage_run_log.py
```

It reads `~/Zomboid/Lua/auto_pilot_run.log` by default (pass a path to triage
another file) and prints: action mix, top action transitions, a
training/resting/survival/idle time split, threat events, and per-session
STR/FIT level deltas. A final "Suspicious patterns" section flags long
single-action streaks, zero-XP training loops, repeated flee/combat cycles,
and empty-loot scavenge spirals, each with a one-line hint; a clean log prints
"none detected". The heuristics are deliberately conservative (triage, not
diagnosis). Read-only, stdlib-only; thresholds are constants at the top of
the script.

Full guide: [docs/triage.md](docs/triage.md) (schema reference, report
walkthrough, the suspicious-pattern catalog including signatures the tool
does not auto-detect, and the fixture workflow for adding new detectors).

## Contributing

1. Create a branch
2. Keep changes in 42/media/lua/client/ focused and testable
3. Run bash check.sh
4. Open a PR with behavior notes and test evidence

If your change modifies gameplay logic, include:
- Expected trigger conditions
- Expected queued action(s)
- Log snippets showing behavior
