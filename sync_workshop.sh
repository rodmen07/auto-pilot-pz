#!/usr/bin/env bash
# sync_workshop.sh — build/refresh the Steam Workshop staging folder from this
# repo.  Run after every release commit, then upload in-game:
#   PZ Main Menu -> Workshop -> Create/Update Item -> AutoPilotLeveler
#
# Copies ONLY the mod payload (42/, common/, mod.info, poster.png) — never the
# git repo, tests, or dev tooling.  workshop.txt is created once and then left
# alone (the game writes the assigned id= back into it after first upload),
# with ONE exception added in V5.3: the description's version line is kept in
# sync with mod.info's modversion, in place, by marker.  See
# _sync_workshop_version below for why that is safe on a published item.

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

# ── workshop.txt version line (V5.3) ─────────────────────────────────────────
# The Workshop description must state the published version, so the user can
# compare the store page against what the F11 panel title reports in game.
# (Real incident: the cached Workshop copy was modversion 3.2 while the source
# tree was 4.3, and nothing on screen said so.)
#
# MODVERSION is read from mod.info, never hardcoded here, so this file cannot
# drift from the payload it is shipping.
MODVERSION="$(sed -n 's/^modversion=//p' "${SCRIPT_DIR}/mod.info" | head -1 | tr -d '\r')"
if [[ -z "${MODVERSION}" ]]; then
    echo "ERROR: could not read modversion= from ${SCRIPT_DIR}/mod.info" >&2
    exit 1
fi

# Stable marker prefix: the ONE line this script is allowed to rewrite.
VERSION_MARKER='description=[b]Mod version: '
VERSION_LINE="${VERSION_MARKER}${MODVERSION}[/b] (press F11 in game: the panel title shows the version actually loaded)"

# Rewrite ONLY the marker line, preserving every other line byte for byte.
#
# Why this is safe for an already-published item: the file is streamed line by
# line and each line is echoed unchanged unless it starts with VERSION_MARKER.
# id= (which the game fills in after the first upload and which identifies the
# published item), title=, tags=, visibility= and every other description=
# line are never parsed, matched, or reordered — they are copied verbatim,
# including their CRLF terminators, which the game writes.  A backup is left
# at workshop.txt.bak, nothing is written when the line is already current,
# and if the file has neither a version line nor the anchor to insert one, the
# script refuses to guess and prints the line for the human to paste.
_sync_workshop_version() {
    local file="$1"
    local tmp="${file}.new.$$"
    local emitted=0
    local changed=0
    : > "${tmp}"
    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        local line="${raw%$'\r'}"
        local eol=""
        [[ "${line}" != "${raw}" ]] && eol=$'\r'
        if [[ "${line}" == "${VERSION_MARKER}"* ]]; then
            [[ "${line}" != "${VERSION_LINE}" ]] && changed=1
            printf '%s%s\n' "${VERSION_LINE}" "${eol}" >> "${tmp}"
            emitted=1
            continue
        fi
        # No version line yet (every file published before V5.3): insert one
        # just above the trailing "Build 42.x ... Source: ..." credit line.
        if [[ ${emitted} -eq 0 && "${line}" == "description=Build "* ]]; then
            printf '%s%s\n' "${VERSION_LINE}" "${eol}" >> "${tmp}"
            printf 'description=%s\n' "${eol}" >> "${tmp}"
            emitted=1
            changed=1
        fi
        printf '%s%s\n' "${line}" "${eol}" >> "${tmp}"
    done < "${file}"

    if [[ ${emitted} -eq 0 ]]; then
        rm -f "${tmp}"
        echo ""
        echo "!!! workshop.txt has no version line and no 'description=Build ...' anchor."
        echo "!!! Refusing to guess where it belongs.  Add this line by hand before uploading:"
        echo "!!!   ${VERSION_LINE}"
        echo ""
        return 0
    fi
    if [[ ${changed} -eq 0 ]]; then
        rm -f "${tmp}"
        echo "workshop.txt version line already reads ${MODVERSION}."
        return 0
    fi
    cp "${file}" "${file}.bak"
    mv "${tmp}" "${file}"
    echo "workshop.txt version line updated to ${MODVERSION} (backup: workshop.txt.bak)."
    echo "Remember to re-upload: PZ Main Menu -> Workshop -> Create/Update Item."
}

# ── workshop.txt (created only when absent — the game manages id= after upload) ──
if [[ ! -f "${STAGING}/workshop.txt" ]]; then
    # The version placeholder below is rewritten by _sync_workshop_version
    # immediately after creation, so there is exactly one code path that
    # decides what the version line says.
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
description=[b]Survival fail-safe:[/b] eats, drinks, sleeps, bandages, and fights or flees when zombies actually threaten - wanderers outside your walls are ignored. Keeps a small stockpile with short near-home loot trips.
description=
description=[b]Death learning:[/b] every death is recorded with full context, and the mod adjusts its survival thresholds within safe bounds next session.
description=
description=[b]Multiplayer:[/b] client-side only; each player automates their own character through the normal server-validated actions. Safe to list on hosted servers (Mods=AutoPilot). Splitscreen is not supported.
description=
description=[b]Fair play:[/b] this automates AFK play - use it on your own server or with the owner's blessing.
description=
description=[b]Mod version: 0.0[/b] (press F11 in game: the panel title shows the version actually loaded)
description=
description=Build 42.19.0 Unstable. Source: https://github.com/rodmen07/auto-pilot-pz
tags=Build 42;Multiplayer;QualityOfLife
visibility=public
EOF
    echo "Created workshop.txt (id= will be filled by the game after first upload)."
fi

_sync_workshop_version "${STAGING}/workshop.txt"

echo "Workshop staging synced: ${STAGING}"
find "${STAGING}" -maxdepth 4 | head -20
