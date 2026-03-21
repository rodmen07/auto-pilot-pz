#!/usr/bin/env bash
# autopilot_prompt.sh — Send a natural-language goal to the AutoPilot pilot mode.
#
# Usage:
#   bash autopilot_prompt.sh "search for a saw"
#   bash autopilot_prompt.sh "find food and water, then barricade the house"
#   bash autopilot_prompt.sh "level carpentry by building stuff"
#
# The sidecar (auto_pilot_sidecar.py --pilot) reads this file and plans
# multi-step actions to achieve the goal.

PROMPT_FILE="$HOME/Zomboid/Lua/auto_pilot_prompt.txt"

GOAL="${1:?Usage: autopilot_prompt.sh \"<your goal>\"}"

printf '%s' "$GOAL" > "$PROMPT_FILE"
echo "Goal sent: $GOAL"
echo "File: $PROMPT_FILE"
