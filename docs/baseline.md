# AutoPilot Baseline Policy — V1.0

This document freezes the **control policy** for AutoPilot V1.0.
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

| Constant | Value | Notes |
|---|---|---|
| `HUNGER_THRESHOLD` | 0.20 | 0.0–1.0 stat scale |
| `THIRST_THRESHOLD` | 0.20 | 0.0–1.0 stat scale |
| `FATIGUE_THRESHOLD` | 0.70 | 0.0–1.0 stat scale |
| `BOREDOM_THRESHOLD` | 30 | 0–100 integer scale |
| `SADNESS_THRESHOLD` | 20 | 0–100 integer scale |
| `ENDURANCE_REST_MIN` | 0.30 | trigger rest below this |
| `ENDURANCE_EXERCISE_MIN` | 0.50 | skip exercise below this |
| `FLEE_MOODLE_LIMIT` | 2 | flee when negative stats > this |
| `DETECTION_RADIUS` | 10 | tiles to scan for zombies |
| `FLEE_DISTANCE` | 20 | tiles to run when fleeing |
| `HOME_DEFAULT_RADIUS` | 150 | home containment circle (tiles) |
| `EXERCISE_DAILY_CAP` | 20 | sets per in-game day |
| `EXERCISE_MINUTES` | 20 | game-minutes per exercise set |
| `PAIN_SLEEP_THRESHOLD` | 30 | pain level (0–100) that blocks sleep |
| `TEMP_TOO_COLD` | −20 | body-temp units; triggers clothing swap |
| `TEMP_TOO_HOT` | 20 | body-temp units; triggers clothing swap |
| `SUPPLY_RUN_TRIGGER` | 5 | consecutive empty loot cycles before expanding search |
| `WEAPON_CONDITION_MIN` | 0.25 | swap weapon below this durability |

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

---

## Telemetry Log Format (auto_pilot_run.log)

Each line written by `AutoPilot_Telemetry.lua`:

```
mode=autopilot,ff=<normal|active>,run_tick=<N>,action=<label>,reason=<label>,
hunger=<0-100>,thirst=<0-100>,fatigue=<0-100>,endurance=<0-100>,
zombies=<N>,bleeding=<N>,str=<0-10>,fit=<0-10>
```

`action` labels: `eat`, `drink`, `bandage`, `sleep`, `rest`, `exercise`,
`combat`, `shelter`, `idle`, `cooldown`, `busy`, `dead`

Run-end marker (`auto_pilot_run_end.json`):

```json
{"status": "dead|timeout", "reason": "<string>", "ticks": <N>, "timestamp": <unix>}
```
