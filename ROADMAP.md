# AutoPilot Leveler Roadmap

**Status:** V3.3 shipped, pushed, and published to Steam Workshop (id 3767254910) on 2026-07-18.
**Direction:** STABILIZE (V3.4-V3.8), then EXPAND (V4.0 track, user-gated). This file supersedes `EXPANSION_ROADMAP.md` (the old V1.1-V2.0 expansion plan) as of 2026-07-18.
**Cadence:** roughly one minor version per week; each milestone below is sized for one or two small PRs.

---

## Current state (as of 2026-07-18)

AutoPilot Leveler is an auto-EXERCISE leveler for Project Zomboid Build 42 (pzversion 42.19.0, unstable branch):

- Auto / Strength / Fitness focus, F10 arm/disarm, F11 metrics panel with live status, equipment exercises (dumbbell press, biceps curl, barbell curl) with a daily gear fetch from home containers, PZAPI.ModOptions sliders and rebindable keys.
- Always-on survival FAIL-SAFE (eat, drink, sleep, flee, medical) plus death learning (DeathLog + Adaptive bounded threshold tuning).
- OFF by default. MP-compatible, client-side only. Splitscreen support was removed in V3.2.
- 17 Lua modules under `42/media/lua/client/`; 9 Lua test suites (194 assertions, all green) plus Python tests; luacheck clean.

### Shipped 2026-07-18 (the pivot-and-stabilize burst)

All of V2.1 through V3.3 shipped on 2026-07-18; `CHANGELOG.md` is the authoritative record. In brief:

- **V2.1:** API compatibility sweep against the installed B42 build (timed-action signatures, `common/` folder fix, log append fix). Note: its changelog entry is titled a "Build 42.20" pass and set pzversion to 42.20.0; V3.0 corrected the target to 42.19.0 because 42.20 was still internal.
- **V3.0:** identity pivot to auto-leveler (Leveler, XP metrics, F11 UI, DeathLog, Adaptive); CI expanded to run all Lua test files; direct `addXp()` grants explicitly rejected as cheating.
- **V3.1:** scope refocus; DELETED the Skills, Foraging, Vehicles, Combat, Explore, and Actions modules and their wiring; survival made always-on; fixed the MP Lua-reload stale-closure bug.
- **V3.2** (commit a3cedd2): splitscreen removed entirely; three MP dry-run fixes (Events.OnQueueNewGame guard, ISFitnessAction:new signature restored to the runtime-verified table-4th/string-5th form, proactive-scavenging starvation of the trainer); test mocks updated to verified signatures.
- **V3.3** (commit eef62ec): equipment exercises with vanilla prop equipping, daily equipment fetch, live F11 status line + sets/day + regularity + arm/disarm button, ModOptions sliders and rebindable keys, fix for load-time constant caching that made Adaptive tuning partially inert, telemetry log rotation past 20k lines.
- **Tooling and publish:** `sync_workshop.sh` Workshop staging builder (commit 0e3e275), Workshop description refreshed to the leveler identity (commit 8e988fa), mod published to Steam Workshop id 3767254910.

---

## Direction and standing non-goals

The near-term direction is **stabilize**: harden CI, make the docs truthful, build triage tooling for the now-public Workshop audience, and prepare (but not execute) the Build 42.20 migration. The standing emphasis after that is **expansion** (user direction, 2026-07-18): grow the mod's capability through the V4.0 proposal track below rather than stopping at maintenance. Expansion routes through an approved proposal, never ad-hoc module resurrection.

Standing non-goals (do NOT plan these without explicit user direction):

- NO resurrection of the deleted Skills / Foraging / Combat / Vehicles / Explore / Actions modules.
- NO LLM sidecar (retired; `release.yml` asserts no anthropic imports, and the Kahlua sandbox forbids HTTP anyway).
- NO splitscreen support (removed in V3.2 because it could not be made reliable).
- NO direct `addXp()` grants (rejected in V3.0 as cheating; XP must come from real queued actions).
- Non-exercise leveler skills (Tailoring, Mechanics, Cooking, Fishing, Foraging) are not scheduled directly: 42.19 offers no clean queueable action path for most of them. Where a real queued-action path exists (skill-book reading, carpentry via the barricade pass), the V4.0 expansion proposal is the route in; do not add them outside that gate.

