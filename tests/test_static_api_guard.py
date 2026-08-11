"""The deprecated-API scan, and the corpus probe that keeps it honest.

``.github/workflows/ci.yml``'s **Static API Guard** step scans the shipped
client Lua for Build 41 stat getters that Build 42 removed
(``:getHunger()`` and friends, ``CharacterStats.``).  It decides from an EMPTY
grep result -- five greps, and if none of them matches, the step prints PASSED.

Until this module was written, nothing checked that those greps could match
anything at all.  The corpus is named by a hardcoded relative path, and::

    grep -rn --include="*.lua" -- "$pattern" 42/media/lua/client/

against an absent directory (or one holding no ``.lua`` file) exits non-zero for
every pattern, leaving ``FOUND`` at 0.  Measured on a tree with no ``42/`` at
all, before the fix: five ``No such file or directory`` lines on stderr, then
``Static API Guard PASSED: no deprecated APIs detected``, exit 0.
:meth:`TestBlindCorpus.test_the_legacy_scan_passed_on_an_absent_corpus` keeps
that original body in the suite and asserts it still behaves that way, so the
defect this module closes cannot quietly become folklore.

It was the last ``run:`` step in ``lint-and-test`` deciding from an empty result
with no blind guard.  Its neighbours all fail closed already: the changelog
guard on an unresolvable base, the Action pin guard on zero ``uses:`` lines, the
Lua test discovery on zero test files, the checkout credential guard on a config
it cannot read.

The realistic way this one goes blind is a MOVE, not a deletion.  The same path
is hardcoded at four sites across two files (this scan and the ``luacheck`` line
in ``ci.yml``, and check.sh's copy of each), and ``docs/b42_20_checklist.md``
plans a Build-42.20 layout change.  An edit that updates the lint line and
misses the scan leaves luacheck happily linting the new directory while this
guard reports a clean scan of nothing.

What ships instead is a POSITIVE CONTROL in the same shape the checkout
credential guard uses one step earlier: the guard first runs its own grep form
-- recursive, the same ``--include`` glob, the same directory -- for the mod's
namespace prefix, and refuses to scan when that reaches zero files.  One command
proves both that the corpus resolves and that this invocation reaches it, which
a bare ``test -d`` would not.

This module is the guard on the guard.  Same drift-guard shape as
:mod:`tests.test_luacheck_pin` and :mod:`tests.test_changelog_guard`: it
extracts the real script out of the yaml and **executes it** against synthetic
trees in every direction, and it holds check.sh's second copy of the same guard
to the same standard by executing that block too -- a test that merely read
either one would be asserting about text rather than about behaviour.

Both homes are also pinned to ONE pattern list and ONE corpus directory here.
A local gate and a merge gate that disagree about what counts as a deprecated
API is the drift this repo has been bitten by before (``check.sh``'s luacheck
version, fixed by deriving it from the workflow in :mod:`tests.test_luacheck_pin`).
"""

from __future__ import annotations

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

GUARD_STEP = "Static API Guard"

BASH = shutil.which("bash")

# `DEPRECATED_PATTERNS=(` ... `)`, in either home.  Text rather than a yaml or
# shell parse on purpose: this repo's Python surface is stdlib-only plus pytest,
# a deliberate DevSecOps posture, and reading one array does not justify
# widening it.
PATTERN_ARRAY = re.compile(r"DEPRECATED_PATTERNS=\(\n(?P<body>.*?)\n[ \t]*\)", re.S)

# The probe's grep, from which both the corpus directory variable and the
# sentinel token are read.  Extracted rather than restated so this test cannot
# be the thing that drifts.
PROBE_GREP = re.compile(
    r"""grep -rl --include="\*\.lua" -e '(?P<sentinel>[^']+)' -- "\$\{(?P<var>\w+)\}\"""",
)

DIR_ASSIGNMENT = "{var}=\"{value}\""

# check.sh's copy runs inside a larger script with shared counters, so it is
# delimited by its first executable line and the banner of the section after it.
CHECK_SH_START = "API_GUARD_DIR="
CHECK_SH_END = "# M4.3 Line-count guard"

