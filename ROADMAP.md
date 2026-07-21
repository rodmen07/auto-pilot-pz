# AutoPilot Leveler Roadmap

**Status:** Code and packaged builds are current through V5.8 (`mod.info` modversion 5.8, 2026-07-20; `CHANGELOG.md` is the authoritative shipped record). Workshop item 3767254910 was published at V3.3 on 2026-07-18; later Workshop updates are USER-ONLY (`sync_workshop.sh` plus in-game "Update Item") and not verifiable from this environment — confirm the live Workshop version in-game before assuming parity with the code.
> ## ⚠ IDENTITY PIVOT IN PROGRESS (2026-07-21) — read this before anything below
>
> **The mod is pivoting from "auto-exercise leveler" to "autonomous survival mod."** User
> directive, verbatim: *"There are already autotrainer mods, I want to pivot away from the leveling
> angle. I want the mod to be an autonomous survival mod with lower priority actions to fulfill
> when there are not immediate threats or needs. For example, exercise is deprioritized for
> securing the area. That means that combat will need a significant overhaul."*
>
> **Decisions already made:** exercise drops to the bottom idle slot; "secure the area" becomes a
> first-class priority phase above scavenging; barricading/construction is reopened but sequenced
> AFTER the combat-clearing milestone; the mod gets renamed.
>
> **Consequence for this document:** every "Direction" and "standing non-goal" statement below was
> written for the narrow leveler identity and is being reassessed. Two prior scope cuts were
> justified explicitly BY that identity and are now void: V3.1's six-module deletion ("a deliberate
> scope-down... to a focused identity") and V5.0's barricading removal ("more of an artifact of the
> broader scoped auto-survival and is now out of scope"). Broad autonomous survival is the scope
> again. Treat anything below that contradicts this box as stale until the pivot's release plan
> lands.

**Direction (pre-pivot, being superseded):** The V3.4-V3.8 stabilize track (including V3.8 preparation, done 2026-07-20 — execution stays gated on Build 42.20) and the entire V4.0-approved expansion track (V4.1-V4.9) are COMPLETE. A user-directed scope cut (V5.0) and five bug-driven hardening releases (V5.1-V5.8) followed. Then a code-health split of `AutoPilot_Needs.lua` (four slices shipped 2026-07-20: eat/drink, sleep, endurance-critical rest, and the exercise/trainer block, 1848 → 706 lines). This file supersedes `EXPANSION_ROADMAP.md` (the old V1.1-V2.0 expansion plan) as of 2026-07-18.
**Cadence:** each milestone is sized for one or two small PRs, ordered by dependency and user gates, never by calendar time — agent execution runs far faster than a planned weekly cadence (the V4.1-V5.8 arc below shipped in about a day and a half).

---

## Current state (as of 2026-07-20)

AutoPilot Leveler is an auto-EXERCISE leveler for Project Zomboid Build 42 (pzversion 42.19.0, unstable branch):

