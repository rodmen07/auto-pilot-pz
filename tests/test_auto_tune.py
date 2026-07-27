"""First coverage for auto_tune.py's mutation and persistence layer.

auto_tune.py has carried tests for exactly one function (evaluate_summary,
in test_automation_metrics.py) since 2026-03-23. Everything else -- the
regex-driven rewrite of AutoPilot_Constants.lua, the backup/restore pair,
the results persistence, and the best-score selection that decides what a
whole grid of real game runs was FOR -- has never been executed by a test.

Everything here runs headlessly: no game launch, no automate.py subprocess.
Write-path tests operate on a COPY of the real AutoPilot_Constants.lua in a
temp dir, with auto_tune's module-level paths patched for the duration.

Drift guard (reads BOTH sources): TestConstantsPatternsDriftGuard imports
auto_tune's own compiled patterns and runs them against the real production
Constants file. write_needs/write_threat rewrite only lines their patterns
match and silently no-op otherwise, so a rename or reshape of those three
assignments would make the tuner mutate nothing while burning real game
runs; this guard turns that silent no-op into a red build.

Regression proof (negative-score selection): score is
mean_ticks - 50*deaths - 100*timeouts and can be legitimately negative
(one early death against a short run does it). init_best_from_results and
main() both compared against a numeric sentinel of -1, so a negative score
could NEVER become best: an all-negative grid reported params=None after
burning every run. The all-negative tests here fail against that code.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import auto_tune

REAL_CONSTANTS = Path(auto_tune.CONSTANTS_FILE)


class TestConstantsPatternsDriftGuard(unittest.TestCase):
    """auto_tune's three rewrite patterns must keep matching the real file.

    Both sources are read live: the compiled patterns from auto_tune itself
    (not a restated copy) and the production AutoPilot_Constants.lua.
    """

    PATTERNS = {
        "THIRST_THRESHOLD": auto_tune.pattern_thirst,
        "HUNGER_THRESHOLD": auto_tune.pattern_hunger,
        "FLEE_MOODLE_LIMIT": auto_tune.pattern_flee,
    }

    def test_constants_file_exists_and_is_nonempty(self) -> None:
        # Hard-fail, never skip: a missing Constants file means the guard
        # below would vacuously pass on zero lines.
        self.assertTrue(
            REAL_CONSTANTS.exists(),
            f"{REAL_CONSTANTS} not found; the drift guard has gone blind",
        )
        self.assertGreater(len(REAL_CONSTANTS.read_text(encoding="utf-8")), 0)

    def test_each_pattern_matches_exactly_one_line(self) -> None:
        lines = REAL_CONSTANTS.read_text(encoding="utf-8").splitlines()
        for name, pattern in self.PATTERNS.items():
            matches = [ln for ln in lines if pattern.match(ln)]
            self.assertEqual(
                len(matches), 1,
                f"auto_tune's {name} pattern matched {len(matches)} lines in "
                f"{REAL_CONSTANTS.name} (want exactly 1). write_needs/"
                f"write_threat would silently no-op and the tuner would burn "
                f"game runs while mutating nothing.",
            )

    def test_rewrite_is_lossless_beyond_the_value(self) -> None:
        # write_needs/write_threat replace a matched line with
        # prefix + new value + newline, DISCARDING anything after the value.
        # Today the three lines carry nothing after the value; if a trailing
        # comment is ever added, this fails so the rewrite is updated
        # consciously instead of deleting the comment silently.
        lines = REAL_CONSTANTS.read_text(encoding="utf-8").splitlines()
        for name, pattern in self.PATTERNS.items():
            for ln in lines:
                m = pattern.match(ln)
                if m:
                    rest = ln[m.end(2):].strip()
                    self.assertEqual(
                        rest, "",
                        f"{name} line carries trailing content {rest!r} that "
                        f"auto_tune's rewrite would silently delete",
                    )


class _TmpPathsMixin(unittest.TestCase):
    """Patch auto_tune's module-level paths into a temp dir with a copy of
    the real Constants file."""

    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        tmp = Path(self._td.name)
        self.constants = tmp / "AutoPilot_Constants.lua"
        shutil.copyfile(REAL_CONSTANTS, self.constants)
        self.backup = tmp / "AutoPilot_Constants.lua.bak"
        self.results = tmp / "auto_tune_results.json"
        for attr, value in (
            ("CONSTANTS_FILE", str(self.constants)),
            ("BACKUP_CONSTANTS", str(self.backup)),
            ("RESULT_FILE", str(self.results)),
        ):
            patcher = mock.patch.object(auto_tune, attr, value)
            patcher.start()
            self.addCleanup(patcher.stop)


class TestWritePaths(_TmpPathsMixin):
    def _lines(self) -> list[str]:
        return self.constants.read_text(encoding="utf-8").splitlines()

    def test_write_needs_rewrites_both_thresholds_and_nothing_else(self) -> None:
        before = self._lines()
        auto_tune.write_needs(0.11, 0.27)
        after = self._lines()
        self.assertEqual(len(before), len(after))
        changed = [
            (b, a) for b, a in zip(before, after) if b != a
        ]
        self.assertEqual(
            len(changed), 2,
            f"write_needs must change exactly the two threshold lines, "
            f"changed: {changed}",
        )
        joined = "\n".join(a for _, a in changed)
        self.assertIn("THIRST_THRESHOLD = 0.11", joined)
        self.assertIn("HUNGER_THRESHOLD = 0.27", joined)

    def test_write_threat_rewrites_flee_limit_only(self) -> None:
        before = self._lines()
        auto_tune.write_threat(3)
        after = self._lines()
        changed = [(b, a) for b, a in zip(before, after) if b != a]
        self.assertEqual(len(changed), 1, f"changed: {changed}")
        self.assertIn("FLEE_MOODLE_LIMIT = 3", changed[0][1])

    def test_backup_then_restore_round_trips_bytes(self) -> None:
        original = self.constants.read_bytes()
        auto_tune.backup_files()
        auto_tune.write_needs(0.11, 0.27)
        auto_tune.write_threat(3)
        self.assertNotEqual(self.constants.read_bytes(), original)
        auto_tune.restore_files()
        self.assertEqual(self.constants.read_bytes(), original)

    def test_restore_without_backup_raises(self) -> None:
        with self.assertRaises(FileNotFoundError):
            auto_tune.restore_files()


class TestResultsPersistence(_TmpPathsMixin):
    def test_load_missing_file_returns_empty_list(self) -> None:
        self.assertEqual(auto_tune.load_tune_results(), [])

    def test_save_then_load_round_trips_all(self) -> None:
        all_results = [
            {"thirst": 0.12, "hunger": 0.16, "flee_moodle_limit": 2,
             "score": 10, "incomplete": False},
        ]
        best = {"score": 10, "params": (0.12, 0.16, 2),
                "result": all_results[0]}
        auto_tune.save_tune_results(best, all_results)
        self.assertEqual(auto_tune.load_tune_results(), all_results)
        saved = json.loads(self.results.read_text(encoding="utf-8"))
        self.assertEqual(saved["best"]["score"], 10)


class TestInitBestFromResults(unittest.TestCase):
    @staticmethod
    def _entry(score, thirst=0.12, hunger=0.16, flee=2, **extra):
        entry = {
            "thirst": thirst, "hunger": hunger, "flee_moodle_limit": flee,
            "score": score,
        }
        entry.update(extra)
        return entry

    def test_picks_highest_score(self) -> None:
        best = auto_tune.init_best_from_results([
            self._entry(10), self._entry(30, thirst=0.24), self._entry(20),
        ])
        self.assertEqual(best["score"], 30)
        self.assertEqual(best["params"], (0.24, 0.16, 2))

    def test_skips_score_none(self) -> None:
        best = auto_tune.init_best_from_results([
            self._entry(None, incomplete=True), self._entry(5),
        ])
        self.assertEqual(best["score"], 5)

    def test_all_negative_scores_still_select_a_best(self) -> None:
        # Regression: score = mean_ticks - 50*deaths - 100*timeouts goes
        # negative on early deaths. The old -1 sentinel discarded every
        # negative score, so a resumed all-negative grid reported
        # params=None. Fails against the pre-fix code.
        best = auto_tune.init_best_from_results([
            self._entry(-300), self._entry(-30, hunger=0.24),
            self._entry(-120),
        ])
        self.assertEqual(best["score"], -30)
        self.assertEqual(best["params"], (0.12, 0.24, 2))

    def test_incomplete_entries_never_become_best(self) -> None:
        # main() refuses to let an incomplete (timeout-tainted) tuple become
        # best; the resume path must apply the same rule or a crashy tuple
        # wins after a restart. Fails against the pre-fix code.
        best = auto_tune.init_best_from_results([
            self._entry(999, incomplete=True), self._entry(5),
        ])
        self.assertEqual(best["score"], 5)

    def test_empty_results_yield_no_best(self) -> None:
        best = auto_tune.init_best_from_results([])
        self.assertIsNone(best["score"])
        self.assertIsNone(best["params"])


class TestMainLoopSelection(_TmpPathsMixin):
    """First coverage for main()'s grid/resume/selection glue, fully stubbed:
    run_automate and load_summary are replaced, so no game and no subprocess.
    """

    def setUp(self) -> None:
        super().setUp()
        for attr, value in (
            ("THIRST_RANGE", [0.11]),
            ("HUNGER_RANGE", [0.27]),
            ("FLEE_MOODLE_RANGE", [3]),
        ):
            patcher = mock.patch.object(auto_tune, attr, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_negative_score_grid_still_reports_a_best(self) -> None:
        # One tuple, one dead-at-tick-40 run: score = 40 - 50 = -10.
        # Fails against the pre-fix code (best stays params=None at -1).
        summary = {"results": [
            {"status": "dead", "ticks": 40, "ff_active_ratio": 0.0},
        ]}
        original = self.constants.read_bytes()
        with mock.patch.object(auto_tune, "run_automate", return_value=True), \
                mock.patch.object(auto_tune, "load_summary",
                                  return_value=summary):
            auto_tune.main()
        saved = json.loads(self.results.read_text(encoding="utf-8"))
        self.assertEqual(saved["best"]["score"], -10)
        self.assertEqual(saved["best"]["params"], [0.11, 0.27, 3])
        # The finally-clause restore must leave the constants byte-identical.
        self.assertEqual(self.constants.read_bytes(), original)

    def test_resume_skips_completed_tuples_without_rerunning(self) -> None:
        # On a fully-resumed grid main() never re-saves the result file
        # (the save sits inside the non-skipped branch), so the re-derived
        # best is observable only on stdout. That quirk is asserted here
        # deliberately: if a refresh-save is ever added, update this test.
        seeded = [{
            "thirst": 0.11, "hunger": 0.27, "flee_moodle_limit": 3,
            "score": 10, "incomplete": False,
        }]
        auto_tune.save_tune_results({"score": None, "params": None,
                                     "result": None}, seeded)
        before_on_disk = self.results.read_text(encoding="utf-8")
        out = io.StringIO()
        with mock.patch.object(auto_tune, "run_automate",
                               return_value=True) as run_stub, \
                mock.patch.object(auto_tune, "load_summary",
                                  return_value=None), \
                contextlib.redirect_stdout(out):
            auto_tune.main()
        run_stub.assert_not_called()
        # The resume path re-derived the seeded entry as best (score 10).
        # Fails against the pre-fix code only in the all-negative variant;
        # here it pins that resume selection works at all.
        self.assertIn("'score': 10", out.getvalue())
        self.assertIn("(0.11, 0.27, 3)", out.getvalue())
        self.assertEqual(self.results.read_text(encoding="utf-8"),
                         before_on_disk)

    def test_missing_summary_marks_tuple_incomplete_not_best(self) -> None:
        with mock.patch.object(auto_tune, "run_automate", return_value=True), \
                mock.patch.object(auto_tune, "load_summary",
                                  return_value=None):
            auto_tune.main()
        saved = json.loads(self.results.read_text(encoding="utf-8"))
        self.assertIsNone(saved["best"]["score"])
        self.assertIsNone(saved["best"]["params"])
        self.assertEqual(len(saved["all"]), 1)
        self.assertTrue(saved["all"][0]["incomplete"])
        self.assertEqual(saved["all"][0]["failure"], "missing_summary")


if __name__ == "__main__":
    unittest.main()
