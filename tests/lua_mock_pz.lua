-- tests/lua_mock_pz.lua
-- Mocks essential Project Zomboid Build 42 APIs for off-game Lua testing.
--
-- Load this file with dofile() before loading any AutoPilot module under test.
-- All globals declared here mirror the real PZ engine surface so that the
-- production Lua modules can be executed without launching the game client.

-- ── CharacterStat enum ────────────────────────────────────────────────────────
-- B42 replaced all direct stat getters with player:getStats():get(CharacterStat.X).
CharacterStat = {
    HUNGER    = "HUNGER",
    THIRST    = "THIRST",
    FATIGUE   = "FATIGUE",
    ENDURANCE = "ENDURANCE",
    PAIN      = "PAIN",
    BOREDOM   = "BOREDOM",
    SANITY    = "SANITY",
}

-- ── MoodleType enum ───────────────────────────────────────────────────────────
MoodleType = {
    ENDURANCE = "ENDURANCE",
    Unhappy   = "Unhappy",
}

-- ── BodyPartType ──────────────────────────────────────────────────────────────
BodyPartType = {
    MAX = "MAX",
    ToIndex = function(_) return 1 end,
}

-- ── Perks ─────────────────────────────────────────────────────────────────────
Perks = {
    Strength = "Strength",
    Fitness  = "Fitness",
}

-- ── IsoFlagType ───────────────────────────────────────────────────────────────
IsoFlagType = {
    bed = "bed",
}

-- ── Timed-action queue ────────────────────────────────────────────────────────
-- ISTimedActionQueue_calls is reset between test cases via reset().
ISTimedActionQueue_calls = {}

ISTimedActionQueue = {
    add = function(action)
        table.insert(ISTimedActionQueue_calls, action)
    end,
    addGetUpAndThen = function(_, action)
        table.insert(ISTimedActionQueue_calls, action)
    end,
    clear = function(_) end,
}

-- ── Timed-action constructors ─────────────────────────────────────────────────
ISEatFoodAction = {
    new = function(_, player, item, _count)
        return { type = "eat", item = item }
    end,
}

ISGetOnBedAction = {
    new = function(_, player, bedObj)
        return { type = "sleep", bedObj = bedObj }
    end,
}

ISSitOnGround = {
    new = function(_, player, obj)
        return { type = "rest", obj = obj }
    end,
}

ISWalkToTimedAction = {
    new = function(_, player, sq)
        return { type = "walk", sq = sq }
    end,
}

ISFitnessAction = {
    new = function(_, player, exType, _mins, _exeData, _exeDataType)
        return { type = "exercise", exType = exType }
    end,
}

ISReadABook = {
    new = function(_, player, book)
        return { type = "read", book = book }
    end,
}

ISApplyBandage = {
    new = function(_, player, bodyPart, bandage)
        return { type = "bandage", bodyPart = bodyPart, bandage = bandage }
    end,
}

ISPathFindAction = {
    pathToSitOnFurniture = function(_, player, furniture, _)
        -- Return a stub path action; callbacks are ignored in tests.
        local action = { type = "pathfind" }
        action.setOnComplete = function(self, ...) end
        action.setOnFail     = function(self, ...) end
        action.addAfter      = function(self, _) return nil end
        return action
    end,
}

ISRestAction = {
    new = function(_, player, target, _)
        return { type = "rest_furniture", target = target }
    end,
}

AdjacentFreeTileFinder = {
    Find = function(sq, player, _)
        return nil
    end,
}

-- ── AutoPilot_Telemetry stub ──────────────────────────────────────────────────
-- setDecision() and logTick() are no-ops in tests — telemetry side-effects are
-- irrelevant to priority logic correctness.
AutoPilot_Telemetry = {
    setDecision = function(_action, _reason) end,
    logTick     = function(_player, _action, _reason) end,
    onDeath     = function(_player) end,
    getRunTick  = function() return 0 end,
}


-- MockTime allows tests to advance the in-game clock so that timed cooldowns
-- (e.g. restCooldownMs, sleepCooldownMs) can be expired between test cases.
MockTime = {}

local _mockTimeMs = 0

