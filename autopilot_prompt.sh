#!/usr/bin/env bash
# autopilot_prompt.sh — Send a natural-language goal to the AutoPilot pilot mode.
#
# Usage:
#   bash autopilot_prompt.sh "search for a saw"
#   bash autopilot_prompt.sh "find food and water, then barricade the house"
#   bash autopilot_prompt.sh "level carpentry by building stuff"
#
# Sidecar support has been removed; prompt override is now built into AutoPilot.
# Use 2 in-game to trigger the prompt, and 3-7 for options.

PROMPT_FILE="$HOME/Zomboid/Lua/auto_pilot_prompt.txt"

GOAL="${1:?Usage: autopilot_prompt.sh \"<your goal>\"}"

printf '%s' "$GOAL" > "$PROMPT_FILE"
echo "Goal sent: $GOAL"
echo "File: $PROMPT_FILE"
