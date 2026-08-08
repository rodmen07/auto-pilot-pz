"""Truth guard for ``README.md``'s module roster: the one claim in the front
page of this repository that goes stale on a *deliberate, dated* decision and
can be checked against the filesystem.

WHY THIS EXISTS
---------------
``README.md`` is the first screen anyone sent here by the Steam Workshop item
or the GitHub release page reads, and it is the LAST document this project
kept honest.  ``CHANGELOG.md`` got a mechanical tie to reality in ``ci.yml``
(the *Changelog guard*, exercised by ``tests/test_changelog_guard.py``);
``ROADMAP.md`` got one in ``tests/test_roadmap_truth.py``; the version string
got one in ``tests/test_version_sync.py``.  The README got nothing, and by
2026-08-08 it opened with a banner announcing that the project had been
decommissioned -- fifteen days after that decommission was reversed, and on
the day the project cut its second release.  Under the same heading it claimed
``17`` Lua modules, listed ``16`` of them by name, and the glob found ``24``.

The banner was a one-off correction; **the module roster is the part that will
drift again**, because every code-health extraction adds a file (this project
has shipped six such splits) and nothing made the README notice.  So the
roster is what gets a guard.

WHAT IS GUARDED, AND WHAT IS DELIBERATELY NOT
---------------------------------------------
Guarded, both directions, against ``42/media/lua/client/*.lua``:

  1. the module COUNT stated in the section heading
  2. the module NAMES listed underneath it

Two claims rather than one because the drift that motivated this file was
between the README and *itself*: the count said 17 while the list named 16, so
a guard that checked only the count would have gone green on a list that was
already missing a module.  Checking the names makes the count redundant as a
correctness matter -- it is kept because the heading is what a reader actually
sees, and an unchecked number beside a checked list is exactly the kind of
decoration this project keeps finding.

Deliberately NOT guarded: the deprecation banner this file's removal was
prompted by, and every other prose claim in the README (the feature bullets,
the priority chain, the install steps).  A bare ``assertNotIn("NO LONGER
MAINTAINED")`` would be a tripwire with nothing coupled to it -- it could only
ever fail if somebody deliberately re-added the banner, and it would not know
whether that was true when they did.  The line this repo already draws in
``tests/test_roadmap_truth.py`` applies unchanged: *guard what changes on a
deliberate, dated decision (a module added or deleted); audit what changes as
a side effect of ordinary work.*  The prose stays the job of the periodic
product truth audit.

WHY THE ANCHOR IS STRICT
------------------------
The heading anchor must match **exactly once**: zero matches means the section
was reworded and the guard has gone blind, more than one means the anchor is
no longer unique.  Both are hard failures.  A guard that reports success on
input it cannot see is worse than no guard.

The module names are collected from the roster SECTION ONLY -- from the
heading to the next ``##`` -- not from the whole file.  The README names
individual modules elsewhere on purpose (``AutoPilot_Constants.lua`` appears
in the version checklist and in the telemetry section), and a file-wide scan
would silently absorb those into the roster.

PARSE AS TEXT, like ``tests/test_version_sync.py``,
``tests/test_changelog_guard.py`` and ``tests/test_roadmap_truth.py``: no
markdown library, no game, no network.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent

README = ROOT / "README.md"
CLIENT_LUA_DIR = ROOT / "42" / "media" / "lua" / "client"

# ---------------------------------------------------------------------------
# The anchors.  Changing the README's wording means changing these here, on
# purpose, in the same commit -- that coupling IS the guard.
# ---------------------------------------------------------------------------
ANCHOR_MODULE_COUNT = (
    r"(?m)^## Core Runtime Modules \((\d+) under `42/media/lua/client/`\)\s*$"
)

# A roster line: "- AutoPilot_Foo.lua: what it does".  Anchored at the start of
# the line and requiring the trailing colon, so a module named mid-sentence in
# a paragraph of the same section cannot be mistaken for an entry.
ROSTER_ENTRY = re.compile(r"(?m)^- (AutoPilot_[A-Za-z0-9_]+\.lua):")

# Where the roster section ends: the next level-2 heading.
NEXT_HEADING = re.compile(r"(?m)^## ")

FIX_HINT = (
    "README.md and 42/media/lua/client/ disagree.  Fix the README (it is the\n"
    "one that goes stale), not this test -- a module extraction or deletion is\n"
    "supposed to edit the roster in the same commit.  If the section was\n"
    "deliberately reworded, update the anchor in tests/test_readme_truth.py in\n"
    "that same commit."
)


class ReadmeAnchorError(AssertionError):
    """The anchor did not match exactly once, so the guard cannot see its input."""


def readme_text() -> str:
    return README.read_text(encoding="utf-8")


def extract_module_count(text: str) -> int:
    """Return the module count stated in the roster heading.

    Raises :class:`ReadmeAnchorError` on zero matches (the heading was reworded
    -- the guard has gone blind) and on more than one (which copy is
    authoritative is undefined).  Never returns a default: a truth guard that
    silently degrades to "nothing to check" is the failure this module exists
    to prevent.
    """
    matches = re.findall(ANCHOR_MODULE_COUNT, text)
    if not matches:
        raise ReadmeAnchorError(
            "README.md truth guard has gone BLIND on the module count: the anchor\n"
            f"  {ANCHOR_MODULE_COUNT}\n"
            "matched ZERO times.  The roster heading was reworded, moved or\n"
            "deleted.  A guard that passes when it can no longer find what it\n"
            "checks is worse than no guard, so this is a hard failure.\n" + FIX_HINT
        )
    if len(matches) > 1:
        raise ReadmeAnchorError(
            "README.md truth guard is AMBIGUOUS on the module count: the anchor\n"
            f"  {ANCHOR_MODULE_COUNT}\n"
            f"matched {len(matches)} times ({matches!r}).  Two live homes for the\n"
            "same claim drift apart with the guard still green.  Keep ONE.\n"
            + FIX_HINT
        )
    return int(matches[0])


def extract_roster_section(text: str) -> str:
    """Return the text between the roster heading and the next ``##`` heading.

    Scoping matters: the README names individual modules outside this section
    on purpose (the version checklist points at ``AutoPilot_Constants.lua``),
    and a file-wide scan would absorb them into the roster.
    """
    match = re.search(ANCHOR_MODULE_COUNT, text)
    if match is None:
        raise ReadmeAnchorError(
            "README.md truth guard has gone BLIND: no roster heading, so there is\n"
            "no section to read module names out of.\n" + FIX_HINT
        )
    rest = text[match.end() :]
    end = NEXT_HEADING.search(rest)
    return rest[: end.start()] if end else rest


def extract_listed_modules(text: str) -> list[str]:
    """Every module named in the roster section, in the order listed."""
    return ROSTER_ENTRY.findall(extract_roster_section(text))


def client_module_names() -> list[str]:
    """Glob-discovered client Lua module filenames (never a hand-written list).

    A hand-enumerated list degrades silently on the next module extraction; a
    glob with a zero-match hard failure announces itself instead.
    """
    return sorted(path.name for path in CLIENT_LUA_DIR.glob("*.lua"))


# ---------------------------------------------------------------------------
# The live gate: the real README.md against the real module tree.
# ---------------------------------------------------------------------------
class TestReadmeRosterMatchesTheModuleTree(unittest.TestCase):
    """Each test reads BOTH sources -- the claim and the thing it claims."""

    def test_readme_exists(self) -> None:
        self.assertTrue(
            README.is_file(),
            "README.md is missing.  If it was renamed, retarget this guard in\n"
            "the same commit rather than deleting it.",
        )

    def test_the_glob_finds_modules_at_all(self) -> None:
        """Zero matches means the tree moved and this guard measures nothing."""
        self.assertGreater(
            len(client_module_names()),
            0,
            f"no *.lua files found under {CLIENT_LUA_DIR}.  Discovery is\n"
            "glob-driven; zero matches means the module tree moved and every\n"
            "assertion below would be comparing against an empty set.",
        )

    def test_heading_count_matches_the_client_lua_glob(self) -> None:
        claimed = extract_module_count(readme_text())
        actual = client_module_names()
        self.assertEqual(
            claimed,
            len(actual),
            f"README.md's roster heading claims {claimed} Lua modules under\n"
            f"42/media/lua/client/, the glob finds {len(actual)}:\n  "
            + "\n  ".join(actual)
            + "\n"
            + FIX_HINT,
        )

    def test_listed_names_match_the_client_lua_glob(self) -> None:
        """The assertion the count alone could not make.

        The 2026-08-08 drift had the heading claiming 17 and the list naming
        16 -- two wrong numbers that a count-only guard could still have been
        talked into agreeing with.
        """
        listed = extract_listed_modules(readme_text())
        actual = client_module_names()
        missing = sorted(set(actual) - set(listed))
        extra = sorted(set(listed) - set(actual))
        self.assertEqual(
            (missing, extra),
            ([], []),
            "README.md's Core Runtime Modules roster does not match the module\n"
            "tree.\n"
            f"  shipped but NOT listed in the README ({len(missing)}): "
            f"{missing or 'none'}\n"
            f"  listed in the README but NOT shipped ({len(extra)}): "
            f"{extra or 'none'}\n" + FIX_HINT,
        )

    def test_the_roster_lists_each_module_once(self) -> None:
        """A duplicate entry would make the name set agree while the count does
        not, which is the split-brain the two assertions above exist to close."""
        listed = extract_listed_modules(readme_text())
        duplicates = sorted({name for name in listed if listed.count(name) > 1})
        self.assertEqual(
            duplicates, [], f"module(s) listed more than once in the roster: {duplicates}"
        )
        self.assertEqual(
            len(listed),
            extract_module_count(readme_text()),
            "the roster heading's number and the number of entries beneath it\n"
            "disagree, which is exactly the state the README shipped in on\n"
            "2026-08-08 (heading 17, entries 16).\n" + FIX_HINT,
        )


# ---------------------------------------------------------------------------
# Committed controls.  A check never observed failing is not trusted, so every
# check above has synthetic input here that makes it fire, and synthetic input
# that must leave it silent.  These are committed rather than run once by hand,
# so the guard cannot rot into decoration the way release.yml's version gate
# did (see tests/test_release_gate.py).
# ---------------------------------------------------------------------------

# A minimal stand-in for README.md carrying a correct roster AND the two shapes
# that a careless scanner trips on: a module named in a NEIGHBOURING section,
# and a module named inside the roster's own prose rather than as an entry.
SYNTHETIC_README = """\
# AutoPilot Leveler for Project Zomboid Build 42

