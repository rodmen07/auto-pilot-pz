"""
Unit tests for auto_pilot_sidecar.py.

All Anthropic API calls are mocked — no network access, no API key required.
Run:  pytest tests/ -v
"""

import importlib.util
import json
import pathlib
import sys
import tempfile
import types
import unittest
from unittest.mock import MagicMock

# ── Mock 'anthropic' before the sidecar module loads it ───────────────────────

_mock_anthropic = types.ModuleType("anthropic")
_mock_anthropic.Anthropic = MagicMock
_mock_anthropic.APIError  = Exception
sys.modules.setdefault("anthropic", _mock_anthropic)

# ── Load sidecar by file path (avoids package/sys.path gymnastics) ────────────

_SIDECAR_PATH = pathlib.Path(__file__).parent.parent / "auto_pilot_sidecar.py"
_spec   = importlib.util.spec_from_file_location("auto_pilot_sidecar", _SIDECAR_PATH)
sidecar = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sidecar)

# ── Helper: build a mock response object ──────────────────────────────────────

def _make_response(
    action: str = "eat",
    reason: str = "hungry",
    raw_text: str | None = None,
) -> MagicMock:
    """Return a mock Messages API response."""
    if raw_text is None:
        raw_text = json.dumps({"action": action, "reason": reason})

    text_block = MagicMock()
    text_block.type = "text"
    text_block.text = raw_text

    response = MagicMock()
    response.content = [text_block]
    response.usage = MagicMock(input_tokens=100, output_tokens=20)
    return response


# ── Shared minimal game state ─────────────────────────────────────────────────

_BASE_STATE: dict = {
    "health": 75, "endurance": 50,
    "zombie_count_nearby": 0, "negative_moodles": 0,
    "has_food": True, "has_drink": True, "has_weapon": False,
    "has_readable": False, "has_water_source": True,
    "strength_level": 1, "fitness_level": 1,
    "is_outside": False,
    "moodles": {
        "hungry": 0, "thirsty": 0, "tired": 0, "panicked": 0,
        "injured": 0, "sick": 0, "stressed": 0, "bored": 0, "sad": 0,
    },
    "wounds": {
        "bleeding": 0, "scratched": 0, "deep_wounded": 0,
        "bitten": False, "burnt": 0,
    },
    "inventory_summary": ["Claw Hammer", "Bandage x3"],
    "search_results": {},
}


# ─────────────────────────────────────────────────────────────────────────────
# VALID_ACTIONS
# ─────────────────────────────────────────────────────────────────────────────

class TestValidActions(unittest.TestCase):

    def test_contains_core_survival_actions(self):
        core = {"eat", "drink", "sleep", "rest", "exercise", "fight",
                "flee", "bandage", "idle", "stop"}
        missing = core - sidecar.VALID_ACTIONS
        self.assertFalse(missing, f"Missing core actions: {missing}")

    def test_contains_pilot_actions(self):
        pilot = {"search_item", "loot_item", "place_item", "walk_to"}
        missing = pilot - sidecar.VALID_ACTIONS
        self.assertFalse(missing, f"Missing pilot actions: {missing}")

    def test_all_actions_are_lowercase(self):
        for action in sidecar.VALID_ACTIONS:
            self.assertEqual(action, action.lower(),
                             f"Action '{action}' should be lowercase")


# ─────────────────────────────────────────────────────────────────────────────
# build_state_message
# ─────────────────────────────────────────────────────────────────────────────

class TestBuildStateMessage(unittest.TestCase):

    def test_contains_key_fields(self):
        msg = sidecar.build_state_message(_BASE_STATE)
        self.assertIn("Health: 75%", msg)
        self.assertIn("Endurance: 50%", msg)
        self.assertIn("Zombies nearby: 0", msg)
        self.assertIn("Has food: True", msg)
        self.assertIn("Has weapon: False", msg)
        self.assertIn("hungry=0", msg)

    def test_missing_health_shows_question_mark(self):
        state = {k: v for k, v in _BASE_STATE.items() if k != "health"}
        self.assertIn("Health: ?%", sidecar.build_state_message(state))

    def test_missing_moodle_keys_default_to_zero(self):
        state = dict(_BASE_STATE, moodles={})
        msg = sidecar.build_state_message(state)
        self.assertIn("hungry=0", msg)
        self.assertIn("tired=0", msg)

    def test_inventory_shown_when_present(self):
        msg = sidecar.build_state_message(_BASE_STATE)
        self.assertIn("Claw Hammer", msg)

    def test_inventory_omitted_when_empty(self):
        state = dict(_BASE_STATE, inventory_summary=[])
        msg = sidecar.build_state_message(state)
        self.assertNotIn("Inventory:", msg)

    def test_wounds_shown(self):
        state = dict(_BASE_STATE, wounds={
            "bleeding": 2, "scratched": 1, "deep_wounded": 0,
            "bitten": True, "burnt": 0,
        })
        msg = sidecar.build_state_message(state)
        self.assertIn("bleeding=2", msg)
        self.assertIn("bitten=True", msg)

    def test_search_results_shown(self):
        state = dict(_BASE_STATE, search_results=["Saw", "Plank x4"])
        msg = sidecar.build_state_message(state)
        self.assertIn("Saw", msg)

    def test_empty_state(self):
        msg = sidecar.build_state_message({})
        self.assertIn("Health:", msg)


