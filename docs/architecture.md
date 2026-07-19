# AutoPilot Leveler Architecture (V4.3)

## Overview

AutoPilot Leveler is an in-process Lua mod for Project Zomboid Build 42
(target: 42.19.0 Unstable). It is an auto-exercise leveler: the player arms
it with F10 and the character grinds Strength/Fitness while an always-on
survival fail-safe (eat, drink, sleep, medical, fight-or-flee) keeps them
alive. A death-learning layer records every death and applies bounded
threshold tuning at the next session start.

All decision logic runs natively inside the game engine (Kahlua/Lua 5.1).
No sidecar process, no HTTP, no external state is required at runtime. The
mod is client-side only and MP-compatible (in multiplayer each client
automates its own character). Splitscreen is not supported (removed in
V3.2). The mod starts OFF; arming it is a deliberate player action.

The runtime is 18 modules under `42/media/lua/client/`. PZ loads client Lua
files alphabetically; `AutoPilot_Constants` loads before every module that
reads it at load time, and the modules that sort earlier (`Adaptive`,
`Barricade`) only touch Constants inside function bodies, never at load.

## Module Map

Each module owns a specific slice of state. Cross-module reads are allowed;
cross-module writes go through the owner's public API. The one deliberate
exception is `AutoPilot_Constants`: it is the shared tuning surface that
both `AutoPilot_Options` (player sliders) and `AutoPilot_Adaptive`
(death-learning deltas) mutate, in that order.

### Leveler core

| Module | Responsibility | Key interactions |
|---|---|---|
| `AutoPilot_Main` | Orchestrator for the local player: OnTick evaluation loop, F10 arm/disarm, HUD status line, queue-thrash guard, session-end telemetry hooks. Owns the mode (off/autopilot), post-action cooldown, and action-streak counters. | Registers `Events.OnTick` / `OnKeyPressed` (plus guarded session-end events). Calls `Threat.beginCycle`/`check`, `Needs.check`/`shouldInterrupt`, `Telemetry.logTick`/`onDeath`/`onShutdown`, `Home.set`, `Barricade.doBarricade`, `Options.applyOnce`, `Adaptive.init`, `UI.toggle`. Exposes `AutoPilot.isActive()` / `AutoPilot.toggle()` for the panel. |
| `AutoPilot_Leveler` | Training focus selection per character: Auto (balance the lower of STR/FIT), Strength, or Fitness. Focus persists in player ModData (MP-safe via `transmitModData`). V4.3: also owns the weekly training-program scheduler, a pure table plus day-resolution logic mapping the in-game weekday to that day's focus (auto/strength/fitness/rest); the selected program id is read live from `AutoPilot_Constants.TRAINING_PROGRAM`. | Called by `Needs.check`'s exercise slot (`Leveler.check`). Samples both exercise perks via `AutoPilot_XP.sample` every call, resolves today's program day (rest days yield the slot; a program day focus overrides the selection for that day), then delegates the actual set to `Needs.trainExercise(player, focus)`. `getMetricsFor` and `getProgramStatus` serve the UI. |
| `AutoPilot_XP` | XP metrics engine: per-perk session baseline plus a rolling real-time sample window that yields session gain, XP/hour, and ETA to next level. | Leaf module (no calls into other AutoPilot modules). `sample`/`getMetrics` are called by `Leveler` (STR/FIT every exercise cycle) and, since V4.1, by `Barricade`/`Medical` when real barricade or treatment actions queue (Woodwork/Doctor visibility, read-only); the UI reads metrics through `Leveler.getMetricsFor`. |
| `AutoPilot_UI` | F11 leveler panel (`ISCollapsableWindow`): focus buttons, arm/disarm button, live trainer status, sets/day, exercise regularity, both perks' metrics, death count, and the applied adaptive tweaks. Panel position is remembered per character in ModData. | Opened from `Main`'s key handler (panel errors are printed to the real console and flashed on the HUD, never swallowed). Reads `Leveler` (focus + metrics), `Needs.getExerciseStatus`, `DeathLog.getDeathCount`, `Adaptive.getApplied`; the arm button calls `AutoPilot.toggle`. |
| `AutoPilot_Options` | In-game configurability via 42.19's `PZAPI.ModOptions`: sliders for training and fail-safe tunables, rebindable arm/panel keys, and (V4.3) the weekly training-program selector. | Registers at load. `applyOnce` (called from `Main`'s tick, before `Adaptive.init`) copies slider values into `AutoPilot_Constants` (V4.3: including the program pick, mapped to a program id in `TRAINING_PROGRAM`); saving the options screen re-applies live. `Main` reads `getKey` for the rebindable F10/F11 bindings. |

