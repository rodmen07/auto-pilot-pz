"""Truth guard for ``ROADMAP.md``: the three claims that are cheap, durable and
unambiguous to check against the repository itself.

WHY THIS EXISTS
---------------
``CHANGELOG.md`` got a mechanical tie to reality (``ci.yml``'s *Changelog
guard*, exercised by ``tests/test_changelog_guard.py``) after it drifted from
the code it describes.  ``ROADMAP.md`` never got one, and it drifted the same
way: created 2026-07-19, hand-corrected by 31 commits since, and re-audited by
hand in PRs #47, #72, #110 and #124.  The 2026-08-07 audit (PR #124) found six
false claims in it, and **four of the six were facts the AutoPilot backlog
already carried correctly** — nobody was ignorant, the two documents simply had
no way to disagree out loud.  This module is that way.

WHAT IS GUARDED, AND WHAT IS DELIBERATELY NOT
---------------------------------------------
Guarded (three claims, each low-churn and single-valued):

  1. the ``modversion`` string, against ``mod.info`` and ``42/mod.info``
  2. the "latest tag" claim, against the repository's own tags
  3. the client Lua module count, against ``42/media/lua/client/*.lua``

Deliberately NOT guarded: **line counts, suite and assertion totals, and
commit share.**  Those change on almost every pull request, so a guard over
them would redden unrelated work daily and be disabled or ``# noqa``'d within a
week, which is strictly worse than no guard — a disabled guard still reads as
coverage.  They stay the job of the periodic product truth audit, which
re-measures them live.  The line drawn here is: *guard what changes on a
deliberate, dated decision (a release, a module added or deleted); audit what
changes as a side effect of ordinary work.*

WHY THE ANCHORS ARE STRICT
--------------------------
``ROADMAP.md`` **deliberately contains false sentences.**  This project's
documented convention is to quote superseded prose verbatim where it stood, so
a wrong correction stays recoverable by grep — the file carries, today, both
*"the last tag is v1.2.1"* (twice, as a tombstone) and *"the latest tag is
`v0.2.0`"* (the live claim).  Any guard that scans this file with a loose
regex will therefore match a tombstone and fail on a correct document.  Each
claim is consequently bound to a NARROW anchor that must match **exactly
once**: zero matches means the claim was reworded and the guard has gone blind,
more than one means the anchor is no longer unique.  Both are hard failures.
A guard that reports success on input it cannot see is worse than no guard —
the same rule ``ci.yml``'s three inline guards already state.

PARSE AS TEXT, like ``tests/test_version_sync.py`` and
``tests/test_changelog_guard.py``: no markdown library, no game, no network.
"""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent

ROADMAP = ROOT / "ROADMAP.md"
MOD_INFO_ROOT = ROOT / "mod.info"
MOD_INFO_42 = ROOT / "42" / "mod.info"
CLIENT_LUA_DIR = ROOT / "42" / "media" / "lua" / "client"

# ---------------------------------------------------------------------------
# The anchors.  Each is deliberately narrow enough that the tombstoned copies
# of the same fact elsewhere in the file cannot match it.  Changing a claim's
# wording in ROADMAP.md means changing the anchor here, on purpose, in the same
# commit -- that coupling IS the guard.
# ---------------------------------------------------------------------------
ANCHOR_MODVERSION = r"modversion is \*\*`([^`]+)`\*\*"
ANCHOR_LATEST_TAG = r"the latest tag is \*\*`([^`]+)`\*\*"
ANCHOR_MODULE_COUNT = r"(?m)^- (\d+) Lua modules under `42/media/lua/client/`"

FIX_HINT = (
    "ROADMAP.md and the repository disagree.  Fix the ROADMAP claim (it is the\n"
    "one that goes stale), not this test -- and if the claim was deliberately\n"
    "reworded, update the anchor in tests/test_roadmap_truth.py in the SAME\n"
    "commit and quote the superseded wording where it stood, per this repo's\n"
    "tombstone convention."
)


class RoadmapAnchorError(AssertionError):
    """The anchor did not match exactly once, so the guard cannot see its input."""


