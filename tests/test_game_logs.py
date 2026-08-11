"""
Game log validation — parse PZ console.txt and the AutoPilot telemetry run
log for evidence of runtime health.

Two independent data sources, because they prove different things:

- console.txt: catches genuine engine-level errors. Every AutoPilot module
  shadows Lua's `print` with a no-op (see AutoPilot_Needs.lua,
  AutoPilot_Medical.lua, AutoPilot_Home.lua, and 9 others — routine per-tick
  chatter is silenced so a long session doesn't spam the log), so this file
  can never be used to prove the mod DID something; it can only prove PZ or
  the mod threw an error, via `_realPrint` escape-hatch calls (AutoPilot_Main)
  and genuine Java exceptions, both of which bypass the shadow.
- auto_pilot_run.log (parsed via triage_run_log.py, the same parser
  tools/triage.md and the CLI use): the mod's own telemetry, written from
  inside its live tick loop. A well-formed entry is real evidence the mod
  loaded and executed, which console.txt cannot provide (verified 2026-07-20:
  a real console.txt from a session that ran fine and later died contains
  zero "autopilot" matches, case-insensitive).

Run:  pytest tests/test_game_logs.py -v
Skip: each test class is skipped automatically if its data source is absent.
"""

from __future__ import annotations

import pathlib
import re
import tempfile
import unittest

import triage_run_log as tr

CONSOLE_LOG = pathlib.Path.home() / "Zomboid" / "console.txt"
RUN_LOG = pathlib.Path.home() / "Zomboid" / "Lua" / "auto_pilot_run.log"

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONSTANTS_LUA = REPO_ROOT / "42" / "media" / "lua" / "client" / "AutoPilot_Constants.lua"


def tree_build() -> str:
    """The build stamp the CURRENT source tree writes into the run log.

    Read from ``AutoPilot_Constants.VERSION`` — the same value
    AutoPilot_Telemetry stamps onto every schema-v6 line — rather than from
    mod.info, so this compares against what the code under test would actually
    write.  (The two cannot drift: tests/test_version_constant.lua and
    tests/test_version_sync.py bind VERSION to ``modversion=`` in both
    mod.info files.)

    Hard-fails on a miss instead of returning a default.  A silent "" here
    would make the gate below compare against the unstamped sentinel and start
    failing on ancient sessions — an existence search that passes vacuously is
    exactly the shape this whole increment exists to remove.
    """
    text = CONSTANTS_LUA.read_text(encoding="utf-8", errors="replace")
    match = re.search(r'^AutoPilot_Constants\.VERSION\s*=\s*"([^"]+)"',
                      text, re.MULTILINE)
    if match is None:
        raise AssertionError(
            f"no AutoPilot_Constants.VERSION assignment in {CONSTANTS_LUA}")
    return match.group(1)

# Patterns that indicate AutoPilot Lua errors
LUA_ERROR_PATTERNS = [
    re.compile(r"ERROR.*AutoPilot", re.IGNORECASE),
    re.compile(r"java\.lang\.\w+Exception.*auto_pilot", re.IGNORECASE),
    re.compile(r"LuaError.*AutoPilot", re.IGNORECASE),
    re.compile(r"attempted to call.*nil.*AutoPilot", re.IGNORECASE),
]