### Survival fail-safe

| Module | Responsibility | Key interactions |
|---|---|---|
| `AutoPilot_Needs` | Priority state machine for survival needs plus the exercise slot: eat/drink/sleep/rest, shelter, clothing, wound treatment dispatch, boredom relief, proactive scavenging, base maintenance, and `doExercise` (endurance gates, daily set cap, equipment preference, XP-fatigue rotation). | Called by `Main` (`check`, `shouldInterrupt`). Calls `Medical.check`/`hasCriticalWound`, many `Inventory` helpers, `Home` bounds checks, `Barricade.checkMaintenance`, `Leveler.check`, and `Telemetry.setDecision` for every decision. Exposes `trainExercise` (the Leveler's seam) and `getExerciseStatus` (the panel's status line). |
| `AutoPilot_Threat` | Zombie detection (same z-level, cached per cycle) and the fight/flee decision, including the V3.2 engagement gate, directional spread analysis, encirclement handling, and flee stutter prevention. | Called by `Main` (`beginCycle`, `check`). `getNearbyZombies` is also read by `Main`'s HUD, `Telemetry`, and `DeathLog`. Calls `Medical.hasCriticalWound` (bleeding forces flee), `Inventory.checkAndSwapWeapon`/`getBestWeapon` (pre-equip before the engage decision), and `Home` (flee redirects toward home when set). |
| `AutoPilot_Inventory` | Item selection and looting: safe-food/drink choice, weapon selection and swap, bandage-loot support, supply counts, supply runs, water sourcing and refill, clothing adjustment, and exercise-equipment checks plus the daily gear fetch. | Called by `Needs` and `Threat`. Reads `Home` bounds to keep loot trips inside the containment circle and reads/writes `Map` depletion so empty containers are not revisited. |
| `AutoPilot_Medical` | Wound detection and treatment: bleeding first, then deep wounds, bites, scratches, burns; bandage selection by quality with a rip-sheets fallback. | `check(player, bleedingOnly)` is called from `Needs`; `hasCriticalWound` from `Needs` and `Threat`; `getWoundSnapshot` from `Telemetry` and `DeathLog`. V4.1: a queued treatment samples the Doctor perk via `AutoPilot_XP.sample` (visibility only). |
| `AutoPilot_Home` | Home anchor persistence (player ModData, survives save/reload) and bounds logic: `isInside`, walk-target clamping, and up to three fallback shelter squares. | Anchored by `Main` on the first ACTIVE cycle after arming. Read by `Barricade` (scan bounds), `Inventory` (loot bounds), `Threat` (flee-toward-home), `Needs`, and `DeathLog` (distance from home at death). |
| `AutoPilot_Barricade` | Periodic barricade maintenance: re-barricades windows inside home bounds when the countdown expires; requires an equipped hammer and plank plus 2+ nails. | `checkMaintenance` is called every cycle from `Needs`' base-maintenance slot (a single counter decrement in the common case); `doBarricade` is the immediate pass `Main` runs at first-active-cycle init. Uses `Home.isInside` and `Utils` square iteration. V4.1: a scan that queues barricade work samples the Woodwork perk via `AutoPilot_XP.sample` (visibility only). |
| `AutoPilot_Map` | Depleted-square memory: remembers containers found empty so loot passes skip them; entry count is bounded (`DEPLETED_CAP`). | Written and read by `Inventory` only (`markDepleted`, `isDepleted`); supply runs call `resetDepleted` so the expanded search re-checks everything. |

### Learning and infrastructure

