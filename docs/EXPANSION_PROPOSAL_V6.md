# AutoPilot Leveler: V6.0 Expansion Proposal

> ## ✅ DECIDED 2026-07-26. This document is now HISTORY; the live scope is `docs/MILESTONE_V6_0.md`
>
> The user answered directly on 2026-07-26 and both open rows are closed:
>
> - **C2 (decision-reason visibility on the F11 panel): APPROVED.** It carries into V6.0 unchanged.
> - **C1 (sickness-aware exercise/scavenge gating): REPLACED, not deferred and not rejected on its
>   merits.** In its place the user directed a different feature: **prioritise food gathering and
>   eating by the ABSENCE OF MALUS EFFECTS** (rank food by carrying no negative effect, in both the
>   eat path and what the looting path prefers to carry), scoped explicitly to the EXISTING looting
>   path, with the Foraging module staying deleted.
> - **C3: remains WITHDRAWN** on the 2026-07-25 negative lookup. No decision was needed and none
>   was given.
>
> **Read `docs/MILESTONE_V6_0.md` instead of this file for what is being built.** That document
> carries the slice plan, the source-verified evidence table, the remaining overridable defaults,
> and a done-when per slice that CI can check. Everything below is preserved unedited as the
> record of how the decision was reached, including the audit box and the strike-throughs; the
> C1 body in particular describes a candidate that is NOT being built.
>
> ---
>
> ## AUDITED 2026-07-25: two candidates left, and one of them needs an answer from you first
>
> This document was drafted 2026-07-20, four days before the project was decommissioned and
> revived, and its premises were re-verified against the live 42.19 install and the current code
> on 2026-07-25 (Product-role truth audit). Three things changed. **Read this box, then the
> Decision section at the bottom; the candidate bodies are unchanged except where marked
> AUDIT 2026-07-25.**
>
> 1. **C3 is WITHDRAWN, and it cost you nothing to settle.** It was gated on a lookup this
>    document called "user-only in-game work". That lookup is one shell command against the
>    installed game, it was run, and the answer is negative: B42.19 defines exactly **seven**
>    exercises and the mod already uses **all seven**, including all three equipment ones. There
>    is no "variety beyond dumbbell/barbell" to add because the game ships none. Rejecting on a
>    negative result is the outcome this document itself pre-authorised, so the row is withdrawn
>    rather than left for you to mark. Evidence in C3 below.
> 2. **C1 needs one answer from you before it can be implemented, and it is not the one this
>    document asked for.** Its proposed default ("sickness < ~40 does not interrupt training")
>    is very likely unreachable: two independent engine signals say `CharacterStat.SICKNESS` is
>    a **0.0-1.0** stat, not the 0-100 one this document assumed, so a threshold of 40 would
>    never fire and C1 would ship a dead gate. That is the exact failure mode that kept bug 5
>    alive through three fixes. See C1's AUDIT note.
> 3. **C2 is unchanged and still worth doing.** Re-verified at source: the decision reason is
>    still write-only, and nothing outside `AutoPilot_Telemetry` reads it.
>
> Two of this document's own evidence bullets were also found FALSE and are corrected in place
> below (struck through, not deleted, so the correction is auditable).

**Status:** DECIDED 2026-07-26 (drafted 2026-07-20, branch `autodev/v6.0-expansion-proposal`;
premises re-verified 2026-07-25; answered by the user 2026-07-26, see the decision box at the top).
C2 approved, C1 replaced by a user-directed feature, C3 withdrawn. The live scope document is
`docs/MILESTONE_V6_0.md`; this file is retained as the decision record.
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

