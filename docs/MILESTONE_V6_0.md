# AutoPilot V6.0: scope, defaults, and done-when

> ## STATUS: DECIDED, not proposed (user decision 2026-07-26)
>
> `docs/EXPANSION_PROPOSAL_V6.md` asked for a decision and got one. This document is the
> other half: what the decision actually means in code, sliced into increments, with every
> remaining choice carrying an overridable default and a done-when a test or CI job can check.
>
> **What the user decided, verbatim in effect:**
> 1. **C2 APPROVED** (decision-reason visibility on the F11 panel).
> 2. **C1 REPLACED, not deferred.** In its place: *prioritise food gathering and eating by the
>    ABSENCE OF MALUS EFFECTS*. Rank food by carrying no negative effect (rotten, poisonous,
>    unhappiness-inducing) in BOTH the eat path and what the looting path prefers to carry.
> 3. **Scope fence the user set and this document does not widen:** "gathering" means the
>    EXISTING looting path (`AutoPilot_Inventory.lootNearbyFood`). The Foraging module stays
>    deleted and reviving it remains a standing non-goal.
>
> Nothing here is scheduled until the defaults table at the bottom is accepted or overridden.
> "Use your defaults" is a complete answer to all of it.

---

## 1. Everything below was verified at source before it was written

Product increments in this repo have exactly one recurring defect: prose asserting a state a
single command falsifies. Every claim in this document was re-read at source on 2026-07-26,
against the live tree at `e34a8e9` and the installed 42.19 game, and the evidence is cited
inline so a reviewer can falsify any line in one command.

| Claim | Where it was verified | Result |
|---|---|---|
| The eat path filters food through one helper | `AutoPilot_Inventory.lua:19-34` (`isFoodSafe`), used by `getBestFood` (:42), `getBestFoodForHunger` (:63), `selectFoodByWeight` (:99), `preferTastyFood` (:832) | TRUE, one helper, four callers |
| `isFoodSafe` already rejects unhappiness-inducing food | `AutoPilot_Inventory.lua:33`, `return unhappy <= 0 and boring <= 0` | TRUE, and see section 2: this is a HARD reject on the hunger path, which is a defect |
| `isFoodSafe` does NOT consider poison or tainted water | same block, lines 19-34: rotten, frozen, uncooked-cookable, unhappy, boredom, and nothing else | TRUE |
| The looting path uses a WEAKER predicate than the eat path | `AutoPilot_Inventory.lua:400`, `item:isFood() and not item:isRotten()` plus calorie-positive and non-drink | TRUE: the mod hauls home food it will then refuse to eat |
| The loot predicate is deliberately coupled to the supply counter | `AutoPilot_Inventory.lua:401-403` comment ("Match getSupplyCounts... mismatched predicates caused an endless loot loop") and `getSupplyCounts` (:446-465) | TRUE, and it is a hard constraint on slice 2 (section 5) |
| `item:getPoisonPower()` is a real, Lua-visible engine API | install: `client/ISUI/ISInventoryPane.lua:2094,2097`; `client/Foraging/ISForageIcon.lua:24` | TRUE |
| `item:isTainted()` is a real, Lua-visible engine API for Food | install: `client/ISUI/ISInventoryPane.lua:2310,2349` (`instanceof(item, "Food") and item:isTainted()`) | TRUE |
| `player:isKnownPoison(item)` exists (the character-knowledge gate) | install: `client/ISUI/ISInventoryPane.lua:2310,2349` | TRUE, and it is the subject of open question Q2 |
| Nothing in the mod reads back a decision reason | repo-wide grep for `getLastReason|getDecision|lastReason|getLastDecision` across `*.lua`, `*.py`, `*.md`: zero hits outside the proposal document itself | TRUE, C2's premise still holds |
| `AutoPilot_Telemetry` exports no reason getter | `AutoPilot_Telemetry.lua`: `setDecision` (:217), `logTick` (:233), `onDeath` (:288), `onShutdown` (:307), `getPendingAction` (:322), `getRunTick` (:329) | TRUE, the read side stops at the pending ACTION |
| The panel and the HUD already share one activity source | `AutoPilot_UI.lua:268-269` and `AutoPilot_Main.lua:95-99` both render `AutoPilot.getActionIntention` (:320) | TRUE, so C2 extends a seam instead of adding a second one |
| `HUNGER_THRESHOLD` is 0.15, not the 0.20 older notes cite | `AutoPilot_Constants.lua:145` | The 0.20 figure is STALE; use 0.15 |
| `HAPPINESS_FOOD_PRIORITY` is live and consumed | `AutoPilot_Constants.lua:338` (value 2), read at `AutoPilot_Needs.lua:337` | TRUE since PR #80 |