| Module | Responsibility | Key interactions |
|---|---|---|
| `AutoPilot_DeathLog` | Death learning, recording half: a per-player ring buffer of the last 15 distinct decisions (consecutive duplicates collapse) and, on death, one key=value context snapshot line (stats, wounds, zombie count, position, distance from home, hours survived, focus, recent decisions, classified cause) appended to `auto_pilot_deaths.log`. | `recordDecision` is fed by `Telemetry.logTick` each cycle; `writeSnapshot` is triggered by `Telemetry.onDeath`. Snapshot collection reads `Home`, `Medical`, `Threat`, `Leveler`, and `Utils`. `readLines`/`parseLine` serve `Adaptive`; `getDeathCount` serves the panel. |
| `AutoPilot_Adaptive` | Death learning, adaptation half: once per session, reads the death log, buckets causes over the most recent 25 deaths, and applies bounded, transparent threshold adjustments to `AutoPilot_Constants` (each rule has a hard floor or cap). | `init` is called from `Main`'s tick (after `Options.applyOnce`, so player settings are the base the deltas apply to). Reads `DeathLog`; `getApplied` lists this session's adjustments in the F11 panel. |
| `AutoPilot_SessionHistory` | Session history data layer (V4.2): one compact key=value summary line per session (ticks, STR/FIT/Woodwork/Doctor start/end levels, end reason) appended to `auto_pilot_sessions.log`, written at session end and refreshed by periodic "open" checkpoints; a versioned header line, a tolerant parser, once-per-session collapse rotation (newest `SESSION_HISTORY_KEEP` sessions survive), and pre-formatted panel strings (rows + trend sparkline). Registers NO events. | `observe` is fed by `Telemetry.logTick` each cycle; `finalize` by `Telemetry.onDeath` ("dead") and `Telemetry.onShutdown` ("timeout"), all existence-guarded. `getPanelLines` serves the F11 history block (the UI renders the returned strings verbatim). |
| `AutoPilot_Telemetry` | Per-tick run-log writer: one key=value CSV line per evaluation cycle to `auto_pilot_run.log`, a JSON end marker (`dead` or `timeout`) to `auto_pilot_run_end.json`, and once-per-session log rotation. | `logTick` is called by `Main` every evaluation; `setDecision` by `Needs` at each decision point; `onDeath`/`onShutdown` by `Main`. Collects stats via `Utils.safeStat`, `Threat.getNearbyZombies` (cached scan), and `Medical.getWoundSnapshot`; feeds `DeathLog.recordDecision` and `SessionHistory.observe`/`finalize` (V4.2) and triggers `DeathLog.writeSnapshot`. |
| `AutoPilot_Constants` | Central registry of tunable thresholds and constants, with documented units and rationale. The shared tuning surface: `Options` writes player settings into it, then `Adaptive` applies its deltas on top; consuming modules read tunables live at their use sites (the V3.3 fix). | Read by every module. Written only by `Options` and `Adaptive`. |
| `AutoPilot_Utils` | Safe shared helpers: `safeStat` (pcall-wrapped B42 `getStats():get(CharacterStat.X)` access) and the square-scan primitives `iterateNearbySquares` (flat radius scan) and `findNearestSquare` (outward spiral). | Leaf module; called from nearly everywhere. Sorts last alphabetically, which is safe because its globals are only resolved when functions are called, never at load. |

## Main Loop: OnTick Cadence and Cycle Priority

`Events.OnTick` fires roughly 20 times per real second. `Main`'s handler
counts ticks on the shared global `AutoPilot` table and runs one evaluation
cycle every `TICK_INTERVAL` (15) ticks, i.e. about every 0.75 s. Before
each evaluation it runs the two once-per-session tuning steps in a fixed
order: `Options.applyOnce` (player settings) then `Adaptive.init`
(death-learning deltas on top), so the two tuning layers always compose the
same way.

Each evaluation cycle for the local player proceeds top to bottom; the
first stage that claims the cycle ends it:

1. `Threat.beginCycle` clears and arms the zombie-scan cache (HUD, threat
   check, and telemetry share one scan per cycle), then the HUD status
   line updates. If the mod is OFF, the cycle ends here.
2. First ACTIVE cycle only: anchor home at the current position and queue
   an initial barricade pass (idempotent).
