"""
Game log validation — parse PZ console.txt for AutoPilot runtime errors.

This test reads the actual PZ console log (if it exists) and checks for
error patterns that indicate bugs in the Lua mod code. Useful for
post-session validation: play for a while, then run pytest to catch issues.

Run:  pytest tests/test_game_logs.py -v
Skip: these tests are skipped automatically if console.txt doesn't exist.
"""

import pathlib
import re
import unittest

CONSOLE_LOG = pathlib.Path.home() / "Zomboid" / "console.txt"

# Patterns that indicate AutoPilot Lua errors
LUA_ERROR_PATTERNS = [
    re.compile(r"ERROR.*AutoPilot", re.IGNORECASE),
    re.compile(r"java\.lang\.\w+Exception.*auto_pilot", re.IGNORECASE),
    re.compile(r"LuaError.*AutoPilot", re.IGNORECASE),
    re.compile(r"attempted to call.*nil.*AutoPilot", re.IGNORECASE),
]

# Patterns for known-bad behaviors (action spam, infinite loops)
SPAM_PATTERNS = [
    # Same action logged more than 20 times in a row = likely spam loop
    (r"\[Needs\] Exhausted — resting\.", 20, "rest spam"),
    (r"\[Needs\] Drinking:", 15, "drink spam"),
    (r"\[Needs\] Eating:", 15, "eat spam"),
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
        cls.autopilot_lines = [
            line for line in cls.lines if "AutoPilot" in line or "auto_pilot" in line
        ]

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

    def test_mod_loaded_successfully(self):
        loaded = any("AutoPilot loaded" in line for line in self.autopilot_lines)
        self.assertTrue(loaded,
                        "AutoPilot mod did not load — check for syntax errors")

    def test_medical_module_loaded(self):
        loaded = any("Medical" in line and "loaded" in line
                      for line in self.autopilot_lines)
        self.assertTrue(loaded, "AutoPilot_Medical module did not load")


@unittest.skipUnless(CONSOLE_LOG.exists(), "No PZ console.txt found")
class TestActionSpamDetection(unittest.TestCase):
    """Detect action spam loops by checking for repeated log patterns."""

    @classmethod
    def setUpClass(cls):
        cls.lines = [
            line for line in _read_log(CONSOLE_LOG) if "[AutoPilot]" in line
        ]

    def test_no_action_spam(self):
        for pattern_str, threshold, label in SPAM_PATTERNS:
            pattern = re.compile(pattern_str)
            consecutive = 0
            max_consecutive = 0
            for line in self.lines:
                if pattern.search(line):
                    consecutive += 1
                    max_consecutive = max(max_consecutive, consecutive)
                else:
                    consecutive = 0
            self.assertLess(
                max_consecutive, threshold,
                f"Detected {label}: '{pattern_str}' appeared "
                f"{max_consecutive} times consecutively (threshold={threshold})")

if __name__ == "__main__":
    unittest.main()
