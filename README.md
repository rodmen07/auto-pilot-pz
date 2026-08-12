# AutoPilot Leveler for Project Zomboid Build 42

Auto-exercise leveler with a survival fail-safe. Reach a stable spot, press
F10, and your character grinds Strength/Fitness while you step away.

Status: ACTIVE — Build 42.19.0 Unstable. **Distributed through GitHub Releases only.**

The Steam Workshop item (3767254910) was delisted on 2026-07-21 and, by owner decision on
2026-08-10, **stays delisted permanently** — the listing is deliberately retired, not awaiting
a relist. Do not wait for a Workshop update: releases here are the whole channel. The reasoning
is recorded in `docs/WORKSHOP_RELIST_DECISION.md`.

> **Note on this file's history:** between 2026-07-21 and 2026-08-08 this README opened with a
> banner headed *"⚠️ DEPRECATED — NO LONGER MAINTAINED"*, stating that the project *"was
> decommissioned on 2026-07-21 and is no longer developed, supported, or published"*, that the
> Workshop item had been delisted, and that *"no further releases, bug fixes, or compatibility
> updates will be made."* **Every clause of that is false.** The decommission was reversed on
> 2026-07-24, four days after it was written, and development has been continuous since: `v0.2.0`
> was released 2026-08-05 and `v0.2.1` on 2026-08-08. The banner is removed rather than quoted
> in full because, unlike `ROADMAP.md` and the backlogs, this file is read by people deciding
> whether to install the mod, and a superseded warning left in place still warns. The full
> original text is preserved in this file's git history and in the pull request that removed it.

See MULTIPLAYER.md for server setup and TESTING.md for the pre-release
checklist. WORKSHOP.md holds the Workshop description and is kept as a
record of the retired listing, not as a step anyone still performs.

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
  version of the code that is actually loaded, so a stale Workshop copy on a
  server is visible at a glance
- Survival fail-safe: hunger, thirst, sleep, wounds, temperature; and a
  FLEE-ONLY threat response when zombies actually engage (chasing/visible/close).
  The mod does NOT fight: Build 42 gives an AI-driven character no way to swing a
  weapon, so combat is not viable for automation. It runs away from the threat
  instead, and holds position only when no escape square is reachable.
- Player control guarantees (V4.5): the mod only ever interrupts or clears
  actions it queued itself; anything you start manually (like an exercise
  from the fitness UI) is never touched, armed or disarmed. If you cancel a
  set or exercise manually while armed, training backs off (default 10 game
  minutes, "Training backoff after manual cancel" slider, 0 disables)
  instead of instantly re-queuing. The fail-safe stays always-on while
  armed, but it can only act on the mod's own actions; the one exception is
  the flee response, which still clears the queue when zombies actually engage.
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
- `tests/` — Lua and Python tests
- `check.sh` — lint + API guard + Lua tests + pytest
- `deploy.sh` — copy `42/` into live PZ mod folder
- `sync_after_merge.bat` — fetch/ff and optional deploy on Windows

## Core Runtime Modules (24 under `42/media/lua/client/`)

This roster is a guarded claim, not prose: `tests/test_readme_truth.py` reads the count above
and every module named below, globs `42/media/lua/client/*.lua`, and fails the build if the two
disagree in either direction. Extracting or deleting a module means editing this section in the
same commit.

Leveler:
- AutoPilot_Main.lua: orchestrator for the local player (eval loop, F10 arm/disarm, HUD/status)
- AutoPilot_Leveler.lua: training focus selection (Auto/Strength/Fitness) with ModData persistence
- AutoPilot_Exercise.lua: the trainer — exercise selection, XP-productivity fatigue tracking, manual-cancel backoff, daily set counter
- AutoPilot_XP.lua: XP metrics engine (session gain, XP/hour, ETA to next level)
- AutoPilot_UI.lua: F11 leveler panel (focus, live metrics, trainer status, arm/disarm button)
- AutoPilot_Options.lua: PZAPI.ModOptions sliders and rebindable keys
- AutoPilot_SessionHistory.lua: session history data layer behind the panel's history block

Survival fail-safe:
- AutoPilot_Needs.lua: priority state machine for survival needs and idle behaviour
- AutoPilot_Threat.lua: zombie detection and flee-only threat response
- AutoPilot_Consumption.lua: eat and drink behaviour
- AutoPilot_Sleep.lua: sleep behaviour and bed-finding
- AutoPilot_Rest.lua: rest-in-place (furniture or ground, never sleep) and seating classification
- AutoPilot_Medical.lua: wound detection and treatment
- AutoPilot_Mood.lua: boredom and unhappiness relief (read, media, go outside)
- AutoPilot_Media.lua: boredom and unhappiness relief from a switched-on television or radio
- AutoPilot_Comfort.lua: physical-comfort upkeep — drying off with a towel (the Wet moodle)
- AutoPilot_Inventory.lua: food/drink/loot/equipment helpers
- AutoPilot_Home.lua: home anchor persistence and bounds logic
- AutoPilot_Map.lua: visited-building and depleted-container tracking