# The ORIGINAL scan body, kept verbatim as an always-on negative control.  This
# is what the workflow ran before the corpus probe existed; the test that uses
# it asserts it really did report a clean scan of an absent corpus, which is the
# whole reason the probe was added.
LEGACY_SCAN = """\
echo "=== Static API Guard: checking for deprecated PZ APIs ==="
DEPRECATED_PATTERNS=(
  ":getHunger()"
  ":getThirst()"
  ":getFatigue()"
  ":getEndurance()"
  "CharacterStats\\."
)
FOUND=0
for pattern in "${DEPRECATED_PATTERNS[@]}"; do
  if grep -rn --include="*.lua" -- "$pattern" 42/media/lua/client/; then
    echo "ERROR: Deprecated API pattern found: $pattern"
    FOUND=$((FOUND + 1))
  fi
done
if [ "$FOUND" -gt 0 ]; then
  echo "Static API Guard FAILED: $FOUND deprecated pattern(s) detected."
  exit 1
fi
echo "Static API Guard PASSED: no deprecated APIs detected."
"""


def _workflow_text() -> str:
    return CI_WORKFLOW.read_text(encoding="utf-8")


def _ci_script() -> str:
    return extract_step_script(_workflow_text(), GUARD_STEP)


def _check_sh_block() -> str:
    """check.sh's copy of the guard, from its first statement to the next section."""
    text = CHECK_SH.read_text(encoding="utf-8")
    start = text.find(CHECK_SH_START)
    end = text.find(CHECK_SH_END)
    if start < 0 or end < 0 or end <= start:
        raise AssertionError(
            f"could not locate check.sh's Static API Guard block between "
            f"{CHECK_SH_START!r} and {CHECK_SH_END!r}.  The extractor has gone "
            "blind; it must never return an empty block and let the tests below "
            "pass on nothing."
        )
    block = text[start:end].strip()
    if not block:
        raise AssertionError("check.sh's Static API Guard block extracted EMPTY.")
    return block


def _patterns(script: str) -> list[str]:
    """The deprecated patterns declared in one home, in file order."""
    match = PATTERN_ARRAY.search(script)
    if match is None:
        raise AssertionError(
            "no DEPRECATED_PATTERNS array found: the scan has no patterns to look for."
        )
    out = [line.strip().strip('"') for line in match.group("body").splitlines() if line.strip()]
    if not out:
        raise AssertionError("DEPRECATED_PATTERNS is EMPTY: the scan would check nothing.")
    return out


def _probe(script: str) -> tuple[str, str]:
    """``(sentinel, corpus_directory)`` as the probe in ``script`` really spells them."""
    match = PROBE_GREP.search(script)
    if match is None:
        raise AssertionError(
            "no corpus probe found.  Without it the scan reports PASSED on an "
            "unreachable corpus, which is the defect this module exists to keep closed."
        )
    var = match.group("var")
    assignment = re.search(
        re.escape(var) + r'="(?P<value>[^"]+)"',
        script,
    )
    if assignment is None:
        raise AssertionError(f"the probe reads ${{{var}}} but nothing assigns it.")
    return match.group("sentinel"), assignment.group("value")


def _require_bash() -> str:
    if BASH:
        return BASH
    if sys.platform == "win32":
        raise unittest.SkipTest(
            "bash not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        "bash not found on a POSIX runner: the Static API Guard must not skip in CI."
    )


def _tree(root: Path, files: dict[str, str]) -> None:
    for rel, body in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8", newline="\n")


def _run(script: str, files: dict[str, str], preamble: str = "") -> subprocess.CompletedProcess:
    """Execute a guard body with ``cwd`` at a synthetic repository root."""
    bash = _require_bash()
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        _tree(tmpdir, files)
        script_path = tmpdir / "guard.sh"
        script_path.write_text(preamble + script + "\n", encoding="utf-8", newline="\n")
        return subprocess.run(
            [bash, "-e", str(script_path)],
            capture_output=True,
            text=True,
            cwd=str(tmpdir),
        )


def _run_check_sh_block(files: dict[str, str]) -> subprocess.CompletedProcess:
    """check.sh's block, with the counters it shares with the rest of that script."""
    preamble = "set -euo pipefail\nPASS=0\nFAIL=0\n"
    result = _run(
        _check_sh_block() + '\nprintf "COUNTERS PASS=%s FAIL=%s\\n" "$PASS" "$FAIL"\n',
        files,
        preamble,
    )
    return result


