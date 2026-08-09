"""Truth guard: what the mod tells PLAYERS about combat, bound to what it does.

WHY THIS EXISTS
---------------
The mod has been FLEE-ONLY since PR #74 (2026-07-25), on a hard engine finding:
Build 42 exposes no attack API for an AI-driven character, so ``doFight`` walked
the character up to a zombie where it could never swing, and every "fight" was a
walk to its death.  Every branch of ``_decideEngagement`` has returned the intent
``"flee"`` ever since, and ``doFight``/``forceFight`` were deleted.

``README.md`` said so correctly.  The three files that describe the mod to
**players** did not.  For two weeks and across two releases, ``mod.info``,
``42/mod.info`` and the ``workshop.txt`` template embedded in
``sync_workshop.sh`` all advertised that the mod *"fights or flees when zombies
actually threaten"* -- the one behaviour it provably cannot perform.  That is
not cosmetic drift in a developer doc: ``mod.info``'s ``description=`` is the
blurb the game's own Mods list renders, the template is what the Steam Workshop
listing is written from, and the expectation gap had already been reported once
as a user bug (*"the fight/flee mechanic is not working as expected"*, V5.6).

So the claim needs an owner that is not prose.  This module is it.

WHAT IS GUARDED, AND WHY IN THIS SHAPE
--------------------------------------
1. **The policy is READ from the code, never hardcoded here.**  The engagement
   intents are extracted from ``_decideEngagement``'s body in
   ``AutoPilot_Threat.lua``.  If Build 43 ever exposes an attack API and a
   ``"fight"`` intent comes back, this guard does not quietly keep demanding a
   no-combat disclaimer -- it fails and says the player-facing copy is now a
   product decision.  That is the two-source agreement the module exists for.

2. **The corpus is GLOB-DISCOVERED**, from ``git ls-files``, not hand-listed: a
   hand list degrades silently the day a ``41/mod.info`` or a second payload
   root appears, and going quiet is the exact failure mode being guarded.  A
   zero/short match is a hard failure, never a pass.

3. **The claim test asks whether a negation GOVERNS the verb**, not whether one
   appears nearby.  Banning the word "fight" outright would redden the correct
   text, because an honest description has to *use* the word to disclaim it
   ("It never fights: ...").  But a sentence-level negation test is worse than
   useless here, and control A proved it on the first run: the shipped blurb
   reads *"a FAIL-SAFE, **not** a full autopilot: ... and fights or flees"*, so
   a sentence-level rule finds a "not", calls the sentence a disclaimer, and
   passes the exact defect this module exists for.  The negation therefore has
   to sit within a few words of the verb and inside the same clause.  Each file
   must additionally carry the disclosure at least once, so deleting the
   disclaimer is as red as re-adding the promise.

4. **The template is proven by RUNNING the script, not by reading it.**
   ``sync_workshop.sh`` writes its embedded template only when ``workshop.txt``
   is ABSENT; every other ``description=`` line is copied byte for byte from
   whatever the file already had.  A source-text scan cannot tell a template
   that ships the right words from one that composes the wrong ones at run
   time, so this module runs the real script under a sandboxed ``HOME`` and
   scans the bytes it actually produced.

5. **Both reachable staging states are exercised, not just the convenient one.**
   The script's output depends on one thing the user can actually vary: whether
   ``workshop.txt`` already exists.  Checking only the fresh path would prove the
   fix under the state the fix was written for and read as though it proved the
   contract.  The pre-existing path is the documented second-order trap -- it is
   how V5.0 shipped a release still advertising "maintains window barricades"
   after barricading was removed -- so it is asserted here in the direction that
   is TRUE: the script does NOT auto-fix a stale copy, and it must say so.

NEGATIVE CONTROLS
-----------------
* **A** -- the real pre-fix sentence, restored into a synthetic ``mod.info``,
  must fire the claim scan.
* **B** -- the control that matters, shaped to satisfy the cheap clause while
  breaking the behaviour: a sync script whose source contains no combat verb in
  any ``description=`` line at all (asserted, not assumed, because that is the
  half a text-only guard would certify as honest) which nevertheless composes
  the promise into ``workshop.txt`` from a shell variable.  Only running it
  catches that.  If the run-scan were dropped, control B would pass and this
  guard would bless a listing advertising combat.
* **C** -- a doctored ``_decideEngagement`` returning a ``"fight"`` intent must
  make the policy read report NOT flee-only, proving the expectation is derived
  from the module rather than baked in here.
* **D** -- a threat source whose function or whose returns cannot be found must
  RAISE.  A guard that cannot see its input must fail, never report clean.
* **E** -- a script that exits non-zero must raise UNVERIFIED.  A failed run
  writes no ``workshop.txt`` and is byte-identical, at the "did the scan find a
  claim" question, to a run that produced a clean one.
* **F** -- the phantom-match control: the raw threat source mentions ``"fight"``
  inside comments, so a whole-file regex sees combat where the scoped,
  comment-stripped read correctly sees only ``flee``.

Parses as text and runs one local shell script.  No game, no network, no Steam.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).parent.parent

THREAT_LUA = ROOT / "42" / "media" / "lua" / "client" / "AutoPilot_Threat.lua"
SYNC_SCRIPT = ROOT / "sync_workshop.sh"

#: Where ``sync_workshop.sh`` puts the staging folder, relative to ``$HOME``.
STAGING_REL = Path("Zomboid") / "Workshop" / "AutoPilotLeveler"

BASH = shutil.which("bash")

#: Verbs that assert the mod engages zombies.  Deliberately small and
#: unambiguous: every one of these describes the character doing something to a
#: zombie, which is exactly what Build 42 gives an AI-driven character no way to
#: do.  "flee", "run", "escape" are not here -- those are the true claims.
COMBAT_VERB = re.compile(
    r"\b(fight|fights|fighting|fought|attack|attacks|attacking|melee|"
    r"kill|kills|killing)\b",
    re.IGNORECASE,
)

#: What turns a combat verb into an honest disclaimer instead of a promise.
NEGATION = re.compile(r"\b(never|no|not|cannot|n't|neither|nor)\b", re.IGNORECASE)

#: How close the negation has to sit in front of the verb, in words.
#:
#: This window is not decoration and the number is not a guess.  The first
#: version of this guard asked only whether the SENTENCE contained a negation
#: anywhere, and control A immediately proved that vacuous: the real pre-fix
#: blurb reads *"survival acts as a FAIL-SAFE, **not** a full autopilot: eats,
#: drinks, sleeps, bandages wounds, and fights or flees ..."*.  A sentence-level
#: rule reads that "not" -- which negates "a full autopilot" twelve words
#: earlier -- as though it negated "fights", so the guard would have blessed the
#: exact text it exists to catch.  The negation must therefore govern the VERB.
NEGATION_WINDOW_WORDS = 3

#: Clause boundaries.  A negation on the far side of one of these belongs to a
#: different clause, which is precisely how the pre-fix sentence fooled the
#: first version: "not a full autopilot: ... and fights" has a colon and four
#: commas between the negation and the verb.
CLAUSE_BREAK = re.compile(r"[,:;()\[\]]")

#: A ``description=`` line, in the one form both artefacts use.  ``mod.info``
#: has a single such line; ``workshop.txt`` (and the template that generates it)
#: has one per paragraph.
DESCRIPTION_LINE = re.compile(r"^\s*description=(.*)$")

#: The engagement decision function whose returns ARE the combat policy.
DECIDE_FN = re.compile(
    r"(?ms)^local function _decideEngagement\s*\(.*?^end\b",
)

#: ``return "<intent>", "<reason>", dx, dy`` -- the intent is the first string.
INTENT_RETURN = re.compile(r'\breturn\s+"([a-z_]+)"\s*,\s*"([a-z_]+)"')

FIX_HINT = (
    "The mod's player-facing description and its engagement policy disagree.\n"
    "AutoPilot_Threat is FLEE-ONLY (PR #74): Build 42 exposes no attack API for\n"
    "an AI-driven character, so a description promising combat promises the one\n"
    "behaviour the mod provably cannot perform.  mod.info's description= is the\n"
    "blurb the game's Mods list renders and sync_workshop.sh's template is what\n"
    "the Steam Workshop listing is written from, so this is the install\n"
    "decision, not a developer doc.\n"
    "If an attack API genuinely arrived, that is a product event: update the\n"
    "descriptions deliberately and revisit this guard in the same commit."
)


class ThreatPolicyError(AssertionError):
    """The combat policy could not be read, so the guard has no expectation."""


class SyncRunError(AssertionError):
    """The Workshop script did not complete, so its output proves nothing."""


# ---------------------------------------------------------------------------
# Side 1: the combat policy, read out of the shipped module.
# ---------------------------------------------------------------------------
def strip_lua_comments(src: str) -> str:
    """Remove Lua block and line comments.

    ``AutoPilot_Threat.lua`` carries a long header explaining *why* it cannot
    fight, so the words this module hunts for are all over its prose.  Comments
    are stripped before any intent is extracted; control F pins the difference.
    """
    src = re.sub(r"(?s)--\[\[.*?\]\]", "", src)
    return re.sub(r"(?m)--.*$", "", src)


def engagement_intents(source: str) -> set[str]:
    """Return the set of intents ``_decideEngagement`` can return.

    Raises rather than returning an empty set: a guard that cannot find the
    function or its returns has gone blind, and blindness must never read the
    same as "no combat here".
    """
    body_match = DECIDE_FN.search(strip_lua_comments(source))
    if body_match is None:
        raise ThreatPolicyError(
            "could not find `local function _decideEngagement(...)` in the threat\n"
            "module, so the combat policy cannot be read.  If the function was\n"
            "renamed or moved, update this guard in the same commit -- it must not\n"
            "silently stop checking.\n" + FIX_HINT
        )
    intents = {intent for intent, _reason in INTENT_RETURN.findall(body_match.group(0))}
    if not intents:
        raise ThreatPolicyError(
            "found _decideEngagement but extracted ZERO `return \"intent\", "
            '"reason"` statements from its body.  The guard cannot see its input '
            "and must fail rather than report flee-only.\n" + FIX_HINT
        )
    return intents


def is_flee_only(source: str) -> bool:
    """True when every engagement branch resolves to a flee."""
    return engagement_intents(source) == {"flee"}


# ---------------------------------------------------------------------------
# Side 2: what the player-facing descriptions claim.
# ---------------------------------------------------------------------------
def split_sentences(text: str) -> list[str]:
    """Split on sentence terminators.

    Sentence scope is the unit that separates a promise from a disclaimer:
    "It never fights" and "the mod fights" differ by a word that a line-level or
    file-level scan would happily find somewhere else in the paragraph.
    """
    return [s for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]


def description_text(source: str) -> list[str]:
    """Return the body of every ``description=`` line in ``source``."""
    out: list[str] = []
    for line in source.splitlines():
        match = DESCRIPTION_LINE.match(line)
        if match is not None:
            out.append(match.group(1))
    return out


def is_negated(sentence: str, verb_start: int) -> bool:
    """True when a negation actually governs the combat verb at ``verb_start``.

    Read backwards from the verb, stop at the nearest clause boundary, and look
    for a negation in the last :data:`NEGATION_WINDOW_WORDS` words of what is
    left.  "It never fights" qualifies; "not a full autopilot: ... and fights"
    does not, because the colon and the commas put the negation in another
    clause about another subject.
    """
    prefix = sentence[:verb_start]
    clause = CLAUSE_BREAK.split(prefix)[-1]
    window = clause.split()[-NEGATION_WINDOW_WORDS:]
    return any(NEGATION.fullmatch(word.strip(".!?\"'")) for word in window)


def combat_verb_occurrences(source: str) -> tuple[list[str], list[str]]:
    """Split every combat mention in ``source`` into promises and disclosures.

    Returns ``(promises, disclosures)``, each a list of the sentences the
    mention was found in.  One pass, two answers, so the "does it promise" and
    "does it disclose" questions can never drift apart in how they read text.
    """
    promises: list[str] = []
    disclosures: list[str] = []
    for body in description_text(source):
        for sentence in split_sentences(body):
            for match in COMBAT_VERB.finditer(sentence):
                target = disclosures if is_negated(sentence, match.start()) else promises
                target.append(sentence.strip())
    return promises, disclosures


def combat_claims(source: str) -> list[str]:
    """Return every description sentence that PROMISES combat."""
    return combat_verb_occurrences(source)[0]


def has_combat_disclosure(source: str) -> bool:
    """True when some description sentence explicitly denies combat."""
    return bool(combat_verb_occurrences(source)[1])


def tracked_player_facing_files() -> list[Path]:
    """Every tracked file that describes the mod to players.

    Glob-discovered from ``git ls-files`` rather than hand-listed: the payload
    has carried two ``mod.info`` files since Build 42 split the media root, and
    a third one appearing is precisely the case a hand list would miss while
    still reporting green.
    """
    proc = subprocess.run(
        ["git", "ls-files"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:  # pragma: no cover - git is present in CI and locally
        raise AssertionError(
            "git ls-files failed, so the player-facing corpus cannot be "
            "enumerated.  A guard that cannot see its input must fail rather "
            "than report clean.\n" + proc.stderr
        )
    found: list[Path] = []
    for line in proc.stdout.splitlines():
        rel = line.strip()
        if not rel:
            continue
        if Path(rel).name == "mod.info" or rel == "sync_workshop.sh":
            found.append(ROOT / rel)
    return sorted(found)


# ---------------------------------------------------------------------------
# Side 3: what the script actually WRITES.
# ---------------------------------------------------------------------------
def _require_bash() -> str:
    """Return the bash to run the script with, or fail loudly.

    Same rule as ``tests/test_release_gate.py``: a missing bash on a POSIX
    runner is a broken CI environment, not a reason to pass.  Windows dev boxes
    without Git Bash on PATH are the only sanctioned skip.
    """
    if BASH:
        return BASH
    if sys.platform == "win32":
        raise unittest.SkipTest(
            "bash is not on PATH (Windows dev box). CI runs these on ubuntu-latest."
        )
    raise AssertionError(
        "bash not found on a POSIX runner: the Workshop description tests must "
        "not skip in CI."
    )


def run_sync(home: Path, script: Path) -> subprocess.CompletedProcess[str]:
    """Run ``script`` with ``home`` as ``$HOME``, or raise UNVERIFIED.

    Two deliberate details:

    * ``HOME`` and the script path are passed with FORWARD slashes.  Under Git
      Bash a Windows-style path reaches the script as a string full of
      backslashes, which bash reads as escapes -- the failure looks like a file
      that does not exist rather than like a bad path.
    * The verdict is taken from the EXIT CODE.  A script that died writes no
      ``workshop.txt``, and "no claim found in a file that does not exist" is
      byte-identical to "no claim found in a clean file".
    """
    env = dict(os.environ)
    env["HOME"] = home.as_posix()
    proc = subprocess.run(
        [_require_bash(), script.as_posix()],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(ROOT),
        check=False,
    )
    if proc.returncode != 0:
        raise SyncRunError(
            f"{script.name} exited {proc.returncode}, so nothing it did or did "
            "not write is evidence about the Workshop description.\n"
            f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
        )
    return proc


def staged_workshop_txt(home: Path) -> Path:
    return home / STAGING_REL / "workshop.txt"


# ---------------------------------------------------------------------------
# The live gate.
# ---------------------------------------------------------------------------
class TestThreatModuleIsFleeOnly(unittest.TestCase):
    """The side of the agreement that the descriptions have to match."""

    def test_the_policy_can_be_read_at_all(self) -> None:
        intents = engagement_intents(THREAT_LUA.read_text(encoding="utf-8"))
        self.assertGreaterEqual(
            len(intents),
            1,
            "no engagement intent could be extracted from _decideEngagement.",
        )

    def test_every_branch_resolves_to_a_flee(self) -> None:
        intents = engagement_intents(THREAT_LUA.read_text(encoding="utf-8"))
        self.assertEqual(
            {"flee"},
            intents,
            f"_decideEngagement can now return {sorted(intents)!r}.  If combat "
            "became possible this is a product event and the player-facing "
            "descriptions must be revisited in the same commit.\n" + FIX_HINT,
        )

    def test_the_deleted_fight_helpers_have_not_come_back(self) -> None:
        source = strip_lua_comments(THREAT_LUA.read_text(encoding="utf-8"))
        for helper in ("doFight", "forceFight"):
            self.assertNotRegex(
                source,
                rf"function\s+AutoPilot_Threat\.{helper}\b",
                f"AutoPilot_Threat.{helper} is back.  It was deleted in PR #74 "
                "because walking a character toward a zombie it cannot hit is "
                "how the V5.6 smoke test ended in action=dead.\n" + FIX_HINT,
            )


class TestPlayerFacingDescriptionsMatchThePolicy(unittest.TestCase):
    """The live claim: three files, checked against the module above."""

    def setUp(self) -> None:
        self.corpus = tracked_player_facing_files()
        self.flee_only = is_flee_only(THREAT_LUA.read_text(encoding="utf-8"))

    def test_the_corpus_is_not_short(self) -> None:
        """A corpus that silently shrank would report clean forever."""
        names = sorted(p.relative_to(ROOT).as_posix() for p in self.corpus)
        self.assertGreaterEqual(
            len(self.corpus),
            3,
            "expected at least both mod.info files and sync_workshop.sh in the "
            f"player-facing corpus; git ls-files yielded {names!r}.",
        )
        self.assertIn("mod.info", names)
        self.assertIn("42/mod.info", names)
        self.assertIn("sync_workshop.sh", names)

    def test_every_corpus_file_actually_has_descriptions(self) -> None:
        """Zero description lines means the scan below inspects nothing."""
        for path in self.corpus:
            with self.subTest(file=path.name):
                bodies = description_text(path.read_text(encoding="utf-8"))
                self.assertGreater(
                    len(bodies),
                    0,
                    f"{path.relative_to(ROOT).as_posix()} has no description= "
                    "line, so the claim scan reads an empty input there.",
                )

    def test_no_description_promises_combat(self) -> None:
        self.assertTrue(self.flee_only, "policy is not flee-only; see the sibling test")
        offenders: dict[str, list[str]] = {}
        for path in self.corpus:
            claims = combat_claims(path.read_text(encoding="utf-8"))
            if claims:
                offenders[path.relative_to(ROOT).as_posix()] = claims
        self.assertEqual(
            {},
            offenders,
            f"player-facing descriptions promise combat: {offenders!r}\n" + FIX_HINT,
        )

    def test_every_description_discloses_that_it_does_not_fight(self) -> None:
        """Removing the promise is half the fix; saying so is the other half."""
        self.assertTrue(self.flee_only, "policy is not flee-only; see the sibling test")
        missing = [
            path.relative_to(ROOT).as_posix()
            for path in self.corpus
            if not has_combat_disclosure(path.read_text(encoding="utf-8"))
        ]
        self.assertEqual(
            [],
            missing,
            f"these player-facing descriptions never tell the player the mod "
            f"does not fight: {missing!r}.  A player choosing to install decides "
            "on this text, and the expectation gap has already been reported "
            "once as a bug.\n" + FIX_HINT,
        )


class TestTheGeneratedWorkshopListing(unittest.TestCase):
    """The half a source scan cannot reach: the bytes the script writes."""

    def test_a_fresh_staging_folder_gets_an_honest_description(self) -> None:
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            run_sync(home, SYNC_SCRIPT)
            staged = staged_workshop_txt(home)
            self.assertTrue(
                staged.is_file(),
                "sync_workshop.sh reported success but wrote no workshop.txt.",
            )
            text = staged.read_text(encoding="utf-8")
            self.assertEqual(
                [],
                combat_claims(text),
                "the workshop.txt generated from the embedded template promises "
                f"combat: {combat_claims(text)!r}\n" + FIX_HINT,
            )
            self.assertTrue(
                has_combat_disclosure(text),
                "the generated Workshop listing never tells the player the mod "
                "does not fight.\n" + FIX_HINT,
            )

    def test_a_preexisting_stale_listing_is_NOT_silently_fixed(self) -> None:
        """The documented second-order trap, asserted in the true direction.

        Only the version line is auto-synced.  A ``workshop.txt`` that already
        exists keeps every other ``description=`` line byte for byte, so editing
        the template does NOT reach an already-published item -- that is how V5.0
        shipped a release still advertising "maintains window barricades".  This
        test pins the trap so the reminder can never be dropped as redundant.
        """
        stale_claim = (
            "description=[b]Survival fail-safe:[/b] eats, drinks, sleeps, "
            "bandages, and fights or flees when zombies actually threaten.\n"
        )
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            staged = staged_workshop_txt(home)
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_text(
                "version=1\nid=3767254910\ntitle=AutoPilot Leveler\n"
                + stale_claim
                + "description=Build 42.19.0 Unstable. Source: "
                "https://github.com/rodmen07/auto-pilot-pz\n"
                "tags=Build 42;Multiplayer;QualityOfLife\nvisibility=public\n",
                encoding="utf-8",
            )

            proc = run_sync(home, SYNC_SCRIPT)

            after = staged.read_text(encoding="utf-8")
            self.assertNotEqual(
                [],
                combat_claims(after),
                "a pre-existing workshop.txt carrying the old combat promise was "
                "silently rewritten.  If sync_workshop.sh gained the ability to "
                "update non-version description lines that is a real improvement "
                "-- but it changes what the staleness reminder is for, so update "
                "this test and the reminder together.",
            )
            self.assertIn(
                "id=3767254910",
                after,
                "the published item id must survive the run untouched.",
            )
            self.assertIn(
                "REMINDER",
                proc.stdout,
                "a stale pre-existing workshop.txt was left carrying a false "
                "capability claim and the script said nothing.  The reminder is "
                "the only thing standing between a template edit and a Workshop "
                "listing that never receives it.",
            )
            self.assertIn(
                "re-run this script to regenerate",
                proc.stdout,
                "the reminder must name the delete-and-regenerate fix, because "
                "that is the only way a corrected description reaches an "
                "already-published item.",
            )


# ---------------------------------------------------------------------------
# Negative controls.
# ---------------------------------------------------------------------------
#: Control A: the real sentence, verbatim, as it shipped for two weeks.
PRE_FIX_MOD_INFO = (
    "name=AutoPilot Leveler\n"
    "id=AutoPilot\n"
    "description=Auto-exercise leveler for Build 42. While training, survival "
    "acts as a FAIL-SAFE, not a full autopilot: eats, drinks, sleeps, bandages "
    "wounds, and fights or flees when zombies actually threaten (distant "
    "wanderers are ignored). Multiplayer compatible.\n"
    "modversion=0.2.1\n"
)

#: Control B: no combat verb anywhere in its ``description=`` source, yet it
#: writes the promise.  The claim is assembled from a variable, which is the
#: only shape a real second home ever takes.
COMPOSING_SYNC_SCRIPT = """#!/usr/bin/env bash
set -euo pipefail
STAGING="${HOME}/Zomboid/Workshop/AutoPilotLeveler"
mkdir -p "${STAGING}"
VERB_ONE="fig""hts"
VERB_TWO="fl""ees"
cat > "${STAGING}/workshop.txt" <<EOF
version=1
id=
title=AutoPilot Leveler
description=[b]Survival fail-safe:[/b] eats, drinks, sleeps, bandages, and \
${VERB_ONE} or ${VERB_TWO} when zombies actually threaten.
visibility=public
EOF
echo "wrote ${STAGING}/workshop.txt"
"""

#: Control C: one branch resolves to combat again.
FIGHTING_THREAT_MODULE = """
local function _decideEngagement(player, zombies)
    if _criticalWound(player) then
        return "flee", "flee_wounded", dx, dy
    end
    if #zombies < 2 then
        return "fight", "fight_outnumbering", escDx, escDy
    end
    return "flee", "flee_default", escDx, escDy