3. Dead: log the death once (`Telemetry.onDeath`, which also writes the
   DeathLog snapshot) and stop.
4. Asleep: log and wait.
5. `Threat.check`: an engaged threat claims the cycle and sets the
   post-action cooldown.
6. Post-action cooldown: count down (`ACTION_COOLDOWN_CYCLES` = 4 cycles,
   about 3 s after any queued action).
7. Busy (`ISTimedActionQueue.isPlayerDoingAction`): a running exercise may
   be interrupted when `Needs.shouldInterrupt` reports an urgent need
   (bleeding, thirst/hunger threshold, exhaustion); otherwise the
   queue-thrash guard counts consecutive busy cycles and clears the queue
   past `MAX_ACTION_STREAK` (15).
8. `Needs.check`: the survival-and-training priority chain below.
9. Nothing claimed the cycle: log `idle`.

## Priority Chain (Needs.check)

Evaluated top to bottom each cycle; the first handler that queues an action
wins. Hunger/thirst triggers and other tunables are read live from
`AutoPilot_Constants` at each use site.

```
 1  bleeding          bandage immediately (fatal if untreated)
 2  sleep             fatigue >= threshold (checked before the rest gate)
    [rest cooldown]   suppress routine needs while seated resting
 3  thirst            drink: tap/sink, inventory, then loot
    [weather]         outside in rain/cold: seek shelter
 4  hunger            eat; loot and supply-run fallbacks
 5  wounds            treat non-bleeding wounds (scratch/deep/bite/burn)
    [clothing]        temperature-driven clothing adjustment
 6  exhaustion        rest when endurance is critically low
 7  boredom/unhappy   tasty food, then read, then go outside
 8  EXERCISE          the mod's purpose (see focus flow below)
 9  scavenge          bounded background chore: proactive supply top-up
10  maintenance       periodic barricade re-check (no-op most cycles)
```

Exercise sits directly above the background chores (a V3.2 reorder: it was
previously at the bottom and proactive scavenging claimed every idle
cycle). Survival needs always win; when the endurance gates inside
`doExercise` decline a set, the cycle falls through to the chores while
endurance recovers.

On a training-program rest day (V4.3) the exercise slot yields the same
way the endurance gates do: `Leveler.check` returns false without training
and the cycle falls through to the chores. The scheduler only refines this
one slot's focus-or-rest decision; it never reorders the chain or claims
cycles, so survival behavior is untouched and a scheduler bug cannot
starve anything above or below it (the V3.2 lesson).

Proactive scavenging is deliberately bounded so it can never starve the
trainer again: 25-tile radius, a cooldown of about a minute between trips,
and a back-off of about 15 minutes after 3 trips with no supply-count
improvement. Reactive hunger/thirst still search the full loot radius.

## Exercise Focus Flow

The exercise slot in `Needs.check` calls `Leveler.check`, which samples
both exercise perks for the metrics window, resolves today's
training-program day (V4.3, see Training Programs below; a rest day
returns false here and the cycle falls to the chores), and then delegates
to `Needs.trainExercise(player, focus)` with the day's focus: the
program's day focus when it names one, otherwise the persisted selection
(`nil` for Auto, which balances the lower of STR/FIT). `doExercise` then:

1. Resets the sets-per-day counter on day rollover and enforces the daily
   set cap and the endurance gates (skipping a set is reported to the
   panel as a "resting" status, not silence).
2. Once per day (Strength/Auto focus, no gear carried): queues a fetch
   trip that pulls a dumbbell/barbell from home containers, unlocking the
   higher-xpMod equipment exercises. The fetch is itself that cycle's
   action.
3. Builds the focus's ordered candidate pool (Strength: dumbbell press,
   biceps curl, barbell curl, push-ups; Fitness: squats, or sit-ups while
   any leg part is too stiff; Auto: burpees first) and picks the first
   candidate whose required item is carried (the vanilla
   `inventory:contains` gate) and that is not XP-fatigued.
4. Queues `ISFitnessAction` via `ISTimedActionQueue.addGetUpAndThen`
   (stands the character up first), equipping the exercise's prop item the
   same way the vanilla fitness UI does, and snapshots both perks' XP for
   fatigue judging.