def _sentinel() -> str:
    return _probe(_ci_script())[0]


def _corpus_dir() -> str:
    return _probe(_ci_script())[1]


def _clean_corpus(extra: str = "") -> dict[str, str]:
    """Two modules that look like the real ones: namespaced, modern stat API."""
    sentinel = _sentinel()
    corpus = _corpus_dir()
    return {
        f"{corpus}/{sentinel}_Alpha.lua": (
            f"{sentinel}_Alpha = {{}}\n"
            f"function {sentinel}_Alpha.hunger(p)\n"
            "  return p:getStats():get(CharacterStat.HUNGER)\n"
            f"end\n{extra}"
        ),
        f"{corpus}/{sentinel}_Beta.lua": (
            f"{sentinel}_Beta = {{}}\nfunction {sentinel}_Beta.noop() end\n"
        ),
    }


class TestBothHomesAgree(unittest.TestCase):
    """One pattern list, one corpus, in the merge gate and the local gate."""

    def test_the_step_exists_in_the_workflow(self) -> None:
        self.assertIn(
            GUARD_STEP,
            step_names(_workflow_text()),
            f"step {GUARD_STEP!r} is missing from ci.yml.",
        )

    def test_the_pattern_lists_are_identical(self) -> None:
        ci = _patterns(_ci_script())
        local = _patterns(_check_sh_block())
        self.assertEqual(
            ci,
            local,
            "ci.yml and check.sh disagree about which APIs are deprecated. "
            "A local 'PASS' would then say nothing about the gate that judges "
            "the merge, which is exactly the drift the luacheck pin removed.",
        )

    def test_the_pattern_list_still_covers_the_build_41_getters(self) -> None:
        ci = _patterns(_ci_script())
        for expected in (":getHunger()", ":getThirst()", ":getFatigue()", ":getEndurance()"):
            self.assertIn(
                expected,
                ci,
                f"{expected} is the Build 41 stat getter this guard exists to keep out.",
            )

    def test_both_homes_probe_the_same_corpus_with_the_same_sentinel(self) -> None:
        ci_sentinel, ci_dir = _probe(_ci_script())
        local_sentinel, local_dir = _probe(_check_sh_block())
        self.assertEqual(ci_sentinel, local_sentinel)
        self.assertEqual(
            ci_dir,
            local_dir,
            "the two homes scan different directories: one of them is looking "
            "at a corpus the other does not.",
        )


class TestBlindCorpus(unittest.TestCase):
    """The regression: a scan that reaches nothing must never report clean."""

    def test_the_legacy_scan_passed_on_an_absent_corpus(self) -> None:
        """Always-on negative control: the defect was real, and stays disproved."""
        result = _run(LEGACY_SCAN, {"README.md": "no mod tree here at all\n"})
        self.assertEqual(
            0,
            result.returncode,
            "the pre-probe scan is supposed to demonstrate the DEFECT here; if it "
            "now fails, this control no longer proves anything and must be re-derived.",
        )
        self.assertIn("Static API Guard PASSED", result.stdout)
        self.assertIn("No such file or directory", result.stderr)

    def test_ci_guard_fails_when_the_corpus_directory_is_absent(self) -> None:
        result = _run(_ci_script(), {"README.md": "no mod tree here at all\n"})
        self.assertEqual(
            1, result.returncode, f"guard passed with no corpus at all:\n{result.stdout}"
        )
        self.assertIn("reaches 0 Lua file(s)", result.stdout)
        self.assertIn("gone blind", result.stdout)
        self.assertNotIn("Static API Guard PASSED", result.stdout)

    def test_ci_guard_fails_when_the_directory_holds_no_lua_file(self) -> None:
        """A move that leaves the directory behind is the same blindness."""
        corpus = _corpus_dir()
        result = _run(_ci_script(), {f"{corpus}/README.md": "moved to 43/\n"})
        self.assertEqual(
            1, result.returncode, f"guard passed on a .lua-free corpus:\n{result.stdout}"
        )
        self.assertIn("reaches 0 Lua file(s)", result.stdout)

    def test_ci_guard_fails_when_no_lua_file_carries_the_sentinel(self) -> None:
        """The probe's exact contract, stated as behaviour rather than as prose."""
        corpus = _corpus_dir()
        result = _run(_ci_script(), {f"{corpus}/Unrelated.lua": "local x = 1\n"})
        self.assertEqual(
            1,
            result.returncode,
            f"guard passed on a corpus its own grep form cannot reach:\n{result.stdout}",
        )
        self.assertIn("reaches 0 Lua file(s)", result.stdout)

    def test_check_sh_block_fails_when_the_corpus_directory_is_absent(self) -> None:
        result = _run_check_sh_block({"README.md": "no mod tree here at all\n"})
        self.assertIn("reaches 0 Lua file(s)", result.stdout)
        self.assertIn("COUNTERS PASS=0 FAIL=1", result.stdout)
        self.assertNotIn("PASS  Static API Guard", result.stdout)


