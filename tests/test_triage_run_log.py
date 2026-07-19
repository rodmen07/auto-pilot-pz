"""Unit tests for triage_run_log.py - run-log parser and triage summarizer.

The main fixture (tests/fixtures/run_log_v2_sample.log) is a synthetic
schema_version=2 excerpt matching the exact line format written by
AutoPilot_Telemetry.logTick: two sessions for player 0, the first ending in a
death marker, the second still open.  Field order, empty stage=/fail_reason=
values, and the class=idle fall-through for scavenge/barricade all mirror the
real writer.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import triage_run_log as tr

FIXTURE = Path(__file__).parent / "fixtures" / "run_log_v2_sample.log"


# ── Helper ────────────────────────────────────────────────────────────────────

def _write_log(directory: str, lines: list[str]) -> Path:
    p = Path(directory) / "run.log"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


# ── parse_run_log tests ───────────────────────────────────────────────────────

class TestParseRunLog(unittest.TestCase):

    def test_missing_file_returns_empty(self) -> None:
        entries, skipped = tr.parse_run_log("does_not_exist.log")
        self.assertEqual(entries, [])
        self.assertEqual(skipped, 0)

    def test_empty_file_returns_empty(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "run.log"
            log.write_text("", encoding="utf-8")
            entries, skipped = tr.parse_run_log(log)
        self.assertEqual(entries, [])
        self.assertEqual(skipped, 0)

    def test_fixture_parses_all_lines(self) -> None:
        entries, skipped = tr.parse_run_log(FIXTURE)
        self.assertEqual(len(entries), 20)
        self.assertEqual(skipped, 0)

    def test_fixture_fields_parsed_correctly(self) -> None:
        entries, _ = tr.parse_run_log(FIXTURE)
        e = entries[0]
        self.assertEqual(e["schema_version"], 2)
        self.assertEqual(e["player"],      0)
        self.assertEqual(e["mode"],        "autopilot")
        self.assertEqual(e["ff"],          "normal")
        self.assertEqual(e["run_tick"],    1)
        self.assertEqual(e["action"],      "idle")
        self.assertEqual(e["reason"],      "no_action")
        self.assertEqual(e["class"],       "idle")
        self.assertEqual(e["stage"],       "")
        self.assertEqual(e["fail_reason"], "")
        self.assertEqual(e["retry_count"], 0)
        self.assertEqual(e["hunger"],      10)
        self.assertEqual(e["thirst"],      8)
        self.assertEqual(e["fatigue"],     12)
        self.assertEqual(e["endurance"],   95)
        self.assertEqual(e["zombies"],     0)
        self.assertEqual(e["bleeding"],    0)
        self.assertEqual(e["str"],         2)
        self.assertEqual(e["fit"],         3)

    def test_scavenge_line_carries_class_idle(self) -> None:
        """The Lua REASON_CLASS table lacks scavenge, so its lines log class=idle."""
        entries, _ = tr.parse_run_log(FIXTURE)
        scavenge = [e for e in entries if e["action"] == "scavenge"]
        self.assertEqual(len(scavenge), 1)
        self.assertEqual(scavenge[0]["class"], "idle")

    def test_tolerates_malformed_and_truncated_lines(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "not_a_kv_line",
                # Truncated write missing action / run_tick entirely
                "schema_version=2,player=0,mode=autopil",
                # Valid line in the real v2 format
                "schema_version=2,player=0,mode=autopilot,ff=normal,run_tick=1,"
                "action=idle,reason=no_action,class=idle,stage=,fail_reason=,"
                "retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=90,"
                "zombies=0,bleeding=0,str=1,fit=1",
                # run_tick present but not numeric -> skipped
                "run_tick=abc,action=eat",
                "",
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["action"], "idle")
        self.assertEqual(skipped, 3)

    def test_truncated_tail_with_action_still_parses(self) -> None:
        """A line cut off mid-write keeps its parsed prefix fields."""
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "schema_version=2,player=0,mode=autopilot,ff=normal,run_tick=3,"
                "action=eat,reason=hun",
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["action"], "eat")
        self.assertEqual(entries[0]["run_tick"], 3)
        self.assertEqual(skipped, 0)


# ── Category mapping tests ────────────────────────────────────────────────────

class TestCategoryMapping(unittest.TestCase):

    def test_training_category(self) -> None:
        self.assertEqual(tr.categorize_action("exercise"), "training")

    def test_resting_category(self) -> None:
        self.assertEqual(tr.categorize_action("sleep"), "resting")
        self.assertEqual(tr.categorize_action("rest"),  "resting")

    def test_survival_category(self) -> None:
        for action in ("eat", "drink", "shelter", "bandage", "clothing",
                       "scavenge", "barricade", "combat", "flee"):
            self.assertEqual(tr.categorize_action(action), "survival", action)

    def test_idle_category(self) -> None:
        for action in ("idle", "busy", "cooldown", "blocked", "dead"):
            self.assertEqual(tr.categorize_action(action), "idle", action)

    def test_unknown_action_maps_to_idle(self) -> None:
        self.assertEqual(tr.categorize_action("unknown_action_xyz"), "idle")


# ── split_sessions tests ──────────────────────────────────────────────────────

class TestSplitSessions(unittest.TestCase):

    def test_fixture_splits_on_run_tick_reset(self) -> None:
        entries, _ = tr.parse_run_log(FIXTURE)
        sessions = tr.split_sessions(entries)
        self.assertEqual(len(sessions), 2)
        self.assertEqual(len(sessions[0]), 14)
        self.assertEqual(len(sessions[1]), 6)
        self.assertEqual(sessions[0][-1]["action"], "dead")
        self.assertEqual(sessions[1][0]["run_tick"], 1)

    def test_no_entries_yields_no_sessions(self) -> None:
        self.assertEqual(tr.split_sessions([]), [])


# ── summarize tests ───────────────────────────────────────────────────────────

class TestSummarize(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        cls.entries, cls.skipped = tr.parse_run_log(FIXTURE)
        cls.summary = tr.summarize(cls.entries, cls.skipped)

    def test_total_ticks(self) -> None:
        self.assertEqual(self.summary.total_ticks, 20)
        self.assertEqual(self.summary.skipped_lines, 0)

    def test_action_counts(self) -> None:
        counts = self.summary.action_counts
        self.assertEqual(counts.get("exercise",  0), 7)
        self.assertEqual(counts.get("idle",      0), 2)
        self.assertEqual(counts.get("combat",    0), 2)
        self.assertEqual(counts.get("sleep",     0), 2)
        self.assertEqual(counts.get("rest",      0), 1)
        self.assertEqual(counts.get("eat",       0), 1)
        self.assertEqual(counts.get("scavenge",  0), 1)
        self.assertEqual(counts.get("bandage",   0), 1)
        self.assertEqual(counts.get("dead",      0), 1)
        self.assertEqual(counts.get("cooldown",  0), 1)
        self.assertEqual(counts.get("barricade", 0), 1)
        self.assertEqual(sum(counts.values()), 20)

    def test_category_counts(self) -> None:
        cats = self.summary.category_counts
        self.assertEqual(cats.get("training", 0), 7)
        self.assertEqual(cats.get("resting",  0), 3)   # rest + 2x sleep
        self.assertEqual(cats.get("survival", 0), 6)   # eat,bandage,2x combat,scavenge,barricade
        self.assertEqual(cats.get("idle",     0), 4)   # 2x idle, dead, cooldown
        self.assertEqual(sum(cats.values()), 20)

    def test_transitions_counted_within_sessions(self) -> None:
        t = self.summary.transition_counts
        # exercise streaks: 2 pairs in each session
        self.assertEqual(t.get(("exercise", "exercise"), 0), 4)
        # both sessions open with idle -> exercise
        self.assertEqual(t.get(("idle", "exercise"), 0), 2)
        self.assertEqual(t.get(("sleep", "dead"), 0), 1)
        # 13 pairs in session 1 + 5 pairs in session 2
        self.assertEqual(sum(t.values()), 18)

    def test_no_cross_session_transition(self) -> None:
        """The death marker must not chain into the next session's first tick."""
        self.assertNotIn(("dead", "idle"), self.summary.transition_counts)

    def test_threat_summary(self) -> None:
        s = self.summary
        self.assertEqual(s.threat_ticks,    3)   # run_tick 9, 10, 14 of session 1
        self.assertEqual(s.threat_episodes, 2)   # ticks 9-10, then tick 14
        self.assertEqual(s.max_zombies,     5)
        self.assertEqual(s.combat_ticks,    2)
        self.assertEqual(s.bleeding_ticks,  3)   # ticks 10, 11, 14
        self.assertEqual(s.deaths,          1)

    def test_session_str_fit_deltas(self) -> None:
        sessions = self.summary.sessions
        self.assertEqual(len(sessions), 2)

        s1 = sessions[0]
        self.assertEqual(s1.player,    0)
        self.assertEqual(s1.ticks,     14)
        self.assertEqual(s1.str_start, 2)
        self.assertEqual(s1.str_end,   3)
        self.assertEqual(s1.fit_start, 3)
        self.assertEqual(s1.fit_end,   3)
        self.assertEqual(s1.ended,     "dead")

        s2 = sessions[1]
        self.assertEqual(s2.ticks,     6)
        self.assertEqual(s2.str_start, 5)
        self.assertEqual(s2.str_end,   5)
        self.assertEqual(s2.fit_start, 5)
        self.assertEqual(s2.fit_end,   6)
        self.assertEqual(s2.ended,     "open")

    def test_empty_entries_summary(self) -> None:
        summary = tr.summarize([])
        self.assertEqual(summary.total_ticks, 0)
        self.assertEqual(summary.action_counts, {})
        self.assertEqual(summary.sessions, [])


