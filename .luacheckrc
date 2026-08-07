-- .luacheckrc — luacheck configuration for the AutoPilot PZ B42 mod.
--
-- Install (Windows):  scoop install luacheck
-- Install (other):    luarocks install luacheck
-- Run:                luacheck 42/media/lua/client/

std            = "lua51"   -- Project Zomboid embeds Lua 5.1
max_line_length = 120

-- Project Zomboid engine globals available to every client Lua file.
globals = {
    -- Core game accessors
    "getPlayer",
    "getSpecificPlayer",
    "getCell",
    "getGameTime",
    -- Game-speed INDEX accessors (0 paused, 1 normal, 2/3/4 fast-forward).
    -- Distinct from getGameTime():getMultiplier().  Verified against the 42.19
    -- install: the engine calls both bare at
    -- client/Vehicles/ISUI/ISVehicleDashboard.lua:503-504, and
    -- client/TimedActions/WalkToTimedAction.lua:7 gates isValid() on
    -- getGameSpeed() <= 2.
    "getGameSpeed",
    "setGameSpeed",
    "getFileWriter",
    "getFileReader",

    -- Event system and keyboard input
    "Events",
    "Keyboard",

    -- Enum tables
    "MoodleType",
    "Perks",
    "BodyPartType",
    "Fluid",
    "CharacterStat",
    -- Java-bound trait enum; CharacterTrait.ILLITERATE is the engine's real
    -- literacy gate (ISInventoryPaneContextMenu.lua:549).
    "CharacterTrait",
    "IsoFlagType",
    "IsoDirections",
    "ItemType",
    "ItemTag",

    -- Utility modules
    "luautils",
    "FitnessExercises",
    "GameTime",

    -- Timed-action queue and action constructors used by this mod
    -- (verified against the B42 install; ISGetOnBedAction and
    -- ISEnterVehicleAction do NOT exist in B42 and must stay removed)
    "ISTimedActionQueue",
    "ISEatFoodAction",
    "ISWalkToTimedAction",
    "ISEquipWeaponAction",
    "ISFitnessAction",
    "ISApplyBandage",
    "ISDisinfect",
    "ISReadABook",
    -- Device power/channel action for televisions and radios.  Real 42.19
    -- signature: ISRadioAction:new(mode, character, device, secondaryItem)
    -- (client/RadioCom/ISRadioAction.lua:173).
    "ISRadioAction",
    -- Towel/dishcloth drying action.  Real 42.19 signature:
    -- ISDryMyself:new(character, item)
    -- (shared/TimedActions/ISDryMyself.lua:112).
    "ISDryMyself",
    "ISTakeWaterAction",
    "ISInventoryTransferAction",
    "ISWearClothing",
    "ISWorldObjectContextMenu",

    -- PZ engine utility functions
    "instanceof",
    "isClient",
    "getPlayerCount",

    -- AutoPilot module tables (each defined in its own file, referenced across all)
    "AutoPilot",
    "AutoPilot_Constants",
    "AutoPilot_Utils",
    "AutoPilot_Needs",
    "AutoPilot_Consumption",
    "AutoPilot_Sleep",
    "AutoPilot_Rest",
    "AutoPilot_Exercise",
    "AutoPilot_Threat",
    "AutoPilot_Inventory",
    "AutoPilot_Medical",
    "AutoPilot_Media",
    "AutoPilot_Mood",
    "AutoPilot_Comfort",
    "AutoPilot_Home",
    "AutoPilot_Map",
    "AutoPilot_Telemetry",

    -- V3.x auto-leveler modules
    "AutoPilot_XP",
    "AutoPilot_Leveler",
    "AutoPilot_UI",
    "AutoPilot_DeathLog",
    "AutoPilot_Adaptive",
    "AutoPilot_Options",

    -- V4.2 session-history data layer (expansion candidate C5)
    "AutoPilot_SessionHistory",

    -- V3.3 engine globals (verified against 42.19)
    "PZAPI",

    -- V3.x engine globals (verified against 42.19)
    "PerkFactory",
    "getTimestampMs",
    "ISCollapsableWindow",
    "ISButton",
    "UIFont",

    -- PZ B42 engine global for persistent mod storage
    "ModData",

    -- PZ B42 pathfinding / action globals
    "ISPathFindAction",
    "ISRestAction",
    "AdjacentFreeTileFinder",
    "SeatingManager",
    "ISSitOnGround",

    -- PZ B42 climate/weather globals
    "isRaining",
    "getClimateManager",
}

-- 212: unused argument — tolerated when a function mirrors a PZ callback or
-- engine signature it does not read every parameter of.  Measured 2026-08-07:
-- 3 instances across the 24 shipped client files, every one a genuine
-- signature mirror, so this suppression still earns its place.
--
-- 211 (unused local VARIABLE) was ignored here too until 2026-08-07, on the
-- stated grounds that unused locals are "common in PZ boilerplate (loop
-- indices, etc.)".  Measurement falsified both halves of that:
--
--   * An unused LOOP variable is luacheck 213, not 211, so the justification
--     named a different check.  Running the pinned linter with `--enable 213`
--     over 42/media/lua/client/*.lua reports 0 warnings in 24 files: the
--     category this suppression was written for does not occur here at all.
--   * The suppression was hiding four real 211s, one of them a live hazard.
--     AutoPilot_Medical carried `local MEDICAL_LOOT_RADIUS =
--     AutoPilot_Constants.MEDICAL_LOOT_RADIUS`, a FILE-LOAD-TIME snapshot of a
--     constant AutoPilot_Adaptive MUTATES at runtime after bleed-out deaths.
--     Nothing read it -- the call site correctly reads the constant live -- but
--     anyone "tidying" that call site to use the local would have silently
--     frozen the adaptive widening, with no warning from lint or tests.  That
--     is the same dead-local class PR #49 had to find BY HAND, precisely
--     because this ignore had blinded the linter to it.
--
-- The two deliberate unused locals that remain (the noop `print` shadow in
-- AutoPilot_Main and AutoPilot_XP) are suppressed inline, at the one line each
-- applies to, so the check keeps judging every other local in those files.
--
-- tests/test_luacheck_unused_locals.py runs the pinned linter against THIS
-- config in both directions, so 211 cannot be re-suppressed silently.
ignore = { "212" }
