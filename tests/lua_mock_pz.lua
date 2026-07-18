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
-- 42.19 naming: Carpentry = Woodwork, First Aid = Doctor, Foraging =
-- PlantScavenging (verified against server/XpSystem/XPSystem_SkillBook.lua).
Perks = {
    Strength        = "Strength",
    Fitness         = "Fitness",
    Woodwork        = "Woodwork",
    Doctor          = "Doctor",
    Cooking         = "Cooking",
    Fishing         = "Fishing",
    Tailoring       = "Tailoring",
    Mechanics       = "Mechanics",
    PlantScavenging = "PlantScavenging",
    Carpentry       = "Carpentry",  -- legacy alias used by AutoPilot_Skills
}

-- ── IsoFlagType ───────────────────────────────────────────────────────────────
IsoFlagType = {
    bed = "bed",
}

-- ── Timed-action queue ────────────────────────────────────────────────────────
-- ISTimedActionQueue_calls is reset between test cases via reset().
-- Real 42.19 static surface (verified via shell against the LIVE install —
-- client/TimedActions/ISTimedActionQueue.lua): add, addAfter, addGetUpAndThen,
-- clear, hasAction, hasActionType, isPlayerDoingAction, getTimedActionQueue,
-- queueActions.  isAllDone does NOT exist and stays absent so production calls
-- to it fail loudly here, exactly as in-game.
ISTimedActionQueue_calls = {}

ISTimedActionQueue = {
    add = function(action)
        table.insert(ISTimedActionQueue_calls, action)
    end,
    addGetUpAndThen = function(_character, action)
        table.insert(ISTimedActionQueue_calls, action)
    end,
    clear = function(_) end,
    isPlayerDoingAction = function(_player) return false end,
    getTimedActionQueue = function(_player) return { queue = {} } end,
}

-- ── Timed-action constructors ─────────────────────────────────────────────────
ISEatFoodAction = {
    new = function(_, player, item, _count)
        return { type = "eat", item = item }
    end,
}

-- ISGetOnBedAction does NOT exist in B42 — it is intentionally absent here.
-- B42 sleeps through ISWorldObjectContextMenu.onSleepWalkToComplete(playerIndex, bed),
-- which takes the 0-based player index (NOT the player object).
ISWorldObjectContextMenu = {
    onSleepWalkToComplete = function(playerIndex, bed)
        assert(type(playerIndex) == "number",
            "onSleepWalkToComplete expects a numeric player index, got "
            .. type(playerIndex))
        table.insert(ISTimedActionQueue_calls, { type = "sleep", bed = bed })
    end,
}

ISSitOnGround = {
    new = function(_, player, obj)
        return { type = "rest", obj = obj }
    end,
}

ISWalkToTimedAction = {
    new = function(_, player, sq)
        return {
            type = "walk",
            sq = sq,
            -- Real walk actions support completion callbacks (used by the
            -- walk-to-bed-then-sleep path).
            setOnComplete = function(self, fn, ...)
                self.onComplete = { fn = fn, args = { ... } }
            end,
            addAfter = function(self, _action) end,
        }
    end,
}

