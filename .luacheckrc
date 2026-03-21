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
    "getFileWriter",
    "getFileReader",

    -- Event system and keyboard input
    "Events",
    "Keyboard",

    -- Enum tables
    "MoodleType",
    "Perks",

    -- Timed-action queue and action constructors used by this mod
    "ISTimedActionQueue",
    "ISEatFoodAction",
    "ISWalkToTimedAction",
    "ISGetOnBedAction",
    "ISEquipWeaponAction",
    "ISFitnessAction",

    -- AutoPilot module tables (each defined in its own file, referenced across all)
    "AutoPilot",
    "AutoPilot_Needs",
    "AutoPilot_Threat",
    "AutoPilot_Inventory",
    "AutoPilot_LLM",
}

-- 211: unused local variable  — common in PZ boilerplate (loop indices, etc.)
-- 212: unused argument        — tolerate when mirroring PZ callback signatures
ignore = { "211", "212" }
