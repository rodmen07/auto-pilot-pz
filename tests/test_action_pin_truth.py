"""The Action pin guard, and the truth of its version comments.

``ci.yml``'s ``Action pin guard`` (PR #75) asserts every external action is
pinned to a full 40-hex commit SHA.  What it never checked -- and what no test
had ever executed at all -- is whether the ``# vX.Y.Z`` comment beside each SHA
tells the truth.  The comment is the only thing a human reads: a reviewer
approving a dependabot bump sees ``@<new-sha> # v8.0.0`` and trusts that the
SHA *is* v8.0.0.  Nothing enforced that:

* **A bump editing the SHA but not the comment (or the reverse) passed
  everything.**  The audit trail then lies to every future reader, which is
  precisely the surface a poisoned bump PR would use.
* **An upstream tag re-pointed or deleted after pinning was invisible.**  A
  re-pointed tag is itself a supply-chain event worth failing on.

The 2026-08-08 DevSecOps sweep verified all three pins by hand (3/3 true, each
``git ls-remote`` output recorded in the PR body).  The guard's new TRUTH phase
is that same check run on every push and PR, over the SAME single discovery
pass as the SHAPE phase (a second grep would be a second corpus that could
drift).  Annotated tags resolve through the peeled ``^{}`` SHA --
action-gh-release's tags are annotated (the tag object and the commit differ),
the actions/* tags are lightweight -- and a tag that cannot be queried FAILS
the job, because ``git ls-remote`` exits 0 with EMPTY output for a missing ref,
so "it printed nothing" must be its own failure case, never a pass.

Same guard-on-the-guard shape as :mod:`tests.test_luacheck_pin`: the workflow
stays the single source of truth, this module extracts the real script and
executes it against fake ``git`` binaries in both directions.  The fake logs
every invocation, so the happy path also proves the script really queried one
URL per external pin rather than passing vacuously.
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
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"

GUARD_STEP = "Action pin guard"
SETUP_STEP = "Set up Python"

BASH = shutil.which("bash")

# The guard's own discovery anchor, mirrored here for the static real-corpus
# checks below.  Anchored to line start (plus optional `- `) exactly like the
# script's grep, so the script's echo'd example SHA can never be mistaken for
# a pin.
USES_LINE = re.compile(r"^[ \t]*(?:-[ \t]+)?uses:[ \t]+(?P<spec>\S+)(?P<rest>.*)$")
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
VERSION_COMMENT = re.compile(r"#[ \t]*(?P<claim>\S+)")


def _uses_lines(text: str) -> list[tuple[str, str]]:
    """Every (spec, rest-of-line) for uses: lines, matching the guard's grep."""
    out = []
    for line in text.splitlines():
        m = USES_LINE.match(line)
        if m:
            out.append((m.group("spec"), m.group("rest")))
    return out


def _require_bash() -> str:
    if BASH:
        return BASH
    if sys.platform == "win32":
        raise unittest.SkipTest(
            "bash not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        "bash not found on a POSIX runner: the action pin guard must not skip in CI."
    )


def _run_guard(
    workflow_text: str, git_behavior: str
) -> tuple[subprocess.CompletedProcess, str]:
    """Execute the real guard script against a synthetic workflows dir.

    ``workflow_text`` becomes ``<tmp>/.github/workflows/synthetic.yml`` -- the
    script discovers its corpus with a relative glob, so ``cwd`` selects it.
    ``git_behavior`` is a bash snippet the fake ``git`` runs AFTER logging its
    argv (``$1`` is the subcommand, ``$2`` the URL, ``$3``/``$4`` the refs).
    Returns the completed process and the fake's invocation log.
    """
    bash = _require_bash()
    script = extract_step_script(CI_WORKFLOW.read_text(encoding="utf-8"), GUARD_STEP)

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        wf_dir = tmpdir / ".github" / "workflows"
        wf_dir.mkdir(parents=True)
        if workflow_text:
            (wf_dir / "synthetic.yml").write_text(
                workflow_text, encoding="utf-8", newline="\n"
            )

        bin_dir = tmpdir / "bin"
        bin_dir.mkdir()
        log = tmpdir / "git-calls.log"
        fake_git = bin_dir / "git"
        fake_git.write_text(
            "#!/usr/bin/env bash\n"
            f'printf \'%s\\n\' "$*" >> "{log.as_posix()}"\n' + git_behavior + "\n",
            encoding="utf-8",
            newline="\n",
        )
        fake_git.chmod(0o755)

        script_path = tmpdir / "guard.sh"
        script_path.write_text(script, encoding="utf-8", newline="\n")

        env = dict(os.environ)
        env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"

        result = subprocess.run(
            [bash, "-e", str(script_path)],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(tmpdir),
        )
        calls = log.read_text(encoding="utf-8") if log.exists() else ""
        return result, calls