def _read_log(path: pathlib.Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


@unittest.skipUnless(CONSOLE_LOG.exists(), "No PZ console.txt found")
class TestConsoleLogErrors(unittest.TestCase):
    """Check PZ console.txt for AutoPilot-related errors."""

    @classmethod
    def setUpClass(cls):
        cls.lines = _read_log(CONSOLE_LOG)

    def test_no_lua_errors(self):
        errors = []
        for line in self.lines:
            for pattern in LUA_ERROR_PATTERNS:
                if pattern.search(line):
                    errors.append(line.strip())
                    break
        self.assertEqual(errors, [],
                         f"Found {len(errors)} AutoPilot error(s) in console.txt:\n"
                         + "\n".join(errors[:10]))

    def test_no_java_exceptions_from_mod(self):
        java_errors = [
            line.strip() for line in self.lines
            if "Exception" in line and "auto_pilot" in line.lower()
        ]
        self.assertEqual(java_errors, [],
                 "Java exceptions related to AutoPilot:\n"
                 + "\n".join(java_errors[:10]))


@unittest.skipUnless(RUN_LOG.exists(), "No AutoPilot run log found")
class TestModRanSuccessfully(unittest.TestCase):
    """Check the telemetry run log for evidence the mod loaded and executed.

    Replaces two console-print-based checks (test_mod_loaded_successfully,
    test_medical_module_loaded) that could never pass: both modules' "loaded"
    prints are shadowed to no-ops, so no console.txt from any session, healthy
    or not, would ever satisfy them. A well-formed telemetry entry is only
    written from inside the mod's live tick loop, so it is real, achievable
    evidence of successful load — a Medical-specific load failure (a syntax
    error in that file) would already be caught by test_no_lua_errors above,
    since AutoPilot_Medical is dofile'd unconditionally by Main.
    """

    def test_run_log_has_well_formed_entries(self):
        entries, _skipped = tr.parse_run_log(RUN_LOG)
        self.assertGreater(
            len(entries), 0,
            "auto_pilot_run.log exists but has no parseable entries — "
            "check for a Lua syntax error preventing the mod from loading")


@unittest.skipUnless(RUN_LOG.exists(), "No AutoPilot run log found")
class TestRunLogSuspiciousPatterns(unittest.TestCase):
    """Detect action spam and other suspicious behavior via the telemetry log.

    Replaces the old TestActionSpamDetection, which searched console.txt for
    literal strings like "[Needs] Exhausted — resting." — patterns from
    AutoPilot_Needs.lua's print calls, which are shadowed to no-ops (see this
    file's module docstring), so that class's one test always passed
    vacuously (max_consecutive stayed 0 forever, and 0 is always less than
    the threshold) regardless of what actually happened in the session. This
    reuses triage_run_log.py's own detectors (the same ones tools/triage.md
    documents), which read the run log directly rather than console text.

    The gate is scoped to the build under test, and that is a CORRECTION of a
    false positive rather than a relaxation.  This log lives at ONE fixed path
    and is appended to across every session AND every mod update, so it holds
    evidence about many builds at once; nothing in a pre-v6 line said which.
    A finding from a build whose defect has since been FIXED therefore failed
    this test forever, on every checkout, and was indistinguishable from a live
    regression — which is the state that trains a maintainer to ignore the one
    gate that reads real gameplay.

    That is not a hypothetical.  On 2026-08-10 a HIGH "the FLEE path stalls"
    bug was filed against current ``main`` from this test's five findings.
    Every byte of that evidence was written at or before 2026-08-07 04:01
    (the log's mtime), which is BEFORE all three merged fixes aimed at exactly
    its two shapes: #120 (2026-08-07T16:28Z, flee walks discarded above
    game-speed index 2 — the x11-x21 episode), #122 (18:43Z, every walk site
    clamps the speed) and #123 (2026-08-08T01:35Z, an escape walk that moved
    nobody no longer buys a cooldown — the x1 stride-of-5 episode).  The entry
    even recorded "confirmed pre-existing on origin/main", run in a throwaway
    worktree: a control that CANNOT fail, because the procedure re-reads the
    same historical bytes whatever commit is checked out.

    Nothing is hidden by the scoping: every finding is still detected, still
    carries the build that produced it, and ``triage_run_log.py``'s report
    prints all of them with that stamp.  What changed is which ones a GATE is
    entitled to fail on.
    """

    def test_no_suspicious_patterns_from_the_build_under_test(self):
        build = tree_build()
        entries, _skipped = tr.parse_run_log(RUN_LOG)
        sessions = tr.split_sessions(entries)
        findings = tr.detect_suspicious(sessions)
        mine = tr.findings_for_build(findings, build)
        others = [f for f in findings if f not in mine]
        self.assertEqual(
            mine, [],
            f"Suspicious pattern(s) detected in auto_pilot_run.log, written by "
            f"the build under test ({build}):\n"
            + "\n".join(f"{f.pattern}: {f.detail}" for f in mine[:10])
            + (f"\n\n({len(others)} further finding(s) from other builds are "
               f"reported by triage_run_log.py but are not this build's "
               f"evidence.)" if others else ""))


class TestBuildAttribution(unittest.TestCase):
    """The behaviour difference the build stamp buys, on synthetic logs.

    Deliberately NOT skipped: the real-log gate above only ever runs on a
    machine that has actually played, so the POLICY it implements would
    otherwise have no coverage in CI at all.  Each case below feeds the real
    parse -> split -> detect -> select pipeline the same stalled-flee episode,
    varying ONLY the build stamp, so the difference in outcome can come from
    nothing else.
    """

    STALL_LINE = (
        "schema_version={schema},player=0,mode=autopilot,ff=active,speed=1,"
        "run_tick={tick},action=combat,reason={reason},class=combat,stage=,"
        "fail_reason=,retry_count=0,hunger=10,thirst=10,fatigue=10,"
        "endurance=90,zombies=1,bleeding=0,str=1,fit=1,doc=0{stamp}"
    )

    @classmethod
    def _stall_log(cls, stamp: str | None) -> str:
        """A single combat episode shaped exactly like the live stall.

        Seven flee decisions, each followed by four ``evade_cooldown`` ticks
        and NO ``evade_running`` tick anywhere — over
        FLEE_STALL_MIN_DECISIONS (6), so detect_flee_stalls fires, and 35
        ticks total, under STREAK_MIN_TICKS (40), so it is the ONLY detector
        that does.  A one-detector probe keeps the assertions below about
        attribution rather than about which detector happened to trip.  (It is
        also the exact shape of the live 2026-08-07 x1 episode: seven flee
        decisions on a stride of FLEE_COOLDOWN_CYCLES + 1 = 5.)
        """
        schema = 6 if stamp is not None else 5
        suffix = f",mod_version={stamp}" if stamp is not None else ""
        lines = []
        tick = 1
        for _ in range(7):
            lines.append(cls.STALL_LINE.format(
                schema=schema, tick=tick, reason="flee_default", stamp=suffix))
            tick += 1
            for _ in range(4):
                lines.append(cls.STALL_LINE.format(
                    schema=schema, tick=tick, reason="evade_cooldown",
                    stamp=suffix))
                tick += 1
        return "\n".join(lines) + "\n"

    def _gate_input(self, stamp: str | None):
        """Return (all findings, findings the tree's build is answerable for)."""
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "auto_pilot_run.log"
            path.write_text(self._stall_log(stamp), encoding="utf-8")
            entries, skipped = tr.parse_run_log(path)
        self.assertEqual(skipped, 0, "synthetic log must parse cleanly")
        findings = tr.detect_suspicious(tr.split_sessions(entries))
        return findings, tr.findings_for_build(findings, tree_build())

    def test_a_stall_from_this_build_fails_the_gate(self):
        findings, mine = self._gate_input(tree_build())
        self.assertEqual([f.pattern for f in findings], ["flee stall"])
        self.assertEqual(len(mine), 1,
                         "a stall stamped with the build under test IS this "
                         "build's evidence and must reach the gate")

    def test_the_same_stall_from_another_build_does_not(self):
        other = "0.0.1-some-older-build"
        self.assertNotEqual(other, tree_build())
        findings, mine = self._gate_input(other)
        self.assertEqual([f.pattern for f in findings], ["flee stall"],
                         "the finding is still DETECTED and still reported")
        self.assertEqual([f.mod_version for f in findings], [other],
                         "and it still names the build that produced it")
        self.assertEqual(mine, [],
                         "but it is not evidence about the code under test")

    def test_an_unstamped_pre_v6_session_does_not(self):
        findings, mine = self._gate_input(None)
        self.assertEqual([f.pattern for f in findings], ["flee stall"])
        self.assertEqual([f.mod_version for f in findings],
                         [tr.UNSTAMPED_BUILD],
                         "a pre-v6 session has no build stamp to attribute")
        self.assertEqual(mine, [])

    def test_the_report_names_the_build_for_both_cases(self):
        """Attribution is surfaced to the human, not just to the gate."""
        with tempfile.TemporaryDirectory() as tmp:
            stamped = pathlib.Path(tmp) / "stamped.log"
            stamped.write_text(self._stall_log("0.0.1-some-older-build"),
                               encoding="utf-8")
            plain = pathlib.Path(tmp) / "plain.log"
            plain.write_text(self._stall_log(None), encoding="utf-8")

            entries, _ = tr.parse_run_log(stamped)
            report = tr.format_report(tr.summarize(entries))
            self.assertIn("build 0.0.1-some-older-build", report)
            self.assertIn("build: 0.0.1-some-older-build", report)

            entries, _ = tr.parse_run_log(plain)
            report = tr.format_report(tr.summarize(entries))
            self.assertIn("unstamped (pre-v6 session)", report)

    def test_a_session_stamped_by_two_builds_is_reported_as_both(self):
        """Never resolve an inconsistent stamp by picking one of them."""
        first = self._stall_log("0.2.1").splitlines()
        second = self._stall_log("0.2.2").splitlines()
        # Same session (run_tick keeps climbing), two stamps: only a hand-edited
        # or concatenated log can do this, and the reader must be told.
        merged = first + [
            line.replace(f"run_tick={i + 1},", f"run_tick={len(first) + i + 1},")
            for i, line in enumerate(second)
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "auto_pilot_run.log"
            path.write_text("\n".join(merged) + "\n", encoding="utf-8")
            entries, _ = tr.parse_run_log(path)
        sessions = tr.split_sessions(entries)
        self.assertEqual(len(sessions), 1, "run_tick never resets, so one session")
        self.assertEqual(tr.session_build(sessions[0]), "0.2.1+0.2.2")
        self.assertEqual(
            tr.findings_for_build(tr.detect_suspicious(sessions), "0.2.1"), [],
            "a joined stamp matches neither of its halves, so no gate may "
            "claim the session as its own evidence")


if __name__ == "__main__":
    unittest.main()
