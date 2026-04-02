-- AutoPilot Boot.lua
-- Entry point for the mod. Loads all submodules.

print("[AutoPilot] Boot.lua loading...")

local function safeRequire(name)
	local ok, res = pcall(require, name)
	if not ok then
		print("[AutoPilot] require failed: " .. tostring(name) .. " error: " .. tostring(res))
	else
		print("[AutoPilot] required: " .. tostring(name))
	end
	return ok, res
end

-- Load constants first
safeRequire("AutoPilot_Constants")
safeRequire("AutoPilot_Utils")

-- Load subsystems (order matters: dependencies first)
safeRequire("AutoPilot_LLM")
safeRequire("AutoPilot_Home")
safeRequire("AutoPilot_Map")
safeRequire("AutoPilot_Inventory")
safeRequire("AutoPilot_Medical")
safeRequire("AutoPilot_Needs")
safeRequire("AutoPilot_Threat")
safeRequire("AutoPilot_Barricade")
safeRequire("AutoPilot_Actions")

-- Load main module last (registers events)
safeRequire("AutoPilot_Main")