Learning and infrastructure:
- AutoPilot_DeathLog.lua: death context snapshots plus a recent-decision ring buffer
- AutoPilot_Adaptive.lua: bounded threshold self-tuning from the death log
- AutoPilot_Telemetry.lua: per-tick run log writer with session-start rotation
- AutoPilot_Constants.lua: tunable thresholds and constants
- AutoPilot_Utils.lua: safe wrappers and search helpers

## Priority Model (High to Low)

The chain `AutoPilot_Needs.check()` walks, highest first.  This list is bound to
the code's real branch order by `tests/test_priority_chain_truth.py`, which
derives the chain from `check()`'s own decision calls with comments stripped —
so a comment cannot satisfy it, and a step the code does not walk fails it:

1. Bleeding — bandage immediately
2. Tired — sleep; sits above every need but bleeding so a long rest can hand
   off to sleep, and when the engine refuses sleep (pain, panic) the chain
   falls through to the needs below instead of idling
3. Thirst — drink from a tap or sink, then inventory, then loot
4. Shelter — get indoors when outside in rain or dangerous cold
5. Hunger — eat
6. Wounds — treat non-bleeding wounds (scratches, bites)
7. Clothing — adjust layers for temperature
8. Exhausted — rest when endurance is critically low, and hold an in-progress
   rest (seated reading or snacking allowed) until endurance recovers
9. Wet — dry off with a towel
10. Bored or sad — tasty food, then reading, then a tv/radio, then going outside.
    The Stress moodle enters this step too, and it unlocks the reading arm only:
    literature is where the game declares stress relief (259 of the 301 vanilla
    entries with a negative `StressChange`), while a television only relieves
    stress when the broadcast happens to carry it
11. Winded — sit to recover endurance rather than stand idle
12. Idle — exercise, the mod's primary purpose (strength/fitness alternating by level)
13. Scavenge — proactive supply top-up, the background chore that runs when
    nothing else claimed the cycle

## Technical Constraints (Important)

Project Zomboid Lua (Kahlua) is sandboxed:
- No HTTP/socket access
- No arbitrary Java class loading
- File I/O only through game-safe APIs

So AutoPilot is fully local and rule-based by design.

### The one moodle AutoPilot leaves to you: Uncomfortable

Build 42.19 gives Lua no action that lowers Discomfort. Every other moodle on
the list AutoPilot was built to cover has one — sleep, food, water, a towel,
a book, a radio — but Discomfort has none, so the mod does not pretend to
manage it.

That is not the same as "nothing can be done about it". Discomfort comes from
**what you wear and carry**: 344 vanilla clothing and bag entries declare a
`DiscomfortModifier`, from `0.02` on a kneepad to `0.75` on an NBC mask, and
your sandbox Discomfort Factor scales all of it (`0.7` on Outbreak, `0.8` on
Apocalypse, `1.0` on Extinction). Riding a vehicle over-encumbered adds more.
If your character is permanently uncomfortable, the fix is the loadout, not
the mod.

There is one indirect assist: discomfort feeds **Stress**, and AutoPilot does
manage stress — it will sit your character down with a book. So the mod treats
the symptom while the cure stays in your hands.

## Versioning and Release Notes

- Current modversion: 0.2.1 (root mod.info and 42/mod.info, which must always match)
- Release tags are semver `vX.Y.Z`. The pre-2026-07-25 scheme labelled releases `V5.8`-style;
  it was reset to `0.1.0` by owner decision and those old labels survive only in `CHANGELOG.md`
  and `ROADMAP.md` as history.
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
source tree), press F11: the panel title reads `AutoPilot Leveler  v` followed
by the "Current modversion" above — that string comes from
`AutoPilot_Constants.VERSION`, which is the version compiled into the code the
game actually loaded. Compare it against the version stated in the Workshop
description. They diverging is exactly the cache mismatch this reporting
exists to expose. (No literal version number is repeated here on purpose: this
paragraph carried a stale `v5.1` for months, and one guarded home for the
version is the point of the checklist above.)

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
STR/FIT level deltas. A final "Suspicious patterns" section flags action
streaks not explained by an expected persistent state (sleeping, a
player-owned action, armed idle), repeated flee/combat cycles, and
empty-loot scavenge spirals, each with a one-line hint; a clean log prints
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
