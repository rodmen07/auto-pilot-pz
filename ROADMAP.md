# AutoPilot Leveler Roadmap

**Status:** Code and packaged builds are current through V5.8 (`mod.info` modversion 5.8, 2026-07-20; `CHANGELOG.md` is the authoritative shipped record). Workshop item 3767254910 was published at V3.3 on 2026-07-18; later Workshop updates are USER-ONLY (`sync_workshop.sh` plus in-game "Update Item") and not verifiable from this environment — confirm the live Workshop version in-game before assuming parity with the code.
**Direction:** The V3.4-V3.7 stabilize track and the entire V4.0-approved expansion track (V4.1-V4.9) are COMPLETE. V3.8 preparation is the only stabilize item still open (execution stays gated). A user-directed scope cut (V5.0) and five bug-driven hardening releases (V5.1-V5.8) followed. No further expansion is currently approved; see "Next milestones" below. This file supersedes `EXPANSION_ROADMAP.md` (the old V1.1-V2.0 expansion plan) as of 2026-07-18.
**Cadence:** each milestone is sized for one or two small PRs, ordered by dependency and user gates, never by calendar time — agent execution runs far faster than a planned weekly cadence (the V4.1-V5.8 arc below shipped in about a day and a half).

---

## Current state (as of 2026-07-20)

AutoPilot Leveler is an auto-EXERCISE leveler for Project Zomboid Build 42 (pzversion 42.19.0, unstable branch):

- Auto / Strength / Fitness focus, F10 arm/disarm (protected by the V4.5 ownership registry so the mod never touches an action it did not queue), F11 metrics panel with live status and a session-history trend line, an on-screen action/intention HUD, equipment exercises with a daily gear fetch from home containers (worn and carried containers are now searched too, not just top-level inventory), configurable weekly training programs, PZAPI.ModOptions sliders and rebindable keys registered on `Events.OnMainMenuEnter` with an `OnTick` fallback (V5.5 fix — they previously never reached the in-game menu).
- Always-on survival FAIL-SAFE (eat, drink, sleep, flee, medical) with configurable hunger/thirst thresholds, an endurance-recovery floor for the 30-50 percent dead zone, death learning (DeathLog + Adaptive bounded threshold tuning), and combat where fight and flee share one engage guard (V5.6 fix — the queue was previously cleared every tick, so neither could complete).
- OFF by default. MP-compatible, client-side only. Splitscreen support was removed in V3.2. Barricading and woodworking were removed in V5.0 (artifact of the old broader-survival scope).
- 17 Lua modules under `42/media/lua/client/` (`AutoPilot_Barricade.lua` removed in V5.0, `AutoPilot_SessionHistory.lua` added in V4.2 — the count held steady); 14 Lua test suites, 1106 assertions, 0 failures (verified 2026-07-20); luacheck clean across 17 files; Python tooling suite green aside from two long-known-stale console-log assertions excluded from CI (tracked in the AutoPilot backlog `## Bugs`).

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

Stabilize (V3.4-V3.7) and the full V4.0-approved expansion track (V4.1-V4.9) are both **complete** (2026-07-20); V3.8 preparation is the only stabilize item still open, and its execution stays gated. With no further expansion currently approved, the near-term direction is **harden and maintain**: fix real in-game bug reports (the AutoPilot backlog `## Bugs` section is the queue), keep docs and this roadmap truthful, and split the code-health hotspot files preflight C10 flags (`AutoPilot_Needs.lua`, `AutoPilot_Inventory.lua`) when doing so would unblock parallel work. A new expansion track resumes only through a fresh proposal reviewed the same way V4.0 was, never ad-hoc module resurrection.

Standing non-goals (do NOT plan these without explicit user direction):

- NO resurrection of the deleted Skills / Foraging / Combat / Vehicles / Explore / Actions modules.
- NO resurrection of barricading, woodworking, or any other construction work (deleted in V5.0 as an artifact of the broader auto-survival scope). This includes the Woodwork XP-visibility block that rode on it. `tests/test_priority_logic.lua` Scope Test 1 and `tests/test_leveler_metrics.lua` Leveler Test 5 guard against accidental reintroduction.
- NO LLM sidecar (retired; `release.yml` asserts no anthropic imports, and the Kahlua sandbox forbids HTTP anyway).
- NO splitscreen support (removed in V3.2 because it could not be made reliable).
- NO direct `addXp()` grants (rejected in V3.0 as cheating; XP must come from real queued actions).
- Non-exercise leveler skills (Tailoring, Mechanics, Cooking, Fishing, Foraging) are not scheduled directly: 42.19 offers no clean queueable action path for most of them. Where a real queued-action path exists (skill-book reading), the V4.0 expansion proposal is the route in; do not add them outside that gate. The carpentry-via-barricade-pass route is closed: V5.0 removed barricading from the mod's scope entirely.

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

- A behavior-preserving, verbatim-move-first split of the code-health hotspots preflight C10 flags: `AutoPilot_Needs.lua` (1854 lines) and `AutoPilot_Inventory.lua` (1038 lines).
- A fresh expansion proposal, only if the user wants to grow capability again, drafted and reviewed the same way `docs/EXPANSION_PROPOSAL_V4.md` was — never ad-hoc module resurrection.
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
