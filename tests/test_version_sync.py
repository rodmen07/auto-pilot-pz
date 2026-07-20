"""V5.3 drift guard: one version, stated in five places, checked here.

The mod's version is unavoidably duplicated:

  * ``mod.info``                      ``modversion=`` (Build 42 payload root)
  * ``42/mod.info``                   ``modversion=`` (B42 media root)
  * ``AutoPilot_Constants.VERSION``   what the RUNNING code reports in the
                                      F11 panel title
  * ``README.md``                     the "Current modversion:" line
  * ``sync_workshop.sh``              the Workshop description's version line

It is duplicated because Kahlua is sandboxed: the mod has no verified engine
surface for reading its own ``mod.info`` at runtime, so the in-game value has
to be compiled in.  This module is the price of that duplication.

Motivating incident: the Workshop copy cached on the user's machine was
``modversion=3.2`` while the source tree was ``4.3``.  Nothing in game said
so, and the mismatch was only found by hand-inspecting the cached files.  A
stale README "Current modversion:" line has bitten this project too.

These tests parse files as text (no Lua interpreter, no game), following the
cross-file guard precedent in ``tests/test_automation_metrics.py``.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent

MOD_INFO_ROOT = ROOT / "mod.info"
MOD_INFO_42 = ROOT / "42" / "mod.info"
CONSTANTS_LUA = ROOT / "42" / "media" / "lua" / "client" / "AutoPilot_Constants.lua"
README = ROOT / "README.md"
SYNC_SCRIPT = ROOT / "sync_workshop.sh"

# What a release commit has to touch, quoted in every failure message so the
# fix never has to be reconstructed from memory.
RELEASE_CHECKLIST = (
    "A version bump must change ALL of these in the SAME commit:\n"
    "  1. mod.info                                    modversion=X\n"
    "  2. 42/mod.info                                 modversion=X\n"
    "  3. 42/media/lua/client/AutoPilot_Constants.lua AutoPilot_Constants.VERSION = \"X\"\n"
    "  4. README.md                                   'Current modversion: X'\n"
    "(sync_workshop.sh reads mod.info at run time, so it needs no edit.)"
)


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _mod_info_version(path: Path) -> str | None:
    """Return the ``modversion=`` value from a mod.info file."""
    for line in _read(path).splitlines():
        if line.startswith("modversion="):
            return line.split("=", 1)[1].strip()
    return None


class TestVersionSync(unittest.TestCase):
    """Every place the version is written must agree."""

    def test_all_version_files_exist(self) -> None:
        """Every file this guard reads must still be where it expects."""
        for path in (MOD_INFO_ROOT, MOD_INFO_42, CONSTANTS_LUA, README, SYNC_SCRIPT):
            self.assertTrue(path.exists(), f"missing version-bearing file: {path}")

    def test_both_mod_info_files_agree(self) -> None:
        """The B42 payload ships both mod.info files; they cannot disagree."""
        root_version = _mod_info_version(MOD_INFO_ROOT)
        media_version = _mod_info_version(MOD_INFO_42)
        self.assertIsNotNone(root_version, "no modversion= line in mod.info")
        self.assertIsNotNone(media_version, "no modversion= line in 42/mod.info")
        self.assertEqual(
            root_version,
            media_version,
            f"mod.info says modversion={root_version} but 42/mod.info says "
            f"modversion={media_version}.  The game reads one of them and the "
            f"Workshop payload ships both.\n{RELEASE_CHECKLIST}",
        )

    def test_lua_constant_matches_mod_info(self) -> None:
        """The in-game version must equal the packaged version.

        This is the assertion that would have caught the 3.2-vs-4.3 cache
        mismatch the moment it was introduced.
        """
        mod_version = _mod_info_version(MOD_INFO_ROOT)
        self.assertIsNotNone(mod_version, "no modversion= line in mod.info")

        match = re.search(
            r'^AutoPilot_Constants\.VERSION\s*=\s*"([^"]+)"',
            _read(CONSTANTS_LUA),
            re.MULTILINE,
        )
        self.assertIsNotNone(
            match,
            'no AutoPilot_Constants.VERSION = "..." assignment in '
            f"{CONSTANTS_LUA.name}.  The F11 panel title reads it, so it "
            f"cannot be removed.\n{RELEASE_CHECKLIST}",
        )
        assert match is not None  # narrowing for type checkers
        lua_version = match.group(1)

        self.assertEqual(
            lua_version,
            mod_version,
            f"AutoPilot_Constants.VERSION is \"{lua_version}\" but mod.info "
            f"says modversion={mod_version}.  The F11 panel would report a "
            f"version the payload does not carry, which is exactly the "
            f"failure this guard exists to prevent (the user's cached "
            f"Workshop copy once read 3.2 while the source tree was 4.3).\n"
            f"{RELEASE_CHECKLIST}",
        )

    def test_readme_current_modversion_matches(self) -> None:
        """The README's 'Current modversion:' line has gone stale before."""
        mod_version = _mod_info_version(MOD_INFO_ROOT)
        match = re.search(r"^- Current modversion: (\S+)", _read(README), re.MULTILINE)
        self.assertIsNotNone(
            match,
            "no '- Current modversion: X' line in README.md.  If the line was "
            f"intentionally renamed, update this guard too.\n{RELEASE_CHECKLIST}",
        )
        assert match is not None  # narrowing for type checkers
        self.assertEqual(
            match.group(1),
            mod_version,
            f"README.md says 'Current modversion: {match.group(1)}' but "
            f"mod.info says modversion={mod_version}.\n{RELEASE_CHECKLIST}",
        )


