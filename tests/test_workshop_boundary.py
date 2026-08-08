"""Truth guard for the Steam Workshop boundary claim in ``ROADMAP.md``.

WHY THIS EXISTS
---------------
Until 2026-08-08, nine documents in this repository asserted that Steam Workshop
uploads and ``sync_workshop.sh`` were **USER-ONLY, permanently** -- several of
them in sections that GATE work (``ROADMAP.md``'s "User-only (standing)" list,
V6.1's and V6.3's non-goals, ``docs/b42_20_checklist.md``'s "Done when", and
ground 3 of the V6.0 release hold).  A user decision on 2026-08-08 widened
publishing across every project and named this project's Workshop uploads and
``sync_workshop.sh`` explicitly, which falsified all nine at once.

Correcting them to a bare "delegated" would have replaced one false claim with
another, because **the permission was never the only thing in the way**.  The
audit that retired the fence found two acts fused into one line:

* ``./sync_workshop.sh`` refreshes a LOCAL staging folder.  It is a file copy
  plus an in-place version-line rewrite of ``workshop.txt``.  It uploads
  nothing and opens no socket.  The agent can run it.
* The "Update Item" upload is a Project Zomboid main-menu flow.  There is no
  CLI for it and this repository contains no upload mechanism at all, so the
  agent cannot perform it -- a CAPABILITY limit, not a permission.

Those two decay differently, which is the whole reason this module exists.  A
lifted rule stays lifted; a missing capability is falsified the moment somebody
adds ``steamcmd`` to the tree.  This guard makes that day loud instead of
silent, so the roadmap's table cannot quietly become the next stale claim.

WHAT IS GUARDED
---------------
1. ``sync_workshop.sh`` exists and performs no upload (no named publishing tool,
   no network egress of any kind).
2. No other tracked executable surface performs one either.
3. ``ROADMAP.md`` still states the claim, bound to an anchor that must match
   EXACTLY ONCE.

WHY THE ANCHOR IS STRICT (the ``tests/test_roadmap_truth.py`` rule, restated)
-----------------------------------------------------------------------------
``ROADMAP.md`` deliberately contains false sentences: this project's convention
is to quote superseded prose verbatim where it stood so a wrong correction stays
recoverable by grep.  The file therefore now carries the retired fence -- *"Steam
Workshop "Update Item" uploads and ``sync_workshop.sh`` runs."* -- as a tombstone
inside the very section that retires it.  A loose scan would match that tombstone
and redden a CORRECT document, so the live claim gets a narrow anchor, and the
tombstone it must not match is pinned below as a committed control.

WHY THE NEGATIVE CONTROLS ARE SHAPED THE WAY THEY ARE
-----------------------------------------------------
The upload scan is a token sweep over source text, and a token sweep is
satisfiable by a comment -- it is an existence search wearing a test's clothes.
So there are two controls, and the second is the one that matters:

* Control A is the obvious one: a script invoking ``steamcmd
  +workshop_build_item`` must FIRE the named-tool arm.
* Control B is shaped to **satisfy the cheap clause while breaking the
  behaviour**: a script that contains no named publishing tool anywhere -- so it
  passes the token arm cleanly -- but uploads the payload with ``curl`` against
  Steam's own endpoint.  If the generic network arm were dropped or went blind,
  control B would pass and this guard would certify an uploader as
  upload-free.

PARSE AS TEXT, like the sibling guards: no game, no network, no Steam.
"""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent

ROADMAP = ROOT / "ROADMAP.md"
SYNC_SCRIPT = ROOT / "sync_workshop.sh"

#: This module quotes every pattern it hunts for, so it matches itself by
#: construction and is the one file excluded from the corpus.  The exclusion is
#: asserted to resolve to a real file, so a rename cannot silently widen it into
#: "exclude nothing" or narrow the corpus by accident.
SELF = Path(__file__).resolve()

#: Extensions that could actually execute an upload.  Markdown is excluded on
#: purpose and it is not a hole: prose cannot invoke Steam, and the docs quote
#: these very tokens while describing the boundary.
EXECUTABLE_SUFFIXES = {".sh", ".py", ".yml", ".yaml", ".lua", ".ps1", ".bat", ".cmd"}

#: Arm 1 -- the named publishing tools and Workshop APIs.  Any one of these in
#: an executable surface means an upload path exists.
NAMED_UPLOAD_TOOLS = re.compile(
    r"steamcmd|workshop_build_item|workshop_upload|publishedfileid|ISteamUGC|steam_api",
    re.IGNORECASE,
)

