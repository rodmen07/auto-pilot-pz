# AutoPilot Architecture — v2.0

## Overview

AutoPilot is a single-file, in-process Lua mod for Project Zomboid Build 42.
All decision logic runs natively inside the game engine (Kahlua/Lua 5.1).
No sidecar process, no HTTP, no external state is required at runtime.

---

## Module Ownership Map

Each module owns a specific slice of global state.  Cross-module reads are
allowed; cross-module **writes** are not (the owner is responsible for all
mutations to its own tables).

| Module | Owns / writes | Reads from |
|---|---|---|
| `AutoPilot_Constants` | All named constants | — |
| `AutoPilot_Map` | `_depletedSquares[playerNum]` | Constants |
| `AutoPilot_Home` | `homes[playerNum]`, `homeFallbacks[playerNum]` | Constants, Utils |
| `AutoPilot_Telemetry` | `_runTick[pnum]`, `_pending*[pnum]`, log files | Utils, Threat, Medical |
| `AutoPilot_Threat` | `_fleeRetries[playerNum]` | Constants, Medical, Inventory, Home, Utils |
| `AutoPilot_Inventory` | `_lastSearchResults[playerNum]` | Constants, Map, Home, Utils |
| `AutoPilot_Medical` | (stateless — reads PZ body-damage API) | Constants, Inventory, Utils |
| `AutoPilot_Needs` | `_exerciseSetsToday[pnum]`, `_emptyFoodLootCycles[pnum]`, `_recoverUntilMs[pnum]` | All above |
| `AutoPilot_Barricade` | ModData keys on the player object | Constants, Home, Utils |
| `AutoPilot_Actions` | (stateless) | Needs, Inventory, Medical, Home |
| `AutoPilot_Main` | `_playerModes[pnum]`, `_playerCooldowns[pnum]`, `_lastActionLabel[pnum]`, `_actionStreak[pnum]` | All above |

> **Rule:** a module may only call `write` methods on another module's state
> through that module's public API — never by indexing the internal table
> directly.

---

## Splitscreen Safety

All per-player state tables are keyed by `playerNum` (0-based integer from
`player:getPlayerNum()`).  The key is resolved once per decision cycle via a
`pcall`-wrapped `_pn()` helper that falls back to `0` for API errors.

`AutoPilot_Map._depletedSquares` was the last module-level (singleton) table;
it is now `[playerNum]`-keyed and all callers pass `pnum` explicitly.

---

## Priority Chain (Needs.check)

Decision priority is evaluated top-to-bottom on each tick.  The first
`true`-returning handler wins and sets the action cooldown.

```
P0  medical (bleeding) ─── bandage immediately
P1  recover            ─── post-combat rest/bandage window
P2  sleep              ─── fatigue ≥ threshold
    [rest cooldown]    ─── suppress routine needs while resting
P3  thirst             ─── thirst ≥ threshold
P4  shelter            ─── outdoors + rain/cold
P5  hunger             ─── hunger ≥ threshold; emergency supply-run if severe
P6  wounds (non-bleed) ─── scratch/deep/bite/burn; medical supply-run fallback
P7  clothing           ─── temperature adjustment
P8  endurance          ─── rest when critically low
    [water pre-fill]   ─── proactive refill when near source + thirst < 10%
P9  wellness           ─── tasty food (HAPPINESS_FOOD_PRIORITY) → read → outside
P10 exercise           ─── default idle action
```

---

## Telemetry Schema v2

Log lines are comma-delimited `key=value` pairs.  New fields in v2 are
**additive** — old parsers silently ignore unknown keys.

| Field | v1 | v2 | Description |
|---|---|---|---|
| `schema_version` | — | `2` | Schema version constant |
| `player` | ✓ | ✓ | Player number (0-based) |
| `mode` | ✓ | ✓ | Always `autopilot` |
| `ff` | ✓ | ✓ | `normal` or `active` (zombie nearby) |
| `run_tick` | ✓ | ✓ | Monotonic tick counter per player |
| `action` | ✓ | ✓ | Decision label |
| `reason` | ✓ | ✓ | Trigger description |
| `class` | ✓ | ✓ | Broad category |
| `stage` | — | ✓ | Priority tier that fired |
| `fail_reason` | — | ✓ | Why action returned false |
| `retry_count` | — | ✓ | Per-player retry counter at decision time |
| stat fields | ✓ | ✓ | `hunger`, `thirst`, `fatigue`, `endurance`, `zombies`, `bleeding`, `str`, `fit` |

---

## CI Guards

`check.sh` enforces:
1. **luacheck** — zero errors/warnings on `42/media/lua/client/`.
2. **Lua test suite** — all 9 `tests/test_*.lua` files must pass.
3. **Python tests** — all `tests/test_benchmark.py` tests must pass.
4. **Deprecated API grep** — no direct `getHunger/getThirst/getFatigue/getEndurance/CharacterStats.*` calls.
5. **Line-count warning** — any Lua module > 1000 lines triggers a CI note (not a failure).

---

## KPI Targets (v2.0)

| KPI | Target |
|---|---|
| Survival: mean ticks-to-death | ≥ 1.5× V1.1 baseline |
| Injury rate | ≤ 0.5× V1.1 baseline |
| Exercise uptime | ≥ 30% of idle ticks |
| Max action streak | ≤ 15 |
| Loot-fail cycles before fallback | ≤ 3 |
