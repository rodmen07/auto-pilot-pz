"""triage_run_log.py - Telemetry triage summarizer for AutoPilot run logs.

Reads the structured key=value telemetry log written by AutoPilot_Telemetry.lua
(schema_version=2, one line per evaluation cycle) and prints a human-readable
triage report:

  * Action mix        - per-action tick counts and percentages
  * Transitions       - top action-to-action transitions (within a session)
  * Time split        - training / resting / survival / idle categories
  * Threat events     - threat ticks, episodes, max horde size, deaths
  * Sessions          - per-session STR/FIT level deltas and end status

A "session" is detected by a run_tick reset: AutoPilot_Telemetry increments
run_tick monotonically per player, so a line whose run_tick is not greater
than the previous line's marks a new game session in the same log file.

Usage (CLI):
    python triage_run_log.py [LOG_PATH] [--top N]

    LOG_PATH defaults to ~/Zomboid/Lua/auto_pilot_run.log (the player-0 log).

Usage (API):
    from triage_run_log import parse_run_log, summarize, format_report
    entries, skipped = parse_run_log("path/to/auto_pilot_run.log")
    summary = summarize(entries, skipped)
    print(format_report(summary, "path/to/auto_pilot_run.log"))

Safety policy: this module is read-only and stdlib-only - it never modifies
any Lua source or any log file.
"""

from __future__ import annotations

import argparse
import os
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Default input path (matching benchmark.py / automate.py conventions)
DEFAULT_LOG = Path.home() / "Zomboid" / "Lua" / "auto_pilot_run.log"

# ── Category mapping ──────────────────────────────────────────────────────────
# Derived from the action labels actually emitted by the Lua runtime:
#   AutoPilot_Needs.check()      - bandage, sleep, rest, drink, shelter, eat,
#                                  clothing, read, outside, exercise, scavenge,
#                                  barricade
#   AutoPilot_Main               - sleep, combat, cooldown, busy, idle
#   AutoPilot_Telemetry.onDeath  - dead
# plus the legacy labels still present in Telemetry's REASON_CLASS table
# (loot, fight, flee, happiness, recover, blocked) so old logs triage cleanly.
#
# NOTE: "scavenge" and "barricade" are absent from the Lua REASON_CLASS table,
# so telemetry lines for them carry class=idle.  This map intentionally files
# them under "survival" (they are supply/base upkeep, not idle time), which is
# why the split is computed from the action label rather than the class field.
ACTION_CATEGORY: dict[str, str] = {
    # training - the mod's primary purpose (Needs step 8)
    "exercise":  "training",
    # resting - recovery time (Needs sleep/rest branches, Main "asleep" ticks)
    "sleep":     "resting",
    "rest":      "resting",
    "recover":   "resting",     # legacy REASON_CLASS label
    # survival - needs, medical, threat response, supply and base chores
    "eat":       "survival",
    "drink":     "survival",
    "shelter":   "survival",
    "bandage":   "survival",
    "clothing":  "survival",
    "read":      "survival",    # wellness upkeep (boredom/unhappiness)
    "outside":   "survival",    # wellness upkeep
    "happiness": "survival",    # legacy REASON_CLASS label
    "loot":      "survival",    # legacy REASON_CLASS label
    "scavenge":  "survival",    # Needs step 9 (class=idle in the raw log)
    "barricade": "survival",    # Needs step 10 (class=idle in the raw log)
    "combat":    "survival",
    "fight":     "survival",    # legacy REASON_CLASS label
    "flee":      "survival",    # legacy REASON_CLASS label
    # idle - no productive activity this cycle
    "idle":      "idle",
    "busy":      "idle",
    "cooldown":  "idle",
    "blocked":   "idle",
    "dead":      "idle",
}

CATEGORY_ORDER = ("training", "resting", "survival", "idle")

# Action labels that indicate an active threat response.
COMBAT_ACTIONS = {"combat", "fight", "flee"}


def categorize_action(action: str) -> str:
    """Map an action label to a triage category; unknown labels count as idle."""
    return ACTION_CATEGORY.get(action, "idle")


# ── Data types ────────────────────────────────────────────────────────────────

@dataclass
class SessionSummary:
    """Per-session slice of the log (between run_tick resets)."""

    index: int = 0                  # 1-based session number in file order
    player: int = 0                 # player field of the session's lines
    ticks: int = 0                  # lines in this session
    str_start: int | None = None    # first STR level seen (None: field absent)
    str_end:   int | None = None
    fit_start: int | None = None    # first FIT level seen
    fit_end:   int | None = None
    ended: str = "open"             # "dead" if the last line is a death marker


