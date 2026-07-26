-- AutoPilot_Comfort.lua
-- Physical-comfort upkeep.  First arm: drying off with a towel (the Wet moodle).
--
-- WHY THIS EXISTS.  The user's 2026-07-24 in-game report ("negative moodles /
-- status effects accumulate over long autopilot runs, vitals healthy") listed
-- COVERAGE as its first root cause: "the mod reads only 3 MoodleTypes (Unhappy,
-- ENDURANCE, PAIN) and never references Stress, Sadness/Depression, Heavy Load,
-- Uncomfortable, Wet, Sick, so those accumulate unmanaged."  Wet is the one of
-- that list whose relief the engine actually exposes to Lua as a queueable
-- timed action, so it is the one this slice takes.
--
-- Verified before writing this file (whole-mod grep over 42/media/lua/client
-- and tests/ for "wetness|towel|dishcloth|drymyself|isWet"): the ONLY hit
-- anywhere was tests/test_engine_symbols.lua using CharacterStat.WETNESS as its
-- example of a stat the mock deliberately does NOT model.  So the mod had no
-- wetness surface at all: a character soaked by rain stayed soaked until the
-- engine dried it passively, while carrying a bath towel that would have
-- cleared it outright.
--
-- THE RELIEF IS REAL, NOT ASSUMED, and it is the engine's own action.  Read
-- live from the 42.19 install:
--
--   * shared/TimedActions/ISDryMyself.lua is a normal ISBaseTimedAction.
--       :new(character, item)                                      (line 112)
--       :isValid()  -> the item is still carried, has uses left, and
--                      getStats():get(CharacterStat.WETNESS) > 0   (lines 5-15)
--       :update()   -> decreaseBodyWetness(WETNESS / 20) per tick and consumes
--                      the cloth                                   (lines 17-38)
--       :complete() -> decreaseBodyWetness(WETNESS), i.e. a full clear, then
--                      sendDamage(character)                       (lines 58-68)
--     It is a FINITE action (getDuration is derived from the cloth's remaining
--     uses, line 104), so this arm can never park the character the way a
--     terminal branch can -- the same design constraint PR #82 recorded.
--
--   * The cloth is a towel: client/ISUI/ISInventoryPaneContextMenu.lua:190 is
--     the engine's own gate --
--       (testItem:getType() == "DishCloth" or testItem:getType() == "BathTowel")
--       and playerObj:getStats():get(CharacterStat.WETNESS) > 0
--     -> tests.canBeDry, consumed at line 884, which calls dryMyself (line
--     2758): transferIfNeeded(playerObj, item) FIRST, then
--     ISTimedActionQueue.add(ISDryMyself:new(playerObj, item)).  This module
--     mirrors that order with the mod's own V4.9 transfer-then-use helper.
--
-- THE SCALE IS THE PART THAT KILLS ARMS HERE, so it is settled at source.
-- CharacterStat.WETNESS is a 0-100 stat, not 0-1:
-- client/DebugUIs/DebugMenu/General/ISStatsAndBody.lua:75 registers it as
-- addSliderOptionEnum(CharacterStat.WETNESS, 1) -- an EXPLICIT step of 1, the
-- same as PAIN (:53), PANIC (:55), BOREDOM (:65), UNHAPPINESS (:69),
-- DISCOMFORT (:73), ZOMBIE_INFECTION (:86), ZOMBIE_FEVER (:88) and
-- FOOD_SICKNESS (:90) -- whereas the genuinely 0.0-1.0 stats (STRESS :59,
-- SANITY :71, SICKNESS :84, MORALE :57, ANGER :51) take the DEFAULT step of
-- 0.01 from addSliderOptionEnum's definition at :153-164.  So wetness is
-- divided by 100 here exactly as AutoPilot_Threat already divides PAIN and
-- PANIC, and the tunable is expressed as a 0-1 fraction.  Getting this wrong in
-- either direction produces an arm that is either dead (threshold unreachable)
-- or permanently on (every 1% of damp reads as soaked) -- the failure mode that
-- kept the unhappy arm dead through PRs #68, #77 and #78.
--
-- HONEST LIMITS, recorded here rather than discovered later:
--   * Drying while still standing outside in the rain is pointless -- the
--     engine re-wets the character as fast as the towel dries them -- so the
--     arm refuses in that state and lets the existing shelter step (which
--     already fires on rain, AutoPilot_Needs.check) move indoors first.
--   * A towel is consumed.  The arm therefore prefers the cloth with the MOST
--     uses left: ISDryMyself:update force-stops when the cloth runs out, so a
--     nearly-spent towel gives a partial dry and wastes the trip.
--   * The Wet MOODLE itself is not read.  MoodleType has no attested WET
--     member: a whole-install grep of media/lua for "MoodleType%.[A-Za-z_]+"
--     returns FOOD_EATEN, PAIN, PANIC, ENDURANCE, DRUNK, UNHAPPY, TIRED,
--     STRESS, HYPOTHERMIA, HYPERTHERMIA and HEAVY_LOAD, and no WET.  Under this
--     mod's verified-surface rule an unattested enum member must not be read,
--     so the arm gates on the STAT, which is attested and is what the engine's
--     own towel menu gates on too.
--
-- This module is the seam for the rest of that coverage list (Uncomfortable /
-- DISCOMFORT, Heavy Load) so those arms do not have to grow AutoPilot_Needs or
-- the already-oversized AutoPilot_Inventory.

