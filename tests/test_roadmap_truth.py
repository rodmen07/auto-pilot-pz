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
Guarded (four claims, each low-churn and single-valued):

  1. the ``modversion`` string, against ``mod.info`` and ``42/mod.info``
  2. the "latest tag" claim, against the repository's own tags
  3. the client Lua module count, against ``42/media/lua/client/*.lua``
  4. the Lua TEST-SUITE count, against ``tests/test_*.lua`` (added 2026-08-08)

Claim 2 is NOT a plain equality: see :func:`classify_tag_claim`.  It was one
for about five hours on 2026-08-08, and the first release cut that followed
found that a plain equality makes a release impossible to cut without a red
run -- the roadmap has to name the tag in the commit the tag will later point
at, so there is unavoidably a window where the claim is ahead of reality.  The
guard now allows exactly that window and nothing else, and the exemption is
forward-only so it cannot be entered by moving backwards.

Deliberately NOT guarded: **line counts, the assertion total, and commit
share.**  Those change on almost every pull request, so a guard over them would
redden unrelated work daily and be disabled or ``# noqa``'d within a week,
which is strictly worse than no guard — a disabled guard still reads as
coverage.  They stay the job of the periodic product truth audit, which
re-measures them live.  The line drawn here is: *guard what changes on a
deliberate, dated decision (a release, a module added or deleted); audit what
changes as a side effect of ordinary work.*

THE SUITE COUNT MOVED ACROSS THAT LINE ON 2026-08-08, and the superseded
wording of this paragraph is quoted here because the change is a NARROWING of
the exclusion, not a reversal of its reasoning: *"Deliberately NOT guarded:
line counts, suite and assertion totals, and commit share."*  Claim 4 is the
suite count only; the assertion total stays out, and the two were separated on
measured evidence rather than taste.  Over the ten commits merged after PR #127
(``6377aa4..fbb0170``), every one of the four that changed the suite count
corrected ``ROADMAP.md`` in the SAME commit — #130 (39→40), #132 (40→41),
#133 (41→42), #137 (42→43) — while the one commit that moved the assertion
total without adding a file, #129, did not.  The asymmetry is structural and
not a discipline gap: a pull request that adds ``tests/test_foo.lua`` can SEE
that it changed the suite count, and a pull request that adds three assertions
to an existing suite cannot see that it moved a sum over all 43 suites without
re-measuring the whole tree.  A guard on the first reddens only the author who
is already responsible; a guard on the second would redden authors who had no
way to know, which is exactly the failure mode this paragraph was written to
avoid.  The decision, its table and its counterexample live under *"Figure
maintenance"* in ``ROADMAP.md``'s "Current state" section.

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
LUA_TEST_DIR = ROOT / "tests"

# ---------------------------------------------------------------------------
# The anchors.  Each is deliberately narrow enough that the tombstoned copies
# of the same fact elsewhere in the file cannot match it.  Changing a claim's
# wording in ROADMAP.md means changing the anchor here, on purpose, in the same
# commit -- that coupling IS the guard.
# ---------------------------------------------------------------------------
ANCHOR_MODVERSION = r"modversion is \*\*`([^`]+)`\*\*"
ANCHOR_LATEST_TAG = r"the latest tag is \*\*`([^`]+)`\*\*"
ANCHOR_MODULE_COUNT = r"(?m)^- (\d+) Lua modules under `42/media/lua/client/`"

# The suite-count claim sits mid-line inside the same bullet as the module
# count, so it cannot be line-anchored the way ANCHOR_MODULE_COUNT is.  What
# separates the live claim from its five tombstoned predecessors -- all of them
# on that one 10 kB line, all bolded identically -- is the quoting convention
# this repository uses for superseded prose: a tombstone is wrapped in `*"` ...
# `"*`, and the live claim is not.  The negative lookbehind is therefore a
# structural read of the tombstone marker, not a guess about wording, and the
# exactly-once rule in extract_claim() is what catches the day it stops being
# true: a sixth tombstone written with different quoting makes this AMBIGUOUS
# and hard-fails, rather than silently binding the guard to a dead figure.
# TestTombstonedProseDoesNotFoolTheGuard pins all five real tombstones as a
# committed control so this cannot rot into a comment.
ANCHOR_SUITE_COUNT = r"(?<!\*\")\*\*(\d+) Lua test suites, \d+ assertions, 0 failures\*\*"

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


def lua_suite_paths() -> list[Path]:
    """Glob-discovered Lua test suites -- the same rule as the module glob.

    One file is one suite: this is exactly what ``check.sh`` runs and what the
    roadmap's "N Lua test suites" figure counts.  Discovery is a glob with a
    zero-match hard failure at the call site, never a hand list, so a suite
    added by a future split is counted the moment it lands rather than the day
    somebody remembers to extend an array.
    """
    return sorted(LUA_TEST_DIR.glob("test_*.lua"))


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
    tags = all_tags()
    return tags[0] if tags else None


def all_tags() -> list[str] | None:
    """Every tag in this checkout, most recently CREATED first, or None.

    ``None`` means *git could not answer* (no git binary, not a repository);
    ``[]`` means *git answered and there are no tags*.  The two are different
    and the caller treats them differently: the first is an absent instrument,
    the second is a checkout that lost its tags, which must never pass.
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
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def version_tuple(tag: str) -> tuple[int, ...] | None:
    """Parse a version tag into a comparable integer tuple, or None.

    ``v0.2.1`` -> ``(0, 2, 1)``; ``V1.0`` -> ``(1, 0, 0)``; ``v0.1.0-beta1``
    -> ``(0, 1, 0)``.  Returns ``None`` for anything that is not a dotted
    numeric version, so an unparseable tag can never be silently ordered.
    """
    body = tag[1:] if tag[:1] in ("v", "V") else tag
    body = body.split("-", 1)[0].split("+", 1)[0]
    parts = body.split(".")
    if not parts or not all(part.isdigit() for part in parts):
        return None
    nums = tuple(int(part) for part in parts)
    return nums + (0,) * (3 - len(nums)) if len(nums) < 3 else nums


# The three verdicts the latest-tag claim can carry.  Only STALE fails.
CLAIM_CURRENT = "current"
CLAIM_IN_FLIGHT = "in-flight"
CLAIM_STALE = "stale"


def classify_tag_claim(
    claimed: str,
    newest: str,
    existing_tags: list[str],
    modversion: str,
) -> tuple[str, str]:
    """Judge the roadmap's latest-tag claim.  Returns ``(verdict, detail)``.

    WHY THIS IS NOT A PLAIN EQUALITY ANY MORE
    -----------------------------------------
    It was one, from 2026-08-08 until the first release cut that followed --
    about five hours -- and a plain equality makes cutting a release
    IMPOSSIBLE without a red run.  Both horns were observed, not reasoned
    about, before this function was written:

      * Claim the new tag in the prep pull request, before it exists, and the
        pull request is red (``'v0.2.1' != 'v0.2.0'``), so it cannot merge.
      * Leave the claim at the old tag, merge, then push the new tag, and
        ``release.yml``'s CI gate -- which runs ``this suite`` on the tagged
        tree -- is red the other way (``'v0.2.0' != 'v0.2.1'``).  That job is
        ``needs:`` of the packaging job, so **no release artifact is ever
        built**.

    The tag must therefore be named by the commit it will later point at, and
    the guard has to tolerate exactly that one window and nothing else.

    WHAT IS STILL GUARDED (the exemption is deliberately narrow, and FORWARD
    ONLY, so it cannot be walked into as a bypass)
    ----------------------------------------------------------------------
    A claim that differs from the newest tag is accepted ONLY when all three
    hold, each of them checkable and none of them a matter of opinion:

      1. it names exactly ``v<modversion>`` -- the version this tree is
         actually prepped for, which ``test_modversion_claim_matches_both_mod_
         info_files`` already binds to both ``mod.info`` files and
         ``tests/test_version_sync.py`` binds to the Lua constant and README;
      2. that tag does NOT exist yet, so "in flight" cannot be claimed about a
         tag that has already been cut;
      3. it is strictly NEWER than the newest existing tag.  Without this the
         exemption could be entered by moving BACKWARDS -- bump ``mod.info``
         down and any older version name would satisfy (1) and (2) -- which is
         how a narrow exemption turns into a loophole.

    The incident that motivated the guard is still caught: the roadmap said
    ``v1.2.1`` while ``mod.info`` said ``0.2.0`` and the newest tag was
    ``v0.2.0``.  That fails (1), so it is STALE, exactly as before.
    """
    if claimed == newest:
        return CLAIM_CURRENT, f"the claim names the newest tag ({newest!r})."

    expected = f"v{modversion}"
    if claimed != expected:
        return CLAIM_STALE, (
            f"ROADMAP.md claims the latest tag is {claimed!r}, but the newest tag\n"
            f"by creation date is {newest!r} and this tree is prepped for\n"
            f"modversion {modversion!r} (which would be tagged {expected!r}).\n"
            "The claim names neither, so it is simply stale.\n"
            "This is the exact drift PR #124 found by hand: the file said the last\n"
            "tag was v1.2.1 for weeks after v0.2.0 was cut and released."
        )

    if claimed in existing_tags:
        return CLAIM_STALE, (
            f"ROADMAP.md claims the latest tag is {claimed!r} and that tag DOES\n"
            f"exist, but the newest tag by creation date is {newest!r}.  The\n"
            "release-in-flight exemption is only for a tag that has not been cut\n"
            "yet; a tag that exists but is not the newest means the claim has\n"
            "fallen behind a later cut."
        )

    claimed_version = version_tuple(claimed)
    newest_version = version_tuple(newest)
    if claimed_version is None or newest_version is None:
        return CLAIM_STALE, (
            f"cannot order {claimed!r} against {newest!r}: one of them is not a\n"
            "dotted numeric version, so the release-in-flight exemption cannot be\n"
            "granted (it is forward-only, and 'forward' has to be computable)."
        )
    if claimed_version <= newest_version:
        return CLAIM_STALE, (
            f"ROADMAP.md claims the latest tag is {claimed!r}, which is not NEWER\n"
            f"than the newest existing tag {newest!r}.  The release-in-flight\n"
            "exemption is forward-only on purpose: were it not, bumping mod.info\n"
            "backwards would let any older version name satisfy the guard."
        )

    return CLAIM_IN_FLIGHT, (
        f"release in flight: this tree is prepped for modversion {modversion!r},\n"
        f"the claim names {claimed!r} accordingly, that tag does not exist yet,\n"
        f"and it is newer than {newest!r}."
    )


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
        tags = all_tags()
        # Blind-guard: git IS available (there is a .git), so zero tags means
        # the checkout does not carry them -- a tagless checkout would
        # otherwise let this claim pass unchecked forever.
        self.assertTrue(
            tags,
            "git reported NO tags in this checkout, so the 'latest tag' claim\n"
            "cannot be verified.  In CI this means the checkout lost its tags:\n"
            "actions/checkout needs `fetch-depth: 0` (which fetches tags) or an\n"
            "explicit `fetch-tags: true`.  ci.yml sets fetch-depth: 0 today for\n"
            "the Changelog guard; if that line goes, this guard goes blind too.",
        )
        assert tags is not None  # narrowing for type checkers
        modversion = mod_info_version(MOD_INFO_ROOT)
        self.assertIsNotNone(
            modversion,
            f"no modversion= line in {MOD_INFO_ROOT}; the latest-tag claim is\n"
            "judged against the version this tree is prepped for, so it cannot\n"
            "be judged at all without one.",
        )
        assert modversion is not None  # narrowing for type checkers

        verdict, detail = classify_tag_claim(claimed, tags[0], tags, modversion)
        self.assertNotEqual(verdict, CLAIM_STALE, detail + "\n" + FIX_HINT)

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

    def test_suite_count_claim_matches_the_lua_test_glob(self) -> None:
        """Claim 4, added 2026-08-08 by the figure-maintenance decision.

        The suite count is glob-derived, so the pull request that moves it can
        see that it moved it -- which is why this is guarded and the assertion
        total stated in the same sentence is not.  See the module docstring.
        """
        suites = lua_suite_paths()
        # Zero-match hard failure, same rule as the module glob: a guard that
        # "passes" because it found no suites at all is measuring nothing.
        self.assertGreater(
            len(suites),
            0,
            f"no test_*.lua files found under {LUA_TEST_DIR}.  Discovery is\n"
            "glob-driven; zero matches means the test tree moved and this guard\n"
            "is measuring nothing.",
        )
        claimed = extract_claim(roadmap_text(), ANCHOR_SUITE_COUNT, "suite count")
        self.assertEqual(
            int(claimed),
            len(suites),
            f"ROADMAP.md claims {claimed} Lua test suites, the tests/test_*.lua "
            f"glob finds {len(suites)}:\n  "
            + "\n  ".join(p.name for p in suites)
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

# The five superseded suite-count figures, quoted VERBATIM out of the real
# ROADMAP.md, wrapping marker included.  These are the exact strings the live
# anchor must refuse: they are bolded identically to the live claim, they sit
# on the same physical line, and a loose regex matches all six.  Pinned as data
# rather than described in a comment so a widened anchor fails a test instead of
# passing a review.
SUPERSEDED_SUITE_FIGURES = (
    '*"**42 Lua test suites, 1913 assertions, 0 failures**"*',
    '*"**41 Lua test suites, 1813 assertions, 0 failures**"*',
    '*"**40 Lua test suites, 1785 assertions, 0 failures**"*',
    '*"**39 Lua test suites, 1777 assertions, 0 failures**"*',
    '*"**37 Lua test suites, 1777 assertions, 0 failures**',
)

# A minimal stand-in for ROADMAP.md that carries the four live claims AND the
# tombstoned prose quoted verbatim out of the real file, because the tombstones
# are what a naive scanner trips on.
SYNTHETIC_ROADMAP = """\
# AutoPilot Roadmap

> the mod was V5.8, 21 modules, 14 test suites, 1107 assertions passing, luacheck clean

**Repo state (2026-08-07):** `mod.info` modversion is **`0.2.0`** in both
`mod.info` and `42/mod.info` (reset from `5.8` to `0.1.0` by user decision on
2026-07-25, PR #73; bumped to `0.2.0` by PR #111).

- 24 Lua modules under `42/media/lua/client/` (`AutoPilot_Comfort.lua` added
  2026-07-26 for towel drying); **43 Lua test suites, 2000 assertions, 0 failures**
  (both figures re-measured live 2026-08-08; superseded wording, quoted where it
  stood: *"**42 Lua test suites, 1913 assertions, 0 failures**"*.  The earlier
  note is kept for the record: *"**41 Lua test suites, 1813 assertions, 0 failures**"*,
  and before that *"**40 Lua test suites, 1785 assertions, 0 failures**"*, and
  *"**39 Lua test suites, 1777 assertions, 0 failures**"*, and
  *"**37 Lua test suites, 1777 assertions, 0 failures** (re-measured live 2026-08-07)"*.)

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
        self.assertEqual(
            extract_claim(SYNTHETIC_ROADMAP, ANCHOR_SUITE_COUNT, "suite count"),
            "43",
            "the anchor matched one of the five tombstoned suite-count figures "
            "(42/41/40/39/37) instead of the live claim",
        )

    def test_the_tombstones_really_are_present_in_the_control(self) -> None:
        # Without this the control could pass by containing no tombstones at
        # all, which would make the test above vacuous.
        self.assertIn("the last tag is v1.2.1", SYNTHETIC_ROADMAP)
        self.assertIn("git release tags stopped at v1.2.1", SYNTHETIC_ROADMAP)
        self.assertIn("21 modules", SYNTHETIC_ROADMAP)
        self.assertIn("21-module architecture", SYNTHETIC_ROADMAP)
        for superseded in SUPERSEDED_SUITE_FIGURES:
            self.assertIn(superseded, SYNTHETIC_ROADMAP)
        # ...and the loose form a naive scanner would use really does match all
        # six, so "the narrow anchor found one" is a fact about the anchor
        # rather than a fact about the input.
        self.assertEqual(
            len(re.findall(r"(\d+) Lua test suites", SYNTHETIC_ROADMAP)),
            6,
            "the control is meant to carry one live suite-count claim plus five "
            "tombstones; if it does not, the anchor test above proves nothing",
        )

    def test_the_real_roadmap_still_carries_those_tombstones(self) -> None:
        # Ties the control to reality: if the real file stops keeping
        # superseded prose, this control is no longer modelling it.
        text = roadmap_text()
        self.assertIn("the last tag is v1.2.1", text)
        self.assertIn("21 modules", text)
        for superseded in SUPERSEDED_SUITE_FIGURES:
            self.assertIn(
                superseded,
                text,
                "the real ROADMAP.md no longer carries this tombstoned "
                "suite-count figure, so the control above has stopped modelling "
                "it.  Update SUPERSEDED_SUITE_FIGURES in the same commit that "
                "removed it, rather than deleting this assertion.",
            )


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

    def test_stale_suite_count_is_caught(self) -> None:
        """Claim 4 fires on a wrong number -- the ON half of the decision."""
        live = len(lua_suite_paths())
        stale = SYNTHETIC_ROADMAP.replace(
            "**43 Lua test suites,", f"**{live + 1} Lua test suites,"
        )
        self.assertNotEqual(stale, SYNTHETIC_ROADMAP, "the perturbation did nothing")
        self.assertEqual(
            int(extract_claim(stale, ANCHOR_SUITE_COUNT, "suite count")), live + 1
        )
        self.assertNotEqual(
            live + 1,
            live,
            "the doctored count must differ from the glob, or this proves nothing",
        )

    def test_an_assertion_total_change_does_not_redden_this_guard(self) -> None:
        """Claim 4 stays silent when the UNGUARDED figure moves.

        This is the 2026-08-08 figure-maintenance decision expressed as a
        behaviour difference rather than as prose, and it runs against the REAL
        ``ROADMAP.md`` rather than the synthetic one, because the boundary only
        means something on the document people actually edit: a pull request
        that adds assertions to an existing suite must not go red here, and a
        pull request that adds a suite file must.  If this test ever has to be
        deleted to make a build pass, the decision has been reversed and the
        docstring above it is the thing to correct.
        """
        text = roadmap_text()
        suites = extract_claim(text, ANCHOR_SUITE_COUNT, "suite count")
        live = re.search(
            r"(?<!\*\")\*\*" + suites + r" Lua test suites, (\d+) assertions, 0 failures\*\*",
            text,
        )
        self.assertIsNotNone(live, "the live suite/assertion sentence moved")
        assert live is not None  # narrowing, for the type checker
        moved_total = str(int(live.group(1)) + 7)
        moved = text[: live.start(1)] + moved_total + text[live.end(1) :]
        self.assertNotEqual(moved, text, "the perturbation did nothing")
        self.assertEqual(
            int(extract_claim(moved, ANCHOR_SUITE_COUNT, "suite count")),
            len(lua_suite_paths()),
            "moving the assertion total reddened the suite-count guard.  Those\n"
            "two figures share a sentence but not an owner: the suite count is\n"
            "guarded because a pull request can see it change, the assertion\n"
            "total is not because it cannot.  See 'Figure maintenance' in\n"
            "ROADMAP.md.",
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


class TestTagClaimClassifier(unittest.TestCase):
    """The whole decision surface of :func:`classify_tag_claim`, driven from
    inputs rather than from whatever state this checkout happens to be in.

    The live test above can only ever exercise ONE point of this surface -- the
    one today's repository sits on -- so the interesting cases (a release in
    flight, a claim that has fallen behind, an attempt to walk into the
    exemption backwards) would otherwise never be executed at all.  Feeding the
    function its four inputs directly is what makes them reachable.
    """

    # Realistic tag lists: this repository's actual tags, including the
    # pre-reset ones that sort lexicographically ABOVE the live ones.
    TAGS_BEFORE = ["v0.2.0", "V1.0", "v1.2.1", "v1.2.0"]
    TAGS_AFTER = ["v0.2.1", "v0.2.0", "V1.0", "v1.2.1", "v1.2.0"]

    def test_steady_state_is_current(self) -> None:
        """The ordinary case: the claim names the tag that exists."""
        verdict, detail = classify_tag_claim(
            "v0.2.1", "v0.2.1", self.TAGS_AFTER, "0.2.1"
        )
        self.assertEqual(verdict, CLAIM_CURRENT, detail)

    def test_release_in_flight_is_allowed(self) -> None:
        """The window this exemption exists for, and the reason it exists.

        This is the exact state the v0.2.1 prep commit is in: mod.info bumped,
        roadmap naming the tag it is about to get, tag not pushed yet.  Under
        the plain equality this replaced, this state was RED, which is what
        made a release uncuttable without a red run.
        """
        verdict, detail = classify_tag_claim(
            "v0.2.1", "v0.2.0", self.TAGS_BEFORE, "0.2.1"
        )
        self.assertEqual(verdict, CLAIM_IN_FLIGHT, detail)

    def test_the_incident_the_guard_was_written_for_is_still_caught(self) -> None:
        """PR #124's finding: roadmap said v1.2.1 long after v0.2.0 shipped.

        The claim names an EXISTING tag that is not the newest, and does not
        match ``v<modversion>``, so it is stale under the new logic exactly as
        it was under the old equality.
        """
        verdict, _ = classify_tag_claim(
            "v1.2.1", "v0.2.0", self.TAGS_BEFORE, "0.2.0"
        )
        self.assertEqual(verdict, CLAIM_STALE)

    def test_a_claim_left_behind_by_a_completed_cut_is_stale(self) -> None:
        """The tag was pushed and the roadmap was never updated afterwards."""
        verdict, _ = classify_tag_claim(
            "v0.2.0", "v0.2.1", self.TAGS_AFTER, "0.2.1"
        )
        self.assertEqual(verdict, CLAIM_STALE)

    def test_the_exemption_cannot_be_entered_by_going_backwards(self) -> None:
        """Condition 3, the one that keeps a narrow exemption from becoming a
        bypass: bumping mod.info DOWN must not license an older tag name.

        Without the forward-only check this input satisfies conditions 1 and 2
        (the claim equals ``v<modversion>``, and no such tag exists), so it
        would be waved through as "a release in flight" forever.
        """
        verdict, _ = classify_tag_claim(
            "v0.1.5", "v0.2.0", self.TAGS_BEFORE, "0.1.5"
        )
        self.assertEqual(verdict, CLAIM_STALE)

    def test_the_exemption_cannot_name_a_tag_that_already_exists(self) -> None:
        """Condition 2: "not cut yet" has to be true, not merely asserted."""
        verdict, _ = classify_tag_claim(
            "v1.2.1", "v0.2.0", self.TAGS_BEFORE, "1.2.1"
        )
        self.assertEqual(verdict, CLAIM_STALE)

    def test_a_claim_that_disagrees_with_mod_info_is_stale(self) -> None:
        """Condition 1: the in-flight name is not free-form.

        A typo in the prep commit -- roadmap says v0.3.0 while mod.info says
        0.2.1 -- must not be readable as a release in flight.
        """
        verdict, _ = classify_tag_claim(
            "v0.3.0", "v0.2.0", self.TAGS_BEFORE, "0.2.1"
        )
        self.assertEqual(verdict, CLAIM_STALE)

    def test_an_unorderable_version_is_refused_rather_than_waved_through(self) -> None:
        """"Forward-only" needs a computable 'forward'; when there is none the
        answer is refusal, not a default pass."""
        verdict, _ = classify_tag_claim(
            "vnightly", "v0.2.0", self.TAGS_BEFORE, "nightly"
        )
        self.assertEqual(verdict, CLAIM_STALE)

    def test_forward_only_holds_across_the_whole_version_lattice(self) -> None:
        """Sweep the ordering rather than trusting two hand-picked points.

        Every component of the version is moved in both directions from a
        fixed baseline, and the verdict must follow the DIRECTION of the move
        rather than the fact that the tag is missing -- which is the property
        that stops "no such tag yet" from being the only thing the exemption
        actually tests.
        """
        baseline = (0, 2, 0)
        newest = "v0.2.0"
        checked = 0
        for index in range(3):
            for delta in (-1, +1, +2):
                parts = list(baseline)
                parts[index] += delta
                if any(part < 0 for part in parts):
                    continue
                candidate = "v" + ".".join(str(part) for part in parts)
                if candidate in self.TAGS_BEFORE or candidate == newest:
                    continue
                checked += 1
                verdict, detail = classify_tag_claim(
                    candidate, newest, self.TAGS_BEFORE, candidate[1:]
                )
                expected = (
                    CLAIM_IN_FLIGHT
                    if tuple(parts) > baseline
                    else CLAIM_STALE
                )
                self.assertEqual(
                    verdict,
                    expected,
                    f"{candidate} versus newest {newest}: {detail}",
                )
        # Zero-case hard failure: a sweep that skipped everything proves
        # nothing, and this loop skips candidates by construction.
        self.assertGreaterEqual(
            checked,
            6,
            "the forward/backward sweep exercised too few candidates to be "
            "meaningful; the skip conditions above have eaten the corpus.",
        )

    def test_known_gap_an_abandoned_prep_stays_in_flight_forever(self) -> None:
        """CHARACTERISATION, not an endorsement: the exemption has no clock.

        A tree left prepped for a version whose tag is never pushed reads as
        "release in flight" indefinitely, and this guard cannot tell that from
        a cut that is genuinely five minutes from happening.  Closing it needs
        a second signal the repository does not carry today (nothing here
        records WHEN the prep commit landed in a way a test can read without
        re-implementing git log).

        The residual is pinned here rather than only described in the backlog,
        so that whoever closes it has to delete this test deliberately instead
        of discovering the gap again.  It is bounded in practice: the prep
        commit and the tag push are the same increment by policy, so the window
        is minutes, and any LATER cut moves ``newest`` forward and turns the
        stale claim red through the ordinary path.
        """
        verdict, _ = classify_tag_claim(
            "v0.2.1", "v0.2.0", self.TAGS_BEFORE, "0.2.1"
        )
        self.assertEqual(
            verdict,
            CLAIM_IN_FLIGHT,
            "if this now fails, the exemption grew a staleness bound -- delete "
            "this characterisation test in the same commit.",
        )


if __name__ == "__main__":
    unittest.main()