# ─────────────────────────────────────────────────────────────────────────────
# parse_response
# ─────────────────────────────────────────────────────────────────────────────

class TestParseResponse(unittest.TestCase):

    def test_valid_action(self):
        resp = _make_response(action="eat", reason="hungry")
        result = sidecar.parse_response(resp)
        self.assertEqual(result["action"], "eat")
        self.assertEqual(result["reason"], "hungry")

    def test_all_valid_actions_accepted(self):
        for action in sidecar.VALID_ACTIONS:
            with self.subTest(action=action):
                if action == "chain":
                    raw = json.dumps({"action": "chain",
                                      "steps": "eat|drink",
                                      "reason": "test"})
                    resp = _make_response(raw_text=raw)
                else:
                    resp = _make_response(action=action, reason="test")
                result = sidecar.parse_response(resp)
                self.assertEqual(result["action"], action)

    def test_invalid_action_raises_value_error(self):
        resp = _make_response(action="dance", reason="party")
        with self.assertRaises(ValueError):
            sidecar.parse_response(resp)

    def test_markdown_fences_stripped(self):
        raw = '```json\n{"action": "sleep", "reason": "very tired"}\n```'
        resp = _make_response(raw_text=raw)
        result = sidecar.parse_response(resp)
        self.assertEqual(result["action"], "sleep")

    def test_markdown_fence_no_closing(self):
        raw = '```\n{"action": "rest", "reason": "low endurance"}'
        resp = _make_response(raw_text=raw)
        result = sidecar.parse_response(resp)
        self.assertEqual(result["action"], "rest")

    def test_thinking_block_skipped(self):
        thinking = MagicMock()
        thinking.type = "thinking"
        text = MagicMock()
        text.type = "text"
        text.text = '{"action": "drink", "reason": "thirsty"}'
        resp = MagicMock()
        resp.content = [thinking, text]
        result = sidecar.parse_response(resp)
        self.assertEqual(result["action"], "drink")

    def test_malformed_json_returns_idle(self):
        resp = _make_response(raw_text="not json")
        result = sidecar.parse_response(resp)
        self.assertEqual(result["action"], "idle")


# ─────────────────────────────────────────────────────────────────────────────
# write_command
# ─────────────────────────────────────────────────────────────────────────────

class TestWriteCommand(unittest.TestCase):

    def _with_tmp_cmd_file(self):
        """Redirect CMD_FILE to a temp path."""
        import contextlib

        @contextlib.contextmanager
        def _ctx():
            original = sidecar.CMD_FILE
            with tempfile.TemporaryDirectory() as td:
                tmp = pathlib.Path(td) / "auto_pilot_cmd.json"
                sidecar.CMD_FILE = tmp
                try:
                    yield tmp
                finally:
                    sidecar.CMD_FILE = original
        return _ctx()

    def test_writes_valid_json(self):
        with self._with_tmp_cmd_file() as cmd_path:
            sidecar.write_command({"action": "fight", "reason": "zombie"})
            data = json.loads(cmd_path.read_text(encoding="utf-8"))
            self.assertEqual(data["action"], "fight")

    def test_no_tmp_file_left(self):
        with self._with_tmp_cmd_file() as cmd_path:
            sidecar.write_command({"action": "idle", "reason": "waiting"})
            self.assertFalse(cmd_path.with_suffix(".tmp").exists())

    def test_overwrites_previous(self):
        with self._with_tmp_cmd_file() as cmd_path:
            sidecar.write_command({"action": "eat", "reason": "first"})
            sidecar.write_command({"action": "drink", "reason": "second"})
            data = json.loads(cmd_path.read_text(encoding="utf-8"))
            self.assertEqual(data["action"], "drink")


