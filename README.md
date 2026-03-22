# AutoPilot — Project Zomboid Build 42 Mod

AFK auto-leveler for Strength and Fitness. Keeps your character alive through automated survival (eating, drinking, sleeping, wound treatment) while exercising to max both stats.

## Quick Start

1. The mod is already installed at `~/Zomboid/mods/auto_pilot/`
2. Launch Project Zomboid, enable **AutoPilot** in the mod list
3. Load into a game and press **F7** to toggle on/off
4. Watch the console (`ProjectZomboid64ShowConsole.bat`) for `[AutoPilot]` log messages

### Optional: Run with AI sidecar

```bash
cd ~/Zomboid/mods/auto_pilot
pip install anthropic
set ANTHROPIC_API_KEY=sk-ant-...
python auto_pilot_sidecar.py
```

The sidecar is **not required** — the mod runs fully autonomously without it. When running, the sidecar uses Claude to override the rule-based brain with AI-driven decisions.

## Architecture

Six Lua modules in `42/media/lua/client/`:

| Module | Purpose |
|--------|---------|
| `AutoPilot_Main.lua` | Orchestrator — OnTick loop, F7 toggle, LLM command dispatch |
| `AutoPilot_Needs.lua` | Priority-based survival state machine |
| `AutoPilot_Threat.lua` | Zombie detection, fight/flee logic |
| `AutoPilot_Inventory.lua` | Item scanning, water sources, auto-loot |
| `AutoPilot_Medical.lua` | Wound detection and auto-bandage |
| `AutoPilot_LLM.lua` | File-based IPC with optional Python/Claude sidecar |

### Priority Chain (AutoPilot_Needs)

1. **Bleeding** — bandage immediately (fatal if untreated)
2. **Thirst** — drink from tap/sink first, then inventory, then loot nearby
3. **Hunger** — eat best food from inventory or loot nearby
4. **Wounds** — treat non-bleeding wounds (scratches, bites, deep wounds)
5. **Exhausted** — rest (endurance critically low)
6. **Tired** — sleep in bed or in place
7. **Bored** — read literature, then go outside
8. **Idle** — exercise (Strength if STR <= FIT, else Fitness)

### Optional LLM Sidecar

The mod works fully autonomously without the sidecar. Optionally, run the Python sidecar for Claude-driven decision making:

```bash
# pip install anthropic
# set ANTHROPIC_API_KEY=sk-ant-...    //only need to run these two initially
python auto_pilot_sidecar.py
```

**Note:** PZ's Lua is completely sandboxed (no HTTP, no sockets). File-based IPC is the only mechanism for external communication — the sidecar polls `auto_pilot_state.json` and writes `auto_pilot_cmd.json`.

---

## Development Roadmap

### Phase 1: Don't Die (Survive Indefinitely) — COMPLETE *(v0.1.1)*

Added the two critical missing survival systems that would kill the character before reaching max stats.

| Task | Status | Details |
|------|--------|---------|
| Wound detection & auto-bandage | Done | `AutoPilot_Medical.lua` — iterates body parts, treats bleeding > deep wounds > bites > scratches > burns |
| Bandage priority selection | Done | AlcoholBandage > Bandage > RippedSheets; loots from nearby containers as fallback |
| Injury-aware combat | Done | Always flees when bleeding; flees when unarmed and outnumbered (>1 zombie) |
| Water source management | Done | `findWaterSource()` scans 10-tile radius for sinks/rain barrels via `hasFluid()` |
| Drink from taps/sinks | Done | `drinkFromSource()` — uses `ISTakeWaterAction` with nil item for direct drinking |
| Refill water containers | Done | `refillWaterContainer()` — finds non-full bottles, fills from nearby water source |
| Reading for boredom | Done | `doRead()` — reads literature via `ISReadABook` before going outside |
| Updated priority chain | Done | 8-step priority: bleeding > thirst > hunger > wounds > exhaustion > sleep > boredom > exercise |
| Expanded LLM state snapshot | Done | Now includes wound data + water source availability |
| Updated schemas & sidecar | Done | `bandage` action added, wound/water fields in state |

### Phase 2: Level Faster (Exercise Optimization) — IN PROGRESS *(v0.1.2)*

Maximize XP gain per in-game day.

| Task | Status | Details |
|------|--------|---------|
| Use exercise equipment | Done | `getExerciseEquipmentTier` scans inventory; dumbbell (1.8×) > barbell (1.2×) > bodyweight (1.0×) |
| Endurance-aware scheduling | Done | Hysteresis gate: pause below 0.30, resume only above 0.70 endurance |
| Daily set tracking | Done | `exerciseSetsToday` counter resets on day rollover; cap = 20 sets/day |
| Loot exercise equipment | Done | `equipBestExerciseItem` scans containers for `Base.DumbBell` / `Base.BarBell`, throttled 2 min |
| STR/FIT decay prevention | Done | Gap-aware selection: if \|STR−FIT\| > 1, strongly prefer the lagging stat's exercises |

### Phase 3: Sustained Survival (Weeks/Months) — NOT STARTED *(v0.1.3)*

Handle resource depletion for long-term play.

