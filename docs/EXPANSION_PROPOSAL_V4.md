# AutoPilot Leveler: V4.0 Expansion Proposal

**Status:** DRAFT for user decision (drafted 2026-07-19, branch `autodev/v4.0-expansion-proposal`).
**Fulfils:** ROADMAP.md, milestone "V4.0: expansion track kickoff". The milestone is done when
the user has marked accept or reject on every candidate in the Decision section at the bottom.
**Scope discipline:** implementation is user-gated. Nothing in this document is scheduled work
until a candidate is approved; each approved candidate becomes its own V4.x milestone sized as
one or two small PRs.

---

## Ground rules (standing non-goals, restated from ROADMAP.md)

Every candidate below was designed inside these constraints and each candidate section states
how it complies:

1. **No direct `addXp()` grants.** Rejected in V3.0 as cheating; XP must come from real queued
   actions (CHANGELOG.md V3.0). Vanilla skill-book multipliers earned via a real `ISReadABook`
   action are the game's own mechanic, not a grant.
2. **No LLM sidecar.** Retired; `release.yml` asserts no anthropic imports and the Kahlua
   sandbox forbids HTTP (ROADMAP.md).
3. **No splitscreen.** Removed in V3.2 because it could not be made reliable (CHANGELOG.md V3.2).
4. **No resurrection of deleted modules as they were.** Skills / Foraging / Vehicles / Combat /
   Explore / Actions stay deleted (CHANGELOG.md V3.1). Where a candidate touches territory a
   deleted module once covered, it is a new, narrowly scoped design built on the current
   17-module architecture, never a restore.

## Evidence policy

Every API claim below cites one of the repo's own verified records:

- **ROADMAP.md V3.8 checklist API list**: `ISFitnessAction:new` signature, exercise definitions
  and xpMod values, `PZAPI.ModOptions`, `getSpecificPlayer`, sleep flow
  (`onSleepWalkToComplete`), `ISRestAction` 3-arg, `ISTimedActionQueue.addGetUpAndThen`, and
  the `inventory:contains` equipment gate.
- **`tests/lua_mock_pz.lua` verified-surface header** (V3.4 PR2 mock audit, 2026-07-19): the
  authoritative map of every PZ API the mod calls, with coverage grades
  ([MA] assertion-bearing mock, [M] mocked, [S] suite-local, [G] documented gap).
- **CHANGELOG.md** V2.1 / V3.0 / V3.1 / V3.2 / V3.3 entries (live-install and running-game
  verification sweeps).
- **docs/architecture.md** (the current 17-module design) and in-module header comments
  (`AutoPilot_XP.lua`, `AutoPilot_Options.lua`, `AutoPilot_Barricade.lua`).

No claim comes from a fresh read of the game install. That rule exists because of the
phantom-file incident: V2.1 shipped a wrong `ISFitnessAction` signature from a stale copy while
tests stayed green, and V3.2 had to restore the original from a running-game stack trace
(CHANGELOG.md V3.2; mock header). Anything not in the repo's verified records is flagged
**needs live verification** below, and that verification is user-only in-game work.

---

## Candidate summary

| # | Candidate | Effort | Risk | Verdict |
|---|-----------|--------|------|---------|
| C1 | Skill-book reading sessions (multiplier prep for action-trained perks) | M | Medium | Recommend (gated on live SkillBook re-verification) |
| C2 | Woodwork XP visibility on the existing barricade maintenance pass | S | Low | Recommend |
| C3 | Configurable training programs (weekly splits, rest days) | M | Medium | Recommend |
| C4 | Adaptive strategy packs (opt-in presets over the bounded rules) | S-M | Low-Medium | Defer |
| C5 | F11 session history and trends | M | Medium | Recommend |
| C6 | Doctor (First Aid) passive XP visibility | S | Low | Recommend |

Effort scale: S = one small PR; M = one or two PRs; L = multiple PRs plus design work (no L
candidates made the cut).

---

## C1. Skill-book reading sessions (multiplier prep for action-trained perks)

**What the player gets.** Before performing actions that earn a non-exercise perk's XP, the
character reads the matching unfinished skill book for their current level band, so the XP from
those real actions lands with the vanilla book multiplier applied. Concretely this serves the
perks the mod already trains through real actions: Woodwork via the barricade maintenance pass
(C2) and Doctor via real wound treatment (C6). A "reading: <book>" status joins the F11 trainer
status line. This is NOT for Strength/Fitness: V3.1 removed exercise-book reading precisely
because no STR/FIT books exist in B42 (CHANGELOG.md V3.1), and that fact stands.

