# AutoPilot V1.0+ Expansion Roadmap

**Goal:** Evolve from AFK survival bot to adaptive survival system with emergent gameplay.

---

## Phase 1: Core Expansion (V1.1–V1.3) — Foundation

### V1.1: Smarter Foraging
**New Module:** `AutoPilot_Foraging.lua`
- Item-type targeting (weapons, tools, ammo, medical, food by category)
- Location learning (zones marked as "good for X" after successful loots)
- Defensive looting (prioritize weapons when threat is near)
- Exhaustion memory (don't re-search zones for 4+ hours)
- Supply route optimization (shortest path to known good zones)

**Changes to existing:**
- `AutoPilot_Inventory.lua`: refactor loot predicates to use foraging system
- `AutoPilot_Map.lua`: extend depletion tracking to include zone quality scores
- `AutoPilot_Needs.lua`: delegate loot decisions to foraging system

**Integration points:**
- Threat detection triggers defensive foraging
- Supply runs use learned routes
- Player inventory composition informs next search targets

---

### V1.2: Extended Combat
**New Module:** `AutoPilot_Combat.lua` (extends Threat)
- Zombie type detection (runner vs. walker → different tactics)
- Trap placement (barricades at choke points, spike strips)
- Group tactics (if multiple zombies, fall back to defensible position)
- Weapon persistence (stick with good weapons, upgrade when found)
- Retreat paths (pre-plan escape routes from current location)

**Changes to existing:**
- `AutoPilot_Threat.lua`: delegate fight/flee to Combat module
- `AutoPilot_Inventory.lua`: track weapon "favorites" (best found so far)
- `AutoPilot_Home.lua`: mark defensible positions, choke points

**Integration points:**
- Combat decision tree: zombie type → tactic selection
- Weapon memory: prefer known good weapons
- Threat escalation: horde detected → abandon current task, go home

---

### V1.3: Advanced Skill Development
**New Module:** `AutoPilot_Skills.lua`
- Cooking (find recipes, prepare high-nutrition meals, reduce spoilage)
- Carpentry (repair furniture, reinforce structures, build safe rooms)
- Mechanics (maintain vehicles, fuel management, repair weapons)
- Fishing/Trapping (passive income while resting, learn best spots)
- Tailoring (repair/upgrade clothing, crafting)

**Changes to existing:**
- `AutoPilot_Needs.lua`: skill activities inserted into priority chain
- `AutoPilot_Inventory.lua`: track recipes, tools, resources
- `AutoPilot_Telemetry.lua`: log skill progress, resource gathering

**Integration points:**
- Daily skill rotation (cook on Mon, fish on Tue, etc.)
- Resource-dependent (only cook if ingredients available)
- Quality-of-life improvements (better nutrition, safer home, working vehicles)

---

### V1.4: Vehicle Integration
**New Module:** `AutoPilot_Vehicles.lua`
- Vehicle detection and registration (find, remember, maintain)
- Fuel management (find gas, top up before trips)
- Long-distance supply runs (explore 500+ tiles away, return home)
- Vehicle-as-base (sleep/cook in vehicle if home is compromised)
- Repair cycles (maintain engine, tires, fuel system)

**Changes to existing:**
- `AutoPilot_Explore.lua`: use vehicle for fast frontier expansion
- `AutoPilot_Inventory.lua`: fuel containers, spare parts management
- `AutoPilot_Home.lua`: alternate shelter (vehicle parking spot)

**Integration points:**
- Low fuel → trigger fuel search
- Threat near home → relocate to vehicle
- Supply runs 200+ tiles away → use vehicle

---

## Phase 2: Social & Infrastructure (V1.5–V1.7)

### V1.5: NPC Interactions
**New Module:** `AutoPilot_NPCs.lua`
- NPC detection and profiling (friendly, hostile, neutral)
- Reputation system (gain/lose trust through actions)
- Basic trading (exchange items at fair rates)
- Cooperative tasks (share resources, mutual defense)
- Memory (remember useful NPCs, their locations, inventory)

**Changes to existing:**
- `AutoPilot_Threat.lua`: treat friendly NPCs as allies, protect them
- `AutoPilot_Inventory.lua`: trading prices, valuation system
- `AutoPilot_Home.lua`: guest room, visitor management

**Integration points:**
- NPC nearby → offer trade or cooperation
- NPC under threat → assist (even if risky)
- Good reputation → better trade rates, tips on resources

---

### V1.6: Base Building
**New Module:** `AutoPilot_BaseBuilding.lua`
- Structure repair (identify and fix damaged walls, roofs, doors)
- Fortification (apply metal sheets, install bars, seal gaps)
- Expansion (annex adjacent buildings as supply grows)
- Crafting stations (workbench, kitchen counter, water tank upgrades)
- Territory defense (spike strips, barricades, cleared fire zones)

**Changes to existing:**
- `AutoPilot_Home.lua`: track structure integrity, expansion plan
- `AutoPilot_Inventory.lua`: construction materials tracking
- `AutoPilot_Skills.lua`: carpentry applies here

**Integration points:**
- Daily maintenance routine
- Resource abundance → expand base
- Threat escalation → improve defenses
- Long-term safety increases survival time

---

### V1.7: Data & Analytics
**New Module:** `AutoPilot_Analytics.lua`
- Survival statistics (days alive, kills, deaths, max health reached)
- Resource tracking (total food eaten, water drank, items looted)
- Performance metrics (efficiency: resources gathered per hour)
- Session replay (save log, browse decisions made during session)
- Telemetry dashboard (daily summary, trends, alerts)

**Changes to existing:**
- `AutoPilot_Telemetry.lua`: expand to full event logging
- All modules: emit analytics events on key actions
- `AutoPilot_Main.lua`: periodic snapshot writes

**Integration points:**
- Session playback for learning
- Identify inefficiencies (spent 2h at one location = bad)
- Recognize optimal strategies and repeat them

---

## Phase 3: Advanced Systems (V1.8–V2.0)

### V1.8: LLM Sidecar Enhancement
**Existing:** `AutoPilot_LLM.lua` (file-based IPC)
**New Features:**
- Tactical advice (Claude analyzes threat, recommends action)
- Dynamic strategy (change tactics based on observations)
- Failure analysis (why did we die? adjust strategy)
- Natural language decisions ("go to best nearby water source" → Claude finds it)
- Learning feedback (log decisions + outcomes for future reference)

**Changes to existing:**
- `AutoPilot_Main.lua`: query sidecar on high-risk decisions
- All modules: emit decision logs for sidecar analysis
- `AutoPilot_Threat.lua`: ask Claude for fight/flee advice in ambiguous cases

**Integration points:**
- Threat scenario → ask Claude for optimal response
- Dead end (stuck in bad location) → ask Claude for escape plan
- Luxury decisions (where to explore next) → ask Claude for advice

---

### V1.9: Economy System
**New Module:** `AutoPilot_Economy.lua`
- Money tracking (find cash, spend wisely)
- Trading posts (map of traders, their inventory, preferred items)
- Supply/demand (certain items are valuable now, others later)
- Investment (buy low, sell high; accumulate rare items)
- Factions (different trader groups, faction reputation affects prices)

**Changes to existing:**
- `AutoPilot_NPCs.lua`: integrate trading posts and faction system
- `AutoPilot_Inventory.lua`: valuation system based on market data
- `AutoPilot_Telemetry.lua`: log economic transactions

**Integration points:**
- Trade surplus → save cash or reinvest in upgrades
- Market shifts → buy items before they become scarce
- Faction reputation → access exclusive traders

---

### V2.0: Quest Framework
**New Module:** `AutoPilot_Quests.lua`
- Quest generation (random objectives: reach location, gather X items, survive N days)
- Progression system (quests unlock new areas, NPCs, rewards)
- Long-term goals (multi-stage quests: find X → deliver to Y → explore Z)
- Rewards (cash, rare items, skill books, NPC alliances)
- Narrative arcs (series of quests tell a story)

**Changes to existing:**
- `AutoPilot_Needs.lua`: quest tasks inserted as priorities when active
- `AutoPilot_NPCs.lua`: NPCs issue quests, track progress
- `AutoPilot_Main.lua`: quest UI/status display

**Integration points:**
- Quest acceptance → commit to objective (ignore normal priorities)
- Quest completion → get reward + progress story
- Failed quest → reputation penalty, retry available

---

## Implementation Strategy

### Development Approach
1. **V1.1–V1.4 (Tier 1):** Foundation features, low-risk, ~3–4 weeks
2. **V1.5–V1.7 (Tier 2):** Social systems, ~3 weeks
3. **V1.8–V2.0 (Tier 3):** Advanced, ~2 weeks (heavily dependent on prior work)

### Code Organization
```
42/media/lua/client/
├── Core (existing)
│   ├── AutoPilot_Main.lua
│   ├── AutoPilot_Needs.lua
│   ├── AutoPilot_Threat.lua
│   ├── AutoPilot_Inventory.lua
│   └── ...
├── Phase 1: Expansion (V1.1–V1.4)
│   ├── AutoPilot_Foraging.lua
│   ├── AutoPilot_Combat.lua
│   ├── AutoPilot_Skills.lua
│   └── AutoPilot_Vehicles.lua
├── Phase 2: Social (V1.5–V1.7)
│   ├── AutoPilot_NPCs.lua
│   ├── AutoPilot_BaseBuilding.lua
│   └── AutoPilot_Analytics.lua
└── Phase 3: Advanced (V1.8–V2.0)
    ├── AutoPilot_Economy.lua
    └── AutoPilot_Quests.lua
```

### Testing Strategy
- Unit tests for each new module
- Integration tests at version boundaries
- Playtesting: 24h+ runs to verify stability
- Performance profiling (frame rate, memory, CPU)

### Release Cadence
- **V1.1, V1.2, V1.3, V1.4:** Weekly (Tier 1 foundation)
- **V1.5, V1.6, V1.7:** Bi-weekly (Tier 2 complexity)
- **V1.8, V1.9, V2.0:** Monthly (Tier 3 polish & testing)

---

## Risk Assessment

| Feature | Risk | Mitigation |
|---------|------|-----------|
| Smarter Foraging | Medium | Fallback to dumb search if learning fails |
| Extended Combat | High | Extensive threat testing; safe defaults (flee) |
| Vehicle Integration | High | Graceful degradation (no vehicle = no boost) |
| NPC Interactions | Medium | Simple state machine; offline fallback |
| LLM Sidecar | Medium | File IPC is robust; timeout if no response |
| Economy | Low | Pure data, no gameplay impact if disabled |
| Quests | Low | Optional overlay; ignore if disabled |

---

## Success Metrics

- **Playtime:** Player can AFK for 1+ weeks and survive
- **Emergent Gameplay:** Visible differences in bot behavior (adapts to conditions)
- **Stability:** No crashes or infinite loops
- **Performance:** Steady 60 FPS on baseline hardware
- **Code Quality:** >90% luacheck pass rate, <5% cognitive complexity per function
- **Workshop Rating:** 4.5+ stars, 100+ favorites