- Auto / Strength / Fitness focus, F10 arm/disarm (protected by the V4.5 ownership registry so the mod never touches an action it did not queue), F11 metrics panel with live status and a session-history trend line, an on-screen action/intention HUD, equipment exercises with a daily gear fetch from home containers (worn and carried containers are now searched too, not just top-level inventory), configurable weekly training programs, PZAPI.ModOptions sliders and rebindable keys registered on `Events.OnMainMenuEnter` with an `OnTick` fallback (V5.5 fix — they previously never reached the in-game menu).
- Always-on survival FAIL-SAFE (eat, drink, sleep, flee, medical) with configurable hunger/thirst thresholds, an endurance-recovery floor for the 30-50 percent dead zone, death learning (DeathLog + Adaptive bounded threshold tuning), and combat where fight and flee share one engage guard (V5.6 fix — the queue was previously cleared every tick, so neither could complete).
- OFF by default. MP-compatible, client-side only. Splitscreen support was removed in V3.2. Barricading and woodworking were removed in V5.0 (artifact of the old broader-survival scope).
- 21 Lua modules under `42/media/lua/client/` (`AutoPilot_Barricade.lua` removed in V5.0, `AutoPilot_SessionHistory.lua` added in V4.2, `AutoPilot_Consumption.lua`/`AutoPilot_Sleep.lua`/`AutoPilot_Rest.lua`/`AutoPilot_Exercise.lua` split out of `AutoPilot_Needs` in a 2026-07-20 code-health pass — eat/drink, then sleep, then endurance-critical rest, then the exercise/trainer block, all verbatim moves; the rest move needed a same-day prior seam increment first since its cooldown state was shared with `check()`'s own gate, the exercise move did not since its shared touch points were already named functions); 14 Lua test suites, 1107 assertions, 0 failures (verified 2026-07-20); luacheck clean across 21 files; Python tooling suite green aside from two long-known-stale console-log assertions excluded from CI (tracked in the AutoPilot backlog `## Bugs`). `AutoPilot_Needs.lua` down to 706 lines from 1848 across the four slices — now well under the 1000-line code-health threshold.

### Shipped 2026-07-18 (the pivot-and-stabilize burst)

All of V2.1 through V3.3 shipped on 2026-07-18; `CHANGELOG.md` is the authoritative record. In brief:

- **V2.1:** API compatibility sweep against the installed B42 build (timed-action signatures, `common/` folder fix, log append fix). Note: its changelog entry is titled a "Build 42.20" pass and set pzversion to 42.20.0; V3.0 corrected the target to 42.19.0 because 42.20 was still internal.
- **V3.0:** identity pivot to auto-leveler (Leveler, XP metrics, F11 UI, DeathLog, Adaptive); CI expanded to run all Lua test files; direct `addXp()` grants explicitly rejected as cheating.
- **V3.1:** scope refocus; DELETED the Skills, Foraging, Vehicles, Combat, Explore, and Actions modules and their wiring; survival made always-on; fixed the MP Lua-reload stale-closure bug.
- **V3.2** (commit a3cedd2): splitscreen removed entirely; three MP dry-run fixes (Events.OnQueueNewGame guard, ISFitnessAction:new signature restored to the runtime-verified table-4th/string-5th form, proactive-scavenging starvation of the trainer); test mocks updated to verified signatures.
- **V3.3** (commit eef62ec): equipment exercises with vanilla prop equipping, daily equipment fetch, live F11 status line + sets/day + regularity + arm/disarm button, ModOptions sliders and rebindable keys, fix for load-time constant caching that made Adaptive tuning partially inert, telemetry log rotation past 20k lines.
- **Tooling and publish:** `sync_workshop.sh` Workshop staging builder (commit 0e3e275), Workshop description refreshed to the leveler identity (commit 8e988fa), mod published to Steam Workshop id 3767254910.

### Shipped 2026-07-19 to 2026-07-20 (stabilize completion, full V4.0 expansion, and bug-driven hardening)

`CHANGELOG.md` carries the full detail per release; this is the rollup the "Next milestones" section below used to promise on a weekly cadence and instead shipped in about a day and a half of agent execution:

- **V3.4-V3.7 (stabilize track, PRs #13-#20, #27):** glob-driven test discovery in CI and `check.sh`, a mock-surface audit that caught a stale `ISApplyBandage` signature, nine doc-vs-code corrections, an `architecture.md` rewrite, `triage_run_log.py` plus a fixture and pattern-detector catalog, a validated GitHub issue template, and `FEEDBACK.md`. V3.8 remains **prepared, not executed** — see below.
- **V4.0 (PR #21):** expansion proposal drafted and approved with defaults — C2+C6 (V4.1), C5 (V4.2), C3 (V4.3) accepted; C1 gated on user in-game SkillBook verification; C4 deferred.
- **V4.1-V4.3 (PRs #22-#24):** Woodwork+Doctor XP visibility (later reversed by V5.0), F11 session history with a trend sparkline, five weekly training presets.
- **V4.4-V4.5 (PRs #28, #26):** the on-screen action/intention HUD; the ownership registry (weak-keyed, GC-safe, all ~30 queue sites routed through it) so the mod never touches a foreign action; an armed-intervention backoff; an F10 panic stop that clears any running exercise.
- **V4.6-V4.9:** XP-gated training with an opt-in daily set cap; configurable hunger/thirst thresholds; a real user-reported bug where worn and carried containers were invisible to `findBandage` and every inventory selector (V4.8), a transfer-before-use follow-up (V4.9), and a V5.1 hotfix guarding the container type-check.
- **V5.0 (PR #34):** user-directed scope cut — barricading and woodworking removed entirely (`AutoPilot_Barricade.lua` deleted, the priority-10 maintenance slot gone, telemetry schema v3 to v4).
- **V5.2-V5.8:** auto-days prefer carried equipment over burpees; version visibility in the F11 panel and the Workshop description; an endurance-recovery floor for the 30-50 percent dead zone; two more real user-reported bugs fixed — mod options never reaching the in-game menu (now registered on `Events.OnMainMenuEnter`, was load-time-only before) and combat clearing its own action queue every tick so neither fighting nor fleeing could complete (fight and flee now share one engage guard); the user's tuned option defaults adopted; a rest bug where the character was reported "resting" while still standing, fixed by queuing one sit-and-rest action instead of two, plus a single shared activity string so the F11 panel and the HUD can no longer disagree.

---

## Direction and standing non-goals

> **PIVOT NOTE (2026-07-21):** this whole section predates the identity pivot described at the top
> of this file. The non-goals that SURVIVE the pivot unchanged are: no mod-fabricated `addXp()`,
> no LLM sidecar, no splitscreen, and the V4.5 player-agency guarantee (never touch an action the
> mod did not queue; F10 always stops everything). The non-goals that are REOPENED or void are
> called out inline below. Vehicles and Actions remain closed as of this writing.

Stabilize (V3.4-V3.8, including V3.8 preparation) and the full V4.0-approved expansion track (V4.1-V4.9) are both **complete** (2026-07-20); V3.8's execution stays gated on Build 42.20. With no further expansion currently approved, the near-term direction is **harden and maintain**: fix real in-game bug reports (the AutoPilot backlog `## Bugs` section is the queue) and keep docs and this roadmap truthful. The `AutoPilot_Needs.lua` code-health split preflight C10 flagged is DONE: four slices shipped 2026-07-20 (1848 to 706 lines), now well under the 1000-line threshold. `AutoPilot_Inventory.lua` (1038 lines) was investigated 2026-07-20 and ruled OUT as a near-term candidate — only 10 percent commit share over the last 20 commits, well under the ~50 percent threshold that actually predicts parallelism-blocking (see the AutoPilot backlog CODE HEALTH entry for the evidence). A new expansion track resumes only through a fresh proposal reviewed the same way V4.0 was, never ad-hoc module resurrection. **Direction change 2026-07-21:** the user explicitly reopened four of the six V3.1-deleted areas — **Foraging, Combat, Explore, and Skills** — as expansion territory, choosing a fresh design over a git-history restore. (Actions stays closed as the retired LLM sidecar's command registry; Vehicles was never reopened. Skills was withdrawn and then reopened the same day when its supposed blocker was checked against the live 42.19 install and falsified — see the standing non-goals below.) That work routes through a V7.0 proposal; the "harden and maintain" posture above still governs everything outside it, and the separately-pending V6.0 proposal (`docs/EXPANSION_PROPOSAL_V6.md`) is unaffected and still awaiting its own decision.

Standing non-goals (do NOT plan these without explicit user direction):

- ~~NO resurrection of the deleted Skills / Foraging / Combat / Vehicles / Explore / Actions modules.~~ **REVERSED IN PART 2026-07-21 by explicit user direction:** **Foraging, Combat, Explore, and Skills** are REOPENED as legitimate expansion territory. **Vehicles and Actions remain standing non-goals.** (Skills was briefly withdrawn the same day on the strength of an inherited "no queueable action path" claim, then reopened once that claim was checked against the live game install and found FALSE — see the Skills bullet below.) Reopened does NOT mean restored: the user chose a fresh design against the current 21-module architecture and verified B42.19 APIs, not a git-history restore of the pre-V3.1 code (which predates the API-signature corrections in V2.1/V3.0/V3.2 and every architectural change since). These three areas route through a V7.0 proposal reviewed the same way V4.0 and V6.0 were; nothing is scheduled work until that proposal's Decision section is marked.
- **Skills is REOPENED (2026-07-21) and the long-standing "no queueable action path" claim is FALSIFIED.** That claim was inherited from the V3.1 scope cut and repeated in every roadmap since without ever being exhaustively checked (the L-026 failure mode: asserting absence without searching). A direct search of the live 42.19 install at `media/lua/shared/TimedActions/` found **141 timed actions**, of which many grant skill XP through the game's own `perform()`: Tailoring (`ISRepairClothing`, `ISRemovePatch`), Fishing (`ISCheckFishingNetAction`, `ISPickupFishAction`, plus a whole `Fishing/TimedActions/` subtree), Cooking (`ISAddItemInRecipe`), Farming, Maintenance, Electricity, MetalWelding, Masonry, Husbandry, Butchering, Reloading. Worked example, verified against the live file: `ISRepairClothing:new(character, clothing, part, fabric, thread, needle)` is an `ISBaseTimedAction` subclass whose `perform()` calls `addXp(self.character, Perks.Tailoring, 2)` with a skill-scaled duration (`150 - perkLevel * 6`). **This is NOT an `addXp()` violation:** the non-goal forbids the MOD fabricating XP; here the mod queues a real action and the GAME grants the XP as a consequence — structurally identical to how `ISFitnessAction` already trains Strength/Fitness today. Carpentry/Woodwork stays OUT regardless, under the separate V5.0 construction non-goal below. Which skills are actually worth automating, and at what risk, is the V7.0 proposal's job.
- NO Actions module (briefly reopened 2026-07-21, closed again the same day). `AutoPilot_Actions.lua` was the LLM sidecar's command registry — its own `SCHEMA` table said so verbatim — and the sidecar is a permanent non-goal. At deletion it was fully orphaned: nothing called `execute`, `executeChain`, or `getSchemaNames`, and its handlers were thin wrappers over functions `AutoPilot_Needs` already calls directly. The one thing it might have justified, a single seam for the scattered queue call sites, already exists as the V4.5 ownership registry in `AutoPilot_Utils`.
- ~~NO resurrection of barricading, woodworking, or any other construction work.~~ **REOPENED 2026-07-21 by the identity pivot.** V5.0 deleted `AutoPilot_Barricade.lua` on the user's rationale that it was *"more of an artifact of the broader scoped auto-survival and is now out of scope"* — broad autonomous survival is the scope again, so that rationale is void. **Sequencing is fixed by user decision: area-CLEARING (combat) ships first; barricading/construction is a LATER milestone.** Scope discipline still applies: barricading existing openings is the target, not general base-building. Woodwork XP becomes an incidental side effect, explicitly NOT a leveler feature (the pivot is away from leveling). **Note for whoever implements this:** `tests/test_priority_logic.lua` Scope Test 1 and `tests/test_leveler_metrics.lua` Leveler Test 5 are anti-resurrection guards that will FAIL when barricading returns — they are correct today and must be deliberately rewritten as part of that milestone, not deleted in passing.
- NO LLM sidecar (retired; `release.yml` asserts no anthropic imports, and the Kahlua sandbox forbids HTTP anyway).
- NO splitscreen support (removed in V3.2 because it could not be made reliable).
- NO direct `addXp()` grants (rejected in V3.0 as cheating; XP must come from real queued actions).
- Non-exercise leveler skills (Tailoring, Cooking, Fishing, Farming, ...): **the old "42.19 offers no clean queueable action path" justification is RETIRED as false** (2026-07-21, see the Skills bullet above for the evidence). The real bar is unchanged and still binding, it was just never the blocker it was claimed to be: a skill is in scope only with a **verified** queueable action whose own `perform()` grants the XP, cited to the live game source, never a guessed signature. Skill-book reading (V4.0's C1, still unimplemented) remains a complementary multiplier path, not a substitute. Carpentry/Woodwork stays closed regardless under the V5.0 construction non-goal. **Note on Foraging:** the reopened Foraging area is loot-zone learning, a different thing from PZ's PlantScavenging skill; real wild-food foraging is a *skill* and clears the same bar as any other.

---

## Completed milestones

V3.4 through V3.7, V4.0 through V4.9, and V5.0 through V5.8 are all complete — see the "Shipped" sections above and `CHANGELOG.md` for full per-release detail.

### V3.8: B42.20-stable readiness (PREPARED 2026-07-20, execute BLOCKED)

Build 42.20 was announced as the stable candidate on 2026-07-09, and 42.19 saves will not carry over, so the migration moment is a real event that deserves a script. **Preparation is done:** [docs/b42_20_checklist.md](docs/b42_20_checklist.md) exists, built from `tests/lua_mock_pz.lua`'s continuously-maintained verified-API-surface header rather than a fresh enumeration (a second list of the same surfaces would itself drift), and names the five surfaces with a prior history of breaking (`ISFitnessAction:new`, `ISTimedActionQueue.addGetUpAndThen`, `ISRestAction:new`, `PZAPI.ModOptions` load-time availability, `addComboBox`) as the priority re-verification order.

- BLOCKED (execution): do not run the checklist until Build 42.20 is the Steam default AND the user explicitly decides to migrate.
- USER-ONLY: the migration decision, all in-game verification, and the Workshop "Update Item" upload.
- **Done when (preparation):** DONE — the checklist file exists and covers every API surface `tests/lua_mock_pz.lua` enumerates; execution has its own gate above.

## Next milestones

No expansion milestone is currently approved. The actionable next steps, tracked in the AutoPilot backlog (`d:\Projects\.claude\skills\autodev\backlogs\autopilot-pz.md`), ordered by dependency rather than a calendar:

- The `AutoPilot_Needs.lua` code-health split is DONE: four verbatim-move slices shipped 2026-07-20 (`AutoPilot_Consumption.lua` for eat/drink, `AutoPilot_Sleep.lua` for sleep, `AutoPilot_Rest.lua` for endurance-critical rest, `AutoPilot_Exercise.lua` for the exercise/trainer block; the rest move needed a same-day prior seam increment first, the exercise move did not since its shared touch points with `check()` — `syncSetsCounter`, `isInTrainingRun`, `enduranceResumeGate` — were already named functions, confirmed by re-reading `check()` before starting rather than assumed from the `doRest` precedent). `AutoPilot_Needs.lua` is down to 706 lines from 1848, now well under the 1000-line threshold. `AutoPilot_Inventory.lua` (1038 lines) was investigated and ruled OUT (10 percent commit share, see "Direction and standing non-goals" above); no further code-health candidate is currently open.
- **`docs/EXPANSION_PROPOSAL_V6.md` drafted 2026-07-20, AWAITING USER DECISION**: three small candidates (sickness-aware exercise/scavenge gating, decision-reason visibility on the F11 panel, exercise equipment variety gated on a live table lookup), reviewed the same way `docs/EXPANSION_PROPOSAL_V4.md` was. No implementation until the Decision section is marked.
- V3.8 execution, once unblocked (see above).

---

## Later / candidates (unscheduled)

Worth recording so they are not lost, but none should preempt the milestones above.

- **Release-tag hygiene:** resume tagging (the last tag is v1.2.1; V2.0 through V3.3 shipped untagged, so tag-triggered `release.yml` has produced no v2/v3 GitHub release artifacts; distribution moved to Steam Workshop via `sync_workshop.sh`). Note `release.yml`'s major.minor tag check against `42/mod.info`. USER-ONLY: pushing tags.
- **Adaptive-rule tuning** informed by Workshop feedback and accumulated death-log data (bounds and thresholds only; no new modules).
- **`docs/baseline.md` refresh or retirement:** either freeze a new V3.3 baseline policy or mark the V1.1 one as historical.

---

## Blocked

| Item | Blocking reason |
|------|-----------------|
| B42.20 migration (executing the V3.8 checklist) | Gated on Build 42.20 becoming the Steam default AND an explicit user decision; 42.19 saves will not carry over. |
| Non-exercise leveler skills (Tailoring, Mechanics, Cooking, Fishing, Foraging) | 42.19 has no clean queueable action path for most; candidates with a real path (book reading) route through the V4.0 expansion proposal rather than being planned directly. Carpentry is no longer a candidate: its only path was the barricade pass, removed in V5.0. |

The 2026-06-04 GCP/Fly infra decommission blocks nothing here: this mod has no cloud dependency, and the LLM sidecar retirement was an independent design decision.

---

## User-only (standing)

These are never agent work:

- Steam Workshop "Update Item" uploads and `sync_workshop.sh` runs.
- Version bumps, releases, and tag pushes.
- In-game smoke and soak tests (all playtesting).
- Reading and answering Workshop comments; deciding which reports become GitHub issues.
- The B42.20 migration decision.

---

## History and supersession

- **The V1.1-V2.0 expansion plan is superseded.** `EXPANSION_ROADMAP.md` planned smarter foraging, extended combat, advanced skills, vehicles, NPCs, base building, analytics, an LLM sidecar, economy, and quests. Phase 1 of it (Foraging, Combat, Skills, Vehicles) was actually built on 2026-06-01 (commit 1962c8b) and then deliberately DELETED in V3.1 on 2026-07-18 when the mod pivoted to the leveler identity. The LLM sidecar was retired separately. `PHASE1_SUMMARY.md` documents the deleted phase and is historical only.
- **Reversed decisions:** V1.1 shipped always-on-by-default and splitscreen support; V3.x reversed both (OFF by default since the pivot, splitscreen removed in V3.2). Direct `addXp()` grants were rejected in V3.0. V4.1 shipped Woodwork XP visibility on the barricade maintenance pass (candidate C2); V5.0 reversed it, deleting `AutoPilot_Barricade` and every woodworking surface at the user's direction: barricading was "more of an artifact of the broader scoped auto-survival and is now out of scope".
- **Distribution shift:** git release tags stopped at v1.2.1; V2.0 through V3.3 shipped untagged, and distribution moved to Steam Workshop (published 2026-07-18).
- `CHANGELOG.md` remains the single source of truth on what shipped; `docs/baseline.md` and `CODE_REVIEW.md` are historical records.
