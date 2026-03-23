# Project Overview
AutoPilot is an AFK auto-leveler mod for Project Zomboid Build 42. It handles survival needs (hunger, thirst, sleep, exhaustion, wounds, boredom) while exercising to level Strength and Fitness.

# Architecture
The mod uses a **dual-brain design**:
1. **Rule-based Lua brain (Primary)**: Located in `42/media/lua/client/`. This is the core logic that runs natively within Project Zomboid.
2. **Claude LLM brain (Optional Sidecar)**: `auto_pilot_sidecar.py` polls game state and uses Claude to provide high-level commands.

### Constraints
- Project Zomboid's Lua environment (Kahlua) is network-isolated. No HTTP or socket access.
- All external communication MUST happen via file IPC (`auto_pilot_state.json` and `auto_pilot_cmd.json`) in the Zomboid Lua sandbox directory.

# Core Modules
- `AutoPilot_Main.lua`: Orchestrator (OnTick loop, F7 toggle).
- `AutoPilot_Needs.lua`: Priority-based survival state machine.
- `AutoPilot_Threat.lua`: Zombie detection and fight/flee logic.
- `AutoPilot_Inventory.lua`: Item scanning and looting.
- `AutoPilot_Medical.lua`: Wound detection and auto-bandage.
- `AutoPilot_LLM.lua`: File-based IPC handling.

# Technical Guidelines
- **API**: Use direct Build 42 getters (`getHunger()`, `getThirst()`).
- **Medical**: Use body part methods like `bleeding()`, `scratched()`, `deepWounded()`.
- **Safety**: Wrap PZ API calls in `pcall` to prevent crashes during game updates.
- **IPC**: State is written to `auto_pilot_state.json`; commands are read from `auto_pilot_cmd.json`.

# Status
Current version: V1.0 (Public Release).