#: Arm 2 -- generic network egress from the Workshop script.  This is the arm
#: control B exists to keep honest: an uploader that never spells "steamcmd"
#: still has to reach the network somehow.
NETWORK_EGRESS = re.compile(
    r"\bcurl\b|\bwget\b|Invoke-WebRequest|Invoke-RestMethod|\bnc\b|\bscp\b|\brsync\b|urllib|requests\.",
    re.IGNORECASE,
)

#: The live claim in ROADMAP.md.  Narrow enough that the tombstoned copy of the
#: retired fence, three lines above it in the same section, cannot match.
ANCHOR_NO_UPLOAD_PATH = (
    r"The upload is a Project Zomboid main-menu flow \(\*Workshop → Create/Update Item\*\)"
)

#: The tombstone the anchor must ignore, quoted from the real document.  If a
#: future edit deletes the tombstone the control fails and the convention has
#: been broken; if a future edit makes the anchor loose enough to match it, the
#: exactly-once assertion fails.  Both directions are covered.
#:
#: Deliberately NEWLINE-FREE.  ``ROADMAP.md`` is a CRLF file while this module
#: is LF, so a multi-line literal would compare ``\n`` against ``\r\n`` and this
#: control would fail on a correct document -- the same CRLF/LF mismatch that
#: made PR #130's first perturbation attempt silently match zero occurrences.
#: The quoted fence is therefore kept on ONE line in the roadmap.
TOMBSTONE = 'Steam Workshop "Update Item" uploads and `sync_workshop.sh` runs.'

FIX_HINT = (
    "The Workshop boundary claim in ROADMAP.md and the repository disagree.\n"
    "If an upload path was DELIBERATELY added, the roadmap's 'User-only\n"
    "(standing)' table is now wrong and must be corrected in the SAME commit --\n"
    "the whole point of this guard is that the capability limit is the only\n"
    "thing still keeping the agent off the Workshop, so gaining the capability\n"
    "is a product event, not a refactor."
)


class WorkshopAnchorError(AssertionError):
    """The anchor did not match exactly once, so the guard cannot see its input."""


