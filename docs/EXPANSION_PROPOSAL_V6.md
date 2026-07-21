# AutoPilot Leveler: V6.0 Expansion Proposal

**Status:** DRAFT, awaiting user decision (drafted 2026-07-20, branch `autodev/v6.0-expansion-proposal`).
**Fulfils:** ROADMAP.md's Product-role rule for a dry development queue ("draft the next
expansion-milestone design doc... every decision flagged as an overridable default"). The
code-health split of `AutoPilot_Needs.lua` (four slices, 1848 to 706 lines) completed 2026-07-20
and no expansion track has been approved since V4.0 (2026-07-19); V5.1-V5.8 were bug-driven
hardening, not proposal-gated expansion. This document is complete when the user has marked
accept or reject on every candidate in the Decision section at the bottom.
**Scope discipline:** implementation is user-gated. Nothing in this document is scheduled work
until a candidate is approved; each approved candidate becomes its own V6.x milestone sized as
one or two small PRs, per the same cadence V4.1-V4.3 used.

---

## Why three candidates, not more

V4.0 proposed six candidates because the mod had just pivoted to the leveler identity and had
real breadth to cover. That breadth is now covered: exercise, all five survival needs, threat
response, XP metrics, session history, training programs, and death-learning adaptation all
ship today. ROADMAP.md's own direction is explicit — **"harden and maintain"** — and the standing
non-goals rule out re-growing scope into the deleted Skills/Foraging/Vehicles/Combat/Explore/
Actions territory. *(That last constraint was reversed in part on 2026-07-21, one day after this
document was drafted: Foraging, Combat and Explore were reopened — see the superseding note under
Ground rules. The reopened territory is scoped to its own V7.0 proposal and does not change the
three candidates below.)* Padding this proposal with speculative new action types to hit a bigger
number would be inventing work, which the dispatch rules this document was drafted under
explicitly forbid. Three candidates is the honest size of what a direct code read actually
turned up as real, narrow, low-risk gaps.

## Ground rules (standing non-goals, restated from ROADMAP.md)

Every candidate below was designed inside these constraints and each candidate section states
how it complies:

1. **No direct `addXp()` grants.** XP must come from real queued actions or passive training
   the game itself already grants for those actions.
2. **No LLM sidecar.** Retired; `release.yml` asserts no anthropic imports.
3. **No splitscreen.** Removed in V3.2 because it could not be made reliable.
4. **No resurrection of deleted modules.** Skills / Foraging / Vehicles / Combat / Explore /
   Actions stay deleted. No barricading or woodworking (removed V5.0, user-directed scope cut).
   > **SUPERSEDED IN PART 2026-07-21** (after this document was drafted): the user reopened
   > **Foraging, Combat, Explore, and Skills** as expansion territory, routed through a separate
   > V7.0 proposal. Vehicles, Actions, barricading, and woodworking all remain closed.
   > Note for anyone reading this document's evidence policy: the Skills reopening came with a
   > falsification of a claim repeated across several of these docs — 42.19 DOES expose queueable
   > skill-XP actions (e.g. `ISRepairClothing` grants Tailoring XP in its own `perform()`),
   > verified against the live install. This does NOT change any candidate below — all three were
   > designed inside the stricter constraint and none of them touch the reopened areas.
5. **No new external action surface unless a candidate says so explicitly and justifies it.**
   Every candidate below either observes existing behavior or narrows an existing gate; none
   adds a new `ISXxxAction` call site to a previously-untouched vanilla system.

## Evidence policy

Every claim below was verified by reading the current code directly during this same
increment, not carried over from an older document:

- `CharacterStat.SICKNESS` and `MoodleType` coverage: `tests/lua_mock_pz.lua`'s verified-surface
  header (lines ~238-242), confirming `SICKNESS` is a real, already-mocked stat and that no
  `MoodleType.Sick`-equivalent is mocked (only `ENDURANCE`/`Unhappy` are).
- `AutoPilot_Needs.getMoodleSnapshot`: `sick = math.floor(AutoPilot_Utils.safeStat(player,
  CharacterStat.SICKNESS))` is its only production use — display-only, feeds nothing else.
  Confirmed via a repo-wide grep for `SICKNESS` outside that one line.
