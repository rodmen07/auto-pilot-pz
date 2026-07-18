# In-Game Test Checklist — AutoPilot V3.2

Run these on a **fresh save** (no existing mods, default sandbox settings) on
**Build 42.19.0 Unstable** before Workshop upload. Check each box when
verified. A fresh character starts with no skills and no home base.

> **Why in-game testing is mandatory:** the off-game mocks cannot catch
> class-existence bugs (a mocked `ISGetOnBedAction` passed tests for months
> while the real class does not exist in B42). Every new timed-action call
> must be smoke-tested in the actual game once.

## Auto-Exercise Leveler (V3.2)
- [ ] Mod is INACTIVE on spawn (HUD shows OFF); nothing happens until F10 arms it
- [ ] F10 arms the mod; home anchors at the current position on the first
      active cycle
- [ ] F11 opens/closes the leveler panel
- [ ] Strength focus: push-ups ONLY (no squat/sit-up drift)
- [ ] Fitness focus: squats; switches to sit-ups once leg stiffness builds,
      back to squats after recovery
- [ ] Auto focus: burpees first (levels Strength AND Fitness together)
- [ ] Long grind: when an exercise's XP flatlines (PZ diminishing returns),
      the bot rotates to the next exercise; with everything spent it PAUSES
      ("resting") instead of exercising for zero XP, and resumes ~3 game
      hours later
- [ ] Panel shows BOTH perk blocks; metrics update: XP rises, XP/hour appears
      after ~1 min, ETA shown; focused perk is highlighted
- [ ] Focus survives save/quit/reload (ModData)
- [ ] MP: error counter stays at 0 after joining a server (Lua-reload fix)
- [ ] Zombies wandering OUTSIDE the walls do not interrupt training (HUD may
      show Z:2+ while exercising); a chasing or adjacent zombie still triggers
      fight-or-flee immediately

## Death Learning (V3.2)
- [ ] Die once → `Zomboid/Lua/auto_pilot_deaths.log` gains one line with a
      plausible cause= field and recent decisions
- [ ] Next session start: console shows "[Adaptive] N death(s) on record" and
      the F11 panel shows the adaptive tweak count
- [ ] After 2+ horde deaths, FLEE_HORDE_SIZE drops (flees earlier) but never
      below 3 (bounded)

## B42 Compatibility (V2.1 fixes, verified against 42.19)
- [ ] Mod appears in the in-game mod list (verifies `common/` folder +
      `pzversion` fix — a missing `common/` silently hides the mod)
- [ ] High fatigue near a bed → character walks to the bed and actually falls
      asleep (`onSleepWalkToComplete` path)
- [ ] No bed available but a car nearby → character boards it and sleeps inside
- [ ] Idle with good endurance → exercise animation actually plays (squats etc.)
- [ ] Inside home with hammer + plank + 2 nails → a window gets barricaded
      (hammer/plank equip actions first, then hammering animation)
- [ ] `%USERPROFILE%/Zomboid/Lua/auto_pilot_run.log` GROWS across cycles
      (append fix — previously held only the single most recent line)

## Setup
- [ ] Mod loads without Lua errors in PZ console
- [ ] F10 toggles autopilot on/off (HUD shows OFF/ON)
- [ ] AutoPilot starts **OFF by default** — stabilize first, then F10 to grind
- [ ] First arming auto-sets home base (console shows "[Home] Home set at X, Y (z=Z, r=R)")

## Survival Needs
- [ ] Bot eats when hungry (selects food from inventory or loots nearby)
- [ ] Bot drinks from a sink/tap when thirsty
- [ ] Bot finds a bed and sleeps when tired
- [ ] Bot rests on floor when no bed is available
- [ ] Bot bandages a wound when injured (apply a scratch in debug mode)
- [ ] Bot reads a book/magazine when bored moodle appears
- [ ] Bot equips warmer clothing when temperature drops (use sandbox time-skip to winter)

## Exercise
- [ ] Bot performs exercise actions when idle (squat/sit-up/etc.)
- [ ] Bot picks up dumbbells or barbells if present in home area
- [ ] Bot skips exercise when endurance is low (run extensively first)
- [ ] Exercise set counter increments in log; resets on new in-game day

## Combat
- [ ] Bot detects zombie within 20 tiles (check log for "[Threat]")
- [ ] Bot fights zombie when healthy
- [ ] Bot flees toward home when bleeding (apply wound first, then spawn zombie)
- [ ] Bot swaps weapon when condition is low (degrade weapon in debug mode)

## Looting
- [ ] Bot loots food from nearby container within home bounds
- [ ] Bot skips container after confirming empty (check depleted_squares in state logs)
- [ ] Bot expands search after 5 empty cycles (set SUPPLY_RUN_TRIGGER=1 for faster test)

## Home & Barricade
- [ ] Bot stays within home bounds for all non-combat activities
- [ ] On first enable with hammer + plank + 2 nails, windows near home are queued for barricading
- [ ] Already-barricaded windows are skipped on the periodic maintenance re-check
- [ ] Home position reloads correctly after save/quit/reload

## Multiplayer (private server — setup guide in MULTIPLAYER.md)
- [ ] Mod loads on client; no errors on server console
- [ ] Bot actions affect only the local player (no cross-player item transfers)
- [ ] Home ModData persists after reconnect

## V3.3 Additions
- [ ] With a dumbbell in inventory + Strength focus: dumbbell press runs
      (not push-ups); without gear: push-ups
- [ ] Once per day the bot fetches a dumbbell/barbell from home containers
      when none is carried (strength/auto focus)
- [ ] F11 panel: shows live status line ("training: squats", "resting (...)"),
      sets today N/cap, regularity of the current exercise, arm/disarm button
      works, panel position is remembered after reopening
- [ ] Options > Mods > AutoPilot Leveler: sliders apply in-game after Save
      (e.g. lower daily cap and watch training stop at it); F10/F11 rebind works
- [ ] Telemetry: with a run log over 20k lines, session start trims it to 5k
      ("[Telemetry] Rotated log" in console)

## Soak Test (multi-hour stability)
- [ ] 2+ real hours armed on the server: no error counter growth, no FPS decay
- [ ] XP keeps stepping up across fatigue rotations (panel session gain grows)
- [ ] Survival interruptions (eat/drink/sleep) resume training afterwards
- [ ] Death during soak: snapshot line written; next session shows adaptive
      tweak in panel

## Clean-up
- [ ] No Lua errors in console after 10+ minutes of bot operation
- [ ] No performance degradation (FPS stable over time)
