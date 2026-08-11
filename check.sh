#!/usr/bin/env bash
# check.sh — run all quality checks for the AutoPilot mod.
#
# Usage (Git Bash / WSL / Linux):
#   bash check.sh
#
# What it runs:
#   1. luacheck      — Lua syntax + lint (skipped with instructions if not installed)
#   2. Static API Guard — scans for deprecated PZ Build 42 API patterns
#   3. Lua logic tests  — behavioral tests for AutoPilot_Needs, Threat, Medical,
#                         Home, Map
#   4. pytest        — Python automation and benchmark unit tests
#
# First-time setup:
#   pip install -r requirements-dev.txt
#   scoop install luacheck          (Windows, needs scoop.sh)
#   -- or --
#   luarocks install luacheck       (cross-platform, needs LuaRocks)
#   lua5.1 / lua                    (required for Lua logic tests)
#
# Skip handling (tested by tests/test_check_sh.py):
#   A suite whose tool is missing prints SKIP with install instructions, and a
#   run that skipped ANY suite exits non-zero: a skipped gate did not run, so
#   the run must not report success. Environment overrides:
#     CHECK_ALLOW_SKIP=1        accept a degraded run explicitly (exit 0, but
#                               labelled "degraded run", never a full pass).
#     CHECK_SIMULATE_MISSING="luacheck lua python"
#                               test hook: treat the named tools as absent in
#                               the discovery paths. Absence-only by design --
#                               it can never make a missing tool look present,
#                               so it cannot weaken a passing gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Add Scoop shims to PATH so luacheck is found in new shell sessions.
[[ -d "${HOME}/scoop/shims" ]] && export PATH="${HOME}/scoop/shims:${PATH}"

PASS=0
FAIL=0
SKIP=0
SKIPPED_SUITES=""

# Test hook (see header): returns 0 when $1 is listed in CHECK_SIMULATE_MISSING.
simulated_missing() {
    case " ${CHECK_SIMULATE_MISSING:-} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Tool discovery: found means present on PATH AND not simulated as missing.
have_tool() {
    simulated_missing "$1" && return 1
    command -v "$1" &>/dev/null
}

record_skip() {
    SKIP=$((SKIP + 1))
    SKIPPED_SUITES="${SKIPPED_SUITES:+${SKIPPED_SUITES} }$1"
}

# ── 1. Lua lint ───────────────────────────────────────────────────────────────
echo "=== 1/4  Lua lint (luacheck) ==="

if have_tool luacheck; then
    # Local-vs-CI linter drift, reported before the lint runs.
    #
    # CI pins the linter (LUACHECK_VERSION in .github/workflows/ci.yml, enforced
    # there by the "Luacheck pin guard" step). This box installs its own build
    # -- scoop on Windows, luarocks elsewhere -- so the two can silently differ,
    # and a local "0 warnings" would then be a different linter's opinion than
    # the one that actually gates the merge. The pin is read out of the workflow
    # so there is still exactly ONE source of truth for it.
    #
    # Deliberately INFORMATIONAL, not fatal: a dev box cannot be forced onto a
    # version, and failing here would block local runs without making CI safer.
    CI_LUACHECK_PIN="$(grep -oE 'LUACHECK_VERSION:[[:space:]]*"?[0-9]+(\.[0-9]+)*' \
        .github/workflows/ci.yml 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)*' | head -n 1 || true)"
    LOCAL_LUACHECK_VERSION="$(luacheck --version 2>/dev/null | head -n 1 \
        | grep -oE '[0-9]+(\.[0-9]+)*' | head -n 1 || true)"
    if [[ -z "$CI_LUACHECK_PIN" ]]; then
        echo "NOTE  no LUACHECK_VERSION pin found in .github/workflows/ci.yml — cannot compare."
    elif [[ -z "$LOCAL_LUACHECK_VERSION" ]]; then
        echo "NOTE  local luacheck version unreadable — cannot compare against CI pin ${CI_LUACHECK_PIN}."
    elif [[ "$LOCAL_LUACHECK_VERSION" != "$CI_LUACHECK_PIN" ]]; then
        echo "NOTE  local luacheck ${LOCAL_LUACHECK_VERSION} differs from the CI pin ${CI_LUACHECK_PIN}."
        echo "      CI's verdict is the one that gates the merge; install ${CI_LUACHECK_PIN} to match."
    else
        echo "NOTE  local luacheck ${LOCAL_LUACHECK_VERSION} matches the CI pin."
    fi

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
    record_skip "luacheck"