@dataclass
class TriageSummary:
    """Aggregated triage metrics for one run log."""

    total_ticks: int = 0
    skipped_lines: int = 0

    # Raw counts per action label
    action_counts: dict[str, int] = field(default_factory=dict)

    # Counts per triage category ("training","resting","survival","idle")
    category_counts: dict[str, int] = field(default_factory=dict)

    # (prev_action, action) -> count, session-scoped (no cross-session pairs)
    transition_counts: dict[tuple[str, str], int] = field(default_factory=dict)

    # ── Threat events ────────────────────────────────────────────────────────
    threat_ticks: int = 0       # ticks with zombies > 0 (ff=active)
    threat_episodes: int = 0    # consecutive runs of threat ticks
    max_zombies: int = 0        # largest zombies value seen
    combat_ticks: int = 0       # ticks whose action is a combat response
    bleeding_ticks: int = 0     # ticks with at least one bleeding wound
    deaths: int = 0             # action=dead end-of-session markers

    sessions: list[SessionSummary] = field(default_factory=list)


# ── Parsing ───────────────────────────────────────────────────────────────────

_INT_FIELDS = {
    "schema_version", "player", "run_tick", "retry_count",
    "hunger", "thirst", "fatigue", "endurance",
    "zombies", "bleeding", "str", "fit",
}


def _parse_kv_line(line: str) -> dict[str, str]:
    """Split a comma-delimited key=value line into a dict."""
    result: dict[str, str] = {}
    for part in line.split(","):
        if "=" not in part:
            continue
        key, _, value = part.partition("=")
        result[key.strip()] = value.strip()
    return result


def parse_run_log(log_path: str | os.PathLike[str]) -> tuple[list[dict[str, Any]], int]:
    """Parse *auto_pilot_run.log* and return ``(entries, skipped_line_count)``.

    Each entry mirrors the key=value fields written by AutoPilot_Telemetry.lua
    (schema v2 field order):
      schema_version, player, mode, ff, run_tick,
      action, reason, class, stage, fail_reason, retry_count,
      hunger, thirst, fatigue, endurance, zombies, bleeding, str, fit

    Integer fields are coerced; empty string values (stage=, fail_reason=)
    are kept as empty strings.  A non-empty line is counted as skipped when it
    does not yield both an ``action`` label and an integer ``run_tick`` - this
    tolerates garbage, truncated writes, and rotation artifacts without
    aborting the whole file.  A missing file parses as an empty log.
    """
    path = Path(log_path)
    if not path.exists():
        return [], 0

    entries: list[dict[str, Any]] = []
    skipped = 0

    with path.open(encoding="utf-8", errors="ignore") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line:
                continue
            kv: dict[str, Any] = _parse_kv_line(line)
            for key in _INT_FIELDS:
                if key in kv:
                    try:
                        kv[key] = int(float(kv[key]))
                    except ValueError:
                        pass
            if "action" not in kv or not isinstance(kv.get("run_tick"), int):
                skipped += 1
                continue
            entries.append(kv)

    return entries, skipped