# ─────────────────────────────────────────────────────────────────────────────
# read_prompt / clear_prompt
# ─────────────────────────────────────────────────────────────────────────────

class TestPromptFile(unittest.TestCase):

    def test_read_returns_content(self):
        original = sidecar.PROMPT_FILE
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".txt", delete=False, encoding="utf-8"
            ) as f:
                f.write("find a saw")
                sidecar.PROMPT_FILE = pathlib.Path(f.name)
            result = sidecar.read_prompt()
            self.assertEqual(result, "find a saw")
        finally:
            sidecar.PROMPT_FILE = original

    def test_read_returns_none_for_missing(self):
        original = sidecar.PROMPT_FILE
        try:
            sidecar.PROMPT_FILE = pathlib.Path("/nonexistent/prompt.txt")
            self.assertIsNone(sidecar.read_prompt())
        finally:
            sidecar.PROMPT_FILE = original

    def test_read_returns_none_for_empty(self):
        original = sidecar.PROMPT_FILE
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".txt", delete=False, encoding="utf-8"
            ) as f:
                f.write("")
                sidecar.PROMPT_FILE = pathlib.Path(f.name)
            self.assertIsNone(sidecar.read_prompt())
        finally:
            sidecar.PROMPT_FILE = original


# ─────────────────────────────────────────────────────────────────────────────
# PilotSession
# ─────────────────────────────────────────────────────────────────────────────

class TestPilotSession(unittest.TestCase):

    def test_set_goal_resets_history(self):
        session = sidecar.PilotSession()
        session.history = [{"role": "user", "content": "old"}]
        session.set_goal("new goal")
        self.assertEqual(session.goal, "new goal")
        self.assertEqual(session.history, [])

    def test_same_goal_keeps_history(self):
        session = sidecar.PilotSession()
        session.set_goal("find a saw")
        session.history = [{"role": "user", "content": "msg"}]
        session.set_goal("find a saw")
        self.assertEqual(len(session.history), 1)

    def test_history_trimmed_to_max(self):
        session = sidecar.PilotSession()
        session.goal = "test"
        session.max_history = 4
        session.history = [
            {"role": "user", "content": f"msg{i}"}
            for i in range(10)
        ]

        # Mock the client
        stream = MagicMock()
        resp = _make_response(action="idle", reason="test")
        stream.get_final_message.return_value = resp
        ctx = MagicMock()
        ctx.__enter__ = MagicMock(return_value=stream)
        ctx.__exit__  = MagicMock(return_value=False)
        client = MagicMock()
        client.messages.stream.return_value = ctx

        session.step(client, _BASE_STATE)
        # History should be trimmed: kept max_history entries + new user + assistant
        self.assertLessEqual(len(session.history), session.max_history + 2)


# ─────────────────────────────────────────────────────────────────────────────
# System prompt coverage
# ─────────────────────────────────────────────────────────────────────────────

class TestSystemPrompts(unittest.TestCase):

    def test_pilot_prompt_documents_pilot_actions(self):
        for action in ["search_item", "loot_item", "place_item", "walk_to"]:
            self.assertIn(action, sidecar.PILOT_SYSTEM,
                          f"PILOT_SYSTEM missing '{action}'")

    def test_exercise_prompt_non_empty(self):
        self.assertGreater(len(sidecar.EXERCISE_SYSTEM.strip()), 100)

    def test_pilot_prompt_mentions_json_format(self):
        self.assertTrue(
            "JSON" in sidecar.PILOT_SYSTEM
            or "json" in sidecar.PILOT_SYSTEM
            or '"action"' in sidecar.PILOT_SYSTEM,
            "PILOT_SYSTEM should mention JSON format or action field")

    def test_exercise_prompt_mentions_json_format(self):
        self.assertIn("JSON", sidecar.EXERCISE_SYSTEM)


# ─────────────────────────────────────────────────────────────────────────────
# State JSON round-trip
# ─────────────────────────────────────────────────────────────────────────────

class TestStateRoundTrip(unittest.TestCase):

    def test_state_survives_json_serialization(self):
        serialized = json.dumps(_BASE_STATE)
        restored = json.loads(serialized)
        self.assertEqual(restored, _BASE_STATE)


if __name__ == "__main__":
    unittest.main()