## 2. The finding that changes what F1 should be

The user asked for food to be RANKED by the absence of malus effects. A naive reading is
"filter harder". A source read says the opposite is needed on the hunger path, because the
filter is already too hard and it can starve a character who is carrying food.

`isFoodSafe` returns false for any food with `getUnhappyChange() > 0`, and every hunger-path
selector runs through it. So a food the game considers edible but joyless is not deprioritised,
it is INVISIBLE, at any hunger level, with no override.

Measured against the installed 42.19 item scripts
(`media/scripts/generated/items/food.txt`, 722 item blocks):

- **141** food items define a positive `UnhappyChange`.
- **46** of those are not cookable, so `isFoodSafe`'s unhappiness clause is the SOLE reason the
  mod can never eat them. Examples straight out of that scan: `Pasta` (40), `Macaroni` (40),
  `Ramen` (20), `Butter` (20), `Coffee2` (20), `cheese_powdered` (14), `Teabag2` (10),
  `MayonnaiseFull` (5), plus the pet foods and `Chum`.

A character whose pack holds only dry pasta and ramen therefore starves while "having food",
and the proactive-scavenge path keeps hauling more of it home because the loot predicate
(`AutoPilot_Inventory.lua:400`) is weaker than the eat predicate. Filed as a MED bug on the
AutoPilot backlog (`## Bugs`, 2026-07-26, found by this product increment).

**Consequence for the milestone:** F1's mood-malus half is a RANKING change (prefer malus-free,
fall back rather than refuse), not a stricter filter. Poison and taint are the only NEW hard
rejects, because those two are safety properties rather than preferences. This is written into
slice 1's done-when so the fix cannot be implemented as "add more clauses to `isFoodSafe`".

## 3. What V6.0 contains

Three slices, each one small PR, ordered by dependency only (agent execution runs far faster
than any calendar cadence, so no slice is sized in days or weeks).

