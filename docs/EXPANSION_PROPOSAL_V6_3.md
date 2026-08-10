# AutoPilot: V6.3 Expansion Proposal

> **STATUS: APPROVED WITH DEFAULTS 2026-08-10 by the owner (direct answer: "approve defaults for
> D1-D8"). No longer awaiting a decision.** All eight decisions stand exactly as drafted below:
> **C1** D1 preserve today's vanilla ordering via the both-stats burpees promotion, D2 unknown and
> modded exercises join the auto pool only, D3 no new tunables; **C2** D4 SHIP the stress trigger
> on the existing read arm, D5 DEFER stress-magnitude ranking, D6 DOCUMENT Discomfort as the
> genuine limitation with its indirect lever named, D7 NO tobacco; **C3** D8 KEEP the direct
> `getPoisonPower` read. Nothing was overridden.
>
> **This unblocks net-new dev**, which had been proposal-gated since 2026-07-26. Sequencing is
> dependency order only, no calendar: C1, C2 and C3 are mutually independent, one PR each, except
> C2 which is naturally two (D4 the stress arm, a code slice; D6 the Discomfort documentation,
> docs-only). C1, C2-D4 and C3 each carry the in-game smoke-test flag; C2-D6 does not.
>
> **D5 stays deferred on a genuine unknown, not on the decision:** ranking stress relief by
> magnitude needs `print(item:getStressChange())` for a held `ComicBook` from any in-game session.
> `getStressChange` has ZERO call sites in the whole 42.19 Lua tree, so whether the property is
> reachable FROM Lua is unknown and this project's verified-surface discipline forbids mocking it
> on a guess. D4 needs no such getter and is not blocked by it.
>
> Original status line, preserved: *"PROPOSED 2026-08-07, AWAITING USER DECISION. Every open choice
> below carries an overridable default, so 'approve with defaults' (or a per-candidate answer like
> 'approve C1 only', 'flip C3') is a complete answer. Nothing here is implemented yet; net-new dev
> on this project is proposal-gated (backlog rule, 2026-07-26)."*

> **AUDITED 2026-08-07 before this PR was opened (resume audit of an interrupted increment,
> L-007 + L-026). ONE PREMISE CAME BACK FALSE and C2 was rewritten around it.** The draft's C2
> asserted that Stress has "no Lua-visible relief action" in 42.19 and proposed adopting Stress
> and Discomfort as documented NON-GOALS. That is wrong: 301 vanilla item entries carry a
> negative `StressChange`, and every one of them is delivered by an action the mod ALREADY
> queues. The draft reached the wrong answer by searching exactly one place (`CharacterStat.STRESS`
> inside `media/lua`), which finds only the code that reads or adds the stat — the relief is
> declared one directory over in `media/scripts` and applied engine-side. This is the same
> failure class as the deleted-module incident this project records (an absence claim about B42
> falsified by one grep), caught this time before it shipped rather than after. C1's and C3's
> premises were re-verified line by line and came back TRUE and unchanged. Section 3 carries the
> corrected candidate; **section 3.1 preserves the original C2 verbatim** so the correction is
> auditable. C2's decisions are now D4-D7 and C3's single decision was renumbered D5 -> D8.

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

## 3. C2 (REWRITTEN BY THE AUDIT): Stress is a reachable arm; Discomfort is the real limitation

**Origin:** `ROADMAP.md`'s harden-and-maintain bullet says it outright: *"Stress and
Discomfort management... needs a product answer more than a code slice."* PR #83's follow-up
established the ground and it keeps resurfacing on bug 5's coverage list with nowhere to go.
The draft's answer was "both are non-goals". The audit below says that is half right at best.

**Evidence, re-verified live 2026-08-07 in BOTH layers (`media/lua` AND `media/scripts`),
because searching only the first one is exactly what produced the false claim:**

- **Stress relief is abundant and it is declared on ITEMS, not in Lua.** 301 vanilla entries
  carry a negative `StressChange`: **259** in `scripts/generated/items/literature.txt`, **28**
  in `scripts/generated/items/food.txt`, **12** beverage fluid definitions at `-20.0` in
  `scripts/generated/fluids_Beverages.txt`, and **2** drainables in
  `scripts/generated/items/drainable.txt` (`CigarettePack` `-5`, `TobaccoChewing` `-10`).
  Worked example: `item ComicBook` (literature.txt:1720) is `BoredomChange = -30,
  StressChange = -20, UnhappyChange = -20` — literature typically relieves all three at once.
  `SmithingMag1`-`5` are `StressChange = -15`.
- **Every delivery action is one the mod ALREADY OWNS.** Literature is consumed by
  `ISReadABook`, which `AutoPilot_Mood.lua:157` already queues for boredom. Food, beverage
  fluids and the two tobacco drainables are consumed by `ISEatFoodAction`, which the mod
  queues at four sites (`AutoPilot_Consumption.lua:83` and `:120`, `AutoPilot_Mood.lua:220`,
  `AutoPilot_Sleep.lua:224`) and which handles smokables explicitly
  (`shared/TimedActions/ISEatFoodAction.lua:303-306`: `ItemTag.SMOKABLE` plus a car-lighter or
  open-flame requirement). So the gap is an unclaimed TRIGGER inside two existing arms, not a
  missing engine API.
- **The mod already reads the stat and deliberately never acts on it.**
  `AutoPilot_Threat.lua:132` carries `{ stat = CharacterStat.STRESS, threshold = 0.40,
  isNormalized = true }`, and `AutoPilot_Comfort.lua:7` states in a comment that the comfort
  arm "never references Stress".
- **What the draft's narrower search found is still accurate — it just is not where relief
  lives.** `CharacterStat.STRESS` has exactly 7 `media/lua` hits, re-counted today:
  `ISCraftAction.lua:25,32` and `ISInventoryTransferAction.lua:143` ADD it,
  `forageSystem.lua:1804` reads it, `ISReadABook.lua:165` records it at start and never uses
  it (only `:73-74` act, and only on UNHAPPINESS), `SFarmingSystem.lua:341` removes it on a
  server-side vegetable harvest, `ISStatsAndBody.lua:59` is the debug slider.

**Honesty constraint the audit itself discovered, and it bounds the shape:** `getStressChange`
has **ZERO** hits in the entire 42.19 Lua tree. That is unlike `getUnhappyChange` and
`getBoredomChange`, which are live vanilla practice and are exactly why the mod trusts them
(`AutoPilot_Inventory.lua:900-905` cites the vanilla call sites for the sign convention). So
**ranking candidates by stress magnitude is NOT a verified surface** and must not be assumed
under this project's verified-surface discipline, even though the underlying item property
plainly exists. Triggering on stress needs no such getter; ranking by it does.

- **D4 (default: SHIP the stress TRIGGER on the existing read arm, one dev slice).** When the
  Stress moodle is up and no higher-priority need is pending, the mood arm's existing
  book-reading path fires on stress the same way it fires on boredom. It needs no new module,
  no new action, and no unverified getter: literature is 259 of the 301 relieving entries, the
  mod already selects and queues books, and `ComicBook`-class items relieve boredom and
  unhappiness alongside stress so the existing ranking keys are an honest proxy.
  - **Alternative (declined as default): adopt Stress as a documented non-goal anyway.**
    Declined because it is now known to be false, and a documented non-goal is the most
    expensive kind of wrong prose — it stops anyone from re-deriving the right answer.
- **D5 (default: DEFER stress-magnitude ranking, do not guess at it).** Preferring the
  *most* stress-relieving candidate stays out of D4's slice until `item:getStressChange()` is
  confirmed to exist from Lua. Cheapest confirmation is one line in the user's next in-game
  session (print it for a held `ComicBook`); it is added to the section 6 shopping list rather
  than becoming a blocker. The mod's own `pcall`-with-fallback idiom would make a wrong guess
  harmless at runtime, but it would also silently mock an unverified API in the test suite,
  which is the practice this project forbids.
- **D6 (default: DOCUMENT Discomfort as the genuine limitation, with its lever named).**
  `CharacterStat.DISCOMFORT` still has exactly ONE `media/lua` hit (`ISStatsAndBody.lua:73`,
  the debug slider), so that half of the draft survives the re-check: there is no relief
  ACTION. What the wider search adds is that it is not inert either — discomfort is driven by
  `DiscomfortModifier` on clothing (`scripts/generated/items/clothing.txt`, 0.05-0.12), by
  `SandboxVars.DiscomfortFactor`, and by `VehicleDiscomfortWhenOverEncumbered = 0.25`
  (`shared/defines.lua:58`), and it FEEDS stress through `StressFromDiscomfort = 0.00000013`
  (`shared/defines.lua:30`). So the docs say "no relief action, but an indirect lever through
  what the character wears and carries", never "cannot be managed".
  `docs/b42_20_checklist.md` gains a re-check line that names BOTH layers, so the 42.20 pass
  cannot repeat the one-directory mistake.
- **D7 (default: NO tobacco.)** `CigarettePack` (`-5`) and `TobaccoChewing` (`-10`) are the
  strongest per-item stress relievers the mod could reach, and smoking additionally needs an
  open flame or a car lighter. The mod is a survival safety net, not a habit engine, and
  consuming a scarce lighter charge to shave a moodle is a trade the owner should make
  knowingly. One word ("allow tobacco") flips it.

**Done-when:** D4 ships a behavior-difference suite — the same character with the Stress moodle
above threshold queues a read where today it queues nothing, and with the moodle below
threshold picks element-for-element what it picks today, so the change is provably confined to
the stressed case. D6 is docs-only. D4 carries "needs in-game smoke test before Workshop
update"; D6 does not. D5 closes when the section 6 print comes back.

### 3.1 The original C2, preserved verbatim (superseded by the audit above)

> **C2: The two unmanageable moodles get their product answer (Stress, Discomfort)**
>
> **Evidence, re-verified live 2026-08-07 rather than inherited:** `CharacterStat.DISCOMFORT`
> has exactly ONE hit in the whole 42.19 install (`ISStatsAndBody.lua:73`, a debug slider) —
> Java-driven, no queueable answer. `CharacterStat.STRESS` has seven hits, none of them a relief
> action the mod could queue: two ADD it while crafting (`ISCraftAction.lua:25,32`), one ADDs it
> during inventory transfer (`ISInventoryTransferAction.lua:143`), `forageSystem.lua:1804` reads
> it, `ISReadABook.lua:165` records it at start and never uses it, `SFarmingSystem.lua:341`
> removes it on a vegetable harvest (server-side farming, not a relief arm), and the last is the
> debug slider. (The 2026-07-26 note also counted an `ISReloadWeaponAction` wiggle; the fresh
> grep no longer shows it — the conclusion is unchanged either way: no Lua-visible relief
> action exists.)
>
> - **D4 (default: adopt as DOCUMENTED NON-GOALS):** README/architecture state plainly which
>   moodles the mod manages and that Stress and Discomfort cannot be managed from Lua in 42.19,
>   AND `docs/b42_20_checklist.md` gains a re-check line (re-grep both stats' relief surfaces on
>   42.20) so the decision is revisited exactly when the ground can change, not by memory.
> - **Alternative (declined as default):** leave it undocumented. Declined because the gap keeps
>   resurfacing as apparent missing coverage and re-deriving the negative costs a grep of the
>   whole install every time.
>
> **Done-when:** the docs name the managed and unmanaged sets, the checklist carries the dated
> re-check line, and the backlog's bug-5 residue points at this decision record. Docs-only; no
> smoke-test flag.

## 4. C3: The Q2 poison-knowledge fork gets its explicit ask (default: keep)

**Origin:** V6.0-1 shipped on Q2's default (the mod reads `item:getPoisonPower()` directly)
with the recorded promise this would be asked, never silently kept. The follow-up item has
carried the exact reversal cost since 2026-07-26.

**Evidence, re-verified live 2026-08-07 and re-confirmed line by line during the audit:** the
mod-side predicate is the single `pcall(function() poison = item:getPoisonPower() or 0 end)` at
`AutoPilot_Inventory.lua:44`; the immersion-accurate alternative `player:isKnownPoison(item)`
is live vanilla practice at exactly the two cited lines `ISInventoryPane.lua:2310,2349` (the
inventory tooltip's own call), plus `:983` and four `client/Foraging/` call sites, 13 hits
total. No other mod caller reads poison. Worth recording for the decision: vanilla ALSO reads
`getPoisonPower()` directly in four places (`ISInventoryPane.lua:2094,2097`,
`ISTradingUI.lua:196,199`), so the direct read is not an off-label API — the fork is about
whose knowledge the mod should model, not about which call is legitimate.

- **D8 (was D5 before the audit renumber; default: KEEP the direct read):** the mod is a safety net; letting a
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
| "approve with defaults" | C1 (D1-D3 as written), C2 (D4 ship the stress read arm, D5 defer magnitude ranking, D6 document Discomfort, D7 no tobacco), C3 (D8 keep the direct poison read) |
| "approve C1 only" / "approve C2 only" / ... | that candidate ships, others stay open |
| "confirm withdrawal" (C1) | V6-C3's withdrawal is final; the follow-up item closes; the auto pool stays hardcoded |
| "stress is a non-goal after all" (C2) | D4 is dropped and Stress joins Discomfort in the documented-limitation set — but see the audit banner: the premise that made that the draft's default is false |
| "allow tobacco" (C2) | D7 flips; `CigarettePack` and `TobaccoChewing` become eligible stress relievers |
| "respect knowledge" (C3) | the poison predicate flips to `isKnownPoison`, costed above |
| silence | nothing ships; net-new dev stays proposal-gated |

Sequencing is dependency order only (no calendar): C1, C2, C3 are mutually independent; each
is one PR, except C2 which is naturally two (D4 the stress arm, a code slice; D6 the Discomfort
documentation, docs-only). C1 and C2-D4 and C3 carry the in-game smoke-test flag; C2-D6 does not.

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
- **NEW, added by the 2026-08-07 audit (C2-D5):** one print for a held `ComicBook` —
  `print(item:getStressChange())`. `getStressChange` has zero call sites in the whole 42.19 Lua
  tree, so whether it is callable from Lua is genuinely unknown, and the answer decides whether
  stress-magnitude ranking is ever available. Cheapest possible check; blocks nothing.

## 7. What this proposal deliberately does not contain

No new modules; no revival of the V3.1-deleted modules or barricading (standing non-goals);
no combat (B42 exposes no attack API — flee-only stands); no Workshop action (superseded wording,
quoted where it stood: *"no Workshop action (USER-ONLY, permanently)"* — the permission was widened
2026-08-08; a proposal ships no release regardless, so this non-goal stands on scope); no tuning
changes that a session measurement should drive (that is V6.2-C3's
lane). The identity question the revival left open ("what makes this mod different") is not
re-litigated here: V6.3 hardens the leveler-plus-survival identity the V6.x line has been
shipping, and a bigger identity swing stays the user's call to initiate.
