#!/usr/bin/env bash
# deploy.sh — copy AutoPilot mod files into the Project Zomboid mods directory.
#
# Usage (Git Bash):
#   bash deploy.sh
#
# Currently your dev directory IS ~/Zomboid/mods/auto_pilot/, so this script
# will detect the same-directory case and exit cleanly.
# It becomes useful if you later move your source to a separate git repo
# (e.g. ~/dev/auto_pilot/) and want a one-command deploy.
#
# What gets copied:
#   42/          — Lua mod files (the whole B42 folder)
#   auto_pilot_sidecar.py — Python sidecar
#
# What is NOT copied (dev-only, not needed by PZ):
#   .luacheckrc, schemas/, tests/, check.sh, deploy.sh, requirements*.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_MODS="${HOME}/Zomboid/mods"
DEST="${PZ_MODS}/auto_pilot"

# Resolve real paths so symlinks and MSYS path prefixes don't fool the check.
SRC_REAL="$(realpath "${SCRIPT_DIR}" 2>/dev/null || echo "${SCRIPT_DIR}")"
DST_REAL="$(realpath "${DEST}"      2>/dev/null || echo "${DEST}")"

if [[ "${SRC_REAL}" == "${DST_REAL}" ]]; then
    echo "Source and destination are the same directory — nothing to copy."
    echo "Tip: move your dev repo outside ~/Zomboid/mods/ and re-run to deploy."
    exit 0
fi

echo "Source : ${SCRIPT_DIR}"
echo "Dest   : ${DEST}"
echo ""

mkdir -p "${DEST}"

echo "Copying 42/ …"
cp -r "${SCRIPT_DIR}/42" "${DEST}/"

echo "Copying sidecar …"
cp "${SCRIPT_DIR}/auto_pilot_sidecar.py" "${DEST}/auto_pilot_sidecar.py"

echo ""
echo "Deploy complete → ${DEST}"
