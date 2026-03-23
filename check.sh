#!/usr/bin/env bash
# check.sh — run all quality checks for the AutoPilot mod.
#
# Usage (Git Bash / WSL / Linux):
#   bash check.sh
#
# What it runs:
#   1. luacheck      — Lua syntax + lint (skipped with instructions if not installed)
#   2. Static API Guard — scans for deprecated PZ Build 42 API patterns
#   3. Lua logic tests  — dry-run behavioral tests for AutoPilot_Needs priority chain
#   4. pytest        — Python sidecar unit tests with mocked Anthropic API
#
# First-time setup:
#   pip install -r requirements-dev.txt
#   scoop install luacheck          (Windows, needs scoop.sh)
#   -- or --
#   luarocks install luacheck       (cross-platform, needs LuaRocks)
#   lua5.1 / lua                    (required for Lua logic tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Add Scoop shims to PATH so luacheck is found in new shell sessions.
[[ -d "${HOME}/scoop/shims" ]] && export PATH="${HOME}/scoop/shims:${PATH}"

PASS=0
FAIL=0

# ── 1. Lua lint ───────────────────────────────────────────────────────────────
echo "=== 1/4  Lua lint (luacheck) ==="

if command -v luacheck &>/dev/null; then
    # Pass files explicitly — directory-mode scan fails on Git Bash/Windows
    if luacheck 42/media/lua/client/*.lua --config .luacheckrc; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
else
    echo "SKIP  luacheck not found."
    echo "      Windows:  scoop install luacheck"
    echo "      Other:    luarocks install luacheck"
fi

echo ""

# ── 2. Static API Guard ───────────────────────────────────────────────────────
echo "=== 2/4  Static API Guard (deprecated PZ API scan) ==="

DEPRECATED_PATTERNS=(
    ":getHunger()"
    ":getThirst()"
    ":getFatigue()"
    ":getEndurance()"
    "CharacterStats\."
)

API_GUARD_FOUND=0
for pattern in "${DEPRECATED_PATTERNS[@]}"; do
    if grep -rn --include="*.lua" -- "$pattern" 42/media/lua/client/ 2>/dev/null; then
        echo "ERROR: Deprecated API pattern found: $pattern"
        API_GUARD_FOUND=$((API_GUARD_FOUND + 1))
    fi
done

if [[ $API_GUARD_FOUND -gt 0 ]]; then
    echo "FAIL  Static API Guard: $API_GUARD_FOUND deprecated pattern(s) detected."
    echo "      Use player:getStats():get(CharacterStat.X) instead of direct stat getters."
    FAIL=$((FAIL + 1))
else
    echo "PASS  Static API Guard: no deprecated APIs detected."
    PASS=$((PASS + 1))
fi

echo ""

# ── 3. Lua logic tests ────────────────────────────────────────────────────────
echo "=== 3/4  Lua logic tests (test_priority_logic.lua) ==="

LUA_BIN=""
for candidate in lua lua5.1 lua5.4; do
    if command -v "$candidate" &>/dev/null; then
        LUA_BIN="$candidate"
        break
    fi
done

if [[ -n "$LUA_BIN" ]]; then
    if "$LUA_BIN" tests/test_priority_logic.lua; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
else
    echo "SKIP  No Lua interpreter found (lua / lua5.1 / lua5.4)."
    echo "      Install lua5.1 via your package manager or luarocks."
fi

echo ""

# ── 4. Python unit tests ──────────────────────────────────────────────────────
echo "=== 4/4  Python unit tests (pytest) ==="

if python -m pytest --version &>/dev/null 2>&1; then
    if python -m pytest tests/ -v \
        --ignore=tests/test_priority_logic.lua \
        --ignore=tests/lua_mock_pz.lua; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
else
    echo "SKIP  pytest not found."
    echo "      Install: pip install -r requirements-dev.txt"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Some checks failed."
    exit 1
fi
echo "All checks passed."
