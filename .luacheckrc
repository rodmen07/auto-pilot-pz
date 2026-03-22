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
    "ISTimedActionQueue",
    "ISEatFoodAction",
    "ISWalkToTimedAction",
    "ISGetOnBedAction",
    "ISEquipWeaponAction",
    "ISFitnessAction",
    "ISApplyBandage",
    "ISDisinfect",
    "ISReadABook",
    "ISTakeWaterAction",
    "ISInventoryTransferAction",

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
    "AutoPilot_LLM",
    "AutoPilot_Medical",
    "AutoPilot_Actions",
    "AutoPilot_Home",
    "AutoPilot_Map",

    -- PZ B42 engine global for persistent mod storage
    "ModData",

    -- PZ B42 pathfinding / action globals
    "ISPathFindAction",
    "ISRestAction",
    "AdjacentFreeTileFinder",
    "ISSitOnGround",
}

-- 211: unused local variable  — common in PZ boilerplate (loop indices, etc.)
-- 212: unused argument        — tolerate when mirroring PZ callback signatures
ignore = { "211", "212" }