- `AutoPilot_Telemetry.setDecision(action, reason, ...)`: its public API (`setDecision`,
  `logTick`, `onDeath`, `onShutdown`, `getPendingAction`, `getRunTick`) has no reason-reading
  getter. Confirmed neither `AutoPilot_UI.lua` nor `AutoPilot_Main.lua` reads a decision reason
  anywhere; only the resulting ACTION label reaches the panel/HUD via `getActionIntention`.
- Exercise candidate pools (`_exerciseCandidates` in `AutoPilot_Exercise.lua`, moved there
  2026-07-20 PR #61): `dumbbellpress`/`bicepscurl`/`barbellcurl` (dumbbell/barbell equipment)
  plus `burpees`/`squats`/`pushups`/`situp` (bodyweight). No other `FitnessExercises.exercisesType`
  entries are referenced anywhere in the mod.

No claim comes from a fresh read of the game install (the phantom-file lesson from V2.1/V3.2
still applies). Anything not in the repo's verified records is flagged **needs live
verification** below, and that verification is user-only in-game work.

---

## Candidate summary

| # | Candidate | Effort | Risk | Verdict |
|---|-----------|--------|------|---------|
| C1 | Sickness-aware exercise/scavenge gating | S | Low | Recommend |
| C2 | Decision-reason visibility on the F11 panel | S | Low | Recommend |
| C3 | Exercise equipment variety beyond dumbbell/barbell | S-M | Medium | Recommend (gated on live FitnessExercises verification) |

Effort scale: S = one small PR; M = one or two PRs.

---

## C1. Sickness-aware exercise/scavenge gating

**What the player gets.** `CharacterStat.SICKNESS` is already read every cycle for the F11
panel's moodle snapshot but currently does nothing else — a character in the "Sick" state (food
poisoning, infection) keeps training and scavenging exactly as if healthy. This candidate adds
one gate: above a configurable sickness threshold, the exercise slot and proactive-scavenge slot
both yield (matching the existing shape of the fatigue-overrides-exercise and rest-day-yields
patterns already in `check()`), letting the character rest and recover instead. No new action is
queued for sickness itself — PZ has no simple "treat sickness" queued action the way bandaging
treats a wound, so the honest, narrow scope here is "stop making it worse by exercising through
it," not "cure it."

**Exact API surface.** All **verified**; no new engine APIs.

- `CharacterStat.SICKNESS` via `AutoPilot_Utils.safeStat`: verified today in
  `AutoPilot_Needs.getMoodleSnapshot` and in the mock's verified-surface header (mocked,
  suite-local in `test_threat_logic`).
- Gate placement: `AutoPilot_Needs.check()`'s existing priority chain (mirrors how the fatigue
  check at the top of `check()` already overrides the exercise slot before it is reached), and
  `AutoPilot_Needs.shouldInterrupt` (mirrors the existing endurance/thirst/hunger interrupt
  triggers Main already polls before its action guard).
- New tunable: `AutoPilot_Constants.SICKNESS_EXERCISE_MAX` (a `PZAPI.ModOptions` slider, same
  pattern as `HUNGER_THRESHOLD`/`THIRST_THRESHOLD` added in V4.7 — [G] documented gap in the
  mock, playtest-verifiable only, same as every other slider).

**Effort:** S. One condition added to `check()`'s exercise gate (mirrors the existing rest-day
yield in `Leveler.check`), one condition added to `doProactiveScavenge`'s entry gate, one new
constant, one new slider.