# Synthetic corpus building blocks.  SHAs are arbitrary hex, not credentials.
SHA_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TAG_OBJECT_SHA = "cccccccccccccccccccccccccccccccccccccccc"


def _workflow_with(uses_line: str) -> str:
    return f"jobs:\n  demo:\n    steps:\n      - {uses_line}\n"


class TestRealPinsAreAuditable(unittest.TestCase):
    """The real corpus: every external pin carries a version claim, statically.

    The TRUTH phase needs a claim to check; these run without bash or network
    so the Windows dev box enforces the invariant too.
    """

    def _real_specs(self) -> list[tuple[str, str]]:
        specs = []
        for wf in (CI_WORKFLOW, RELEASE_WORKFLOW):
            specs.extend(_uses_lines(wf.read_text(encoding="utf-8")))
        return specs

    def test_discovery_is_not_blind(self) -> None:
        external = [s for s, _ in self._real_specs() if not s.startswith("./")]
        self.assertGreaterEqual(
            len(external),
            3,
            "fewer than three external action refs found across ci.yml and "
            "release.yml: the discovery regex here has drifted from the guard's.",
        )

    def test_every_external_pin_is_a_full_sha_with_a_version_comment(self) -> None:
        for spec, rest in self._real_specs():
            if spec.startswith("./"):
                continue
            ref = spec.rsplit("@", 1)[-1]
            self.assertRegex(
                ref,
                FULL_SHA,
                f"{spec!r} is not pinned to a full 40-hex commit SHA.",
            )
            comment = VERSION_COMMENT.search(rest)
            self.assertIsNotNone(
                comment,
                f"{spec!r} carries no version comment: the TRUTH phase would "
                "fail this line in CI, and a bare SHA cannot be audited.",
            )

    def test_guard_runs_before_the_toolchain_install(self) -> None:
        names = step_names(CI_WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn(GUARD_STEP, names)
        self.assertIn(SETUP_STEP, names)
        self.assertLess(
            names.index(GUARD_STEP),
            names.index(SETUP_STEP),
            "the guard must fail fast, before the ~25s toolchain install.",
        )


class TestTruthPhaseBehaviour(unittest.TestCase):
    """The guard's real script, executed in both directions with a fake git."""

    def test_passes_when_the_claimed_tag_matches_and_really_queries(self) -> None:
        wf = _workflow_with(f"uses: acme/tool@{SHA_A} # v1.2.3")
        behavior = f'printf \'{SHA_A}\\trefs/tags/v1.2.3\\n\''
        result, calls = _run_guard(wf, behavior)
        self.assertEqual(0, result.returncode, f"guard failed a true pin:\n{result.stdout}")
        self.assertIn("TRUE     acme/tool@" + SHA_A, result.stdout)
        self.assertIn("Action pin guard PASSED", result.stdout)
        # The L-062 half: the pass must come from a real query, not from the
        # phase silently not running.  One ls-remote, right URL, both refs.
        self.assertEqual(
            [f"ls-remote https://github.com/acme/tool refs/tags/v1.2.3 refs/tags/v1.2.3^{{}}"],
            [l for l in calls.splitlines() if l.strip()],
        )

    def test_prefers_the_peeled_sha_for_annotated_tags(self) -> None:
        """action-gh-release's real shape: tag object and commit differ."""
        wf = _workflow_with(f"uses: acme/tool@{SHA_A} # v1.2.3")
        behavior = (
            f'printf \'{TAG_OBJECT_SHA}\\trefs/tags/v1.2.3\\n\'\n'
            f'printf \'{SHA_A}\\trefs/tags/v1.2.3^{{}}\\n\''
        )
        result, _ = _run_guard(wf, behavior)
        self.assertEqual(
            0,
            result.returncode,
            "guard compared against the tag OBJECT instead of the peeled "
            f"commit and failed a true annotated-tag pin:\n{result.stdout}",
        )

    def test_fails_when_the_sha_is_not_what_the_comment_claims(self) -> None:
        wf = _workflow_with(f"uses: acme/tool@{SHA_A} # v1.2.3")
        behavior = f'printf \'{SHA_B}\\trefs/tags/v1.2.3\\n\''
        result, _ = _run_guard(wf, behavior)
        self.assertEqual(1, result.returncode, f"guard passed a lying comment:\n{result.stdout}")
        self.assertIn("UNTRUE", result.stdout)
        self.assertIn(SHA_B, result.stdout, "the message must name what upstream resolves to")
        self.assertIn("Action pin guard FAILED", result.stdout)

    def test_fails_when_a_pin_has_no_version_comment(self) -> None:
        wf = _workflow_with(f"uses: acme/tool@{SHA_A}")
        result, calls = _run_guard(wf, "exit 0")
        self.assertEqual(1, result.returncode, f"guard passed a bare SHA:\n{result.stdout}")
        self.assertIn("no version comment", result.stdout)
        self.assertEqual("", calls.strip(), "no comment means nothing to query")

    def test_fails_when_the_claimed_tag_does_not_exist_upstream(self) -> None:
        """git ls-remote exits 0 with EMPTY output for a missing ref (L-049):
        emptiness must be its own failure, never mistaken for health."""
        wf = _workflow_with(f"uses: acme/tool@{SHA_A} # v9.9.9")
        result, _ = _run_guard(wf, "exit 0")
        self.assertEqual(1, result.returncode, f"guard passed a nonexistent tag:\n{result.stdout}")
        self.assertIn("does not exist", result.stdout)

    def test_fails_closed_when_the_query_itself_fails(self) -> None:
        wf = _workflow_with(f"uses: acme/tool@{SHA_A} # v1.2.3")
        result, _ = _run_guard(wf, "exit 128")
        self.assertEqual(1, result.returncode, f"guard passed an unqueryable pin:\n{result.stdout}")
        self.assertIn("could not query", result.stdout)

    def test_still_fails_on_a_mutable_tag_reference(self) -> None:
        """The SHAPE phase, previously never executed by any test."""
        wf = _workflow_with("uses: acme/tool@v7")
        result, calls = _run_guard(wf, "exit 0")
        self.assertEqual(1, result.returncode, f"guard passed a mutable tag:\n{result.stdout}")
        self.assertIn("UNPINNED acme/tool@v7", result.stdout)
        self.assertEqual("", calls.strip(), "an unpinned spec must not reach the truth phase")

    def test_skips_local_reusable_workflows(self) -> None:
        wf = (
            "jobs:\n  demo:\n    steps:\n"
            "      - uses: ./.github/workflows/ci.yml\n"
            f"      - uses: acme/tool@{SHA_A} # v1.2.3\n"
        )
        behavior = f'printf \'{SHA_A}\\trefs/tags/v1.2.3\\n\''
        result, calls = _run_guard(wf, behavior)
        self.assertEqual(0, result.returncode, result.stdout)
        self.assertIn("SKIP     ./.github/workflows/ci.yml", result.stdout)
        self.assertEqual(
            1,
            len([l for l in calls.splitlines() if l.strip()]),
            "the local workflow ref must not be queried upstream",
        )

    def test_fails_blind_on_an_empty_corpus(self) -> None:
        """Zero uses: lines means moved/renamed workflows, not health (L-031)."""
        result, _ = _run_guard("", "exit 0")
        self.assertEqual(1, result.returncode, f"guard passed on zero input:\n{result.stdout}")
        self.assertIn("gone blind", result.stdout)


if __name__ == "__main__":
    unittest.main()
