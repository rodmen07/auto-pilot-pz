# Steam Workshop Description (BB code — paste into Workshop upload page)

[h1]AutoPilot[/h1]
[b]Keeps your character alive and leveling while you're AFK.[/b]

AutoPilot is a client-side mod for Project Zomboid Build 42 that runs a full survival and fitness routine automatically. Set your home base, toggle the bot, and walk away.

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
[*]Press [b]F7[/b] to set home base at your current position (15-tile radius)
[*]Bot stays within home bounds for all activities
[*]Barricades windows once after home is set (requires nails + hammer in inventory)
[*]Home position persists across sessions via ModData
[/list]

[b]Optional: Claude LLM Sidecar[/b]
[list]
[*]Run [code]auto_pilot_sidecar.py[/code] alongside the game for AI-driven goal mode
[*]Provide a plain-English goal (e.g. "level Strength to 5") and Claude will plan and execute it
[*]Requires an Anthropic API key — see [url=https://github.com/rodmen07/auto-pilot-pz]the GitHub repo[/url] for setup
[/list]

[h2]Controls[/h2]
[list]
[*][b]F7[/b] — Set home base at current position
[*][b]F8[/b] — Toggle AutoPilot on/off
[*][b]H[/b] — Halt all queued actions immediately
[/list]

[h2]Compatibility[/h2]
[list]
[*]Build 42 only
[*]Client-side — no server mod required
[*]Safe for private multiplayer servers (client authority only; no cross-player actions)
[*]Single-player and splitscreen: single-player only (splitscreen support not implemented)
[/list]

[h2]Requirements[/h2]
[list]
[*]Project Zomboid Build 42.15.3+
[*]LLM sidecar (optional): Python 3.10+, [code]pip install anthropic[/code], Anthropic API key
[/list]

[h2]Source & Issues[/h2]
GitHub: [url=https://github.com/rodmen07/auto-pilot-pz]github.com/rodmen07/auto-pilot-pz[/url]
Bug reports and feature requests welcome via GitHub Issues.
