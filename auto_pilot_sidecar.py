#!/usr/bin/env python3
"""
AutoPilot LLM sidecar — AI brain for the Project Zomboid AutoPilot mod.

Two operating modes (match Lua mod's F7/F8):
  EXERCISE  — autonomous survival + exercise bot (original behaviour)
  PILOT     — goal-driven: reads natural-language prompts from the user,
              plans multi-step tasks, and executes them via the command pipe

File locations: %USERPROFILE%/Zomboid/Lua/
  - auto_pilot_state.json   (written by AutoPilot_LLM.lua)
  - auto_pilot_cmd.json     (read by AutoPilot_LLM.lua)
  - auto_pilot_prompt.txt   (written by user or helper script)
  - auto_pilot_sidecar.log  (debug log)

Usage:
  pip install anthropic
  set ANTHROPIC_API_KEY=sk-ant-...
  python auto_pilot_sidecar.py            # exercise mode (default)
  python auto_pilot_sidecar.py --pilot    # pilot mode (goal-driven)
"""

import argparse
import json
import logging
import os
import pathlib
import sys
import time

import anthropic

# ── Configuration ─────────────────────────────────────────────────────────────

ZOMBOID_LUA_DIR = pathlib.Path.home() / "Zomboid" / "Lua"
STATE_FILE      = ZOMBOID_LUA_DIR / "auto_pilot_state.json"
CMD_FILE        = ZOMBOID_LUA_DIR / "auto_pilot_cmd.json"
PROMPT_FILE     = ZOMBOID_LUA_DIR / "auto_pilot_prompt.txt"
LOG_FILE        = ZOMBOID_LUA_DIR / "auto_pilot_sidecar.log"
POLL_INTERVAL   = 2.0
MODEL           = "claude-sonnet-4-6"

# ── Logging ──────────────────────────────────────────────────────────────────

log = logging.getLogger("autopilot")
log.setLevel(logging.DEBUG)

_fmt = logging.Formatter(
    "[%(asctime)s] %(levelname)-5s  %(message)s", datefmt="%H:%M:%S"
)
_console = logging.StreamHandler(sys.stdout)
_console.setLevel(logging.INFO)
_console.setFormatter(_fmt)
log.addHandler(_console)

# ── Valid actions (must match Lua LLM_ACTION_MAP) ─────────────────────────────

VALID_ACTIONS = {
    "eat", "drink", "sleep", "rest", "exercise", "outside",
    "fight", "flee", "bandage", "idle", "stop", "status",
    "search_item", "loot_item", "place_item", "walk_to",
}

# ── System prompts ───────────────────────────────────────────────────────────

EXERCISE_SYSTEM = """\
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

PILOT_SYSTEM = """\
You are the AI brain of a player-controlled bot in Project Zomboid (Build 42).
The user gives you natural-language goals. You break them into small, executable steps.

Each cycle you receive:
- The user's current goal/prompt
- The game state (health, inventory, moodles, nearby items, etc.)
- Your previous plan and progress (conversation history)

You must respond with a SINGLE JSON object (no markdown, no extra text):
{"action": "<action>", "reason": "<what this step accomplishes toward the goal>"}

Available actions:
  eat, drink, sleep, rest, exercise, outside  — survival basics
  fight, flee                                 — combat
  bandage                                     — treat wounds
  search_item  — search nearby containers. Set reason to the item name/keyword to search for.
                 Example: {"action": "search_item", "reason": "saw"}
  loot_item    — pick up a found item. Set reason to the item name to grab.
                 Example: {"action": "loot_item", "reason": "Saw"}
  place_item   — place an item from inventory into the nearest container.
                 Set reason to the item name to place.
                 Example: {"action": "place_item", "reason": "Baking Tray"}
  walk_to      — walk to a compass direction or named place.
                 Example: {"action": "walk_to", "reason": "north 30"}
  idle         — do nothing this cycle, wait for state to change
  stop         — clear the action queue
  status       — log current stats (no game effect)

CRITICAL RULES:
- Issue ONE action per response. The next cycle will show you the result.
- If the goal is complete or you need more info, use "idle" and explain in "reason".
- If a survival need is urgent (bleeding, very thirsty, starving), handle it FIRST even
  if it interrupts the user's goal. Explain why in "reason".
