# Run-Log Triage Guide (`triage_run_log.py`)

`triage_run_log.py` (repo root, next to `benchmark.py`) turns a long
AutoPilot telemetry log into a one-screen health report: action mix,
transitions, time split, threat events, per-session STR/FIT deltas, and a
conservative "Suspicious patterns" scan. It exists because the run log is
the debugging goldmine (it found the V3.2 scavenging-starvation bug) but
nobody wants to read 20,000 CSV lines by hand. Shipped in V3.6: PR #17
added the tool, its clean fixture, and the parser tests; PR #18 added the
four pattern detectors and their fixture. This guide is the reference for
running it, reading it, and extending it.

The tool is read-only and stdlib-only: it never modifies any log or any
Lua source. CI runs it under Python 3.12; any reasonably current Python 3
works.

## Quick start

```bash
python triage_run_log.py                  # default: ~/Zomboid/Lua/auto_pilot_run.log
python triage_run_log.py path/to/some.log # triage another file
python triage_run_log.py --top 20         # show 20 transitions instead of 10
```

The default input is the player-0 run log that `AutoPilot_Telemetry.lua`
writes while the mod is armed, at `~/Zomboid/Lua/auto_pilot_run.log`
(Windows: `%USERPROFILE%\Zomboid\Lua\auto_pilot_run.log`). Splitscreen-era
files (`auto_pilot_run_p1.log` etc.) can be passed as an explicit path.

Exit codes and edge cases:

- `0`: the report printed, or the log was missing/empty (the tool prints
  "No telemetry entries found in: PATH" and still exits 0).
- `2`: command-line usage error (argparse).
- Any other failure is an unexpected error with a traceback (for example
  a file that exists but cannot be read).

Library use mirrors the CLI:

```python
from triage_run_log import parse_run_log, summarize, format_report
entries, skipped = parse_run_log("path/to/auto_pilot_run.log")
print(format_report(summarize(entries, skipped), "path/to/auto_pilot_run.log"))
```

## Input: the telemetry run log

One key=value CSV line is appended per evaluation cycle (about every
0.75 s of real time) while the mod is armed; after a death exactly one
`dead` marker line is written and the cycles stop logging until respawn.
The writer is `AutoPilot_Telemetry.logTick`; decisions are labeled at
their source via `AutoPilot_Telemetry.setDecision` (survival chain) or
passed directly by `AutoPilot_Main` (busy/threat/idle/sleep/dead paths).
The log rotates once per session past 20,000 lines, keeping the newest
5,000 (see the Telemetry section of `docs/architecture.md` for the writer
side).

### Schema (v3, additive-only)

Current lines are `schema_version=3` (since V4.1) with this exact field
order:

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | int | Line format version. 3 since V4.1; 2 before. Additive-only: parsers must ignore unknown keys, and old lines must keep parsing. |
| `player` | int | 0-based player number. Player 0 writes `auto_pilot_run.log`; the numbered files are splitscreen-era plumbing (only player 0 occurs since V3.2). |
| `mode` | string | Always `autopilot` (lines are only written while the mod evaluates). |
| `ff` | string | `active` when this cycle's cached zombie scan saw at least one zombie, else `normal`. |
| `run_tick` | int | Per-player cycle counter, +1 per line. Restarts from 1 in a new game session: this is the session-boundary marker. |
| `action` | string | What claimed the cycle (inventory below). |
| `reason` | string | Why it claimed the cycle (inventory below). |
| `class` | string | Writer-side coarse class of the action (`survival`, `combat`, `wellness`, `exercise`, `recover`, `idle`). The triage tool ignores it and derives categories from `action` instead; see the legacy note below. |
| `stage` | string | Reserved priority-tier label. Every current call site leaves it empty (`stage=`). |
| `fail_reason` | string | Reserved failure label. Currently always empty. |
| `retry_count` | int | Reserved retry counter. Currently always 0. |
| `hunger`, `thirst`, `fatigue`, `endurance` | int | Stat percentages 0-100 (floor of stat * 100). |
| `zombies` | int | Nearby-zombie count from the per-cycle cached scan. |
| `bleeding` | int | Bleeding-wound count from the medical snapshot. |
| `str`, `fit` | int | Strength / Fitness perk levels. |
| `wood`, `doc` | int | v3 only (V4.1): Woodwork / Doctor perk levels, appended after `fit`. Absent on v2 lines. |