---

## Next milestones

### V3.4: CI and test durability (agent-doable now)

Locks in the stabilize direction: make it impossible for test coverage to silently rot, and keep the mock as the guard against another phantom-signature incident.

- Replace the hardcoded 9-file Lua test list in `.github/workflows/ci.yml` (lines 59-68) with glob-driven discovery of `tests/test_*.lua`, failing the job if zero files are found.
- Apply the same glob to the `LUA_TEST_FILES` array in `check.sh` (lines 109-118) so local and CI runs cannot diverge.
- Simplify the pytest `--ignore` lists in `ci.yml` and `check.sh`: pytest does not collect `.lua` files, so the lists are dead weight and are already inconsistent between the two.
- Audit `tests/lua_mock_pz.lua` against every PZ API callsite in `42/media/lua/client/` (special attention: `ISFitnessAction:new` table-4th/string-5th, `ISTimedActionQueue.addGetUpAndThen`, `ISRestAction` 3-arg, `PZAPI.ModOptions`) and record the verified 42.19 surface in the mock's header comment.
- Slicing: PR1 = glob-driven CI + check.sh + pytest cleanup; PR2 = mock audit.
- **Done when:** adding a 10th `tests/test_*.lua` file is picked up by both CI and `check.sh` with no list edits, and the mock header documents the verified 42.19 API surface.

### V3.5: docs truth pass to V3.3 (agent-doable now)

Every user-facing doc should describe the mod that actually shipped; the README currently contradicts `mod.info` and lists a deleted module.

- `README.md`: fix "Current modversion: 1.1" (line 128) to 3.3; remove deleted `AutoPilot_Actions.lua` from Core Runtime Modules and add Leveler / XP / UI / DeathLog / Adaptive / Options; delete the splitscreen telemetry file lines (`_p1`..`_p3`); replace the "grows unbounded" log claim with the V3.3 rotation behavior (rotates past 20k lines, keeps newest 5k).
- `TESTING.md`: retitle from V3.2 to V3.3 and fold the "V3.3 Additions" section into the main checklist so it reads as one current pass.
- `WORKSHOP.md`: update the Known Limitations telemetry line (log rotates since V3.3) and add a line for ModOptions sliders and rebindable keys.
- `MULTIPLAYER.md`: replace the `WorkshopItems=<your-workshop-id>` placeholder (line 33) with the published id 3767254910; the rest of the file already matches V3.2+ behavior.
- `docs/architecture.md`: retitle from v2.0; update the module ownership map to the current 17 modules; remove the Splitscreen Safety section. Accuracy matters here because `release.yml` packages this file into release zips.
- `PHASE1_SUMMARY.md`: add a two-line superseded banner at the top pointing here (the four modules it celebrates were deleted in V3.1); leave the historic content intact.
- Slicing: PR1 = README + TESTING + WORKSHOP + MULTIPLAYER + PHASE1_SUMMARY banner; PR2 = architecture.md.
- **Done when:** no shipped doc names a deleted module, claims modversion 1.1, or describes splitscreen or unbounded logs as current behavior.

### V3.6: telemetry triage helper (agent-doable now)

`auto_pilot_run.log` is the debugging goldmine (it found the V3.2 scavenging-starvation bug); a summarizer turns hours of log reading into minutes.

- Add a small standalone script (e.g. `triage_run_log.py` next to `benchmark.py`) that summarizes `auto_pilot_run.log`: per-action counts, action/reason transition table, training vs resting vs survival time split, threat events, and STR/FIT level deltas per session.
- Emit a "suspicious patterns" section: long single-action streaks, zero-XP training loops, repeated flee cycles, empty-loot spirals.
- Add a pytest for the parser against a fixture log excerpt.
- Document usage in README's Telemetry section; leave `benchmark.py` untouched.
- Slicing: PR1 = script + fixture test; PR2 = README doc + pattern rules.
- **Done when:** running the script on a real session log prints the summary and pattern sections, and its parser test passes in CI.