XP-fatigue detection handles PZ's per-exercise diminishing returns, which
the engine does not expose to Lua: a completed set (at least 80 percent of
its duration) that gained under `EXERCISE_MIN_XP_PER_SET` marks that
exercise fatigued for `EXERCISE_FATIGUE_RECOVERY_MS` (3 in-game hours) and
the pool rotates to the next candidate. A fully fatigued pool PAUSES
training rather than burning food and endurance for zero XP. Snapshots are
guarded by character identity so a death/respawn can never false-fatigue an
exercise against the old character's XP.

## Training Programs (V4.3)

`AutoPilot_Leveler.PROGRAMS` defines five weekly presets (expansion
candidate C3), each mapping the in-game weekday, Sunday through Saturday,
to a day focus:

| Program | Week (Sun..Sat) |
|---|---|
| Balanced (default) | auto every day (identical to pre-V4.3 behavior) |
| Strength emphasis | FIT, STR, STR, FIT, STR, STR, STR (5 STR / 2 FIT) |
| Fitness emphasis | STR, FIT, FIT, STR, FIT, FIT, FIT (5 FIT / 2 STR) |
| Alternating days | STR, FIT, STR, FIT, STR, FIT, STR |
| Rest-day split | rest, STR, FIT, STR, FIT, STR, FIT (Sunday off) |

An "auto" day defers to the player's F11 focus selection (the pre-V4.3
behavior); a "strength" or "fitness" day overrides the selection for that
day; a "rest" day makes the exercise slot yield so the survival chores own
the cycle (no training that day; the F11 program line says so). Only the
opt-in Rest-day split contains rest days: the compiled-in default
("balanced", via `AutoPilot_Constants.TRAINING_PROGRAM`) can never idle
the trainer. Program selection is read live from that constant at every
cycle (the V3.3 live-read pattern), so saving the options screen takes
effect on the next cycle, and unknown values validate to "balanced".

The weekday derives ONLY from the verified
`getGameTime():getCalender():getTimeInMillis()` surface: weekday =
(floor(millis / day) + 4) % 7, the +4 because epoch day zero (1970-01-01)
was a Thursday. No day-of-week calendar API is in the verified record, so
none is called. When the calendar is unavailable the resolution is
pcall-guarded to "auto", i.e. the always-on focus behavior: the scheduler
can only ever narrow the exercise slot's decision, never break it.

## XP Metrics Window

`AutoPilot_XP` tracks each perk with a session baseline (first sample) and
a rolling window of samples capped at 10 minutes of REAL time and 120
entries. XP/hour is computed across the window's endpoints; ETA to next
level divides `PerkFactory` XP-to-next by that rate. Wall-clock time is
used deliberately: the metrics describe the AFK player's actual wait, and
game-time jumps during sleep would corrupt the rate.

## F11 Panel

`AutoPilot_UI` is a vanilla `ISCollapsableWindow` configuring the LOCAL
player only. It shows: an arm/disarm button reflecting live state (same
code path as F10, via `AutoPilot.toggle`), the three focus buttons with the
current focus highlighted, the live trainer status line from
`Needs.getExerciseStatus` ("training: squats", "resting (endurance
recovering)", "resting (exercises fatigued)", "fetching exercise
equipment") with sets today N/cap, the long-term `getRegularity` of the
exercise currently training, the V4.3 training-program day line
pre-formatted by `Leveler.getProgramStatus` ("today: STR day (program:
Strength emphasis)"; rest days read "today: rest day (program: Rest-day
split), survival chores only"), both exercise perks' metric blocks (level, XP
to next, session gain, XP/hour, ETA), the V4.1 Woodwork and Doctor blocks in
the same style (read-only visibility of the XP the game grants for the
barricade maintenance and wound treatment the mod already performs), the
V4.2 session-history block (the last `SESSION_HISTORY_PANEL_ROWS` sessions,
newest first, each row showing session number, ticks, STR/FIT/Woodwork/
Doctor level deltas, and end reason, plus a trend sparkline of total level
gains across the retained sessions), and the death count plus up to four
applied adaptive tweaks. Every history string is pre-formatted by
`AutoPilot_SessionHistory` (where the logic is unit-tested); the panel only
draws what the data layer returns. Panel position persists per character
via ModData.