def tracked_executable_files() -> list[Path]:
    """Every tracked file that could execute an upload, minus this module.

    Uses ``git ls-files`` rather than a filesystem walk so that untracked
    scratch files, build output and ``__pycache__`` cannot influence the
    verdict in either direction.
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
            "git ls-files failed, so the corpus cannot be enumerated.  A guard "
            "that cannot see its input must fail rather than report clean.\n"
            + proc.stderr
        )
    out: list[Path] = []
    for line in proc.stdout.splitlines():
        rel = line.strip()
        if not rel:
            continue
        path = ROOT / rel
        if path.suffix.lower() not in EXECUTABLE_SUFFIXES:
            continue
        if path.resolve() == SELF:
            continue
        out.append(path)
    return sorted(out)


def scan_for_upload(text: str, *, network_arm: bool) -> list[str]:
    """Return every upload indicator found in ``text``.

    ``network_arm`` is enabled only for the Workshop script itself: plenty of
    legitimate tooling in this repo talks to the network (CI actions fetch,
    the triage tooling reads files), so the generic arm is scoped to the one
    file whose whole claim is that it stays local.
    """
    hits = [m.group(0) for m in NAMED_UPLOAD_TOOLS.finditer(text)]
    if network_arm:
        hits += [m.group(0) for m in NETWORK_EGRESS.finditer(text)]
    return hits


def extract_claim(text: str, anchor: str, label: str) -> str:
    """Return the single match ``anchor`` makes in ``text``.

    Zero matches means the claim was reworded and the guard has gone blind;
    more than one means the anchor is no longer unique.  Both are hard
    failures, never a silent default.
    """
    matches = re.findall(anchor, text)
    if not matches:
        raise WorkshopAnchorError(
            f"ROADMAP.md Workshop guard has gone BLIND on '{label}': the anchor\n"
            f"  {anchor}\n"
            "matched ZERO times.  The claim was reworded, moved or deleted.\n" + FIX_HINT
        )
    if len(matches) > 1:
        raise WorkshopAnchorError(
            f"ROADMAP.md Workshop guard is AMBIGUOUS on '{label}': the anchor\n"
            f"  {anchor}\n"
            f"matched {len(matches)} times.  Two live homes for one claim drift\n"
            "apart with the guard still green.\n" + FIX_HINT
        )
    return matches[0]


# ---------------------------------------------------------------------------
# The live gate: the real repository.
# ---------------------------------------------------------------------------
class TestWorkshopUploadCapability(unittest.TestCase):
    """The claim "the agent cannot upload" checked against the tree, not a doc."""

    def test_sync_script_exists(self) -> None:
        self.assertTrue(
            SYNC_SCRIPT.is_file(),
            "sync_workshop.sh is gone.  ROADMAP.md's 'User-only (standing)' table "
            "describes it as the agent-doable half of publishing; if the script "
            "was removed, that table is now wrong.",
        )

    def test_sync_script_performs_no_upload(self) -> None:
        hits = scan_for_upload(
            SYNC_SCRIPT.read_text(encoding="utf-8"), network_arm=True
        )
        self.assertEqual(
            [],
            hits,
            "sync_workshop.sh now contains an upload or network indicator "
            f"({hits!r}).  ROADMAP.md claims it is a purely local staging refresh.\n"
            + FIX_HINT,
        )

    def test_no_tracked_executable_surface_can_upload(self) -> None:
        offenders: dict[str, list[str]] = {}
        for path in tracked_executable_files():
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            hits = scan_for_upload(text, network_arm=False)
            if hits:
                offenders[str(path.relative_to(ROOT))] = sorted(set(hits))
        self.assertEqual(
            {},
            offenders,
            "A Workshop upload mechanism now exists in the tree: "
            f"{offenders!r}.\n" + FIX_HINT,
        )

    def test_the_corpus_is_not_empty(self) -> None:
        """A guard whose corpus silently became empty reports clean forever."""
        corpus = tracked_executable_files()
        self.assertGreater(
            len(corpus),
            10,
            "git ls-files returned almost nothing, so the upload scan is "
            "inspecting an empty corpus and cannot fail.",
        )
        self.assertNotIn(SELF, [p.resolve() for p in corpus])


class TestNegativeControls(unittest.TestCase):
    """Proof that both arms of the scan can actually fire."""

    def test_control_a_named_tool_is_caught(self) -> None:
        """The obvious uploader: it spells the tool out."""
        control = (
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            'steamcmd +login "$USER" +workshop_build_item item.vdf +quit\n'
        )
        self.assertNotEqual(
            [],
            scan_for_upload(control, network_arm=False),
            "The named-tool arm did not fire on a script that literally invokes "
            "steamcmd +workshop_build_item.  The guard is blind.",
        )

    def test_control_b_satisfies_the_token_arm_but_still_uploads(self) -> None:
        """The control that keeps the generic arm honest (the L-033 shape).

        This script contains **no** named publishing tool, so the cheap token
        arm passes it cleanly -- asserted here rather than assumed, because
        that is the half a token-only guard would certify as upload-free -- yet
        it plainly uploads the staged payload.  Only the network arm catches
        it.
        """
        control = (
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "# ship the staged mod to the workshop item\n"
            'curl -X POST -F "file=@${STAGING}/payload.zip" \\\n'
            '     "https://partner.steam-api.com/IPublishedFileService/Update/v1/"\n'
        )
        self.assertEqual(
            [],
            scan_for_upload(control, network_arm=False),
            "Control B was supposed to slip past the named-tool arm.  It no "
            "longer does, so it has stopped proving that the network arm is "
            "load-bearing -- reshape it.",
        )
        self.assertNotEqual(
            [],
            scan_for_upload(control, network_arm=True),
            "The network arm did not fire on a script that POSTs the payload to "
            "Steam.  A token-only scan would certify this uploader as "
            "upload-free, which is exactly the failure this control exists for.",
        )


class TestRoadmapStatesTheClaim(unittest.TestCase):
    """The document half: the claim must be present, and present exactly once."""

    def test_anchor_matches_exactly_once(self) -> None:
        extract_claim(
            ROADMAP.read_text(encoding="utf-8"),
            ANCHOR_NO_UPLOAD_PATH,
            "no-CLI-upload-path",
        )

    def test_the_retired_fence_is_still_tombstoned(self) -> None:
        """The superseded wording stays quoted where it stood, per convention."""
        self.assertIn(
            TOMBSTONE,
            ROADMAP.read_text(encoding="utf-8"),
            "The retired 'Workshop uploads and sync_workshop.sh runs' fence is no "
            "longer quoted in ROADMAP.md.  This repo's convention is that a "
            "retracted claim stays grep-recoverable where it stood.",
        )

    def test_the_anchor_cannot_match_the_tombstone(self) -> None:
        """The control that proves the anchor is narrow, not merely lucky."""
        self.assertEqual(
            [],
            re.findall(ANCHOR_NO_UPLOAD_PATH, TOMBSTONE),
            "The live-claim anchor matches the tombstoned wording, so it would "
            "redden a correct document or silently read the dead claim.",
        )


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
