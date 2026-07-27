"""``check.sh`` must not report success when a suite silently skipped.

``check.sh`` is the local half of the verification gate (``ci.yml`` runs the
same suites as individual jobs steps).  Before this test existed it could print
``All checks passed`` and exit 0 after skipping luacheck, the Lua logic suites,
AND pytest entirely: every tool-discovery miss printed ``SKIP`` with install
instructions and then fell through to a green summary.  On a Windows shell
without ``python`` on the Bash PATH it did exactly that on every single run,
which is this repo's named top defect class -- a gate surface that silently
does nothing (same rule as the Action pin guard's zero-input hard-fail and the
release-gate tests' ``_require_bash``).

The contract pinned here:

* a run that SKIPPED any suite exits non-zero by default and does not print
  ``All checks passed``;
* ``CHECK_ALLOW_SKIP=1`` is the explicit, visible escape hatch: the run exits 0
  but labels itself a degraded run, never a full pass.

``CHECK_SIMULATE_MISSING`` is a test hook inside ``check.sh`` that forces the
tool-discovery paths to treat the named tools (``luacheck``, ``lua``,
``python``) as absent.  It can only simulate ABSENCE -- it cannot make a
missing tool look present -- so it cannot weaken a passing gate.  Simulating
``python`` as missing also guarantees ``check.sh`` never recursively invokes
the very pytest run executing this module.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent
CHECK_SH = ROOT / "check.sh"
BASH = shutil.which("bash")

#: Simulate every discoverable tool as missing: only the pure-grep guards
#: (Static API Guard, line-count guard) can run, and all three suites skip.
ALL_TOOLS_MISSING = "luacheck lua python"


def _require_bash() -> str:
    """Return the bash to run check.sh with, or fail loudly.

    Same rule as ``test_release_gate.py``: a missing bash on a POSIX runner is
    a broken CI environment, not a reason to skip.
    """
    if BASH:
        return BASH
    if sys.platform == "win32":
        raise unittest.SkipTest(
            "bash is not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        "bash not found on a POSIX runner: the check.sh tests must not skip in CI."
    )


def run_check_sh(extra_env: dict[str, str]) -> subprocess.CompletedProcess:
    """Run ``check.sh`` from the repo root with a controlled gate environment."""
    env = os.environ.copy()
    # Never inherit these from the caller's shell: the whole point is that each
    # test states its own gate configuration explicitly.
    env.pop("CHECK_ALLOW_SKIP", None)
    env.pop("CHECK_SIMULATE_MISSING", None)
    env.update(extra_env)
    return subprocess.run(
        [_require_bash(), str(CHECK_SH)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=300,
    )


class TestSkippedSuitesFailByDefault(unittest.TestCase):
    """The old script exited 0 with 'All checks passed' on an all-skipped run."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.result = run_check_sh({"CHECK_SIMULATE_MISSING": ALL_TOOLS_MISSING})

    def test_exit_code_is_nonzero(self) -> None:
        self.assertNotEqual(
            self.result.returncode,
            0,
            "check.sh skipped every suite yet exited 0 -- the gate silently "
            f"did nothing.\nstdout:\n{self.result.stdout}",
        )

    def test_summary_counts_the_skips(self) -> None:
        self.assertIn(
            "3 skipped",
            self.result.stdout,
            "the summary line must count skipped suites so a degraded run is "
            f"visible at a glance.\nstdout:\n{self.result.stdout}",
        )

    def test_no_full_pass_banner(self) -> None:
        self.assertNotIn(
            "All checks passed",
            self.result.stdout,
            "an all-skipped run must never print the full-pass banner.\n"
            f"stdout:\n{self.result.stdout}",
        )

    def test_pytest_suite_reported_as_skipped_not_run(self) -> None:
        """The simulation hook proves absence-only: pytest must not have run."""
        self.assertIn("SKIP  pytest", self.result.stdout)
        self.assertNotIn("=== test session starts ===", self.result.stdout)


class TestAllowSkipEscapeHatch(unittest.TestCase):
    """CHECK_ALLOW_SKIP=1 is the deliberate degraded mode: exit 0, labelled."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.result = run_check_sh(
            {
                "CHECK_SIMULATE_MISSING": ALL_TOOLS_MISSING,
                "CHECK_ALLOW_SKIP": "1",
            }
        )

    def test_exit_code_is_zero(self) -> None:
        self.assertEqual(
            self.result.returncode,
            0,
            "CHECK_ALLOW_SKIP=1 must accept a degraded run.\n"
            f"stdout:\n{self.result.stdout}\nstderr:\n{self.result.stderr}",
        )

    def test_degraded_run_is_labelled(self) -> None:
        self.assertIn(
            "degraded run",
            self.result.stdout,
            "the escape hatch must label the run as degraded, not as a full "
            f"pass.\nstdout:\n{self.result.stdout}",
        )

    def test_no_full_pass_banner_even_when_allowed(self) -> None:
        self.assertNotIn(
            "All checks passed",
            self.result.stdout,
            "a degraded run must never print the full-pass banner, even when "
            f"accepted.\nstdout:\n{self.result.stdout}",
        )


if __name__ == "__main__":
    unittest.main()
