# AutoPilot Leveler — Multiplayer Setup (Build 42 Unstable)

B42 multiplayer shipped to the unstable branch in December 2025 and is actively
patched (42.19 improved MP stability). It remains UNSTABLE: expect desync,
crashes, and save breakage between game updates.

## How the mod behaves in MP

- **Client-side only.** There are no `server/` Lua files. Each player who has
  the mod enabled runs their own automation for their own character only.
  (Splitscreen is not supported as of V3.2 — one automated character per
  client.)
- All actions go through `ISTimedActionQueue` (the same path as manual play),
  so the server validates every action; the mod cannot desync inventory or
  teleport characters.
- Home anchors and skill selections persist via `player:getModData()` +
  `transmitModData()`, which the server stores per character.
- Players WITHOUT the mod are unaffected. Players with the mod each control
  their own toggle (F10) and focus selection (F11).
- Telemetry/death logs write to each client's own `Zomboid/Lua/` folder, never
  to the server.

## Hosting checklist (your own dedicated server)

1. **Branch**: set the server to the Build 42 unstable branch, matching the
   client version exactly (42.19.0 as of this writing; MP rejects mismatches).
2. **RAM**: plan 8-9 GB minimum for a B42 server; keep population under ~20
   (current TIS guidance).
3. **Publish the mod to the Steam Workshop** (see WORKSHOP.md), then add to
   the server's `servertest.ini`:
   ```ini
   Mods=AutoPilot
   WorkshopItems=<your-workshop-id>
   ```
   Joining players auto-download it from the Workshop.
4. **Server options that matter to the mod**:
   - `SleepAllowed=true` — without it the sleep branch is skipped by the
     vanilla checks the mod goes through (`onSleepWalkToComplete` respects it).
   - `SleepNeeded` — if everyone must sleep, AFK characters sleeping on their
     own schedule is desirable; leave on.
5. **Fair-play note**: automation is fine on your own server; if you list the
   mod publicly, say clearly in the description that it automates AFK play so
   other server owners can decide whether to allow it.

## Known MP caveats

- B42 MP updates can break saves without warning; pin the server branch and
  update deliberately.
- `setAsleep`-style forced state changes are avoided by design (server desync);
  sleep goes through the vanilla context-menu flow instead.
- If the server disables sleep, fatigue management degrades to rest-only; the
  leveler keeps training but exercise gating by endurance still applies.