**Risk:** Low. Purely a narrowing gate on existing behavior — nothing new is queued, so the
V3.2 starvation-incident failure mode (a background behavior claiming cycles it shouldn't)
cannot recur here; if anything this candidate REDUCES total action-queueing, the opposite
direction. Default threshold should be high enough that mild sickness (SICKNESS < ~40) does not
interrupt training, since PZ awards partial recovery over time regardless of activity — the
exact default value needs a judgment call in review, not a live-verification gate.

**Identity fit.** Good. Extends the mod's existing "read the survival stats honestly and react"
principle (the same one behind the V5.4 endurance-recovery floor and V4.7 configurable
thresholds) to a stat the mod already reads but currently ignores.

**Testing note.** `_syncSetsCounter`/`check()`'s existing threshold-gate tests in
`test_priority_logic.lua` are the direct template (e.g. the fatigue-overrides-exercise test).
New cases: sickness above threshold skips both exercise and scavenge and falls through to rest;
sickness below threshold changes nothing (regression guard); the slider's default keeps current
behavior unchanged when Options never loads (mirrors the V4.7 slider tests). No new mock surface
needed — `CharacterStat.SICKNESS` is already mocked.

**Verdict: Recommend.**

---

## C2. Decision-reason visibility on the F11 panel

**What the player gets.** `AutoPilot_Telemetry.setDecision(action, reason, ...)` already records
WHY the mod chose its current action every cycle (`"hunger_thresh"`, `"low_endurance"`,
`"sit_recover"`, etc.) — but that reason is write-only, consumed only by the offline
`triage_run_log.py` tool reading the telemetry log file after the fact. The player watching the
F11 panel or the on-screen HUD sees WHAT the character is doing ("Resting") but never WHY. This
candidate adds a small second line — "Resting (low endurance)" style — reusing the same reason
vocabulary the telemetry log and `triage.md`'s pattern catalog already document, so there is
exactly one taxonomy of reasons instead of two.

**Exact API surface.** All **verified**; one new getter, no new engine APIs.

- `AutoPilot_Telemetry.setDecision`: verified today (`AutoPilot_Telemetry.lua`, called from
  every branch of `AutoPilot_Needs.check`, `AutoPilot_Threat.check`, and `AutoPilot_Leveler`'s
  exercise slot). The reason strings are already stable and documented (`docs/triage.md`'s
  pattern catalog).
- New getter: `AutoPilot_Telemetry.getLastReason()` (or `.getDecision()` returning `{action,
  reason}`), mirroring the existing read-side shape of `getPendingAction`/`getRunTick`.
- Rendering: F11 panel (`AutoPilot_UI.lua`) and the V4.4 on-screen HUD both already read
  `getActionIntention`'s formatted action string (architecture.md, F11 Panel /
  `AutoPilot_Main._updateActionHUD`); this candidate adds the reason as a second read next to
  it, same [G] documented-gap rendering surface every other panel line already uses.

**Effort:** S. One getter in Telemetry, one formatting line reused by both the panel and the
HUD (matching the existing single-source-of-truth pattern `getActionIntention` established in
V5.8 specifically to stop the panel and HUD from disagreeing).

**Risk:** Low. Purely observational — reads state that is already computed and stored every
cycle; adds no new decision logic and cannot change what the mod does, only what it displays.

**Identity fit.** Strong. Directly extends the V5.8 fix's own principle (one honest activity
source, not two that can disagree) to the "why," which is the natural next question a player
watching an AFK character asks.

**Testing note.** Same shape as `test_main_logic.lua`'s existing V5.8 assertions (`statusText`/
`statusLine`/`trainedExerciseFrom` checked against the real `getActionIntention`): add a pure
`reasonLine(action, reason)` formatter, unit-test it directly, and assert the panel/HUD both call
it with the same telemetry-sourced value so they cannot drift apart the way the pre-V5.8 code did.

**Verdict: Recommend.**

---

## C3. Exercise equipment variety beyond dumbbell/barbell

**What the player gets.** Today's equipment-exercise pool is exactly two items (dumbbell,
barbell) feeding three exercise types (`dumbbellpress`, `bicepscurl`, `barbellcurl`). If B42's
`FitnessExercises.exercisesType` table defines other home-equipment exercises (the V5.2 changelog
entry that made auto-days prefer carried equipment implies the mod already assumes more exist
than it currently uses), adding verified additional entries to `_exerciseCandidates`' equipment
tier would let more home-gym setups actually get used, the same value V5.2 was chasing.

**Exact API surface.** Partially verified, one real gate.