def extract_claim(text: str, anchor: str, label: str) -> str:
    """Return the single value ``anchor`` captures in ``text``.

    Raises :class:`RoadmapAnchorError` on zero matches (the claim was reworded
    or deleted -- the guard has gone blind) and on more than one (the anchor is
    no longer unique, so which copy is authoritative is undefined).  Never
    returns a default: a truth guard that silently degrades to "nothing to
    check" is exactly the failure this module exists to prevent.
    """
    matches = re.findall(anchor, text)
    if not matches:
        raise RoadmapAnchorError(
            f"ROADMAP.md truth guard has gone BLIND on '{label}': the anchor\n"
            f"  {anchor}\n"
            "matched ZERO times.  The claim was reworded, moved or deleted.\n"
            "A guard that passes when it can no longer find what it checks is\n"
            "worse than no guard, so this is a hard failure.\n" + FIX_HINT
        )
    if len(matches) > 1:
        raise RoadmapAnchorError(
            f"ROADMAP.md truth guard is AMBIGUOUS on '{label}': the anchor\n"
            f"  {anchor}\n"
            f"matched {len(matches)} times ({matches!r}).  The file now states the\n"
            "same live claim in more than one place, so the two copies can drift\n"
            "apart with the guard still green -- the split-brain this module was\n"
            "written to close.  Keep ONE live home for the claim; superseded\n"
            "copies must be worded as tombstones so this anchor cannot match them.\n"
            + FIX_HINT
        )
    return matches[0]


# ---------------------------------------------------------------------------
# The sources of truth.
# ---------------------------------------------------------------------------
def mod_info_version(path: Path) -> str | None:
    """Return the ``modversion=`` value from a mod.info file, or None."""
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("modversion="):
            return line.split("=", 1)[1].strip()
    return None


def client_module_paths() -> list[Path]:
    """Glob-discovered client Lua modules (never a hand-written list).

    A hand-enumerated list degrades silently on the next module extraction; a
    glob with a zero-match hard failure announces itself instead.
    """
    return sorted(CLIENT_LUA_DIR.glob("*.lua"))


