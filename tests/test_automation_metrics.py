"""Unit tests for automation/tuning metrics helpers.

These tests exercise pure-Python logic without launching the game.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import auto_tune
import automate


class TestAutomateParseRunLog(unittest.TestCase):
    def test_parse_run_log_missing_file(self) -> None:
        result = automate.parse_run_log("does_not_exist.log")
        self.assertEqual(result["lines"], 0)
        self.assertEqual(result["ff_active_lines"], 0)
        self.assertEqual(result["ff_normal_lines"], 0)
        self.assertEqual(result["ff_unknown_lines"], 0)
        self.assertEqual(result["ff_active_ratio"], 0.0)
        self.assertEqual(result["max_run_tick"], 0)
        self.assertEqual(result["action_counts"], {})

    def test_parse_run_log_counts_states_and_max_tick(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            run_log = Path(td) / "run.log"
            run_log.write_text(
                "mode=autopilot,ff=active,run_tick=12\n"
                "mode=autopilot,ff=normal,run_tick=48\n"
                "mode=autopilot,run_tick=5\n",
                encoding="utf-8",
            )
            result = automate.parse_run_log(str(run_log))

        self.assertEqual(result["lines"], 3)
        self.assertEqual(result["ff_active_lines"], 1)
        self.assertEqual(result["ff_normal_lines"], 1)
        self.assertEqual(result["ff_unknown_lines"], 1)
        self.assertEqual(result["max_run_tick"], 48)
        self.assertEqual(result["ff_active_ratio"], 0.5)

    def test_parse_run_log_counts_actions(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            run_log = Path(td) / "run.log"
            run_log.write_text(
                "mode=autopilot,ff=normal,run_tick=1,action=exercise,reason=idle,"
                "hunger=5,thirst=5,fatigue=5,endurance=90,zombies=0,bleeding=0,str=3,fit=3\n"
                "mode=autopilot,ff=normal,run_tick=2,action=exercise,reason=idle,"
                "hunger=5,thirst=5,fatigue=5,endurance=85,zombies=0,bleeding=0,str=3,fit=3\n"
                "mode=autopilot,ff=normal,run_tick=3,action=eat,reason=hunger_thresh,"
                "hunger=25,thirst=5,fatigue=5,endurance=90,zombies=0,bleeding=0,str=3,fit=3\n"
                "mode=autopilot,ff=active,run_tick=4,action=combat,reason=threat,"
                "hunger=5,thirst=5,fatigue=5,endurance=90,zombies=2,bleeding=0,str=3,fit=3\n",
                encoding="utf-8",
            )
            result = automate.parse_run_log(str(run_log))

        self.assertEqual(result["action_counts"].get("exercise", 0), 2)
        self.assertEqual(result["action_counts"].get("eat",      0), 1)
        self.assertEqual(result["action_counts"].get("combat",   0), 1)
        self.assertEqual(result["max_run_tick"], 4)
        self.assertEqual(result["ff_active_lines"], 1)


class TestAutoTuneEvaluateSummary(unittest.TestCase):
    def test_evaluate_summary_empty(self) -> None:
        mean_ticks, deaths, ff_mean, timeouts, total = auto_tune.evaluate_summary(None)
        self.assertEqual((mean_ticks, deaths, ff_mean, timeouts, total), (0, 0, 0.0, 0, 0))

    def test_evaluate_summary_mixed_statuses(self) -> None:
        summary = {
            "results": [
                {"status": "dead", "ticks": 100, "ff_active_ratio": 1.0},
                {"status": "timeout", "elapsed_seconds": 300, "ff_active_ratio": 0.0},
                {"status": "ok", "ticks": 200, "ff_active_ratio": 0.5},
            ]
        }
        mean_ticks, deaths, ff_mean, timeouts, total = auto_tune.evaluate_summary(summary)
        self.assertEqual(total, 3)
        self.assertEqual(deaths, 1)
        self.assertEqual(timeouts, 1)
        self.assertAlmostEqual(mean_ticks, (100 + 300 + 200) / 3)
        self.assertAlmostEqual(ff_mean, (1.0 + 0.0 + 0.5) / 3)


if __name__ == "__main__":
    unittest.main()