def split_sessions(entries: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    """Split parsed entries into sessions on run_tick resets, per player.

    run_tick increments by 1 per logged cycle within a session, so a line
    whose run_tick is not greater than the previous line's (for the same
    player) starts a new session.  Lines from different players (numbered
    splitscreen-era files aside, the player field is still written) are
    tracked independently but sessions are returned in file order.
    """
    sessions: list[list[dict[str, Any]]] = []
    current: dict[int, list[dict[str, Any]]] = {}   # player -> open session
    last_tick: dict[int, int] = {}                  # player -> last run_tick

    for entry in entries:
        player = entry.get("player", 0)
        if not isinstance(player, int):
            player = 0
        tick = entry["run_tick"]
        if player not in current or tick <= last_tick[player]:
            session: list[dict[str, Any]] = []
            current[player] = session
            sessions.append(session)
        current[player].append(entry)
        last_tick[player] = tick

    return sessions


# ── Summarizing ───────────────────────────────────────────────────────────────

def _session_summary(index: int, session: list[dict[str, Any]]) -> SessionSummary:
    s = SessionSummary(index=index, ticks=len(session))
    first = session[0]
    player = first.get("player", 0)
    s.player = player if isinstance(player, int) else 0
    for entry in session:
        str_val = entry.get("str")
        fit_val = entry.get("fit")
        if isinstance(str_val, int):
            if s.str_start is None:
                s.str_start = str_val
            s.str_end = str_val
        if isinstance(fit_val, int):
            if s.fit_start is None:
                s.fit_start = fit_val
            s.fit_end = fit_val
    if session[-1].get("action") == "dead":
        s.ended = "dead"
    return s


def summarize(entries: list[dict[str, Any]], skipped: int = 0) -> TriageSummary:
    """Compute a TriageSummary from parsed telemetry entries."""
    summary = TriageSummary(total_ticks=len(entries), skipped_lines=skipped)
    if not entries:
        return summary

    action_counts: Counter[str] = Counter()
    category_counts: Counter[str] = Counter()
    transitions: Counter[tuple[str, str]] = Counter()

    for index, session in enumerate(split_sessions(entries), start=1):
        summary.sessions.append(_session_summary(index, session))

        prev_action: str | None = None
        in_threat = False
        for entry in session:
            action = entry.get("action", "idle")
            action_counts[action] += 1
            category_counts[categorize_action(action)] += 1

            if prev_action is not None:
                transitions[(prev_action, action)] += 1
            prev_action = action

            if action in COMBAT_ACTIONS:
                summary.combat_ticks += 1
            if action == "dead":
                summary.deaths += 1

            zombies = entry.get("zombies", 0)
            threat = (isinstance(zombies, int) and zombies > 0) \
                or entry.get("ff") == "active"
            if threat:
                summary.threat_ticks += 1
                if not in_threat:
                    summary.threat_episodes += 1
                if isinstance(zombies, int) and zombies > summary.max_zombies:
                    summary.max_zombies = zombies
            in_threat = threat

            bleeding = entry.get("bleeding", 0)
            if isinstance(bleeding, int) and bleeding > 0:
                summary.bleeding_ticks += 1

    summary.action_counts = dict(action_counts)
    summary.category_counts = dict(category_counts)
    summary.transition_counts = dict(transitions)
    return summary


# ── Report formatting ─────────────────────────────────────────────────────────

def _pct(count: int, total: int) -> str:
    if total <= 0:
        return "  0.0%"
    return f"{100.0 * count / total:5.1f}%"


def _fmt_level(start: int | None, end: int | None) -> str:
    if start is None or end is None:
        return "n/a"
    delta = end - start
    return f"{start} -> {end} ({delta:+d})"


def format_report(summary: TriageSummary,
                  log_path: str | os.PathLike[str] = "",
                  top_n: int = 10) -> str:
    """Render a TriageSummary as a plain-text triage report."""
    n = summary.total_ticks
    lines: list[str] = []
    lines.append("=== AutoPilot run-log triage ===")
    if log_path:
        lines.append(f"Log: {log_path}")
    lines.append(
        f"Parsed {n} tick(s) across {len(summary.sessions)} session(s); "
        f"{summary.skipped_lines} malformed line(s) skipped."
    )

    lines.append("")
    lines.append("-- Action mix --")
    if summary.action_counts:
        width = max(len(a) for a in summary.action_counts)
        ordered = sorted(summary.action_counts.items(),
                         key=lambda kv: (-kv[1], kv[0]))
        for action, count in ordered:
            lines.append(f"  {action:<{width}}  {count:6d}  {_pct(count, n)}")
    else:
        lines.append("  (none)")

    lines.append("")
    lines.append(f"-- Top action transitions (top {top_n}) --")
    if summary.transition_counts:
        ordered_t = sorted(summary.transition_counts.items(),
                           key=lambda kv: (-kv[1], kv[0]))[:top_n]
        total_t = sum(summary.transition_counts.values())
        pair_width = max(len(f"{a} -> {b}") for (a, b), _ in ordered_t)
        for (prev, curr), count in ordered_t:
            pair = f"{prev} -> {curr}"
            lines.append(f"  {pair:<{pair_width}}  {count:6d}  {_pct(count, total_t)}")
    else:
        lines.append("  (none)")

    lines.append("")
    lines.append("-- Time split (ticks per category) --")
    for category in CATEGORY_ORDER:
        count = summary.category_counts.get(category, 0)
        lines.append(f"  {category:<9}  {count:6d}  {_pct(count, n)}")

    lines.append("")
    lines.append("-- Threat events --")
    lines.append(f"  threat ticks    : {summary.threat_ticks:6d}  {_pct(summary.threat_ticks, n)}")
    lines.append(f"  threat episodes : {summary.threat_episodes:6d}")
    lines.append(f"  max zombies seen: {summary.max_zombies:6d}")
    lines.append(f"  combat ticks    : {summary.combat_ticks:6d}  {_pct(summary.combat_ticks, n)}")
    lines.append(f"  bleeding ticks  : {summary.bleeding_ticks:6d}  {_pct(summary.bleeding_ticks, n)}")
    lines.append(f"  deaths          : {summary.deaths:6d}")

    lines.append("")
    lines.append("-- Sessions (STR/FIT deltas) --")
    if summary.sessions:
        for s in summary.sessions:
            lines.append(
                f"  session {s.index}: player {s.player}, {s.ticks} tick(s), "
                f"STR {_fmt_level(s.str_start, s.str_end)}, "
                f"FIT {_fmt_level(s.fit_start, s.fit_end)}, "
                f"ended: {s.ended}"
            )
    else:
        lines.append("  (none)")

    return "\n".join(lines)


# ── CLI entry point ───────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Summarize an AutoPilot telemetry run log for fast triage."
    )
    parser.add_argument(
        "log",
        nargs="?",
        default=str(DEFAULT_LOG),
        help="Path to auto_pilot_run.log (default: ~/Zomboid/Lua/auto_pilot_run.log)",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="Number of transitions to show (default: 10)",
    )
    args = parser.parse_args()

    entries, skipped = parse_run_log(args.log)
    if not entries:
        print(f"No telemetry entries found in: {args.log}")
        if skipped:
            print(f"({skipped} malformed line(s) skipped.)")
        return

    print(format_report(summarize(entries, skipped), args.log, args.top))


if __name__ == "__main__":
    main()