| Slice | Title | Depends on | Touches |
|---|---|---|---|
| **V6.0-1** | Malus-aware EAT ranking (the user's F1, eat half) | nothing | `AutoPilot_Inventory.lua`, `AutoPilot_Constants.lua`, new `tests/test_food_malus.lua` |
| **V6.0-2** | Malus-aware LOOT preference (the user's F1, gathering half) | V6.0-1 (shares the scoring helper) | `AutoPilot_Inventory.lua`, `tests/test_food_malus.lua` |
| **V6.0-3** | Decision-reason visibility (C2, approved) | nothing (independent of 1 and 2) | `AutoPilot_Telemetry.lua`, `AutoPilot_Main.lua`, `AutoPilot_UI.lua`, new `tests/test_reason_line.lua` |

### V6.0-1: malus-aware eat ranking

Introduce one scoring helper next to `isFoodSafe`, for example
`foodMalusScore(item)`, returning a comparable penalty built from what the engine exposes:
rotten and poisonous and tainted are disqualifying; `getUnhappyChange()` and
`getBoredomChange()` above zero are penalties, not disqualifications.

Split the current single predicate into two honest ones:

- `isFoodEdible(item)`: the SAFETY gate. Not rotten, not frozen, not uncooked-cookable,
  `getPoisonPower() <= 0`, not `isTainted()`. Never overridden by hunger.
- `foodMalusScore(item)`: the PREFERENCE. Lower is better; malus-free food sorts first.

Every existing selector keeps its own primary key (calories, hunger fit, weight fit,
unhappiness for `preferTastyFood`) and uses the malus score as the tie-break and as the reason
to skip a candidate only while a better one exists. `preferTastyFood` keeps its current
behaviour of refusing food that would worsen the very moodle it was invoked for: that is a
correctness rule for the mood arm, not the hunger arm, and `tests/test_mood_food_choice.lua`
Test 2 pins it.

**Done when (all checkable headlessly):**
1. `luacheck 42/media/lua/client/*.lua --config .luacheckrc` is 0 errors, 0 warnings.
2. Every existing Lua suite passes UNCHANGED. In particular `tests/test_mood_food_choice.lua`
   and `tests/test_container_search.lua` must not need edits: if they do, the mood arm's
   contract was changed and that is out of scope.
3. New `tests/test_food_malus.lua` proves the behaviour DIFFERENCE in both directions:
   a. a character carrying only `unhappy > 0` food now eats it (today: `getBestFood` returns nil);
   b. given a malus-free and a malus-carrying food of equal calories, the malus-free one wins;
   c. a poisonous item (`getPoisonPower() > 0`) is never returned by any selector, at any hunger;
   d. a tainted item is never returned by any selector.
4. Each of those four assertions is proven non-vacuous by removing the guard it tests and
   observing the failure, with the flip counts recorded in the PR body.

### V6.0-2: malus-aware loot preference

`lootNearbyFood` (`AutoPilot_Inventory.lua:397-420`) currently takes the highest-calorie
non-rotten food nearby. It should PREFER the malus-free candidate, using the same
`foodMalusScore` helper, with calories as the tie-break.

**The invariant that constrains this slice.** The loot predicate must stay a SUPERSET of
`getSupplyCounts`'s predicate (`AutoPilot_Inventory.lua:446-465`). The in-code comment at
:401-403 records what happens otherwise: an endless loot loop, because the mod hauls items that
its own supply counter refuses to count. So the default is a RANKING change with the predicate
untouched: no item that is lootable today becomes unlootable, only the ORDER changes. That also
keeps this slice clear of the two open carry-capacity follow-ups from PR #85.

**Done when:**
1. luacheck clean, every existing suite passes unchanged, in particular
   `tests/test_carry_capacity.lua` Tests 10-11 which assert on `lootNearbyFood`.
2. `tests/test_food_malus.lua` gains a case proving the ranking difference: with a malus-free
   200-calorie item and a malus-carrying 400-calorie item in the same nearby container, the
   malus-free one is transferred.
3. A case proving the invariant: an item that `getSupplyCounts` counts is still lootable even
   when it carries a malus and nothing better is nearby (guards the loot loop).

### V6.0-3: decision-reason visibility (C2)

Add the read side the proposal specified: a getter on `AutoPilot_Telemetry` mirroring
`getPendingAction`'s shape, plus ONE pure formatter that both the F11 panel and the on-screen
HUD call, so the two surfaces cannot drift the way they did before V5.8 unified them.

**Done when:**
1. A pure formatter (for example `AutoPilot.reasonLine(action, reason)`) is unit-tested
   directly against the reason vocabulary that `docs/triage.md` already documents, including
   the `fail_reason` cases (`pain_block`, `panic`) that answer "why is it doing nothing".
2. A test asserts the panel and the HUD render the SAME formatted value from the same source,
   in the shape `tests/test_main_logic.lua` already uses for `getActionIntention`.
3. An unknown or empty reason renders as the plain action string, with a test, so a new reason
   token can never blank the panel.
4. luacheck clean; no existing suite edited.

## 4. Requirements every slice inherits

1. **Scale-agnostic thresholds.** Any threshold on an engine stat normalises defensively
   (`if v > 1 then v = v / 100 end`) and is expressed as a 0-1 fraction. C1 died on exactly this
   assumption and PR #84 fixed three live `NEGATIVE_STAT_CHECKS` entries with the same defect.
   Note that the food getters in this milestone (`getUnhappyChange`, `getBoredomChange`,
   `getPoisonPower`) are item deltas on an unbounded item scale, NOT 0-1 character stats, so the
   rule binds any new CHARACTER-stat gate a slice might add, not the item comparisons themselves.
2. **Verified-surface discipline.** Only engine APIs observed in the install or already used by
   the mod may be called or mocked. `getPoisonPower` and `isTainted` clear that bar (section 1);
   anything else added later must cite its own install hit.
3. **Guarded calls.** New engine getters are wrapped in `pcall` exactly like
   `getUnhappyChange` at `AutoPilot_Inventory.lua:29-32`. This is not defensive style for its own
   sake: the Lua test suites build item stubs with a local `food()` factory (for example
   `tests/test_mood_food_choice.lua:70-86`) that defines only the getters in use today, so an
   unguarded `item:getPoisonPower()` would break four suites that this milestone must leave
   untouched.
4. **Mock additions.** `tests/lua_mock_pz.lua` and any suite-local `food()` factory that the new
   tests use gain `getPoisonPower` and `isTainted` defaults. Existing factories stay as they are.
5. **Every code slice ships flagged "Needs in-game smoke test before Workshop update."** No
   increment here is verifiable in-game headlessly. Workshop uploads, `sync_workshop.sh`, version
   bumps, and tags stay USER-ONLY.
6. **No new option slider unless a default below says so.** Constants stay in
   `AutoPilot_Constants.lua` with the documented-comment style the file already uses.

## 5. Open questions, each with an overridable default

Accepting all five is one word. Every default is a real decision that was made rather than
deferred, so silence ships the right-hand column.

| # | Question | Recommended default | If you disagree |
|---|---|---|---|
| Q1 | What counts as a MALUS? | Disqualifying: rotten, `getPoisonPower() > 0`, `isTainted()`. Penalising (ranked, not refused): `getUnhappyChange() > 0`, `getBoredomChange() > 0`. Frozen and uncooked-cookable stay disqualifying as they are today. | Say which line moves. Moving unhappiness back to disqualifying re-creates the starvation gap in section 2. |
| Q2 | Should the mod see poison the character does not know about? | YES, read `item:getPoisonPower()` directly. The mod's job is to not kill you, and a foraging-illiterate character who eats a poisonous berry dies just as dead. | Say "respect knowledge" and the guard uses `player:isKnownPoison(item)` instead, which is the immersion-accurate reading and the same call vanilla's own inventory tooltip makes. |
| Q3 | When may the mod eat malus food anyway? | Whenever nothing better is carried. Ranking, not gating: the hunger path always eats the best available EDIBLE food rather than refusing to eat. | Say "add a floor" and it becomes a hunger fraction (suggested 0.30) below which malus food is skipped even when it is all there is. |
| Q4 | Does looting ever REFUSE a malus food? | NO. Ranking only, predicate unchanged, for the loot-loop invariant in slice 2. | Say "refuse poison at least", which is safe for the invariant only if `getSupplyCounts` stops counting poisonous food in the SAME commit. |
| Q5 | Does C2 render on the F11 panel only, or the HUD too? | BOTH, from one formatter. The HUD is where an AFK player actually looks, and one source is the V5.8 rule that stopped the panel and HUD disagreeing. | Say "panel only" and the HUD keeps rendering the bare action. |

## 6. Explicitly NOT in V6.0

- No revival of the Foraging module, or of Skills, Vehicles, Combat, Explore, or Actions. The
  user's scope fence is repeated here because "food gathering" reads like foraging and is not.
- No cooking, no recipes, no food preparation: the mod picks among what exists, it does not
  create better food.
- No new sickness or food-poisoning gate. C1 was replaced, not renamed; the sickness scale
  question in the backlog stays open and unblocked by anything here.
- No change to `AutoPilot_Threat`, no change to the carry-capacity gate from PR #85, and no
  change to the mood arm's "never worsen the moodle you are treating" rule.
- No version bump, tag, or Workshop update: all USER-ONLY.

## 7. What only the user can settle

- Whether the malus ranking FEELS right in game (the smoke test all three slices ship flagged
  for). Headless tests can prove which item is chosen, never whether the character is happier.
- Q2's immersion question, if the default reading is wrong for how the user plays.
- Whether the section 2 starvation gap has actually been observed in a real run. It is proven at
  source and in the item scripts, and the fix is in slice 1 either way, but a real run log line
  would upgrade it from source-verified to observed.