**Why it is legitimate leveling, not cheating.** The multiplier is the game's own mechanic,
earned by a real queued `ISReadABook` action that costs in-game time, light, and literacy. No
`addXp()` anywhere. ROADMAP.md names skill-book reading as the sanctioned route into
non-exercise skills ("Where a real queued-action path exists (skill-book reading, carpentry via
the barricade pass), the V4.0 expansion proposal is the route in").

**Exact API surface.**

- `ISReadABook:new(character, book)` + `ISTimedActionQueue.add`: **verified**. Production
  callsite exists today in `AutoPilot_Needs.doRead` (boredom reading, `AutoPilot_Needs.lua`
  lines 596-640); the mock carries it as [M] (unexercised in suites; see testing note).
- Literacy gate (`getPerkLevel(Perks.Literacy)` pcall) and `player:tooDarkToRead()`:
  **verified as production patterns** in the same `doRead` function, both pcall-guarded.
- Perk naming for book matching: **verified**. Carpentry=Woodwork, FirstAid=Doctor,
  Foraging=PlantScavenging, confirmed against `server/XpSystem/XPSystem_SkillBook.lua` and
  recorded in the mock's Perks section (mock header; mock lines 183-199).
- `player:getXp():getMultiplier(perk)`: **verified** per the `AutoPilot_XP.lua` header (42.19
  API list) and already wired into `AutoPilot_XP.getMetrics` (the panel's multiplier field).
- Readable acquisition seams: `AutoPilot_Inventory.getReadable` / `lootNearbyReadable`
  **exist today** (called from `doRead`); a skill-book-specific selector is new code.
- `SkillBook` table (perk -> books by level band): **needs live verification**. CHANGELOG.md
  V3.0 records it as verified ("SkillBook table + ISReadABook, verified", with level-band
  matching), but the callsite was deleted in V3.1 and the table's exact shape is NOT in the
  mock's verified-surface header. Re-verify the lookup shape in-game before implementation;
  until then the mock must not grow a guessed SkillBook mock.

**Effort:** M. Minimal slice (one PR): bias the existing boredom-read book selection toward an
unfinished matching skill book when C2/C6 perks are visible targets. Full slice (second PR): a
scheduled pre-action read in the chore band of the priority chain.

**Risk:** Medium. (a) The SkillBook re-verification gate above. (b) Scheduling: reading
occupies the timed-action queue, and the V3.2 scavenging-starvation incident (CHANGELOG.md
V3.2, fourth dry-run finding) is the standing lesson that a background behavior can starve the
trainer; reading must sit below EXERCISE in the priority chain and carry a daily cap. (c) The
literacy gate makes the feature a silent no-op for illiterate characters (existing, handled
behavior in `doRead`).

**Identity fit.** Strong. The mod's identity is "leveling from real actions"; multiplier prep
makes the actions the mod already performs level faster, which is exactly the leveler promise.

**Testing note.** The mock's header records `ISReadABook` as [M] but unexercised: every suite
hits `doRead`'s literacy gate because `Perks.Literacy` is intentionally ABSENT from the mock
(not in the verified record). A reading feature therefore needs: (1) the book-selection logic
as a pure function (perk, level, inventory list) -> book, unit-testable without any engine
mock; (2) a suite-local `Perks.Literacy` override to drive the queue path end-to-end; (3) a
SkillBook mock added ONLY after the live re-verification, with the verified shape cited in the
mock header per the V3.4 audit convention.

**Verdict: Recommend**, explicitly gated on the user's live SkillBook re-verification session.
If C2 and C6 are both rejected, this candidate loses its consumers and should be rejected too.

---

## C2. Woodwork XP visibility on the existing barricade maintenance pass

**What the player gets.** The barricade maintenance the mod already performs quietly earns
Carpentry (42.19 name: Woodwork) XP; this candidate makes that visible. The Woodwork perk joins
the XP metrics engine (level, session gain) and gets a compact line on the F11 panel, so the
player sees the safehouse upkeep contributing to a skill. Paired with C1, book-multiplier prep
makes that XP meaningfully larger.

**Exact API surface.** All **verified**; no new engine APIs at all.

- Barricading grants Carpentry XP through a real queued action: recorded in CHANGELOG.md V2.1
  ("carpentry day runs a real barricade pass (Carpentry XP)").
- `ISBarricadeAction:new(character, windowObj, isMetal, isMetalBar)` with EQUIPPED hammer
  (primary) + plank (secondary) + 2 or more nails: V2.1-verified signature, assertion-bearing
  suite-local mock ([S] in `test_home_map_barricade` per the mock header), and the production
  callsite is `AutoPilot_Barricade._doScan` today. This candidate does not touch the action
  call; it only observes.
- `Perks.Woodwork`: verified 42.19 naming (mock header, against
  `server/XpSystem/XPSystem_SkillBook.lua`).
- `AutoPilot_XP.sample` / `getMetrics` are already perk-generic (`AutoPilot_XP.lua`; verified
  API list in its header: `getXp():getXP`, `getPerkLevel`,
  `PerkFactory.getPerk():getTotalXpForLevel`).

**Effort:** S. Sample `Perks.Woodwork` when maintenance queues actions (Barricade already
returns the queued count to Needs), plus one panel line.

**Risk:** Low. Honest cap on the promise: this XP is incidental. The maintenance pass only
fires when windows have been de-barricaded (architecture.md, Barricade row), so Woodwork gain
is slow and event-driven. Deliberately un-barricading to re-barricade is out of scope: it burns
nails for manufactured XP and is exactly the kind of gamey loop the no-addXp principle exists
to avoid.

**Identity fit.** Good. Extends "the leveler tracks what real actions earn" to a third perk
without adding a single new action.

**Testing note.** Mock already carries `Perks.Woodwork`; extend `test_leveler_metrics.lua`
(XP engine is perk-generic, so tests are near-copies of the STR/FIT ones) and add one
`test_home_map_barricade.lua` assertion that a maintenance pass triggers a Woodwork sample. No
new mock surface, no new gaps.

**Verdict: Recommend.**

---

## C3. Configurable training programs (weekly splits, rest days)

**What the player gets.** A "Training program" selector in Options > Mods > AutoPilot Leveler:
for example Balanced (today's Auto behavior, default), Strength emphasis (5 STR days / 2 FIT),
Fitness emphasis (inverse), Alternating days, and a rest-day rule (every Nth day the trainer
idles and lets survival chores and endurance recovery own the day). The F11 panel shows
"today: STR day (program: Strength emphasis)". Pure scheduling on top of the existing focus
plumbing; zero new action types.

**Exact API surface.** All **verified**; nothing new.

- `PZAPI.ModOptions` (create / addSlider / addKeyBind / getOption:getValue / apply): verified
  in 42.19 per the `AutoPilot_Options.lua` header and CHANGELOG.md V3.3; also on the ROADMAP
  V3.8 re-verification checklist. The mock header grades it [G]: a documented, deliberate gap
  (registration is pcall plus existence guarded, falls back to compiled-in defaults).
- Day tracking: `getGameTime():getCalender():getDay()` ([M] in the mock, including the
  "getCalender" spelling note); `doExercise` already uses day rollover for the daily set cap
  (architecture.md, Exercise Focus Flow).
- Focus plumbing: `Leveler` focus persisted in player ModData, MP-safe via `transmitModData`
  (architecture.md, Leveler row); `Needs.trainExercise(player, focus)` is the existing seam.

**Effort:** M. PR1: pure scheduler (program id, day number) -> focus-or-rest decision inside
Leveler, plus tests. PR2: the ModOptions selector plus the panel line.

**Risk:** Medium. A scheduler bug that returns "rest" too eagerly would idle the trainer, which
is the V3.2 starvation incident in new clothes; mitigated by making the scheduler a pure
function with exhaustive unit tests and by keeping Balanced-no-rest-days as the compiled-in
default (identical to current behavior when Options never loads). The ModOptions [G] gap means
the selector wiring itself is only playtest-verifiable, same as the existing sliders.

**Identity fit.** Strong. It deepens the mod's single job (schedule exercise well) and gives
the AFK player agency over the week's shape without touching survival logic.

**Testing note.** The scheduler must live in `AutoPilot_Leveler` (or a small helper) rather
than `AutoPilot_Options`, because the mock header records that NO suite loads AutoPilot_Options
(documented gap) and that must stay true. New tests: table-driven scheduler cases in
`test_leveler_metrics.lua` (each program across a 14-day sweep, rest-day boundaries, default
fallback when no option value is present). No new mock surface.

**Verdict: Recommend.**

---

## C4. Adaptive strategy packs (opt-in presets over the bounded rules)

**What the player gets.** A "Strategy pack" option that swaps the Adaptive layer's rule
parameterization for a themed preset: for example Cautious (stronger horde-response deltas,
tighter floors), Homebody (loot-radius rules bite sooner), Standard (today's RULES table,
default). Packs only re-parameterize the existing bounded rules (per-death deltas, floors,
caps, min_deaths); every applied adjustment still appears in the F11 panel exactly as today.

**Exact API surface.** All **verified**; nothing new. `AutoPilot_Adaptive.aggregate` /
`applyRules` are pure Lua over the RULES table (`AutoPilot_Adaptive.lua`), death-log input
comes via `DeathLog.readLines`/`parseLine` (`getFileReader` is [MA] in the mock), pack
selection would ride the same ModOptions surface as C3 ([G] documented gap).

**Effort:** S-M (the mechanism is small; the real cost is choosing pack values responsibly).

**Risk:** Low-Medium. The hard floors and caps stay, so no pack can tune the mod into absurd
behavior; the real risk is design-by-guesswork. The evidence base for what packs SHOULD contain
is accumulated death-log data and Workshop feedback, and the mod has been public for one day
(published 2026-07-18, ROADMAP.md). ROADMAP's Later section already holds "Adaptive-rule tuning
informed by Workshop feedback and accumulated death-log data" as the successor to exactly this
idea.

**Identity fit.** Moderate. It polishes the death-learning layer's personality but does not
level anything faster; it is tuning surface, not capability.

**Testing note.** Cheapest coverage in the whole proposal: `applyRules`/`aggregate` are already
unit-tested pure functions, and packs are just alternative RULES tables run through the same
assertions (bounds, idempotence). No new mock surface.

**Verdict: Defer.** Revisit after one or two Workshop feedback cycles (V3.7 pipeline) have
produced real death-log evidence to design pack values from. Approving it now would be
premature parameter invention.

---

## C5. F11 session history and trends

**What the player gets.** A history block on the F11 panel: the last N sessions (per session:
XP gained per perk, hours survived, sets completed, end status dead/timeout) plus a compact
text sparkline of session XP gains, so the player can see whether the grind is trending up
without leaving the game. Per-perk ETA is already on the panel (architecture.md, F11 Panel);
this adds the longitudinal view the panel currently lacks.

**Exact API surface.** All **verified**, with a design constraint.

- Write path: `Telemetry.onDeath` / `onShutdown` already exist as session-end hooks
  (architecture.md, Telemetry row) and would append ONE compact key=value summary line per
  session to a new `auto_pilot_sessions.log` via `getFileWriter` ([MA] in the mock, append
  semantics assertion-tested because of the V2.1 truncate bug; the only game-safe file API in
  PZ's sandbox per architecture.md).
- Read path: `getFileReader` with `:readLine()`/`:close()` ([MA] in the mock; the exact
  pattern `DeathLog.readLines` uses today).
- Feasibility precedent: `triage_run_log.py` already derives per-session STR/FIT deltas and
  end status from the telemetry stream (session boundary = run_tick reset, per its header), so
  the summary content is proven derivable; in-game we compute it directly at session end
  instead of re-parsing the 20k-line run log in Kahlua.
- Rendering: `ISCollapsableWindow` panel additions, [G] in the mock (NO suite loads
  AutoPilot_UI; documented gap).

**Effort:** M. PR1: session-summary write + parse + aggregate (Telemetry plus a small pure
helper), bounded file (keep the newest 30 summaries, mirroring the V3.3 rotation pattern).
PR2: the panel block.

**Risk:** Medium. The rendering half sits in the audited UI coverage gap, so panel regressions
are playtest-only (existing condition, not a new one; V3.2's "panel errors print to the real
console and flash the HUD" behavior limits the blast radius). File growth is bounded by
design. MP note: per-player keying already exists in Telemetry (architecture.md).

**Identity fit.** Strong. The F11 panel is the leveler's face; "is my grind working" over days
is the question the panel exists to answer.

**Testing note.** All logic (summary line format, parser, aggregation, retention bound) must
live outside `AutoPilot_UI` so it is fully unit-testable; add cases alongside
`test_telemetry_schema.lua`'s existing write/parse patterns, using the mock's append-counting
`getFileWriter` to assert the file never truncates. The UI [G] gap stays documented, not
widened: the panel only renders pre-formatted strings.

**Verdict: Recommend.**

---

## C6. Doctor (First Aid) passive XP visibility

**What the player gets.** The Medical module already treats real wounds with real actions, and
First Aid trains passively from exactly that (CHANGELOG.md V3.0 skill registry: "passive:
First Aid (trains when treating real wounds)"). This candidate samples the Doctor perk when
treatment actions queue and shows a compact Doctor line (level, session gain) on the F11
panel. With C1 approved, an unfinished first-aid book multiplies that passive gain.

**Exact API surface.** All **verified**; no new engine APIs.

- `Perks.Doctor`: verified 42.19 naming (mock header, against
  `server/XpSystem/XPSystem_SkillBook.lua`).
- Treatment actions already queue from `AutoPilot_Medical.check` (architecture.md;
  `ISApplyBandage` is [MA] in the mock, V2.1/V3.2 sweep-verified).
- `AutoPilot_XP` is perk-generic (see C2).

**Effort:** S. Same shape as C2; the two share one panel-layout change if both are approved.

**Risk:** Low. Purely observational; no behavior change to Medical.

**Identity fit.** Good. Same principle as C2: real actions the mod already performs, made
visible as leveling progress.

**Testing note.** Mock already has `Perks.Doctor`; extend `test_leveler_metrics.lua` with
Doctor sampling cases and one `test_medical_logic.lua` assertion that treatment triggers a
sample. No new mock surface, no new gaps.

**Verdict: Recommend.**

---

## Proposed V4.x ordering (for whichever subset is approved)

Ordering principle: verified-surface, small, observational wins first; the one candidate with a
live-verification gate later; the deferred candidate last, behind evidence.

| Milestone | Content | Why here |
|-----------|---------|----------|
| V4.1 | C2 + C6 (action-perk visibility: Woodwork + Doctor) | Both S, zero new engine surface, shared panel/XP seams; one or two small PRs total. |
| V4.2 | C5 (session history and trends) | Builds on the richer panel; data layer is fully testable now. |
| V4.3 | C3 (training programs) | M-effort scheduling; benefits from the panel work landing first so programs are visible. |
| V4.4 | C1 (skill-book reading) | Blocked on the user-only live SkillBook re-verification session; consumes C2/C6 as its payoff targets. |
| V4.5 | C4 (strategy packs), only if un-deferred | Wants accumulated death-log and Workshop-feedback evidence (V3.7 pipeline) before values are chosen. |

If a candidate is rejected, later milestones renumber; each milestone stays one or two PRs per
the ROADMAP cadence. Note C1's dependency: with both C2 and C6 rejected, C1 should be treated
as rejected as well.

---

## Decision section (user)

Mark one box per row. This document (and the V4.0 milestone) is complete when every row is
marked; approved rows become V4.x milestones per the ordering above (adjusted to your picks).

| # | Candidate | Proposal verdict | Your decision |
|---|-----------|------------------|---------------|
| C1 | Skill-book reading sessions | Recommend (gated) | [ ] Approve  [ ] Reject |
| C2 | Woodwork XP visibility (barricade pass) | Recommend | [x] Approve (2026-07-19; shipped as V4.1)  [ ] Reject |
| C3 | Configurable training programs | Recommend | [ ] Approve  [ ] Reject |
| C4 | Adaptive strategy packs | Defer | [ ] Approve  [ ] Reject  [ ] Confirm defer |
| C5 | F11 session history and trends | Recommend | [ ] Approve  [ ] Reject |
| C6 | Doctor passive XP visibility | Recommend | [x] Approve (2026-07-19; shipped as V4.1)  [ ] Reject |

Notes for the decision:

- Approving C1 also approves one user-only in-game verification session (SkillBook table shape
  on 42.19) before any implementation PR.
- C4's "Confirm defer" keeps it in ROADMAP's Later bucket with the existing
  "Adaptive-rule tuning" candidate; "Approve" pulls it into V4.5 despite the thin evidence
  base; "Reject" drops it entirely.
- All six candidates comply with the standing non-goals: no `addXp()`, no LLM sidecar, no
  splitscreen, no resurrection of deleted modules as they were.