| Task | Status | Details |
|------|--------|---------|
| Extended foraging | Pending | Supply runs beyond 8-tile radius when containers empty |
| Home base tracking | Pending | Record safe position, return after supply runs |
| Visited building tracking | Pending | Avoid re-looting empty buildings |
| Bulk looting | Pending | Transfer all useful items per trip (food, water, medical, equipment) |
| Unhappiness management | Pending | Eat tasty food, read magazines for happiness |
| Weight management | Pending | Calorie-aware food selection based on player weight |

### Phase 4: Polish — NOT STARTED *(v0.2.1)*

Edge cases and minor optimizations.

| Task | Status | Details |
|------|--------|---------|
| Weapon durability tracking | Pending | Check condition before combat, swap to backup |
| Temperature/clothing | Pending | Equip warmer/cooler clothing by season |
| Safehouse barricading | Pending | One-time window/door barricading at home base |

### Phase 5: Deployment — NOT STARTED *(v0.2.2 / V1.0 release milestone)*

Publish the mod for others to use. Completing this phase marks the **V1.0** public release.

| Task | Status | Details |
|------|--------|---------|
| Steam Workshop upload | Pending | Publish via PZ's built-in Workshop uploader or `steamcmd` |
| Workshop description & tags | Pending | Write Steam Workshop page with feature list, screenshots, usage instructions |
| Poster artwork | Pending | Finalize `poster.png` for Workshop listing |
| In-game testing on fresh save | Pending | Full end-to-end validation on clean install (no leftover state) |
| Multiplayer compatibility check | Pending | Verify mod behavior in MP (client-only, no server-side effects) |
| Version tagging | Pending | Minor/patch releases use lowercase `v` (e.g. `v0.1`, `v0.1.2`); major releases use capital `V` (e.g. `V1.0`) |

---

## AI-Driven Architecture

### Current State

The mod has a **dual-brain design**:

1. **Rule-based Lua brain** (primary) — The `AutoPilot_Needs` priority chain handles all decisions locally inside PZ. This is deterministic, zero-latency, and requires no external dependencies. It works today.

2. **Claude LLM brain** (optional sidecar) — `auto_pilot_sidecar.py` polls game state every ~2s, asks Claude for the next action, and writes the command back via file IPC. When active, LLM commands override the rule-based brain.

### The Constraint

PZ's Lua runtime (Kahlua, a Java-embedded Lua 5.1) is **completely network-isolated by design**:
- No HTTP/socket access from Lua
- No arbitrary Java class loading (`java.net.*` is not exposed)
- Only whitelisted game-engine classes are available
- File I/O is sandboxed to `~/Zomboid/Lua/` via `getFileWriter`/`getFileReader`

This means **there is no way to call an API from inside the mod**. External communication must go through the filesystem.

### IPC Flow

```
PZ Game (Lua)                           Python Sidecar
    |                                        |
    |-- writes auto_pilot_state.json ------->|
    |   (every ~10s: health, moodles,        |
    |    zombies, inventory, wounds)          |
    |                                        |-- calls Claude API
    |                                        |
    |<-- reads auto_pilot_cmd.json ----------|
    |   (action: eat/drink/sleep/exercise/   |
    |    fight/flee/bandage/rest/idle)        |
    |                                        |
    |-- applies command on next idle tick    |
```

### Future Options Explored

| Approach | Feasibility | Notes |
|----------|-------------|-------|
| HTTP from Lua | Impossible | Kahlua sandbox blocks all network access |
| Java bridge to `HttpURLConnection` | Impossible | Only whitelisted game classes exposed |
| Sidecar as `.exe` (PyInstaller) | Viable | Bundle sidecar as single executable, no Python install needed |
| Auto-launch sidecar with PZ | Viable | Batch script or Steam launch options to start both |
| Embedded rule engine improvements | Current focus | Make the Lua brain smart enough that AI is optional |

The pragmatic path: keep improving the rule-based system (Phases 2-4) so the mod is fully autonomous, while keeping the sidecar as an optional power-user feature. Packaging the sidecar as a standalone `.exe` is the most likely next step for AI integration UX.

---

## Key Technical Notes

- **PZ Build 42 API:** Uses direct Stats getters (`getHunger()`, `getThirst()`, etc.), NOT the old CharacterStat enum
- **Body part methods:** `bleeding()`, `scratched()`, `deepWounded()`, `bitten()`, `bandaged()` — NOT `isBleeding()` etc.
- **Water API:** `object:hasFluid()`, `ISTakeWaterAction:new(player, item_or_nil, waterObj, tainted)`
- **No STR/FIT skill books** exist in PZ — only trade skills have skill books
- **Exercise XP multipliers:** dumbbellpress/bicepscurl = 1.8x, barbellcurl = 1.2x, bodyweight = 1.0x
- **All PZ API calls wrapped in pcall** to prevent mod crashes on minor B42 version changes

## File Structure

```
auto_pilot/
  42/
    media/lua/client/
      AutoPilot_Main.lua
      AutoPilot_Needs.lua
      AutoPilot_Threat.lua
      AutoPilot_Inventory.lua
      AutoPilot_Medical.lua
      AutoPilot_LLM.lua
    mod.info
    poster.png
  schemas/
    cmd.schema.json
    state.schema.json
  tests/
    test_sidecar.py
  auto_pilot_sidecar.py
  .luacheckrc
  check.sh
  deploy.sh
  requirements.txt
  requirements-dev.txt
```
