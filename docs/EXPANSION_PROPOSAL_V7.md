# AutoPilot: V7.0 Expansion Proposal — non-exercise leveler skills

> **STATUS: APPROVED WITH DEFAULTS 2026-08-14 by the owner (direct answer: "Approve with
> defaults"). No longer awaiting a decision.** All six decisions stand exactly as drafted in
> section 5, nothing overridden: **D1** ADOPT the corrected in-scope bar (the grant must be inside
> the action's own lifecycle, cited by file, line and hook), which is the reading already shipped
> with this document rather than a new edit; **D2** V7.0 is SKILLS-ONLY, with Combat, Explore and
> loot-zone Foraging staying reopened territory but out of scope; **D3** SHIP First Aid accounting
> first — the leveler metrics and the F11 panel count Doctor XP beside Strength and Fitness, no new
> queued action and no new engine surface; **D4** DEFER Tailoring on its supply constraint, not on
> the engine; **D5** DEFER the 714-entry crafting surface to its own proposal; **D6** CLOSE
> Mechanics, Cooking and PlantScavenging, each on its measured reason from section 4.
>
> **What this unblocks, and what it does not.** D3 is the only approved code slice: one PR,
> depending on nothing, held to the done-when already written in section 6 (a behaviour-difference
> test proving the panel value moves for a bandage the mod queued and does NOT move for one it did
> not, the F11 panel and run log reading one source, and the standing in-game smoke-test flag).
> D1 and D6 are documentation and are recorded in `ROADMAP.md` in the same increment as this
> header. D4 and D5 are each their own proposal if they are ever reopened; D4's clearing condition
> stays exactly as drafted — one in-game reading of how many patchable holes and how much thread a
> normal session carries — so it is deferred on a measurement, not on a preference.
>
> **The safety property in section 5 is not affected by this approval and is restated here so it
> travels with the decision:** the mod must never injure the character to create work for a medical
> arm. D3 is accounting only for exactly that reason — it counts XP the mod already earns and
> changes no behaviour.
>
> Original status line, preserved: *"PROPOSED 2026-08-13, AWAITING USER DECISION. Every open choice
> below carries an overridable default, so 'approve with defaults' (or a per-decision answer like
> 'approve D3 only', 'flip D4') is a complete answer. Nothing here is implemented. This document is
> the product gate that `ROADMAP.md`'s Blocked table has named since 2026-08-07 and that nobody had
> written."*
>
> **ONE PREMISE OF THE GATE CAME BACK FALSE, and correcting it is shipped WITH this proposal
> rather than proposed by it.** The bar `ROADMAP.md` set for every candidate in this territory —
> *"a **verified** queueable action whose own `perform()` grants the XP"* — is satisfied by
> **nothing in Build 42.19**, including by the worked example the same document cites. Section 2
> is the measurement. The bar is corrected in this PR because it is a false statement about the
> engine, not a choice; D1 exists only so the owner can reject the correction if they meant the
> stricter reading.
>
> **A SECOND FINDING REFRAMES THE QUESTION.** The territory was always audited in `media/lua`,
> and `media/lua` is the wrong half of the install for this subject: `media/scripts` declares
> **714 `xpAward` entries across 184 files and 14 skills**, applied engine-side, with **zero Lua
> consumers**. Section 3. This is the same failure class the V6.3 audit caught on Stress
> (`StressChange` lives in the item layer, so a `media/lua`-only search concluded a real capability
> was absent) arriving again on a different subject, which is why it is stated as a finding here
> rather than folded quietly into a candidate.

---

## 1. Why this proposal exists, and why now

`ROADMAP.md`'s Blocked table carries one row that is gated on a document rather than on the engine:

> | Non-exercise leveler skills (Tailoring, Mechanics, Cooking, Fishing, Foraging) | **Gated on the
> V7.0 proposal, NOT on the engine.** …which skills are worth automating, and at what risk, is that
> proposal's job. |

That proposal was never written. The V6.3 decision closed out on 2026-08-12 (C1 as PR #151, C2-D4
as PR #153, C2-D6 as PR #155), which emptied the development queue, and the product rule for an
empty queue is to define the next milestone rather than to invent filler. This is that document.

It is deliberately **not** a design for a Skills module. It answers the two questions the Blocked
row actually poses — which candidates have a real path, and what each one costs in player agency —
and it hands the owner a decision menu. A module design, if any candidate is approved, is the next
increment and not this one.

**Everything below was re-derived live on 2026-08-13** against the 42.19 install at
`D:/SteamLibrary/steamapps/common/ProjectZomboid/media/`, from the Bash tool, never from a file
read (this project's phantom-read rule) and never inherited from an earlier document. Where a
figure contradicts one this repo already carries, the superseded figure is quoted where it stood.

---

## 2. The gate is unsatisfiable as written: `perform()` grants XP nowhere

**Measurement.** Every uncommented `addXp(self.character, Perks.*)` call site in the whole
`media/lua` tree, each attributed to the enclosing function:

```
for f in $(grep -rlE "addXp\(self\.character, *Perks\." --include=*.lua .); do
  awk '/^function /{fn=$0} /addXp\(self\.character, *Perks\./{ if ($0 !~ /^[ \t]*--/) print fn }' "$f"
done | sed 's/function [A-Za-z_]*:\([a-zA-Z]*\).*/\1/' | sort | uniq -c | sort -rn
```

| hook | sites |
|---|---|
| `complete()` | 30 |
| `animEvent()` | 5 |
| `update()` | 2 |
| `start()` | 2 |
| `serverStart()` | 2 |
| **`perform()`** | **0** |

41 sites, none of them in `perform()`.

**The worked example the roadmap cites falsifies the roadmap's own bar.** `ROADMAP.md` states, of
`ISRepairClothing`, that it *"is an `ISBaseTimedAction` subclass whose `perform()` calls
`addXp(self.character, Perks.Tailoring, 2)`"*. Read live, `shared/TimedActions/ISRepairClothing.lua`
opens `perform()` at line 52 and it does four things — stop the sewing sound, `resetModel()`, clear
the garment-UI body-part action, and call `ISBaseTimedAction.perform(self)` to advance the queue.
It grants nothing. The `addXp` is at **line 74**, inside `complete()` (which opens at line 63),
after `clothing:addPatch(...)`, the fabric removal and `thread:UseAndSync()`.

**Why this matters more than a wrong word.** `perform()` and `complete()` are not synonyms in this
engine: `complete()` is the hook that runs on the SUCCESS path and returns a boolean, and
`perform()` runs on the way out regardless. A bar written on `perform()` therefore does not merely
misname the hook — read literally it rejects 100% of candidates, so the territory it gates can
never open, and nothing about that failure is visible to a reader who does not open the file.

**The corrected bar (D1's default).** A skill is in scope only with a **verified** queueable action
that grants the XP **inside its own action lifecycle**, cited to the live game source by file,
line **and hook name**. The substance of the old bar is unchanged and still binding: the mod queues
a real action and the GAME grants the XP; the standing non-goal on direct `addXp()` grants by the
mod is untouched by this document.

---

## 3. The finding that reframes the question: 714 XP awards in the layer nobody searched

`media/scripts` — the item and recipe layer, applied engine-side — declares XP awards directly on
craft recipes with an `xpAward = <Skill>:<amount>` key:

```
grep -rhoiE "xpAward[ \t]*=[ \t]*[A-Za-z]+:[0-9]+" scripts/ | sed -E 's/.*=[ \t]*//; s/:[0-9]+$//' \
  | sort | uniq -c | sort -rn
```

| skill | entries | | skill | entries |
|---|---|---|---|---|
| Tailoring | 159 | | Masonry | 24 |
| Woodwork | 142 | | Electricity | 22 |
| Blacksmith | 123 | | Pottery | 21 |
| MetalWelding | 67 | | FlintKnapping | 11 |
| Carving | 52 | | Glassmaking | 8 |
| Cooking | 42 | | Butchering | 2 |
| Maintenance | 40 | | Fishing | 1 |

**714 entries, 184 files, 14 skills.** And the decisive half: `grep -rn "xpAward" --include=*.lua`
over the entire `media/lua` tree returns **zero hits**. Nothing in Lua reads that key, so the award
is applied engine-side — which is precisely why every previous audit of this territory, all of them
conducted in `media/lua`, could not see it and concluded from a partial search.

The queueable carrier exists and is ordinary: `shared/TimedActions/ISCraftAction.lua` is an
`ISBaseTimedAction` subclass (line 3) with `ISCraftAction:new(character, item, recipe, container,
containersIn)` at line 158, `isValid()` at 5, `perform()` at 73, `complete()` at 92, `getDuration()`
at 138.

**This is recorded as a finding, not proposed as work.** Driving `ISCraftAction` means the mod
choosing recipes and consuming the player's materials, which is a categorically larger agency
question than anything the mod does today (see D5).

---

## 4. Candidate paths, re-derived per skill

Each row states the verified grant site with its hook, or states plainly that there is none.

**Tailoring — real action path, but the input is consumed.** `ISRepairClothing.lua:74` (`complete()`,
+2) and `ISRemovePatch.lua:52` (`complete()`, +2). Plus 159 script-layer entries. The cost is in
`isValid()`, read live: the character must simultaneously hold the clothing, a fabric, a needle AND
a thread, and `clothing:getPatchType(part)` must be `nil`. `complete()` then removes the fabric and
calls `thread:UseAndSync()`. So each grant consumes stock the player did not choose to spend, and
the supply is finite.

**Fishing — real action path, and it grants at START.** `ISCheckFishingNetAction.lua:36`
(`complete()`, +1); `ISPickupFishAction.lua` grants at **`serverStart()`** (lines 62, 64) and
**`start()`** (82, 84), scaled `2 * fishSize`. A grant on the start hook has a different risk
profile from one on the completion hook — an interrupted action has already paid — and any Fishing
work must state which hook it is relying on.

**Mechanics — real action path, closed by an existing decision rather than by the engine.** Ten
sites, every one under `shared/Vehicles/TimedActions/` (`ISInstallVehiclePart` 107/112,
`ISRepairEngine` 61/74/80, `ISRepairLightbar` 56, `ISTakeEngineParts` 50/58/62,
`ISUninstallVehiclePart` 89), all in `complete()`. **Vehicles is a standing non-goal.** So the
honest statement is that Mechanics is blocked by a scope decision the owner already made, and
listing it as an engine-gated candidate misrepresents what would have to change for it to open.

**Cooking — NO action-lifecycle path exists, and the roadmap's cited carrier does not carry it.**
`ROADMAP.md` names `ISAddItemInRecipe` as the Cooking action. Read live, that file's only
`Perks.Cooking` reference is `shared/TimedActions/ISAddItemInRecipe.lua:228` —
`return 100 - (self.character:getPerkLevel(Perks.Cooking) * 2.5)` — a **duration scale**, not a
grant. The only `addXp(..., Perks.Cooking, ...)` in the tree is `server/XpSystem/XpUpdate.lua:111`,
inside `xpUpdate.onMakeItem`, an **event handler** fired when a Food item is crafted and keyed on
`getPlayer()` rather than on an action's `self.character`. Cooking's XP is therefore reachable only
through the crafting flow of section 3, never through a dedicated queueable cooking action.

**Foraging (PlantScavenging) — a SYSTEM path, not an action path.** No TimedAction grants it. The
single site is `shared/Foraging/forageSystem.lua:2180`, inside `forageSystem.giveXP(_character,
_itemDef, _distanceTravelled)`, called from `forageSystem.lua:2169` and
`server/Foraging/forageServer.lua:363`, and the amount is derived from **distance travelled** with a
level-based diminishing return. Note also that the reopened "Foraging" territory in `ROADMAP.md` is
loot-zone learning, which is a different subject from the PlantScavenging skill; this row is about
the skill.

**First Aid (Doctor) — the candidate nobody listed, and the only one whose surface this repo
already owns.** Six sites, all in `complete()`: `ISApplyBandage.lua:117` (+5), `ISCleanBurn.lua:66`
(+10), `ISRemoveGlass.lua:63` (+15), `ISSplint.lua:92` (+15), `ISStitch.lua:105` (+15),
`ISRemoveBullet.lua:65` (+20) — the largest per-action grants in the whole table. And the mod
**already queues in this domain**: `AutoPilot_Medical.lua` is a shipped module, `ISApplyBandage`
already appears in the mod's own source, and `AutoPilot_Medical.lua:228` and
`AutoPilot_Telemetry.lua:233,250` already sample `Perks.Doctor`. Nothing new has to be verified
against the engine for the accounting slice in D3.

---

## 5. Decision menu

Every default is overridable. Silence ships the defaults **only if the owner says "approve with
defaults"** — this document does not ship by silence, because D1 corrects a live document.

| id | question | **default** | the alternative, stated honestly |
|---|---|---|---|
| **D1** | the gate wording | **adopt the corrected bar**: the grant must be inside the action's own lifecycle, cited by file, line and hook | keep the literal `perform()` reading, which closes this territory permanently — say so in the roadmap rather than leaving it looking open |
| **D2** | scope of V7.0 | **skills only.** Combat, Explore and loot-zone Foraging stay reopened territory but are not in this document | widen V7.0 to the whole reopened set, which makes it a much larger proposal and delays every decision in it |
| **D3** | what ships first | **First Aid accounting, no new queued action.** The mod already bandages; the change is that the leveler metrics and the F11 panel count Doctor XP beside Strength and Fitness | ship nothing first and hold the whole territory until a bigger design exists |
| **D4** | Tailoring | **DEFER on the supply constraint, not on the engine** — thread and fabric are consumed and `isValid()` needs four items at once. Clearing condition: one in-game reading of how many patchable holes and how much thread a normal session actually carries | approve Tailoring now and accept that the mod spends the player's sewing stock without being asked |
| **D5** | the 714-entry crafting surface | **DEFER to its own proposal.** Driving `ISCraftAction` means the mod picking recipes and consuming the player's materials | fold crafting into V7.0 now, which makes this the largest expansion the mod has ever taken |
| **D6** | Mechanics, Cooking, PlantScavenging | **CLOSE all three, each with its measured reason** (section 4): Mechanics on the standing Vehicles non-goal, Cooking on having no action path at all, PlantScavenging on being a distance-derived system path | keep any of them listed as a candidate, which requires reversing the Vehicles non-goal for Mechanics or accepting an event-handler path for Cooking |

**A safety property that is not a decision, and is stated so it is never proposed.** The mod must
never injure the character to create work for a medical arm. Every First Aid grant above is paid
for by an injury that already exists; an arm that farmed them would invert the mod's standing
player-agency property (never touch what it did not queue, F10 always cancels). D3 is accounting
only for exactly this reason — it counts XP the mod already earns and changes no behaviour.

**Sequencing is dependency order only, no calendar.** D3 is one PR and depends on nothing. D1 and
D6 are documentation and ship with this one. D4 and D5 are each their own proposal if approved.

---

## 6. Done-when, checkable by command

For **this document** (the product increment):

- `docs/EXPANSION_PROPOSAL_V7.md` exists on `main` and `ROADMAP.md`'s Blocked row names it as
  written rather than as pending.
- The falsified `perform()` claim is corrected in **every** home a grep finds, each with the
  superseded wording quoted where it stood: `ROADMAP.md` (the Skills bullet, the standing non-goal,
  the Blocked row) and `docs/EXPANSION_PROPOSAL_V6.md`. Verified by
  `grep -rn "perform()" --include=*.md .` returning only corrected or tombstoned text.
- `bash check.sh` green, and `tests/test_roadmap_truth.py` green — this edit moves neither of the
  two glob-derived figures that guard binds (`42/media/lua/client/*.lua` and `tests/test_*.lua`),
  which was checked before the first edit, not after.

For **D3**, if approved (stated now so the slice cannot drift):

- A behaviour-difference test: the same session's metrics with and without a Doctor XP sample,
  proving the panel value moves for a bandage the mod queued and does not move for one it did not
  (the V4.5 ownership registry is the discriminator).
- The F11 panel and the run log agree on the number, read from one source.
- Carries the standing "needs in-game smoke test before Workshop update" flag.

**No guard is added for the engine figures in sections 2, 3 and 4, deliberately.** They are
statements about an install that is not checked in, so no test in this repo can read them — the
same reasoning `tests/test_architecture_truth.py:255-265` already records for the V6.3 Discomfort
claim, and `docs/b42_20_checklist.md` is the artifact that owns re-deriving engine facts by hand on
42.20. Writing a text-matching guard over this document instead would assert only that the
sentences still exist, which is the shape that reads as coverage while providing none. Recorded
here so the absence is not read later as an oversight.

---

## 7. What this proposal deliberately does not contain

- **No module design.** If D3 is approved it is an accounting change inside existing modules, not a
  Skills module; the V3.1-deleted `AutoPilot_Skills.lua` stays deleted and is not a starting point
  (it predates every API correction since V2.1).
- **No new engine surface.** Every symbol named here was read live today; nothing is mocked on a
  guess, per this project's verified-surface discipline.
- **No combat.** The hard engine finding stands: Build 42 exposes no attack API for an AI-driven
  character, so no candidate here involves the mod swinging a weapon.
- **No Carpentry/Woodwork**, despite 142 script-layer `xpAward` entries making it the second-largest
  surface in the game. The owner directed that woodwork XP is explicitly not a leveler feature, and
  a large number is not a reason to reopen a decision.
- **No calendar.** Agent throughput makes dates meaningless here; the only sequencing constraints
  are dependency order and the owner's gates.