- When searching for items, be specific with keywords the game would use.
- Think step by step. Your reason field should track progress toward the goal.
"""

# ── Helpers ───────────────────────────────────────────────────────────────────

def build_state_message(state: dict) -> str:
    """Format the game state snapshot into a readable string."""
    m = state.get("moodles", {})
    w = state.get("wounds", {})
    inv = state.get("nearby_items", [])
    player_inv = state.get("inventory_summary", [])

    lines = [
        f"Health: {state.get('health', '?')}%  "
        f"Endurance: {state.get('endurance', '?')}%",
        f"Zombies nearby: {state.get('zombie_count_nearby', 0)}  "
        f"Negative moodles: {state.get('negative_moodles', 0)}",
        f"Has food: {state.get('has_food')}  "
        f"Has drink: {state.get('has_drink')}  "
        f"Has weapon: {state.get('has_weapon')}  "
        f"Has readable: {state.get('has_readable', False)}  "
        f"Has water source: {state.get('has_water_source', False)}",
        f"Strength: {state.get('strength_level', 0)}  "
        f"Fitness: {state.get('fitness_level', 0)}  "
        f"Outside: {state.get('is_outside')}",
        f"Wounds — bleeding={w.get('bleeding', 0)} "
        f"scratched={w.get('scratched', 0)} "
        f"deep_wounded={w.get('deep_wounded', 0)} "
        f"bitten={w.get('bitten', False)} "
        f"burnt={w.get('burnt', 0)}",
        f"Moodles — hungry={m.get('hungry', 0)} "
        f"thirsty={m.get('thirsty', 0)} "
        f"tired={m.get('tired', 0)} "
        f"panicked={m.get('panicked', 0)} "
        f"injured={m.get('injured', 0)} "
        f"sick={m.get('sick', 0)} "
        f"stressed={m.get('stressed', 0)} "
        f"bored={m.get('bored', 0)} "
        f"sad={m.get('sad', 0)}",
    ]

    if player_inv:
        lines.append(f"Inventory: {', '.join(player_inv)}")
    if inv:
        lines.append(f"Nearby items found: {', '.join(inv)}")

    # Include last search results if present
    sr = state.get("search_results")
    if sr:
        lines.append(f"Last search results: {sr}")

    return "\n".join(lines)


def parse_response(response) -> dict:
    """Extract and validate JSON command from Claude's response."""
    text = next((b.text for b in response.content if b.type == "text"), "")
    text = text.strip()

    # Strip markdown fences
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if lines[-1] == "```" else lines[1:])
        text = text.strip()

    cmd = json.loads(text)
    action = cmd.get("action", "")
    if action not in VALID_ACTIONS:
        raise ValueError(f"Invalid action: {action!r}")
    return cmd


def write_command(cmd: dict) -> None:
    """Write atomically to avoid Lua reading a partial file."""
    tmp = CMD_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(cmd), encoding="utf-8")
    tmp.replace(CMD_FILE)


def read_prompt() -> str | None:
    """Read and consume the user's prompt file. Returns None if no prompt."""
    if not PROMPT_FILE.exists():
        return None
    text = PROMPT_FILE.read_text(encoding="utf-8").strip()
    if not text:
        return None
    return text


def clear_prompt() -> None:
    """Clear the prompt file after reading."""
    try:
        PROMPT_FILE.write_text("", encoding="utf-8")
    except OSError:
        pass


# ── Exercise mode (original) ─────────────────────────────────────────────────

def exercise_cycle(client: anthropic.Anthropic, state: dict) -> dict:
    """Single-shot: pick the best survival/exercise action."""
    user_msg = build_state_message(state)
    log.debug("Prompt to Claude:\n%s", user_msg)

    t0 = time.perf_counter()
    with client.messages.stream(
        model=MODEL, max_tokens=256,
        system=EXERCISE_SYSTEM,
        messages=[{"role": "user", "content": user_msg}],
    ) as stream:
        response = stream.get_final_message()
    elapsed = time.perf_counter() - t0

    usage = response.usage
    log.info("Claude: %.1fs (in=%d out=%d)", elapsed, usage.input_tokens, usage.output_tokens)
    return parse_response(response)


# ── Pilot mode (goal-driven) ─────────────────────────────────────────────────

