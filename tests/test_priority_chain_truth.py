#!/usr/bin/env python3
"""tests/test_priority_chain_truth.py — the priority chain's prose is bound to check() itself.

The mod's decision chain is enumerated in two prose homes: ``README.md``'s
"Priority Model (High to Low)" list (what a player reads) and the header
comment of ``42/media/lua/client/AutoPilot_Needs.lua`` (what a developer
reads).  Until 2026-08-08 nothing bound either of them to the code, and both
were false the same way: they listed an "Explore" step whose module was
deleted in V3.1 (commit ``a3cedd2``), they put Tired below Thirst/Hunger/
Wounds when ``check()`` has walked the fatigue gate second since the blocked-
sleep work, and they put Scavenge above mood relief and exercise when the
V3.2 reorder moved it to the very bottom.  PR #138 then copied the header's
ten steps into the README *believing the header authoritative* — the exact
trap its own follow-up item predicted: binding one comment to another proves
only that two comments agree.

This guard therefore derives the chain from ``check()``'s EXECUTABLE body —
the ordered ``AutoPilot_Telemetry.setDecision("<action>", "<reason>")`` call
sites plus the two ``AutoPilot_Mood.doMoodRelief(player, <flag>)`` calls —
with comments stripped first, so no prose on either side can satisfy it.
Both prose homes must list exactly that chain, in that order.

Scope, stated honestly: this binds the prose to the ORDER OF DECISION CALL
SITES in the source, not to runtime behaviour.  The runtime ordering of
individual pairs (bleeding beats thirst, and so on) is behaviourally pinned
by ``tests/test_priority_logic.lua`` under the mock engine; this file is the
missing README/header binding, not a replacement for those tests.

Maintenance contract: a new ``setDecision`` call site in ``check()`` fails
this guard until it is added to ``ANCHOR_TO_STEP``, and a new step id fails
until both prose homes list it in position.  That is deliberate — the prose
cannot drift silently in either direction.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from test_combat_claim_truth import strip_lua_comments  # noqa: E402

ROOT = Path(__file__).parent.parent
NEEDS_LUA = ROOT / "42" / "media" / "lua" / "client" / "AutoPilot_Needs.lua"
README = ROOT / "README.md"

#: The body slice starts at check()'s definition and ends at the next
#: top-level definition on the module table.  Inline ``pcall(function()``
#: closures never match because they do not begin a line with ``function``.
CHECK_HEADER = "function AutoPilot_Needs.check(player)"
NEXT_TOP_LEVEL = re.compile(r"\nfunction AutoPilot_Needs\.")

#: A body that parses shorter than this has lost most of the chain; fail
#: loudly rather than derive a tiny "order" that trivially matches nothing.
MIN_BODY_CHARS = 2000

#: Ordered anchors: a decision call, or a mood-relief delegation whose
#: boolean names which step owns it (seated subset = the rest hold).
ANCHOR = re.compile(
    r'AutoPilot_Telemetry\.setDecision\(\s*"([a-z_]+)"\s*,\s*"([a-z_]+)"'
    r"|AutoPilot_Mood\.doMoodRelief\(player,\s*(true|false)\)"
)

#: Every (action, reason) pair check() may emit, mapped to the chain step
#: that owns it.  An UNMAPPED pair raises: a new decision call site must be
#: classified here (and listed in both prose homes) in the same commit.
ANCHOR_TO_STEP = {
    ("bandage", "bleeding"): "bleeding",
    ("sleep", "fatigue_thresh"): "sleep",
    ("drink", "thirst_thresh"): "thirst",
    ("drink", "thirst_moodle"): "thirst",
    ("shelter", "weather"): "shelter",
    ("eat", "hunger_thresh"): "hunger",
    ("eat", "hunger_moodle"): "hunger",
    ("bandage", "wound"): "wounds",
    ("clothing", "temperature"): "clothing",
    ("rest", "low_endurance"): "rest",
    ("rest", "rest_cooldown"): "rest",
    ("dry", "wet"): "dry",
    ("dry", "no_towel"): "dry",
    ("rest", "sit_recover"): "sit_recover",
    ("exercise", "training"): "exercise",
    ("scavenge", "low_supplies"): "scavenge",
}

#: The seated mood-relief subset runs INSIDE the rest hold and belongs to the
#: rest step; the standing full call is the Bored-or-sad step itself.
MOOD_FLAG_TO_STEP = {"true": "rest", "false": "mood"}

#: Prose labels, mapped to step ids.  Retired labels stay mapped so a dead
#: step fails the ORDER comparison by name instead of dying as an unknown
#: word: "Explore" is the caught specimen — listed in both prose homes from
#: the V3.1 module deletion until 2026-08-08 while no explore code existed.
LABEL_TO_STEP = {
    "Bleeding": "bleeding",
    "Tired": "sleep",
    "Thirst": "thirst",
    "Shelter": "shelter",
    "Hunger": "hunger",
    "Wounds": "wounds",
    "Clothing": "clothing",
    "Exhausted": "rest",
    "Wet": "dry",
    "Bored or sad": "mood",
    "Bored/Sad": "mood",
    "Winded": "sit_recover",
    "Idle": "exercise",
    "Scavenge": "scavenge",
    "Explore": "explore",
}

README_HEADING = "## Priority Model (High to Low)"
#: A README step line: ``1. Bleeding — bandage immediately`` (em dash).
README_STEP = re.compile(r"^(\d+)\.\s+([A-Za-z][A-Za-z /]*?)\s+—\s", re.M)

HEADER_MARKER = "-- Priority order (highest -> lowest):"
#: A header step line: ``--   1. Bleeding      -> bandage immediately``.
HEADER_STEP = re.compile(r"^--\s+(\d+)\.\s+([A-Za-z][A-Za-z /]*?)\s+->\s")

FIX_HINT = (
    "The priority-chain prose and AutoPilot_Needs.check() disagree.\n"
    "If you reordered or extended check(), update BOTH prose homes (README.md\n"
    "'Priority Model' and the Needs.lua header) in the same commit, and map any\n"
    "new setDecision call site in ANCHOR_TO_STEP here.  If you edited the\n"
    "prose, it must list exactly the chain the code walks.  A step with no\n"
    "anchor in check() is a capability claim the code does not walk -- that is\n"
    "how a dead 'Explore' step survived in both homes from the V3.1 module\n"
    "deletion until 2026-08-08."
)


class ChainReadError(AssertionError):
    """A source could not be read, so the guard has no expectation."""


# ---------------------------------------------------------------------------
# Truth side: the chain check() actually walks.
# ---------------------------------------------------------------------------
def check_body(needs_source: str) -> str:
    """Return check()'s body slice, or raise rather than scan the wrong text."""
    start = needs_source.find(CHECK_HEADER)
    if start < 0:
        raise ChainReadError(
            "could not find `" + CHECK_HEADER + "` in AutoPilot_Needs.lua, so the\n"
            "chain cannot be derived.  If check() was renamed or moved, update\n"
            "this guard in the same commit — it must not silently stop checking.\n"
            + FIX_HINT
        )
    rest = needs_source[start:]
    nxt = NEXT_TOP_LEVEL.search(rest, len(CHECK_HEADER))
    body = rest[: nxt.start()] if nxt else rest
    if len(body) < MIN_BODY_CHARS:
        raise ChainReadError(
            f"check()'s body parsed to only {len(body)} characters (floor\n"
            f"{MIN_BODY_CHARS}).  The slice rule has gone stale; a tiny body\n"
            "would derive a tiny chain and 'verify' almost anything.\n" + FIX_HINT
        )
    return body