- `FitnessExercises.exercisesType` table shape and the full entry list: **verified** for the
  four entries currently referenced (`dumbbellpress`, `bicepscurl`, `barbellcurl`, `burpees`,
  plus the bodyweight three) via their production use in `_exerciseCandidates` and
  `_hasExerciseItem`'s `exeData.item`/`exeData.prop` field reads. **NOT verified**: whether the
  table defines additional entries (e.g. other equipment-gated exercises) that the mod has
  simply never looked for. CHANGELOG.md's V5.2 entry ("auto-days prefer carried equipment over
  burpees") describes tuning the EXISTING two-item pool's priority, not confirming the pool is
  exhaustive.
- `ISFitnessAction:new` signature and the `inventory:contains(item, true)` equipment gate:
  **verified**, unchanged by this candidate (same call shape, just more `exeData` entries feeding
  it).

**Effort:** S-M. If the live table lookup finds additional entries: one PR adding the verified
new entries to `_exerciseCandidates`'s equipment tier plus `_hasExerciseItem` coverage (already
generic, needs no change) and extending `test_priority_logic.lua`'s candidate-selection cases.
If the lookup finds nothing new: this candidate is simply rejected with the negative result
recorded, which is itself a useful, cheap outcome.

**Risk:** Medium, entirely concentrated in the verification gate. Implementing against a guessed
table shape is exactly the class of mistake the phantom-file/V2.1 `ISFitnessAction` incident
warns against; this candidate is explicitly NOT implementable until the live lookup happens.
Zero risk to the priority chain or existing exercises either way — new entries only ADD to the
candidate list `_exerciseCandidates` already iterates.

**Identity fit.** Good. Directly deepens the mod's single stated purpose (train well from real
equipment) rather than adding a new capability area.

**Testing note.** Same pattern as the existing equipment tier: `_hasExerciseItem` and the
XP-fatigue rotation (`_exerciseStillProductive`) are already generic over any `exeData`, so new
verified entries are additive test cases, not new test infrastructure.

**Verdict: Recommend**, explicitly gated on the user's live `FitnessExercises.exercisesType`
table lookup (in-game console or a decompiled Lua reference) before any implementation PR. If the
lookup finds no additional relevant entries, reject and record the negative result — do not
implement against a guess.

---

## Proposed V6.x ordering (for whichever subset is approved)

Ordering principle: purely observational and verified-surface candidates first; the
live-verification-gated candidate last.

| Milestone | Content | Why here |
|-----------|---------|----------|
| V6.1 | C2 (decision-reason visibility) | Zero behavior change, fully verified surface, smallest possible PR. |
| V6.2 | C1 (sickness-aware gating) | Small behavior change, fully verified surface, benefits from the reason line (V6.1) to show WHY the trainer paused for sickness. |
| V6.3 | C3 (exercise equipment variety) | Blocked on the user-only live `FitnessExercises` table lookup; ships last regardless of approval order. |

If a candidate is rejected, later milestones renumber; each milestone stays one or two PRs per
the existing cadence.

---

## Decision section (user)

Mark one box per row. This document (and the V6.0 milestone) is complete when every row is
marked; approved rows become V6.x milestones per the ordering above (adjusted to your picks).

| # | Candidate | Proposal verdict | Your decision |
|---|-----------|------------------|---------------|
| C1 | Sickness-aware exercise/scavenge gating | Recommend | [ ] Approve  [ ] Reject |
| C2 | Decision-reason visibility on the F11 panel | Recommend | [ ] Approve  [ ] Reject |
| C3 | Exercise equipment variety | Recommend (gated) | [ ] Approve  [ ] Reject |

Notes for the decision:

- Approving C3 also approves one user-only in-game (or decompiled-source) lookup of
  `FitnessExercises.exercisesType`'s full entry list before any implementation PR.
- C1's default `SICKNESS_EXERCISE_MAX` threshold value is a judgment call for review, not a
  live-verification gate — flag a preferred default (or "use your best judgment") in your
  decision if you approve it.
- All three candidates comply with the standing non-goals as they stood when this was drafted:
  no `addXp()`, no LLM sidecar, no splitscreen, no resurrection of deleted modules, no new
  external action surface. The 2026-07-21 partial reopening of the deleted-module non-goal does
  not affect them — none of the three touch Foraging, Combat, or Explore.
- Rejecting all three is a completely valid outcome: ROADMAP.md's stated direction is "harden
  and maintain," and none of this document's candidates are load-bearing for that direction.
