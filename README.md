# AutoPilot — Project Zomboid Build 42 Mod

AFK auto-leveler for Strength and Fitness. Keeps your character alive through automated survival (eating, drinking, sleeping, wound treatment) while exercising to max both stats.

> **Status:** All 4 feature phases complete (V1.0). Pending Steam Workshop upload (V1.0).
> See [WORKSHOP.md](WORKSHOP.md) for the Workshop description and [TESTING.md](TESTING.md) for the pre-release test checklist.

## Quick Start

1. Prerequisite: The mod is already installed at `~/Zomboid/mods/auto_pilot/`
2. Launch Project Zomboid, enable **AutoPilot** in the mod list
3. Load into a game and press **Ctrl+1** to start/stop autopilot
4. Press **H** once to set your home anchor
4. Watch the console (`ProjectZomboid64ShowConsole.bat`) for `[AutoPilot]` log messages

### Controls (local autonomous survivor)

- Ctrl+1: toggle autopilot on/off
- Ctrl+2: prompt override (asks for priority)
- Ctrl+3: select prompt priority 1 (survival)
- Ctrl+4: select prompt priority 2 (safety)
- Ctrl+5: select prompt priority 3 (comfort)
- Ctrl+6: select prompt priority 4 (training)
- Ctrl+7: select prompt priority 5 (status)

- H: set/reset home position while autopilot is active
- Ctrl+0: show/hide quick help overlay

The mod is fully autonomous and no external AI service is needed. Autopilot will return to normal behavior automatically 30 seconds after the prompt if no selection is made.

### Cloud Agent -> Local Game Sync (Windows)

If Copilot's cloud coding agent opens and merges a PR, those changes only exist in GitHub until you sync locally.

```bat
cd C:\Users\rodme\Zomboid\mods\auto_pilot
sync_after_merge.bat
```

What this does:

1. Fetches and fast-forwards your local `main` from `origin/main`
2. If your repo is not the same as the live game mod folder, deploys `42/` + `auto_pilot_sidecar.py` into `%USERPROFILE%\Zomboid\mods\auto_pilot`

Notes:

- Script aborts if your working tree has local uncommitted changes
- Optional branch argument: `sync_after_merge.bat main`
- Optional custom deploy target via env var:
  `set AUTO_PILOT_GAME_MOD_DIR=C:\path\to\Zomboid\mods\auto_pilot`

## Architecture

Six Lua modules in `42/media/lua/client/`:

| Module | Purpose |
|--------|---------|
| `AutoPilot_Main.lua` | Orchestrator — OnTick loop, F3 autopilot toggle, prompt dispatch || `AutoPilot_Needs.lua` | Priority-based survival state machine |
| `AutoPilot_Threat.lua` | Zombie detection, fight/flee logic |
| `AutoPilot_Inventory.lua` | Item scanning, water sources, auto-loot |
| `AutoPilot_Medical.lua` | Wound detection and auto-bandage |
| `AutoPilot_LLM.lua` | Minimal logger compatibility adapter (no sidecar IPC) |

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

### Phase 2: Level Faster (Exercise Optimization) — COMPLETE *(v0.1.2)*

Maximize XP gain per in-game day.

| Task | Status | Details |
|------|--------|---------|
| ✅ Exercise equipment preference (dumbbells 1.8x, barbells 1.2x XP) | Done | `AutoPilot_Inventory.equipBestExerciseItem` — scans home area, transfers best gear |
| ✅ Endurance-aware scheduling | Done | Phase 2 gate: skip exercise below 30% endurance; resume above threshold |
| ✅ Daily set tracking (cap: 20/day) | Done | `_exerciseSetsToday` resets on day rollover; hard cap at `EXERCISE_DAILY_CAP` |
| ✅ STR/FIT decay prevention | Done | `preferredExerciseType()` targets the lower perk to keep both stats progressing |

### Phase 3: Sustained Survival (Weeks/Months) — COMPLETE *(v0.1.3)*

Handle resource depletion for long-term play.

| Task | Status | Details |
|------|--------|---------|
| ✅ Extended foraging | Done | `supplyRunLoot()` expands radius to 200 tiles after 5 empty loot cycles; resets depletion cache |
| ✅ Home base tracking | Done | Home position established at enable time; supply runs ignore home bounds then return |
| ✅ Visited building tracking | Done | `AutoPilot_Map` tracks depleted squares (empty containers); skipped on next scan |
| ✅ Bulk looting | Done | `bulkLoot()` transfers all keyword-matched items per container; `bulk_loot` action added |
| ✅ Unhappiness management | Done | Prefers boredom-reducing food when Unhappy moodle fires; falls back to reading |
| ✅ Weight management | Done | `selectFoodByWeight()` scores food by calories vs. player weight (under/over thresholds) |

### Phase 4: Polish — COMPLETE *(v0.2.1)*

Edge cases and minor optimizations.

| Task | Status | Details |
|------|--------|---------|
| ✅ Weapon durability tracking | Done | `checkAndSwapWeapon()` — swaps to best inventory weapon when condition < 25% before combat |
| ✅ Temperature/clothing | Done | `adjustClothing()` — equips warm/cool gear based on body temperature delta |
| ✅ Safehouse barricading | Done | `AutoPilot_Barricade` — one-time window barricading on home set (ModData flag) |

### Phase 5: Deployment — IN PROGRESS *(v0.2.2 / V1.0 release milestone)*

Publish the mod for others to use. Completing this phase marks the **V1.0** public release.

| Task | Status | Details |
|------|--------|---------|
| Steam Workshop upload | 🔲 Pending | Publish via PZ's built-in Workshop uploader or `steamcmd` |
| Workshop description & tags | ✅ Done | `WORKSHOP.md` — full BB-code description ready to paste |
| Poster artwork | 🔲 Pending | Finalize `poster.png` for Workshop listing |
| In-game testing on fresh save | 🔲 Pending | Full end-to-end validation on clean install — see `TESTING.md` |
| Multiplayer compatibility check | ✅ Done | Security audit complete — client-only; no cross-player actions; safe for private servers |
| Version tagging | ✅ Done | Minor/patch releases use lowercase `v` (e.g. `v0.1`, `v0.1.2`); major releases use capital `V` (e.g. `V1.0`) |

---

## Local-Only Architecture

### Current State

The mod is now designed as a single local brain only:

- **Rule-based Lua brain** — `AutoPilot_Needs` checks survival needs, threat response, and exercise decisions entirely locally.
- **No sidecar required** — `auto_pilot_sidecar.py` support has been removed.

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
