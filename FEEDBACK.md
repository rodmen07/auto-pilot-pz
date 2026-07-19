# Feedback Triage Guide

AutoPilot Leveler has been public on the Steam Workshop (id 3767254910) since
2026-07-18. Reports arrive through two channels: Workshop comments and GitHub
issues (the bug-report form in `.github/ISSUE_TEMPLATE/bug_report.yml`
collects the evidence this guide works from). This guide maps the common
report shapes to the evidence that isolates them and the local test suite or
tool that reproduces the logic offline.

Plainly: reading and answering Workshop comments, and deciding which comments
become GitHub issues, is the maintainer's call. Nothing in this guide or the
issue form automates that judgment; they only make the chosen reports
actionable in one pass.

## Evidence sources

All paths are Windows form; on Linux replace `%USERPROFILE%` with `~`.

| Source | Where | What it shows |
|---|---|---|
| `console.txt` | `%USERPROFILE%/Zomboid/console.txt` | Mod load list (load order), every Lua error, all `[AutoPilot]` prints |
| `auto_pilot_run.log` | `%USERPROFILE%/Zomboid/Lua/` | One key=value line per evaluation cycle: action, reason, fail_reason, stats, zombies, STR/FIT |
| `auto_pilot_deaths.log` | `%USERPROFILE%/Zomboid/Lua/` | One snapshot line per death: classified cause=, stats, wounds, position, recent decisions |
| `triage_run_log.py` | `python triage_run_log.py [path]` | Action mix, transitions, time split, threat events, per-session STR/FIT deltas, suspicious patterns |
| Mod options | Options > Mods > AutoPilot Leveler | Slider and keybind deviations from defaults (the form requires this list) |

[docs/triage.md](docs/triage.md) is the full `triage_run_log.py`
reference: the run-log schema, how to read each report section, the
suspicious-pattern catalog (including V4.5 signatures the tool does not
auto-detect, like `foreign_action` ticks and training-backoff gaps), and
the fixture workflow for adding new detectors.

**The first-error rule.** Project Zomboid loads client Lua files
alphabetically and stops loading a file at its FIRST error. One early crash
therefore silently prevents every later module from loading, and the visible
symptom (dead panel, no training) is often far downstream of the real bug.
When reading a `console.txt` excerpt, always start from the first error in
the file; everything after it may be fallout.

## Report shapes

### 1. "The mod does nothing"

- **Ask for:** `console.txt` from the top (the mod list is logged at load, so
  the same excerpt doubles as load-order evidence); whether the mod appears
  in the in-game Mods list; whether F10 was actually pressed (the mod is OFF
  by default and stays off until armed); whether `auto_pilot_run.log` exists
  at all; whether the arm key was rebound in options.
- **What the evidence looks like:** a healthy load has no Lua errors and the
  HUD shows OFF until F10. A load-order casualty shows a first console error
  inside an AutoPilot file (or a file that sorts before it); apply the
  first-error rule above. The known MP class: joining a server re-executes
  all mod Lua, and some events (`Events.OnQueueNewGame`) do not exist during
  that reload; both session-end registrations have been existence-guarded
  since V3.2, so a recurrence would show as a console error at the guard
  site. A missing or empty run log means the evaluation loop never ran or
  the mod was never armed (telemetry writes only while the mod evaluates).
- **Isolate locally:** `lua tests/test_main_logic.lua` (arm/disarm toggle,
  tick handler, key handling, guarded event registration); `bash check.sh`
  for the full pass (luacheck catches the syntax-level causes of a load
  abort).

### 2. "Exercise never starts"

- **Ask for:** `triage_run_log.py` output (or a run-log excerpt covering
  several armed minutes); the F11 status line text; "sets today N/cap" from
  the panel; the chosen focus; the mod-options-changed list.
- **What the evidence looks like:** exercise is step 8 of the 10-step
  priority chain, so any active survival need above it (bleeding, sleep,
  thirst, hunger, wounds, exhaustion, boredom) legitimately claims the cycle;
  the triage time split shows survival ticks dominating when that is the
  story. The panel status line names the gate: "resting (endurance
  recovering)" is the endurance minimum, "resting (exercises fatigued)" is
  XP-fatigue rotation with the whole pool spent (resumes about 3 game hours
  later), and hitting the daily set cap also reports as resting. A lowered
  daily-cap slider or a raised endurance-minimum slider explains most
  reports of this shape, which is why the form requires the options list.
  In the raw log, the reason and fail_reason fields on each line show what
  claimed every cycle instead of exercise.
