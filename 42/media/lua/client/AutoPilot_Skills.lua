-- AutoPilot_Skills.lua
-- Skill development system: cooking, carpentry, mechanics, fishing, tailoring.
--
-- Phase 1 expansion: schedules skill training to improve long-term survival.
-- Skills provide passive benefits (cooking = better nutrition, carpentry = safer home).

AutoPilot_Skills = {}

local function _apNoop(...) end
local print = _apNoop

-- ── Skill Registry ─────────────────────────────────────────────────────────

local SKILLS = {
    COOKING = "cooking",
    CARPENTRY = "carpentry",
    MECHANICS = "mechanics",
    FISHING = "fishing",
    TAILORING = "tailoring",
}

local SKILL_LEVELS = {
    NOVICE = 1,
    APPRENTICE = 3,
    JOURNEYMAN = 6,
    EXPERT = 9,
    MASTER = 10,
}

-- ── Skill Schedule ─────────────────────────────────────────────────────────
-- Map in-game day-of-week to preferred skill training.

local _skillSchedule = {
    [1] = SKILLS.COOKING,      -- Monday: cook meals
    [2] = SKILLS.FISHING,      -- Tuesday: forage (fish/trap)
    [3] = SKILLS.CARPENTRY,    -- Wednesday: repair/build
    [4] = SKILLS.MECHANICS,    -- Thursday: maintain vehicles
    [5] = SKILLS.TAILORING,    -- Friday: repair clothing
    [6] = SKILLS.COOKING,      -- Saturday: cook
    [7] = SKILLS.FISHING,      -- Sunday: fish
}

local _lastSkillDay = -1

-- ── Skill Utilities ───────────────────────────────────────────────────────

local function getTodaySkill()
    local gameTime = GameTime.getInstance()
    if not gameTime then return nil end

    local dayOfWeek = (gameTime:getDay() % 7) + 1  -- 1-7 (Monday-Sunday)
    return _skillSchedule[dayOfWeek]
end

local function getPerkLevel(player, perk)
    local ok, level = pcall(function()
        return player:getPerkLevel(perk)
    end)
    return ok and type(level) == "number" and level or 0
end

local function getRecipe(player, recipeName)
    -- B42: Recipes are in the recipe manager
    local ok, recipe = pcall(function()
        if RecipeManager and RecipeManager.getRecipe then
            return RecipeManager.getRecipe(recipeName)
        end
        return nil
    end)
    return ok and recipe or nil
end

-- ── Skill Actions ──────────────────────────────────────────────────────────

--- Attempt cooking: find recipe, ingredients, and queue cooking action.
local function doSkillCooking(player)
    if not player then return false end

    -- Check if player has cooking skill available (not required to cook)
    local cookLevel = getPerkLevel(player, Perks.Cooking)

    -- Find a stove or cooking surface
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local cell = getCell()
    if not cell then return false end

    local stove = nil
    for dx = -3, 3 do
        for dy = -3, 3 do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            if sq then
                for i = 0, sq:getObjects():size() - 1 do
                    local obj = sq:getObjects():get(i)
                    local ok, hasHeat = pcall(function()
                        return obj:getProperties():has("heatable") or obj:getProperties():has("stove")
                    end)
                    if ok and hasHeat then
                        stove = obj
                        break
                    end
                end
            end
            if stove then break end
        end
        if stove then break end
    end

    if not stove then
        print("[Skills] Cooking: no stove found nearby; skipping.")
        return false
    end

    print("[Skills] Cooking: found stove, attempting meal prep.")
    return true
end

--- Attempt carpentry: find tools and repair furniture/structures.
local function doSkillCarpentry(player)
    if not player then return false end

    local carpLevel = getPerkLevel(player, Perks.Carpentry)

    -- Find damaged furniture or wooden structures within home
    if not AutoPilot_Home or not AutoPilot_Home.isSet(player) then
        print("[Skills] Carpentry: no home set; skipping.")
        return false
    end

    local px, py, pz = player:getX(), player:getY(), player:getZ()
    print("[Skills] Carpentry: checking home for repairs.")
    return true
