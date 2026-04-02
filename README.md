# AutoPilot for Project Zomboid Build 42

AutoPilot is a client-side AFK survivor/trainer mod.
It keeps your character alive and leveling while you step away.

Status: V1.0 code complete. Steam Workshop upload pending.

See WORKSHOP.md for the Workshop description and TESTING.md for the pre-release checklist.

## Who This README Is For

This guide is for a technical user who wants to:
- Install and run the mod quickly
- Edit behavior in Lua
- Run checks/tests before pushing changes

## What AutoPilot Does

- Survival: hunger, thirst, fatigue, wounds, boredom
- Combat: fight/flee logic based on local risk
- Progression: Strength/Fitness exercise selection and scheduling
- Resource loop: nearby looting, depletion tracking, supply runs
- Home safety: home bounds + one-time barricade attempt

Control keys:
- F10: toggle AutoPilot on/off
- Home anchor: auto-set when AutoPilot is first enabled

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

- 42/media/lua/client/: active Build 42 source of truth
- media/lua/client/: legacy mirror copy used by some local workflows
- tests/: Lua and Python tests
- check.sh: lint + API guard + Lua tests + pytest
- deploy.sh: copy 42/ into live PZ mod folder
- sync_after_merge.bat: fetch/ff and optional deploy on Windows

## Core Runtime Modules

- AutoPilot_Main.lua: OnTick loop, mode toggle, HUD/status
- AutoPilot_Needs.lua: priority state machine for actions
- AutoPilot_Threat.lua: zombie detection and fight/flee
- AutoPilot_Inventory.lua: food/drink/loot/equipment helpers
- AutoPilot_Medical.lua: wound detection and treatment
- AutoPilot_Home.lua: home anchor persistence and bounds logic
- AutoPilot_Barricade.lua: one-time barricade queue
- AutoPilot_Map.lua: depleted-square tracking
- AutoPilot_Actions.lua: timed-action wrappers
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

- Current modversion: 1.0 (root mod.info and 42/mod.info)
- Major release label style: V1.0
- Workshop publish assets/checklist live in WORKSHOP.md and TESTING.md

## Contributing

1. Create a branch
2. Keep changes in 42/media/lua/client/ focused and testable
3. Run bash check.sh
4. Open a PR with behavior notes and test evidence

If your change modifies gameplay logic, include:
- Expected trigger conditions
- Expected queued action(s)
- Log snippets showing behavior
