# AutoPilot: V6.3 Expansion Proposal

> **STATUS: PROPOSED 2026-08-07, AWAITING USER DECISION.** Every open choice below carries an
> overridable default, so "approve with defaults" (or a per-candidate answer like "approve C1
> only", "flip C3") is a complete answer. Nothing here is implemented yet; net-new dev on this
> project is proposal-gated (backlog rule, 2026-07-26).

## 1. Why this proposal exists, and why now

V6.2 is spent as of 2026-08-04: C1 (moodle-aligned triggers) shipped as PR #108, C2 (FF-4
multiplier-honest XP/hr) shipped as PR #109, and C3 (rest-hold decoupling) stays SESSION-GATED
with default WAIT. The v0.2.0 release was cut 2026-08-05. Since then the dev feature queue has
been EMPTY: the two dev slots on 2026-08-07 both went to test-file code-health splits (PR #115,
PR #116) because nothing net-new is approved. The product rule "when a milestone completes,
define the next one" is genuinely open.

The honesty constraint from V6.2 still binds: the best input for TUNING work is the next
in-game session's telemetry, not more static analysis. This proposal respects it the same way
V6.2 did:

- Every candidate below is session-INDEPENDENT and grounded in evidence that already exists:
  a recorded open question from a prior audit, a live install read taken while drafting this
  (2026-08-07), or a shipped-code grep. None is invented from fresh ambition.
- Everything that needs the session stays gated and is restated in section 6 so the one
  session's shopping list lives in one place.
- C1 and C3 are the two promises the backlog made the user ("reversible on one word",
  "asked, never silently kept") converted into concrete, costed questions.

## 2. C1: Generic exercise discovery (the surviving form of withdrawn V6-C3)

**Origin, which is why this is not a fresh idea:** the 2026-07-25 product audit (PR #79)
withdrew V6-C3 (exercise variety) on a negative lookup — vanilla B42.19 defines exactly seven
exercises and the mod already uses all seven. The same audit recorded the surviving form
verbatim: *"iterate `FitnessExercises.exercisesType` generically and select by `xpMod` plus
equipment availability, instead of hardcoding seven names, which would also pick up exercises
added by other mods or a future Build"* — and left it to clear "when the user either confirms
the withdrawal or asks for the generic-iteration version." This candidate asks that question
concretely instead of leaving it parked.

**Evidence, re-verified live 2026-08-07 (install greps via live Bash, per the phantom-read
rule):**

- `shared/Definitions/FitnessExercises.lua` defines exactly 7 exercises, each carrying `xpMod`:
  squats 1, pushups 1, situp 1, burpees 0.8 ("few less xp as it gives xp for 3 body parts"),
  barbellcurl 1.2, dumbbellpress 1.8, bicepscurl 1.8.
- The mod's candidate pools are HARDCODED name lists: `AutoPilot_Exercise.lua:190` (strength)
  and `:207-208` (auto). The live table is only read for equipment fields (`:486-487`).
- The mock mirror (`tests/lua_mock_pz.lua:964-977`) carries type/item/prop but NOT `xpMod`,
  so the slice extends the mirror with the live values above (verified-surface discipline:
  the field is confirmed present in the install read).

**Honesty constraints discovered while drafting (both bound the shape):**

1. The vanilla table carries NO perk mapping (fields: type, name, tooltip, stiffness,
   metabolics, item, prop, xpMod). "Which stat does this exercise train" is mod-side
   knowledge (the V3.2 focus mapping) and cannot be derived generically for an unknown
   exercise.
2. Pure xpMod-descending ordering does NOT reproduce today's auto pool: burpees (0.8) would
   fall below the 1.0 bodyweight trio, but it deliberately leads them today because it trains
   BOTH stats (V5.2 decision). A naive "sort by xpMod" silently demotes the one both-stats
   exercise.

**Shape (one dev slice):** derive the AUTO pool by iterating `FitnessExercises.exercisesType`,
ordered by xpMod descending, with the existing equipment gate (`_hasExerciseItem`) and
XP-fatigue rotation untouched. Focused pools (strength/fitness) keep the mod-side perk map
exactly as-is. Extend the mock mirror with xpMod.

- **D1 (default: preserve today's order exactly):** an explicit both-stats promotion keeps
  burpees ahead of the 1.0 bodyweight trio in the auto pool, layered over xpMod ordering, so
  the vanilla-seven result is IDENTICAL to today's hardcoded list. The generic path only
  changes behavior when the table changes.
- **D2 (default: unknown exercises join AUTO only):** an exercise the perk map does not know
  (another mod's, or a future Build's) slots into the auto pool by its xpMod, and never into
  the strength/fitness focused pools — its trained perk is unknowable from Lua, and the
  focused pools promise a specific stat.
- **D3 (default: no new tunables):** no slider for this; the table is the configuration.

**Done-when (behavior difference, not existence):** a new suite injects a synthetic 8th
exercise into the mock mirror and asserts (a) it appears in the auto candidate list at the
position its xpMod earns, (b) with the vanilla-only mirror the generated auto pool is
element-for-element identical to today's hardcoded list (the D1 guarantee), (c) the focused
pools are byte-identical with and without the synthetic entry. Ships flagged "needs in-game
smoke test before Workshop update" like every dev PR.

**Cost:** one function's auto arm (`_exerciseCandidates`) + mock mirror xpMod values + one new
suite. **Risk: low.** Reversal: one revert, the hardcoded list is in git history.

## 3. C2: The two unmanageable moodles get their product answer (Stress, Discomfort)

**Origin:** `ROADMAP.md`'s harden-and-maintain bullet says it outright: *"Stress and
Discomfort management... needs a product answer more than a code slice."* PR #83's follow-up
established the ground and it keeps resurfacing on bug 5's coverage list with nowhere to go.

**Evidence, re-verified live 2026-08-07 rather than inherited:** `CharacterStat.DISCOMFORT`
has exactly ONE hit in the whole 42.19 install (`ISStatsAndBody.lua:73`, a debug slider) —
Java-driven, no queueable answer. `CharacterStat.STRESS` has seven hits, none of them a relief
action the mod could queue: two ADD it while crafting (`ISCraftAction.lua:25,32`), one ADDs it
during inventory transfer (`ISInventoryTransferAction.lua:143`), `forageSystem.lua:1804` reads
it, `ISReadABook.lua:165` records it at start and never uses it, `SFarmingSystem.lua:341`
removes it on a vegetable harvest (server-side farming, not a relief arm), and the last is the
debug slider. (The 2026-07-26 note also counted an `ISReloadWeaponAction` wiggle; the fresh
grep no longer shows it — the conclusion is unchanged either way: no Lua-visible relief
action exists.)

- **D4 (default: adopt as DOCUMENTED NON-GOALS):** README/architecture state plainly which
  moodles the mod manages and that Stress and Discomfort cannot be managed from Lua in 42.19,
  AND `docs/b42_20_checklist.md` gains a re-check line (re-grep both stats' relief surfaces on
  42.20) so the decision is revisited exactly when the ground can change, not by memory.
- **Alternative (declined as default):** leave it undocumented. Declined because the gap keeps
  resurfacing as apparent missing coverage and re-deriving the negative costs a grep of the
  whole install every time.

**Done-when:** the docs name the managed and unmanaged sets, the checklist carries the dated
re-check line, and the backlog's bug-5 residue points at this decision record. Docs-only; no
smoke-test flag.

## 4. C3: The Q2 poison-knowledge fork gets its explicit ask (default: keep)

**Origin:** V6.0-1 shipped on Q2's default (the mod reads `item:getPoisonPower()` directly)
with the recorded promise this would be asked, never silently kept. The follow-up item has
carried the exact reversal cost since 2026-07-26.

**Evidence, re-verified live 2026-08-07:** the mod-side predicate is the single
`pcall(function() poison = item:getPoisonPower() or 0 end)` at `AutoPilot_Inventory.lua:44`;
the immersion-accurate alternative `player:isKnownPoison(item)` is live vanilla practice at
`ISInventoryPane.lua:2310,2349` (the inventory tooltip's own call). No other mod caller reads
poison.

- **D5 (default: KEEP the direct read):** the mod is a safety net; letting a
  foraging-illiterate character eat a poison berry it "could not know about" optimizes
  roleplay over survival, and the mod's contract since V6.0 is "never knowingly worsen the
  character." One word ("respect knowledge") flips it.
- **Cost to flip, already recorded and re-confirmed:** thread the player into `isFoodEdible`
  (it currently takes only the item) and rewrite the six poison assertions in
  `tests/test_food_malus.lua` Test 7. A signature change and one test block, not a rewrite.

**Done-when (if flipped):** Test 7 proves the behavior difference — a poisonous item is
selectable when the player does NOT know it is poison and rejected when they do. If kept, the
predicate comment gains the decision date and the follow-up item closes.

## 5. Decision menu

| Answer | Meaning |
|---|---|
| "approve with defaults" | C1 (D1-D3 as written), C2 (D4 adopt + document), C3 (D5 keep) |
| "approve C1 only" / "approve C2 only" / ... | that candidate ships, others stay open |
| "confirm withdrawal" (C1) | V6-C3's withdrawal is final; the follow-up item closes; the auto pool stays hardcoded |
| "respect knowledge" (C3) | the poison predicate flips to `isKnownPoison`, costed above |
| silence | nothing ships; net-new dev stays proposal-gated |

Sequencing is dependency order only (no calendar): C1, C2, C3 are mutually independent; each
is one PR. C2 is docs-only and can land any time; C1 and C3 each carry the in-game smoke-test
flag.

## 6. Session-gated, deliberately NOT in this proposal

All already open in the backlog with their own close conditions; restated here so the ONE
in-game session's shopping list reads in one place:

- **V6.2-C3** rest-hold decoupling: WAIT on the exercise-share measurement.
- **V6.1-1 success metric:** attributed exercise share from the next real session (compare
  attributed-to-attributed per the PR #112 caveat; pre-retune baselines 32.4% attributed /
  2.0% decision-tick).
- **The MED verification gap:** the next smoke test should deliberately drive the untested
  trigger states (get wet, bored, unhappy) so PR #80/#82/#83's arms finally run in game.
- **SANITY healthy-baseline read** and the **sickness scale print** (both USER-ONLY in-game
  reads, recorded 2026-07-25/26).
- **V6.2-D4:** the `stash@{0}` drop-or-keep question (asked 2026-08-04, still open).

## 7. What this proposal deliberately does not contain

No new modules; no revival of the V3.1-deleted modules or barricading (standing non-goals);
no combat (B42 exposes no attack API — flee-only stands); no Workshop action (USER-ONLY,
permanently); no tuning changes that a session measurement should drive (that is V6.2-C3's
lane). The identity question the revival left open ("what makes this mod different") is not
re-litigated here: V6.3 hardens the leveler-plus-survival identity the V6.x line has been
shipping, and a bigger identity swing stays the user's call to initiate.
