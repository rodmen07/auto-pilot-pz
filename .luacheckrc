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
    "ISTakeWaterAction",
    "ISInventoryTransferAction",
    "ISWearClothing",
    "ISBarricadeAction",
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
    "AutoPilot_Threat",
    "AutoPilot_Inventory",
    "AutoPilot_Medical",
    "AutoPilot_Home",
    "AutoPilot_Map",
    "AutoPilot_Barricade",
    "AutoPilot_Telemetry",

    -- V3.x auto-leveler modules
    "AutoPilot_XP",
    "AutoPilot_Leveler",
    "AutoPilot_UI",
    "AutoPilot_DeathLog",
    "AutoPilot_Adaptive",
    "AutoPilot_Options",

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
    "ISSitOnGround",

    -- PZ B42 climate/weather globals
    "isRaining",
    "getClimateManager",
}

-- 211: unused local variable  — common in PZ boilerplate (loop indices, etc.)
-- 212: unused argument        — tolerate when mirroring PZ callback signatures
ignore = { "211", "212" }
