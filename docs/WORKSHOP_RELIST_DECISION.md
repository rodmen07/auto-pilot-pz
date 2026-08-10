# AutoPilot: Steam Workshop Relist Decision

> **STATUS: DECIDED 2026-08-10 by the owner — D1 = OPTION B, "stay delisted". The default (C)
> was OVERRIDDEN.** Workshop item 3767254910 is now **deliberately retired**, not parked pending
> a relist: GitHub Releases is the only distribution channel, by decision rather than by neglect.
>
> **D2 and D3 are MOOT and are answered by D1 rather than separately.** Both govern an upload —
> D2 whether the first upload is gated on a passing in-game smoke test, D3 which build it carries
> — and under option B there is no upload, ever. They are left below unedited as the record of
> what was weighed; they are not open questions and no future run should treat them as pending.
>
> **What option B changes, per its own text:** the two backlog items that named this brief as
> their clearing condition become dated decision records ("listing deliberately retired") rather
> than blocked work; the standing "needs in-game smoke test before Workshop update" flag loses
> its DISTRIBUTION half; and future release cuts are complete in themselves, with no owed
> Workshop step trailing them. The item's existing subscribers and comment history stay
> permanently parked — that was named as the cost of B when it was offered, and it is accepted.
>
> **What it does NOT change:** the in-game verification gap is untouched. Nothing in this project
> is verifiable in-game headlessly (CI runs luacheck plus pytest only), so dev PRs still carry the
> smoke-test flag as a QUALITY statement. What ended is only the obligation for that flag to clear
> before players receive something — because players no longer receive anything through Steam.
>
> Original status line, preserved: *"PROPOSED 2026-08-09, AWAITING USER DECISION. Every choice
> below carries an overridable default, so 'approve with defaults' is a complete answer (as is a
> per-decision answer like 'D1 option B' or 'approve, but skip the gate'). This brief decides
> nothing by itself: relisting is a product call the backlog has recorded as the user's since
> 2026-08-08, and this document exists to bring that call as a concrete question instead of
> leaving it parked. It is the distribution companion to `docs/EXPANSION_PROPOSAL_V6_3.md`
> (features, separately pending), whose section 7 deliberately scopes Workshop action out."*

## 1. Why this decision is due

The 2026-07-24 revival reversed every decommission-era act except one. The GitHub repo was
unarchived (2026-07-24, by the user), the README's deprecation banner was replaced with an
accurate revival note (PR #138), releases resumed (`v0.2.0` 2026-08-05, `v0.2.1` 2026-08-08 —
`gh release list` verified 2026-08-09), and all four streams have shipped 80+ PRs since. The
one act never reversed is the **Workshop delisting of 2026-07-21**: item 3767254910 is still
not publicly reachable, so the project's only player-facing distribution channel is dead while
every other surface advertises an active project.

Two backlog items block on exactly this call and say so in their clearing conditions:

- the PR #140 follow-up ("the correction has reached the REPO, not the published Steam
  listing, and only an upload closes that gap"), and
- the PR #134 decision record ("CLEARS WHEN the user decides whether to relist the Workshop
  item — relisting is a product call, and re-listing plus uploading is the increment where
  running the script actually buys something").