## Death Learning: DeathLog Ring and Adaptive Tuning

Recording: every telemetry tick feeds `DeathLog.recordDecision`, a
15-entry-per-player ring buffer that collapses consecutive duplicates (a
long idle streak is one entry). On death, `Telemetry.onDeath` triggers
`DeathLog.writeSnapshot`: one key=value line capturing stats, wounds,
zombie count, position, distance from home, hours survived, the active
focus, the recent-decision ring, and a classified cause (horde,
zombie_wounded, bleed_out, infection, starvation, dehydration, zombies,
unknown; most specific signal wins).

Adaptation: at session start `Adaptive.init` parses the log, counts causes
over the most recent 25 deaths (plus an "away" bucket for deaths more than
60 tiles from a set home), and applies its RULES table to
`AutoPilot_Constants`. Every rule is bounded by a hard floor or cap, so the
mod can never tune itself into absurd behavior. Examples: horde deaths
lower `FLEE_HORDE_SIZE` (floor 3) and widen `DETECTION_RADIUS` (cap 30);
starvation deaths lower `HUNGER_THRESHOLD` (floor 0.10) and raise
`SUPPLY_FOOD_MIN` (cap 6); away-from-home deaths shrink
`LOOT_RADIUS_SUPPLY` (floor 80). Every applied adjustment is recorded and
listed in the F11 panel.

## Runtime Tuning: ModOptions and Live-Read Constants

`AutoPilot_Options` registers a `PZAPI.ModOptions` page (Options > Mods >
AutoPilot Leveler) with sliders for the daily set cap, endurance minimum,
XP-fatigue recovery hours, food/drink stockpile minimums, proactive loot
radius, detection radius, and close-danger radius, plus rebindable arm and
panel keys. Values are copied into `AutoPilot_Constants` once per session
from `Main`'s tick, BEFORE `Adaptive.init`, so player settings and
death-learning deltas compose in a stable order; saving the options screen
re-applies immediately.

V4.3 adds the weekly training-program selector to the page: a dropdown
where `addComboBox` exists (it is NOT in the mock's verified 42.19 record,
so the call is existence-checked inside its own pcall and cannot take the
sliders down with it), with a slider over the 1-based program indices (a
verified surface) as the fallback. Either control's value is mapped to a
program id (index or display text; unmappable values leave the constant
untouched) and written to `AutoPilot_Constants.TRAINING_PROGRAM`, which
the Leveler reads live at the exercise slot. The program table itself and
all day resolution live in `AutoPilot_Leveler`, keeping the documented
no-suite-loads-Options coverage gap exactly as narrow as it was.

This works because of the V3.3 fix: tunable constants are read live from
`AutoPilot_Constants` at their use sites. Before V3.3, several modules
captured tunables into file-locals at load time (`DETECTION_RADIUS` and
`FLEE_HORDE_SIZE` in Threat, `MEDICAL_LOOT_RADIUS` in Medical, the
hunger/thirst triggers in Needs), which made the Adaptive rules targeting
them silently inert and would have broken mod options the same way.

## Multiplayer Guards

Joining a server makes PZ re-execute all mod Lua, which produced two
distinct failure classes that the architecture now defends against:

- Event existence checks: `Events.OnQueueNewGame` does not exist during
  the 42.19 server-connect Lua reload, and an unguarded `.Add` crashed
  `Main`'s load. Because PZ loads files alphabetically and stops loading a
  file at its first error, that single crash silently prevented every
  later module (Needs, Threat, Telemetry, UI, ...) from loading, which is
  why F11 appeared dead. Both session-end registrations are now
  existence-guarded, and F11 failures are never silent (real console
  print plus a HUD warning).