class TestGuardBehaviourDifference(unittest.TestCase):
    """The scan itself, executed in both directions, one control per pattern."""

    def test_ci_guard_passes_on_a_clean_corpus_and_says_what_it_read(self) -> None:
        result = _run(_ci_script(), _clean_corpus())
        self.assertEqual(
            0, result.returncode, f"guard failed on a clean corpus:\n{result.stdout}"
        )
        self.assertIn("Corpus probe: the scan reaches 2 Lua file(s)", result.stdout)
        self.assertIn("Static API Guard PASSED", result.stdout)

    def test_ci_guard_fails_on_each_deprecated_pattern_separately(self) -> None:
        """One offending file per pattern: a shared fixture would let four hide behind one."""
        corpus = _corpus_dir()
        sentinel = _sentinel()
        for pattern in _patterns(_ci_script()):
            with self.subTest(pattern=pattern):
                # `CharacterStats\.` is a regex in the shell array; the literal
                # a real module would carry is the same text without the escape.
                literal = pattern.replace("\\", "")
                files = _clean_corpus()
                files[f"{corpus}/{sentinel}_Offender.lua"] = (
                    f"{sentinel}_Offender = {{}}\n"
                    f"function {sentinel}_Offender.read(p) return p{literal} end\n"
                )
                result = _run(_ci_script(), files)
                self.assertEqual(
                    1,
                    result.returncode,
                    f"guard passed a module using {literal!r}:\n{result.stdout}",
                )
                self.assertIn("Static API Guard FAILED", result.stdout)
                self.assertIn(pattern, result.stdout)

    def test_check_sh_block_passes_on_a_clean_corpus(self) -> None:
        result = _run_check_sh_block(_clean_corpus())
        self.assertIn("PASS  Static API Guard", result.stdout)
        self.assertIn("COUNTERS PASS=1 FAIL=0", result.stdout)

    def test_check_sh_block_fails_on_a_deprecated_pattern(self) -> None:
        corpus = _corpus_dir()
        sentinel = _sentinel()
        files = _clean_corpus()
        files[f"{corpus}/{sentinel}_Offender.lua"] = (
            f"{sentinel}_Offender = {{}}\n"
            f"function {sentinel}_Offender.read(p) return p:getHunger() end\n"
        )
        result = _run_check_sh_block(files)
        self.assertIn("FAIL  Static API Guard", result.stdout)
        self.assertIn("COUNTERS PASS=0 FAIL=1", result.stdout)


class TestTheRealCorpus(unittest.TestCase):
    """The probe must not be about to fire on the repository as it stands."""

    def test_the_shipped_corpus_satisfies_the_probe(self) -> None:
        sentinel, corpus = _probe(_ci_script())
        modules = sorted((ROOT / corpus).glob("*.lua"))
        self.assertGreater(
            len(modules),
            0,
            f"{corpus}/ holds no .lua files: the guard's corpus has moved and "
            "both homes must move with it.",
        )
        reachable = [m for m in modules if sentinel in m.read_text(encoding="utf-8")]
        self.assertEqual(
            len(modules),
            len(reachable),
            f"{len(modules) - len(reachable)} shipped module(s) do not contain "
            f"{sentinel!r}, so the probe under-counts the corpus. The guard still "
            "works (it needs one file, not all of them), but the reported count "
            "would no longer be the number of modules scanned.",
        )


if __name__ == "__main__":
    unittest.main()
