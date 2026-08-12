# Build 42.20 Migration Checklist

**Status:** PREPARATION ONLY. Do not execute any step below until Build 42.20
is the Steam default branch AND the user has explicitly decided to migrate
(`ROADMAP.md` "Blocked" table). This document exists so that decision does
not also require re-deriving the mod's API surface from scratch.

## Why this is a real event, not a routine bump

`pzversion=42.19.0` is pinned in both `mod.info` files, and 42.19 saves will
not carry over to 42.20. The mod has already been burned by an untested
engine-surface assumption twice in its history: `ISTimedActionQueue.addGetUpAndThen`
was wrongly assumed removed in V2.1 and shipped for a time without it
(restored in V3.2 after a live stack trace proved it exists), and
`PZAPI.ModOptions` availability-at-load was assumed vanilla-client-guaranteed
until V5.5 proved it silently `nil` on a real client, making every option
inert for several releases while the off-game mock stayed green throughout.
Both are the same failure shape: a mocked assumption survived because the
mock, not the live engine, was what tests actually ran against. 42.20 is
exactly the situation that shape recurs in.

## Source of truth: `tests/lua_mock_pz.lua`, not this document

The mod's own mock file carries a continuously-maintained,
line-cited **"VERIFIED 42.19 API SURFACE"** header (updated at every release
that touches an engine call — most recently V5.8) enumerating every PZ API
this mod calls, its runtime-verified signature, and how the test suite
covers it. This checklist does **not** duplicate that list: a second enumeration is a
second thing that can drift out of sync with the code, the same shape as the
stale `README.md` modversion claim the V3.5 docs-truth pass had to correct
against `mod.info`. Instead, this document is
the **procedure** for re-verifying that existing list against 42.20 and
updating its header in place.

## Step 1: re-verify each surface against the running 42.20 client

For every `[MA]`/`[M]`/`[S]` entry in `tests/lua_mock_pz.lua`'s header
(constructors, statics, engine accessors, `PZAPI.ModOptions` widgets), confirm
on the actual running B42.20 client that:

1. The class or function still exists (a class that silently no longer
   exists is indistinguishable from a class that always failed a guarded
   `pcall`, so absence must be checked positively, not inferred from "no
   error").
2. The argument order, count, and types are unchanged.
3. Any behavior the mod depends on beyond the signature (e.g. `getFileWriter`
   append-vs-truncate semantics, `getSpecificPlayer` vs `getPlayer` index
   handling) still holds.

**Never re-derive this from a fresh file read of the game install.** File-read
tools against the Steam install directory can return stale or phantom
content; only a live shell command against the actual running install, or a
real in-game stack trace, counts as verification. This is the same
phantom-file class of bug that shipped a wrong `ISFitnessAction` signature
once already (`CHANGELOG.md` V2.1/V3.2; `docs/EXPANSION_PROPOSAL_V4.md`).

### Prioritize by prior-break history first

These five surfaces have each already broken once in this mod's history —
verify them before the rest of the list:

- `ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)`
  — the exeData/exeDataType argument order broke across V2.1→V3.2.
- `ISTimedActionQueue.addGetUpAndThen(character, action)` — existence, not
  just signature; V2.1 wrongly assumed it removed.
- `ISRestAction:new(character, bed, useAnimations)` — exact 3-arg form,
  reconfirmed in V3.2; V5.8 changed how the mod calls it (fallback-only) but
  not the signature itself.
- `PZAPI.ModOptions` **availability at mod-load time** — proven `nil` on a
  real client in V5.5 despite being assumed vanilla-guaranteed; the fix
  (retry on `Events.OnMainMenuEnter` + `Events.OnTick`) depends on those
  events still firing in that order on 42.20.
- `PZAPI.ModOptions:addComboBox` — exists and returns successfully but
  renders zero items on a real V5.5-era client (V5.7 finding); any control
  added between now and the 42.20 pass needs the same "a successful call is
  not proof the widget works" scrutiny before trusting it.

Also newest and least battle-tested: `ISPathFindAction:pathToSitOnFurniture`
(V5.8) has exactly one release of real-world exposure.

### Re-check the Discomfort absence claim, in BOTH layers

`docs/architecture.md`'s **Moodle Coverage** section and the README's
"The one moodle AutoPilot leaves to you" note both state that 42.19 exposes no
Lua-visible relief action for Discomfort. That is a NEGATIVE claim about the
engine, which is precisely the kind 42.20 can flip without anything in this
repo going red — no test can see it, because the install is not checked in.
Re-derive it on 42.20 rather than inheriting it, with **two** greps, not one:

1. `grep -rn "iscomfort" media/lua/ | grep -v Translate/` — 42.19 answer: 10
   hits, none a queueable action (the debug slider and its label, the sandbox
   `DiscomfortFactor` rows, and `StressFromDiscomfort` /
   `VehicleDiscomfortWhenOverEncumbered` in `shared/defines.lua`). A hit that
   is a timed action, a context-menu entry, or anything a mod could queue means
   the claim has flipped and both documents are wrong.
2. `grep -rc "DiscomfortModifier" media/scripts/generated/items/*.txt` — 42.19
   answer: 343 in `clothing.txt`, 1 in `container.txt`, values 0.02 to 0.75.
   This is the layer the original false claim never looked at, and it is where
   the item EFFECT properties live.

**Both layers, every time.** The one-directory mistake has now been made twice
in this project's history — once about Stress (301 `StressChange` entries sat
in `media/scripts` while a `media/lua`-only grep concluded there was no relief
at all, PR #117) and once about Discomfort's lever. `media/lua` holds the code
that READS and ADDS stats; `media/scripts` holds the definitions that carry the
EFFECT properties the engine applies when a queued action completes. A search
of the first alone makes real capability look absent.

## Step 2: update the mock header, not just the mock behavior

When a signature or existence fact changes, update the corresponding line in
`tests/lua_mock_pz.lua`'s header comment in the same change that updates the
mock body and any production callsite — the header is the audit trail future
runs (agent or human) read first, per its own stated purpose.

## Step 3: mechanical release steps (execute only once Step 1 is clean)

1. Bump `pzversion` in **both** `mod.info` (repo root) and `42/mod.info`.
   Correction (2026-07-20): an earlier draft of this document claimed no CI
   check enforces the two files staying in sync. That was wrong —
   `tests/test_version_sync.py::test_both_mod_info_files_agree` already
   does, runs on every push via `ci.yml`'s bare `pytest tests/`, and would
   fail loudly on a `pzversion=` (or `modversion=`) mismatch. `pzversion=`
   itself is outside that test's scope (it only compares `modversion=`), so
   still bump and diff both by hand — the guard just means a caught mistake
   fails CI instead of shipping silently.
2. Review `tags=` in both `mod.info` files and the Workshop description
   template in `sync_workshop.sh` for anything 42.20-specific.
3. Full `TESTING.md` pass, including the soak test. Note in passing: the
   file's own title still reads "V3.3" (last retitled in the V3.5 docs pass);
   retitling it to the current version is a separate small hygiene item, not
   part of this checklist, filed in the AutoPilot backlog.
4. Workshop tag/description update and "Update Item" upload. `./sync_workshop.sh`
   is agent-doable (it only refreshes the local staging folder); the "Update
   Item" upload itself is the user's, because it is an in-game main-menu flow
   with no CLI path — see `ROADMAP.md` "User-only (standing)". (Superseded
   wording, quoted where it stood: *"USER-ONLY: Workshop tag/description update
   and "Update Item" upload via `sync_workshop.sh`."* The USER-ONLY marker was
   lifted 2026-08-08.)

## Done when

**Preparation** (agent-doable, this document): exists and covers every
`[MA]`/`[M]`/`[S]` API surface `tests/lua_mock_pz.lua` currently enumerates,
by procedure rather than by duplicating the list.

**Execution** (USER-GATED, blocked): Build 42.20 is the Steam default branch
AND the user has explicitly decided to migrate. See `ROADMAP.md` "Blocked".
The gate is the migration DECISION and the in-game verification it needs, both
of which are genuinely the user's; it is no longer the Workshop upload, whose
USER-ONLY marker was lifted 2026-08-08 (superseded wording, quoted where it
stood: *"**Execution** (USER-ONLY, blocked)"*).
