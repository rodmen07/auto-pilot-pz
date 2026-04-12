"""Unit tests for benchmark.py — telemetry parser and run scorer."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import benchmark as bm


# ── Helper ────────────────────────────────────────────────────────────────────

def _write_log(directory: str, lines: list[str]) -> Path:
    p = Path(directory) / "run.log"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


# ── parse_telemetry tests ─────────────────────────────────────────────────────

class TestParseTelemetry(unittest.TestCase):

    def test_missing_file_returns_empty_list(self) -> None:
        result = bm.parse_telemetry("does_not_exist.log")
        self.assertEqual(result, [])

    def test_parses_fields_correctly(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "mode=autopilot,ff=normal,run_tick=1,action=exercise,reason=idle,"
                "hunger=10,thirst=8,fatigue=15,endurance=85,zombies=0,bleeding=0,str=3,fit=3",
            ])
            entries = bm.parse_telemetry(log)

        self.assertEqual(len(entries), 1)
        e = entries[0]
        self.assertEqual(e["action"],    "exercise")
        self.assertEqual(e["reason"],    "idle")
        self.assertEqual(e["ff"],        "normal")
        self.assertEqual(e["run_tick"],  1)
        self.assertEqual(e["hunger"],    10)
        self.assertEqual(e["thirst"],    8)
        self.assertEqual(e["fatigue"],   15)
        self.assertEqual(e["endurance"], 85)
        self.assertEqual(e["zombies"],   0)
        self.assertEqual(e["bleeding"],  0)
        self.assertEqual(e["str"],       3)
        self.assertEqual(e["fit"],       3)

    def test_skips_blank_lines(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "",
                "mode=autopilot,ff=active,run_tick=2,action=combat,reason=threat,"
                "hunger=20,thirst=5,fatigue=10,endurance=70,zombies=3,bleeding=0,str=2,fit=2",
                "",
            ])
            entries = bm.parse_telemetry(log)

        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["action"], "combat")

    def test_multiple_entries_parsed_in_order(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "mode=autopilot,ff=normal,run_tick=1,action=eat,reason=hunger,"
                "hunger=30,thirst=5,fatigue=5,endurance=90,zombies=0,bleeding=0,str=1,fit=1",
                "mode=autopilot,ff=normal,run_tick=2,action=drink,reason=thirst,"
                "hunger=5,thirst=25,fatigue=5,endurance=90,zombies=0,bleeding=0,str=1,fit=1",
                "mode=autopilot,ff=active,run_tick=3,action=combat,reason=threat,"
                "hunger=5,thirst=5,fatigue=5,endurance=90,zombies=2,bleeding=1,str=1,fit=1",
            ])
            entries = bm.parse_telemetry(log)

        self.assertEqual(len(entries), 3)
        self.assertEqual(entries[0]["action"], "eat")
        self.assertEqual(entries[1]["action"], "drink")
        self.assertEqual(entries[2]["action"], "combat")
        self.assertEqual(entries[2]["zombies"], 2)
        self.assertEqual(entries[2]["bleeding"], 1)

    def test_tolerates_malformed_lines(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "not_a_kv_line",
                "mode=autopilot,ff=normal,run_tick=1,action=idle,reason=no_action,"
                "hunger=5,thirst=5,fatigue=5,endurance=90,zombies=0,bleeding=0,str=1,fit=1",
            ])
            entries = bm.parse_telemetry(log)

        # Malformed line produces a partial entry (no meaningful keys), valid line parses
        valid = [e for e in entries if e.get("action") == "idle"]
        self.assertEqual(len(valid), 1)


# ── score_run tests ───────────────────────────────────────────────────────────

class TestScoreRun(unittest.TestCase):

    def test_empty_entries_returns_zero_result(self) -> None:
        result = bm.score_run([])
        self.assertEqual(result.total_ticks, 0)
        self.assertEqual(result.score, 0.0)

    def test_total_ticks_matches_entry_count(self) -> None:
        entries = [
            {"action": "idle",    "ff": "normal", "hunger": 5,  "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
            {"action": "exercise","ff": "normal", "hunger": 10, "thirst": 10,
             "fatigue": 10, "endurance": 80, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
        ]
        result = bm.score_run(entries)
        self.assertEqual(result.total_ticks, 2)

    def test_combat_rate_counts_ff_active(self) -> None:
        entries = [
            {"action": "combat", "ff": "active",  "hunger": 5,  "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 2, "bleeding": 0,
             "str": 1, "fit": 1},
            {"action": "idle",   "ff": "normal",  "hunger": 5,  "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
            {"action": "combat", "ff": "active",  "hunger": 5,  "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 1, "bleeding": 0,
             "str": 1, "fit": 1},
            {"action": "idle",   "ff": "normal",  "hunger": 5,  "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
        ]
        result = bm.score_run(entries)
        self.assertAlmostEqual(result.combat_rate, 0.5)

    def test_injury_rate_counts_bleeding_ticks(self) -> None:
        entries = [
            {"action": "bandage", "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 2,
             "str": 1, "fit": 1},
            {"action": "idle",    "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
        ]
        result = bm.score_run(entries)
        self.assertAlmostEqual(result.injury_rate, 0.5)

    def test_hunger_pressure_threshold(self) -> None:
        entries = [
            # hunger=25 ≥ 20 → pressure tick
            {"action": "eat",  "ff": "normal", "hunger": 25, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
            # hunger=10 < 20 → no pressure
            {"action": "idle", "ff": "normal", "hunger": 10, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
        ]
        result = bm.score_run(entries)
        self.assertAlmostEqual(result.hunger_pressure, 0.5)

    def test_exercise_rate(self) -> None:
        entries = [
            {"action": "exercise", "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 3, "fit": 3},
            {"action": "exercise", "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 85, "zombies": 0, "bleeding": 0,
             "str": 3, "fit": 3},
            {"action": "idle",     "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 70, "zombies": 0, "bleeding": 0,
             "str": 3, "fit": 3},
            {"action": "idle",     "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 65, "zombies": 0, "bleeding": 0,
             "str": 3, "fit": 3},
        ]
        result = bm.score_run(entries)
        self.assertEqual(result.exercise_ticks, 2)
        self.assertAlmostEqual(result.exercise_rate, 0.5)

    def test_action_counts_and_fractions(self) -> None:
        entries = [
            {"action": "eat",  "ff": "normal", "hunger": 30, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
            {"action": "eat",  "ff": "normal", "hunger": 25, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
            {"action": "idle", "ff": "normal", "hunger": 5,  "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
            {"action": "idle", "ff": "normal", "hunger": 5,  "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
        ]
        result = bm.score_run(entries)
        self.assertEqual(result.action_counts.get("eat",  0), 2)
        self.assertEqual(result.action_counts.get("idle", 0), 2)
        self.assertAlmostEqual(result.action_fractions.get("eat",  0.0), 0.5)
        self.assertAlmostEqual(result.action_fractions.get("idle", 0.0), 0.5)

    def test_score_penalises_death(self) -> None:
        entries = [
            {"action": "idle", "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
        ] * 100
        alive_result = bm.score_run(entries, end_status="timeout")
        dead_result  = bm.score_run(entries, end_status="dead")
        self.assertGreater(alive_result.score, dead_result.score)

    def test_score_penalises_injury_time(self) -> None:
        healthy_entry = {"action": "idle", "ff": "normal", "hunger": 5, "thirst": 5,
                         "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
                         "str": 1, "fit": 1}
        injured_entry = {"action": "idle", "ff": "normal", "hunger": 5, "thirst": 5,
                         "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 2,
                         "str": 1, "fit": 1}
        healthy = bm.score_run([healthy_entry] * 100, end_status="timeout")
        injured = bm.score_run([injured_entry] * 100, end_status="timeout")
        self.assertGreater(healthy.score, injured.score)

    def test_skill_start_end_tracking(self) -> None:
        entries = [
            {"action": "exercise", "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 2, "fit": 2},
            {"action": "exercise", "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 85, "zombies": 0, "bleeding": 0,
             "str": 2, "fit": 2},
            {"action": "exercise", "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 80, "zombies": 0, "bleeding": 0,
             "str": 3, "fit": 2},
        ]
        result = bm.score_run(entries)
        self.assertEqual(result.str_start, 2)
        self.assertEqual(result.str_end,   3)
        self.assertEqual(result.fit_start, 2)
        self.assertEqual(result.fit_end,   2)


# ── write_benchmark tests ─────────────────────────────────────────────────────

class TestWriteBenchmark(unittest.TestCase):

    def test_output_is_valid_json(self) -> None:
        result = bm.score_run([
            {"action": "idle", "ff": "normal", "hunger": 5, "thirst": 5,
             "fatigue": 5, "endurance": 90, "zombies": 0, "bleeding": 0,
             "str": 1, "fit": 1},
        ])
        with tempfile.TemporaryDirectory() as td:
            out_path = Path(td) / "benchmark.json"
            bm.write_benchmark(result, out_path)
            data = json.loads(out_path.read_text(encoding="utf-8"))

        self.assertIn("total_ticks",   data)
        self.assertIn("score",         data)
        self.assertIn("action_counts", data)
        self.assertIn("combat_rate",   data)
        self.assertIn("injury_rate",   data)
        self.assertEqual(data["total_ticks"], 1)

    def test_roundtrip_preserves_values(self) -> None:
        entries = [
            {"action": "exercise", "ff": "normal", "hunger": 10, "thirst": 10,
             "fatigue": 10, "endurance": 80, "zombies": 0, "bleeding": 0,
             "str": 4, "fit": 3},
        ] * 50
        result = bm.score_run(entries, end_status="timeout")
        with tempfile.TemporaryDirectory() as td:
            out_path = Path(td) / "bm.json"
            bm.write_benchmark(result, out_path)
            data = json.loads(out_path.read_text(encoding="utf-8"))

        self.assertEqual(data["total_ticks"],   50)
        self.assertEqual(data["end_status"],    "timeout")
        self.assertEqual(data["exercise_ticks"], 50)
        self.assertAlmostEqual(data["exercise_rate"], 1.0)


if __name__ == "__main__":
    unittest.main()