def derived_chain(needs_source: str, min_steps: int = 8) -> list[str]:
    """The ordered step ids check()'s executable body walks.

    Comments are stripped BEFORE extraction, so prose cannot leave phantom
    anchors (the control test pins that difference).  Consecutive anchors of
    one step collapse; a step REAPPEARING later is an order violation and
    raises, because a split step means the prose list can no longer be true.

    ``min_steps`` is the blindness floor for the LIVE file; the synthetic
    control bodies below pass an explicit lower floor because their point is
    the derivation rule, not the live chain's size.
    """
    stripped = strip_lua_comments(check_body(needs_source))
    steps: list[str] = []
    for action, reason, mood_flag in ANCHOR.findall(stripped):
        if mood_flag:
            step = MOOD_FLAG_TO_STEP[mood_flag]
        else:
            try:
                step = ANCHOR_TO_STEP[(action, reason)]
            except KeyError:
                raise ChainReadError(
                    f'setDecision("{action}", "{reason}") in check() is not in\n'
                    "ANCHOR_TO_STEP.  Classify the new call site and list its step\n"
                    "in both prose homes in the same commit.\n" + FIX_HINT
                ) from None
        if steps and steps[-1] == step:
            continue
        if step in steps:
            raise ChainReadError(
                f"step '{step}' appears twice non-consecutively in check() --\n"
                f"derived so far: {steps + [step]}.  A split step has no single\n"
                "position, so no prose list can be true; restructure or remap.\n"
                + FIX_HINT
            )
        steps.append(step)
    if len(steps) < min_steps:
        raise ChainReadError(
            f"derived only {len(steps)} steps ({steps}) from check().  The\n"
            "extractor has gone blind; blindness must never read as a short\n"
            "chain that some short prose list happens to match.\n" + FIX_HINT
        )
    return steps