## Why three candidates, not more (as drafted; two remain after the 2026-07-25 audit)

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
   > skill-XP actions (e.g. `ISRepairClothing` grants Tailoring XP in its own `complete()`, at
   > line 74), verified against the live install.
   > **⤷ CORRECTED 2026-08-13 by `docs/EXPANSION_PROPOSAL_V7.md` section 2; superseded wording,
   > quoted where it stood: *"`ISRepairClothing` grants Tailoring XP in its own `perform()`"*.
   > `perform()` grants XP nowhere in 42.19: all 41 uncommented `addXp(self.character, Perks.*)`
   > sites sit in `complete()`, `animEvent()`, `update()`, `start()` or `serverStart()`. The
   > reopening this note records still stands — only the hook name was wrong.**
   > This does NOT change any candidate below — all three were
   > designed inside the stricter constraint and none of them touch the reopened areas.
   >
   > **FURTHER BOUNDED 2026-07-25 (hard engine finding, does not affect this document's
   > candidates):** the reopened **Combat** territory cannot mean the mod swinging a weapon.
   > Build 42 exposes no attack API for an AI-driven character, verified while fixing the
   > user-reported "the character walks into zombies and dies" bug, so `AutoPilot_Threat` was made
   > FLEE-ONLY (`doFight`/`forceFight` deleted). Any V7.0 combat work is limited to positioning,
   > avoidance, luring and fleeing. Full statement and evidence: the HARD ENGINE FINDING bullet in
   > `ROADMAP.md`. Recorded here because this document is where a reader is told Combat is open.
5. **No new external action surface unless a candidate says so explicitly and justifies it.**
   Every candidate below either observes existing behavior or narrows an existing gate; none
   adds a new `ISXxxAction` call site to a previously-untouched vanilla system.

## Evidence policy

Every claim below was verified by reading the current code directly during this same
increment, not carried over from an older document:

- `CharacterStat.SICKNESS` and `MoodleType` coverage: `tests/lua_mock_pz.lua`'s verified-surface
  header (lines ~238-242), confirming `SICKNESS` is a real, already-mocked stat and that no
  `MoodleType.Sick`-equivalent is mocked (only `ENDURANCE`/`Unhappy` are).
  > **AUDIT 2026-07-25, PARTLY STALE (harmless).** The mock member is now spelled
  > `MoodleType.UNHAPPY`: the CamelCase name this bullet cites did not exist in B42 and had been
  > resolving to nil since the port, which is why unhappiness relief never fired (fixed in
  > PR #78, guarded by `tests/test_engine_symbols.lua`). The bullet's actual claim, that
  > `SICKNESS` is a real mocked stat and no sickness MOODLE is modelled, still holds. Related and
  > worth knowing for C1: a whole-install enumeration of `MoodleType.*` returns eleven members
  > (DRUNK, ENDURANCE, FOOD_EATEN, HEAVY_LOAD, HYPERTHERMIA, HYPOTHERMIA, PAIN, PANIC, STRESS,
  > TIRED, UNHAPPY) and none of them is a sickness moodle, so sickness really is stat-only.
- ~~`AutoPilot_Needs.getMoodleSnapshot`: `sick = math.floor(AutoPilot_Utils.safeStat(player,
  CharacterStat.SICKNESS))` is its only production use — display-only, feeds nothing else.
  Confirmed via a repo-wide grep for `SICKNESS` outside that one line.~~
  > **AUDIT 2026-07-25: FALSE, and it was false when this document was drafted.** The claimed
  > repo-wide grep missed a second production use that has been there since commit `93e08a8`
  > (v1.2.0), long before this document: `AutoPilot_Threat.lua:112` lists
  > `{ stat = CharacterStat.SICKNESS, threshold = 0.20, isNormalized = false }` in
  > `NEGATIVE_STAT_CHECKS`, consumed by `AutoPilot_Threat.countNegativeMoodles`. Re-checked this
  > audit with `grep -rn SICKNESS 42/media/lua/client/`, which returns three hits, not one.
  > The bullet is also wrong in the other direction: `getMoodleSnapshot`'s only in-mod caller is
  > `printStatus`, which is itself called from nowhere, so the `sick` value is **display-only in
  > name and displayed nowhere in fact** (filed as a LOW dead-reporting-path bug during PR #78).
  > Both corrections matter to C1 and are carried into it below.
- `AutoPilot_Telemetry.setDecision(action, reason, ...)`: its public API (`setDecision`,
  `logTick`, `onDeath`, `onShutdown`, `getPendingAction`, `getRunTick`) has no reason-reading
  getter. Confirmed neither `AutoPilot_UI.lua` nor `AutoPilot_Main.lua` reads a decision reason
  anywhere; only the resulting ACTION label reaches the panel/HUD via `getActionIntention`.
  > **AUDIT 2026-07-25: RE-VERIFIED AT SOURCE, still true.** The module's exported function list
  > is unchanged (`setDecision`, `logTick`, `onDeath`, `onShutdown`, `getPendingAction`,
  > `getRunTick`), and a repo-wide grep for `getLastReason|getDecision|lastReason` across
  > `42/media/lua/client/` and `tests/` returns zero hits. C2 is still unimplemented and still
  > implementable exactly as written.
- Exercise candidate pools (`_exerciseCandidates` in `AutoPilot_Exercise.lua`, moved there
  2026-07-20 PR #61): `dumbbellpress`/`bicepscurl`/`barbellcurl` (dumbbell/barbell equipment)
  plus `burpees`/`squats`/`pushups`/`situp` (bodyweight). No other `FitnessExercises.exercisesType`
  entries are referenced anywhere in the mod.
  > **AUDIT 2026-07-25: true, and it quietly refutes C3.** This bullet lists seven exercise
  > types; the live engine table defines exactly those seven and nothing else (see C3). The
  > evidence needed to settle C3 was therefore already sitting in this document's own evidence
  > section, one table lookup away, and the candidate was written as though the pool might be
  > incomplete without ever checking the one file that defines it.

~~No claim comes from a fresh read of the game install (the phantom-file lesson from V2.1/V3.2
still applies). Anything not in the repo's verified records is flagged **needs live
verification** below, and that verification is user-only in-game work.~~

> **AUDIT 2026-07-25: this policy was wrong, and it is what left C3 sitting unanswered.** The
> phantom-file lesson bans the FILE TOOLS against the game install (Read and Grep can return
> stale content there); it never banned reading the install, and it does not make such a read
> "user-only in-game work". A live shell read of the install is the standard, cheap move on this
> project and is how PRs #77 and #78 found two shipped defects on 2026-07-25 (the non-existent
> `Perks.Literacy` gate and the CamelCase `MoodleType.Unhappy`). Corrected policy: **claims about
> the engine are verified by live shell reads of the install, quoting file and line; only
> BEHAVIOUR that has to be watched in a running game is user-only.** Under the old policy this
> document gated a candidate on the user running a lookup that took one command here.

---

## Candidate summary

| # | Candidate | Effort | Risk | Verdict (as drafted 2026-07-20) | Verdict after the 2026-07-25 audit |
|---|-----------|--------|------|--------------------------------|-----------------------------------|
| C1 | Sickness-aware exercise/scavenge gating | S | Low | Recommend | Recommend, **blocked on one scale answer** (see C1) |
| C2 | Decision-reason visibility on the F11 panel | S | Low | Recommend | Recommend, premises re-verified, unchanged |
| C3 | Exercise equipment variety beyond dumbbell/barbell | S-M | Medium | Recommend (gated on live FitnessExercises verification) | **WITHDRAWN**: the gating lookup was run and came back negative |

Effort scale: S = one small PR; M = one or two PRs.

---

## C1. Sickness-aware exercise/scavenge gating

> ### AUDIT 2026-07-25: still recommended, but do not implement it as written
>
> Three corrections, one of which would have shipped a gate that can never fire.
>
> **(a) The scale is probably wrong, and the proposed default depends on it.** The Risk
> paragraph below suggests a default "high enough that mild sickness (SICKNESS < ~40) does not
> interrupt training", i.e. it assumes a 0-100 stat. Two independent engine signals say
> `CharacterStat.SICKNESS` is **0.0-1.0**:
> - `shared/Foraging/forageSystem.lua:1741-1746` (`getBodyPenalty`) reads
>   `getStats():get(CharacterStat.SICKNESS)` **without dividing**, while dividing `PAIN`,
>   `FOOD_SICKNESS` and `INTOXICATION` by 100 on the surrounding lines, then takes
>   `math.max` of all four against a 0-1 penalty.
> - `client/DebugUIs/DebugMenu/General/ISStatsAndBody.lua:85` registers `SICKNESS` with the
>   default slider step of `0.01` (`addSliderOptionEnum`, line 153-164), whereas the stats that
>   really are 0-100 integers get an explicit step of `1` there: `PANIC`, `BOREDOM`,
>   `UNHAPPINESS`, `DISCOMFORT`, `WETNESS`, `FOOD_SICKNESS`, `ZOMBIE_INFECTION`, `ZOMBIE_FEVER`.
>
>   A threshold of 40 on a 0-1 stat is unreachable, so C1 as drafted would ship a gate that never
>   fires and looks fine in every test. That is precisely how bug 5 survived three separate
>   fixes. **Cheapest resolution: do not depend on the answer.** Read the stat and normalise
>   defensively (`if v > 1 then v = v / 100 end`), express the tunable as a 0-1 fraction, and the
>   candidate is correct under either scale. The definitive check is one in-game print of
>   `getPlayer():getStats():get(CharacterStat.SICKNESS)` while sick, which is genuinely user-only
>   because it needs a running game with a sick character.
>
> **(b) "does nothing else" is false, and the same wrong-scale question already affects live
> code.** `CharacterStat.SICKNESS` has fed `AutoPilot_Threat.NEGATIVE_STAT_CHECKS` since commit
> `93e08a8` with `threshold = 0.20, isNormalized = false` (divide the raw value by 100, so it
> fires at raw 20). If the stat is 0-1, that entry can never count, and the same reasoning makes
> `STRESS` and `SANITY` suspect on the slider-step signal. Impact today is small because the only
> consumer, `countNegativeMoodles`, now merely picks between the telemetry reasons `flee_moodles`
> and `flee_default` (both branches flee since the flee-only rework), so it costs log fidelity
> rather than behaviour. It is filed as a LOW bug in the AutoPilot backlog. **C1 must not copy
> that entry's scale assumption.**
>
> **(c) "the Sick state (food poisoning, infection)" names stats C1 does not read.** B42 splits
> this across five stats, all present in the live install: `SICKNESS`, `FOOD_SICKNESS`, `POISON`,
> `ZOMBIE_FEVER`, `ZOMBIE_INFECTION`. Food poisoning specifically lives in `FOOD_SICKNESS`
> (`forageSystem.lua:1743`), which the mod never reads. So C1 gating on `SICKNESS` alone will
> **not** pause training for food poisoning. Decide explicitly which stats the candidate owns;
> `SICKNESS` plus `FOOD_SICKNESS` is the honest minimum for the stated motivation, and
> `ZOMBIE_INFECTION` is deliberately worth leaving out (pausing training changes nothing about
> that outcome).
>
> **Implementation note.** Any new `CharacterStat.X` read must be modelled in
> `tests/lua_mock_pz.lua` or `tests/test_engine_symbols.lua` fails the build (the enum-drift
> guard added in PR #78). `SICKNESS` is already modelled; `FOOD_SICKNESS` is not.

**What the player gets.** `CharacterStat.SICKNESS` is already read every cycle for the F11
panel's moodle snapshot but currently does nothing else — a character in the "Sick" state (food
poisoning, infection) keeps training and scavenging exactly as if healthy.
*(AUDIT 2026-07-25: both halves of that first clause are wrong. It reaches no panel, because
`getMoodleSnapshot`'s only caller is uncalled, and it does feed one other thing, the flee
negative-stat count. The paragraph's actual point, that sickness never gates training or
scavenging, survives both corrections. See the box above.)* This candidate adds
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

> ### AUDIT 2026-07-25: re-verified, unchanged, and now worth slightly more
>
> Every premise below still holds at source: `AutoPilot_Telemetry`'s exported functions are still
> `setDecision`, `logTick`, `onDeath`, `onShutdown`, `getPendingAction`, `getRunTick` (no reason
> getter), and a grep for `getLastReason|getDecision|lastReason` across `42/media/lua/client/`
> and `tests/` returns zero hits, so nothing outside the module reads a decision reason. Two
> notes from the audit:
> - The value went **up**, not down. The audit confirmed that the mod's other "why" surface,
>   `AutoPilot_Needs.printStatus`, is dead code that nothing calls, so today the player has no
>   way at all to see why the mod chose what it chose. C2 is the only candidate that changes that.
> - The reason vocabulary grew since drafting and the candidate absorbs it for free:
>   `fail_reason=pain_block|panic` (PR #67) is exactly the "why is it doing nothing" case a
>   player stares at the panel to answer.

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

## C3. Exercise equipment variety beyond dumbbell/barbell (WITHDRAWN 2026-07-25)

> ### AUDIT 2026-07-25: the gating lookup was run. Negative result. Candidate withdrawn.
>
> This candidate's own verdict said: *"explicitly gated on the user's live
> `FitnessExercises.exercisesType` table lookup ... If the lookup finds no additional relevant
> entries, reject and record the negative result."* The lookup is a single shell read of the
> installed game, it was run on 2026-07-25, and it found no additional entries. The negative
> result is recorded here and the candidate is withdrawn by its author rather than left as a row
> for the user to mark. Overriding this and re-opening it is of course still the user's call.
>
> **The evidence.** `shared/Definitions/FitnessExercises.lua` in the live 42.19 install is 65
> lines long and defines `FitnessExercises.exercisesType` with exactly **seven** entries:
>
> | Entry | `item` (equipment gate) | `xpMod` | Used by the mod? |
> |-------|------------------------|---------|------------------|
> | `squats` | none (bodyweight) | 1 | yes |
> | `pushups` | none (bodyweight) | 1 | yes |
> | `situp` | none (bodyweight) | 1 | yes |
> | `burpees` | none (bodyweight) | 0.8 | yes |
> | `barbellcurl` | `Base.BarBell` | 1.2 | yes |
> | `dumbbellpress` | `Base.DumbBell` | 1.8 | yes |
> | `bicepscurl` | `Base.DumbBell` | 1.8 | yes |
>
> The mod's auto pool (`_exerciseCandidates`, `AutoPilot_Exercise.lua:202-203`) is
> `dumbbellpress, bicepscurl, barbellcurl, burpees, squats, pushups, situp`: all seven, with the
> three equipment entries deliberately leading since V5.2. **There is no equipment exercise in
> B42.19 that the mod does not already use, and no equipment item beyond the dumbbell and the
> barbell.** The premise of the candidate, that the pool might be incomplete, is false.
>
> **Absence claim, stated with its search scope (this is the part the original document skipped).**
> The claim is "vanilla B42.19 defines no other exercise". Searched: the whole
> `media/lua` tree of the install for any other definition or mutation of the table
> (`grep -rn "exercisesType\[" .` returns exactly one hit, `client/ISUI/ISFitnessUI.lua:147`,
> which READS it; `grep -rl exercisesType .` returns only that file and the definition file).
> Not claimed: that no third-party mod can add entries at runtime. It can, and the mod would not
> pick them up, because `_exerciseCandidates` is a hardcoded whitelist rather than an iteration
> over the table.
>
> **If you still want the value C3 was chasing**, the only remaining version of it is a different
> candidate: iterate `FitnessExercises.exercisesType` generically and select by `xpMod` and
> equipment availability, instead of hardcoding seven names. That would make the mod
> automatically support exercises added by other mods or by a future Build. It is NOT scheduled
> work and is not proposed here; it is recorded so the idea is not lost with the withdrawal.

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
| ~~V6.3~~ | ~~C3 (exercise equipment variety)~~ | **WITHDRAWN 2026-07-25**: the lookup it was blocked on was run and came back negative. |

If a candidate is rejected, later milestones renumber; each milestone stays one or two PRs per
the existing cadence.

> **AUDIT 2026-07-25, two corrections to this table.**
> - **The "V6.x" labels no longer match how this mod is versioned.** `mod.info` was reset from
>   `5.8` to `modversion=0.1.0` on 2026-07-25 at the user's direction, to signal a revived mod in
>   active rework. Read V6.1 and V6.2 as milestone NAMES for the two remaining candidates, not as
>   version numbers to ship. The version any of this actually ships under is a user decision, as
>   all version bumps on this project are.
> - **The ordering still holds, and for a better reason than before.** C2 before C1 was argued on
>   size; the audit adds a real dependency. C1 now has a live scale question attached (see its
>   AUDIT note), and C2 puts the mod's chosen reason on screen, which is the cheapest way to see
>   in-game whether a new sickness gate is firing at all. Ordering by dependency and by what is
>   answerable, never by calendar.

---

## Decision section (user)

**ANSWERED 2026-07-26. Both rows are closed; the table below records what was decided, and the
remaining open choices moved to `docs/MILESTONE_V6_0.md` section 5. The paragraphs after this
table are the pre-decision recommendations, kept unedited as the record.**

| # | Candidate | Verdict after audit | Decision (user, 2026-07-26) |
|---|-----------|---------------------|---------------|
| C1 | Sickness-aware exercise/scavenge gating | Recommend, with the defaults below | **REPLACED.** Not rejected on merit and not deferred: the user directed a different feature into the slot, "prioritise food gathering and eating by the ABSENCE OF MALUS EFFECTS", scoped to the existing looting path. The C1 body below describes work that is NOT being built. |
| C2 | Decision-reason visibility on the F11 panel | Recommend, premises re-verified | **[x] APPROVED**, unchanged, now V6.0-3 |
| ~~C3~~ | ~~Exercise equipment variety~~ | **WITHDRAWN 2026-07-25**, lookup ran, negative result: B42.19 defines seven exercises and the mod already uses all seven | no decision needed (say so if you want it re-opened anyway) |

Recommended defaults for C1, each overridable, each a one-word "no" if you disagree:

| Question the audit opened | Recommended default |
|---------------------------|---------------------|
| Which stats does the gate own? | `CharacterStat.SICKNESS` **and** `CharacterStat.FOOD_SICKNESS` (food poisoning lives in the second one, and the candidate's own motivation names it). NOT `ZOMBIE_INFECTION`, `ZOMBIE_FEVER` or `POISON`: pausing training changes nothing about those outcomes. |
| Is the stat 0-1 or 0-100? | Do not depend on the answer. Normalise defensively (`if v > 1 then v = v / 100 end`) so the gate is correct under either scale, and express the tunable as a 0-1 fraction. |
| Threshold default | `0.30` as a fraction, so mild sickness keeps training and a genuinely sick character rests. |
| Does it treat sickness? | No. Yield the exercise slot and the proactive-scavenge slot, queue nothing new. There is no Lua-side "cure sickness" timed action in the install (searched: the whole `media/lua` tree; `CharacterStat.SICKNESS` appears only in the debug menu and in `forageSystem`, neither of which treats it), so "stop making it worse" is the honest scope, exactly as the candidate says. |

Other notes for the decision:
- Both remaining candidates comply with the standing non-goals as they stood when this was
  drafted: no `addXp()`, no LLM sidecar, no splitscreen, no resurrection of deleted modules, no
  new external action surface. Neither touches Foraging, Combat, Explore or Skills, so neither
  the 2026-07-21 reopening of that non-goal nor the 2026-07-25 flee-only engine finding affects
  them.
- Rejecting both is still a completely valid outcome: ROADMAP.md's stated direction is "harden
  and maintain," and none of this document's candidates are load-bearing for that direction. The
  revival's real queue right now is the `## Bugs` section of the AutoPilot backlog plus the
  in-game smoke tests waiting on you, not this document.
- Nothing here is scheduled work until a row is marked. The audit changed only what is TRUE in
  this document; it did not approve anything.