class PilotSession:
    """Maintains conversation history for multi-step goal execution."""

    def __init__(self):
        self.goal: str = ""
        self.history: list[dict] = []  # Claude messages API format
        self.max_history = 20  # keep last N exchanges to fit context

    def set_goal(self, goal: str) -> None:
        if goal != self.goal:
            log.info("New goal: %s", goal)
            self.goal = goal
            self.history = []  # reset history for new goal

    def step(self, client: anthropic.Anthropic, state: dict) -> dict:
        """Execute one planning cycle toward the current goal."""
        state_text = build_state_message(state)
        user_content = (
            f"CURRENT GOAL: {self.goal}\n\n"
            f"GAME STATE:\n{state_text}\n\n"
            f"What is the next single action to take?"
        )

        self.history.append({"role": "user", "content": user_content})

        # Trim history to prevent context overflow
        if len(self.history) > self.max_history:
            self.history = self.history[-self.max_history:]

        t0 = time.perf_counter()
        with client.messages.stream(
            model=MODEL, max_tokens=512,
            system=PILOT_SYSTEM,
            messages=self.history,
        ) as stream:
            response = stream.get_final_message()
        elapsed = time.perf_counter() - t0

        usage = response.usage
        log.info("Claude: %.1fs (in=%d out=%d)", elapsed, usage.input_tokens, usage.output_tokens)

        cmd = parse_response(response)

        # Add assistant response to history
        text = next((b.text for b in response.content if b.type == "text"), "")
        self.history.append({"role": "assistant", "content": text.strip()})

        return cmd


# ── Main loop ─────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="AutoPilot LLM sidecar")
    parser.add_argument("--pilot", action="store_true",
                        help="Start in pilot mode (goal-driven, reads prompt file)")
    args = parser.parse_args()

    ZOMBOID_LUA_DIR.mkdir(parents=True, exist_ok=True)

    file_handler = logging.FileHandler(LOG_FILE, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(_fmt)
    log.addHandler(file_handler)

    mode = "pilot" if args.pilot else "exercise"

    log.info("AutoPilot LLM sidecar starting")
    log.info("Mode     : %s", mode.upper())
    log.info("Watching : %s", STATE_FILE)
    log.info("Commands : %s", CMD_FILE)
    log.info("Prompts  : %s", PROMPT_FILE)
    log.info("Log file : %s", LOG_FILE)
    log.info("Model    : %s", MODEL)
    log.info("Press Ctrl-C to stop.\n")

    client = anthropic.Anthropic()
    log.info("Anthropic client initialized")

    pilot = PilotSession()
    last_mtime: float = 0.0
    cycle = 0

    while True:
        try:
            if not STATE_FILE.exists():
                time.sleep(POLL_INTERVAL)
                continue

            # Check for new user prompt (pilot mode) — do this BEFORE
            # the mtime gate so new goals trigger immediately.
            new_goal = False
            if mode == "pilot":
                prompt = read_prompt()
                if prompt:
                    pilot.set_goal(prompt)
                    clear_prompt()
                    new_goal = True

            mtime = STATE_FILE.stat().st_mtime
            state_changed = mtime > last_mtime

            # Skip cycle unless state changed OR a new goal just arrived
            if not state_changed and not new_goal:
                time.sleep(POLL_INTERVAL)
                continue

            if state_changed:
                last_mtime = mtime

            cycle += 1
            state = json.loads(STATE_FILE.read_text(encoding="utf-8"))

            # Compact state summary
            m = state.get("moodles", {})
            w = state.get("wounds", {})
            log.info(
                "[#%d] State: HP=%s%% End=%s%% Zom=%s | "
                "hungry=%s thirsty=%s tired=%s | "
                "bleed=%s scratch=%s",
                cycle,
                state.get("health", "?"), state.get("endurance", "?"),
                state.get("zombie_count_nearby", 0),
                m.get("hungry", 0), m.get("thirsty", 0), m.get("tired", 0),
                w.get("bleeding", 0), w.get("scratched", 0),
            )
            log.debug("[#%d] Full state: %s", cycle, json.dumps(state))

            # Check for prompt again on state-change cycles (goal may have
            # arrived between polls)
            if mode == "pilot" and not new_goal:
                prompt = read_prompt()
                if prompt:
                    pilot.set_goal(prompt)
                    clear_prompt()

            # Decide
            if mode == "exercise":
                cmd = exercise_cycle(client, state)
            elif mode == "pilot" and pilot.goal:
                cmd = pilot.step(client, state)
            else:
                # Pilot mode but no goal set — skip
                time.sleep(POLL_INTERVAL)
                continue

            write_command(cmd)
            log.info(
                "[#%d] >>> %s — %s",
                cycle, cmd["action"].upper(), cmd.get("reason", ""),
            )

        except json.JSONDecodeError as exc:
            log.error("JSON parse error: %s", exc)
        except anthropic.APIError as exc:
            log.error("Anthropic API error: %s", exc)
        except KeyboardInterrupt:
            log.info("Stopped by user.")
            break
        except Exception as exc:
            log.error("Unexpected error: %s", exc, exc_info=True)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
