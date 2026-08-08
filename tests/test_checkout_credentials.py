"""The checkout credential guard, exercised on every push and pull request.

``actions/checkout`` persists the job's ``GITHUB_TOKEN`` by default.  That is
not a documentation reading: ``persist-credentials`` is declared
``default: true`` in ``action.yml`` at commit
``3d3c42e5aac5ba805825da76410c181273ba90b1`` (v7.0.1), the exact SHA both
workflows pin.

What the token's persistence actually looks like in v7 is worth stating,
because it is no longer the shape most write-ups describe.  The action does not
put the header in ``.git/config``.  It writes
``$RUNNER_TEMP/git-credentials-<uuid>.config`` containing::

    [http "https://github.com/"]
        extraheader = AUTHORIZATION: basic <base64 x-access-token:TOKEN>

and adds ``includeIf.gitdir:<workspace>/.git.path`` in ``.git/config`` pointing
at it, so ``git config`` resolves the header from anywhere inside the workspace
all the same.  ``src/git-source-provider.ts`` removes it in a ``finally`` block
**only** when persistence is off::

    if (!settings.persistCredentials) {
      core.startGroup('Removing auth')
      await authHelper.removeAuth()

With persistence on, the removal instead happens in the ``Post`` phase of the
checkout step -- after every other step in the job has already run.

This repository has two checkouts and both were exposed.  ``ci.yml``'s job then
installs ``requirements-dev.txt`` from PyPI and ``luacheck`` from luarocks, and
``release.yml``'s job holds ``contents: write`` and hands control to a
third-party action; all of that ran with a live token readable from the
workspace.

It was proven live rather than argued.  The guard below was pushed to PR #135
**without** the fix, and CI run ``31272670005`` failed in 4 seconds with::

    FOUND a persisted HTTP auth header:
      http.https://github.com/.extraheader <redacted>
    FOUND an includeIf entry pointing at a credentials config file:
    Checkout credential guard FAILED: 2 credential surface(s) survive the checkout.

Two layers keep it fixed, because one cannot cover both workflows:

* ``ci.yml``'s ``Checkout credential guard`` step asserts the property AT RUN
  TIME, on the real runner, immediately after checkout.  It also covers tag
  pushes, because ``release.yml``'s CI gate job calls ``ci.yml``.
* :class:`TestEveryCheckoutOptsOut` asserts the yaml line itself, which is the
  only reachable check for ``release.yml``'s own ``release`` job -- no pull
  request ever executes it.

:class:`TestGuardScriptBothDirections` extracts the run-time guard's script out
of the workflow yaml and executes it under ``bash`` against synthetic
repositories, so the workflow stays the single source of truth and a guard that
stops being able to fail fails HERE instead of silently passing forever.  Same
shape as :mod:`tests.test_changelog_guard` and :mod:`tests.test_release_gate`,
and it exists for the same reason: a CI step nothing exercises is an inert
surface by default.
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
WORKFLOW_DIR = ROOT / ".github" / "workflows"
CI_WORKFLOW = WORKFLOW_DIR / "ci.yml"

STEP_NAME = "Checkout credential guard"

BASH = shutil.which("bash")
GIT = shutil.which("git")

# A plausible-looking token, so the redaction assertion has something concrete
# to prove never reaches the log.  It is not a credential of any kind.
FAKE_TOKEN = "AUTHORIZATION: basic eC1hY2Nlc3MtdG9rZW46bm90LWEtcmVhbC10b2tlbg=="


def _require_tools() -> tuple[str, str]:
    """Return ``(bash, git)``, or fail loudly rather than skip where it matters.

    A POSIX runner missing either tool is a broken CI environment, not a reason
    to report success.  A Windows dev box without Git Bash on PATH is the only
    sanctioned skip, matching tests/test_changelog_guard.py.
    """
    if BASH and GIT:
        return BASH, GIT
    missing = ", ".join(n for n, v in (("bash", BASH), ("git", GIT)) if not v)
    if sys.platform == "win32":
        raise unittest.SkipTest(
            f"{missing} not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        f"{missing} not found on a POSIX runner: the credential guard must not skip in CI."
    )


def checkout_steps(workflow_text: str) -> list[tuple[int, str | None]]:
    """Return ``(line_number, persist_credentials_value)`` per checkout step.

    ``None`` means the step declares no ``persist-credentials`` at all, which is
    the dangerous state: the input defaults to ``true``.
    """
    lines = workflow_text.splitlines()
    found: list[tuple[int, str | None]] = []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if "actions/checkout@" not in stripped:
            continue
        if not stripped.startswith(("- uses:", "uses:")):
            continue
        indent = len(line) - len(line.lstrip())
        body_indent = indent + 2 if stripped.startswith("- ") else indent

        value: str | None = None
        for nxt in lines[i + 1:]:
            if not nxt.strip():
                continue
            nxt_indent = len(nxt) - len(nxt.lstrip())
            if nxt_indent < body_indent or nxt.strip().startswith("- "):
                break
            body = nxt.strip()
            if body.startswith("#"):
                continue
            if body.startswith("persist-credentials:"):
                value = body.split(":", 1)[1].strip()
        found.append((i + 1, value))
    return found


class TestEveryCheckoutOptsOut(unittest.TestCase):
    """Every ``actions/checkout`` in this repo must turn persistence off."""

    def setUp(self) -> None:
        self.workflows = sorted(
            p for p in WORKFLOW_DIR.iterdir() if p.suffix in (".yml", ".yaml")
        )
        self.assertTrue(
            self.workflows,
            f"no workflow files under {WORKFLOW_DIR}: this scan has gone blind.",
        )

    def test_the_scan_finds_the_checkouts_that_exist(self) -> None:
        """Blind guard: a scan that matches nothing must not report success.

        Deliberately NOT "parsed count equals substring count".  That was the
        first draft and it went red on its first run for the wrong reason:
        ci.yml's own Action-pin-guard failure message quotes a pinned
        ``actions/checkout@<sha>`` inside an ``echo``, so the substring count is
        3 against 2 real steps.  It was also close to tautological, since the
        parser starts from the same ``uses:`` line prefix a text search would.
        What is checked instead is coverage per FILE: any workflow that mentions
        the action at all must yield at least one parsed step, which still
        catches a parser that has gone blind without being fooled by prose.
        """
        parsed = {
            p.name: checkout_steps(p.read_text(encoding="utf-8"))
            for p in self.workflows
        }
        self.assertGreaterEqual(
            sum(len(v) for v in parsed.values()),
            2,
            f"expected at least the ci.yml and release.yml checkouts, got {parsed}",
        )
        for name in ("ci.yml", "release.yml"):
            self.assertIn(name, parsed, f"{name} is gone from {WORKFLOW_DIR}.")
            self.assertTrue(
                parsed[name],
                f"{name} parses to zero checkout steps; the scan has gone blind.",
            )
        for path in self.workflows:
            if "actions/checkout@" in path.read_text(encoding="utf-8"):
                self.assertTrue(
                    parsed[path.name],
                    f"{path.name} names actions/checkout but the parser found no step "
                    f"in it; it has drifted from the yaml.",
                )

    def test_no_checkout_persists_the_job_token(self) -> None:
        for path in self.workflows:
            for line_no, value in checkout_steps(path.read_text(encoding="utf-8")):
                with self.subTest(workflow=path.name, line=line_no):
                    self.assertIsNotNone(
                        value,
                        f"{path.name}:{line_no} declares no persist-credentials, and the "
                        f"input DEFAULTS TO TRUE, so the job token stays readable from "
                        f"the workspace for every step that follows.",
                    )
                    self.assertEqual(
                        value,
                        "false",
                        f"{path.name}:{line_no} sets persist-credentials: {value!r}.",
                    )

    def test_the_parser_can_actually_see_a_missing_opt_out(self) -> None:
        """The scan's other direction: it must FAIL on a workflow that omits it."""
        exposed = (
            "jobs:\n"
            "  build:\n"
            "    steps:\n"
            "      - uses: actions/checkout@" + "0" * 40 + " # v7.0.1\n"
            "        with:\n"
            "          fetch-depth: 0\n"
            "      - name: next\n"
            "        run: echo hi\n"
        )
        self.assertEqual(checkout_steps(exposed), [(4, None)])

        fixed = exposed.replace(
            "          fetch-depth: 0\n",
            "          fetch-depth: 0\n          persist-credentials: false\n",
        )
        self.assertEqual(checkout_steps(fixed), [(4, "false")])

    def test_the_guard_runs_before_any_third_party_code(self) -> None:
        """Ordering is the point: a token is only safe if nothing read it first."""
        text = CI_WORKFLOW.read_text(encoding="utf-8")
        names = [
            line.strip()[len("- name: "):]
            for line in text.splitlines()
            if line.strip().startswith("- name: ")
        ]
        self.assertIn(STEP_NAME, names, f"{STEP_NAME!r} is gone from ci.yml.")
        guard_at = names.index(STEP_NAME)
        for later in ("Install Python dependencies", "Install Lua and luacheck"):
            self.assertIn(later, names)
            self.assertLess(
                guard_at,
                names.index(later),
                f"{STEP_NAME!r} must run before {later!r}: that step executes code "
                f"fetched from a public registry inside this job.",
            )


