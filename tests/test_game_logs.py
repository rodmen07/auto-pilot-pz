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
import unittest

import triage_run_log as tr

CONSOLE_LOG = pathlib.Path.home() / "Zomboid" / "console.txt"
RUN_LOG = pathlib.Path.home() / "Zomboid" / "Lua" / "auto_pilot_run.log"

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
    """

    def test_no_suspicious_patterns(self):
        entries, _skipped = tr.parse_run_log(RUN_LOG)
        sessions = tr.split_sessions(entries)
        findings = tr.detect_suspicious(sessions)
        self.assertEqual(
            findings, [],
            "Suspicious pattern(s) detected in auto_pilot_run.log:\n"
            + "\n".join(f"{f.pattern}: {f.detail}" for f in findings[:10]))


if __name__ == "__main__":
    unittest.main()
