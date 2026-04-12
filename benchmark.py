"""benchmark.py — Offline benchmark analyzer for AutoPilot run telemetry.

Parses the structured key=value telemetry log written by AutoPilot_Telemetry.lua
and produces a BenchmarkResult that quantifies run performance across the
dimensions that matter for learning and policy improvement:

  • Survival      — how many evaluation ticks the bot lasted
  • Action mix    — distribution of decision types (eat/drink/combat/rest/…)
  • Combat rate   — fraction of ticks with active zombie threat
  • Injury rate   — fraction of ticks with at least one bleeding wound
  • Exercise rate — fraction of idle ticks spent exercising
  • Resource pressure — fraction of ticks where hunger or thirst was elevated

Usage (CLI):
    python benchmark.py [--log PATH] [--out PATH]

Usage (API):
    from benchmark import parse_telemetry, score_run, write_benchmark
    entries = parse_telemetry("path/to/auto_pilot_run.log")
    result  = score_run(entries)
    write_benchmark(result, "auto_pilot_benchmark.json")

Safety policy: this module is read-only — it never modifies any Lua source.
"""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

# Default I/O paths (matching automate.py conventions)
DEFAULT_LOG = Path.home() / "Zomboid" / "Lua" / "auto_pilot_run.log"
DEFAULT_OUT = Path(__file__).parent / "auto_pilot_benchmark.json"

# ── Data types ────────────────────────────────────────────────────────────────

@dataclass
class BenchmarkResult:
    """Aggregated metrics for a single AutoPilot run."""

    # Total number of evaluation ticks logged
    total_ticks: int = 0

    # Run ended by: "dead" | "timeout" | "unknown"
    end_status: str = "unknown"

    # ── Schema versioning ────────────────────────────────────────────────────
    # Schema version from the log (0 = legacy / unknown)
    schema_version: int = 0

    # ── Action distribution ──────────────────────────────────────────────────
    # Raw counts per decision label
    action_counts: dict[str, int] = field(default_factory=dict)

    # Fraction of ticks (0.0–1.0) per decision label
    action_fractions: dict[str, float] = field(default_factory=dict)

    # ── Reason-class distribution ────────────────────────────────────────────
    # Counts per broad category: "survival","combat","wellness","exercise","recover","idle"
    class_counts: dict[str, int] = field(default_factory=dict)

    # Fraction per broad category
    class_fractions: dict[str, float] = field(default_factory=dict)

    # ── Stage distribution ───────────────────────────────────────────────────
    # Counts per priority-tier stage label (schema_version ≥ 2 only)
    stage_counts: dict[str, int] = field(default_factory=dict)

    # ── Fail-reason distribution ─────────────────────────────────────────────
    # Counts per fail_reason label (schema_version ≥ 2 only)
    fail_reason_counts: dict[str, int] = field(default_factory=dict)

    # ── Blocked action tracking ──────────────────────────────────────────────
    # Number of ticks where fail_reason was "blocked"
    blocked_ticks: int = 0

    # ── Threat / combat ──────────────────────────────────────────────────────
    # Fraction of ticks where ff=active (zombie nearby)
    combat_rate: float = 0.0

    # ── Injury ───────────────────────────────────────────────────────────────
    # Fraction of ticks with at least one bleeding wound
    injury_rate: float = 0.0

    # ── Resource pressure ────────────────────────────────────────────────────
    # Fraction of ticks where hunger ≥ 20 (matching HUNGER_THRESHOLD * 100)
    hunger_pressure: float = 0.0

    # Fraction of ticks where thirst ≥ 20 (matching THIRST_THRESHOLD * 100)
    thirst_pressure: float = 0.0

    # ── Exercise efficiency ──────────────────────────────────────────────────
    # Total exercise-action ticks
    exercise_ticks: int = 0

    # Fraction of total ticks spent exercising
    exercise_rate: float = 0.0

    # ── Stat averages ────────────────────────────────────────────────────────
    # Per-stat mean values across all logged ticks (0–100 integer scale)
    mean_hunger:    float = 0.0
    mean_thirst:    float = 0.0
    mean_fatigue:   float = 0.0
    mean_endurance: float = 0.0

    # ── Skill progression ────────────────────────────────────────────────────
    # Strength/Fitness levels at first and last tick (if available)
    str_start: int = 0
    str_end:   int = 0
    fit_start: int = 0
    fit_end:   int = 0

    # ── Loop detection ───────────────────────────────────────────────────────
    # Longest consecutive run of ticks with the identical action label.
    # Values > 15 (v2.0 KPI) often indicate a stuck loop.
    max_action_streak: int = 0

    # The action label that produced the longest streak.
    max_action_streak_label: str = ""

    # ── Composite score ──────────────────────────────────────────────────────
    # Higher is better.  Designed to reward survival and penalise deaths.
    # Formula:  ticks  −  500 × (ended_dead)  −  1000 × injury_rate × ticks
    score: float = 0.0


