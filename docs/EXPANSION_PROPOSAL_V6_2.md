# AutoPilot: V6.2 Expansion Proposal

> **STATUS: DECIDED 2026-08-01 — APPROVED WITH DEFAULTS (user decision, direct, decision
> walkthrough; recorded in the backlog banner).** C1 and C2 are approved as written (C1's D1-D4
> defaults included), sequenced C1 then C2, each its own PR. C3 stays SESSION-GATED with default
> WAIT. D4 (drop the superseded stash) is asked again after C1 merges, never silently. The body
> below is preserved unedited as the decision record.
>
> Implementation state: **C1 SHIPPED** (moodle-aligned triggers, the PR that flipped this banner).
> C2 is the next dev slice. C3 waits on the next in-game session's exercise-share measurement.
>
> Original banner, for the record: *STATUS: PROPOSED 2026-08-01, AWAITING USER DECISION.* Every
> open choice below carries an overridable default, so "approve with defaults" (or "approve C1
> only", etc.) is a complete answer. Nothing here is implemented yet; net-new dev on this project
> is proposal-gated (backlog rule, 2026-07-26).

## 1. Why this proposal exists, and why now

V6.0 (malus-aware eat/loot ranking + decision-reason visibility) and V6.1 ("train more,
lie less") are both COMPLETE as of 2026-08-01. The V6 proposal pipeline is spent: C2 shipped
as V6.0-3, C1 was replaced by the malus feature and shipped, C3 was withdrawn on a negative
live lookup. The backlog item that opened this slot (2026-08-01, PR #102's closure) says the
product queue's top action, "when a milestone completes, define the next one", is genuinely
open, and adds an honesty constraint: the best input for the NEXT milestone is the next
in-game session's telemetry, not more static analysis.

This proposal respects that constraint instead of arguing with it:

- The one candidate that depends on session evidence (C3) is explicitly SESSION-GATED and
  its default is WAIT.
- The two session-independent candidates are grounded in evidence that already exists:
  C1 revives YOUR OWN work-in-progress found in the repo's stash, and C2 fixes the last
  still-open CONFIRMED finding from the 2026-07-24 fast-forward investigation. Neither is
  invented from fresh code reading.
- The pending v0.2.0 release-scope question (RELEASE-PREP item in the backlog, dated
  2026-08-01) is deliberately NOT part of this proposal. It stays its own one-word user call.

## 2. C1: Moodle-aligned hunger/thirst triggers (revives your stashed WIP)

**Origin, which is the strongest signal this is wanted:** the repo carries `stash@{0}`
("WIP on main: 73f3a32", one file, +25/-13, from the March phase-2 period). It changes
`AutoPilot_Needs` so eating and drinking trigger when the game's own "Hungry"/"Thirsty"
moodle reaches level >= 1, with the raw stat thresholds kept as fallbacks. That is user
intent recorded in the repo itself, never shipped.

**What the code does today (verified at source this run):** hunger and thirst react to raw
stats only. `AutoPilot_Constants.HUNGER_THRESHOLD = 0.15` (Constants.lua:145) and
`THIRST_THRESHOLD = 0.15` (Constants.lua:150), consumed in `AutoPilot_Needs.shouldInterrupt`
(Needs.lua:334-340) and `check()` (Needs.lua:388-391 thirst, :414+ hunger). Both are
player-tunable sliders since V4.7, and V5.7 lowered the defaults 0.20 -> 0.15.

**Honest value assessment:** part of the stash's original pain is already gone; the V4.7
sliders plus the V5.7 lowering mean the stat trigger now fires close to where the level-1
moodle appears. The residual value is (a) the mod reacts to the same signal the game shows
the player, so its behaviour needs no explanation, and (b) the trigger survives any future
engine retuning of the hidden stat scale, the exact defect class that killed the original
V6 C1 (a threshold on a scale the author assumed wrong).

**Surface verification (done THIS RUN, closing the gap that made the stash unshippable):**
the stash uses `MoodleType.HUNGRY` and `MoodleType.THIRST`, names that appear NOWHERE in
the install's Lua (a live grep of `media/lua` finds vanilla Lua touching only DRUNK,
ENDURANCE, FOOD_EATEN, HEAVY_LOAD, HYPERTHERMIA, HYPOTHERMIA, PAIN, PANIC, STRESS, TIRED,
UNHAPPY). The question is Java-side, and it was settled by reading the enum out of the jar:

    python zipfile read of projectzomboid.jar ->
    zombie/scripting/objects/MoodleType.class constant pool:
    ... TIRED, HUNGRY, PANIC, SICK, BORED, UNHAPPY, BLEEDING, WET, HAS_A_COLD, ANGRY,
    STRESS, THIRST, INJURED, PAIN, HEAVY_LOAD, DRUNK, ... UNCOMFORTABLE, NOXIOUS_SMELL,
    FOOD_EATEN

`HUNGRY` and `THIRST` are real B42.19 constants in the SAME enum that provides the five
constants the mod already uses successfully in-game (ENDURANCE, UNHAPPY, PAIN, PANIC,
HEAVY_LOAD), so this sits on verified surface. `safeMoodleLevel` +
`getMoodles():getMoodleLevel()` are already the mod's standard moodle read (Needs.lua:122,
Utils.lua:37, Exercise.lua:33, Mood.lua:50).

**Overridable defaults:**

- **D1 (trigger shape):** moodle >= 1 OR the existing tunable stat threshold, a pure
  widening. The sliders keep their meaning and the moodle arm cannot make the mod eat
  LATER than today. This is the stash's own OR shape.
- **D2 (where):** both `check()` and `shouldInterrupt()`, matching the stash, so an
  in-progress action is interrupted by the same signal that would start one.
- **D3 (telemetry honesty):** new decision reasons `hunger_moodle` / `thirst_moodle` when
  the moodle arm fired and the stat arm alone would not have. Both get `_REASON_LABELS`
  entries; `tests/test_reason_line.lua` Test 4b now enforces label-or-allowlist for every
  new reason token automatically.
- **D4 (your stash is yours):** the stash itself is NOT touched. It predates the
  Consumption/Mood extractions and no longer applies to current `AutoPilot_Needs.lua`;
  on approval C1 is a fresh implementation against current main. Once C1 merges, dropping
  the superseded stash is proposed as its own one-word user decision (dated 2026-08-01;
  clears when you say drop it or keep it).

**Done-when (headless):** behaviour-difference tests through the existing mock
(`tests/lua_mock_pz.lua` `cfg.moodles`, which gains additive `HUNGRY`/`THIRST` keys on the
surface verified above): moodle 1 with stat below threshold eats/drinks with the new reason;
moodle 0 with stat below threshold does not; stat above threshold keeps today's behaviour
byte-for-byte. luacheck 0/0; all suites green; ships flagged "Needs in-game smoke test
before Workshop update".

## 3. C2: FF-4, honest XP/hr under fast-forward

The last CONFIRMED still-open finding from the 2026-07-24 fast-forward investigation
(FF-1, FF-2, FF-3 are all fixed and merged; FF-4's backlog status is OPEN, low priority).

**Re-verified at source this run:** `AutoPilot_XP._nowMs` (AutoPilot_XP.lua:43) uses real
time for the XP/hr window, so the F11 rate and ETA swing with game speed. Its consumers:
exactly one, `AutoPilot_UI.lua:218` (the F11 perk line). It feeds no decision; the claim
in the bug entry was re-checked by grep rather than inherited.

**Overridable default:** accumulate elapsed time scaled by `getGameTime():getMultiplier()`
(the same call the FF-1 fix already made load-bearing in `AutoPilot_Main`), keeping the
real-time base that protects the window from sleep's game-time jump. Display-only change.

**Done-when (headless):** a behaviour-difference test showing the same XP delta over the
same real window reports a multiplier-honest rate at speed 5 and an UNCHANGED rate at
speed 1 (the speed-1 path stays byte-identical). Ships with the same smoke-test flag.

## 4. C3: V6.1 option (b), decouple the rest-hold release (SESSION-GATED)

`docs/MILESTONE_V6_1.md` section 2 option (b): release the rest hold at RESUME + 0.05
instead of TARGET, so TARGET keeps meaning "a seated rest may continue to here" without
gating the return to training. It was NOT chosen for V6.1-1 and NOT discarded.

**Gate (dated 2026-08-01, observable):** the open backlog follow-up from PR #101, "exercise
tick share well above the measured 1.5% in the next real session", read from the schema-3
XP telemetry. If the next session shows a healthy share, C3 dies and is recorded closed; if
the share is still low, C3 is the documented next lever. **Default: WAIT for that session.
No implementation before the measurement.**

## 5. Q0: sequencing (overridable default)

Suggested order, dependency-driven only (no calendar):

1. Your decision on this proposal (one word suffices).
2. On approval: C1 then C2 as two normal dev increments, each its own PR.
3. C3 waits for the next in-game session, which is the SAME session the open v0.2.0
   release question recommends anyway (option (ii) there) and the one the MED
   verification-gap entry lists trigger states for. One session answers three things.

## 6. Not in scope, recorded so it is not re-derived

- The v0.2.0 cut decision: its own backlog item, its own user call.
- Stress / Uncomfortable moodle management: both have NO Lua-visible relief action in
  42.19 (PR #83's follow-up); needs a product answer, not a code slice.
  **⤷ HALF FALSIFIED, annotated 2026-08-12 rather than rewritten (dated out-of-scope
  record).** Stress DOES have relief, declared on items in `media/scripts` rather than in
  Lua, and it shipped as V6.3 C2-D4 (PR #153). Discomfort's half holds and is now
  documented in `docs/architecture.md` "Moodle Coverage" — no relief ACTION, but an
  indirect lever through what the character wears and carries. The product answer arrived
  as the V6.3 decision.
- Foraging revival, combat, barricading: standing non-goals; combat is engine-impossible
  (no B42 AI-attack API, flee-only rework stands).
- The TV/radio zombie-attraction question (PR #82's follow-up) stays open, but note for
  whoever picks it up: the jar-extraction technique used in section 2 makes Java-side
  questions like this one answerable headlessly. Recorded as a research candidate, not
  part of V6.2.

## 7. Decision table

| Row | Question | Default if you just say "approve" |
|-----|----------|-----------------------------------|
| C1  | Moodle-aligned hunger/thirst triggers? | YES, D1-D4 as written |
| C2  | FF-4 honest XP/hr fix? | YES, multiplier-scaled window |
| C3  | Rest-hold decouple? | WAIT for the session measurement |
| D4  | Drop the superseded stash after C1 merges? | ASK AGAIN after C1 (never silently) |
| Q0  | Sequencing | C1 -> C2 now; C3 after the session |