# ── format_report tests ───────────────────────────────────────────────────────

class TestFormatReport(unittest.TestCase):

    def test_report_contains_all_sections(self) -> None:
        entries, skipped = tr.parse_run_log(FIXTURE)
        report = tr.format_report(tr.summarize(entries, skipped), FIXTURE)
        self.assertIn("Action mix", report)
        self.assertIn("Top action transitions", report)
        self.assertIn("Time split", report)
        self.assertIn("Threat events", report)
        self.assertIn("Sessions (STR/FIT deltas)", report)
        self.assertIn("exercise -> exercise", report)
        self.assertIn("STR 2 -> 3 (+1)", report)
        self.assertIn("FIT 5 -> 6 (+1)", report)
        self.assertIn("ended: dead", report)

    def test_empty_summary_report_does_not_raise(self) -> None:
        report = tr.format_report(tr.summarize([]))
        self.assertIn("Parsed 0 tick(s)", report)

    def test_missing_str_fit_prints_na(self) -> None:
        """Old-schema entries without str/fit fields report n/a deltas."""
        entries = [
            {"action": "idle", "run_tick": 1, "player": 0},
            {"action": "idle", "run_tick": 2, "player": 0},
        ]
        report = tr.format_report(tr.summarize(entries))
        self.assertIn("STR n/a", report)
        self.assertIn("FIT n/a", report)


if __name__ == "__main__":
    unittest.main()