# ── Parsing ───────────────────────────────────────────────────────────────────

def _parse_kv_line(line: str) -> dict[str, str]:
    """Split a comma-delimited key=value line into a dict."""
    result: dict[str, str] = {}
    for part in line.split(","):
        if "=" not in part:
            continue
        key, _, value = part.partition("=")
        result[key.strip()] = value.strip()
    return result


def parse_telemetry(log_path: str | os.PathLike[str]) -> list[dict[str, Any]]:
    """Parse *auto_pilot_run.log* and return a list of entry dicts.

    Each entry mirrors the key=value fields written by AutoPilot_Telemetry.lua:
      schema_version (v2+), mode, ff, run_tick, action, reason, class,
      stage (v2+), fail_reason (v2+), retry_count (v2+),
      hunger, thirst, fatigue, endurance,
      zombies, bleeding, str, fit

    Integer/float fields are coerced; unknown values remain as strings.
    Lines that cannot be parsed are silently skipped.
    Old-format log files (schema_version absent) are still parsed; missing v2
    fields are left absent in the entry dict so downstream code must use .get().
    """
    path = Path(log_path)
    if not path.exists():
        return []

    entries: list[dict[str, Any]] = []
    int_fields = {
        "schema_version", "run_tick", "retry_count",
        "hunger", "thirst", "fatigue",
        "endurance", "zombies", "bleeding", "str", "fit",
    }

    with path.open(encoding="utf-8", errors="ignore") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line:
                continue
            kv = _parse_kv_line(line)
            if not kv:
                continue
            # Coerce numeric fields
            for key in int_fields:
                if key in kv:
                    try:
                        kv[key] = int(float(kv[key]))
                    except ValueError:
                        pass
            entries.append(kv)

    return entries


# ── Scoring ───────────────────────────────────────────────────────────────────

_HUNGER_PRESSURE_THRESHOLD  = 20   # hunger ≥ 20% triggers needs check
_THIRST_PRESSURE_THRESHOLD  = 20   # thirst ≥ 20%

# Maps action labels (from the telemetry log) to broad reason classes.
# Used as a fallback when the "class" field is absent (older log files).
# Must stay in sync with the REASON_CLASS table in AutoPilot_Telemetry.lua.
_ACTION_CLASS_MAP: dict[str, str] = {
    "eat":      "survival",
    "drink":    "survival",
    "sleep":    "survival",
    "rest":     "survival",
    "shelter":  "survival",
    "bandage":  "survival",
    "loot":     "survival",
    "fight":    "combat",
    "flee":     "combat",
    "combat":   "combat",
    "read":     "wellness",
    "outside":  "wellness",
    "clothing": "wellness",
    "happiness":"wellness",
    "exercise": "exercise",
    "recover":  "recover",
    "idle":     "idle",
    "busy":     "idle",
    "cooldown": "idle",
    "dead":     "idle",
    "blocked":  "idle",
}


