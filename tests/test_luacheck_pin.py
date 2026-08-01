"""The luacheck pin, and the guard that keeps it honest.

``.github/workflows/ci.yml`` used to install the Lua linter like this::

    sudo luarocks install luacheck

That is not an install, it is a subscription: luarocks serves whatever the
newest published rock happens to be on the morning the job runs.  Two concrete
costs, both silent:

* **An unrelated pull request can go red overnight.**  luacheck ships new
  checks in minor releases, so a release published between two runs can fail a
  branch whose diff never touched the flagged code.  Nothing in the repository
  would record that the linter changed.
* **Local runs and CI can disagree about the same file.**  ``check.sh`` uses
  whatever this box installed (scoop on Windows, luarocks elsewhere) while CI
  used whatever it downloaded, so "0 warnings locally" was never evidence about
  the linter that actually gates the merge.

The workflow now declares ``LUACHECK_VERSION`` once at job level, installs that
exact version, and then asserts that the binary which will do the linting really
reports it.  This module is the guard on the guard: it reads the pin out of the
yaml and **executes the real "Luacheck pin guard" script** against fake
``luacheck`` binaries in both directions, so the guard cannot rot into an inert
step the way ``release.yml``'s version gate did (see
:mod:`tests.test_release_gate`) and the way the unversioned install itself did.

Same drift-guard shape as :mod:`tests.test_changelog_guard`: the workflow stays
the single source of truth and the test extracts from it rather than restating
it.  ``check.sh``'s local-vs-CI notice is held to the same rule -- it derives the
pin from the workflow, and the last test here runs check.sh's own extraction and
asserts it agrees with what the yaml declares, so the two can never drift apart.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from test_release_gate import extract_step_script, step_names  # noqa: E402

ROOT = Path(__file__).parent.parent
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
CHECK_SH = ROOT / "check.sh"

INSTALL_STEP = "Install Lua and luacheck"
GUARD_STEP = "Luacheck pin guard"
LINT_STEP = "Lua lint"

BASH = shutil.which("bash")

# A concrete release, not a range, not "latest", not a rockspec revision alone.
CONCRETE_VERSION = re.compile(r"^\d+\.\d+(\.\d+)?$")

# The job-level declaration, e.g. `      LUACHECK_VERSION: "1.2.0"`.  Anchored to
# a whole line so the guard script's own `${LUACHECK_VERSION:-}` reference and
# the surrounding prose can never be mistaken for the declaration.  Text rather
# than a yaml parse on purpose: this repo's Python surface is stdlib-only (the
# single dev dependency is pytest), which is a deliberate DevSecOps posture, and
# reading one scalar does not justify widening it.  The yaml is validated by
# GitHub itself on every run of this workflow.
PIN_DECLARATION = re.compile(
    r'^[ \t]+LUACHECK_VERSION:[ \t]*"?(?P<version>[^"\s#]+)"?[ \t]*(?:#.*)?$',
    re.M,
)


def _workflow_text() -> str:
    return CI_WORKFLOW.read_text(encoding="utf-8")


def _pinned_version() -> str:
    """The pin, read from the workflow -- the single place it is declared."""
    matches = PIN_DECLARATION.findall(_workflow_text())
    if len(matches) != 1:
        raise AssertionError(
            f"expected exactly one LUACHECK_VERSION declaration in {CI_WORKFLOW.name}, "
            f"found {len(matches)}: {matches!r}. More than one is a second source "
            "of truth; none means the pin is gone."
        )
    return matches[0]


def _require_bash() -> str:
    if BASH:
        return BASH
    if sys.platform == "win32":
        raise unittest.SkipTest(
            "bash not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        "bash not found on a POSIX runner: the luacheck pin guard must not skip in CI."
    )


def _run_guard(fake_version_output: str | None, pin: str | None) -> subprocess.CompletedProcess:
    """Execute the real guard script with a fake ``luacheck`` on PATH.

    ``fake_version_output`` is what the fake prints for ``--version``.  ``None``
    means print nothing at all, which is the same empty-``RAW`` branch a
    genuinely missing binary lands in (``luacheck --version 2>/dev/null`` inside
    ``$( ... || true )`` yields an empty string either way).
    """
    bash = _require_bash()
    script = extract_step_script(_workflow_text(), GUARD_STEP)

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        fake = tmpdir / "luacheck"
        body = "" if fake_version_output is None else fake_version_output
        fake.write_text(
            "#!/usr/bin/env bash\n" + "".join(f"echo '{line}'\n" for line in body.splitlines()),
            encoding="utf-8",
            newline="\n",
        )
        fake.chmod(0o755)

        script_path = tmpdir / "guard.sh"
        script_path.write_text(script, encoding="utf-8", newline="\n")

        env = dict(os.environ)
        env["PATH"] = f"{tmpdir}{os.pathsep}{env.get('PATH', '')}"
        if pin is None:
            env.pop("LUACHECK_VERSION", None)
        else:
            env["LUACHECK_VERSION"] = pin

        return subprocess.run(
            [bash, "-e", str(script_path)],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(ROOT),
        )


class TestThePinItself(unittest.TestCase):
    """The workflow must name one concrete version, in one place."""

    def test_job_declares_a_concrete_pin(self) -> None:
        pin = _pinned_version()
        self.assertRegex(
            pin,
            CONCRETE_VERSION,
            f"LUACHECK_VERSION is {pin!r}: the pin must be a concrete release "
            "(e.g. '1.2.0'), never a range or a moving alias.",
        )

    def test_install_step_installs_the_pinned_version(self) -> None:
        script = extract_step_script(_workflow_text(), INSTALL_STEP)
        self.assertIn(
            'luarocks install luacheck "${LUACHECK_VERSION}"',
            script,
            "the install step must pass the pin to luarocks.",
        )

    def test_install_step_has_no_unversioned_install_left(self) -> None:
        script = extract_step_script(_workflow_text(), INSTALL_STEP)
        bare = [
            line
            for line in script.splitlines()
            if re.match(r"^\s*(sudo\s+)?luarocks\s+install\s+luacheck\s*$", line)
        ]
        self.assertEqual(
            [],
            bare,
            "an unversioned 'luarocks install luacheck' installs whatever "
            "luarocks serves that day; that is the defect this pin removes.",
        )

    def test_guard_runs_between_the_install_and_the_lint(self) -> None:
        names = step_names(_workflow_text())
        for name in (INSTALL_STEP, GUARD_STEP, LINT_STEP):
            self.assertIn(name, names, f"step {name!r} is missing from ci.yml")
        self.assertLess(
            names.index(INSTALL_STEP),
            names.index(GUARD_STEP),
            "the guard must run after the install, or it checks nothing.",
        )
        self.assertLess(
            names.index(GUARD_STEP),
            names.index(LINT_STEP),
            "the guard must run before the lint, so a drifted linter never "
            "gets to render a verdict on the code.",
        )


class TestGuardBehaviourDifference(unittest.TestCase):
    """The guard's real script, executed in both directions."""

    def test_passes_when_the_installed_version_matches_the_pin(self) -> None:
        pin = _pinned_version()
        result = _run_guard(f"Luacheck: {pin}\nLua: PUC-Rio Lua 5.1", pin)
        self.assertEqual(
            0, result.returncode, f"guard failed on a matching version:\n{result.stdout}"
        )
        self.assertIn("Luacheck pin guard PASSED", result.stdout)

    def test_fails_when_the_installed_version_differs(self) -> None:
        pin = _pinned_version()
        drifted = "9.9.9"
        self.assertNotEqual(pin, drifted)
        result = _run_guard(f"Luacheck: {drifted}\nLua: PUC-Rio Lua 5.1", pin)
        self.assertEqual(
            1, result.returncode, f"guard passed a drifted linter:\n{result.stdout}"
        )
        self.assertIn("Luacheck pin guard FAILED", result.stdout)
        self.assertIn(drifted, result.stdout)
        self.assertIn(pin, result.stdout)

    def test_fails_blind_when_no_version_can_be_read(self) -> None:
        """A binary that prints nothing usable is the missing-binary branch too."""
        result = _run_guard(None, _pinned_version())
        self.assertEqual(
            1, result.returncode, f"guard passed with no version to compare:\n{result.stdout}"
        )
        self.assertIn("gone blind", result.stdout)

    def test_fails_when_the_pin_is_unset(self) -> None:
        """Deleting the job env must break the guard loudly, not quietly."""
        pin = _pinned_version()
        result = _run_guard(f"Luacheck: {pin}", None)
        self.assertEqual(
            1, result.returncode, f"guard passed with no pin at all:\n{result.stdout}"
        )
        self.assertIn("no pin to check", result.stdout)


