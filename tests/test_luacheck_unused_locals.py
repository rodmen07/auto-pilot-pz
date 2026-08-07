"""The unused-local check (luacheck 211), and the guard that keeps it live.

``.luacheckrc`` used to suppress luacheck 211 repo-wide::

    -- 211: unused local variable  — common in PZ boilerplate (loop indices, etc.)
    -- 212: unused argument        — tolerate when mirroring PZ callback signatures
    ignore = { "211", "212" }

Measurement falsified both halves of that justification on 2026-08-07:

* **It named the wrong check.**  An unused LOOP variable is luacheck **213**,
  not 211.  Running the pinned linter with ``--enable 213`` over the 24 shipped
  client files reports **0 warnings**: the category the suppression was written
  for does not occur in this codebase at all.
* **It was hiding four real findings**, one of them a live hazard.
  ``AutoPilot_Medical`` carried ``local MEDICAL_LOOT_RADIUS =
  AutoPilot_Constants.MEDICAL_LOOT_RADIUS``, a *file-load-time snapshot* of a
  constant ``AutoPilot_Adaptive`` mutates at runtime after bleed-out deaths.
  Nothing read it — the call site correctly reads the constant live — but
  anyone "tidying" that call site to use the local would have silently frozen
  the adaptive widening, with no warning from lint or from any test.  That is
  the same dead-local class PR #49 had to find *by hand*, precisely because
  this ignore had blinded the linter to it.

So this module is the guard on that gate.  A config assertion alone would only
prove the ignore list *reads* a certain way; that is the "the code path is
reachable" claim, not evidence.  The tests below run the **real linter against
the real ``.luacheckrc``** in both directions:

* ``test_unused_local_is_reported`` — the gate ON.  A synthetic file with one
  unused local must be REJECTED under the config as shipped.
* ``test_unused_local_is_not_reported_when_211_is_suppressed`` — the gate OFF.
  The identical file under the identical config plus ``--ignore 211`` (i.e. the
  configuration this repo shipped until 2026-08-07) must pass clean.  Without
  this half, a config that had stopped working would still look tested.

Same drift-guard shape as :mod:`tests.test_luacheck_pin` and
:mod:`tests.test_changelog_guard`: the real artifact stays the single source of
truth and the test reads it rather than restating it.  Note that the ON/OFF
result is a statement about whichever ``luacheck`` is on PATH;
:mod:`tests.test_luacheck_pin` is what guarantees CI's binary is the pinned
``LUACHECK_VERSION`` from ``.github/workflows/ci.yml``.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent
LUACHECKRC = ROOT / ".luacheckrc"
CLIENT_DIR = ROOT / "42" / "media" / "lua" / "client"

LUACHECK = shutil.which("luacheck")

# One unused local, nothing else.  Deliberately boring: the point is that the
# ONLY thing that can make this file red is check 211.
UNUSED_LOCAL_LUA = "local unusedThing = 1\nreturn 1\n"

# One unused ARGUMENT, nothing else.  Check 212, which stays ignored on purpose.
UNUSED_ARG_LUA = "local function f(a, b) return a end\nreturn f\n"

# A clean file, to prove the harness itself is not simply always red.
CLEAN_LUA = "local used = 1\nreturn used\n"

# Every sanctioned inline suppression in the shipped client Lua, as
# (file, symbol) with the reason it earned one.  Pinned exactly so the inline
# escape hatch cannot quietly spread: silencing the linter at the call site is
# how a repo-wide blind spot starts, which is the whole story of check 211 here.
#
#   AutoPilot_Main / AutoPilot_XP, `print` — both shadow print with a noop so
#     that any print() added to the file is silenced by default.  Neither calls
#     print() today, which is why 211 flags the shadow; it is a standing
#     guarantee about FUTURE lines, not dead code.
#   AutoPilot_Rest, `sitOnly` — an argument retained for signature
#     compatibility after the V5.4 design change stopped it excluding beds
#     (documented at the declaration).  Pre-dates this guard, and is currently
#     REDUNDANT because 212 is ignored repo-wide; it is kept, not deleted,
#     because it is the correct suppression should 212 ever be un-blinded too.
ALLOWED_INLINE_IGNORES = {
    ("AutoPilot_Main.lua", "print"),
    ("AutoPilot_XP.lua", "print"),
    ("AutoPilot_Rest.lua", "sitOnly"),
}

# What each sanctioned suppression is attached to.  If the construct goes away,
# the allowlist entry must go with it -- otherwise the entry silently permits an
# unrelated future suppression of the same symbol in that file.
INLINE_IGNORE_ANCHORS = {
    ("AutoPilot_Main.lua", "print"): "local print = _apNoop",
    ("AutoPilot_XP.lua", "print"): "local print = _apNoop",
    ("AutoPilot_Rest.lua", "sitOnly"): "findRestFurniture(player, sitOnly)",
}


def _run_luacheck(cwd: Path, *args: str) -> subprocess.CompletedProcess:
    """Run the linter in ``cwd`` so it auto-discovers the ``.luacheckrc`` there.

    ``--no-color`` is not cosmetic here.  luacheck decides how to render a
    reported name from whether colour is on: with colour it emits the bare name
    wrapped in SGR escapes (``unused variable \\x1b[0m\\x1b[1munusedThing``),
    and without colour it QUOTES it (``unused variable 'unusedThing'``).  The
    first cut of this module asserted on the quoted form, which passed on the
    Windows dev box and failed on the Linux runner against *identical, correct*
    linter output -- the gate had found the defect and the test still went red.
    Pinning ``--no-color`` makes the output the same string everywhere.
    """
    return subprocess.run(
        [LUACHECK, "--no-color", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
    )


@unittest.skipUnless(LUACHECK, "luacheck is not on PATH")
class TestUnusedLocalCheckIsLive(unittest.TestCase):
    """The behavior difference between 211 suppressed and 211 live."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        # The REAL config, copied verbatim — not a restatement of it.  luacheck
        # discovers `.luacheckrc` from the working directory, so a copy beside
        # the probe file is what puts the shipped configuration under test.
        shutil.copyfile(LUACHECKRC, self.tmp / ".luacheckrc")
        self.addCleanup(self._tmp.cleanup)

    def _write(self, name: str, body: str) -> str:
        (self.tmp / name).write_text(body, encoding="utf-8")
        return name

    def test_harness_is_not_always_red(self) -> None:
        """A clean file passes, so a red below means the probe, not the setup."""
        name = self._write("clean.lua", CLEAN_LUA)
        result = _run_luacheck(self.tmp, name)
        self.assertEqual(
            result.returncode,
            0,
            f"a file with no findings should pass:\n{result.stdout}{result.stderr}",
        )

    def test_unused_local_is_reported(self) -> None:
        """GATE ON: the config as shipped must reject an unused local."""
        name = self._write("probe.lua", UNUSED_LOCAL_LUA)
        result = _run_luacheck(self.tmp, name)
        self.assertNotEqual(
            result.returncode,
            0,
            "luacheck accepted a file containing an unused local, so check 211 "
            "is suppressed again somewhere in .luacheckrc:\n" + result.stdout,
        )
        # The determinism `--no-color` buys is itself asserted, so a future
        # luacheck that ignored the flag would say so here rather than through a
        # confusing substring miss on one platform only.
        self.assertNotIn(
            "\x1b",
            result.stdout,
            "luacheck emitted ANSI escapes despite --no-color; the assertions "
            "below are about rendered text and cannot be trusted:\n"
            + repr(result.stdout),
        )
        # Asserted as three independent substrings rather than one rendered
        # sentence: the diagnostic's exact spacing and quoting are luacheck
        # presentation details that differ with colour and version, while the
        # location, the check's wording and the name are the actual content.
        for fragment in ("probe.lua:1:7", "unused variable", "unusedThing"):
            self.assertIn(
                fragment,
                result.stdout,
                f"expected {fragment!r} in the 211 diagnostic:\n" + result.stdout,
            )

    def test_unused_local_is_not_reported_when_211_is_suppressed(self) -> None:
        """GATE OFF: the same file, under the configuration shipped before this
        change, passes clean.  This is the other half of the behavior
        difference; without it, a config that had stopped working entirely would
        still satisfy the ON test's sibling assertions.
        """
        name = self._write("probe.lua", UNUSED_LOCAL_LUA)
        result = _run_luacheck(self.tmp, name, "--ignore", "211")
        self.assertEqual(
            result.returncode,
            0,
            "with 211 ignored the probe must pass; if it does not, this file is "
            "red for some reason OTHER than the unused local, and the ON test "
            "above proves nothing:\n" + result.stdout + result.stderr,
        )

    def test_unused_argument_is_still_tolerated(self) -> None:
        """212 stays ignored deliberately: PZ callback signatures are mirrored
        whole, so an unused parameter is a fact about the engine's API, not a
        defect.  Pinned so un-blinding 211 is not read as un-blinding both.
        """
        name = self._write("arg.lua", UNUSED_ARG_LUA)
        result = _run_luacheck(self.tmp, name)
        self.assertEqual(
            result.returncode,
            0,
            "check 212 (unused argument) is ignored on purpose; a red here means "
            "the ignore list lost it:\n" + result.stdout,
        )


class TestIgnoreListContents(unittest.TestCase):
    """Cheap assertions on the config text, complementing the runtime proof."""

    def _ignore_list(self) -> list[str]:
        text = LUACHECKRC.read_text(encoding="utf-8")
        # The single active `ignore = { ... }` assignment.  Comment lines in this
        # file legitimately mention "211", so the codes must come from the real
        # assignment rather than from a search over the whole file.
        matches = [
            m
            for m in re.finditer(r"^ignore\s*=\s*\{([^}]*)\}", text, re.MULTILINE)
        ]
        self.assertEqual(
            len(matches),
            1,
            f"expected exactly one active `ignore = {{...}}` line, found {len(matches)}",
        )
        return re.findall(r'"(\d+)"', matches[0].group(1))

    def test_211_is_not_ignored(self) -> None:
        self.assertNotIn(
            "211",
            self._ignore_list(),
            "check 211 (unused local variable) is back in the ignore list. It was "
            "removed on 2026-08-07 after measurement showed its stated "
            "justification named check 213 (which reports 0 warnings in this "
            "codebase) while the suppression itself was hiding a stale local copy "
            "of a runtime-mutated constant in AutoPilot_Medical. Fix the unused "
            "local instead, or suppress it inline at the one line it applies to.",
        )

    def test_212_is_still_ignored(self) -> None:
        self.assertIn(
            "212",
            self._ignore_list(),
            "check 212 (unused argument) is ignored deliberately, for functions "
            "mirroring a PZ callback signature they do not read every parameter of.",
        )


class TestInlineSuppressionsAreContained(unittest.TestCase):
    """The inline escape hatch must not spread past the two files that earned it."""

    def _found_inline_ignores(self) -> set[tuple[str, str]]:
        found = set()
        for path in sorted(CLIENT_DIR.glob("*.lua")):
            for symbols in re.findall(
                r"--\s*luacheck:\s*ignore\s+(.*)", path.read_text(encoding="utf-8")
            ):
                for symbol in symbols.split():
                    found.add((path.name, symbol))
        return found

    def test_inline_ignores_are_exactly_the_sanctioned_set(self) -> None:
        found = self._found_inline_ignores()
        self.assertEqual(
            found,
            ALLOWED_INLINE_IGNORES,
            "the set of inline `-- luacheck: ignore` suppressions in shipped "
            "client Lua has changed.\n"
            f"  unsanctioned (fix the finding, or add it above with its reason): "
            f"{sorted(found - ALLOWED_INLINE_IGNORES)}\n"
            f"  stale allowlist entries (delete them): "
            f"{sorted(ALLOWED_INLINE_IGNORES - found)}",
        )

    def test_every_sanctioned_suppression_still_has_its_anchor(self) -> None:
        """If the construct a suppression exists for is deleted, the suppression
        must go with it -- otherwise the allowlist entry silently permits an
        unrelated future ignore of that symbol in that file.
        """
        for (name, symbol), anchor in sorted(INLINE_IGNORE_ANCHORS.items()):
            body = (CLIENT_DIR / name).read_text(encoding="utf-8")
            self.assertIn(
                anchor,
                body,
                f"{name} is sanctioned to suppress `{symbol}` because of "
                f"`{anchor}`, which is no longer in the file. Drop the inline "
                "comment and the allowlist entry together.",
            )

    def test_every_sanctioned_suppression_is_covered_by_an_anchor(self) -> None:
        self.assertEqual(
            set(INLINE_IGNORE_ANCHORS),
            ALLOWED_INLINE_IGNORES,
            "every sanctioned suppression needs an anchor, or the guard above "
            "cannot notice when the construct it exists for disappears",
        )


@unittest.skipUnless(LUACHECK, "luacheck is not on PATH")
class TestShippedTreeIsCleanUnderTheLiveCheck(unittest.TestCase):
    """The four findings un-blinding 211 exposed stay fixed."""

    def test_client_lua_has_no_unused_locals(self) -> None:
        files = sorted(str(p) for p in CLIENT_DIR.glob("*.lua"))
        self.assertGreater(len(files), 0, "no client Lua found; the guard has gone blind")
        result = subprocess.run(
            [LUACHECK, "--no-color", *files, "--config", ".luacheckrc"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.returncode,
            0,
            "shipped client Lua is not clean under the unblinded config:\n"
            + result.stdout,
        )