end
"""

#: Control D: the function is there but its returns are not the shape the guard
#: knows, so the intent set comes back empty.
UNREADABLE_THREAT_MODULE = """
local function _decideEngagement(player, zombies)
    local decision = _resolve(player, zombies)
    return decision.intent, decision.reason
end
"""

#: Control E: a script that fails.  It creates the staging folder first, so a
#: guard reading "did a claim appear" would find a clean absence.
FAILING_SYNC_SCRIPT = """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${HOME}/Zomboid/Workshop/AutoPilotLeveler"
echo "could not read mod.info" >&2
exit 3
"""


class TestControlsOnTheClaimScan(unittest.TestCase):
    """Proof the description scan can fire, and is not merely lucky."""

    def test_control_a_the_pre_fix_sentence_is_caught(self) -> None:
        claims = combat_claims(PRE_FIX_MOD_INFO)
        self.assertNotEqual(
            [],
            claims,
            "the claim scan did not fire on the exact sentence that shipped for "
            "two weeks.  The guard is blind.",
        )
        self.assertIn("fights or flees", claims[0])
        self.assertFalse(
            has_combat_disclosure(PRE_FIX_MOD_INFO),
            "the pre-fix text must not count as having disclosed anything; if it "
            "did, the disclosure requirement would have passed on the bug too.",
        )

    def test_the_far_negation_that_defeated_the_first_version(self) -> None:
        """Why the negation window exists, pinned so it cannot be widened away.

        The shipped sentence carries *"not a full autopilot"* twelve words and
        one colon in front of *"fights"*.  A sentence-level negation test reads
        that as a disclaimer and passes the defect -- which is exactly what the
        first draft of this module did, until control A caught it.  This control
        keeps a future simplification from reintroducing it.
        """
        far = (
            "description=Survival acts as a FAIL-SAFE, not a full autopilot: "
            "eats, drinks, and fights or flees when zombies threaten.\n"
        )
        self.assertRegex(far, NEGATION)
        self.assertNotEqual(
            [],
            combat_claims(far),
            "a negation in another clause was allowed to excuse the combat "
            "promise.  The window in is_negated() is load-bearing.",
        )
        near = "description=The mod does not fight zombies.\n"
        self.assertEqual([], combat_claims(near))
        self.assertTrue(has_combat_disclosure(near))

    def test_the_corrected_sentence_is_clean(self) -> None:
        """The disclaimer USES the word, so a token ban would redden the fix."""
        corrected = PRE_FIX_MOD_INFO.replace(
            "and fights or flees when zombies actually threaten",
            "and flees when zombies actually threaten",
        ).replace(
            "(distant wanderers are ignored).",
            "(distant wanderers are ignored). It never fights: Build 42 gives an "
            "AI-driven character no way to swing a weapon.",
        )
        self.assertEqual([], combat_claims(corrected))
        self.assertTrue(
            has_combat_disclosure(corrected),
            "the corrected text must still register as an explicit disclosure.",
        )

    def test_a_bare_token_ban_would_have_reddened_the_correct_text(self) -> None:
        """Why the scan is sentence-scoped, pinned as a control.

        This is the assertion that stops a future simplification from replacing
        the sentence walk with ``assertNotIn("fights", text)``.
        """
        honest = "It never fights: Build 42 gives it no way to swing a weapon."
        self.assertRegex(honest, COMBAT_VERB)
        self.assertEqual([], combat_claims(f"description={honest}\n"))

    def test_dropping_the_disclaimer_is_caught(self) -> None:
        silent = "description=Eats, drinks, sleeps and bandages wounds.\n"
        self.assertEqual([], combat_claims(silent), "no promise is made here")
        self.assertFalse(
            has_combat_disclosure(silent),
            "a description that never mentions combat must not count as having "
            "disclosed it; otherwise deleting the disclaimer passes.",
        )


class TestControlsOnThePolicyRead(unittest.TestCase):
    """Proof the expectation is derived from the module, not baked in."""

    def test_control_c_a_fight_intent_flips_the_policy(self) -> None:
        intents = engagement_intents(FIGHTING_THREAT_MODULE)
        self.assertIn("fight", intents)
        self.assertFalse(
            is_flee_only(FIGHTING_THREAT_MODULE),
            "a module that can return a fight intent was still read as "
            "flee-only, so the guard's expectation is hardcoded rather than "
            "derived and would keep demanding a no-combat disclaimer forever.",
        )

    def test_control_d_a_missing_function_raises(self) -> None:
        with self.assertRaises(ThreatPolicyError):
            engagement_intents("local function _somethingElse() end\n")

    def test_control_d_unreadable_returns_raise(self) -> None:
        with self.assertRaises(ThreatPolicyError):
            engagement_intents(UNREADABLE_THREAT_MODULE)

    def test_control_f_comments_produce_phantom_combat_matches(self) -> None:
        """The phantom the scoped, comment-stripped read does not produce."""
        raw = THREAT_LUA.read_text(encoding="utf-8")
        self.assertRegex(
            raw,
            COMBAT_VERB,
            "the threat module no longer explains why it cannot fight; if the "
            "header was rewritten, re-check that this control still has a "
            "phantom to demonstrate.",
        )
        self.assertNotIn(
            "fight",
            " ".join(engagement_intents(raw)),
            "the extracted intents picked up a word that only ever appears in "
            "prose.  Scoping to the function body and stripping comments is what "
            "keeps this guard from reporting garbage.",
        )


class TestControlsOnTheGeneratedListing(unittest.TestCase):
    """Proof that running the script is load-bearing, not decoration."""

    def test_control_b_passes_the_text_scan_and_still_ships_the_promise(self) -> None:
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            script = home / "composing_sync.sh"
            script.write_text(COMPOSING_SYNC_SCRIPT, encoding="utf-8")

            # Half one: the cheap clause is genuinely satisfied.  Asserted, not
            # assumed -- this is the state a text-only guard would bless.
            self.assertEqual(
                [],
                combat_claims(script.read_text(encoding="utf-8")),
                "control B was supposed to slip past the source scan.  It no "
                "longer does, so it has stopped proving the run is load-bearing "
                "-- reshape it.",
            )

            # Half two: the behaviour is broken anyway.
            run_sync(home, script)
            produced = staged_workshop_txt(home).read_text(encoding="utf-8")
            self.assertNotEqual(
                [],
                combat_claims(produced),
                "the run-scan did not fire on a script that composes the combat "
                "promise into workshop.txt from a variable.  A source-only guard "
                "would certify this listing as honest, which is exactly the "
                "failure this control exists for.",
            )

    def test_control_e_a_failing_script_is_UNVERIFIED_not_clean(self) -> None:
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            script = home / "failing_sync.sh"
            script.write_text(FAILING_SYNC_SCRIPT, encoding="utf-8")
            with self.assertRaises(SyncRunError) as caught:
                run_sync(home, script)
            self.assertIn("exited 3", str(caught.exception))
            # The staging folder exists and holds no workshop.txt at all, which
            # is the state a scan-for-claims check would read as "clean".
            self.assertFalse(staged_workshop_txt(home).exists())


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
