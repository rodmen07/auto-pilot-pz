"""Truth guard for docs/architecture.md's module count.

WHY THIS FILE EXISTS (2026-08-09).  PR #126 built ``tests/test_roadmap_truth.py``
to bind ROADMAP.md's cheap, unambiguous claims to the repository, and its
follow-up recorded that the module count has a SECOND live home this file now
guards: ``docs/architecture.md``'s "The runtime is N modules under
`42/media/lua/client/`" sentence.  That claim was CORRECT on the day the
follow-up was filed (24 = 24), which is exactly the state that drifts later
with everything still green -- and the premise held better than the item knew:
re-deriving it on 2026-08-09 found architecture.md contradicting ITSELF, the
same L-043 shape the roadmap had.  Line 22 said 24 modules while the CI-guards
section said luacheck runs "across the 23 modules", stale since
``AutoPilot_Mood`` became the 24th client module (PR #103, 2026-08-01) and
sitting right through two product truth audits that only read ROADMAP.md.
The first run of this guard on the unmodified document was RED on that line.

DESIGN DECISION the follow-up item asked for: the guard does NOT grow a
per-file claim table inside ``test_roadmap_truth.py`` -- it goes per-file by
IMPORT instead.  This module owns architecture.md's claims and reuses the
roadmap guard's machinery unchanged (``extract_claim`` with its exactly-once
rule, ``client_module_paths`` with its zero-match hard failure), the same
cross-test import shape ``test_priority_chain_truth.py`` and the workflow
suites already use.  That also keeps ``test_roadmap_truth.py`` at 917 lines
rather than pushing it over the C10 threshold its own follow-up predicts the
fifth in-file claim would (the PR #144 placement precedent).

WHAT IS GUARDED AND WHAT IS NOT.  Exactly one figure: the runtime module
count, glob-derived, so the PR that moves it can see that it moved it (the
2026-08-08 figure-maintenance decision).  The count deliberately has ONE live
home in the file; the luacheck bullet now says "every module" instead of
restating the number, because a second live copy is the split-brain itself --
``test_the_module_count_has_exactly_one_live_home`` fails if a numeric module
count reappears anywhere outside a tombstone.  Line counts, dates and the
module TABLE's prose stay audited, not guarded, per the same decision.

Tombstones: this repository quotes superseded prose verbatim where it stood,
wrapped ``*"``..``"*`` (L-048), so every scan here strips those spans first
and a committed control proves the stripping is load-bearing.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent
ARCHITECTURE = ROOT / "docs" / "architecture.md"

# Reuse the roadmap guard's machinery unchanged -- the exactly-once anchor
# extractor, its typed blind/ambiguous failure, and the glob the count is
# checked against.  Same import shape as test_priority_chain_truth.py.
sys.path.insert(0, str(Path(__file__).parent))
from test_roadmap_truth import (  # noqa: E402
    CLIENT_LUA_DIR,
    RoadmapAnchorError,
    client_module_paths,
    extract_claim,
)

# The live claim's anchor.  Narrow on purpose: it names the sentence, not the
# number, so a tombstoned old figure elsewhere in the file cannot match it,
# and rewording the sentence is a BLIND hard failure rather than a silent
# pass (extract_claim's exactly-once rule).
ANCHOR_RUNTIME_MODULE_COUNT = r"The runtime is (\d+) modules under `42/media/lua/client/`"

# Any numeric module-count phrasing, anchored or not.  This is what catches a
# SECOND live home appearing later ("spread across 25 modules...") -- the
# drift the narrow anchor cannot see because it only reads its own sentence.
# A digit is required, so prose like "the two modules that sort earlier" and
# "several modules" (both really in the file) cannot match.
BROAD_MODULE_COUNT = r"(\d+)\s+(?:Lua\s+)?modules\b"

# A tombstone is a superseded quote kept verbatim where it stood, wrapped
# *"..."* on a single line (the repo's convention; multi-line tombstones are
# deliberately not written because CRLF working trees make their literals
# unpinnable -- the PR #131 note).  Spans are stripped before any broad scan.
TOMBSTONE_SPAN = r"\*\"[^\"\r\n]*\"\*"

# The real tombstone the 2026-08-09 correction left in the file: the luacheck
# bullet's superseded wording, stale 23 against a live glob of 24 from
# 2026-08-01 (AutoPilot_Mood, PR #103) until this guard's first, red, run.
REAL_TOMBSTONE = '*"across the 23 modules in `42/media/lua/client/`"*'


def strip_tombstones(text: str) -> str:
    """Remove every ``*"..."*`` span so scans only ever see live prose."""
    return re.sub(TOMBSTONE_SPAN, "", text)


def live_module_count_mentions(text: str) -> list[str]:
    """Every numeric module-count mention OUTSIDE a tombstone, in file order."""
    return re.findall(BROAD_MODULE_COUNT, strip_tombstones(text))


def architecture_text() -> str:
    return ARCHITECTURE.read_text(encoding="utf-8")


class TestArchitectureClaimsMatchReality(unittest.TestCase):
    """The live document against the live tree."""

    def test_architecture_md_exists(self) -> None:
        self.assertTrue(
            ARCHITECTURE.is_file(),
            f"{ARCHITECTURE} is missing -- if the document moved, move this "
            "guard's path in the same commit.",
        )

    def test_runtime_module_count_matches_the_client_lua_glob(self) -> None:
        modules = client_module_paths()
        # Zero-match hard failure: an empty glob means the tree moved, and a
        # guard that "passes" on an empty directory proves nothing.
        self.assertGreater(
            len(modules),
            0,
            f"no *.lua files found under {CLIENT_LUA_DIR}.  Discovery is "
            "glob-driven; zero matches means the module tree moved and this "
            "guard is measuring nothing.",
        )
        claimed = extract_claim(
            architecture_text(), ANCHOR_RUNTIME_MODULE_COUNT, "architecture module count"
        )
        self.assertEqual(
            int(claimed),
            len(modules),
            f"docs/architecture.md claims the runtime is {claimed} modules, "
            f"the 42/media/lua/client/*.lua glob finds {len(modules)}:\n  "
            + "\n  ".join(p.name for p in modules)
            + "\nFix the architecture claim (it is the one that goes stale), "
            "not this test -- and quote the superseded wording where it stood, "
            "per this repo's tombstone convention.",
        )

    def test_the_module_count_has_exactly_one_live_home(self) -> None:
        """A second live copy of the figure is the split-brain itself.

        This is the assertion that was RED on the unmodified document when
        this guard first ran on 2026-08-09: the luacheck bullet still said
        "across the 23 modules" while the runtime sentence said 24, so the
        file disagreed with itself and one of the two had to be wrong.
        """
        text = architecture_text()
        anchored = extract_claim(
            text, ANCHOR_RUNTIME_MODULE_COUNT, "architecture module count"
        )
        mentions = live_module_count_mentions(text)
        self.assertEqual(
            mentions,
            [anchored],
            f"docs/architecture.md carries {len(mentions)} live numeric module "
            f"counts ({mentions!r}); it must carry exactly ONE, the anchored "
            f"runtime claim ({anchored!r}).  A second live copy drifts "
            "independently with every guard green -- either delete the figure "
            "from the extra site (say 'every module'), or tombstone it as "
            '*"..."* superseded prose.',
        )


# ---------------------------------------------------------------------------
# Synthetic controls: the behaviour difference between a correct document and
# a stale one, pinned in-suite so the guard cannot rot into a scan that
# passes on everything.  Built from the REAL live claim wording and the REAL
# tombstone, with a reality-pinning test keeping both tied to the file.
# ---------------------------------------------------------------------------
SYNTHETIC_ARCHITECTURE = f"""\
# AutoPilot architecture (synthetic control)