class TestWorkshopVersionLine(unittest.TestCase):
    """sync_workshop.sh must keep the published description's version current.

    The script writes its embedded workshop.txt template only when the file is
    ABSENT, so template edits never reach an already-published item.  V5.3
    added a marker-driven in-place rewrite of the single version line to close
    that trap; these tests pin the pieces it depends on.
    """

    MARKER = "description=[b]Mod version: "

    def test_script_reads_version_from_mod_info(self) -> None:
        """The version line must be derived, never hardcoded in the script."""
        src = _read(SYNC_SCRIPT)
        self.assertIn(
            "modversion=",
            src,
            "sync_workshop.sh no longer reads modversion= from mod.info; the "
            "Workshop description would drift from the payload it ships.",
        )
        self.assertRegex(
            src,
            r'(?m)^MODVERSION="\$\(sed .*mod\.info.*\)"$',
            "sync_workshop.sh must read MODVERSION out of mod.info at run "
            "time so the Workshop description cannot be stale.",
        )

    def test_template_carries_the_version_marker(self) -> None:
        """A freshly created workshop.txt must already have the version line."""
        src = _read(SYNC_SCRIPT)
        self.assertEqual(
            src.count(self.MARKER),
            2,
            f"expected exactly two occurrences of {self.MARKER!r} in "
            "sync_workshop.sh (the VERSION_MARKER definition and the embedded "
            "workshop.txt template).  The rewrite finds the published line by "
            "this exact prefix, so the two must stay identical.",
        )

    def test_rewrite_never_touches_the_workshop_id(self) -> None:
        """id= is assigned by Steam after the first upload and is untouchable."""
        src = _read(SYNC_SCRIPT)
        self.assertIn(
            'if [[ "${line}" == "${VERSION_MARKER}"* ]]',
            src,
            "sync_workshop.sh must select the line to rewrite by the version "
            "marker alone.  Any broader match risks rewriting id=, which "
            "identifies the published Workshop item.",
        )
        self.assertNotRegex(
            src,
            r"^\s*(sed|awk|perl)\s[^\n]*\bid=",
            "nothing in sync_workshop.sh may rewrite the id= line.",
        )


if __name__ == "__main__":
    unittest.main()