# ---------------------------------------------------------------------------
# Claim side: what the two prose homes list.
# ---------------------------------------------------------------------------
def readme_priority_section(readme: str) -> str:
    """The Priority Model section only — the README has OTHER numbered lists
    (install steps, dev steps) that must never satisfy this guard."""
    if README_HEADING not in readme:
        raise ChainReadError(
            "README.md has no `" + README_HEADING + "` heading.  If the section\n"
            "was renamed, update this guard in the same commit — a reworded\n"
            "heading must fail loudly, never pass silently.\n" + FIX_HINT
        )
    section = readme.split(README_HEADING, 1)[1]
    nxt = re.search(r"^## ", section, re.M)
    return section[: nxt.start()] if nxt else section


def labelled_steps(numbered: list[tuple[str, str]], home: str) -> list[str]:
    """Map (number, label) pairs to step ids; loud on any unknown label."""
    steps = []
    for _num, label in numbered:
        label = label.strip()
        if label not in LABEL_TO_STEP:
            raise ChainReadError(
                f"{home} lists a step labelled '{label}' that LABEL_TO_STEP does\n"
                "not know.  Add the label (or fix the typo) in the same commit.\n"
                + FIX_HINT
            )
        steps.append(LABEL_TO_STEP[label])
    return steps


def readme_chain(readme: str) -> list[str]:
    numbered = README_STEP.findall(readme_priority_section(readme))
    if len(numbered) < 5:
        raise ChainReadError(
            f"parsed only {len(numbered)} numbered steps from the README's\n"
            "Priority Model section.  The list grammar has drifted; fix the\n"
            "parser or the prose, never trust a short parse.\n" + FIX_HINT
        )
    return labelled_steps(numbered, "README.md")


def readme_numbering(readme: str) -> list[int]:
    return [int(n) for n, _ in README_STEP.findall(readme_priority_section(readme))]


def header_block_lines(needs_source: str) -> list[str]:
    """The comment lines following the header marker, and only those."""
    lines = needs_source.splitlines()
    try:
        at = next(i for i, ln in enumerate(lines) if ln.strip() == HEADER_MARKER)
    except StopIteration:
        raise ChainReadError(
            "AutoPilot_Needs.lua has no `" + HEADER_MARKER + "` marker line, so\n"
            "the header list cannot be located.  If the header was reworded,\n"
            "update this guard in the same commit.\n" + FIX_HINT
        ) from None
    block = []
    for ln in lines[at + 1:]:
        if not ln.startswith("--"):
            break
        block.append(ln)
    return block


def header_chain(needs_source: str) -> list[str]:
    numbered = []
    for ln in header_block_lines(needs_source):
        m = HEADER_STEP.match(ln)
        if m:
            numbered.append((m.group(1), m.group(2)))
    if len(numbered) < 5:
        raise ChainReadError(
            f"parsed only {len(numbered)} numbered steps from the Needs.lua\n"
            "header block.  The list grammar has drifted; fix the parser or the\n"
            "prose, never trust a short parse.\n" + FIX_HINT
        )
    return labelled_steps(numbered, "AutoPilot_Needs.lua header")


def header_numbering(needs_source: str) -> list[int]:
    nums = []
    for ln in header_block_lines(needs_source):
        m = HEADER_STEP.match(ln)
        if m:
            nums.append(int(m.group(1)))
    return nums


def chain_diff(claimed: list[str], walked: list[str], home: str) -> str:
    dead = [s for s in claimed if s not in walked]
    missing = [s for s in walked if s not in claimed]
    msg = [
        f"{home} does not list the chain check() walks.",
        f"  {home} claims : {claimed}",
        f"  check() walks : {walked}",
    ]
    if dead:
        msg.append(f"  DEAD steps (claimed, never walked): {dead}")
    if missing:
        msg.append(f"  MISSING steps (walked, not listed): {missing}")
    if not dead and not missing:
        msg.append("  Same steps, WRONG ORDER.")
    return "\n".join(msg) + "\n" + FIX_HINT