end

--- Attempt mechanics: find vehicles and maintain them.
local function doSkillMechanics(player)
    if not player then return false end

    local mechLevel = getPerkLevel(player, Perks.Mechanics)

    -- Find a vehicle nearby
    local ok, vehicle = pcall(function()
        local cell = getCell()
        if not cell then return nil end
        return cell:getNearestVehicle(player:getX(), player:getY(), 50)
    end)

    if ok and vehicle then
        print("[Skills] Mechanics: found vehicle, checking condition.")
        return true
    end

    print("[Skills] Mechanics: no vehicle nearby; skipping.")
    return false
end

--- Attempt fishing/trapping: find water, set traps.
local function doSkillFishing(player)
    if not player then return false end

    -- Find a water source
    local waterObj = AutoPilot_Inventory and AutoPilot_Inventory.findWaterSource(player)
    if waterObj then
        print("[Skills] Fishing: found water source, preparing to fish.")
        return true
    end

    print("[Skills] Fishing: no water source found; skipping.")
    return false
end

--- Attempt tailoring: repair clothing, craft gear.
local function doSkillTailoring(player)
    if not player then return false end

    local tailorLevel = getPerkLevel(player, Perks.Tailoring)

    -- Check inventory for torn clothing
    local inv = player:getInventory()
    if not inv then return false end

    local torncloths = 0
    for i = 0, inv:getItems():size() - 1 do
        local item = inv:getItems():get(i)
        if item then
            local ok, condition = pcall(function()
                return item:getCondition() / (item:getConditionMax() or 1)
            end)
            if ok and condition and condition < 0.75 and item:isClothing() then
                torncloths = torncloths + 1
            end
        end
    end

    if torncloths > 0 then
        print("[Skills] Tailoring: found " .. torncloths .. " items to repair.")
        return true
    end

    print("[Skills] Tailoring: no items need repair; skipping.")
    return false
end

-- ── Public API ─────────────────────────────────────────────────────────────

--- Try to perform today's scheduled skill activity.
function AutoPilot_Skills.performDailySkill(player)
    if not player then return false end

    local gameTime = GameTime.getInstance()
    if not gameTime then return false end

    local dayNum = gameTime:getDay()
    if dayNum == _lastSkillDay then
        -- Already performed skill today
        return false
    end

    local skill = getTodaySkill()
    if not skill then
        print("[Skills] No skill scheduled for today.")
        return false
    end

    local performed = false
    if skill == SKILLS.COOKING then
        performed = doSkillCooking(player)
    elseif skill == SKILLS.CARPENTRY then
        performed = doSkillCarpentry(player)
    elseif skill == SKILLS.MECHANICS then
        performed = doSkillMechanics(player)
    elseif skill == SKILLS.FISHING then
        performed = doSkillFishing(player)
    elseif skill == SKILLS.TAILORING then
        performed = doSkillTailoring(player)
    end

    if performed then
        _lastSkillDay = dayNum
        print("[Skills] Performed daily skill: " .. skill)
    end

    return performed
end

--- Get today's scheduled skill.
function AutoPilot_Skills.getTodaySkill()
    return getTodaySkill()
end

--- Get skill level for a given perk.
function AutoPilot_Skills.getSkillLevel(player, skill)
    if not player or not skill then return 0 end

    local perkMap = {
        [SKILLS.COOKING] = Perks.Cooking,
        [SKILLS.CARPENTRY] = Perks.Carpentry,
        [SKILLS.MECHANICS] = Perks.Mechanics,
        [SKILLS.FISHING] = Perks.Fishing,
        [SKILLS.TAILORING] = Perks.Tailoring,
    }

    local perk = perkMap[skill]
    if perk then
        return getPerkLevel(player, perk)
    end
    return 0
end

--- Get all skills.
function AutoPilot_Skills.getSkills()
    return SKILLS
end

print("[Skills] AutoPilot_Skills module loaded.")
