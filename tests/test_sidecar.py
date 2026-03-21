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
# The sidecar does `import anthropic` at module scope, so we must inject the
# mock into sys.modules BEFORE exec_module() is called below.

_mock_anthropic = types.ModuleType("anthropic")
_mock_anthropic.Anthropic = MagicMock   # client constructor
_mock_anthropic.APIError  = Exception   # base exception caught in the main loop
sys.modules.setdefault("anthropic", _mock_anthropic)

# ── Load sidecar by file path (avoids package/sys.path gymnastics) ────────────

_SIDECAR_PATH = pathlib.Path(__file__).parent.parent / "auto_pilot_sidecar.py"
_spec   = importlib.util.spec_from_file_location("auto_pilot_sidecar", _SIDECAR_PATH)
sidecar = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sidecar)

# ── Helper: build a mock client that returns the given response ───────────────

def _make_client(
    action: str = "eat",
    reason: str = "hungry",
    raw_text: str | None = None,
) -> MagicMock:
    """Return a mock anthropic.Anthropic client for a single ask_claude call."""
    if raw_text is None:
        raw_text = json.dumps({"action": action, "reason": reason})

    text_block = MagicMock()
    text_block.type = "text"
    text_block.text = raw_text

    response = MagicMock()
    response.content = [text_block]

    stream = MagicMock()
    stream.get_final_message.return_value = response

    ctx = MagicMock()
    ctx.__enter__ = MagicMock(return_value=stream)
    ctx.__exit__  = MagicMock(return_value=False)

    client = MagicMock()
    client.messages.stream.return_value = ctx
    return client


# ── Shared minimal game state ─────────────────────────────────────────────────

_BASE_STATE: dict = {
    "health": 75, "endurance": 50,
    "zombie_count_nearby": 0, "negative_moodles": 0,
    "has_food": True, "has_drink": True, "has_weapon": False, "has_readable": False,
    "strength_level": 1, "fitness_level": 1,
    "is_outside": False,
    "moodles": {
        "hungry": 0, "thirsty": 0, "tired": 0, "panicked": 0,
        "injured": 0, "sick": 0, "stressed": 0, "bored": 0, "sad": 0,
    },
}


# ─────────────────────────────────────────────────────────────────────────────
# build_user_message
# ─────────────────────────────────────────────────────────────────────────────

class TestBuildUserMessage(unittest.TestCase):

    def test_full_state_contains_key_values(self):
        state = dict(_BASE_STATE, health=80, endurance=60, zombie_count_nearby=3)
        state["moodles"] = dict(_BASE_STATE["moodles"], thirsty=2)
        msg = sidecar.build_user_message(state)
        self.assertIn("Health: 80%", msg)
        self.assertIn("Endurance: 60%", msg)
        self.assertIn("Zombies nearby: 3", msg)
        self.assertIn("thirsty=2", msg)
        self.assertIn("Strength level: 1", msg)

    def test_missing_health_shows_question_mark(self):
        state = {k: v for k, v in _BASE_STATE.items() if k != "health"}
        self.assertIn("Health: ?%", sidecar.build_user_message(state))

    def test_missing_zombie_count_defaults_to_zero(self):
        state = {k: v for k, v in _BASE_STATE.items() if k != "zombie_count_nearby"}
        self.assertIn("Zombies nearby: 0", sidecar.build_user_message(state))

    def test_missing_has_readable_defaults_to_false(self):
        state = {k: v for k, v in _BASE_STATE.items() if k != "has_readable"}
        self.assertIn("Has readable: False", sidecar.build_user_message(state))

    def test_missing_moodle_keys_default_to_zero(self):
        state = dict(_BASE_STATE, moodles={})
        msg = sidecar.build_user_message(state)
        self.assertIn("hungry=0", msg)
        self.assertIn("tired=0", msg)
        self.assertIn("bored=0", msg)


# ─────────────────────────────────────────────────────────────────────────────
# ask_claude
# ─────────────────────────────────────────────────────────────────────────────

