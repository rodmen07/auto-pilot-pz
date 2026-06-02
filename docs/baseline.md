# AutoPilot Baseline Policy — V1.1

This document freezes the **control policy** for AutoPilot V1.1.
It serves as the reference baseline for all future learning and self-augmentation work.
Any proposed policy change must be benchmarked against this document before promotion.

---

## Priority Chain (highest → lowest)

| Priority | Trigger condition | Action |
|----------|------------------|--------|
| 1 | Any body part bleeding (unbandaged) | `bandage` immediately |
| 2 | Fatigue ≥ 70 % | `sleep` (find bed; fall back to rest) |
| 3 | Thirst ≥ 20 % | `drink` (water source → inventory → loot) |
| 4 | Outside + raining or body temp < −20 | `shelter` (walk inside) |
| 5 | Hunger ≥ 20 % | `eat` (best calorie-match food → loot) |
| 6 | Any non-bleeding wound (scratch, bite, deep, burn) | `bandage` |
| 7 | Clothing out of range for temperature | `adjust_clothing` |
| 8 | Endurance ≤ 30 % or endurance moodle ≥ 3 | `rest` (furniture → floor) |
| 9 | Boredom ≥ 30 or sadness ≥ 20 or unhappy moodle ≥ 40 | `read` then `go_outside` |
| 10 | None of the above | `exercise` (strength/fitness alternating) |

Threat check runs **before** the priority chain every tick:
- Bleeding → always flee
- Unarmed + multiple zombies → flee
- Negative stats > `FLEE_MOODLE_LIMIT` (2) → flee; otherwise fight

---

## Baseline Thresholds (AutoPilot_Constants.lua)

All tunable constants live in `AutoPilot_Constants.lua`.  The table below
maps each constant to the owning behavior and the test/scenario that
validates it.

| Constant | Value | Owning behavior | Validation |
|---|---|---|---|
| `HUNGER_THRESHOLD` | 0.20 | Needs.doHunger | test_priority_logic #3 |
| `THIRST_THRESHOLD` | 0.20 | Needs.doThirst | test_priority_logic #2 |
| `FATIGUE_THRESHOLD` | 0.70 | Needs.doSleep | test_priority_logic #4 |
| `BOREDOM_THRESHOLD` | 30 | Needs.doBoredom | — |
| `SADNESS_THRESHOLD` | 20 | Needs.doBoredom | — |
| `ENDURANCE_REST_MIN` | 0.30 | Needs.doRest | test_priority_logic #17 |
| `ENDURANCE_EXERCISE_MIN` | 0.50 | Needs.doExercise | test_priority_logic #11 |
| `EXERCISE_MINUTES` | 20 | Needs.doExercise | — |
| `EXERCISE_DAILY_CAP` | 20 | Needs.doExercise | — |
| `PAIN_SLEEP_THRESHOLD` | 30 | Needs.doSleep | test_priority_logic #15/#16 |
| `FLEE_MOODLE_LIMIT` | 2 | Threat.check | test_threat_logic #6/#7 |
| `DETECTION_RADIUS` | 10 | Threat.getNearbyZombies | test_threat_logic #2/#3 |
| `FLEE_DISTANCE` | 20 | Threat.doFlee | test_threat_logic #9 |
| `HOME_DEFAULT_RADIUS` | 150 | Home.set | test_home_map_barricade Home#1 |
| `MEDICAL_LOOT_RADIUS` | 30 | Medical.lootNearbyBandage | test_medical_logic #10 |
| `LOOT_SEARCH_RADIUS` | 150 | Inventory.lootNearby* | — |
| `WATER_SEARCH_RADIUS` | 150 | Inventory.findWaterSource | — |
| `SUPPLY_RUN_TRIGGER` | 5 | Needs supply-run counter | test_priority_logic #18 |
| `WEAPON_CONDITION_MIN` | 0.25 | Inventory.checkAndSwapWeapon | — |
| `TEMP_TOO_COLD` | −20 | Needs.doShelter | — |
| `TEMP_TOO_HOT` | 20 | Needs.adjustClothing | — |
| `DEPLETED_CAP` | 500 | Map.markDepleted | test_home_map_barricade Map#3 |
| `BARRICADE_SEARCH_RADIUS` | 15 | Barricade.doBarricade | test_home_map_barricade Bar#3 |

---

## Safety Invariants (must never be violated by any candidate policy)

1. **Medical priority is immutable.**  
   Bleeding detection and treatment is always priority 1, before all other decisions.

2. **Threat check is unconditional.**  
   `AutoPilot_Threat.check()` runs every tick regardless of any other mode or override.

3. **No direct runtime code injection.**  
   Policy candidates are implemented only as changes to constants or Lua source files,
   never as dynamic string evaluation (`load`, `loadstring`, `dofile` with user data).

4. **All PZ API calls are pcall-wrapped.**  
   Any new code path that calls the PZ Java API must wrap the call in `pcall` and
   handle the failure case without crashing.

5. **Telemetry is append-only.**  
   `AutoPilot_Telemetry.lua` writes to `~/Zomboid/Lua/`; it never reads game state from
   external files or executes commands received from the Python harness.

6. **Home bounds are respected.**  
   Non-combat actions that move the player must check `AutoPilot_Home.isInside()`.

7. **Barricade is idempotent.**  
   `AutoPilot_Barricade.doBarricade()` is safe to call multiple times; the ModData
   flag prevents duplicate work.

---

## Benchmark Scoring Formula (baseline)

```
score = total_ticks − 500 × (died) − 10 × (bleeding_ticks)
```

- `total_ticks` — number of evaluation cycles logged (≈ 0.75 s each in real-time)
- `died` — 1 if `end_status == "dead"`, 0 otherwise
- `bleeding_ticks` — ticks where at least one body part was bleeding

Candidate policies must produce a **higher mean score** than this baseline across
3+ matched runs before promotion.

Loop detection: if `max_action_streak` in the benchmark report exceeds 20, investigate
whether the bot is stuck in a repeated no-op cycle (e.g. repeated loot-fail loops).

---

## Telemetry Log Format (auto_pilot_run.log)

Each line written by `AutoPilot_Telemetry.lua`:

```
mode=autopilot,ff=<normal|active>,run_tick=<N>,action=<label>,reason=<label>,class=<category>,
hunger=<0-100>,thirst=<0-100>,fatigue=<0-100>,endurance=<0-100>,
zombies=<N>,bleeding=<N>,str=<0-10>,fit=<0-10>
```

`action` labels: `eat`, `drink`, `bandage`, `sleep`, `rest`, `exercise`,
`combat`, `shelter`, `idle`, `cooldown`, `busy`, `dead`

`class` field (reason-class): `survival`, `combat`, `wellness`, `exercise`, `idle`

Run-end marker (`auto_pilot_run_end.json`):

```json
{"status": "dead|timeout", "reason": "<string>", "ticks": <N>, "timestamp": <unix>}
```

---

## Source of Truth

- **All gameplay logic**: `42/media/lua/client/` only.
- `media/lua/client/` is a **deprecated legacy mirror** — do not edit.
- Tunable constants: `AutoPilot_Constants.lua` only.  Patching individual modules
  to change thresholds is a policy violation.
- `auto_tune.py` patches `AutoPilot_Constants.lua` directly (not individual modules).