The runtime is 24 modules under `42/media/lua/client/` (list elided).

## CI Guards

1. **luacheck**: zero errors and zero warnings across every module in
   `42/media/lua/client/`.  Superseded wording: {REAL_TOMBSTONE}.
"""


class TestEachCheckFiresOnDoctoredInput(unittest.TestCase):
    """Each failure mode observed failing, on doctored input."""

    def test_a_stale_runtime_count_is_caught(self) -> None:
        stale = SYNTHETIC_ARCHITECTURE.replace(
            "The runtime is 24 modules under", "The runtime is 23 modules under"
        )
        self.assertNotEqual(stale, SYNTHETIC_ARCHITECTURE, "the perturbation did nothing")
        self.assertEqual(
            int(extract_claim(stale, ANCHOR_RUNTIME_MODULE_COUNT, "control")), 23
        )
        self.assertNotEqual(
            23,
            len(client_module_paths()),
            "23 was chosen as a wrong count; it is no longer wrong, pick another",
        )

    def test_a_reworded_claim_raises_instead_of_passing(self) -> None:
        """The blind-guard failure: the assertion that fires when the surface
        is dead (L-001) -- a reworded sentence must never read as clean."""
        reworded = SYNTHETIC_ARCHITECTURE.replace(
            "The runtime is 24 modules under", "The mod ships 24 modules living under"
        )
        self.assertNotEqual(
            reworded, SYNTHETIC_ARCHITECTURE, "the perturbation did nothing"
        )
        with self.assertRaises(RoadmapAnchorError):
            extract_claim(reworded, ANCHOR_RUNTIME_MODULE_COUNT, "control")

    def test_a_second_live_home_is_caught_by_the_broad_scan(self) -> None:
        """The exact 2026-08-09 defect class, reproduced: a live figure the
        narrow anchor cannot see.  'the 23 modules' matches no anchor, so only
        the exactly-one-live-home scan can redden on it -- and must."""
        second_home = SYNTHETIC_ARCHITECTURE.replace(
            "across every module in", "across the 23 modules in"
        )
        self.assertNotEqual(
            second_home, SYNTHETIC_ARCHITECTURE, "the perturbation did nothing"
        )
        anchored = extract_claim(second_home, ANCHOR_RUNTIME_MODULE_COUNT, "control")
        self.assertEqual(anchored, "24", "the anchored claim itself must survive")
        self.assertNotEqual(
            live_module_count_mentions(second_home),
            [anchored],
            "a second live module count must NOT read as exactly-one-home",
        )
        self.assertEqual(live_module_count_mentions(second_home), ["24", "23"])

    def test_the_tombstone_does_not_fool_the_scan(self) -> None:
        """The stripping is load-bearing (L-048): on the raw text the broad
        pattern matches the tombstoned 23 as well, so without the strip this
        guard would redden a CORRECT document."""
        raw_matches = re.findall(BROAD_MODULE_COUNT, SYNTHETIC_ARCHITECTURE)
        self.assertEqual(
            raw_matches,
            ["24", "23"],
            "the synthetic control must contain a tombstoned figure the raw "
            "pattern sees -- if it does not, this control controls nothing",
        )
        self.assertEqual(live_module_count_mentions(SYNTHETIC_ARCHITECTURE), ["24"])

    def test_the_real_architecture_still_carries_that_tombstone(self) -> None:
        """Ties the synthetic control to reality: the tombstone it strips is
        really in docs/architecture.md, newline-free on one line (the CRLF
        rule -- a multi-line literal compares \\n against \\r\\n and reddens a
        correct document)."""
        self.assertIn(
            REAL_TOMBSTONE,
            architecture_text(),
            "the 2026-08-09 correction's tombstone is gone from "
            "docs/architecture.md.  If it was deliberately removed, update "
            "REAL_TOMBSTONE and SYNTHETIC_ARCHITECTURE in the same commit; "
            "these controls must strip a REAL tombstone, not an invented one.",
        )


if __name__ == "__main__":
    unittest.main()
