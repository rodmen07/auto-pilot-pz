# In-Game Test Checklist — AutoPilot V1.0

Run these on a **fresh save** (no existing mods, default sandbox settings) before Workshop upload.
Check each box when verified. A fresh character starts with no skills and no home base.

## Setup
- [ ] Mod loads without Lua errors in PZ console
- [ ] F10 toggles autopilot on/off (HUD shows OFF/ON)
- [ ] H sets or resets home base (chat log shows "[Home] Home set at X,Y,Z r=15")

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
- [ ] Bot detects zombie within 10 tiles (check log for "[Threat]")
- [ ] Bot fights zombie when healthy
- [ ] Bot flees toward home when bleeding (apply wound first, then spawn zombie)
- [ ] Bot swaps weapon when condition is low (degrade weapon in debug mode)

## Looting
- [ ] Bot loots food from nearby container within home bounds
- [ ] Bot skips container after confirming empty (check depleted_squares in state logs)
- [ ] Bot expands search after 5 empty cycles (set SUPPLY_RUN_TRIGGER=1 for faster test)

## Home & Barricade
- [ ] Bot stays within 15-tile home radius for all non-combat activities
- [ ] On F7, windows near home are nailed (requires nails + hammer in inventory)
- [ ] Barricade does not repeat on second F7 press (ModData flag set)
- [ ] Home position reloads correctly after save/quit/reload

## Multiplayer (private server)
- [ ] Mod loads on client; no errors on server console
- [ ] Bot actions affect only the local player (no cross-player item transfers)
- [ ] Home ModData persists after reconnect

## Clean-up
- [ ] No Lua errors in console after 10+ minutes of bot operation
- [ ] No performance degradation (FPS stable over time)