class TestCheckShAgreesWithTheWorkflow(unittest.TestCase):
    """check.sh must DERIVE the pin, never restate it."""

    def _extraction_snippet(self) -> str:
        text = CHECK_SH.read_text(encoding="utf-8")
        match = re.search(r'^[ \t]*CI_LUACHECK_PIN=.*?\|\| true\)"', text, re.S | re.M)
        self.assertIsNotNone(
            match,
            "check.sh no longer derives CI_LUACHECK_PIN from the workflow; "
            "a hardcoded version there is a second source of truth that will drift.",
        )
        return match.group(0).strip()

    def test_check_sh_reads_the_pin_out_of_the_workflow(self) -> None:
        snippet = self._extraction_snippet()
        self.assertIn(".github/workflows/ci.yml", snippet)
        self.assertIn("LUACHECK_VERSION", snippet)

    def test_check_sh_extraction_yields_exactly_the_pinned_version(self) -> None:
        """Run check.sh's own extraction and compare it to the parsed yaml."""
        bash = _require_bash()
        snippet = self._extraction_snippet()
        result = subprocess.run(
            [bash, "-c", f'{snippet}\nprintf "%s" "$CI_LUACHECK_PIN"'],
            capture_output=True,
            text=True,
            cwd=str(ROOT),
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            _pinned_version(),
            result.stdout.strip(),
            "check.sh reads a different pin than ci.yml declares: the local "
            "notice would then compare against the wrong version.",
        )


if __name__ == "__main__":
    unittest.main()
