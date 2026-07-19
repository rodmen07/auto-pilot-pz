# Steam Workshop Description (BB code — paste into Workshop upload page)

[h1]AutoPilot Leveler[/h1]
[b]Grind Strength and Fitness while AFK — with a survival fail-safe watching your back.[/b]

AutoPilot Leveler is a client-side mod for Project Zomboid Build 42 (unstable). Reach a stable spot — vicinity cleared, supplies stocked — then press [b]F10[/b] and your character trains while you're away. This is a deliberate tool, not an always-on autopilot: it does nothing until you arm it.

[h2]Leveling[/h2]
[list]
[*]Pick a focus in the [b]F11[/b] panel:
[*]— [b]Strength[/b]: push-ups
[*]— [b]Fitness[/b]: squats, switching to sit-ups while the legs are stiff
[*]— [b]Auto[/b]: burpees (trains both stats together)
[*]Live metrics per stat: level, XP to next, session gain, XP/hour, ETA to next level
[*]Detects the game's per-exercise diminishing returns: when a set stops yielding XP, it rotates exercises — and rests instead of grinding for zero
[*]Equips dumbbells/barbells from your inventory or home area when available
[*]Endurance-aware: pauses between sets while wind recovers; daily set cap prevents over-training
[/list]

[h2]Survival Fail-Safe (while training)[/h2]
[list]
[*]Eats, drinks (including sinks/taps), sleeps in the nearest bed, and bandages wounds
[*]Fights or flees when zombies actually threaten — chasing, visible, or adjacent. Wanderers shambling outside your walls are ignored, not panicked over
[*]Keeps a small food/drink stockpile with short, near-home loot trips (never wanders the neighborhood)
[*]Maintains window barricades at your home anchor (hammer + planks + nails)
[*]Temperature-aware clothing swaps
[/list]

[h2]Death Learning[/h2]
[list]
[*]Every death is recorded with full context: stats, wounds, zombie pressure, position, recent decisions, and a classified cause
[*]On the next session the mod adjusts its own survival thresholds within safe bounds — flee earlier after horde deaths, eat earlier after starving, stay closer to home after dying far away
[*]The F11 panel shows deaths on record and active adaptive tweaks
[/list]

[h2]Controls[/h2]
[list]
[*][b]F10[/b] — arm / disarm (starts OFF; home anchors where you stand when first armed)
[*][b]F11[/b] — leveler panel: focus selection + live XP metrics
[*]Options > Mods > AutoPilot Leveler: sliders for training and survival tunables (daily set cap, endurance minimum, stockpile minimums, loot/detection radii) plus rebindable F10/F11 keys
[/list]

[h2]Compatibility[/h2]
[list]
[*]Project Zomboid Build [b]42.19.0 Unstable[/b]
[*]Client-side only — no server mod required; safe to list on hosted servers ([i]Mods=AutoPilot[/i])
[*]Multiplayer: each player automates their own character only; all actions go through the normal server-validated action queue
[*]Focus and home anchor persist per character via ModData
[*]Splitscreen is NOT supported
[/list]

[h2]Known Limitations[/h2]
[list]
[*]Exercise-focused by design: it will not explore, clear buildings, or manage a base beyond barricade upkeep
[*]The survival layer is a fail-safe, not a caretaker — arm it from a stable position
[*]Telemetry log ([i]~/Zomboid/Lua/auto_pilot_run.log[/i]) rotates automatically since V3.3 (trimmed to the newest 5,000 lines at session start once it passes 20,000); safe to delete anytime
[*]B42 multiplayer is itself unstable; expect the usual unstable-branch rough edges
[/list]

[h2]Fair Play Note[/h2]
This mod automates AFK play. Use it on your own server or with the server owner's blessing.

[h2]Source & Issues[/h2]
GitHub: [url=https://github.com/rodmen07/auto-pilot-pz]github.com/rodmen07/auto-pilot-pz[/url]
Bug reports and feature requests welcome via GitHub Issues.