class TestGuardScriptBothDirections(unittest.TestCase):
    """Run the real workflow script against repositories built from scratch."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.bash, cls.git = _require_tools()
        cls.script = extract_step_script(
            CI_WORKFLOW.read_text(encoding="utf-8"), STEP_NAME
        )

    def _run(self, cwd: Path, home: Path) -> subprocess.CompletedProcess[str]:
        script = Path(cwd) / "_guard.sh"
        # The guard inspects git config, so the environment must not leak a dev
        # box's global config into the verdict in either direction.
        script.write_text(self.script, encoding="utf-8", newline="\n")
        env = dict(os.environ)
        env["HOME"] = str(home)
        env["GIT_CONFIG_GLOBAL"] = str(home / ".gitconfig")
        env["GIT_CONFIG_SYSTEM"] = str(home / ".gitconfig-system")
        (home / ".gitconfig").write_text("", encoding="utf-8")
        (home / ".gitconfig-system").write_text("", encoding="utf-8")
        return subprocess.run(
            [self.bash, "-e", str(script)],
            cwd=str(cwd),
            env=env,
            capture_output=True,
            text=True,
        )

    def _repo(self, tmp: Path, *, with_origin: bool = True) -> Path:
        repo = tmp / "repo"
        repo.mkdir()
        subprocess.run([self.git, "init", "-q", "."], cwd=str(repo), check=True)
        if with_origin:
            subprocess.run(
                [self.git, "config", "remote.origin.url",
                 "https://github.com/rodmen07/auto-pilot-pz"],
                cwd=str(repo),
                check=True,
            )
        return repo

    def test_a_clean_checkout_passes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            home = tmp / "home"
            home.mkdir()
            repo = self._repo(tmp)
            result = self._run(repo, home)
            self.assertEqual(
                result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
            self.assertIn("PASSED", result.stdout)

    def test_the_v7_includeif_shape_is_caught(self) -> None:
        """The shape actions/checkout actually leaves behind at the pinned SHA."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            home = tmp / "home"
            home.mkdir()
            repo = self._repo(tmp)
            creds = tmp / "git-credentials-deadbeef.config"
            subprocess.run(
                [self.git, "config", "--file", str(creds),
                 "http.https://github.com/.extraheader", FAKE_TOKEN],
                cwd=str(repo),
                check=True,
            )
            gitdir = (repo / ".git").as_posix()
            subprocess.run(
                [self.git, "config", f"includeIf.gitdir:{gitdir}.path", str(creds)],
                cwd=str(repo),
                check=True,
            )
            result = self._run(repo, home)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("includeIf entry pointing at a credentials config", result.stdout)
            self.assertIn("FAILED", result.stdout)

    def test_a_persisted_extraheader_is_caught_and_redacted(self) -> None:
        """The classic shape, plus: the guard must never print the secret."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            home = tmp / "home"
            home.mkdir()
            repo = self._repo(tmp)
            subprocess.run(
                [self.git, "config", "http.https://github.com/.extraheader", FAKE_TOKEN],
                cwd=str(repo),
                check=True,
            )
            result = self._run(repo, home)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("persisted HTTP auth header", result.stdout)
            self.assertIn("<redacted>", result.stdout)
            combined = result.stdout + result.stderr
            self.assertNotIn(
                FAKE_TOKEN.split()[-1],
                combined,
                "the guard printed the credential it was reporting on.",
            )

    def test_a_persisted_ssh_command_is_caught(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            home = tmp / "home"
            home.mkdir()
            repo = self._repo(tmp)
            subprocess.run(
                [self.git, "config", "core.sshCommand", "ssh -i /tmp/deploy_key"],
                cwd=str(repo),
                check=True,
            )
            result = self._run(repo, home)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("core.sshCommand", result.stdout)

    def test_it_fails_blind_when_the_local_config_reads_empty(self) -> None:
        """Absence and unreadability look identical, so the probe must gate them."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            home = tmp / "home"
            home.mkdir()
            repo = self._repo(tmp, with_origin=False)
            result = self._run(repo, home)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("gone blind", result.stdout)

    def test_it_fails_blind_outside_a_git_working_tree(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            home = tmp / "home"
            home.mkdir()
            plain = tmp / "plain"
            plain.mkdir()
            result = self._run(plain, home)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("gone blind", result.stdout)


if __name__ == "__main__":
    unittest.main()