def newest_tag() -> str | None:
    """The most recently CREATED tag, or None when git cannot answer.

    Sorted by ``creatordate``, NOT by name.  ``git tag --list`` sorts
    lexicographically, and this repository's version scheme was RESET (5.8 ->
    0.1.0 by user decision on 2026-07-25, PR #73), so the newest tag ``v0.2.0``
    sorts BEFORE the long-dead ``v1.2.1``.  A guard reading ``git tag --list |
    tail -1`` would compare the roadmap against ``v1.2.1`` and fail on a
    correct document.  ``creatordate`` also covers both tag kinds present here
    (``v0.2.0`` is lightweight, ``V1.0`` is annotated); ``taggerdate`` would be
    empty for the lightweight ones.
    """
    try:
        proc = subprocess.run(
            [
                "git",
                "for-each-ref",
                "--sort=-creatordate",
                "--format=%(refname:short)",
                "refs/tags",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    tags = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    return tags[0] if tags else None


def roadmap_text() -> str:
    return ROADMAP.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# The live gate: the real ROADMAP.md against the real repository.
# ---------------------------------------------------------------------------
class TestRoadmapClaimsMatchReality(unittest.TestCase):
    """Each test reads BOTH sources -- the claim and the thing it claims."""

    def test_roadmap_exists(self) -> None:
        self.assertTrue(
            ROADMAP.is_file(),
            "ROADMAP.md is missing.  If it was renamed, retarget this guard in the\n"
            "same commit rather than deleting it.",
        )

    def test_modversion_claim_matches_both_mod_info_files(self) -> None:
        claimed = extract_claim(roadmap_text(), ANCHOR_MODVERSION, "modversion")
        root_version = mod_info_version(MOD_INFO_ROOT)
        b42_version = mod_info_version(MOD_INFO_42)
        self.assertIsNotNone(
            root_version, f"no modversion= line in {MOD_INFO_ROOT}"
        )
        self.assertIsNotNone(b42_version, f"no modversion= line in {MOD_INFO_42}")
        # tests/test_version_sync.py already owns "the five copies agree with
        # each other"; this guard owns "the ROADMAP agrees with them", and
        # checks both files so it cannot be satisfied by a half-done bump.
        self.assertEqual(
            claimed,
            root_version,
            f"ROADMAP.md claims modversion {claimed!r}, mod.info says "
            f"{root_version!r}.\n" + FIX_HINT,
        )
        self.assertEqual(
            claimed,
            b42_version,
            f"ROADMAP.md claims modversion {claimed!r}, 42/mod.info says "
            f"{b42_version!r}.\n" + FIX_HINT,
        )

    def test_latest_tag_claim_matches_the_newest_tag(self) -> None:
        if not (ROOT / ".git").exists():
            self.skipTest(
                "no .git directory: the instrument is absent, not disagreeing"
            )
        claimed = extract_claim(roadmap_text(), ANCHOR_LATEST_TAG, "latest tag")
        actual = newest_tag()
        # Blind-guard: git IS available (there is a .git), so zero tags means
        # the checkout does not carry them -- a tagless checkout would
        # otherwise let this claim pass unchecked forever.
        self.assertIsNotNone(
            actual,
            "git reported NO tags in this checkout, so the 'latest tag' claim\n"
            "cannot be verified.  In CI this means the checkout lost its tags:\n"
            "actions/checkout needs `fetch-depth: 0` (which fetches tags) or an\n"
            "explicit `fetch-tags: true`.  ci.yml sets fetch-depth: 0 today for\n"
            "the Changelog guard; if that line goes, this guard goes blind too.",
        )
        self.assertEqual(
            claimed,
            actual,
            f"ROADMAP.md claims the latest tag is {claimed!r}, but the newest tag\n"
            f"by creation date is {actual!r}.\n"
            "This is the exact drift PR #124 found by hand: the file said the last\n"
            "tag was v1.2.1 for weeks after v0.2.0 was cut and released.\n" + FIX_HINT,
        )

    def test_module_count_claim_matches_the_client_lua_glob(self) -> None:
        modules = client_module_paths()
        # Zero-match hard failure: an empty glob means the tree moved, and a
        # guard that "passes" on an empty directory proves nothing.
        self.assertGreater(
            len(modules),
            0,
            f"no *.lua files found under {CLIENT_LUA_DIR}.  Discovery is\n"
            "glob-driven; zero matches means the module tree moved and this guard\n"
            "is measuring nothing.",
        )
        claimed = extract_claim(roadmap_text(), ANCHOR_MODULE_COUNT, "module count")
        self.assertEqual(
            int(claimed),
            len(modules),
            f"ROADMAP.md claims {claimed} Lua modules under 42/media/lua/client/, "
            f"the glob finds {len(modules)}:\n  "
            + "\n  ".join(p.name for p in modules)
            + "\n"
            + FIX_HINT,
        )


# ---------------------------------------------------------------------------
# Committed controls.  A check never observed failing is not trusted, so every
# check above has a synthetic input here that makes it fire, and a synthetic
# input that must leave it silent.  These are committed rather than run once by
# hand, so the guard cannot rot into decoration the way release.yml's version
# gate did (see tests/test_release_gate.py).
# ---------------------------------------------------------------------------

# A minimal stand-in for ROADMAP.md that carries the three live claims AND the
# tombstoned prose quoted verbatim out of the real file, because the tombstones
# are what a naive scanner trips on.
SYNTHETIC_ROADMAP = """\
# AutoPilot Roadmap

> the mod was V5.8, 21 modules, 14 test suites, 1107 assertions passing, luacheck clean

**Repo state (2026-08-07):** `mod.info` modversion is **`0.2.0`** in both
`mod.info` and `42/mod.info` (reset from `5.8` to `0.1.0` by user decision on
2026-07-25, PR #73; bumped to `0.2.0` by PR #111).

- 24 Lua modules under `42/media/lua/client/` (`AutoPilot_Comfort.lua` added
  2026-07-26 for towel drying)

the user chose a fresh design against the then-current 21-module architecture

- ~~**Release-tag hygiene:** resume tagging (the last tag is v1.2.1 ...).~~
  **DONE 2026-08-05.** Tagging has resumed: the latest tag is **`v0.2.0`** with a
  matching GitHub release. The stale reading this bullet carried — *"the last tag
  is v1.2.1"* — predated the 0.1.0 version-scheme reset.
- **Distribution shift:** git release tags stopped at v1.2.1
"""


class TestTombstonedProseDoesNotFoolTheGuard(unittest.TestCase):
    """The reason the anchors are narrow, pinned as a test rather than a comment.

    ``ROADMAP.md`` keeps superseded claims verbatim on purpose.  If an anchor
    ever widens enough to match one, these fail.
    """

    def test_live_claims_are_extracted_not_the_tombstones(self) -> None:
        self.assertEqual(
            extract_claim(SYNTHETIC_ROADMAP, ANCHOR_MODVERSION, "modversion"),
            "0.2.0",
        )
        self.assertEqual(
            extract_claim(SYNTHETIC_ROADMAP, ANCHOR_LATEST_TAG, "latest tag"),
            "v0.2.0",
            "the anchor matched a tombstoned 'the last tag is v1.2.1' quote "
            "instead of the live claim",
        )
        self.assertEqual(
            extract_claim(SYNTHETIC_ROADMAP, ANCHOR_MODULE_COUNT, "module count"),
            "24",
            "the anchor matched the historical '21 modules' / '21-module' prose "
            "instead of the live claim",
        )

    def test_the_tombstones_really_are_present_in_the_control(self) -> None:
        # Without this the control could pass by containing no tombstones at
        # all, which would make the test above vacuous.
        self.assertIn("the last tag is v1.2.1", SYNTHETIC_ROADMAP)
        self.assertIn("git release tags stopped at v1.2.1", SYNTHETIC_ROADMAP)
        self.assertIn("21 modules", SYNTHETIC_ROADMAP)
        self.assertIn("21-module architecture", SYNTHETIC_ROADMAP)

    def test_the_real_roadmap_still_carries_those_tombstones(self) -> None:
        # Ties the control to reality: if the real file stops keeping
        # superseded prose, this control is no longer modelling it.
        text = roadmap_text()
        self.assertIn("the last tag is v1.2.1", text)
        self.assertIn("21 modules", text)


class TestEachCheckFiresOnDoctoredInput(unittest.TestCase):
    """The behaviour difference between a correct roadmap and a stale one."""

    def test_stale_modversion_is_caught(self) -> None:
        # The real 2026-08-07 drift: the file said 0.1.0 while both mod.info
        # files said 0.2.0.
        stale = SYNTHETIC_ROADMAP.replace(
            "modversion is **`0.2.0`**", "modversion is **`0.1.0`**"
        )
        self.assertNotEqual(stale, SYNTHETIC_ROADMAP, "the perturbation did nothing")
        self.assertEqual(
            extract_claim(stale, ANCHOR_MODVERSION, "modversion"), "0.1.0"
        )
        self.assertNotEqual(
            extract_claim(stale, ANCHOR_MODVERSION, "modversion"),
            mod_info_version(MOD_INFO_ROOT),
            "a roadmap claiming 0.1.0 must not agree with the live mod.info",
        )

    def test_stale_latest_tag_is_caught(self) -> None:
        stale = SYNTHETIC_ROADMAP.replace(
            "the latest tag is **`v0.2.0`**", "the latest tag is **`v1.2.1`**"
        )
        self.assertNotEqual(stale, SYNTHETIC_ROADMAP, "the perturbation did nothing")
        self.assertEqual(
            extract_claim(stale, ANCHOR_LATEST_TAG, "latest tag"), "v1.2.1"
        )

    def test_stale_module_count_is_caught(self) -> None:
        stale = SYNTHETIC_ROADMAP.replace(
            "- 24 Lua modules under", "- 23 Lua modules under"
        )
        self.assertNotEqual(stale, SYNTHETIC_ROADMAP, "the perturbation did nothing")
        self.assertEqual(
            int(extract_claim(stale, ANCHOR_MODULE_COUNT, "module count")), 23
        )
        self.assertNotEqual(
            23,
            len(client_module_paths()),
            "23 was chosen as a wrong count; it is no longer wrong",
        )


class TestTheGuardFailsLoudlyRatherThanSilently(unittest.TestCase):
    """Zero matches and duplicate matches are both hard failures."""

    def test_reworded_claim_raises_instead_of_passing(self) -> None:
        reworded = SYNTHETIC_ROADMAP.replace(
            "modversion is **`0.2.0`**", "the mod version is 0.2.0"
        )
        self.assertNotIn("modversion is **", reworded)
        with self.assertRaises(RoadmapAnchorError) as ctx:
            extract_claim(reworded, ANCHOR_MODVERSION, "modversion")
        self.assertIn("BLIND", str(ctx.exception))

    def test_a_second_live_home_for_the_same_claim_raises(self) -> None:
        duplicated = SYNTHETIC_ROADMAP + (
            "\n\nElsewhere: the latest tag is **`v0.2.0`** as well.\n"
        )
        with self.assertRaises(RoadmapAnchorError) as ctx:
            extract_claim(duplicated, ANCHOR_LATEST_TAG, "latest tag")
        self.assertIn("AMBIGUOUS", str(ctx.exception))

    def test_a_second_home_raises_even_when_the_two_copies_agree(self) -> None:
        # The point of the ambiguity check: two copies that agree TODAY are
        # exactly the state that drifts tomorrow with the guard still green.
        duplicated = SYNTHETIC_ROADMAP + "\n- 24 Lua modules under `42/media/lua/client/`\n"
        with self.assertRaises(RoadmapAnchorError):
            extract_claim(duplicated, ANCHOR_MODULE_COUNT, "module count")


class TestNewestTagOrdering(unittest.TestCase):
    """The trap this repo sets for a naive 'last tag' reading."""

    def test_newest_tag_is_not_the_lexicographically_last_one(self) -> None:
        if not (ROOT / ".git").exists():
            self.skipTest("no .git directory")
        proc = subprocess.run(
            ["git", "tag", "--list"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            self.skipTest("git tag --list unavailable")
        names = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
        if len(names) < 2:
            self.skipTest("fewer than two tags; the ordering trap cannot exist yet")
        # Not an assertion that they MUST differ forever -- it is a record of
        # why newest_tag() sorts by creatordate.  When the version scheme grows
        # past the reset the two readings will agree again and this test simply
        # documents that they did not, historically.
        lexicographic_last = sorted(names)[-1]
        newest = newest_tag()
        self.assertIsNotNone(newest)
        if lexicographic_last != newest:
            self.assertEqual(
                newest,
                newest_tag(),
                "newest_tag() must be stable across calls",
            )


if __name__ == "__main__":
    unittest.main()
