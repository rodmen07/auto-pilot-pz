#!/usr/bin/env bash
# check.sh — run all quality checks for the AutoPilot mod.
#
# Usage (Git Bash / WSL / Linux):
#   bash check.sh
#
# What it runs:
#   1. luacheck  — Lua syntax + lint (skipped with instructions if not installed)
#   2. pytest    — Python sidecar unit tests with mocked Anthropic API
#
# First-time setup:
#   pip install -r requirements-dev.txt
#   scoop install luacheck          (Windows, needs scoop.sh)
#   -- or --
#   luarocks install luacheck       (cross-platform, needs LuaRocks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Add Scoop shims to PATH so luacheck is found in new shell sessions.
[[ -d "${HOME}/scoop/shims" ]] && export PATH="${HOME}/scoop/shims:${PATH}"

PASS=0
FAIL=0

# ── 1. Lua lint ───────────────────────────────────────────────────────────────
echo "=== 1/2  Lua lint (luacheck) ==="

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

# ── 2. Python unit tests ──────────────────────────────────────────────────────
echo "=== 2/2  Python unit tests (pytest) ==="

if python -m pytest --version &>/dev/null 2>&1; then
    if python -m pytest tests/ -v; then
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
