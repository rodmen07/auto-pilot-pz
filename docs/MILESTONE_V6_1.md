# AutoPilot V6.1: train more, lie less

> ## STATUS: PROPOSED 2026-07-26 (V6.0 close-out increment), awaiting one answer
>
> **Slice 1 requires an EXPLICIT user answer and does NOT ship by silence**, because it
> reverses endurance defaults the user chose directly in V5.7 ("I want the character to rest
> until endurance is nearly full" is quoted in the shipped comment above
> `ENDURANCE_REST_TARGET`). Slices 2 and 3 close bugs already filed in the backlog (MED and
> LOW), carry ordinary overridable defaults, and are actionable now without any decision.
>
> Ordering is by dependency only; nothing here is sized in calendar time.

---

## 1. Why this milestone

Every claim below is a measurement from the 2026-07-26 in-game session (02:12-02:51, 10,400
ticks; `auto_pilot_run.log`, 15,630 lines, 100% schema_version=5), not static analysis:

- **The leveler exercised for 1.5% of the session** (238 exercise ticks of 15,630). Of 1,636
  action episodes, **1,374 were rest**, and 1,341 of those logged `reason=rest_cooldown` —
  the endurance hold. Measured endurance: min 58, max 100, **mean 85.3**; the stop floor that
  would justify all that resting (`EXERCISE_ENDURANCE_MIN = 0.30`) was never approached.
- **The combat telemetry says "engage" on a path that can only flee.** 90 of 105 combat ticks
  logged `engage_running`/`engage_cooldown`; PR #74 made `AutoPilot_Threat` flee-only because
  Build 42 exposes no attack API. Anyone reading the log concludes the mod fights; it cannot.
- A whole reporting surface (`printStatus`/`getMoodleSnapshot`) is computed for nobody: no
  production caller, output through a noop-shadowed `print`.

V6.0 made the mod explain its decisions; V6.1 makes the numbers behind them worth reading.

## 2. The slices

### V6.1-1 — Close the idle band (fixes the HIGH tuning bug; USER-GATED, see Q1)

Constants at source, verified live 2026-07-26 (all three already player-tunable sliders):

| Constant | Value | Where | Provenance |
|---|---|---|---|
| `ENDURANCE_REST_TARGET` | 0.95 | `AutoPilot_Constants.lua:217` | V5.7, the user's direct request; rest ends here |
| `EXERCISE_ENDURANCE_RESUME` | 0.90 | `AutoPilot_Constants.lua:309` | V5.7, the user's own "90"; training resumes here |
| `EXERCISE_ENDURANCE_MIN` | 0.30 | `AutoPilot_Constants.lua:301` | the floor an active run trains down to |

Mechanism: the rest hold (`reason=rest_cooldown`, emitted at `AutoPilot_Needs.lua:644`) keeps
the character seated until endurance reaches TARGET (0.95). Endurance recovery flattens near
full, so the crawl from ~0.85 to 0.95 dominates wall-clock time in a band where training was
already permitted (RESUME = 0.90). The session's mean endurance of 85.3 is the picture of a
character waiting out the flat part of the curve.

**Q1 — pick one (explicit answer required; the recommended default is (a)):**

- **(a) RECOMMENDED: lower the shipped defaults to `EXERCISE_ENDURANCE_RESUME = 0.75` and
  `ENDURANCE_REST_TARGET = 0.80`.** Keeps the invariant MIN < RESUME < TARGET and the >= 0.05
  anti-thrash margin the V5.7 comment demands. Both remain sliders, so "rest until nearly
  full" stays one options change away — this moves the DEFAULT, not the ceiling.
- **(b) Decouple the two meanings:** the rest hold releases at RESUME + 0.05 instead of
  TARGET; TARGET keeps meaning "a seated rest may continue to here" but stops gating the
  return to training. More code than (a), preserves the 0.95 feel when idle.
- **(c) Keep as-is:** accept ~1.5% training as the cost of near-full endurance. The bug is
  then closed as working-as-directed and the backlog entry records that.

Done-when (checkable headlessly): a behavior-difference fixture proving a character at
endurance 0.85 TRAINS under the new rule and RESTED under the old; a guard asserting
`ENDURANCE_REST_TARGET - EXERCISE_ENDURANCE_RESUME >= 0.05` so the thrash margin cannot
silently erode; luacheck 0/0 and every existing suite green with only expected-value edits.
Ships flagged "needs in-game smoke test"; the success metric — exercise tick share well above
1.5% in the next real session — is measurable since PR #89's XP telemetry.

### V6.1-2 — Flee-only telemetry must say flee (fixes the MED "telemetry lies" bug; actionable now)

Rename the `engage_running`/`engage_cooldown` reasons set at `AutoPilot_Threat.lua:493,502`
to names describing what runs (e.g. `evade_running`/`evade_cooldown`), and reconcile the
"fight OR flee" / "a fighting player must not start bare-handed" comments in the same file.
The Lua `REASON_CLASS` table and `tools/benchmark.py`'s `_ACTION_CLASS_MAP` move in the SAME
commit (the CI sync guard rejects a one-sided edit, proven by PR #19).

**Overridable default:** `checkAndSwapWeapon`'s pre-equip on the threat path STAYS. A fleeing
character can be caught, and a caught character under player control defends with whatever is
in hand; the pre-equip is cheap and does not contradict flee-only. Say "drop it" and it goes.

Done-when: no `engage_*` string survives in `42/media/lua/client/` or `tools/` (grep-clean);
suites green with renamed expectations; the triage detectors keyed on decision labels
(`detect_combat_cycles`) updated in the same commit if they name the old strings.

### V6.1-3 — Delete the dead reporting path (fixes the LOW dead-path bug; actionable now)

`AutoPilot_Needs.printStatus` has zero production callers and prints through the
noop-shadowed local `print`; `getMoodleSnapshot`'s only in-mod caller is `printStatus`
itself. **Overridable default: DELETE both** (the F11 panel, the HUD reason line, and the run
log are the living surfaces; a second, dead vocabulary invites exactly the drift PR #84
fixed). Say "wire it" and the snapshot routes into the run log instead of being deleted.

Done-when: both functions gone (or wired), their test coverage retargeted or removed with the
reason recorded, luacheck 0/0, suites green.

## 3. Explicitly NOT in V6.1

- No revival of Foraging, Skills, Vehicles, Combat, Explore, or Actions.
- No Stress or Discomfort relief action: 42.19 exposes no Lua-visible path for either
  (established by PR #83's follow-up). That gap needs a product answer, not a code slice.
- No change to the V6.0 malus ranking, the carry-capacity gate, or the ownership registry.
- No Workshop action of any kind (USER-ONLY, permanently).

## 4. What only the user can settle

- Q1. It is the whole reason slice 1 is gated: (a) and (b) both override values you chose.
- Whether 1.5% training is actually a problem for how you play. If the mod's job during your
  AFK sessions is "stay alive" first and "level" second, option (c) is a legitimate answer.
- The in-game smoke test for whatever ships.