Real lines from the clean test fixture
(`tests/fixtures/run_log_v2_sample.log`, schema v2 kept deliberately as
the backward-compat control):

```
schema_version=2,player=0,mode=autopilot,ff=normal,run_tick=2,action=exercise,reason=training,class=exercise,stage=,fail_reason=,retry_count=0,hunger=11,thirst=9,fatigue=13,endurance=90,zombies=0,bleeding=0,str=2,fit=3
schema_version=2,player=0,mode=autopilot,ff=active,run_tick=9,action=combat,reason=threat,class=combat,stage=,fail_reason=,retry_count=0,hunger=8,thirst=15,fatigue=24,endurance=60,zombies=3,bleeding=0,str=3,fit=3
schema_version=2,player=0,mode=autopilot,ff=active,run_tick=14,action=dead,reason=player_died,class=idle,stage=,fail_reason=,retry_count=0,hunger=12,thirst=20,fatigue=35,endurance=10,zombies=5,bleeding=2,str=3,fit=3
schema_version=2,player=0,mode=autopilot,ff=normal,run_tick=1,action=idle,reason=no_action,class=idle,stage=,fail_reason=,retry_count=0,hunger=5,thirst=4,fatigue=8,endurance=98,zombies=0,bleeding=0,str=5,fit=5
```

The last two lines show a session boundary: `run_tick` drops from 14 back
to 1, so the tool starts session 2 there. A v3 line, as used by the
schema-tolerance tests in `tests/test_triage_run_log.py`:

```
schema_version=3,player=0,mode=autopilot,ff=normal,run_tick=1,action=barricade,reason=maintenance,class=idle,stage=,fail_reason=,retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=90,zombies=0,bleeding=0,str=1,fit=2,wood=4,doc=3
```

