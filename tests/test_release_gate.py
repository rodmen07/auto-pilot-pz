"""The release pipeline's version gate, exercised on every PR.

``.github/workflows/release.yml`` runs only on a tag push.  When this module was
written its ``Verify version tag matches mod.info`` step had never been executed
by anything: not by CI, not by a release (the last pushed tag was ``v1.2.1``,
from before the workflow's current shape).  An unexercised gate is an inert
surface by default, and this one had in fact gone dead:

.. note::

   Superseded premise, corrected 2026-08-08 by a product truth audit and quoted
   verbatim where it stood: *"and tag pushes are USER-ONLY in this project"*.
   That was false twice over by the time it was read.  Tag pushes were delegated
   to the agent on 2026-07-26, and ``v0.2.0`` was in fact tagged and released on
   2026-08-05, which is the first time ``release.yml``'s tag-push path ran end to
   end.  The REASON this module exists is unaffected — the gate was dead when the
   module was written, and this suite is what proves it is not dead now — but a
   live test file asserting a retracted permission is exactly the stale prose the
   guard next door (``tests/test_roadmap_truth.py``) was built to catch, so it is
   corrected here rather than left to be inherited.  Publishing is now delegated
   in full (2026-08-08), Steam Workshop uploads included; see ``ROADMAP.md``
   "User-only (standing)".

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

It now covers the PACKAGING half of the same job as well.  Everything after the
version check was still unexercised, and two of those steps interpolated
``${{ github.ref_name }}`` straight into a bash body inside a job holding
``contents: write`` — the documented Actions script-injection shape, since git
permits ``;``, ``$`` and backticks in a ref name.  The archive name was also
spelled out by hand three times (zip target, integrity check, release upload),
so an edit to one could publish a file that was never built.  Both are now
single-sourced from the job-level ``env:`` block and asserted here:

* every ``run:`` body in the file is scanned for ``${{`` (not just the version
  step's), with an always-on negative control proving the OLD interpolated form
  really did execute an attacker-supplied ref;
* the archive-name prefix must appear exactly once in the workflow;
* the build step's zip target and the integrity check's REQUIRED/DEV_PATTERNS
  assertions are executed for real, the former with ``zip`` stubbed by a shell
  function (the name is what is under test, not the compression) and the latter
  against archives built with :mod:`zipfile` and listed by the real ``unzip``.

And finally the ANTHROPIC-IMPORT half.  ``Verify no anthropic import in Python
sources`` was the last ``run:`` step in the job with no coverage at all, and it
is the guard standing between the removed LLM-sidecar architecture and a silent
reintroduction.  Executing it found the same class of defect the version gate
had: the original pattern was the fixed string ``import anthropic``, which the
modern SDK style (``from`` + `` anthropic import Anthropic``, class name
capitalised after ``import``) sails straight past, so the one import shape a
reintroduction would actually use was invisible to it.  The step now matches
both shapes; :class:`TestAnthropicImportGate` proves each direction plus an
always-on negative control showing the old pattern really was blind.

And the CI-GATE half, which turned out to be the broadest of the lot.  The
``lint-and-test`` job at the top of ``release.yml`` calls this repo's CI suite
as a reusable workflow (``uses: ./.github/workflows/ci.yml``), and GitHub only
honours that call when the called workflow declares ``on: workflow_call`` —
which ``ci.yml`` never did.  So the FIRST job of every release would have
failed at parse time ("workflow is not reusable"), before the version gate,
the packaging, or any other step this module exercises could run at all.
:class:`TestCiGateIsActuallyCallable` pins the contract from both ends.

Implementation notes:

* No PyYAML.  This repo's Python surface is deliberately stdlib only (plus
  pytest), so steps, jobs and their env blocks are located by small hand-rolled
  block readers.  Every reader hard-fails when it cannot find its subject or
  comes back empty: a guard that silently reports success on zero input is
  worse than no guard (same rule as ``ci.yml``'s Action pin guard).
* Scripts are run with ``bash -e``, which is the default shell GitHub uses for
  a ``run:`` step on Linux when no ``shell:`` key is given.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).parent.parent
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
MOD_INFO_42 = ROOT / "42" / "mod.info"

STEP_NAME = "Verify version tag matches mod.info"
BUILD_STEP = "Build mod archive"
VERIFY_STEP = "Verify archive contents"
ANTHROPIC_STEP = "Verify no anthropic import in Python sources"
RELEASE_STEP = "Create GitHub Release"
JOB_NAME = "release"

# The one place the packaged file is named.  Spelled here as two fragments so
# that this module's own source cannot be mistaken for a second definition by
# anyone grepping the repo for it.
ARCHIVE_PREFIX = "AutoPilot" + "-"

BASH = shutil.which("bash")
UNZIP = shutil.which("unzip")

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


def step_names(workflow_text: str) -> list[str]:
    """Return every ``- name:`` step label in the workflow, in file order."""
    prefix = "- name: "
    return [
        line.strip()[len(prefix):]
        for line in workflow_text.splitlines()
        if line.strip().startswith(prefix)
    ]


def iter_run_steps(workflow_text: str) -> list[tuple[str, str]]:
    """Return ``(step_name, script)`` for every step carrying a ``run: |`` body.

    Steps that only invoke an action (``uses:``) have no script and are simply
    absent from the result.
    """
    out: list[tuple[str, str]] = []
    for name in step_names(workflow_text):
        block = extract_step_block(workflow_text, name)
        if any(line.strip() == "run: |" for line in block):
            out.append((name, extract_step_script(workflow_text, name)))
    return out


def extract_job_block(workflow_text: str, job_name: str) -> list[str]:
    """Return the raw lines of the named job, up to the next top-level job."""
    lines = workflow_text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.rstrip() == f"  {job_name}:":
            start = i
            break
    if start is None:
        raise LookupError(
            f"job {job_name!r} not found in {RELEASE_WORKFLOW}; this guard must "
            "never pass by failing to find its subject."
        )
    block: list[str] = []
    for line in lines[start + 1:]:
        if line.strip() and not line.startswith("    "):
            break
        block.append(line)
    return block


def extract_job_env(workflow_text: str, job_name: str) -> dict[str, str]:
    """Return the job-level ``env:`` mapping for ``job_name``.

    This is where every tag-derived value must live: a value defined here is
    visible to each step's shell without being interpolated into its body.
    """
    block = extract_job_block(workflow_text, job_name)
    env_at = None
    for i, line in enumerate(block):
        if line.rstrip() == "    env:":
            env_at = i
            break
    if env_at is None:
        raise LookupError(
            f"job {job_name!r} has no job-level 'env:' block, so tag-derived "
            "values can only reach the steps by interpolation."
        )
    out: dict[str, str] = {}
    for line in block[env_at + 1:]:
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= 4:
            break
        if line.lstrip().startswith("#"):
            continue
        key, sep, value = line.strip().partition(":")
        if sep:
            out[key.strip()] = value.strip()
    if not out:
        raise LookupError(f"job {job_name!r} has an EMPTY job-level 'env:' block")
    return out


def parse_bash_array(script: str, name: str) -> list[str]:
    """Return the double-quoted entries of a ``NAME=( ... )`` array literal.

    Read out of the workflow rather than restated here, so the assertions below
    can never drift from the list the release job actually enforces.
    """
    marker = f"{name}=("
    idx = script.find(marker)
    if idx == -1:
        raise LookupError(f"bash array {name!r} not found in the extracted script")
    end = script.find(")", idx)
    if end == -1:
        raise LookupError(f"bash array {name!r} is unterminated")
    return re.findall(r'"([^"]+)"', script[idx + len(marker):end])


def local_workflow_calls(workflow_text: str) -> list[str]:
    """Return every local reusable-workflow target (``uses: ./...``) in order.

    These are workflow-to-workflow calls, not action refs: the caller's job
    delegates its entire definition to another file in this repository, and
    GitHub refuses the call unless that file's ``on:`` includes
    ``workflow_call``.  The reader returns an empty list rather than raising so
    the blind-guard test below can assert the CI gate still EXISTS as its own
    named failure.
    """
    calls: list[str] = []
    for line in workflow_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or "uses:" not in stripped:
            continue
        rest = stripped.split("uses:", 1)[1].strip()
        if not rest:
            continue
        spec = rest.split()[0]
        if spec.startswith("./"):
            calls.append(spec.split("@", 1)[0])
    return calls


def trigger_keys(workflow_text: str, source: str) -> list[str]:
    """Return the trigger names under a workflow's top-level ``on:`` block.

    Handles the two shapes this repo's workflows use: a mapping block
    (``on:`` followed by indented keys) and the flow list (``on: [a, b]``).
    Hard-fails when no ``on:`` block or no triggers can be found: a reader
    that answers "no triggers" for a malformed file would let the callable
    test pass on exactly the breakage it exists to catch.
    """
    lines = workflow_text.splitlines()
    for i, line in enumerate(lines):
        flow = re.match(r"^(?:on|\"on\"|'on'):\s*\[(.+)\]\s*$", line)
        if flow:
            keys = [k.strip().strip("\"'") for k in flow.group(1).split(",")]
            keys = [k for k in keys if k]
            if not keys:
                raise LookupError(f"empty flow-style on: list in {source}")
            return keys
        if re.match(r"^(?:on|\"on\"|'on'):\s*$", line):
            keys = []
            for block_line in lines[i + 1:]:
                if block_line.strip() and not block_line.startswith((" ", "\t")):
                    break  # next top-level key ends the on: block
                key = re.match(r"^ {2}([A-Za-z_][A-Za-z0-9_]*):", block_line)
                if key:
                    keys.append(key.group(1))
            if not keys:
                raise LookupError(
                    f"found an on: block in {source} but no trigger keys under "
                    "it; the reader must never answer 'no triggers' silently"
                )
            return keys
    raise LookupError(
        f"no top-level on: block found in {source}; a workflow without "
        "triggers cannot run at all, so this reader refuses to guess"
    )


WORKFLOW_TEXT = RELEASE_WORKFLOW.read_text(encoding="utf-8")
CI_TEXT = CI_WORKFLOW.read_text(encoding="utf-8")
GATE_SCRIPT = extract_step_script(WORKFLOW_TEXT, STEP_NAME)
BUILD_SCRIPT = extract_step_script(WORKFLOW_TEXT, BUILD_STEP)
VERIFY_SCRIPT = extract_step_script(WORKFLOW_TEXT, VERIFY_STEP)
ANTHROPIC_SCRIPT = extract_step_script(WORKFLOW_TEXT, ANTHROPIC_STEP)
JOB_ENV = extract_job_env(WORKFLOW_TEXT, JOB_NAME)

# The forbidden import shapes, assembled by concatenation so this module can
# never trip the gate it tests: the release job runs the real step against the
# real tree, and this file is a .py source inside that tree.  (The constant
# folding a .pyc performs is harmless because the step scans
# ``--include="*.py"`` only.)
PLAIN_IMPORT = "import" + " " + "anthropic"
FROM_IMPORT = "from" + " " + "anthropic" + " import Anthropic"
FROM_SUBMODULE = "from" + " " + "anthropic" + ".types import Message"
LOOKALIKE_IMPORT = "from" + " " + "anthropic" + "_utils import helper"

# `zip` is present on ubuntu-latest but not on every dev box, and what is under
# test is the NAME the build step passes, not the compression.  A shell
# function shadows the external command, so the extracted script text itself is
# executed unmodified.
ZIP_STUB = 'zip() { printf "%s\\n" "$@" > "${ZIP_ARGV_OUT}"; }\n'


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


def _require_unzip() -> str:
    """Return the unzip to list archives with, or fail loudly.

    Same rule as :func:`_require_bash`: a missing unzip on a POSIX runner is a
    broken CI environment, never a reason to report success.
    """
    if UNZIP:
        return UNZIP
    if sys.platform == "win32":
        raise unittest.SkipTest(
            "unzip is not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        "unzip not found on a POSIX runner: the archive tests must not skip in CI."
    )


def run_build_step(archive_name: str, script: str | None = None):
    """Run the build step with ``zip`` stubbed; return (result, argv, leftovers).

    ``leftovers`` is every file the script left in its working directory apart
    from the stub's own capture file — which is how an injected ``touch`` is
    detected.
    """
    bash = _require_bash()
    body = BUILD_SCRIPT if script is None else script
    with tempfile.TemporaryDirectory() as tmp:
        argv_out = Path(tmp) / "zip-argv.txt"
        env = dict(os.environ)
        env["ARCHIVE_NAME"] = archive_name
        env["ZIP_ARGV_OUT"] = str(argv_out)
        result = subprocess.run(
            [bash, "-e", "-c", ZIP_STUB + body],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
        )
        argv = (
            argv_out.read_text(encoding="utf-8").splitlines()
            if argv_out.exists()
            else []
        )
        leftovers = sorted(
            p.name for p in Path(tmp).iterdir() if p.name != argv_out.name
        )
        return result, argv, leftovers


def run_verify_step(
    archive_name: str,
    members: list[str],
    env_name: str | None = None,
) -> subprocess.CompletedProcess:
    """Build a real archive with :mod:`zipfile`, then run the integrity check.

    The step's own ``unzip -l`` does the listing, so what is exercised is the
    real assertion logic, not a re-implementation of it.  ``env_name`` defaults
    to the on-disk name; passing a different one points the step at an archive
    that does not exist, which is how "the step really reads ARCHIVE_NAME" is
    proved rather than assumed.
    """
    bash = _require_bash()
    _require_unzip()
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(Path(tmp) / archive_name, "w") as archive:
            for member in members:
                archive.writestr(member, "x")
        env = dict(os.environ)
        env["ARCHIVE_NAME"] = env_name if env_name is not None else archive_name
        return subprocess.run(
            [bash, "-e", "-c", VERIFY_SCRIPT],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
        )


def run_anthropic_step(
    files: dict[str, str],
    script: str | None = None,
) -> subprocess.CompletedProcess:
    """Run the anthropic-import step against a synthetic source tree.

    ``files`` maps relative paths to contents; parent directories are created,
    so nested layouts (``tests/x.py``, ``docs/y.md``) work.  ``script``
    defaults to the body extracted from the workflow; the negative control
    passes the reconstructed pre-fix body instead.
    """
    bash = _require_bash()
    body = ANTHROPIC_SCRIPT if script is None else script
    with tempfile.TemporaryDirectory() as tmp:
        for rel, content in files.items():
            path = Path(tmp) / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        return subprocess.run(
            [bash, "-e", "-c", body],
            cwd=tmp,
            env=dict(os.environ),
            capture_output=True,
            text=True,
        )


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
    """``${{ }}`` inside a run body is the Actions script-injection shape.

    Widened from the version step alone to EVERY run body in the file: the
    archive build and the archive integrity check ran in the same
    ``contents: write`` job and both interpolated the ref straight into bash.
    """

    def test_tag_arrives_through_the_job_env_block(self) -> None:
        self.assertEqual(JOB_ENV.get("TAG_NAME"), "${{ github.ref_name }}")

    def test_run_body_contains_no_expression_interpolation(self) -> None:
        self.assertNotIn(
            "${{",
            GATE_SCRIPT,
            "the gate script interpolates an Actions expression into shell; "
            "pass it through `env:` instead (a git ref may contain ; $ or backticks)",
        )

    def test_no_run_body_in_the_file_interpolates_an_expression(self) -> None:
        steps = iter_run_steps(WORKFLOW_TEXT)
        self.assertGreaterEqual(
            len(steps),
            3,
            "found fewer run steps than release.yml has; the scanner has gone blind",
        )
        offenders = [name for name, script in steps if "${{" in script]
        self.assertEqual(
            offenders,
            [],
            "these run bodies interpolate an Actions expression into shell: "
            f"{offenders!r}. Define the value in the job-level `env:` block "
            "instead; a git ref may contain ; $ or backticks and this job holds "
            "contents: write.",
        )

    def test_no_single_line_run_interpolates_either(self) -> None:
        """The block scanner above only sees ``run: |`` bodies."""
        offenders = [
            line.strip()
            for line in WORKFLOW_TEXT.splitlines()
            if line.strip().startswith("run:")
            and line.strip() != "run: |"
            and "${{" in line
        ]
        self.assertEqual(offenders, [], f"single-line run: with interpolation: {offenders!r}")


class TestArchiveNameHasExactlyOneDefinition(unittest.TestCase):
    """Three hand-written copies of the archive name could silently disagree."""

    def test_job_env_defines_the_archive_name(self) -> None:
        self.assertEqual(
            JOB_ENV.get("ARCHIVE_NAME"),
            ARCHIVE_PREFIX + "${{ github.ref_name }}.zip",
        )

    def test_missing_job_env_raises_rather_than_passing(self) -> None:
        fake = "\n".join(
            [
                "jobs:",
                f"  {JOB_NAME}:",
                "    name: Package & publish",
                "    steps:",
                "      - name: Build mod archive",
            ]
        )
        with self.assertRaises(LookupError):
            extract_job_env(fake, JOB_NAME)

    def test_missing_job_raises_rather_than_passing(self) -> None:
        with self.assertRaises(LookupError):
            extract_job_env(WORKFLOW_TEXT, "a job that does not exist")

    def test_the_prefix_is_spelled_exactly_once(self) -> None:
        self.assertEqual(
            WORKFLOW_TEXT.count(ARCHIVE_PREFIX),
            1,
            "the archive name is spelled out more than once in release.yml; a "
            "second copy can drift from the first and publish a file that was "
            "never built. Read ARCHIVE_NAME from the job-level env block.",
        )

    def test_all_three_consumers_read_the_one_definition(self) -> None:
        self.assertIn('zip -r "${ARCHIVE_NAME}"', BUILD_SCRIPT)
        self.assertIn("${ARCHIVE_NAME}", VERIFY_SCRIPT)
        upload = "\n".join(extract_step_block(WORKFLOW_TEXT, RELEASE_STEP))
        self.assertIn("files: ${{ env.ARCHIVE_NAME }}", upload)


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


class TestBuildStepNamesTheArchiveFromTheEnvironment(unittest.TestCase):
    """The zip target must come from ARCHIVE_NAME, not from a substituted ref."""

    def test_the_zip_target_is_exactly_the_env_value(self) -> None:
        name = ARCHIVE_PREFIX + "v9.9.9.zip"
        result, argv, _ = run_build_step(name)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(name, argv, f"zip argv was {argv!r}")

    def test_the_packaged_paths_are_unchanged(self) -> None:
        """Guards against a rename that quietly drops docs or the changelog."""
        _, argv, _ = run_build_step(ARCHIVE_PREFIX + "v9.9.9.zip")
        for expected in ("42/", "docs/", "CHANGELOG.md"):
            self.assertIn(expected, argv, f"zip argv was {argv!r}")


class TestTheRefNameCannotInjectShell(unittest.TestCase):
    """A git ref may contain ``;``, ``$`` and backticks.

    ``test_no_run_body_in_the_file_interpolates_an_expression`` asserts the
    shape; these two assert the CONSEQUENCE, in both directions, so the change
    is provably a fix and not a cosmetic move.
    """

    HOSTILE_REF = 'v1.0.0";touch injected;"'

    def test_env_form_treats_a_hostile_ref_as_one_literal_filename(self) -> None:
        name = ARCHIVE_PREFIX + self.HOSTILE_REF + ".zip"
        result, argv, leftovers = run_build_step(name)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(name, argv, f"zip argv was {argv!r}")
        self.assertNotIn("injected", leftovers, f"leftovers were {leftovers!r}")

    def test_negative_control_the_old_interpolated_form_executed_it(self) -> None:
        """Always-on control: the pre-fix workflow really was exploitable.

        Actions substitutes ``${{ github.ref_name }}`` into the script TEXT
        before bash ever sees it, so the old body is reproduced here by the same
        textual substitution.  If this ever stops creating the file, the whole
        premise of the fix above is wrong and should be re-checked.
        """
        old = BUILD_SCRIPT.replace(
            '"${ARCHIVE_NAME}"',
            f'"{ARCHIVE_PREFIX}{self.HOSTILE_REF}.zip"',
        )
        self.assertNotIn("${ARCHIVE_NAME}", old, "the control did not patch the script")
        _, _, leftovers = run_build_step("unused", script=old)
        self.assertIn(
            "injected",
            leftovers,
            "the pre-fix interpolated form no longer injects; re-derive the fix "
            f"before trusting it (leftovers were {leftovers!r})",
        )


class TestArchiveIntegrityCheckActuallyChecks(unittest.TestCase):
    """The packaging half of the job had never been executed by anything."""

    def setUp(self) -> None:
        self.required = parse_bash_array(VERIFY_SCRIPT, "REQUIRED")
        self.dev_patterns = parse_bash_array(VERIFY_SCRIPT, "DEV_PATTERNS")
        self.archive = ARCHIVE_PREFIX + "v9.9.9.zip"

    def test_both_assertion_lists_were_read_from_the_workflow(self) -> None:
        """A guard that runs against empty lists would pass on anything."""
        self.assertGreaterEqual(len(self.required), 5, self.required)
        self.assertGreaterEqual(len(self.dev_patterns), 3, self.dev_patterns)
        self.assertIn("42/mod.info", self.required)

    def test_a_complete_archive_passes(self) -> None:
        result = run_verify_step(self.archive, self.required)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Archive integrity check PASSED", result.stdout)

    def test_a_missing_required_file_fails(self) -> None:
        result = run_verify_step(self.archive, self.required[1:])
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Required file missing", result.stdout)

    def test_a_bundled_dev_file_fails(self) -> None:
        result = run_verify_step(self.archive, self.required + ["tests/test_x.lua"])
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Dev-only file found", result.stdout)

    def test_the_step_reads_the_archive_name_from_the_environment(self) -> None:
        """Pointed at a name that was never built, the step must fail loudly."""
        result = run_verify_step(
            self.archive,
            self.required,
            env_name=ARCHIVE_PREFIX + "never-built.zip",
        )
        self.assertNotEqual(
            result.returncode,
            0,
            "the integrity check passed against an archive it was not pointed at: "
            f"{result.stdout}{result.stderr}",
        )


class TestAnthropicImportGate(unittest.TestCase):
    """The last run step in the release job whose logic nothing had executed.

    It guards the removed LLM-sidecar architecture: nothing may reintroduce
    the Anthropic SDK into this repo's Python surface.  Running it found the
    same defect class the version gate had when IT first ran: the original
    fixed-string pattern missed the modern SDK import style entirely (the
    text after ``import `` in a ``from`` import is the capitalised class
    name, and the old grep was case-sensitive with no ``from`` alternative),
    so the one shape a reintroduction would actually use went straight past
    the gate.
    """

    CLEAN_TREE = {
        "triage_run_log.py": "import sys\n\n\ndef main() -> int:\n    return 0\n",
        "tests/test_example.py": "import unittest\n",
    }

    def test_script_is_non_empty_and_is_the_real_check(self) -> None:
        self.assertTrue(ANTHROPIC_SCRIPT.strip(), "extracted anthropic script is empty")
        self.assertIn("anthropic", ANTHROPIC_SCRIPT)
        self.assertIn('--include="*.py"', ANTHROPIC_SCRIPT)

    def test_a_clean_tree_passes(self) -> None:
        result = run_anthropic_step(self.CLEAN_TREE)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASSED", result.stdout)

    def test_a_plain_import_fails(self) -> None:
        files = dict(self.CLEAN_TREE)
        files["sidecar.py"] = PLAIN_IMPORT + "\n\nclient = None\n"
        result = run_anthropic_step(files)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("ERROR", result.stdout)

    def test_an_indented_lazy_import_fails(self) -> None:
        """An import inside a function body is still a reintroduction."""
        files = dict(self.CLEAN_TREE)
        files["sidecar.py"] = "def lazy():\n    " + PLAIN_IMPORT + "\n"
        result = run_anthropic_step(files)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_the_from_import_form_fails(self) -> None:
        """The modern SDK style, invisible to the original fixed-string grep."""
        files = dict(self.CLEAN_TREE)
        files["sidecar.py"] = FROM_IMPORT + "\n"
        result = run_anthropic_step(files)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("ERROR", result.stdout)

    def test_a_submodule_from_import_fails(self) -> None:
        files = dict(self.CLEAN_TREE)
        files["sidecar.py"] = FROM_SUBMODULE + "\n"
        result = run_anthropic_step(files)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_a_lookalike_module_does_not_trip(self) -> None:
        """``anthropic_utils`` is somebody else's module, not the SDK."""
        files = dict(self.CLEAN_TREE)
        files["helper.py"] = LOOKALIKE_IMPORT + "\n"
        result = run_anthropic_step(files)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_commented_mention_does_not_trip(self) -> None:
        """History notes in comments must not block a release."""
        files = dict(self.CLEAN_TREE)
        files["notes.py"] = "# " + PLAIN_IMPORT + " was removed with the sidecar\n"
        result = run_anthropic_step(files)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_python_files_are_not_scanned(self) -> None:
        files = dict(self.CLEAN_TREE)
        files["docs/history.md"] = "The sidecar used `" + PLAIN_IMPORT + "`.\n"
        result = run_anthropic_step(files)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_negative_control_the_old_pattern_missed_the_from_form(self) -> None:
        """Always-on control: the pre-fix pattern really was blind.

        The original body's grep was the fixed string ``import anthropic``.
        Reconstruct that body by swapping the grep line back, feed it the
        ``from`` form, and it must PASS (that is the missed detection).  The
        same tree fails under the current script above, so together the two
        prove the pattern change is a behavior difference and not cosmetics.
        If this control ever fails, the old pattern caught the form after
        all and the premise of the change should be re-derived.
        """
        old_grep = 'if grep -rn --include="*.py" "' + PLAIN_IMPORT + '" .; then'
        lines = ANTHROPIC_SCRIPT.splitlines()
        swapped = False
        for i, line in enumerate(lines):
            if line.lstrip().startswith("if grep"):
                indent = line[: len(line) - len(line.lstrip())]
                lines[i] = indent + old_grep
                swapped = True
                break
        self.assertTrue(swapped, "control could not locate the grep line to swap")
        old_script = "\n".join(lines)

        files = dict(self.CLEAN_TREE)
        files["sidecar.py"] = FROM_IMPORT + "\n"
        result = run_anthropic_step(files, script=old_script)
        self.assertEqual(
            result.returncode,
            0,
            "the pre-fix fixed-string pattern now catches the from-import form; "
            "re-derive the fix before trusting it:\n"
            f"{result.stdout}{result.stderr}",
        )
        self.assertIn("PASSED", result.stdout)

    def test_the_real_tree_releases_clean(self) -> None:
        """Run the step against THIS repo, exactly as a tag push would.

        Proves at PR time that the next real release will not fail on this
        step, and that this module's own fixtures never leak a forbidden
        string into a scanned file.
        """
        bash = _require_bash()
        result = subprocess.run(
            [bash, "-e", "-c", ANTHROPIC_SCRIPT],
            cwd=ROOT,
            env=dict(os.environ),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASSED", result.stdout)


class TestCiGateIsActuallyCallable(unittest.TestCase):
    """The CI-gate job above all the others had never been runnable at all.

    ``release.yml``'s first job delegates to this repo's CI suite with
    ``uses: ./.github/workflows/ci.yml`` — a reusable-workflow call, and the
    gate that stops a broken tag from producing a release artifact.  GitHub
    only honours such a call when the CALLED workflow's ``on:`` includes
    ``workflow_call`` ("For a workflow to be reusable, the values for ``on``
    must include ``workflow_call``" — docs/actions, reuse-workflows); without
    it the caller dies at parse time with "workflow is not reusable", before
    a single step of any job runs.

    ``ci.yml`` never declared it.  The call shape dates from the workflow's
    first commit and ``gh run list --workflow Release`` is empty, so nothing
    had ever exercised it: the fourth consecutive release-path defect found by
    exercising a surface only a tag push runs (after the unpassable version
    gate, the ``${{ }}`` injection shape, and the anthropic-import gate that
    missed the ``from`` form).  Every release would have failed on its FIRST
    job — including the gate's own reason to exist, a broken tag, which would
    have been "stopped" only because nothing could run at all.

    These tests pin the contract from both ends: the caller still has a local
    CI gate (so the contract cannot be satisfied by deleting it), and every
    locally-called workflow both exists and declares ``workflow_call``.  The
    Changelog guard's PR-only ``if:`` is asserted too, because under a
    workflow_call from a tag push the caller's event name (``push``)
    propagates and a tag diffed against main is an empty diff, which that
    guard's own blind-guard converts into a hard failure: losing the ``if:``
    would re-break the release path while every pull request stayed green.
    """

    def test_release_workflow_still_has_a_local_ci_gate(self) -> None:
        """Blind guard: zero local calls means the CI gate itself is gone."""
        calls = local_workflow_calls(WORKFLOW_TEXT)
        self.assertTrue(
            calls,
            "release.yml no longer calls any local reusable workflow: the "
            "CI gate in front of packaging has been removed or renamed, and "
            "the callable-contract tests below are running on nothing",
        )
        self.assertIn("./.github/workflows/ci.yml", calls)

    def test_every_locally_called_workflow_exists(self) -> None:
        for target in local_workflow_calls(WORKFLOW_TEXT):
            with self.subTest(target=target):
                self.assertTrue(
                    (ROOT / target).is_file(),
                    f"release.yml calls {target}, which does not exist",
                )

    def test_every_locally_called_workflow_declares_workflow_call(self) -> None:
        """The behavior difference: this fails on the pre-fix ci.yml."""
        for target in local_workflow_calls(WORKFLOW_TEXT):
            with self.subTest(target=target):
                text = (ROOT / target).read_text(encoding="utf-8")
                self.assertIn(
                    "workflow_call",
                    trigger_keys(text, target),
                    f"{target} is called as a reusable workflow by release.yml "
                    "but its on: block does not include workflow_call, so the "
                    "call fails at parse time ('workflow is not reusable') and "
                    "the whole release dies on its first job",
                )

    def test_ci_workflow_keeps_its_push_and_pr_triggers(self) -> None:
        """workflow_call is additive: the normal CI triggers must survive."""
        keys = trigger_keys(CI_TEXT, "ci.yml")
        self.assertIn("push", keys)
        self.assertIn("pull_request", keys)

    def test_changelog_guard_stays_pull_request_only(self) -> None:
        """A tag push must SKIP the guard, not feed it an empty diff."""
        block = "\n".join(extract_step_block(CI_TEXT, "Changelog guard"))
        self.assertRegex(
            block,
            r"if:.*github\.event_name\s*==\s*'pull_request'",
            "the Changelog guard has lost its pull_request-only condition; "
            "called from release.yml on a tag push it would diff the tag "
            "against main, get an empty diff, and hard-fail the CI gate",
        )

    def test_trigger_reader_refuses_a_workflow_without_triggers(self) -> None:
        """Never-pass-blind: no on: block is an error, not an empty answer."""
        with self.assertRaises(LookupError):
            trigger_keys("name: X\njobs:\n  a:\n    runs-on: ubuntu-latest\n", "synthetic")

    def test_trigger_reader_refuses_an_empty_on_block(self) -> None:
        with self.assertRaises(LookupError):
            trigger_keys("name: X\non:\njobs:\n  a: {}\n", "synthetic")

    def test_trigger_reader_handles_the_flow_list_shape(self) -> None:
        """The one alternative shape a future edit would plausibly use."""
        keys = trigger_keys("on: [push, workflow_call]\njobs: {}\n", "synthetic")
        self.assertEqual(keys, ["push", "workflow_call"])


if __name__ == "__main__":
    unittest.main()
