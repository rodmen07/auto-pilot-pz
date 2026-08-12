-- AutoPilot_Mood.lua
-- Boredom / unhappiness relief: the mood arm of the needs chain.
--
-- WHY THIS FILE EXISTS.  Code-health split, 2026-08-01, fifth slice of the
-- AutoPilot_Needs decomposition (after AutoPilot_Consumption #54,
-- AutoPilot_Sleep #55, AutoPilot_Rest #59 and AutoPilot_Exercise #61).  This
-- one is driven by CHURN, not by line count: AutoPilot_Needs.lua was 851 lines
-- -- comfortably under the 1000-line guard -- but appeared in 15 of the last 30
-- commits touching 42/media/lua/client (50 percent), which is the metric that
-- actually predicts whether two increments can run in parallel.  Reading the
-- hunks of the last twelve commits that touched it shows where the changes
-- cluster: doMoodRelief was edited by PR #78 (MoodleType.UNHAPPY), PR #80
-- (unhappiness-relief food), and PR #82 (television/radio arm); doRead by
-- PR #77 (the illiterate-trait gate).  That is the seam, so that is the cut.
--
-- WHAT MOVED, VERBATIM.  doGoOutside, doRead and doMoodRelief, byte-for-byte
-- from AutoPilot_Needs.lua, with only the module-table name in front of
-- doMoodRelief changed so check() can still reach it.  doRead and doGoOutside
-- stay LOCAL: their only caller was, and still is, doMoodRelief, so widening
-- them into public API would invent a surface nothing asked for.
--
-- WHAT DID NOT MOVE, and why.  isRaining and doSeekShelter stayed behind:
-- check() itself calls both (the weather-shelter guard at step 2b and the
-- AutoPilot_Comfort dry-off arm at 6c), so they belong to the chain, not to
-- mood.  safeMoodleLevel is duplicated rather than moved because
-- AutoPilot_Needs still reads it twice (shouldInterrupt's exertion gate and
-- check()'s step 6) -- and duplication is already this repo's answer for that
-- helper: AutoPilot_Utils and AutoPilot_Exercise each carry their own local
-- copy for the same reason.  The shared activity string (_setActivity) is NOT
-- touched here: doMoodRelief never wrote it, it RETURNS a label and the caller
-- in check() writes it, which is exactly the V5.8 one-writer property.
--
-- BEHAVIOUR IS UNCHANGED.  Every symbol this file reads (AutoPilot_Constants,
-- AutoPilot_Home, AutoPilot_Inventory, AutoPilot_Media, AutoPilot_Telemetry,
-- AutoPilot_Utils, ISEatFoodAction, ISReadABook, ISWalkToTimedAction) is a
-- global resolved at CALL time, not at load time, so the file's position in
-- PZ's load order cannot matter.

local function _apNoop(...) end
local print = _apNoop

AutoPilot_Mood = {}

-- Same alias AutoPilot_Needs used to hold: the policy number lives in
-- AutoPilot_Constants, this is readability only.
local BOREDOM_STAT_THRESHOLD = AutoPilot_Constants.BOREDOM_THRESHOLD

-- Safe moodle level getter — returns 0 if the moodle type doesn't exist or isn't active.
-- B42 stores moodles in a Map; missing entries cause a Java NPE, so we pcall.
local function safeMoodleLevel(player, moodleType)
    if not moodleType then return 0 end
    local ok, level = pcall(function()
        return player:getMoodles():getMoodleLevel(moodleType)
    end)
    if ok and type(level) == "number" then
        return level
    end
    return 0
end

-- Walk to the nearest outdoor square to relieve boredom.
local function doGoOutside(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local cell = getCell()
    if not cell then return false end
    local curSq = cell:getGridSquare(px, py, pz)
    if curSq and curSq:isOutside() then
        print("[Needs] Already outside — boredom will decrease naturally.")
        return false
    end

    print("[Needs] Bored — finding outdoor square.")

    -- Home set: only search within home bounds
    if AutoPilot_Home.isSet(player) then
        local outsideSq = AutoPilot_Home.getNearestInside(player, function(sq)
            return sq:isOutside() and sq:isFree(false)
        end)
        if outsideSq then
            AutoPilot_Utils.prepareWalk("go outside")
            AutoPilot_Utils.queueModAction(ISWalkToTimedAction:new(player, outsideSq))
            return true
        end
        print("[Needs] No outdoor square found inside home bounds — skipping.")
        return false
    end

    -- No home set: skip outdoor walk for safety (containment guard)
    print("[Needs] No home set — skipping outdoor walk.")
    return false
end

-- ── Reading (boredom/unhappiness relief) ────────────────────────────────────

-- seatedOnly=true means the character is currently sitting out a rest hold, so
-- the walking fallback (loot a book from a nearby container) is skipped: it
-- would stand the character up and end the rest this call is trying to keep.
local function doRead(player, seatedOnly)
    -- Literacy gate.  The old implementation asked for a Perks.Literacy SKILL
    -- level, which does not exist in 42.19: a whole-install grep of
    -- media/lua for "Literacy" returns ZERO hits, so `Perks.Literacy` was
    -- always nil, `getPerkLevel(nil)` never produced a positive number, and
    -- doRead returned false on EVERY call.  The read arm of boredom relief has
    -- therefore never fired in-game.  (tests/lua_mock_pz.lua already recorded
    -- both halves of this — Perks.Literacy "intentionally ABSENT" and
    -- ISReadABook "unexercised: doRead's literacy gate fails in the suites" —
    -- but as a test-surface note, never as a production defect.)
    --
    -- The engine's real gate is the ILLITERATE TRAIT, not a perk:
    --   playerObj:hasTrait(CharacterTrait.ILLITERATE)
    -- verified live in the 42.19 install at
    -- client/ISUI/ISInventoryPaneContextMenu.lua:549 (and nine sibling
    -- callsites, e.g. ISInventoryPane.lua:1102).  Mirror that.
    --
    -- Fails OPEN (assume literate) when the trait cannot be read: the engine's
    -- own ISReadABook:isValid does not check literacy at all, so a wrong
    -- "literate" only costs a book with no benefit, while a wrong "illiterate"
    -- silently disables the entire relief path — which is the bug being fixed.
    local traitOk, illiterate = pcall(function()
        return player:hasTrait(CharacterTrait.ILLITERATE)
    end)
    if traitOk and illiterate then
        print("[Needs] Cannot read: character has the Illiterate trait.")
        return false
    end
    if not traitOk then
        print("[Needs] Illiterate-trait check failed (" .. tostring(illiterate)
            .. "); assuming literate.")
    end

    local book, bookCont = AutoPilot_Inventory.getReadable(player)
    if not book then
        if seatedOnly then
            -- Seated: looting walks to a container, which would break the sit.
            print("[Needs] No readable carried and seated — not looting mid-rest.")
            return false
        end
        -- No readable in inventory — try looting one from nearby containers
        return AutoPilot_Inventory.lootNearbyReadable(player)
    end

    -- Check if too dark to read
    local darkOk, tooDark = pcall(function() return player:tooDarkToRead() end)
    if darkOk and tooDark then
        print("[Needs] Too dark to read.")
        return false
    end

    print("[Needs] Reading: " .. tostring(book:getName()))
    -- V4.9: a book in a bag must reach the main inventory before ISReadABook.
    local _, usable = AutoPilot_Utils.queueItemToMainInventory(player, book, bookCont)
    if not usable then
        print("[Needs] Book transfer refused: not reading this cycle.")
        return false
    end
    local readOk, _ = pcall(function()
        AutoPilot_Utils.queueModAction(ISReadABook:new(player, book))
    end)
    return readOk
end

-- ── Mood relief (boredom / unhappiness) ─────────────────────────────────────
--
-- Extracted verbatim from check() step 7 so the SAME relief can also run while
-- a rest hold is in progress (step 6b).  That is where the mod spent most of
-- its idle time: the hold returns true without queueing anything, so every
-- cycle stopped ABOVE step 7 and boredom/unhappiness built up untouched while
-- the character sat recovering endurance — the user-reported "negative moodles
-- accumulate over long autopilot runs" with vitals staying healthy.
--
-- seatedOnly=true restricts relief to what a SEATED character can do without
-- standing up.  Eating and reading qualify, and that is the engine's own
-- position, not an assumption: ISRestAction:update carries the comment
-- "Removed this as being an action, this way we can still passively regain
-- endurance and read at the same time"
-- (shared/TimedActions/ISRestAction.lua:44, verified live in the 42.19
-- install).  Walking outdoors and walking to a container to loot a book both
-- end the sit, so both are skipped in that mode.
--
-- Returns (true, label) when relief was queued, false otherwise.  The label is
-- the seated activity text; it is unused by step 7, which has its own HUD path.
function AutoPilot_Mood.doMoodRelief(player, seatedOnly)
    -- NOTE: CharacterStat.SANITY reads HIGH when healthy, so it must not be used
    -- as a "sadness" signal (it made this branch fire nearly every idle cycle).
    -- The unhappy moodle level is the correct low-mood source.
    --
    -- The constant is MoodleType.UNHAPPY, not MoodleType.Unhappy.  B42 renamed
    -- every MoodleType constant to SCREAMING_SNAKE_CASE; the engine's own gate
    -- reads getMoodleLevel(MoodleType.UNHAPPY) at
    -- shared/TimedActions/ISBaseTimedAction.lua:102, and a whole-install grep
    -- of media/lua for "MoodleType.Unhappy" returns zero.  The CamelCase name
    -- resolved to nil, so safeMoodleLevel degraded to 0 on every call and the
    -- unhappy arm of this function could never run in-game (only the
    -- translation KEYS, Moodles_Unhappy_lvl1..4, kept the old spelling).
    local boredom    = AutoPilot_Utils.safeStat(player, CharacterStat.BOREDOM)
    local unhappyLvl = safeMoodleLevel(player, MoodleType.UNHAPPY)
    local boredOrSad = boredom >= BOREDOM_STAT_THRESHOLD
        or unhappyLvl >= AutoPilot_Constants.HAPPINESS_LOW_THRESHOLD

    -- V6.3 C2-D4: stress is the THIRD trigger for this arm, and it unlocks the
    -- read path ONLY.  The mod has read CharacterStat.STRESS since V4
    -- (AutoPilot_Threat.NEGATIVE_STAT_CHECKS) and never acted on it, while the
    -- relief was sitting in the item layer the whole time: 301 vanilla entries
    -- carry a negative StressChange and 259 of them are literature consumed by
    -- ISReadABook, which doRead already queues.  So this needs no new module,
    -- no new engine action and no unverified getter -- only the trigger.
    --
    -- The moodle, not the stat, because it is what the player sees on screen
    -- and because the unhappy arm above already reads its band from the same
    -- getter (V6.2 C1 made the same choice for hunger/thirst).
    local stressLvl = safeMoodleLevel(player, MoodleType.STRESS)
    local stressed  = stressLvl >= AutoPilot_Constants.STRESS_MOODLE_THRESHOLD

    if not boredOrSad and not stressed then
        return false
    end

    -- Phase 3: when unhappy enough, prefer mood food before reading.
    -- This gate is HAPPINESS_FOOD_PRIORITY, not HAPPINESS_LOW_THRESHOLD: the
    -- threshold above decides whether relief runs AT ALL, this one decides
    -- whether relief is allowed to spend food on it.  The constant had been
    -- defined and documented since Phase 3 but read by nothing, so the two
    -- levels were silently the same knob; they default to the same value, so
    -- the default behaviour is unchanged and raising it now reserves food for
    -- the unhappier levels while reading still covers the milder ones.
    -- `boredOrSad and` is what confines V6.3 C2-D4 to the read arm.  It is a
    -- no-op at the shipped defaults (both levels are 2, so unhappyLvl below
    -- HAPPINESS_LOW_THRESHOLD is also below HAPPINESS_FOOD_PRIORITY), and it
    -- matters for a player who has LOWERED the food priority: without it, a
    -- stress-only cycle would start spending food that preferTastyFood ranks by
    -- getUnhappyChange -- a happiness ranking, not a stress one, which is the
    -- kind of unevidenced spend D5 deferred.
    if boredOrSad and unhappyLvl >= AutoPilot_Constants.HAPPINESS_FOOD_PRIORITY then
        local tastyFood, tastyCont = AutoPilot_Inventory.preferTastyFood(player)
        if tastyFood then
            AutoPilot_Telemetry.setDecision("eat", "unhappy")
            print("[Needs] Unhappy — eating tasty food: "
                .. tostring(tastyFood:getName()))
            -- V4.9: transfer out of a bag first, then eat.
            local _, usable = AutoPilot_Utils.queueItemToMainInventory(
                player, tastyFood, tastyCont)
            if usable then
                AutoPilot_Utils.queueModAction(ISEatFoodAction:new(player, tastyFood, 1))
                return true, "eating"
            end
            print("[Needs] Tasty-food transfer refused: falling through to reading.")
        end
    end

    -- Telemetry honesty, the same rule V6.2 C1 set for the *_moodle reasons:
    -- "stress" is recorded ONLY when the stress arm is what fired and the
    -- boredom/unhappy arms alone would not have.  A stressed AND bored cycle
    -- still reads "boredom", so no existing log line changes meaning.
    --
    -- Written as two literal calls rather than one
    -- `setDecision("read", boredOrSad and "boredom" or "stress")`, and that is
    -- not a style preference: tests/test_reason_line.lua discovers the reason
    -- VOCABULARY by scanning production sources for the literal shape
    -- `setDecision("<action>", "<reason>")`, so the ternary form emits a token
    -- no drift guard can see -- which is exactly how a reason token ends up
    -- with no F11 label and nothing failing.  The ternary was written first
    -- here and that suite caught it.
    if boredOrSad then
        AutoPilot_Telemetry.setDecision("read", "boredom")
    else
        AutoPilot_Telemetry.setDecision("read", "stress")
    end
    if doRead(player, seatedOnly) then return true, "reading" end

    if not boredOrSad then
        -- Stress-only cycle: reading is the whole arm, and that is a claim about
        -- EVIDENCE, not a shortcut.  Going outdoors is gated on boredom below
        -- and relieves boredom, not stress.  A television or radio CAN carry a
        -- stress operation, but only when the broadcast script happens to
        -- contain one (Interactions.STS, shared/RadioCom/ISRadioInteractions.lua:99)
        -- -- it is a property of what is being aired, not of the device -- so
        -- walking a stressed character to a set is not a relief the mod can
        -- promise.  Fall through to the rest of the chain instead.
        return false
    end

    if seatedOnly then
        -- Going outside walks; it is not available to a seated character.
        -- Neither is media relief: switching a television on means standing up
        -- and walking to within the engine's own 1.5-tile interaction distance
        -- (server/ISObjectClickHandler.lua:241), which ends the sit.
        return false
    end

    -- Media relief: a television or radio, the third arm.  Placed after reading
    -- because a carried book needs no walk at all, and before going outdoors
    -- because indoors is safer and because walking outdoors FORFEITS media
    -- relief outright (ISRadioInteractions.checkPlayer returns early when the
    -- device square and the player square disagree on isOutside()).
    local mediaQueued, mediaState = AutoPilot_Media.doMediaRelief(player)
    if mediaQueued then return true, mediaState end

    if boredom >= BOREDOM_STAT_THRESHOLD then
        if mediaState == "tuned" then
            -- A device is already playing within range: relief is accruing
            -- where the character stands.  Queue nothing and let the chain fall
            -- through to lower needs, rather than walking out of the broadcast
            -- box to relieve the same moodle less safely.
            print("[Needs] A device is playing in range; not walking outdoors.")
            return false
        end
        AutoPilot_Telemetry.setDecision("outside", "boredom")
        if doGoOutside(player) then return true, "outside" end
    end
    return false
end