local function _apNoop(...) end
local print = _apNoop

AutoPilot_Comfort = {}

-- The engine's two drying cloths, ISInventoryPaneContextMenu.lua:190.
local DRY_CLOTH_TYPES = {
    BathTowel = true,
    DishCloth = true,
}

-- Constants are read at CALL time, never at load time.  PZ loads this mod's
-- client files in filename order and "AutoPilot_Comfort" sorts BEFORE
-- "AutoPilot_Constants", so a file-scope read would capture nil.  (Reading them
-- live also means an options change takes effect without a reload, which is how
-- the rest of the mod behaves.)
local function _dryThreshold()
    local v = tonumber(AutoPilot_Constants and AutoPilot_Constants.WETNESS_DRY_THRESHOLD)
    if not v then return 0.30 end
    return v
end

--- Wetness as a 0-1 fraction.  See the scale note in the file header: the
--- engine stat is 0-100.
--- @return number  0.0 (dry) .. 1.0 (soaked); 0 when the stat cannot be read.
function AutoPilot_Comfort.wetness(player)
    if not player then return 0 end
    local raw = AutoPilot_Utils.safeStat(player, CharacterStat.WETNESS)
    if type(raw) ~= "number" then return 0 end
    return raw / 100
end

--- True when the character is standing outside while it rains, i.e. drying now
--- would be undone immediately.
function AutoPilot_Comfort.isExposedToRain(player, raining)
    if not raining then return false end
    local okSq, sq = pcall(function() return player:getCurrentSquare() end)
    if not okSq or not sq then return false end
    local okOut, outside = pcall(function() return sq:isOutside() end)
    return okOut and outside == true
end

--- Best carried drying cloth: a BathTowel or DishCloth with uses remaining,
--- preferring the one with the MOST uses left (a nearly-spent cloth force-stops
--- part-way through, ISDryMyself:update).
--- @return item|nil, container|nil
function AutoPilot_Comfort.findDryingCloth(player)
    local best, bestCont, bestUses = nil, nil, 0

    AutoPilot_Utils.iteratePlayerItems(player, function(item, container)
        if not item then return false end

        local okType, itemType = pcall(function() return item:getType() end)
        if not okType or not DRY_CLOTH_TYPES[itemType] then return false end

        -- Uses left.  ISDryMyself:isValid requires > 0; a cloth that cannot
        -- report its uses is treated as spent rather than gambled on.
        local okUses, uses = pcall(function() return item:getCurrentUsesFloat() end)
        if not okUses or type(uses) ~= "number" or uses <= 0 then return false end

        if uses > bestUses then
            best, bestCont, bestUses = item, container, uses
        end
        return false  -- scan every container; this is a max, not a first match
    end)

    return best, bestCont
end

--- Dry the character off when they are wet enough to be worth a towel.
---
--- Queue-only: it queues a finite engine action and returns, so it can never
--- hold the cycle open.
---
--- @param player   IsoPlayer
--- @param raining  boolean  the caller's weather reading (AutoPilot_Needs owns
---                          the climate-manager probe; passing it in keeps this
---                          module free of a second unverified engine surface)
--- @return boolean queued, string state
---   false,"dry"       below the threshold, nothing to do
---   false,"exposed"   soaked but standing outside in the rain
---   false,"no_cloth"  soaked but carrying no usable towel
---   false,"blocked"   the cloth could not be moved into the main inventory
---   true, "drying"    ISDryMyself queued
function AutoPilot_Comfort.doDryOff(player, raining)
    if not player then return false, "dry" end

    local wet = AutoPilot_Comfort.wetness(player)
    if wet < _dryThreshold() then return false, "dry" end

    if AutoPilot_Comfort.isExposedToRain(player, raining) then
        print("[Comfort] Soaked but standing in the rain; sheltering comes first.")
        return false, "exposed"
    end

    local cloth, cont = AutoPilot_Comfort.findDryingCloth(player)
    if not cloth then
        print("[Comfort] Wet, but no towel or dishcloth carried.")
        return false, "no_cloth"
    end

    -- V4.9 transfer-then-use: ISDryMyself:isValid checks the item is in the
    -- character's inventory, and the engine's own menu path calls
    -- transferIfNeeded before queueing for exactly this reason.
    local _, usable = AutoPilot_Utils.queueItemToMainInventory(player, cloth, cont)
    if not usable then
        print("[Comfort] Towel transfer refused; not drying this cycle.")
        return false, "blocked"
    end

    print(string.format("[Comfort] Wet (%.0f%%) — drying off with %s.",
        wet * 100, tostring(cloth.getName and cloth:getName() or "a cloth")))
    AutoPilot_Utils.queueModAction(ISDryMyself:new(player, cloth))
    return true, "drying"
end
