#!/usr/bin/env bash
# autopilot_cmd.sh — Pipe a command to the AutoPilot mod.
#
# Usage:
#   bash autopilot_cmd.sh eat
#   bash autopilot_cmd.sh sleep "character is exhausted"
#   bash autopilot_cmd.sh fight
#
# Available actions:
#   eat, drink, sleep, rest, exercise, outside,
#   fight, flee, bandage, idle, stop, status
#
# The mod reads this file on its next evaluation cycle (~1s).

CMD_FILE="$HOME/Zomboid/Lua/auto_pilot_cmd.json"

ACTION="${1:?Usage: autopilot_cmd.sh <action> [reason]}"
REASON="${2:-manual command}"

printf '{"action":"%s","reason":"%s"}' "$ACTION" "$REASON" > "$CMD_FILE"
echo "Sent: action=$ACTION reason=$REASON"
