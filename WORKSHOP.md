# Steam Workshop Description (BB code — paste into Workshop upload page)

[h1]AutoPilot[/h1]
[b]Keeps your character alive and leveling while you're AFK.[/b]

AutoPilot is a client-side mod for Project Zomboid Build 42 that runs a full survival and fitness routine automatically. Toggle the bot and it auto-sets home on first enable.

[h2]Features[/h2]

[b]Survival[/b]
[list]
[*]Eats when hungry — calorie-aware food selection (high-cal when underweight, low-cal when over)
[*]Drinks from sinks, taps, and containers when thirsty
[*]Sleeps in the nearest bed; rests on the floor when no bed is available
[*]Bandages wounds automatically, prioritising bleeding and infection
[*]Manages happiness — prefers tasty food; reads magazines/books when bored
[*]Temperature-aware clothing — equips warmer/cooler gear based on body temperature
[/list]

[b]Exercise[/b]
[list]
[*]Exercises to level Strength and Fitness evenly — targets whichever stat is lower
[*]Prefers dumbbells (1.8× XP) and barbells (1.2× XP) over bodyweight exercises
[*]Searches home area for exercise equipment and equips the best available
[*]Skips exercise when endurance is below 30%; resumes at 70%
[*]Caps at 20 sets per in-game day to avoid over-training; resets on day rollover
[/list]

[b]Combat[/b]
[list]
[*]Detects zombies within 10 tiles
[*]Fights when safe; flees toward home when bleeding or outnumbered
[*]Checks weapon durability before combat — auto-swaps to best melee weapon when condition drops below 25%
[/list]

[b]Looting[/b]
[list]
[*]Forages for food, drink, medical supplies, and exercise equipment within home bounds
[*]Bulk-loots containers — grabs all useful items in one trip
[*]Tracks depleted containers and skips them on future passes
[*]Expands search radius to 200 tiles after 5 consecutive empty loot cycles (supply runs)
[/list]

[b]Home Base[/b]
[list]
[*]Home base is auto-set to your current position the first time you enable autopilot
[*]Bot stays within home bounds for all activities
[*]Barricades windows once after home is set (requires nails + hammer in inventory)
[*]Home position persists across sessions via ModData
[/list]

[b]Local Autonomous Survivor Mode[/b]
[list]
[*]No sidecar required — all decision logic runs inside the mod.
[*]Toggle autopilot with [b]F10[/b] (keyboard/mouse player).
[*]Controller players (splitscreen) toggle with [b]Back/Select double-tap[/b].
[*]AutoPilot starts enabled by default — no setup needed.
[*]Home anchor is auto-set on first enable.
[/list]

[h2]Controls[/h2]
[list]
[*][b]F10[/b] — Toggle autopilot on/off (keyboard/mouse player)
[*][b]Back / Select × 2[/b] — Toggle autopilot (controller players in splitscreen)
[/list]

[h2]Compatibility[/h2]
[list]
[*]Build 42 only
[*]Client-side — no server mod required
[*]Safe for private multiplayer servers (client authority only; no cross-player actions)
[*]Splitscreen: up to 4 local players, each with an independent autopilot instance
[/list]

[h2]Known Limitations[/h2]
[list]
[*]No server-side authority — autopilot actions are local to each client; the server is not aware of the bot.
[*]No cross-player item transfers in splitscreen — each player's bot only uses their own inventory.
[*]Telemetry log ([i]~/Zomboid/Lua/auto_pilot_run.log[/i]) grows unbounded; delete it between benchmark sessions.
[*]The launcher scripts ([i]start_autopilot.bat[/i], [i]sync_after_merge.bat[/i]) are developer tools — they are not required for normal gameplay.
[/list]

[h2]Requirements[/h2]
[list]
[*]Project Zomboid Build 42.15.3+
[/list]

[h2]Source & Issues[/h2]
GitHub: [url=https://github.com/rodmen07/auto-pilot-pz]github.com/rodmen07/auto-pilot-pz[/url]
Bug reports and feature requests welcome via GitHub Issues.
