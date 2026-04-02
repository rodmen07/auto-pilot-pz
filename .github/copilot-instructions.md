# Project Overview
AutoPilot is an AFK auto-leveler mod for Project Zomboid Build 42. It handles survival needs (hunger, thirst, sleep, exhaustion, wounds, boredom) while exercising to level Strength and Fitness.

# Architecture
The mod uses a **single local Lua brain**:
1. **Rule-based Lua brain**: Located in `42/media/lua/client/`. This is the core logic that runs natively within Project Zomboid.

### Constraints
- Project Zomboid's Lua environment (Kahlua) is network-isolated. No HTTP or socket access.


# Core Modules
- `AutoPilot_Main.lua`: Orchestrator (OnTick loop, F7 toggle).
- `AutoPilot_Needs.lua`: Priority-based survival state machine.
- `AutoPilot_Threat.lua`: Zombie detection and fight/flee logic.
- `AutoPilot_Inventory.lua`: Item scanning and looting.
- `AutoPilot_Medical.lua`: Wound detection and auto-bandage.

# Technical Guidelines
- **API**: Use direct Build 42 getters (`getHunger()`, `getThirst()`).
- **Medical**: Use body part methods like `bleeding()`, `scratched()`, `deepWounded()`.
- **Safety**: Wrap PZ API calls in `pcall` to prevent crashes during game updates.


# Status
Current version: V1.0 (Public Release).