- Shared-global handler state: a previously registered OnTick closure can
  survive a Lua reload with dead upvalues (observed live as "__add not
  defined" spam every engine tick). Tick state therefore lives on the
  shared global `AutoPilot` table, which is resolved at call time and so
  is immune to stale upvalues; duplicate handler registrations dedupe via
  the frame timestamp; and the keyboard handler carries a matching
  stale-closure guard that retires dead copies quietly.

Per-player keying (`[playerNum]` tables in Home, Map, Telemetry, Leveler,
XP) survives from the splitscreen era as harmless plumbing; since V3.2 only
the local player exists and every key resolves to 0.

## Telemetry

One key=value CSV line per evaluation cycle is appended to
`~/Zomboid/Lua/auto_pilot_run.log` via `getFileWriter` (the only game-safe
file API in PZ's sandbox); a JSON end marker distinguishing `dead` from
`timeout` goes to `auto_pilot_run_end.json`, and death snapshots go to
`auto_pilot_deaths.log`.

Schema v3 fields (additive; old parsers ignore unknown keys):
`schema_version`, `player`, `mode`, `ff` (normal/active), `run_tick`,
`action`, `reason`, `class`, `stage`, `fail_reason`, `retry_count`, and the
stat fields `hunger`, `thirst`, `fatigue`, `endurance`, `zombies`,
`bleeding`, `str`, `fit`, plus the V4.1 action-perk levels `wood`, `doc`
(Woodwork / Doctor) appended after `fit`. Schema v2 lines are identical
minus the trailing `wood`/`doc` pair and still parse everywhere.

Rotation (V3.3): once per session, on the first append per player, if the
run log exceeds `TELEMETRY_MAX_LINES` (20,000) the oldest lines are dropped
and only the newest `TELEMETRY_KEEP_LINES` (5,000) are kept. This closed
the "log grows unbounded" limitation.

## Session History (V4.2)

`AutoPilot_SessionHistory` owns `~/Zomboid/Lua/auto_pilot_sessions.log`:
line one is a versioned header (`# auto_pilot_sessions schema=1`) and each
following line is one session's key=value summary in fixed, additive-only
field order: `schema`, `session` (monotonic id), `player`, `ticks`,
`str_start`/`str_end`, `fit_start`/`fit_end`, `wood_start`/`wood_end`,
`doc_start`/`doc_end`, `ended` (`open`/`dead`/`timeout`). The field
conventions mirror `triage_run_log.py`'s per-session summaries; in-game the
values are accumulated directly from `Telemetry.logTick`'s stat collection
instead of re-parsing the run log in Kahlua.

Writes are append-only: the definitive line lands at session end
(`Telemetry.onDeath` -> `ended=dead`, `Telemetry.onShutdown` ->
`ended=timeout`, idempotent so a shutdown after a death changes nothing),
and every `SESSION_HISTORY_CHECKPOINT_CYCLES` (400) evaluation cycles an
`ended=open` checkpoint line is refreshed so a crash still leaves a recent
summary. At read time the latest line per session id wins, collapsing the
checkpoints; the parser is tolerant (comment lines, malformed lines, and
unknown or missing additive fields never abort a read). Once per Lua
session, on the first session begin, the file is collapsed to one line per
session and only the newest `SESSION_HISTORY_KEEP` (30) summaries are
retained (the module's only non-append write, mirroring the run-log
rotation). A death followed by a respawn in the same Lua state finalizes
the old session and starts the next id.

## CI Guards

`check.sh` (mirrored by `.github/workflows/ci.yml`) enforces:

1. **luacheck**: zero errors and zero warnings across the 18 modules in
   `42/media/lua/client/`.
2. **Static API guard**: no deprecated direct stat getters
   (`:getHunger()`, `:getThirst()`, `:getFatigue()`, `:getEndurance()`,
   `CharacterStats.`); B42 code must use
   `player:getStats():get(CharacterStat.X)`.
3. **Line-count guard**: any Lua module over 1000 lines triggers a warning
   (non-fatal).
4. **Lua test suite**: glob-driven discovery of `tests/test_*.lua` (zero
   matches fails the run), so new test files are picked up with no list
   edits; currently 10 files, all green.
5. **pytest**: the Python benchmark and log-analysis tests.

`release.yml` packages this file (with `42/`, the rest of `docs/`, and
`CHANGELOG.md`) into release archives and verifies its presence, so what
this document claims ships to users.
