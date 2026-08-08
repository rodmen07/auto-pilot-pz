"""The unused-ARGUMENT check (luacheck 212), which stays suppressed but no
longer stays unwatched.

``.luacheckrc`` ignores check 212 repo-wide, and that decision is now
PERMANENT (2026-08-08) rather than pending: a function that mirrors a Project
Zomboid callback signature it does not read every parameter of is a fact about
the engine's API, not a defect, and every 212 site in this repo is either that
or the uniform debug-print noop shadow.  What was NOT acceptable was leaving
the check blind, which is the shape that made check 211 hide a live hazard for
months (see :mod:`tests.test_luacheck_unused_locals`).

So the suppression is kept and MONITORED instead of removed.  This module runs
the real linter with ``--enable 212`` against the real ``.luacheckrc`` and
requires every finding to be sanctioned, in both directions:

* a NEW unused argument anywhere in shipped client Lua fails here, even though
  ``luacheck ... --config .luacheckrc`` (what CI's lint step runs) stays green;
* a sanctioned entry whose declaration has disappeared fails too, so the
  allowlist cannot outlive the code it was written for.

THE MEASUREMENT THIS REPLACES WAS WRONG, WHICH IS WHY THE GUARD EXISTS
---------------------------------------------------------------------

The backlog item that asked for this decision recorded ``--enable 212`` as
reporting **3** instances, "every one a genuine signature mirror".  Re-measured
on 2026-08-08 with the CI-pinned luacheck 1.2.0 over the same 24 files, the
real number is **23**:

* **19** ``unused variable length argument`` findings -- one per module carrying
  the ``local function _apNoop(...) end`` debug-print shadow;
* **4** named ``unused argument`` findings (three ``self``, one ``sitOnly``).

Check 212 covers an unused ``...`` as well as an unused named parameter, and
luacheck renders that as "unused variable length argument".  A count taken by
grepping the rendered output for the words "unused argument" therefore sees
**3 of 23** findings and reports a clean-looking number that is off by 20 --
the same class as reading a tool's verdict without reading its scope.  Counting
here is done by parsing every finding line and asserting the linter's own
``Total: ... in N files`` trailer covers every client file, so a run that
silently checked nothing cannot pass as a run that found nothing.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent
LUACHECKRC = ROOT / ".luacheckrc"
CLIENT_DIR = ROOT / "42" / "media" / "lua" / "client"
CLIENT_GLOB = "42/media/lua/client"

LUACHECK = shutil.which("luacheck")

# The debug-print noop shadow, carried verbatim by every module that silences
# print().  Its `...` is the unused vararg luacheck 212 reports, and the shadow
# is uniform by design, so it is sanctioned as a RULE (match the declaration
# line at the reported location) rather than as 19 identical allowlist entries.
NOOP_SHADOW = "local function _apNoop(...) end"

# Named unused arguments that are sanctioned, keyed by (file, argument) and
# anchored to the DECLARATION TEXT rather than a line number, which rots on the
# next edit above it.  If a declaration changes, its entry must be re-justified
# here in the same commit.
SANCTIONED_UNUSED_ARGS: dict[tuple[str, str], tuple[str, str]] = {
    ("AutoPilot_Options.lua", "self"): (
        "PZAPI ModOptions calls apply() on the options object with `:`, so the "
        "method is declared with `:` for call-site symmetry; the body reaches "
        "AutoPilot_Options directly and never needs the instance.",
        "    function o:apply()",
    ),
    ("AutoPilot_Rest.lua", "sitOnly"): (
        "Retained for signature compatibility after the V5.4 design change "
        "stopped it excluding beds (documented at the declaration). Held an "
        "inline `-- luacheck: ignore sitOnly` until 2026-08-08; that comment "
        "was removed because it hid the site from THIS guard as well as from "
        "the linter, which is the opposite of what monitoring the suppression "
        "is for.",
        "local function findRestFurniture(player, sitOnly)",
    ),
    ("AutoPilot_UI.lua", "self"): (
        "Two ISButton/panel methods declared with `:` because that is how the "
        "UI layer calls them (`self.onclick(self.target, self, ...)`); neither "
        "body reads the instance. Declaring them with `.` would move the "
        "unused parameter rather than remove it.",
        "function AutoPilot_UI:_player()",
    ),
}

# A second sanctioned `self` site in the same file needs its own anchor, or the
# entry above would silently cover any future unused `self` in AutoPilot_UI.
EXTRA_ANCHORS: dict[tuple[str, str], tuple[str, ...]] = {
    ("AutoPilot_UI.lua", "self"): ("function AutoPilot_UI:onToggleArm(_button)",),
}

FINDING_RE = re.compile(
    r"^\s*" + re.escape(CLIENT_GLOB) + r"/(?P<file>[\w.]+\.lua)"
    r":(?P<line>\d+):(?P<col>\d+): (?P<message>.+?)\s*$"
)
TRAILER_RE = re.compile(
    r"Total:\s+(?P<warnings>\d+)\s+warnings?\s+/\s+(?P<errors>\d+)\s+errors?\s+"
    r"in\s+(?P<files>\d+)\s+files?"
)
NAMED_ARG_RE = re.compile(r"^unused argument '(?P<name>[^']+)'$")
VARARG_MESSAGE = "unused variable length argument"


def client_files() -> list[str]:
    """Every shipped client Lua file, as forward-slash paths luacheck echoes back."""
    return sorted(f"{CLIENT_GLOB}/{p.name}" for p in CLIENT_DIR.glob("*.lua"))


def run_luacheck(cwd: Path, *args: str) -> subprocess.CompletedProcess:
    """Run the linter in ``cwd`` so it discovers the ``.luacheckrc`` there.

    ``--no-color`` is load-bearing: luacheck renders a reported name bare inside
    SGR escapes when colour is on and quoted when it is off, so the parsing
    below is only stable with colour pinned off.  That difference already cost
    one red CI run on this repo (PR #121).
    """
    return subprocess.run(
        [LUACHECK, "--no-color", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
    )


def parse(stdout: str) -> tuple[list[tuple[str, int, str]], int]:
    """Return ``([(file, line, message), ...], files_checked)``.

    ``files_checked`` comes from luacheck's own trailer, so a run that checked
    nothing is distinguishable from a run that found nothing.  A missing
    trailer returns -1 and every caller treats that as UNVERIFIED.
    """
    findings = []
    for raw in stdout.splitlines():
        m = FINDING_RE.match(raw)
        if m:
            findings.append((m.group("file"), int(m.group("line")), m.group("message")))
    trailer = TRAILER_RE.search(stdout)
    return findings, int(trailer.group("files")) if trailer else -1


def source_line(name: str, line: int) -> str:
    body = (CLIENT_DIR / name).read_text(encoding="utf-8").splitlines()
    return body[line - 1] if 0 < line <= len(body) else ""


@unittest.skipUnless(LUACHECK, "luacheck is not on PATH")
class TestUnusedArgumentsAreContained(unittest.TestCase):
    """Every 212 finding in shipped client Lua is one this repo signed off on."""

    @classmethod
    def setUpClass(cls) -> None:
        files = client_files()
        assert files, "no shipped client Lua found; the guard has gone blind"
        cls.expected_files = len(files)
        result = run_luacheck(ROOT, *files, "--config", ".luacheckrc", "--enable", "212")
        cls.stdout = result.stdout + result.stderr
        cls.findings, cls.files_checked = parse(cls.stdout)

    def test_the_linter_actually_read_every_client_file(self) -> None:
        """Scope before verdict: a report that omitted files would otherwise be
        indistinguishable from a report with nothing to say."""
        self.assertEqual(
            self.files_checked,
            self.expected_files,
            "luacheck's own trailer says it checked "
            f"{self.files_checked} files, not the {self.expected_files} shipped "
            "client Lua files this guard is about; the findings below cover an "
            "unknown subset and prove nothing:\n" + self.stdout,
        )

    def test_findings_were_actually_parsed(self) -> None:
        """The noop shadow alone guarantees findings, so an empty parse means the
        output format moved, not that the tree got cleaner."""
        self.assertGreater(
            len(self.findings),
            0,
            "no 212 findings parsed out of luacheck's output. Either --enable "
            "212 stopped working or the diagnostic format changed; both make "
            "this guard silently vacuous:\n" + self.stdout,
        )

    def test_no_unsanctioned_unused_arguments(self) -> None:
        """GATE: a new unused argument fails here even though CI's lint step,
        which runs the config as shipped, stays green on it."""
        unsanctioned = []
        for name, line, message in self.findings:
            text = source_line(name, line)
            if message == VARARG_MESSAGE:
                if text.strip() == NOOP_SHADOW:
                    continue
                unsanctioned.append((name, line, message, text.strip()))
                continue
            m = NAMED_ARG_RE.match(message)
            if not m:
                unsanctioned.append((name, line, message, text.strip()))
                continue
            key = (name, m.group("name"))
            entry = SANCTIONED_UNUSED_ARGS.get(key)
            if entry is None:
                unsanctioned.append((name, line, message, text.strip()))
                continue
            allowed = {entry[1], *EXTRA_ANCHORS.get(key, ())}
            if text not in allowed:
                unsanctioned.append((name, line, message, text.strip()))

        self.assertEqual(
            unsanctioned,
            [],
            "unsanctioned luacheck 212 findings in shipped client Lua.\n"
            "Check 212 is ignored repo-wide, so the lint step will NOT tell you "
            "about these. Either read the parameter, rename it to `_`, or add it "
            "to SANCTIONED_UNUSED_ARGS above with the reason it mirrors an "
            "engine signature:\n"
            + "\n".join(f"  {n}:{ln}: {msg}  |  {src}" for n, ln, msg, src in unsanctioned),
        )

    def test_every_sanctioned_entry_is_still_reported(self) -> None:
        """A stale entry is deleted with the code it described, or it silently
        pre-approves an unrelated future finding of the same name."""
        reported = set()
        for name, line, message in self.findings:
            m = NAMED_ARG_RE.match(message)
            if m:
                reported.add((name, m.group("name")))
        self.assertEqual(
            reported,
            set(SANCTIONED_UNUSED_ARGS),
            "the sanctioned set and the linter disagree.\n"
            f"  reported but unsanctioned: {sorted(reported - set(SANCTIONED_UNUSED_ARGS))}\n"
            f"  sanctioned but no longer reported (delete the entry): "
            f"{sorted(set(SANCTIONED_UNUSED_ARGS) - reported)}",
        )

    def test_every_sanctioned_anchor_still_exists(self) -> None:
        for key, (_reason, anchor) in sorted(SANCTIONED_UNUSED_ARGS.items()):
            name, arg = key
            body = (CLIENT_DIR / name).read_text(encoding="utf-8")
            for text in (anchor, *EXTRA_ANCHORS.get(key, ())):
                self.assertIn(
                    text,
                    body,
                    f"{name} is sanctioned to leave `{arg}` unused because of "
                    f"`{text.strip()}`, which is no longer in the file. Drop the "
                    "entry, or re-anchor it to the declaration that replaced it.",
                )

    def test_extra_anchors_belong_to_a_sanctioned_entry(self) -> None:
        self.assertEqual(
            set(EXTRA_ANCHORS) - set(SANCTIONED_UNUSED_ARGS),
            set(),
            "EXTRA_ANCHORS names a (file, argument) pair that is not sanctioned, "
            "so the anchors it lists guard nothing",
        )

    def test_noop_shadow_findings_match_the_source(self) -> None:
        """Cross-check with a second instrument: the number of vararg findings
        must equal the number of files literally carrying the shadow."""
        carriers = sum(
            1
            for p in sorted(CLIENT_DIR.glob("*.lua"))
            if NOOP_SHADOW in p.read_text(encoding="utf-8")
        )
        varargs = sum(1 for _n, _l, msg in self.findings if msg == VARARG_MESSAGE)
        self.assertEqual(
            varargs,
            carriers,
            f"luacheck reports {varargs} unused-vararg findings but {carriers} "
            f"client files carry `{NOOP_SHADOW}`. Either a shadow gained a real "
            "use of `...` (fine, but the counts must be re-derived) or an unused "
            "vararg appeared somewhere that is not the shadow.",
        )


@unittest.skipUnless(LUACHECK, "luacheck is not on PATH")
class TestTheGuardIsTheThingThatCatchesIt(unittest.TestCase):
    """The behavior difference, on a synthetic file: 212 findings are invisible
    to the shipped lint and visible to this guard."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        # The REAL config, copied verbatim, so this is a statement about what
        # the repo ships and not about a restatement of it.
        shutil.copyfile(LUACHECKRC, self.tmp / ".luacheckrc")
        (self.tmp / "probe.lua").write_text(
            "local function f(a, b) return a end\nreturn f\n", encoding="utf-8"
        )
        self.addCleanup(self._tmp.cleanup)

    def test_the_shipped_config_does_not_report_it(self) -> None:
        """GATE OFF: this is why the guard has to exist. Same file, config as
        shipped, exit 0 -- CI's lint step would never mention it."""
        result = run_luacheck(self.tmp, "probe.lua")
        self.assertEqual(
            result.returncode,
            0,
            "check 212 is supposed to be ignored repo-wide; a red here means the "
            "ignore list lost it and this guard's premise changed:\n"
            + result.stdout,
        )

    def test_enabling_212_reports_it(self) -> None:
        """GATE ON: the identical file under the flag this guard uses."""
        result = run_luacheck(self.tmp, "probe.lua", "--enable", "212")
        self.assertNotEqual(
            result.returncode,
            0,
            "luacheck accepted an unused argument under --enable 212, so the "
            "flag this guard depends on no longer overrides the ignore list:\n"
            + result.stdout,
        )
        self.assertNotIn(
            "\x1b",
            result.stdout,
            "luacheck emitted ANSI escapes despite --no-color; every assertion "
            "here parses rendered text and cannot be trusted:\n"
            + repr(result.stdout),
        )
        for fragment in ("probe.lua:1:21", "unused argument", "'b'"):
            self.assertIn(
                fragment,
                result.stdout,
                f"expected {fragment!r} in the 212 diagnostic:\n" + result.stdout,
            )

    def test_a_clean_file_still_passes_under_the_flag(self) -> None:
        """So a red above is the probe, not the harness."""
        (self.tmp / "clean.lua").write_text(
            "local function f(a) return a end\nreturn f\n", encoding="utf-8"
        )
        result = run_luacheck(self.tmp, "clean.lua", "--enable", "212")
        self.assertEqual(
            result.returncode,
            0,
            "a file with no findings should pass:\n" + result.stdout + result.stderr,
        )


class TestTheSuppressionIsRecordedWhereItLives(unittest.TestCase):
    """Cheap text assertions tying the decision to the config that implements it."""

    def _ignore_list(self) -> list[str]:
        text = LUACHECKRC.read_text(encoding="utf-8")
        matches = list(re.finditer(r"^ignore\s*=\s*\{([^}]*)\}", text, re.MULTILINE))
        self.assertEqual(
            len(matches),
            1,
            f"expected exactly one active `ignore = {{...}}` line, found {len(matches)}",
        )
        return re.findall(r'"(\d+)"', matches[0].group(1))

    def test_212_is_the_only_repo_wide_suppression(self) -> None:
        """If a third check is ever ignored repo-wide it needs its own guard, so
        this fails rather than letting a new blind spot ride in silently."""
        self.assertEqual(
            self._ignore_list(),
            ["212"],
            "the repo-wide luacheck ignore list changed. 212 is monitored by "
            "this module; anything added beside it is unmonitored until it gets "
            "the same treatment.",
        )

    def test_the_config_points_at_this_guard(self) -> None:
        self.assertIn(
            "tests/test_luacheck_unused_args.py",
            LUACHECKRC.read_text(encoding="utf-8"),
            ".luacheckrc must name the guard that monitors its 212 suppression, "
            "or the next reader sees only the suppression",
        )