# ---------------------------------------------------------------------------
# The guard proper.
# ---------------------------------------------------------------------------
class TestTheChainCanBeRead(unittest.TestCase):
    """Parse health: every raise-path above is a guard against silent blindness."""

    def test_check_body_is_found_and_substantial(self) -> None:
        body = check_body(NEEDS_LUA.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(body), MIN_BODY_CHARS)

    def test_every_anchor_in_check_is_classified(self) -> None:
        # derived_chain raises on any unmapped call site; reaching the floor
        # assertion means every live anchor is classified.
        chain = derived_chain(NEEDS_LUA.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(chain), 8)

    def test_both_prose_homes_parse(self) -> None:
        self.assertGreaterEqual(len(readme_chain(README.read_text(encoding="utf-8"))), 5)
        self.assertGreaterEqual(
            len(header_chain(NEEDS_LUA.read_text(encoding="utf-8"))), 5
        )


class TestReadmeMatchesTheCode(unittest.TestCase):
    def test_readme_lists_exactly_the_walked_chain_in_order(self) -> None:
        walked = derived_chain(NEEDS_LUA.read_text(encoding="utf-8"))
        claimed = readme_chain(README.read_text(encoding="utf-8"))
        self.assertEqual(
            claimed, walked, chain_diff(claimed, walked, "README.md Priority Model")
        )

    def test_readme_numbering_is_consecutive_from_one(self) -> None:
        nums = readme_numbering(README.read_text(encoding="utf-8"))
        self.assertEqual(
            nums,
            list(range(1, len(nums) + 1)),
            "README Priority Model numbering is not 1..N — a missing middle\n"
            "entry renumbers silently, which is exactly how a dropped step hid\n"
            "before (PR #138 found the list at 8 continuous steps).",
        )


class TestHeaderMatchesTheCode(unittest.TestCase):
    def test_header_lists_exactly_the_walked_chain_in_order(self) -> None:
        src = NEEDS_LUA.read_text(encoding="utf-8")
        walked = derived_chain(src)
        claimed = header_chain(src)
        self.assertEqual(
            claimed, walked, chain_diff(claimed, walked, "AutoPilot_Needs.lua header")
        )

    def test_header_numbering_is_consecutive_from_one(self) -> None:
        src = NEEDS_LUA.read_text(encoding="utf-8")
        nums = header_numbering(src)
        self.assertEqual(nums, list(range(1, len(nums) + 1)))


# ---------------------------------------------------------------------------
# Controls: each check observed FIRING on doctored input (hand-written
# fixtures, not transformations of the live files, so a broken transform
# cannot silently blank a control).
# ---------------------------------------------------------------------------
SYNTHETIC_BODY = (
    "function AutoPilot_Needs.check(player)\n"
    + "    -- comment mentioning AutoPilot_Telemetry.setDecision(\"scavenge\", \"low_supplies\")\n"
    + '    AutoPilot_Telemetry.setDecision("exercise", "training")\n'
    + '    AutoPilot_Telemetry.setDecision("bandage", "bleeding")\n'
    + "    AutoPilot_Mood.doMoodRelief(player, false)\n"
    + "end\n"
    + ("-- padding so the body-length floor is met\n" * 60)
    + "\nfunction AutoPilot_Needs.other()\nend\n"
)


class TestTheDerivationReadsTheInputNotTheMap(unittest.TestCase):
    """The chain must come from the SOURCE's order, not from any table here."""

    def test_synthetic_body_order_is_reproduced_verbatim(self) -> None:
        # exercise before bleeding — the opposite of the live chain and of
        # every mapping table above.  Only reading the input can produce it.
        self.assertEqual(
            derived_chain(SYNTHETIC_BODY, min_steps=3),
            ["exercise", "bleeding", "mood"],
        )

    def test_a_commented_anchor_is_a_phantom_the_strip_removes(self) -> None:
        # The comment names a scavenge anchor; the executable body has none.
        self.assertNotIn("scavenge", derived_chain(SYNTHETIC_BODY, min_steps=3))
        # Control of the control: WITHOUT stripping, the phantom is visible —
        # the comment really does contain the anchor text.
        raw_hits = ANCHOR.findall(check_body(SYNTHETIC_BODY))
        self.assertIn(("scavenge", "low_supplies", ""), raw_hits)

    def test_mood_flag_routes_the_seated_subset_to_the_rest_hold(self) -> None:
        seated = SYNTHETIC_BODY.replace(
            "doMoodRelief(player, false)", "doMoodRelief(player, true)"
        )
        self.assertEqual(
            derived_chain(seated, min_steps=3), ["exercise", "bleeding", "rest"]
        )

    def test_an_unmapped_call_site_raises_instead_of_guessing(self) -> None:
        rogue = SYNTHETIC_BODY.replace(
            '"exercise", "training"', '"warcry", "morale"'
        )
        with self.assertRaisesRegex(ChainReadError, "warcry"):
            derived_chain(rogue, min_steps=1)

    def test_a_nonconsecutive_repeat_raises(self) -> None:
        split = SYNTHETIC_BODY.replace(
            "    AutoPilot_Mood.doMoodRelief(player, false)\n",
            "    AutoPilot_Mood.doMoodRelief(player, false)\n"
            + '    AutoPilot_Telemetry.setDecision("exercise", "training")\n',
        )
        with self.assertRaisesRegex(ChainReadError, "twice non-consecutively"):
            derived_chain(split, min_steps=1)


