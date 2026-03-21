# AutoPilot — Project Zomboid Build 42 Mod

AFK auto-leveler for Strength and Fitness. Keeps your character alive through automated survival (eating, drinking, sleeping, wound treatment) while exercising to max both stats.

Press **F7** in-game to toggle on/off.

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
pip install anthropic
set ANTHROPIC_API_KEY=sk-ant-...
python auto_pilot_sidecar.py
```

**Note:** PZ's Lua is completely sandboxed (no HTTP, no sockets). File-based IPC is the only mechanism for external communication — the sidecar polls `auto_pilot_state.json` and writes `auto_pilot_cmd.json`.

---

## Development Roadmap

### Phase 1: Don't Die (Survive Indefinitely) — COMPLETE

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

### Phase 2: Level Faster (Exercise Optimization) — NOT STARTED

Maximize XP gain per in-game day.

| Task | Status | Details |
|------|--------|---------|
| Use exercise equipment | Pending | Dumbbells (1.8x XP) and barbells (1.2x XP) vs bodyweight (1.0x) |
| Endurance-aware scheduling | Pending | Variable set duration based on current endurance; rest between sets |
| Daily set tracking | Pending | Track diminishing returns per day; reset at midnight |
| Loot exercise equipment | Pending | Prioritize `Base.DumbBell` and `Base.BarBell` in container scanning |
| STR/FIT decay prevention | Pending | Ensure consistent exercise cadence to prevent XP timer decay |

### Phase 3: Sustained Survival (Weeks/Months) — NOT STARTED

Handle resource depletion for long-term play.

| Task | Status | Details |
|------|--------|---------|
| Extended foraging | Pending | Supply runs beyond 8-tile radius when containers empty |
| Home base tracking | Pending | Record safe position, return after supply runs |
| Visited building tracking | Pending | Avoid re-looting empty buildings |
| Bulk looting | Pending | Transfer all useful items per trip (food, water, medical, equipment) |
| Unhappiness management | Pending | Eat tasty food, read magazines for happiness |
| Weight management | Pending | Calorie-aware food selection based on player weight |

### Phase 4: Polish — NOT STARTED

Edge cases and minor optimizations.

| Task | Status | Details |
|------|--------|---------|
| Weapon durability tracking | Pending | Check condition before combat, swap to backup |
| Temperature/clothing | Pending | Equip warmer/cooler clothing by season |
| Safehouse barricading | Pending | One-time window/door barricading at home base |

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