def score_run(entries: list[dict[str, Any]], end_status: str = "unknown") -> BenchmarkResult:
    """Compute a BenchmarkResult from a list of parsed telemetry entries.

    @param entries     Output of parse_telemetry().
    @param end_status  "dead" | "timeout" | "unknown" — how the run ended.
    """
    result = BenchmarkResult(end_status=end_status)
    if not entries:
        return result

    result.total_ticks = len(entries)

    # ── Counters ──────────────────────────────────────────────────────────────
    action_counts:      dict[str, int] = {}
    class_counts:       dict[str, int] = {}
    stage_counts:       dict[str, int] = {}
    fail_reason_counts: dict[str, int] = {}
    ff_active     = 0
    bleeding_ticks = 0
    hunger_ticks   = 0
    thirst_ticks   = 0
    blocked_ticks  = 0

    hunger_sum    = 0.0
    thirst_sum    = 0.0
    fatigue_sum   = 0.0
    endurance_sum = 0.0

    str_start = fit_start = -1
    str_end   = fit_end   = 0

    # Track highest schema_version seen in the log.
    max_schema_version = 0

    # Loop detection: track streaks of the same action label.
    current_streak_label = ""
    current_streak_len   = 0
    max_streak_label     = ""
    max_streak_len       = 0

    for entry in entries:
        action = entry.get("action", "idle")
        action_counts[action] = action_counts.get(action, 0) + 1

        # reason_class: prefer the explicit "class" field written by newer telemetry;
        # fall back to deriving from action for older log files.
        cls = entry.get("class", "")
        if not cls:
            cls = _ACTION_CLASS_MAP.get(action, "idle")
        class_counts[cls] = class_counts.get(cls, 0) + 1

        # Schema v2+: stage, fail_reason, retry_count, schema_version.
        sv = entry.get("schema_version", 0)
        if isinstance(sv, int) and sv > max_schema_version:
            max_schema_version = sv

        stage = entry.get("stage", "")
        if stage:
            stage_counts[stage] = stage_counts.get(stage, 0) + 1

        fail_reason = entry.get("fail_reason", "")
        if fail_reason:
            fail_reason_counts[fail_reason] = fail_reason_counts.get(fail_reason, 0) + 1
            if fail_reason == "blocked":
                blocked_ticks += 1

        if entry.get("ff") == "active":
            ff_active += 1

        bleeding = entry.get("bleeding", 0)
        if isinstance(bleeding, int) and bleeding > 0:
            bleeding_ticks += 1

        hunger = entry.get("hunger", 0)
        if isinstance(hunger, int):
            hunger_sum += hunger
            if hunger >= _HUNGER_PRESSURE_THRESHOLD:
                hunger_ticks += 1

        thirst = entry.get("thirst", 0)
        if isinstance(thirst, int):
            thirst_sum += thirst
            if thirst >= _THIRST_PRESSURE_THRESHOLD:
                thirst_ticks += 1

        if isinstance(entry.get("fatigue"), int):
            fatigue_sum += entry["fatigue"]
        if isinstance(entry.get("endurance"), int):
            endurance_sum += entry["endurance"]

        # Track start/end skill levels
        str_val = entry.get("str")
        fit_val = entry.get("fit")
        if isinstance(str_val, int) and isinstance(fit_val, int):
            if str_start < 0:
                str_start = str_val
                fit_start = fit_val
            str_end = str_val
            fit_end = fit_val

        # Update streak tracking for loop detection.
        if action == current_streak_label:
            current_streak_len += 1
        else:
            current_streak_label = action
            current_streak_len   = 1
        if current_streak_len > max_streak_len:
            max_streak_len   = current_streak_len
            max_streak_label = current_streak_label

    n = result.total_ticks

    result.schema_version          = max_schema_version
    result.action_counts           = action_counts
    result.action_fractions        = {k: v / n for k, v in action_counts.items()}
    result.class_counts            = class_counts
    result.class_fractions         = {k: v / n for k, v in class_counts.items()}
    result.stage_counts            = stage_counts
    result.fail_reason_counts      = fail_reason_counts
    result.blocked_ticks           = blocked_ticks
    result.combat_rate             = ff_active      / n
    result.injury_rate             = bleeding_ticks / n
    result.hunger_pressure         = hunger_ticks   / n
    result.thirst_pressure         = thirst_ticks   / n
    result.exercise_ticks          = action_counts.get("exercise", 0)
    result.exercise_rate           = result.exercise_ticks / n
    result.mean_hunger             = hunger_sum    / n
    result.mean_thirst             = thirst_sum    / n
    result.mean_fatigue            = fatigue_sum   / n
    result.mean_endurance          = endurance_sum / n
    result.str_start               = max(str_start, 0)
    result.str_end                 = str_end
    result.fit_start               = max(fit_start, 0)
    result.fit_end                 = fit_end
    result.max_action_streak       = max_streak_len
    result.max_action_streak_label = max_streak_label

    # Composite score: reward survival, penalise death and injury time
    death_penalty   = 500 if end_status == "dead" else 0
    injury_penalty  = round(result.injury_rate * n * 10)   # 10 pts per injured tick
    result.score    = n - death_penalty - injury_penalty

    return result


# ── Output ────────────────────────────────────────────────────────────────────

def write_benchmark(result: BenchmarkResult, out_path: str | os.PathLike[str]) -> None:
    """Serialise *result* to a JSON file at *out_path*."""
    data = asdict(result)
    Path(out_path).write_text(json.dumps(data, indent=2), encoding="utf-8")


# ── CLI entry point ───────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Parse AutoPilot run telemetry and write a benchmark JSON report."
    )
    parser.add_argument(
        "--log",
        default=str(DEFAULT_LOG),
        help="Path to auto_pilot_run.log (default: ~/Zomboid/Lua/auto_pilot_run.log)",
    )
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="Output JSON path (default: auto_pilot_benchmark.json)",
    )
    parser.add_argument(
        "--status",
        default="unknown",
        choices=["dead", "timeout", "unknown"],
        help="How the run ended (default: unknown)",
    )
    args = parser.parse_args()

    entries = parse_telemetry(args.log)
    if not entries:
        print(f"No telemetry entries found in: {args.log}")
        return

    result = score_run(entries, end_status=args.status)
    write_benchmark(result, args.out)
    print(
        f"Benchmark complete: {result.total_ticks} ticks, "
        f"score={result.score:.0f}, status={result.end_status}"
    )
    print(f"Report written to: {args.out}")


if __name__ == "__main__":
    main()