### V3.7: Workshop feedback triage process (mostly agent-doable)

The mod is public as of 2026-07-18 (id 3767254910); reports will arrive and each one needs the same evidence to be actionable.

- Add `.github/ISSUE_TEMPLATE/bug_report.yml` capturing: pzversion, SP or MP, `console.txt` excerpt, `auto_pilot_run.log` excerpt, `auto_pilot_deaths.log` lines, and mod options changed from defaults.
- Add a short `FEEDBACK.md` triage guide mapping common report types (mod does nothing, exercise never starts, panel dead, died while AFK) to the log evidence and the test suite that isolates each.
- USER-ONLY: reading and answering Workshop comments and deciding which reports become GitHub issues.
- **Done when:** a new GitHub issue opened via the template contains every field the triage guide needs.

### V3.8: B42.20-stable readiness (prepare now, execute BLOCKED)

Build 42.20 was announced as the stable candidate on 2026-07-09, and 42.19 saves will not carry over, so the migration moment is a real event that deserves a script. The checklist can be written today; running it is gated (see Blocked).

- Write `docs/b42_20_checklist.md` listing every API surface to re-verify on 42.20: `ISFitnessAction:new` signature, exercise definitions and xpMod values, `PZAPI.ModOptions`, `getSpecificPlayer`, sleep flow (`onSleepWalkToComplete`), `ISRestAction` 3-arg, `ISTimedActionQueue.addGetUpAndThen`, and the `inventory:contains` equipment gate.
- Include the mechanical steps: bump pzversion in both `mod.info` files, update Workshop tags/description, full TESTING.md pass including the soak test, then Workshop update.
- BLOCKED (execution): do not run the checklist until Build 42.20 is the Steam default AND the user explicitly decides to migrate.
- USER-ONLY: the migration decision, all in-game verification, and the Workshop "Update Item" upload.
- **Done when (preparation):** the checklist file exists and covers every API surface the mod touches; execution has its own gate above.

### V4.0: expansion track kickoff (agent-doable proposal; implementation user-gated)

The V3.1 trim was about shedding the broad-survival identity, not about the mod staying small. This milestone restarts deliberate expansion under the leveler identity, grounded in verified 42.19 APIs.

- Draft `docs/EXPANSION_PROPOSAL_V4.md`: candidate features with effort, risk, and the exact API surface each needs. Starting candidates: skill-book reading (SkillBook table + ISReadABook, with the Carpentry=Woodwork / FirstAid=Doctor / Foraging=PlantScavenging perk-name mapping), carpentry XP via the existing barricade pass, configurable training programs and schedules, richer Adaptive strategies from accumulated death-log data, and F11 panel upgrades (session history, per-perk ETAs).
- Every candidate must respect the standing non-goals (no direct addXp, no LLM sidecar, no splitscreen) and cite runtime-verified API facts, never phantom reads.
- USER-ONLY: choosing which proposals proceed; each approved feature becomes its own V4.x milestone with one-or-two-PR slices.
- **Done when:** the proposal doc exists with at least five costed candidates and the user has marked accept or reject on each.

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
| Non-exercise leveler skills (Tailoring, Mechanics, Cooking, Fishing, Foraging) | 42.19 has no clean queueable action path for most; candidates with a real path (book reading, carpentry) route through the V4.0 expansion proposal rather than being planned directly. |

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
- **Reversed decisions:** V1.1 shipped always-on-by-default and splitscreen support; V3.x reversed both (OFF by default since the pivot, splitscreen removed in V3.2). Direct `addXp()` grants were rejected in V3.0.
- **Distribution shift:** git release tags stopped at v1.2.1; V2.0 through V3.3 shipped untagged, and distribution moved to Steam Workshop (published 2026-07-18).
- `CHANGELOG.md` remains the single source of truth on what shipped; `docs/baseline.md` and `CODE_REVIEW.md` are historical records.