Legacy `class` note: that test line carries `class=idle` on a barricade
action because scavenge/barricade were missing from the Lua
`REASON_CLASS` table until the V3.6 audit fix (PR #19); the current
writer emits `class=survival` for both. Both eras triage identically
because the tool's time split is computed from the `action` label, never
from `class`.

### Action / reason inventory (current code)

Fixed pairs logged by `AutoPilot_Main`:

| `action` | `reason` | Emitted when |
|---|---|---|
| `sleep` | `asleep` | The character is asleep this cycle. |
| `combat` | `threat` | The threat response claimed the cycle (fight or flee). |
| `cooldown` | `post_action` | Post-action cooldown (4 cycles, about 3 s, after any queued action). |
| `busy` | `foreign_action` | V4.5: the running timed action was NOT queued by the mod (player-initiated, another mod, or a vanilla internal queue). The mod never touches it. |
| `busy` | `action_running` | The mod's own queued action is still running. |
| `idle` | `no_action` | Nothing claimed the cycle. |
| `dead` | `player_died` | Death marker, once per death. |

Decision pairs set by `AutoPilot_Needs` via `setDecision`: `bandage`
(`bleeding`, `wound`), `sleep` (`fatigue_thresh`), `rest`
(`rest_cooldown`, `low_endurance`), `drink` (`thirst_thresh`), `shelter`
(`weather`), `eat` (`hunger_thresh`, `unhappy`), `clothing`
(`temperature`), `read` (`boredom`), `outside` (`boredom`), `exercise`
(`training`), `scavenge` (`low_supplies`), `barricade` (`maintenance`).

Older logs may also contain the legacy labels `loot`, `fight`, `flee`,
`happiness`, `recover`, and `blocked`; the tool still categorizes them.

### Parser tolerance

A non-empty line is skipped (and counted in the report header) when it
does not yield both an `action` label and an integer `run_tick`. This
tolerates garbage, truncated writes, and rotation artifacts without
aborting the file. A truncated tail that still has those two fields keeps
its parsed prefix. Integer fields are coerced; a missing file parses as
an empty log.

## Reading the report

```
=== AutoPilot run-log triage ===
Log: ...
Parsed N tick(s) across M session(s); K malformed line(s) skipped.
```

- **Action mix**: per-action tick counts and percentages, sorted by
  count. The at-a-glance answer to "what did the character actually do".
- **Top action transitions**: (previous action, action) pairs counted
  within sessions only (a death marker never chains into the next
  session's first tick). Dominant `exercise -> exercise` is a healthy
  grind; heavy `X -> Y -> X` churn between two non-training actions is a
  lead.
- **Time split**: every tick filed into exactly one category, derived
  from the `action` label:

  | Category | Actions |
  |---|---|
  | training | `exercise` |
  | resting | `sleep`, `rest`, `recover` |
  | survival | `eat`, `drink`, `shelter`, `bandage`, `clothing`, `read`, `outside`, `happiness`, `loot`, `scavenge`, `barricade`, `combat`, `fight`, `flee` |
  | idle | `idle`, `busy`, `cooldown`, `blocked`, `dead`, plus any unknown label |

  The mod's purpose is training, so a healthy armed-and-safe log is
  training-heavy with survival claiming cycles only when needs fire.
- **Threat events**: threat ticks (`zombies > 0` or `ff=active`), threat
  episodes (consecutive runs of threat ticks), max zombies seen, combat
  ticks (`combat`/`fight`/`flee`), bleeding ticks (`bleeding > 0`), and
  deaths (`dead` markers).
- **Sessions (STR/FIT deltas)**: one line per detected session with tick
  count, first-to-last STR and FIT levels, and how it ended: `dead` when
  the last line is a death marker, otherwise `open`. Note that a clean
  quit also reads `open` here; the dead-versus-timeout distinction lives
  in `auto_pilot_run_end.json`, not in the run log.
- **Suspicious patterns**: the catalog below. A clean log prints
  `none detected`.

## Suspicious patterns

Deliberately conservative: this is triage, not diagnosis. Every detector
is session-scoped (one odd session cannot smear across the whole file)
and each finding is a flag for a human to look at, never a verdict. Each
finding prints as `[pattern] detail` plus a one-line hint. Thresholds are
named constants at the top of `triage_run_log.py`.

### Automated detectors (the four the tool runs)

| Pattern tag | Signature | Threshold |
|---|---|---|
| `[action streak]` | One action label repeated 40+ consecutive ticks within a session. | `STREAK_MIN_TICKS = 40` |
| `[zero-XP training]` | 30+ training ticks in a session while neither STR nor FIT moved a level (needs `str`/`fit` fields present). | `ZERO_XP_MIN_TRAINING_TICKS = 30` |
| `[flee/combat cycle]` | Combat re-entered 4+ times, each within 3 non-combat ticks of the previous fight ending (combat = `combat`/`fight`/`flee`). | `COMBAT_CYCLE_MIN_CYCLES = 4`, `COMBAT_CYCLE_MAX_GAP = 3` |
| `[empty-loot spiral]` | 15+ scavenge ticks in a session while hunger or thirst still rose by 15+ points. | `LOOT_SPIRAL_MIN_SCAVENGE = 15`, `LOOT_SPIRAL_NEED_RISE = 15` |

What each one usually means:

- **action streak**: the rotation is stuck on one thing. Read the
  `reason`/`fail_reason` fields around that stretch of the raw log. Note
  that a long `sleep` streak overnight is expected; the detector still
  reports it and the human dismisses it.
- **zero-XP training**: levels are coarse (XP grows inside a level), but
  this much training with no level movement deserves a look at the F11
  XP panel (session gain and XP/hour resolve what the level fields
  cannot).
- **flee/combat cycle**: the survivor keeps getting pulled back into a
  fight right after patching up; the area may be too hot for the current
  flee threshold, so consider relocating home.
- **empty-loot spiral**: loot trips are coming back empty while needs
  climb; nearby containers may be depleted, so a new home area may help.

### Signatures worth a manual look (not auto-detected)

The report will not flag these; grep the raw log for them when a symptom
points that way.

- **`reason=foreign_action` (V4.5)**: signature
  `action=busy,reason=foreign_action`. A running timed action the mod
  did not queue: the player, another mod, or a vanilla internal queue
  owns the character, and the mod (by the V4.5 guarantee) never clears,
  interrupts, or streak-counts it. Long armed stretches of these are
  usually correct behavior (for example the player exercising manually),
  not a bug; but a "mod does nothing while armed" report whose log is
  wall-to-wall `foreign_action` means something else is holding the
  queue, and identifying that something is the investigation.
- **`busy`/`action_running` streaks past the thrash guard**: signature
  is more than about 15 consecutive
  `action=busy,reason=action_running` lines. The queue-thrash guard
  clears the mod's own stuck action after `MAX_ACTION_STREAK` (15)
  consecutive busy evaluations (about 11 s), so a much longer unbroken
  run of `action_running` means the guard is not engaging; that would
  be a code defect worth a report.
- **Training backoff gaps (V4.5)**: no dedicated log line exists. The
  backoff is visible only indirectly: `exercise`/`training` lines stop
  for up to `EXERCISE_BACKOFF_MINUTES` game minutes (Options slider,
  default 10, 0 disables) immediately after either (a) a mod-queued
  exercise that vanished early (player cancelled it), (b) an F10 panic
  stop, or (c) a stretch of `foreign_action` lines (a manual exercise
  refreshes the window every cycle). During the gap, armed cycles fall
  through to `scavenge`/`barricade`/`idle` with no survival pressure.
  Live, the F11 status line says "backing off (...)" or "waiting (manual
  exercise in progress)"; nothing about the backoff appears in
  `console.txt` (the module's debug prints are compiled to no-ops), so
  the run-log gap is the only offline evidence.
- **`cooldown`/`post_action` share**: every queued action costs about 4
  cycles (3 s) of cooldown, so some share is normal; `cooldown`
  dominating the action mix means the mod is churning many tiny actions
  instead of settling into sets.
- **Reserved fields non-empty**: `stage=`, `fail_reason=` and
  `retry_count=0` are what every current call site writes. Any non-empty
  `stage`/`fail_reason` or nonzero `retry_count` in a user log means the
  log was written by code that is not in this tree (a fork or a newer
  version); check the reporter's mod version first.
- **`class=idle` on scavenge/barricade lines**: pre-PR-#19 logs only
  (see the legacy note above). Harmless; confirms an older mod version.
- **Rapid `run_tick` resets**: many sessions of only a handful of ticks
  each means the player is relogging or restarting rapidly, or the mod
  is being armed and the game quit over and over; correlate with
  `console.txt` before reading anything else into the log.
- **Nonzero skipped-line count**: a few malformed lines are normal
  (truncated writes, rotation artifacts). A large count means the wrong
  file was passed or the log is corrupted.
- **Mixed `schema_version` values mid-file**: normal for a log spanning
  the V4.1 upgrade (v2 lines then v3 lines); the schema is additive-only
  and both parse.

## Adding a new pattern detector (fixture workflow)

The two fixtures split the roles: `tests/fixtures/run_log_v2_sample.log`
(20 lines, 2 sessions, first ends in a death) is the clean control that
no detector may ever fire on; `tests/fixtures/run_log_v2_suspicious.log`
(111 lines, 4 sessions) is the trap log where each session trips exactly
one detector. Both are schema v2 on purpose, doubling as the
backward-compat proof; detectors needing v3-only fields (`wood`/`doc`)
should build inline v3 lines in the test instead, the way
`TestSchemaV3WoodDoc` does.

1. Pick a session-scoped signature and a threshold conservative enough
   that a finding is worth a human's time. Add the threshold as a named
   constant next to the existing ones at the top of `triage_run_log.py`.
2. Write `detect_<name>(sessions)` returning a list of
   `SuspiciousFinding(pattern=..., detail=..., hint=...)`: `pattern` is
   the short report tag, `detail` names the session number, the observed
   counts, and the threshold, and `hint` is one plain-language pointer
   for the human doing triage.
3. Append the detector to `detect_suspicious` (its position there is the
   report order; the combined-order test pins it).
4. Append one new session to `run_log_v2_suspicious.log` that trips ONLY
   the new detector, and check it stays below every existing threshold
   (and that existing sessions stay below the new one). `run_tick`
   restarting from 1 is what starts the new session.
5. Add tests in `tests/test_triage_run_log.py` following the existing
   pairs: fires-on-suspicious (asserting tag and detail content), silent
   on the clean fixture, plus updates to the suspicious-fixture
   line/session counts, the `detect_suspicious` order test, and the
   `summarize` findings count.
6. Run `python -m pytest tests/test_triage_run_log.py -v`, then
   `bash check.sh` for the full gate.

The tool's safety policy holds for extensions: read-only, stdlib-only,
and `benchmark.py` stays untouched.

## Related documents

- `FEEDBACK.md`: which report shapes call for triage output, and what to
  ask a reporter for.
- `docs/architecture.md`: the Telemetry and Session History sections
  describe the writer side (rotation, end markers, schema history).
- `README.md`: Telemetry section, quick usage. The tool itself lives at
  the repo root as `triage_run_log.py`, alongside `benchmark.py` and
  `auto_tune.py`.