class TestAskClaude(unittest.TestCase):

    def test_valid_action_returned(self):
        client = _make_client(action="eat", reason="hungry moodle level 2")
        result = sidecar.ask_claude(client, _BASE_STATE)
        self.assertEqual(result["action"], "eat")
        self.assertEqual(result["reason"], "hungry moodle level 2")

    def test_all_nine_valid_actions_accepted(self):
        for action in sidecar.VALID_ACTIONS:
            with self.subTest(action=action):
                client = _make_client(action=action, reason="test")
                result = sidecar.ask_claude(client, _BASE_STATE)
                self.assertEqual(result["action"], action)

    def test_invalid_action_raises_value_error(self):
        client = _make_client(action="dance", reason="party time")
        with self.assertRaises(ValueError):
            sidecar.ask_claude(client, _BASE_STATE)

    def test_markdown_fences_stripped(self):
        raw = '```json\n{"action": "sleep", "reason": "very tired"}\n```'
        client = _make_client(raw_text=raw)
        result = sidecar.ask_claude(client, _BASE_STATE)
        self.assertEqual(result["action"], "sleep")

    def test_markdown_fence_no_closing_backticks(self):
        # Model sometimes omits the closing fence
        raw = '```\n{"action": "rest", "reason": "low endurance"}'
        client = _make_client(raw_text=raw)
        result = sidecar.ask_claude(client, _BASE_STATE)
        self.assertEqual(result["action"], "rest")

    def test_thinking_block_before_text_block_is_skipped(self):
        thinking_block = MagicMock()
        thinking_block.type = "thinking"
        # thinking blocks must NOT be picked as the text block
        text_block = MagicMock()
        text_block.type = "text"
        text_block.text = '{"action": "drink", "reason": "thirsty"}'

        response = MagicMock()
        response.content = [thinking_block, text_block]

        stream = MagicMock()
        stream.get_final_message.return_value = response

        ctx = MagicMock()
        ctx.__enter__ = MagicMock(return_value=stream)
        ctx.__exit__  = MagicMock(return_value=False)

        client = MagicMock()
        client.messages.stream.return_value = ctx

        result = sidecar.ask_claude(client, _BASE_STATE)
        self.assertEqual(result["action"], "drink")

    def test_malformed_json_raises_json_decode_error(self):
        client = _make_client(raw_text="not valid json at all")
        with self.assertRaises(json.JSONDecodeError):
            sidecar.ask_claude(client, _BASE_STATE)

    def test_stream_called_with_correct_model(self):
        client = _make_client()
        sidecar.ask_claude(client, _BASE_STATE)
        call_kwargs = client.messages.stream.call_args
        self.assertEqual(call_kwargs.kwargs.get("model") or call_kwargs.args[0], sidecar.MODEL)


# ─────────────────────────────────────────────────────────────────────────────
# write_command
# ─────────────────────────────────────────────────────────────────────────────

class TestWriteCommand(unittest.TestCase):

    def _patch_cmd_file(self, tmp_path: pathlib.Path):
        """Context manager that redirects CMD_FILE to tmp_path for the test."""
        import contextlib

        @contextlib.contextmanager
        def _ctx():
            original = sidecar.CMD_FILE
            sidecar.CMD_FILE = tmp_path
            try:
                yield tmp_path
            finally:
                sidecar.CMD_FILE = original

        return _ctx()

    def test_writes_correct_json(self):
        with tempfile.TemporaryDirectory() as td:
            cmd_path = pathlib.Path(td) / "auto_pilot_cmd.json"
            with self._patch_cmd_file(cmd_path):
                sidecar.write_command({"action": "fight", "reason": "zombie close"})
            written = json.loads(cmd_path.read_text(encoding="utf-8"))
            self.assertEqual(written["action"], "fight")
            self.assertEqual(written["reason"], "zombie close")

    def test_no_tmp_file_left_behind(self):
        with tempfile.TemporaryDirectory() as td:
            cmd_path = pathlib.Path(td) / "auto_pilot_cmd.json"
            with self._patch_cmd_file(cmd_path):
                sidecar.write_command({"action": "idle", "reason": "nothing urgent"})
            self.assertFalse(
                cmd_path.with_suffix(".tmp").exists(),
                "Atomic rename should leave no .tmp file behind",
            )

    def test_output_is_valid_json(self):
        with tempfile.TemporaryDirectory() as td:
            cmd_path = pathlib.Path(td) / "auto_pilot_cmd.json"
            with self._patch_cmd_file(cmd_path):
                sidecar.write_command({"action": "flee", "reason": "too many debuffs"})
            # Should not raise
            json.loads(cmd_path.read_text(encoding="utf-8"))


