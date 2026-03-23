-- AutoPilot Boot.lua
-- Entry point for the mod. Loads all submodules.

print("[AutoPilot] Boot.lua loading...")

-- Load constants first
require "AutoPilot_Constants"
require "AutoPilot_Utils"

-- Load subsystems (order matters: dependencies first)
require "AutoPilot_LLM"
require "AutoPilot_Home"
require "AutoPilot_Map"
require "AutoPilot_Inventory"
require "AutoPilot_Medical"
require "AutoPilot_Needs"
require "AutoPilot_Threat"
require "AutoPilot_Barricade"
require "AutoPilot_Actions"

-- Load main module last (registers events)
require "AutoPilot_Main"