function MockTime.set(ms)
    _mockTimeMs = ms
end

function MockTime.advance(ms)
    _mockTimeMs = _mockTimeMs + ms
end

-- NOTE: PZ's Java API spells this "getCalender" (not "getCalendar") — the
-- mock intentionally mirrors that spelling so production pcall paths resolve.
local _mockCalender = {
    getTimeInMillis = function(self) return _mockTimeMs end,
}

local _mockGameTimeInstance = {
    getCalender = function(self) return _mockCalender end,
    getDay      = function(self) return 1 end,
}

GameTime = {
    getInstance = function() return _mockGameTimeInstance end,
}

function getGameTime()
    return _mockGameTimeInstance
end

-- ── getCell ───────────────────────────────────────────────────────────────────
-- Returns a stub cell whose getGridSquare() always returns nil so that all
-- square-iteration helpers and bed-search loops exit cleanly without error.
local _mockCell = {
    getGridSquare = function(self, _x, _y, _z) return nil end,
}

function getCell()
    return _mockCell
end

-- ── FitnessExercises ──────────────────────────────────────────────────────────
FitnessExercises = {
    exercisesType = {
        pushups = { type = "pushups" },
        squats  = { type = "squats" },
        situp   = { type = "situp" },
        burpees = { type = "burpees" },
    },
}

-- ── MockPlayer builder ────────────────────────────────────────────────────────
-- Creates a lightweight mock IsoPlayer with configurable state.
--
-- Parameters (all optional):
--   cfg.stats    table  CharacterStat key → value (0.0–1.0)
--   cfg.moodles  table  MoodleType key → integer level
--   cfg.perks    table  Perks key → integer level
--   cfg.bleeding bool   true if a body part is actively bleeding
--
-- Example:
--   local p = MockPlayer.new({
--       stats   = { HUNGER = 0.30, THIRST = 0.05, ENDURANCE = 0.90 },
--       moodles = { ENDURANCE = 0, Unhappy = 0 },
--       bleeding = false,
--   })

MockPlayer = {}

function MockPlayer.new(cfg)
    cfg = cfg or {}
    local stats   = cfg.stats   or {}
    local moodles = cfg.moodles or {}
    local perks   = cfg.perks   or {}

    local statsObj = {
        get = function(self, key)
            return stats[key] or 0
        end,
    }

    local moodlesObj = {
        getMoodleLevel = function(self, moodleType)
            return moodles[moodleType] or 0
        end,
    }

    -- Single stub body part used by AutoPilot_Medical helpers.
    local bodyPart = {
        bleeding    = function(self) return cfg.bleeding    or false end,
        deepWounded = function(self) return cfg.deepWounded or false end,
        bitten      = function(self) return cfg.bitten      or false end,
        scratched   = function(self) return cfg.scratched   or false end,
        isBurnt     = function(self) return cfg.burnt       or false end,
        bandaged    = function(self) return false end,
    }

    local bodyPartsArr = { [0] = bodyPart }

    local bodyPartsCollection = {
        get  = function(self, i) return bodyPartsArr[i] end,
        size = function(self) return 1 end,
    }

    local bodyDamageObj = {
        getBodyParts = function(self)
            return bodyPartsCollection
        end,
    }

    local emptyItems = {
        size = function(self) return 0 end,
        get  = function(self, _i) return nil end,
    }

    local inv = {
        getItems = function(self) return emptyItems end,
    }

    local player = {
        getStats      = function(self) return statsObj end,
        getMoodles    = function(self) return moodlesObj end,
        getBodyDamage = function(self) return bodyDamageObj end,
        getInventory  = function(self) return inv end,
        getPerkLevel  = function(self, perk) return perks[perk] or 0 end,
        getPlayerNum  = function(self) return cfg.playerNum or 0 end,
        getX          = function(self) return 0 end,
        getY          = function(self) return 0 end,
        getZ          = function(self) return 0 end,
        getCurrentSquare = function(self) return nil end,
        getFitness    = function(self)
            return {
                init                = function(self) end,
                setCurrentExercise  = function(self, _t) end,
            }
        end,
        tooDarkToRead = function(self) return false end,
    }

    return player
end