- **Isolate locally:** `lua tests/test_priority_logic.lua` (the priority
  chain ordering) and `lua tests/test_leveler_metrics.lua` (focus selection
  and XP metrics).

### 3. "The F11 panel is dead"

- **Ask for:** `console.txt` (first error); whether F10 still works; whether
  the panel key was rebound in options.
- **What the evidence looks like:** this is the classic load-cascade symptom.
  `AutoPilot_UI` sorts late alphabetically, so a crash in almost any earlier
  module aborts loading before the UI exists, and F11 appears dead even
  though the real bug is elsewhere; the first-error rule finds it. Since
  V3.2 a panel-open failure is never silent (a real console print plus a HUD
  warning), so "F11 dead with zero console output" points at a rebound panel
  key or at the key handler never registering at all (which is shape 1).
- **Isolate locally:** `bash check.sh` (luacheck flags syntax-level load
  aborts); `lua tests/test_main_logic.lua` (key handler wiring). Actual
  panel rendering can only be confirmed in-game: TESTING.md, Auto-Exercise
  Leveler section.

### 4. "I died while AFK"

- **Ask for:** the matching `auto_pilot_deaths.log` line(s); a run-log
  excerpt from before the death or `triage_run_log.py` output (session
  "ended: dead", threat events); where the player armed the mod (a cleared
  base or a hot area).
- **What the evidence looks like:** the death snapshot's cause= field
  (horde, zombie_wounded, bleed_out, infection, starvation, dehydration,
  zombies, unknown) plus the recent-decisions ring shows what the mod chose
  in the final cycles. Distinguish a fail-safe limit from a decision bug:
  the survival layer is a fail-safe, not a caretaker, so arming in a hot
  area and being overwhelmed is by design; a snapshot showing many bleeding
  ticks with bandages in inventory and no bandage decision is a bug. The
  learning layer leaves its own evidence: next session the console prints
  "[Adaptive] N death(s) on record" and the F11 panel lists the bounded
  threshold tweaks applied.
- **Isolate locally:** `lua tests/test_threat_logic.lua` (detection radius,
  engagement gate, flee decisions) and `lua tests/test_medical_logic.lua`
  (wound priority, bandage selection). If the complaint is about the
  learning rather than the death itself, `lua tests/test_leveler_metrics.lua`
  covers the DeathLog parse and the bounded Adaptive rules.

### 5. "The mod tanks my FPS" (performance)

- **Ask for:** how long the mod was armed; the run-log line count; whether
  `console.txt` shows the same error repeating every engine tick; SP or MP
  and rough zombie population.
- **What the evidence looks like:** since V3.3 the run log rotates once per
  session (past 20,000 lines it is trimmed to the newest 5,000, with a
  "[Telemetry] Rotated log" console line), so unbounded-log complaints
  should only reproduce on pre-V3.3 installs; the log is safe to delete at
  any time. Per-tick console error spam is the proven FPS killer here (the
  MP stale-closure bug printed "__add not defined" every engine tick until
  V3.1 fixed it); a healthy mod evaluates once per 15 ticks, roughly every
  0.75 s. In the triage output, a tick count wildly out of proportion to
  the time armed, or an action mix dominated by idle/busy churn, is a lead.
- **Isolate locally:** `python triage_run_log.py` (action mix and streak
  detection) and `python benchmark.py` (offline run analysis);
  `python -m pytest tests/` covers both parsers. Rotation itself is
  verified in-game: TESTING.md, B42 Compatibility and Telemetry section.

## From report to fix

1. Workshop comment or issue arrives; the maintainer decides whether it
   becomes (or already is) a GitHub issue.
2. Match the report to a shape above; if the issue form is missing the
   evidence that shape needs, ask for exactly that and nothing more.
3. Run the isolating suite locally; a reproducing test goes in the same PR
   as the fix.
4. `bash check.sh` green before merge; the fix lands in CHANGELOG.md.
