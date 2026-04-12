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


class TestActionClassMapSync(unittest.TestCase):
    """Verify _ACTION_CLASS_MAP in benchmark.py stays in sync with
    the REASON_CLASS table in AutoPilot_Telemetry.lua.

    Parses the Lua source with a simple regex rather than executing it,
    so no Lua interpreter is needed.
    """

    def _parse_lua_reason_class(self) -> set[str]:
        """Return the set of action-label keys found in the Lua REASON_CLASS table."""
        import re
        lua_path = (
            Path(__file__).parent.parent
            / "42" / "media" / "lua" / "client"
            / "AutoPilot_Telemetry.lua"
        )
        if not lua_path.exists():
            self.skipTest("AutoPilot_Telemetry.lua not found")

        text = lua_path.read_text(encoding="utf-8")
        # Match lines like:     eat        = "survival",
        pattern = re.compile(r'^\s+(\w+)\s*=\s*"(\w+)"', re.MULTILINE)

        in_table = False
        keys: set[str] = set()
        for line in text.splitlines():
            if "REASON_CLASS" in line and "=" in line and "{" in line:
                in_table = True
            if in_table:
                m = pattern.match(line)
                if m:
                    keys.add(m.group(1))
                if "}" in line and in_table and not "{" in line:
                    break
        return keys

    def test_benchmark_map_keys_match_lua_reason_class(self) -> None:
        """Every action key in the Lua REASON_CLASS table must also appear
        in benchmark._ACTION_CLASS_MAP, and vice versa."""
        import benchmark as bm
        lua_keys = self._parse_lua_reason_class()
        if not lua_keys:
            self.skipTest("Could not parse REASON_CLASS from Lua source")

        py_keys = set(bm._ACTION_CLASS_MAP.keys())
        missing_in_py  = lua_keys - py_keys
        missing_in_lua = py_keys  - lua_keys

        self.assertEqual(
            missing_in_py, set(),
            f"Keys in Lua REASON_CLASS missing from benchmark._ACTION_CLASS_MAP: {missing_in_py}",
        )
        self.assertEqual(
            missing_in_lua, set(),
            f"Keys in benchmark._ACTION_CLASS_MAP missing from Lua REASON_CLASS: {missing_in_lua}",
        )


if __name__ == "__main__":
    unittest.main()
