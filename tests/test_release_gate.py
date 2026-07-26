"""The release pipeline's version gate, exercised on every PR.

``.github/workflows/release.yml`` runs only on a tag push, and tag pushes are
USER-ONLY in this project, so its ``Verify version tag matches mod.info`` step
had never been executed by anything: not by CI, not by a release (the last
pushed tag is ``v1.2.1``, from before the workflow's current shape).  An
unexercised gate is an inert surface by default, and this one had in fact gone
dead:

    modversion=0.1.0            (since the 2026-07-25 version reset)
    tag v0.1.0
      -> old script truncated the TAG to major.minor  = "0.1"
      -> compared "0.1" against the RAW modversion    = "0.1.0"
      -> ERROR: Version mismatch, exit 1

The truncated left-hand side can never contain two dots, so with a
three-component ``modversion`` NO tag could satisfy the check.  The first real
release after the reset would have failed on its first step, before packaging
anything.

This module extracts that step's script out of the workflow yaml and runs it
under ``bash`` against synthetic ``42/mod.info`` fixtures, so the gate is
proven on every push and pull request instead of at tag-push time.  It is a
drift guard, not a one-time reconciliation: it reads the WORKFLOW as its source
of truth, so a future edit that re-breaks the comparison fails CI here.

Implementation notes:

* No PyYAML.  This repo's Python surface is deliberately stdlib only (plus
  pytest), so the step is located by a small hand-rolled block reader.  The
  reader hard-fails when it cannot find the step or the script comes back
  empty: a guard that silently reports success on zero input is worse than no
  guard (same rule as ``ci.yml``'s Action pin guard).
* The script is run with ``bash -e``, which is the default shell GitHub uses
  for a ``run:`` step on Linux when no ``shell:`` key is given.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
MOD_INFO_42 = ROOT / "42" / "mod.info"

STEP_NAME = "Verify version tag matches mod.info"

BASH = shutil.which("bash")

# A mod.info with every field the gate does not read, so the fixtures differ
# from the real file only in the line under test.
MOD_INFO_TEMPLATE = """name=AutoPilot Leveler
id=AutoPilot
url=https://github.com/rodmen07/auto-pilot-pz
{modversion_line}
pzversion=42.19.0
"""


def _require_bash() -> str:
    """Return the bash to run the gate with, or fail loudly.

    A missing bash on a POSIX runner is a broken CI environment, not a reason
    to pass: these tests must never silently skip where they actually matter.
    Windows dev boxes without Git Bash on PATH are the only sanctioned skip.
    """
    if BASH:
        return BASH
    if sys.platform == "win32":
        raise unittest.SkipTest(
            "bash is not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        "bash not found on a POSIX runner: the release-gate tests must not skip in CI."
    )


def extract_step_block(workflow_text: str, step_name: str) -> list[str]:
    """Return the raw lines of the named workflow step, up to the next step."""
    lines = workflow_text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == f"- name: {step_name}":
            start = i
            break
    if start is None:
        raise LookupError(
            f"step {step_name!r} not found in {RELEASE_WORKFLOW}. "
            "If the step was renamed, update STEP_NAME here in the same commit: "
            "this guard must never pass by failing to find its subject."
        )
    block = [lines[start]]
    for line in lines[start + 1:]:
        if line.strip().startswith("- name:"):
            break
        block.append(line)
    return block


def extract_step_script(workflow_text: str, step_name: str) -> str:
    """Return the dedented body of the named step's ``run: |`` block."""
    block = extract_step_block(workflow_text, step_name)
    run_at = None
    for i, line in enumerate(block):
        if line.strip() == "run: |":
            run_at = i
            break
    if run_at is None:
        raise LookupError(
            f"step {step_name!r} has no 'run: |' block; the gate cannot be exercised."
        )
    run_indent = len(block[run_at]) - len(block[run_at].lstrip())

    body: list[str] = []
    for line in block[run_at + 1:]:
        if not line.strip():
            body.append("")
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= run_indent:
            break
        body.append(line)

    widths = [len(l) - len(l.lstrip()) for l in body if l.strip()]
    if not widths:
        raise LookupError(f"step {step_name!r} has an EMPTY run block.")
    pad = min(widths)
    return "\n".join(line[pad:] if line.strip() else "" for line in body)


WORKFLOW_TEXT = RELEASE_WORKFLOW.read_text(encoding="utf-8")
GATE_SCRIPT = extract_step_script(WORKFLOW_TEXT, STEP_NAME)


