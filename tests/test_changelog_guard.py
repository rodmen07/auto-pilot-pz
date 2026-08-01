"""The changelog guard, exercised on every push and pull request.

``CHANGELOG.md`` is this project's authoritative shipped record -- ``ROADMAP.md``
says so in as many words, and the release notes for a tag are cut from it.  It
had quietly stopped being true.  Between PR #74 and PR #101, seventeen merged
commits touched ``42/media/lua/client/`` and **seven of them never touched
CHANGELOG.md at all**::

    ec62fe5  #84   fix(threat): three of eight negative-stat entries could never fire
    ab8403b  #88   feat(inventory): rank food by malus instead of hiding joyless food
    56c1cd3  #89   feat(telemetry): record raw XP in the session summary
    4ddf0d8  #90   feat(inventory): prefer malus-free food when looting
    a7ee36d  #92   feat(ui): show WHY on the F11 panel and the HUD
    7928bf7  #100  feat(media): back off when broadcasts stop helping
    f713929  #101  feat(tuning): close the endurance idle band (V6.1-1)

That is the whole of the approved V6.0 milestone plus V6.1-1, missing from the
record days before v0.2.0 was due to be cut from it.  Nothing failed, because
nothing was checking.

``.github/workflows/ci.yml``'s ``Changelog guard`` step now checks it on every
pull request.  This module is the guard on the guard: it EXTRACTS that step's
script out of the workflow yaml and runs it under ``bash`` against synthetic git
repositories, so the workflow itself stays the single source of truth and an
edit that breaks the comparison fails here rather than months later.  That is
the same drift-guard shape :mod:`tests.test_release_gate` uses, and it exists
for the same reason: ``release.yml``'s version gate ran only on a tag push, was
therefore never executed by anything, and had rotted into a step that could not
pass at all.  A CI step nothing exercises is an inert surface by default.

The synthetic repositories are built from scratch inside a temp directory with
``git init``, so these tests depend on no commit, branch or remote of the real
repository and cannot be weakened by history rewrites or shallow clones.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from test_release_gate import extract_step_script  # noqa: E402

ROOT = Path(__file__).parent.parent
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

STEP_NAME = "Changelog guard"

BASH = shutil.which("bash")
GIT = shutil.which("git")

# A file under the shipped client path, and one outside it.  The guard keys on
# the path, not on the contents, so the bodies only need to differ per commit.
SHIPPED_LUA = "42/media/lua/client/AutoPilot_Guarded.lua"
UNSHIPPED_LUA = "tests/test_guarded.lua"


def _require_tools() -> tuple[str, str]:
    """Return (bash, git), or fail loudly rather than skip where it matters.

    A POSIX runner missing either tool is a broken CI environment, not a reason
    to report success.  A Windows dev box without Git Bash on PATH is the only
    sanctioned skip, matching tests/test_release_gate.py.
    """
    if BASH and GIT:
        return BASH, GIT
    missing = ", ".join(n for n, v in (("bash", BASH), ("git", GIT)) if not v)
    if sys.platform == "win32":
        raise unittest.SkipTest(
            f"{missing} not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        f"{missing} not found on a POSIX runner: the changelog guard must not skip in CI."
    )


class _Repo:
    """A throwaway git repository with a ``main`` branch and a feature branch."""

    def __init__(self, path: Path, git: str) -> None:
        self.path = path
        self.git = git

    def git_run(self, *args: str) -> None:
        subprocess.run(
            [self.git, *args],
            cwd=self.path,
            check=True,
            capture_output=True,
            text=True,
        )

    def write(self, relpath: str, text: str) -> None:
        dest = self.path / relpath
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")

    def commit(self, message: str) -> None:
        self.git_run("add", "-A")
        self.git_run("commit", "-q", "-m", message)


def _new_repo(tmpdir: str, git: str) -> _Repo:
    """A repo whose ``main`` holds one commit with both files already present."""
    repo = _Repo(Path(tmpdir), git)
    repo.git_run("init", "-q")
    repo.git_run("checkout", "-qb", "main")
    repo.git_run("config", "user.email", "guard@example.invalid")
    repo.git_run("config", "user.name", "Changelog Guard Test")
    repo.git_run("config", "commit.gpgsign", "false")
    repo.write(SHIPPED_LUA, "-- base\n")
    repo.write(UNSHIPPED_LUA, "-- base\n")
    repo.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n")
    repo.write("README.md", "base\n")
    repo.commit("base")
    repo.git_run("checkout", "-qb", "feature")
    return repo


class TestChangelogGuard(unittest.TestCase):
    """Run the real workflow script against synthetic branches."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.bash, cls.git = _require_tools()
        cls.script = extract_step_script(
            CI_WORKFLOW.read_text(encoding="utf-8"), STEP_NAME
        )
        if not cls.script.strip():
            raise AssertionError(
                f"the {STEP_NAME!r} step in {CI_WORKFLOW} has an empty run block; "
                "the guard cannot be exercised and must not be reported as passing."
            )

    def run_guard(self, repo: _Repo, base_ref: str = "main"):
        env = dict(os.environ)
        env["GITHUB_BASE_REF"] = base_ref
        # A repo-level git config in the test runner's HOME must not leak in.
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        return subprocess.run(
            [self.bash, "-e", "-c", self.script],
            cwd=repo.path,
            env=env,
            capture_output=True,
            text=True,
        )

    # ---- the behaviour difference the guard exists to create -----------------

    def test_shipped_lua_without_changelog_fails(self):
        """The exact shape of all seven misses: client Lua moves, record does not."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = _new_repo(tmp, self.git)
            repo.write(SHIPPED_LUA, "-- base\n-- a behaviour change\n")
            repo.commit("feat(guarded): change shipped behaviour")
            result = self.run_guard(repo)
        self.assertNotEqual(
            0,
            result.returncode,
            "shipped client Lua changed with no CHANGELOG.md entry and the guard "
            f"PASSED.  This is the defect the guard exists to catch.\n{result.stdout}",
        )
        self.assertIn("Changelog guard FAILED", result.stdout)
        self.assertIn(SHIPPED_LUA, result.stdout)

    def test_shipped_lua_with_changelog_passes(self):
        """The same change, documented: the guard must get out of the way."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = _new_repo(tmp, self.git)
            repo.write(SHIPPED_LUA, "-- base\n-- a behaviour change\n")
            repo.write(
                "CHANGELOG.md",
                "# Changelog\n\n## [Unreleased]\n\n- A behaviour change.\n",
            )
            repo.commit("feat(guarded): change shipped behaviour, and say so")
            result = self.run_guard(repo)
        self.assertEqual(
            0,
            result.returncode,
            f"a documented change was rejected:\n{result.stdout}\n{result.stderr}",
        )
        self.assertIn("PASSED: CHANGELOG.md changed alongside", result.stdout)

    def test_change_outside_shipped_client_lua_passes(self):
        """Docs, tests and tooling are not shipped behaviour and are not gated."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = _new_repo(tmp, self.git)
            repo.write(UNSHIPPED_LUA, "-- base\n-- a new assertion\n")
            repo.write("README.md", "base\nmore prose\n")
            repo.commit("test(guarded): add an assertion")
            result = self.run_guard(repo)
        self.assertEqual(
            0,
            result.returncode,
            f"a test-only change was rejected:\n{result.stdout}\n{result.stderr}",
        )
        self.assertIn("no shipped client Lua changed", result.stdout)

    def test_override_token_passes_and_is_announced(self):
        """The escape hatch works, and says out loud that it was used."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = _new_repo(tmp, self.git)
            repo.write(SHIPPED_LUA, "-- base\n-- comment typo fixed\n")
            repo.commit("docs(guarded): fix a comment typo [no changelog]")
            result = self.run_guard(repo)
        self.assertEqual(
            0,
            result.returncode,
            f"the [no changelog] override did not work:\n{result.stdout}\n{result.stderr}",
        )
        self.assertIn("PASSED BY OVERRIDE", result.stdout)

    # ---- controls: the guard must never pass on nothing ----------------------

    def test_empty_diff_fails(self):
        """Zero changed files is a blind guard, not a clean bill of health."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = _new_repo(tmp, self.git)
            result = self.run_guard(repo)
        self.assertNotEqual(
            0,
            result.returncode,
            f"the guard passed on an empty diff:\n{result.stdout}",
        )
        self.assertIn("zero input", result.stdout)

    def test_unresolvable_base_fails(self):
        """A base branch that does not exist must fail, not silently pass."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = _new_repo(tmp, self.git)
            repo.write(SHIPPED_LUA, "-- base\n-- a behaviour change\n")
            repo.commit("feat(guarded): change shipped behaviour")
            result = self.run_guard(repo, base_ref="no-such-branch")
        self.assertNotEqual(
            0,
            result.returncode,
            f"the guard passed with an unresolvable base:\n{result.stdout}",
        )
        self.assertIn("gone blind", result.stdout)

    # ---- the gate is actually wired up --------------------------------------

    def test_step_runs_on_pull_requests(self):
        """The step must carry its pull_request condition, or it never runs."""
        text = CI_WORKFLOW.read_text(encoding="utf-8")
        marker = f"- name: {STEP_NAME}"
        self.assertIn(
            marker, text, f"{STEP_NAME!r} is gone from {CI_WORKFLOW}; the gate is unwired."
        )
        block = text.split(marker, 1)[1].split("- name:", 1)[0]
        self.assertIn(
            "if: github.event_name == 'pull_request'",
            block,
            "the changelog guard lost its pull_request condition.  On a push there "
            "is no base branch, so the step would error on every main build.",
        )

    def test_checkout_keeps_full_history(self):
        """Without fetch-depth: 0 there is no merge base and the guard cannot judge."""
        text = CI_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            "fetch-depth: 0",
            text,
            "actions/checkout in ci.yml no longer requests the full history.  The "
            "changelog guard needs a merge base against the PR's base branch; "
            "without it the step fails for the wrong reason on every PR.",
        )


if __name__ == "__main__":
    unittest.main()
