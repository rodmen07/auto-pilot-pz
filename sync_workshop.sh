#!/usr/bin/env bash
# sync_workshop.sh — build/refresh the Steam Workshop staging folder from this
# repo.  Run after every release commit, then upload in-game:
#   PZ Main Menu -> Workshop -> Create/Update Item -> AutoPilotLeveler
#
# Copies ONLY the mod payload (42/, common/, mod.info, poster.png) — never the
# git repo, tests, or dev tooling.  workshop.txt is created once and then left
# alone (the game writes the assigned id= back into it after first upload).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING="${HOME}/Zomboid/Workshop/AutoPilotLeveler"
PAYLOAD="${STAGING}/Contents/mods/auto_pilot"

mkdir -p "${PAYLOAD}"

# ── Mod payload ───────────────────────────────────────────────────────────────
rm -rf "${PAYLOAD}/42" "${PAYLOAD}/common"
cp -r "${SCRIPT_DIR}/42"     "${PAYLOAD}/42"
cp -r "${SCRIPT_DIR}/common" "${PAYLOAD}/common"
cp "${SCRIPT_DIR}/mod.info"   "${PAYLOAD}/mod.info"
cp "${SCRIPT_DIR}/poster.png" "${PAYLOAD}/poster.png"

# ── Preview image (Workshop card; the 42/ poster is the higher-res one) ──────
cp "${SCRIPT_DIR}/42/poster.png" "${STAGING}/preview.png"

# ── workshop.txt (only when absent — the game manages id= after upload) ──────
if [[ ! -f "${STAGING}/workshop.txt" ]]; then
    cat > "${STAGING}/workshop.txt" <<'EOF'
version=1
id=
title=AutoPilot Leveler
description=[b]Grind Strength and Fitness while AFK - with a survival fail-safe watching your back.[/b]
description=
description=Inactive on spawn: stabilize first (clear the area, stock supplies), then press [b]F10[/b] to start the grind.
description=
description=[b]Leveling:[/b] pick a focus in the [b]F11[/b] panel - Strength (push-ups), Fitness (squats, sit-ups while legs are stiff), or Auto (burpees, both stats). Live metrics: level, XP to next, session gain, XP/hour, ETA. Detects the game's per-exercise diminishing returns and rotates or rests instead of grinding for zero XP. Uses dumbbells/barbells when available.
description=
description=[b]Survival fail-safe:[/b] eats, drinks, sleeps, bandages, and fights or flees when zombies actually threaten - wanderers outside your walls are ignored. Keeps a small stockpile with short near-home loot trips and maintains window barricades.
description=
description=[b]Death learning:[/b] every death is recorded with full context, and the mod adjusts its survival thresholds within safe bounds next session.
description=
description=[b]Multiplayer:[/b] client-side only; each player automates their own character through the normal server-validated actions. Safe to list on hosted servers (Mods=AutoPilot). Splitscreen is not supported.
description=
description=[b]Fair play:[/b] this automates AFK play - use it on your own server or with the owner's blessing.
description=
description=Build 42.19.0 Unstable. Source: https://github.com/rodmen07/auto-pilot-pz
tags=Build 42;Multiplayer;QualityOfLife
visibility=public
EOF
    echo "Created workshop.txt (id= will be filled by the game after first upload)."
fi

echo "Workshop staging synced: ${STAGING}"
find "${STAGING}" -maxdepth 4 | head -20