Leaving it undecided has a concrete cost in both directions: every release cut reaches only
GitHub visitors (the honest sentence `ROADMAP.md` now carries: cutting a release "still
reaches nobody who installs from the Workshop"), and the delisted page contradicts the revived
README for anyone who follows the Workshop id from the mod's own history.

## 2. The facts, each re-verified live 2026-08-09 (none inherited)

1. **The item is not publicly reachable.** `curl -s -L
   "https://steamcommunity.com/sharedfiles/filedetails/?id=3767254910"` returns HTTP 200 with
   Steam's error page: *"There was a problem accessing the item."* This probe cannot
   distinguish owner-delisted from deleted; the recorded cause is the 2026-07-21 delisting
   (`ROADMAP.md`, "Repo state" paragraph). If the item turns out to be deleted rather than
   hidden, D1's default still works — the in-game flow can publish a fresh item — but the id,
   its subscribers, and its comment history would be gone; the user can see which it is from
   their Workshop items page, which the agent cannot.
2. **What the frozen listing says is now known to overpromise.** The published build is the
   V3.3 upload of 2026-07-18 — the leveler-identity era, three identities and 80+ PRs behind
   `main` (`modversion=0.2.1` in both `mod.info` files). PR #140 established that the
   pre-correction description tells players the mod *"fights or flees"* when the shipped code
   has been flee-only since PR #74; the repo-side template is corrected and guarded
   (`tests/test_combat_claim_truth.py`), but `sync_workshop.sh` only writes the LOCAL staging
   folder, so no correction has reached Steam. **Relisting without uploading would therefore
   re-publish a combat claim the repo has already retracted.** This is what rules out D1
   option A as the default.
3. **The upload is the user's act for a mechanical reason, not a permission.** Publishing is
   delegated in full as of 2026-08-08, `sync_workshop.sh` included. The "Update Item" upload
   is a PZ main-menu flow with no CLI path anywhere in this tree; `tests/test_workshop_boundary.py`
   binds that capability claim so the day it changes is loud. Staging
   (`./sync_workshop.sh`) is agent-doable, and because `~/Zomboid/Workshop/AutoPilotLeveler/`
   does not exist on this machine (verified by PR #140's run and end-to-end by its guard), the
   next run regenerates `workshop.txt` fully from the corrected template — the V5.0
   stale-listing incident cannot recur on this path.
4. **Current `main` carries no in-game verification.** The last smoke test (2026-08-01)
   covered V6.0-era code and cleared the `v0.2.0` release. Everything since is unexercised in
   game, including the `v0.2.1` window's four user-visible evade/flee fixes (PRs #120, #122,
   #123, #129) and V6.2's C1/C2. CI here is luacheck plus pytest; no automated gate has ever
   run this code in the game. Uploading it sight-unseen is permitted under the 2026-08-08
   delegation — and would have to be reported as exactly that.
5. **The session that would clear the gate is already owed for other reasons.**
   `docs/EXPANSION_PROPOSAL_V6_3.md` section 6 holds the one in-game session's shopping list
   (V6.2-C3 gate, V6.1-1 exercise share, the MED verification-gap trigger states, two
   USER-ONLY reads, the D4 stash question, the `getStressChange` print). A smoke pass over
   the evade/flee fixes is one more item on the same session, not a new session.

## 3. Decision menu

### D1 — What happens to Workshop item 3767254910

- **Option A — relist now, as-is.** Fastest, and rejected as the default on fact 2: it
  re-exposes a three-identity-old build under a listing whose combat claim the repo just
  spent a PR retracting. Nothing else in this brief makes sense before that text is replaced.
- **Option B — stay delisted; GitHub releases become the only channel, deliberately.**
  Honest and cheap, and the right answer if the mod is now personal-use. Choosing it converts
  the two blocked backlog items into dated decision records ("listing deliberately retired"),
  ends the "needs in-game smoke test before Workshop update" flag's distribution half, and
  makes future release cuts complete in themselves. It also leaves the id's subscribers and
  comment history permanently parked.
- **Option C — relist and upload as ONE act, gated on the owed smoke test. DEFAULT.** The
  listing and the build go public together, so the store page never shows the stale combat
  claim again: the first thing a returning subscriber sees is the corrected flee-only
  description with a version line matching a tagged release. Sequencing in section 4.

**Default: C.** Clearing condition for the whole brief: the user answers, or names a
different option; silence ships nothing (unlike a defaults-approved feature proposal, this
one's final step is physically the user's, so "silence means defaults" cannot execute it).

### D2 — The gate: does the first upload require a passing in-game smoke test?

- **Default: YES.** The upload may proceed without it under the 2026-08-08 delegation, but
  fact 4 is the sharp edge: the first thing players would receive after a three-week silence
  would be code no gate has ever exercised in the game. The gate costs nothing extra because
  the session is already owed (fact 5).
- Overridable to NO ("upload current `v0.2.1` sight-unseen") — the run that stages it must
  then state, in its report and per SKILL.md, that the build carries no in-game verification
  and name what the skipped smoke test would have covered: the four evade/flee fixes, the
  V6.2 moodle-aligned triggers, and the malus-aware eat/loot paths under real play.

### D3 — Which build the upload carries

- **Default: the newest tagged release whose tree the smoke session exercised.** If the
  session runs on current `main` (`v0.2.1`, `c795f0f` at the time of writing) and passes, the
  upload carries `v0.2.1` and no new cut is needed. If `main` has moved past the smoke-tested
  commit by then, the choice is the smoke-tested tag (safe, slightly stale) — cutting a fresh
  release of unsmoked newer code and uploading that would reopen D2.

## 4. Sequencing under the defaults (who does what) — SUPERSEDED 2026-08-10, NOT EXECUTED

> **None of the four steps below will happen.** They sequence D1's default (option C, relist and
> upload as one act); the owner chose option B, so there is no smoke session owed for
> distribution, no `sync_workshop.sh` run, no Create/Update Item act, and no aftercare probe of a
> public page. Kept verbatim as the record of what option C would have cost, which is part of why
> B was chosen. Do not execute it.

1. **User:** the owed in-game session (shopping list: V6.3 section 6, plus the evade/flee
   smoke items above). Pass/fail comes back as a user report, as on 2026-08-01.
2. **Agent, on a pass:** run `./sync_workshop.sh` — regenerates staging from the corrected
   template; verify the generated `workshop.txt` carries the corrected description and the
   `Mod version: 0.2.1` line (the existing guard already proves this end to end).
3. **User:** PZ Main Menu → Workshop → Create/Update Item → AutoPilotLeveler (the one no-CLI
   act), and set visibility back to public in the same sitting — one act, per D1's default.
4. **Agent, aftercare:** re-probe the public page and confirm the live listing text no longer
   promises combat and states the uploaded version; check both blocked backlog items off with
   this evidence; the run report states the in-game verification status either way.

## 5. What this brief deliberately does not decide

- **V6.3's candidates** — separately pending in `docs/EXPANSION_PROPOSAL_V6_3.md`; nothing
  here depends on any of them.
- **Workshop comment handling** — reading and answering comments stays user-only standing
  (`ROADMAP.md`), and relisting will eventually produce comments; that standing line is
  unchanged.
- **The B42.20 migration** — separate USER-ONLY decision with its own checklist
  (`docs/b42_20_checklist.md`); an upload under the defaults ships a B42.19-verified build.
- **No guard ships with this doc.** Like the expansion proposals, a decision brief is spent
  the moment it is decided; binding its prose to a truth test would guard a document whose
  correct end state is "superseded" (the `tests/test_roadmap_truth.py` line: guard what
  changes on a deliberate dated decision, audit what changes as a side effect — this file IS
  the deliberate dated decision, and the backlog records its outcome).