fi

echo ""

# ── 2. Static API Guard ───────────────────────────────────────────────────────
echo "=== 2/4  Static API Guard (deprecated PZ API scan) ==="

# The pattern list and the corpus probe below are the SECOND home of ci.yml's
# "Static API Guard" step. tests/test_static_api_guard.py extracts both and
# fails if the two pattern lists drift, and executes this block's blind guard,
# so the local gate and the merge gate can never disagree about what counts as
# a deprecated API or about how few files it is willing to scan.
API_GUARD_DIR="42/media/lua/client"

DEPRECATED_PATTERNS=(
    ":getHunger()"
    ":getThirst()"
    ":getFatigue()"
    ":getEndurance()"
    "CharacterStats\."
)

# Positive control, in the scan's OWN grep form (recursive, same --include glob,
# same directory): every check below decides from an EMPTY grep result, and an
# unreachable corpus reads empty exactly like a clean one. Before this probe
# existed, running this section anywhere without a 42/media/lua/client/ printed
# "PASS Static API Guard: no deprecated APIs detected" having read nothing.
API_GUARD_FILES="$(grep -rl --include="*.lua" -e 'AutoPilot' -- "${API_GUARD_DIR}" 2>/dev/null || true)"

if [[ -z ${API_GUARD_FILES} ]]; then
    echo "FAIL  Static API Guard: the scan reaches 0 Lua file(s) under ${API_GUARD_DIR}/."
    echo "      The guard has gone blind; it must never report a clean scan of nothing."
    echo "      Fix: point API_GUARD_DIR (and ci.yml's CLIENT_DIR) at the directory the"
    echo "      shipped client Lua now lives in."
    FAIL=$((FAIL + 1))
else
    API_GUARD_REACHED="$(printf '%s\n' "${API_GUARD_FILES}" | wc -l | tr -d '[:space:]')"
    echo "      Corpus probe: the scan reaches ${API_GUARD_REACHED} Lua file(s) under ${API_GUARD_DIR}/."

    API_GUARD_FOUND=0
    for pattern in "${DEPRECATED_PATTERNS[@]}"; do
        if grep -rn --include="*.lua" -- "$pattern" "${API_GUARD_DIR}/" 2>/dev/null; then
            echo "ERROR: Deprecated API pattern found: $pattern"
            API_GUARD_FOUND=$((API_GUARD_FOUND + 1))
        fi
    done

    if [[ $API_GUARD_FOUND -gt 0 ]]; then
        echo "FAIL  Static API Guard: $API_GUARD_FOUND deprecated pattern(s) detected."
        echo "      Use player:getStats():get(CharacterStat.X) instead of direct stat getters."
        FAIL=$((FAIL + 1))
    else
        echo "PASS  Static API Guard: no deprecated APIs detected in ${API_GUARD_REACHED} file(s)."
        PASS=$((PASS + 1))
    fi
fi

