#!/usr/bin/env python3
"""
AutoPilot LLM sidecar.

Watches auto_pilot_state.json (written by the Lua mod every ~10 s), calls Claude
to decide the next action, and writes the result to auto_pilot_cmd.json.

File locations: %USERPROFILE%/Zomboid/Lua/
  - auto_pilot_state.json  (written by AutoPilot_LLM.lua)
  - auto_pilot_cmd.json    (read by AutoPilot_LLM.lua)

Usage:
  pip install anthropic
  set ANTHROPIC_API_KEY=sk-ant-...
  python auto_pilot_sidecar.py
"""

import json
import os
import pathlib
import sys
import time

import anthropic

# ── Configuration ─────────────────────────────────────────────────────────────

ZOMBOID_LUA_DIR = pathlib.Path.home() / "Zomboid" / "Lua"
STATE_FILE      = ZOMBOID_LUA_DIR / "auto_pilot_state.json"
CMD_FILE        = ZOMBOID_LUA_DIR / "auto_pilot_cmd.json"
POLL_INTERVAL   = 2.0   # seconds between state-file mtime checks
MODEL           = "claude-opus-4-6"

# Matches the keys in AutoPilot_Main.lua's LLM_ACTION_MAP
VALID_ACTIONS = {"eat", "drink", "sleep", "rest", "exercise", "outside",
                 "fight", "flee", "bandage", "idle"}

SYSTEM_PROMPT = """\
You are the autonomous decision-making brain of an AFK survival bot in Project Zomboid.
Given the player's current game state, choose the single best action to take right now.

Priority order (highest → lowest):
1. Bleeding wounds → bandage immediately
2. Zombies nearby  → fight (if healthy, well-rested, few debuffs) or flee (2+ active negative moodles or bleeding)
3. Health/thirst/hunger — eat or drink when moodle level ≥ 2
4. Non-bleeding wounds → bandage scratches, bites, deep wounds
5. Exhausted (endurance critically low, ~15%) → rest
6. Very tired (tired moodle ≥ 3) → sleep
7. Bored (bored moodle ≥ 3) → outside (go outdoors) or read if already outside
8. Nothing urgent → exercise (Strength if STR ≤ FIT, else Fitness) or idle

Respond with a JSON object and nothing else — no markdown fences, no extra text:
{"action": "<action>", "reason": "<one short sentence explaining why>"}

Valid actions: eat, drink, sleep, rest, exercise, outside, fight, flee, bandage, idle
"""

# ── Helpers ───────────────────────────────────────────────────────────────────

def build_user_message(state: dict) -> str:
    """Format the game state snapshot into a human-readable message for Claude."""
    m = state.get("moodles", {})
    w = state.get("wounds", {})
    return (
        f"Health: {state.get('health', '?')}%  "
        f"Endurance: {state.get('endurance', '?')}%\n"
        f"Zombies nearby: {state.get('zombie_count_nearby', 0)}  "
        f"Negative moodles active: {state.get('negative_moodles', 0)}\n"
        f"Has food: {state.get('has_food')}  "
        f"Has drink: {state.get('has_drink')}  "
        f"Has weapon: {state.get('has_weapon')}  "
        f"Has readable: {state.get('has_readable', False)}  "
        f"Has water source: {state.get('has_water_source', False)}\n"
        f"Strength level: {state.get('strength_level', 0)}  "
        f"Fitness level: {state.get('fitness_level', 0)}\n"
        f"Is outside: {state.get('is_outside')}\n"
        f"Wounds — "
        f"bleeding={w.get('bleeding', 0)} "
        f"scratched={w.get('scratched', 0)} "
        f"deep_wounded={w.get('deep_wounded', 0)} "
        f"bitten={w.get('bitten', False)} "
        f"burnt={w.get('burnt', 0)}\n"
        f"Moodle levels — "
        f"hungry={m.get('hungry', 0)} "
        f"thirsty={m.get('thirsty', 0)} "
        f"tired={m.get('tired', 0)} "
        f"panicked={m.get('panicked', 0)} "
        f"injured={m.get('injured', 0)} "
        f"sick={m.get('sick', 0)} "
        f"stressed={m.get('stressed', 0)} "
        f"bored={m.get('bored', 0)} "
        f"sad={m.get('sad', 0)}"
    )


def ask_claude(client: anthropic.Anthropic, state: dict) -> dict:
    """Call Claude and return a validated {action, reason} dict."""
    user_msg = build_user_message(state)

    with client.messages.stream(
        model=MODEL,
        max_tokens=256,
        thinking={"type": "adaptive"},
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_msg}],
    ) as stream:
        response = stream.get_final_message()

    # Extract the text block (thinking blocks may appear first)
    text = next((b.text for b in response.content if b.type == "text"), "")
    text = text.strip()

    # Strip markdown code fences if the model adds them despite instructions
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if lines[-1] == "```" else lines[1:])
        text = text.strip()

    cmd = json.loads(text)
    if cmd.get("action") not in VALID_ACTIONS:
        raise ValueError(f"Claude returned invalid action: {cmd.get('action')!r}")
    return cmd


def write_command(cmd: dict) -> None:
    """Write atomically to avoid Lua reading a partial file."""
    tmp = CMD_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(cmd), encoding="utf-8")
    tmp.replace(CMD_FILE)


# ── Main loop ─────────────────────────────────────────────────────────────────

def main() -> None:
    print("[Sidecar] AutoPilot LLM sidecar starting.")
    print(f"[Sidecar] Watching : {STATE_FILE}")
    print(f"[Sidecar] Commands : {CMD_FILE}")
    print("[Sidecar] Press Ctrl-C to stop.\n")

    ZOMBOID_LUA_DIR.mkdir(parents=True, exist_ok=True)

    client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from env

    last_mtime: float = 0.0

    while True:
        try:
            if not STATE_FILE.exists():
                time.sleep(POLL_INTERVAL)
                continue

            mtime = STATE_FILE.stat().st_mtime
            if mtime <= last_mtime:
                time.sleep(POLL_INTERVAL)
                continue

            last_mtime = mtime
            state = json.loads(STATE_FILE.read_text(encoding="utf-8"))

            print("[Sidecar] State updated — asking Claude...", end=" ", flush=True)
            cmd = ask_claude(client, state)
            write_command(cmd)
            print(f"→ {cmd['action']!r}: {cmd['reason']}")

        except json.JSONDecodeError as exc:
            print(f"\n[Sidecar] JSON error: {exc}", file=sys.stderr)
        except anthropic.APIError as exc:
            print(f"\n[Sidecar] API error: {exc}", file=sys.stderr)
        except KeyboardInterrupt:
            print("\n[Sidecar] Stopped.")
            break
        except Exception as exc:  # noqa: BLE001
            print(f"\n[Sidecar] Unexpected error: {exc}", file=sys.stderr)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