# ─────────────────────────────────────────────────────────────────────────────
# JSON schema validation (skipped gracefully if jsonschema not installed)
# ─────────────────────────────────────────────────────────────────────────────

try:
    import jsonschema as _jsonschema
    _JSONSCHEMA_OK = True
except ImportError:
    _JSONSCHEMA_OK = False

_SCHEMAS_DIR = pathlib.Path(__file__).parent.parent / "schemas"

_VALID_STATE = {
    "health": 80, "endurance": 55, "negative_moodles": 1, "zombie_count_nearby": 0,
    "has_food": True, "has_drink": False, "has_weapon": True, "has_readable": False,
    "strength_level": 2, "fitness_level": 3, "is_outside": False,
    "moodles": {
        "hungry": 0, "thirsty": 2, "tired": 1, "panicked": 0,
        "injured": 0, "sick": 0, "stressed": 0, "bored": 0, "sad": 0,
    },
}


@unittest.skipUnless(_JSONSCHEMA_OK, "jsonschema not installed — pip install jsonschema")
class TestStateSchema(unittest.TestCase):

    def setUp(self):
        self.schema = json.loads((_SCHEMAS_DIR / "state.schema.json").read_text())

    def test_valid_state_passes(self):
        _jsonschema.validate(_VALID_STATE, self.schema)  # must not raise

    def test_health_over_100_fails(self):
        bad = dict(_VALID_STATE, health=150)
        with self.assertRaises(_jsonschema.ValidationError):
            _jsonschema.validate(bad, self.schema)

    def test_negative_endurance_fails(self):
        bad = dict(_VALID_STATE, endurance=-1)
        with self.assertRaises(_jsonschema.ValidationError):
            _jsonschema.validate(bad, self.schema)

    def test_moodle_level_5_fails(self):
        bad_moodles = dict(_VALID_STATE["moodles"], hungry=5)
        bad = dict(_VALID_STATE, moodles=bad_moodles)
        with self.assertRaises(_jsonschema.ValidationError):
            _jsonschema.validate(bad, self.schema)

    def test_missing_required_field_fails(self):
        bad = {k: v for k, v in _VALID_STATE.items() if k != "health"}
        with self.assertRaises(_jsonschema.ValidationError):
            _jsonschema.validate(bad, self.schema)

    def test_extra_field_fails(self):
        bad = dict(_VALID_STATE, unexpected_key="oops")
        with self.assertRaises(_jsonschema.ValidationError):
            _jsonschema.validate(bad, self.schema)


@unittest.skipUnless(_JSONSCHEMA_OK, "jsonschema not installed — pip install jsonschema")
class TestCmdSchema(unittest.TestCase):

    def setUp(self):
        self.schema = json.loads((_SCHEMAS_DIR / "cmd.schema.json").read_text())

    def test_all_valid_actions_pass(self):
        for action in ["eat", "drink", "sleep", "rest", "exercise", "outside", "fight", "flee", "idle"]:
            with self.subTest(action=action):
                _jsonschema.validate({"action": action, "reason": "test"}, self.schema)

    def test_unknown_action_fails(self):
        with self.assertRaises(_jsonschema.ValidationError):
            _jsonschema.validate({"action": "dance", "reason": "party"}, self.schema)

    def test_empty_reason_fails(self):
        with self.assertRaises(_jsonschema.ValidationError):
            _jsonschema.validate({"action": "eat", "reason": ""}, self.schema)

    def test_missing_reason_fails(self):
        with self.assertRaises(_jsonschema.ValidationError):
            _jsonschema.validate({"action": "eat"}, self.schema)


if __name__ == "__main__":
    unittest.main()