# M4.3 Line-count guard: warn if any single Lua module exceeds 1000 lines.
echo ""
echo "=== 2b/4  Line-count guard (1000-line warning) ==="
LC_WARN=0
for lua_file in 42/media/lua/client/*.lua; do
    lines=$(wc -l < "$lua_file")
    if [[ $lines -gt 1000 ]]; then
        echo "  WARN  $lua_file has $lines lines (> 1000 — consider splitting)."
        LC_WARN=$((LC_WARN + 1))
    fi
done
if [[ $LC_WARN -eq 0 ]]; then
    echo "PASS  Line-count guard: all modules ≤ 1000 lines."
else
    echo "NOTE  Line-count guard: $LC_WARN module(s) exceed 1000 lines (CI does not fail on this)."
fi

echo ""

# ── 3. Lua logic tests ────────────────────────────────────────────────────────
echo "=== 3/4  Lua logic tests ==="

LUA_BIN=""
if ! simulated_missing lua; then
    for candidate in lua lua5.1 lua5.4; do
        if command -v "$candidate" &>/dev/null; then
            LUA_BIN="$candidate"
            break
        fi
    done
fi

# Discover all Lua test files via glob so local and CI runs cannot diverge.
# New tests/test_*.lua files are picked up automatically; zero matches is fatal.
shopt -s nullglob
LUA_TEST_FILES=(tests/test_*.lua)
shopt -u nullglob

if [[ ${#LUA_TEST_FILES[@]} -eq 0 ]]; then
    echo "FAIL  No Lua test files found matching tests/test_*.lua"
    echo "      Test discovery is glob-driven; zero matches means the suite is missing."
    exit 1
fi

if [[ -n "$LUA_BIN" ]]; then
    LUA_PASS=0
    LUA_FAIL=0
    for test_file in "${LUA_TEST_FILES[@]}"; do
        echo "  → $test_file"
        if "$LUA_BIN" "$test_file"; then
            LUA_PASS=$((LUA_PASS + 1))
        else
            LUA_FAIL=$((LUA_FAIL + 1))
        fi
    done
    echo ""
    echo "  Lua tests: ${LUA_PASS}/${#LUA_TEST_FILES[@]} files passed"
    if [[ $LUA_FAIL -gt 0 ]]; then
        FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1))
    fi
else
    echo "SKIP  No Lua interpreter found (lua / lua5.1 / lua5.4)."
    echo "      Install lua5.1 via your package manager or luarocks."
    record_skip "lua-tests"
fi

echo ""

# ── 4. Python unit tests ──────────────────────────────────────────────────────
echo "=== 4/4  Python unit tests (pytest) ==="

# Detect python3 first, then fall back to python, then the Windows launcher.
PYTHON_BIN=""
if ! simulated_missing python; then
    for candidate in python3 python py; do
        if command -v "$candidate" &>/dev/null && \
           "$candidate" -m pytest --version &>/dev/null; then
            PYTHON_BIN="$candidate"
            break
        fi
    done
    # Git Bash on Windows: python.exe installs to C:\Python3XX and is usually
    # NOT on the Bash PATH (this repo's dev box is exactly that case, and the
    # old discovery therefore skipped pytest on every local run). Probe the
    # conventional install roots before giving up.
    if [[ -z "$PYTHON_BIN" ]]; then
        for candidate in /c/Python3*/python.exe; do
            [[ -x "$candidate" ]] || continue
            if "$candidate" -m pytest --version &>/dev/null; then
                PYTHON_BIN="$candidate"
                break
            fi
        done
    fi
fi

if [[ -n "$PYTHON_BIN" ]]; then
    echo "Using ${PYTHON_BIN}"
    if "$PYTHON_BIN" -m pytest tests/ -v; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
else
    echo "SKIP  pytest not found."
    echo "      Install: pip install -r requirements-dev.txt"
    record_skip "pytest"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Summary: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Some checks failed."
    exit 1
fi
if [[ $SKIP -gt 0 ]]; then
    echo "Skipped suite(s): ${SKIPPED_SUITES}"
    if [[ "${CHECK_ALLOW_SKIP:-0}" == "1" ]]; then
        echo "CHECK_ALLOW_SKIP=1: accepting a degraded run (skipped suites did NOT run;"
        echo "this is not a full pass)."
        exit 0
    fi
    echo "FAIL  A skipped suite is a gate that did not run, so this run cannot"
    echo "      report success. Install the missing tool(s) above, or set"
    echo "      CHECK_ALLOW_SKIP=1 to accept a degraded run explicitly."
    exit 1
fi
echo "All checks passed."