-- Real 42.19 signature (shared/TimedActions/ISFitnessAction.lua:200, verified
-- against the RUNNING game's stack trace after a phantom-file mixup):
--   new(character, exercise, timeToExe, exeData, exeDataType)
-- Line 217 feeds exeDataType into the String-typed Java call
-- fitness:setCurrentExercise(exeDataType), so the mock enforces table-4th /
-- string-5th — wrong slots fail loudly here, exactly as in-game.
ISFitnessAction = {
    new = function(_, player, exercise, timeToExe, exeData, exeDataType)
        assert(type(timeToExe) == "number",
            "ISFitnessAction:new expects numeric timeToExe as 3rd arg")
        assert(type(exeData) == "table",
            "ISFitnessAction:new expects exeData table as 4th arg (got "
            .. type(exeData) .. ")")
        assert(type(exeDataType) == "string",
            "ISFitnessAction:new expects exeDataType STRING as 5th arg (got "
            .. type(exeDataType) .. ")")
        player:getFitness():setCurrentExercise(exeDataType)
        return { type = "exercise", exType = exercise }
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

-- Real 42.19 signature (shared/TimedActions/ISRestAction.lua:245):
-- ISRestAction:new(character, bed, useAnimations).
ISRestAction = {
    new = function(_, player, bed, _useAnimations)
        return { type = "rest_furniture", target = bed }
    end,
}

AdjacentFreeTileFinder = {
    Find = function(sq, player, _)
        return nil
    end,
    isTileOrAdjacent = function(_sqA, _sqB)
        return false
    end,
}

-- ── Splitscreen player registry ───────────────────────────────────────────────
-- getSpecificPlayer(n) is the real B42 accessor (getPlayer() ignores args and
-- returns player 0).  Tests populate MockPlayers[n] as needed.
MockPlayers = {}

function getSpecificPlayer(n)
    return MockPlayers[n]
end

-- ── File writer/reader (telemetry, death log) ─────────────────────────────────
-- Real signatures: getFileWriter(name, createIfNotExist, append) and
-- getFileReader(name, createIfNotExist) with reader:readLine()/close().
-- MockFiles captures truncate-vs-append behaviour so tests can verify the
-- telemetry log actually grows, and lets reader tests round-trip content.
MockFiles = {}

function getFileWriter(name, _create, append)
    MockFiles[name] = MockFiles[name] or { lines = {}, appends = 0, truncates = 0 }
    local f = MockFiles[name]
    if append then
        f.appends = f.appends + 1
    else
        f.lines = {}
        f.truncates = f.truncates + 1
    end
    return {
        write = function(_self, s) table.insert(f.lines, s) end,
        close = function(_self) end,
    }
end

function getFileReader(name, _create)
    local f = MockFiles[name] or { lines = {} }
    local i = 0
    return {
        readLine = function(_self)
            i = i + 1
            local line = f.lines[i]
            if line == nil then return nil end
            return (line:gsub("\n$", ""))
        end,
        close = function(_self) end,
    }
end

-- ── Real-time clock ───────────────────────────────────────────────────────────
-- getTimestampMs() is PZ's wall-clock; tests control it via MockRealTime.
MockRealTime = {}

local _mockRealMs = 0

function MockRealTime.set(ms)     _mockRealMs = ms end
function MockRealTime.advance(ms) _mockRealMs = _mockRealMs + ms end

function getTimestampMs()
    return _mockRealMs
end

-- ── Perk XP tables ────────────────────────────────────────────────────────────
-- PerkFactory.getPerk(perk):getTotalXpForLevel(n) — cumulative XP threshold.
-- Simple deterministic mock table: level n needs n*100 total XP.
PerkFactory = {
    getPerk = function(_perk)
        return {
            getTotalXpForLevel = function(_self, level)
                return level * 100
            end,
            getXpForLevel = function(_self, level)
                return level * 100 - (level - 1) * 100
            end,
        }
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

    -- Mutable XP store: tests write player._xp[perk] = number, and set
    -- player._xpMult[perk] for skill-book multipliers.
    local xpStore   = cfg.xp   or {}
    local multStore = cfg.mult or {}

    local xpObj = {
        getXP = function(self, perk)
            return xpStore[perk] or 0
        end,
        getMultiplier = function(self, perk)
            return multStore[perk] or 0
        end,
    }

    local player = {
        _xp           = xpStore,
        _xpMult       = multStore,
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
        getXp         = function(self) return xpObj end,
        getHoursSurvived = function(self) return cfg.hoursSurvived or 0 end,
        getModData    = function(self)
            self._modData = self._modData or (cfg.modData or {})
            return self._modData
        end,
        transmitModData = function(self) end,
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