DOCTORED_README = (
    "# AutoPilot\n\n"
    + "## Install\n\n"
    + "1. Decoy — install steps are a numbered list too\n"
    + "2. Decoy — and must never satisfy the chain guard\n\n"
    + README_HEADING
    + "\n\nThe chain, highest first:\n\n"
    + "{steps}\n"
    + "## Next Section\n\n"
    + "1. Decoy — trailing numbered list outside the section\n"
)


def doctored_readme(steps: list[str]) -> str:
    listing = "\n".join(
        f"{i}. {label} — blurb text" for i, label in enumerate(steps, start=1)
    )
    return DOCTORED_README.format(steps=listing)


class TestEachCheckFiresOnDoctoredProse(unittest.TestCase):
    """The live chain, perturbed one defect at a time; every defect must fail."""

    def live_chain_labels(self) -> list[str]:
        walked = derived_chain(NEEDS_LUA.read_text(encoding="utf-8"))
        step_to_label = {}
        for label, step in LABEL_TO_STEP.items():
            step_to_label.setdefault(step, label)
        return [step_to_label[s] for s in walked]

    def test_the_doctored_baseline_passes(self) -> None:
        # The control fixture with NO defect matches the live chain — so each
        # failure below is caused by its one perturbation, nothing else.
        walked = derived_chain(NEEDS_LUA.read_text(encoding="utf-8"))
        self.assertEqual(readme_chain(doctored_readme(self.live_chain_labels())), walked)

    def test_a_dead_step_is_caught(self) -> None:
        # The real-world specimen: Explore, dead since V3.1, listed anyway.
        labels = self.live_chain_labels()
        labels.insert(7, "Explore")
        claimed = readme_chain(doctored_readme(labels))
        walked = derived_chain(NEEDS_LUA.read_text(encoding="utf-8"))
        self.assertNotEqual(claimed, walked)
        self.assertIn("explore", chain_diff(claimed, walked, "doctored"))

    def test_a_swapped_pair_is_caught(self) -> None:
        # The real-world shape: prose putting Tired below Thirst.
        labels = self.live_chain_labels()
        i, j = labels.index("Tired"), labels.index("Thirst")
        labels[i], labels[j] = labels[j], labels[i]
        self.assertNotEqual(
            readme_chain(doctored_readme(labels)),
            derived_chain(NEEDS_LUA.read_text(encoding="utf-8")),
        )

    def test_a_dropped_step_is_caught(self) -> None:
        labels = self.live_chain_labels()
        labels.remove("Scavenge")
        self.assertNotEqual(
            readme_chain(doctored_readme(labels)),
            derived_chain(NEEDS_LUA.read_text(encoding="utf-8")),
        )

    def test_decoy_lists_outside_the_section_are_not_collected(self) -> None:
        doc = doctored_readme(self.live_chain_labels())
        # The decoys really are present in the fixture...
        self.assertEqual(doc.count("Decoy"), 3)
        # ...and none of them reached the parse.
        section_steps = README_STEP.findall(readme_priority_section(doc))
        self.assertEqual(len(section_steps), len(self.live_chain_labels()))

    def test_a_reworded_heading_raises_instead_of_passing(self) -> None:
        doc = doctored_readme(self.live_chain_labels()).replace(
            README_HEADING, "## Priorities"
        )
        with self.assertRaises(ChainReadError):
            readme_chain(doc)

    def test_an_unknown_label_raises_by_name(self) -> None:
        labels = self.live_chain_labels()
        labels[0] = "Bleeding badly"
        with self.assertRaisesRegex(ChainReadError, "Bleeding badly"):
            readme_chain(doctored_readme(labels))


if __name__ == "__main__":
    unittest.main(verbosity=2)