def run_gate(tag_name: str, modversion_line: str) -> subprocess.CompletedProcess:
    """Run the real gate script against a synthetic 42/mod.info."""
    bash = _require_bash()
    with tempfile.TemporaryDirectory() as tmp:
        mod_dir = Path(tmp) / "42"
        mod_dir.mkdir()
        (mod_dir / "mod.info").write_text(
            MOD_INFO_TEMPLATE.format(modversion_line=modversion_line),
            encoding="utf-8",
        )
        env = dict(os.environ)
        env["TAG_NAME"] = tag_name
        return subprocess.run(
            [bash, "-e", "-c", GATE_SCRIPT],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
        )


def _repo_modversion() -> str:
    for line in MOD_INFO_42.read_text(encoding="utf-8").splitlines():
        if line.startswith("modversion="):
            return line.split("=", 1)[1].strip()
    raise AssertionError(f"no modversion= line in {MOD_INFO_42}")


class TestGateIsExtractable(unittest.TestCase):
    """The guard must fail loudly rather than test an empty string."""

    def test_script_is_non_empty_and_is_the_real_check(self) -> None:
        self.assertTrue(GATE_SCRIPT.strip(), "extracted gate script is empty")
        self.assertIn("modversion", GATE_SCRIPT)
        self.assertIn("TAG_NAME", GATE_SCRIPT)
        self.assertIn("42/mod.info", GATE_SCRIPT)

    def test_missing_step_raises_rather_than_passing(self) -> None:
        with self.assertRaises(LookupError):
            extract_step_script(WORKFLOW_TEXT, "a step that does not exist")

    def test_empty_run_block_raises(self) -> None:
        fake = "\n".join(
            [
                "      - name: Verify version tag matches mod.info",
                "        run: |",
                "      - name: Next step",
                "        run: echo hi",
            ]
        )
        with self.assertRaises(LookupError):
            extract_step_script(fake, STEP_NAME)


class TestTagIsNotInterpolated(unittest.TestCase):
    """`${{ }}` inside a run body is the Actions script-injection shape."""

    def test_tag_arrives_through_env(self) -> None:
        block = "\n".join(extract_step_block(WORKFLOW_TEXT, STEP_NAME))
        self.assertIn("env:", block)
        self.assertIn("TAG_NAME: ${{ github.ref_name }}", block)

    def test_run_body_contains_no_expression_interpolation(self) -> None:
        self.assertNotIn(
            "${{",
            GATE_SCRIPT,
            "the gate script interpolates an Actions expression into shell; "
            "pass it through `env:` instead (a git ref may contain ; $ or backticks)",
        )


class TestGateAcceptsValidTags(unittest.TestCase):
    def test_accepts_the_version_this_repo_actually_ships(self) -> None:
        """The regression proof: v<modversion> must be releasable.

        This is the exact case the old script rejected, for every possible tag.
        """
        version = _repo_modversion()
        result = run_gate(f"v{version}", f"modversion={version}")
        self.assertEqual(
            result.returncode,
            0,
            f"tag v{version} rejected against modversion={version}:\n{result.stdout}\n{result.stderr}",
        )
        self.assertIn("Version check PASSED", result.stdout)

    def test_accepts_three_component_version(self) -> None:
        result = run_gate("v0.1.0", "modversion=0.1.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_accepts_historical_two_component_version(self) -> None:
        """The 5.8-era scheme keeps working: this fix must not break old tags."""
        result = run_gate("v5.8.0", "modversion=5.8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_accepts_tag_without_patch_component(self) -> None:
        result = run_gate("v5.8", "modversion=5.8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_accepts_prerelease_suffix(self) -> None:
        result = run_gate("v0.1.0-beta1", "modversion=0.1.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class TestGateStillRejectsMismatches(unittest.TestCase):
    """The fix must not weaken the gate: a real mismatch still fails."""

    def test_rejects_wrong_minor(self) -> None:
        result = run_gate("v0.2.0", "modversion=0.1.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Version mismatch", result.stdout)

    def test_rejects_wrong_major(self) -> None:
        result = run_gate("v1.1.0", "modversion=0.1.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Version mismatch", result.stdout)

    def test_rejects_wrong_patch(self) -> None:
        """Stricter than the old gate, which truncated the patch away."""
        result = run_gate("v0.1.1", "modversion=0.1.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Version mismatch", result.stdout)

    def test_rejects_missing_modversion_line(self) -> None:
        result = run_gate("v0.1.0", "# no modversion here")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no modversion=", result.stdout)


class TestGateMatchesTheShippedModInfo(unittest.TestCase):
    """Cross-file: the version a release would be tagged with is derivable."""

    def test_repo_modversion_is_a_dotted_number(self) -> None:
        version = _repo_modversion()
        parts = version.split(".")
        self.assertGreaterEqual(len(parts), 2, f"modversion={version!r}")
        for part in parts:
            self.assertTrue(part.isdigit(), f"non-numeric component in {version!r}")


if __name__ == "__main__":
    unittest.main()