## Core Runtime Modules (3 under `42/media/lua/client/`)

This roster is a guarded claim. Extracting a module such as AutoPilot_Rest.lua
means editing this section in the same commit.

Leveler:
- AutoPilot_Main.lua: orchestrator for the local player
- AutoPilot_UI.lua: F11 leveler panel

Learning and infrastructure:
- AutoPilot_Constants.lua: tunable thresholds and constants

## Versioning and Release Notes

- Current modversion: 0.2.1
3. `42/media/lua/client/AutoPilot_Constants.lua` -> `AutoPilot_Constants.VERSION = "X"`
- AutoPilot_Telemetry.lua: named here on purpose, OUTSIDE the roster section
"""

SYNTHETIC_MODULES = ["AutoPilot_Constants.lua", "AutoPilot_Main.lua", "AutoPilot_UI.lua"]


class TestScopingDoesNotFoolTheGuard(unittest.TestCase):
    """The reason the roster is read section-scoped, pinned as a test rather
    than a comment."""

    def test_only_roster_entries_are_collected(self) -> None:
        self.assertEqual(
            sorted(extract_listed_modules(SYNTHETIC_README)), SYNTHETIC_MODULES
        )

    def test_the_decoys_really_are_present_in_the_control(self) -> None:
        # Without this the control could pass by containing no decoys at all,
        # which would make the test above vacuous.
        self.assertIn(
            "- AutoPilot_Telemetry.lua: named here on purpose", SYNTHETIC_README
        )
        self.assertIn("such as AutoPilot_Rest.lua", SYNTHETIC_README)
        self.assertIn(
            "3. `42/media/lua/client/AutoPilot_Constants.lua`", SYNTHETIC_README
        )
        # ...and that each decoy is the shape it is meant to model: one entry
        # line after the section, one mid-prose mention inside it, one numbered
        # checklist line.  Asserting presence alone would not catch a decoy
        # that had been reworded into something the scanner never had trouble
        # with in the first place.
        section = extract_roster_section(SYNTHETIC_README)
        self.assertIn("AutoPilot_Rest.lua", section)
        self.assertNotIn("AutoPilot_Telemetry.lua", section)

    def test_the_real_readme_still_names_modules_outside_the_roster(self) -> None:
        # Ties the control to reality: if the real file stops naming modules
        # outside the section, this control is no longer modelling it.
        text = readme_text()
        outside = text.replace(extract_roster_section(text), "")
        self.assertIn("AutoPilot_Constants.lua", outside)


class TestEachCheckFiresOnDoctoredInput(unittest.TestCase):
    """The behaviour difference between a correct README and a stale one."""

    def test_a_dropped_module_is_caught(self) -> None:
        """The real drift: a module ships, the roster never hears about it."""
        stale = SYNTHETIC_README.replace(
            "- AutoPilot_UI.lua: F11 leveler panel\n", ""
        )
        self.assertNotEqual(stale, SYNTHETIC_README, "the perturbation did nothing")
        listed = extract_listed_modules(stale)
        self.assertNotIn("AutoPilot_UI.lua", listed)
        self.assertEqual(
            sorted(set(SYNTHETIC_MODULES) - set(listed)), ["AutoPilot_UI.lua"]
        )

    def test_a_module_listed_but_not_shipped_is_caught(self) -> None:
        """The other direction: a deletion the roster was never told about."""
        stale = SYNTHETIC_README.replace(
            "- AutoPilot_UI.lua: F11 leveler panel",
            "- AutoPilot_UI.lua: F11 leveler panel\n- AutoPilot_Barricade.lua: deleted in V5.0",
        )
        self.assertNotEqual(stale, SYNTHETIC_README, "the perturbation did nothing")
        listed = extract_listed_modules(stale)
        self.assertEqual(
            sorted(set(listed) - set(SYNTHETIC_MODULES)), ["AutoPilot_Barricade.lua"]
        )

    def test_a_stale_heading_count_is_caught(self) -> None:
        stale = SYNTHETIC_README.replace(
            "## Core Runtime Modules (3 under", "## Core Runtime Modules (17 under"
        )
        self.assertNotEqual(stale, SYNTHETIC_README, "the perturbation did nothing")
        self.assertEqual(extract_module_count(stale), 17)
        self.assertNotEqual(
            17,
            len(extract_listed_modules(stale)),
            "17 was chosen because it is the number the real README shipped "
            "while listing 16 modules; it must not accidentally be right here",
        )

    def test_the_count_and_the_list_disagreeing_is_caught(self) -> None:
        """The exact 2026-08-08 state: heading 17, entries 16, glob 24."""
        stale = SYNTHETIC_README.replace(
            "## Core Runtime Modules (3 under", "## Core Runtime Modules (2 under"
        ).replace("- AutoPilot_UI.lua: F11 leveler panel\n", "")
        self.assertNotEqual(stale, SYNTHETIC_README, "the perturbation did nothing")
        # Count and list now agree with each other (2 and 2) but BOTH are wrong
        # about the tree -- which is why the glob comparison is the load-bearing
        # assertion and the internal-consistency one is only a second net.
        self.assertEqual(extract_module_count(stale), 2)
        self.assertEqual(len(extract_listed_modules(stale)), 2)
        self.assertNotEqual(len(extract_listed_modules(stale)), len(SYNTHETIC_MODULES))


class TestTheGuardFailsLoudlyRatherThanSilently(unittest.TestCase):
    """Zero matches and duplicate matches are both hard failures."""

    def test_a_reworded_heading_raises_instead_of_passing(self) -> None:
        reworded = SYNTHETIC_README.replace(
            "## Core Runtime Modules (3 under `42/media/lua/client/`)",
            "## Modules",
        )
        self.assertNotIn("## Core Runtime Modules", reworded)
        with self.assertRaises(ReadmeAnchorError) as ctx:
            extract_module_count(reworded)
        self.assertIn("BLIND", str(ctx.exception))

    def test_a_reworded_heading_also_blinds_the_name_scan(self) -> None:
        """The name scan must not silently degrade to "no modules listed" when
        the heading it scopes itself by disappears -- an empty roster would
        otherwise compare cleanly against an empty expectation."""
        reworded = SYNTHETIC_README.replace(
            "## Core Runtime Modules (3 under `42/media/lua/client/`)",
            "## Modules",
        )
        with self.assertRaises(ReadmeAnchorError):
            extract_listed_modules(reworded)

    def test_a_second_live_home_for_the_heading_raises(self) -> None:
        duplicated = SYNTHETIC_README + (
            "\n## Core Runtime Modules (3 under `42/media/lua/client/`)\n"
        )
        with self.assertRaises(ReadmeAnchorError) as ctx:
            extract_module_count(duplicated)
        self.assertIn("AMBIGUOUS", str(ctx.exception))

    def test_a_second_home_raises_even_when_the_two_copies_agree(self) -> None:
        # Two copies that agree TODAY are exactly the state that drifts
        # tomorrow with the guard still green.
        duplicated = SYNTHETIC_README.replace(
            "## Versioning and Release Notes",
            "## Core Runtime Modules (3 under `42/media/lua/client/`)\n\n"
            "## Versioning and Release Notes",
        )
        self.assertNotEqual(duplicated, SYNTHETIC_README, "the perturbation did nothing")
        with self.assertRaises(ReadmeAnchorError):
            extract_module_count(duplicated)


if __name__ == "__main__":
    unittest.main()
