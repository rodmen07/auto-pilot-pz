-- AutoPilot_Exercise.lua
-- The trainer: exercise selection, XP-productivity fatigue tracking,
-- player-intervention backoff, and the daily set counter. Extracted from
-- AutoPilot_Needs.lua (code-health split, 2026-07-20, fourth slice -- see
-- AutoPilot_Consumption.lua, AutoPilot_Sleep.lua and AutoPilot_Rest.lua for
-- the first three). The largest remaining block once eat/drink/sleep/rest
-- were out.
--
-- Unlike doRest, no separate seam PR was needed first: everything
-- AutoPilot_Needs.check() touches here (_syncSetsCounter, _inTrainingRun,
-- _exerciseEnduranceResume, doExercise, endTrainingRun) was ALREADY a named
-- function, never a bare module-level variable read/write, so the move
-- itself is the only increment -- confirmed by re-reading check()'s four
-- exercise touch points before starting, not assumed from the doRest
-- precedent. endTrainingRun was already public (AutoPilot_Needs.endTrainingRun,
-- called externally by AutoPilot_Leveler.lua and heavily by tests); the other
-- three become newly public here. AutoPilot_Needs keeps every existing public
-- name reachable via one-line delegation, the same pattern already used for
-- seatPriorityForSprite/setActivity (AutoPilot_Rest) and doEat/doDrink
-- (AutoPilot_Consumption). Moved verbatim; behavior is unchanged.

local function _apNoop(...) end
local print = _apNoop

AutoPilot_Exercise = {}

-- Safe moodle level getter — returns 0 if the moodle type doesn't exist or
-- isn't active. B42 stores moodles in a Map; missing entries cause a Java
-- NPE, so we pcall. Duplicated from AutoPilot_Needs.lua rather than shared
-- across the module boundary: it is a tiny, self-contained, generic helper
-- that check() also needs to keep locally, and this keeps the exercise move
-- verbatim instead of inventing a new cross-module utility surface.
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

-- Phase 2: daily exercise tracking (resets on day rollover).
-- V5.7 (BUG FIX): also resets when the PLAYER CHANGES.  The count used to key
-- off the in-game day alone, so starting a new character in the same Lua
-- session inherited the dead character's total and the F11 panel opened on
-- "Sets today: 150 (no cap)" for a survivor who had not done a single set.
-- Identity is the player OBJECT, the same signal the V4.5 `who` guards use on
-- _pendingSet / _exSetStart: a respawn is a new IsoPlayer even at the same
-- player number, which is exactly what an object comparison catches and what
-- getPlayerNum() alone cannot.
local _exerciseSetsToday = 0
local _lastTrackedDay    = -1
local _setsOwner         = nil   -- the player the count above belongs to
-- In-game day of the last equipment-fetch attempt (one trip per day).
local _equipFetchDay     = -1

local EXERCISE_MINUTES = AutoPilot_Constants.EXERCISE_MINUTES

-- ── V5.7: the exercise endurance HYSTERESIS PAIR ────────────────────────────
--
-- Until V5.7 there were two constants with transposed names and both gated
-- exercise inside doExercise, one immediately after the other:
--   * AutoPilot_Constants.ENDURANCE_EXERCISE_MIN (0.50), copied into a
--     FILE-LOCAL right here at load time -- so an options change could never
--     move it, no matter what the slider wrote;
--   * AutoPilot_Constants.EXERCISE_ENDURANCE_MIN (0.30), live-read, and the
--     one the endurance slider actually writes.
-- The effective gate was max(0.30, 0.50) = 0.50, so the untunable constant
-- silently floored the tunable one and the slider's entire 10-50% range was
-- inert.  That much was just a bug factory.
--
-- The DEEPER problem was that whatever survived was a SINGLE threshold doing
-- two incompatible jobs: deciding when to start training AND when to stop it.
-- The user hit the consequence directly: "The old setting of 50 made it so
-- that only a single rep would be completed after a period of resting."  Rest
-- to 50, start a set, one rep drops endurance under 50, stop, rest again.
-- Raising the number makes it worse, not better.
--
-- So the resolution is a PAIR, not a merge:
--   _exerciseEnduranceResume()  START a run at or above this   (high, 0.90)
--   _exerciseEnduranceFloor()   STOP an active run below this  (low,  0.30)
-- Which one applies depends on whether a run is currently active, which is
-- why the module has to track that (see _runActive below).  A stateless
-- `endurance >= X` test cannot express "keep going until the floor".
--
-- Both are functions, not load-time copies, so they re-read their constant at
-- every call: the V3.3 live-read pattern the options page depends on.
local function _exerciseEnduranceFloor()
    return tonumber(AutoPilot_Constants.EXERCISE_ENDURANCE_MIN) or 0.30
end

local function _exerciseEnduranceResume()
    return tonumber(AutoPilot_Constants.EXERCISE_ENDURANCE_RESUME) or 0.90
end

--- Cross-module accessor: AutoPilot_Needs.check() reads the resume gate for
--- its sit-threshold branch (V5.7 run-aware dead-zone fix).
function AutoPilot_Exercise.enduranceResumeGate()
    return _exerciseEnduranceResume()
end

-- Is a training run in progress right now?  Set when a set is actually
-- queued, cleared by EVERY path that ends training for any reason (see
-- AutoPilot_Exercise.endTrainingRun).  Owner-guarded the same way the
-- _pendingSet / _exSetStart records are: a run belongs to one character, and
-- a death or a respawn must never leave the new one believing it is mid-run.
local _runActive = false
local _runOwner  = nil

--- End the current training run, if any.  Idempotent and argument-light.
--- Being generous about calling this is the safe direction: a spurious call
--- costs one extra rest cycle, whereas a MISSED call leaves the character
--- believing a run is in progress and training down to the floor when it
--- should have been recovering to the resume gate.
function AutoPilot_Exercise.endTrainingRun()
    _runActive = false
    _runOwner  = nil
end

--- Is the given player mid-run?  Ownership makes a stale flag from a dead
--- character read as "not running" for the new one. Public: AutoPilot_Needs
--- .check()'s V5.7 run-aware sit threshold reads this across the module
--- boundary.
function AutoPilot_Exercise.isInTrainingRun(player)
    return _runActive and _runOwner == player
end

-- ── Exercise ────────────────────────────────────────────────────────────────
-- B42: ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)
-- Exercise data comes from FitnessExercises.exercisesType
-- (shared/Definitions/FitnessExercises.lua): squats(legs), pushups(arms,chest),
-- situp(abs), burpees(legs,arms,chest).
--
-- Focus mapping (player design, V3.2):
--   strength -> push-ups (pure Strength work)
--   fitness  -> squats; sit-ups when the legs are too stiff for squats
--   auto     -> burpees (levels Strength AND Fitness together)

local LEG_PARTS = { "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R" }

-- True when any leg part's stiffness reaches the squat cutoff.
local function _legsTooStiffForSquats(player)
    local tooStiff = false
    pcall(function()
        local bd = player:getBodyDamage()
        for _, name in ipairs(LEG_PARTS) do
            local part = bd:getBodyPart(BodyPartType[name])
            if part and part:getStiffness()
                >= AutoPilot_Constants.SQUAT_STIFFNESS_MAX then
                tooStiff = true
                return
            end
        end
    end)
    return tooStiff
end

-- True when the exercise's required item (if any) is in the inventory.
-- Mirrors the vanilla gate (ISFitnessUI: inventory:contains(item, true)).
local function _hasExerciseItem(player, exeData)
    if not exeData.item then return true end
    local has = false
    pcall(function()
        has = player:getInventory():contains(exeData.item, true)
    end)
    return has
end

-- Ordered exercise candidates for the focus; the first one that has
-- definition data, whose required item is carried, and that is not
-- XP-fatigued is used.  Later entries are fallbacks for when the primary
-- exercise stops yielding XP (PZ diminishing returns).
--
-- Equipment exercises lead every pool that can use them: their xpMod
-- (dumbbell 1.8x, barbell 1.2x) belongs to the EXERCISE TYPE, so doing
-- dumbbellpress beats push-ups whenever a dumbbell is carried.  An
-- equipment entry whose item is NOT carried fails the _hasExerciseItem
-- gate and falls through silently to the next candidate, so a barehanded
-- character still trains normally.  No fitness equipment exists, so the
-- fitness pool stays bodyweight-only.
local function _exerciseCandidates(player, focus)
    if focus == "strength" then
        return { "dumbbellpress", "bicepscurl", "barbellcurl", "pushups" }
    elseif focus == "fitness" then
        if _legsTooStiffForSquats(player) then
            print("[Needs] Legs too stiff for squats — switching to sit-ups.")
            return { "situp" }
        end
        return { "squats", "situp" }
    end
    -- auto (V5.2): equipment first, then burpees (the one exercise that
    -- trains BOTH stats), then the bodyweight fallbacks.  Burpees used to
    -- lead here, so an auto day never touched the dumbbell the mod itself
    -- walks out to fetch (fetchExerciseEquipment, below): the 1.8x/1.2x
    -- equipment xpMod was fetched and then ignored.  With equipment
    -- leading, the XP-fatigue rotation still falls through to burpees and
    -- the bodyweight pool as each option stops paying, so Fitness keeps
    -- progressing across the day; since V4.6 dropped the daily set cap,
    -- that rotation runs long enough for every tier to get used.
    return { "dumbbellpress", "bicepscurl", "barbellcurl", "burpees",
             "squats", "pushups", "situp" }
end

-- ── Per-exercise XP-productivity tracking ───────────────────────────────────
-- PZ applies per-exercise diminishing returns: repeat one exercise long
-- enough and its XP drops to ~zero while the animation happily continues.
-- The engine does not expose that fatigue to Lua (only long-term
-- getRegularity), so it is detected the honest way: by measuring the actual
-- XP a completed set produced.

-- [exType] -> { str, fit, ms }  snapshot taken when the set was queued.
local _exSetStart     = {}
-- [exType] -> game-ms until which the exercise is considered fatigued.
local _exFatiguedUntil = {}
-- Human-readable state of the trainer: written through AutoPilot_Needs
-- .setActivity, the single activity string the needs layer shares (V5.8).
-- The trainer is no longer its only writer -- doRest writes it too -- which
-- is what stops the F11 panel reporting "training: burpees" at a character
-- who is sitting down.

-- ── Player-intervention backoff (V4.5) ──────────────────────────────────────
-- The user-reported lockup: cancel an exercise and the armed trainer
-- re-queues a new set ~0.75 s later, bulldozing the cancel.  Fix: track the
-- one exercise action the mod itself queues; when it vanishes from the
-- queue before running ~a full set AND the mod did not clear it itself
-- (urgent-need interrupt, threat response, thrash guard), the player
-- intervened, and training backs off for EXERCISE_BACKOFF_MINUTES (game
-- minutes, live-read so the Options slider applies immediately).  A
-- FOREIGN exercise observed running (Main's busy cycle) refreshes the same
-- window every cycle, so training also stays away while, and shortly
-- after, the player exercises manually.  Movement input has no verified
-- read surface in this mod; in PZ movement cancels the queued action, so
-- it lands in the vanished-uncompleted path and is covered the same way.
--
-- All state is module-local: a Lua reload (MP join) starts clean, and the
-- `who` field guards against judging a dead character's set against the
-- respawned character (same pattern as _exSetStart.who).
local _pendingSet    = nil   -- { action, exType, ms, who } last mod-queued set
local _backoffUntilMs = 0    -- game-ms; training yields while now < this

local function _backoffWindowMs()
    local mins = tonumber(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES) or 0
    if mins <= 0 then return 0 end
    return mins * 60000
end

local function _setBackoff(nowMs, why)
    local windowMs = _backoffWindowMs()
    if windowMs <= 0 then return end
    _backoffUntilMs = nowMs + windowMs
    AutoPilot_Needs.setActivity("backing off (" .. why .. ")")
    print("[Needs] Training backoff (" .. why .. ") for "
        .. tostring(AutoPilot_Constants.EXERCISE_BACKOFF_MINUTES)
        .. " game minutes.")
end

-- Resolve the tracked mod-queued set: still running, completed normally, or
-- vanished uncompleted (= player intervention -> backoff).  Called at the
-- top of doExercise, before any gate, so the record can never go stale.
local function _updateInterventionState(player, nowMs)
    local ps = _pendingSet
    if not ps then return end
    -- Never judge a snapshot from a different character (death/respawn).
    if ps.who ~= player then
        _pendingSet = nil
        AutoPilot_Utils.clearModAction(ps.action)
        return
    end
    local stillQueued = false
    pcall(function()
        local q   = ISTimedActionQueue.getTimedActionQueue(player)
        local arr = q and q.queue
        if type(arr) == "table" then
            for i = 1, #arr do
                if arr[i] == ps.action then
                    stillQueued = true
                    break
                end
            end
        end
    end)
    if stillQueued then return end
    -- The set left the queue: resolve the record either way.
    _pendingSet = nil
    AutoPilot_Utils.clearModAction(ps.action)
    local fullSetMs = AutoPilot_Constants.EXERCISE_MINUTES * 60000
    if (nowMs - ps.ms) < fullSetMs * 0.8 then
        -- Vanished well short of a full set and the mod did not clear it
        -- itself (those paths consume the record via noteModExerciseCleared):
        -- the player cancelled it.  Do not judge the aborted set as
        -- XP-fatigue, and back off instead of re-queuing over player intent.
        _exSetStart[ps.exType] = nil
        _setBackoff(nowMs, "manual cancel")
    end
end

local function _perkXp(player, perk)
    local ok, xp = pcall(function() return player:getXp():getXP(perk) end)
    return (ok and type(xp) == "number") and xp or 0
end

-- Judge the previous set of exType (if one ran to roughly full length):
-- returns false when the exercise is now fatigued and should be skipped.
local function _exerciseStillProductive(player, exType, nowMs)
    local fatiguedUntil = _exFatiguedUntil[exType]
    if fatiguedUntil and nowMs < fatiguedUntil then
        return false
    end
    local s = _exSetStart[exType]
    if not s then return true end
    -- A snapshot from a DIFFERENT character (death/respawn) must never be
    -- judged: the new character's lower XP would read as negative gain and
    -- falsely fatigue the exercise.
    if s.who ~= player then
        _exSetStart[exType] = nil
        return true
    end
    -- Only judge sets that ran most of their duration (an interrupted set
    -- legitimately gains nothing).
    local fullSetMs = AutoPilot_Constants.EXERCISE_MINUTES * 60000
    if (nowMs - s.ms) < fullSetMs * 0.8 then return true end
    local gain = (_perkXp(player, Perks.Strength) - s.str)
               + (_perkXp(player, Perks.Fitness)  - s.fit)
    if gain < AutoPilot_Constants.EXERCISE_MIN_XP_PER_SET then
        print(string.format(
            "[Needs] %s produced %.1f XP last set — fatigued; resting it.",
            exType, gain))
        _exFatiguedUntil[exType] = nowMs
            + AutoPilot_Constants.EXERCISE_FATIGUE_RECOVERY_MS
        _exSetStart[exType] = nil
        return false
    end
    return true
end

-- Log cooldown for "waiting for endurance" to prevent spam
local exerciseWaitLogMs = 0

--- V5.7: bring the daily set counter into agreement with WHO and WHEN.
---
--- Two things invalidate the count, and before V5.7 only the first was
--- checked: the in-game day rolling over, and the count belonging to a
--- DIFFERENT character.  The second is the user-reported bug ("when starting
--- a new character, the number of sets completed should reset"): a fresh
--- survivor opened the F11 panel on the previous character's total because
--- module state outlives a death and a new game inside one Lua session.
---
--- Called from BOTH doExercise and the top of AutoPilot_Needs.check(), so the
--- reset lands on the very first evaluation cycle after a respawn even when
--- some other need (thirst, wounds, a threat) wins that cycle and exercise is
--- never reached. Public: check() calls this across the module boundary.
--- @param player IsoPlayer
--- @return number today  the in-game day this counter is now tracking
function AutoPilot_Exercise.syncSetsCounter(player)
    local gt    = GameTime.getInstance()
    local today = gt and gt:getDay() or 0
    if _setsOwner ~= player then
        -- New character (or the first sync of the session): nothing this
        -- counter holds belongs to them.  Scope note: _equipFetchDay is keyed
        -- off the day alone and has the same theoretical staleness, but it is
        -- deliberately NOT reset here.  The user asked for the SET COUNT to
        -- reset; a new character being denied one dumbbell-fetch trip until
        -- the next in-game day is cosmetic, self-healing, and outside what
        -- was requested.
        _exerciseSetsToday = 0
        _lastTrackedDay    = today
        _setsOwner         = player
        -- V5.7: a run belongs to a character.  The new one is not mid-run.
        AutoPilot_Exercise.endTrainingRun()
    elseif today ~= _lastTrackedDay then
        -- Same character, new day: the original Phase 2 rollover, unchanged.
        _exerciseSetsToday = 0
        _lastTrackedDay    = today
    end
    return today
end

--- V5.7: test seam for the per-character reset (no engine surface involved).
function AutoPilot_Exercise.syncSetsCounterForTest(player)
    return AutoPilot_Exercise.syncSetsCounter(player)
end

-- focus: "strength" | "fitness" | nil (nil = auto-balance the lower of the two)
function AutoPilot_Exercise.doExercise(player, focus)
    -- Phase 2 day rollover + V5.7 per-character reset.
    local _today = AutoPilot_Exercise.syncSetsCounter(player)

    local okMs, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    nowMs = okMs and nowMs or 0

    -- V4.5: resolve the last mod-queued set (completed vs player-cancelled)
    -- BEFORE any gate, then honor the intervention backoff window.
    _updateInterventionState(player, nowMs)
    if nowMs < _backoffUntilMs then
        local minsLeft = math.ceil((_backoffUntilMs - nowMs) / 60000)
        AutoPilot_Needs.setActivity("backing off (player intervened; "
            .. minsLeft .. "m left)")
        -- V5.7: the run is over.  Whatever resumes after the backoff window
        -- is a NEW run and must clear the resume gate on its own merits.
        AutoPilot_Exercise.endTrainingRun()
        return false
    end

    -- V4.6: optional daily-cap gate.  The PRIMARY limiter is XP
    -- productivity (_exerciseStillProductive, below): training stops when an
    -- exercise stops paying XP, not at an arbitrary set count.  A cap of 0
    -- (the default) means unlimited, so this gate is skipped entirely; only
    -- a user-configured cap > 0 enforces a hard ceiling.
    local dailyCap = tonumber(AutoPilot_Constants.EXERCISE_DAILY_CAP) or 0
    if dailyCap > 0 and _exerciseSetsToday >= dailyCap then
        print(("[Needs] Daily exercise cap %d reached; resting."):format(
            dailyCap))
        AutoPilot_Needs.setActivity("resting (daily set cap reached)")
        AutoPilot_Exercise.endTrainingRun()
        return false
    end

    -- ── V5.7: the endurance HYSTERESIS gate ─────────────────────────────────
    -- This used to be two consecutive gates built on two transposed constants
    -- that both asked "is there enough to START?" (see the pair of helpers at
    -- the top of this file).  Asking only that question is what produced the
    -- user's single-rep loop: rest to the gate, start a set, the first rep
    -- drops below the gate, stop, rest again.
    --
    -- Now the threshold DEPENDS ON WHETHER A RUN IS ALREADY GOING:
    --   not running -> must reach the high RESUME gate to start
    --   running     -> keep going all the way down to the low FLOOR
    -- so one rest buys a long run of reps instead of one.
    --
    -- The severe exertion-moodle test is preserved verbatim and stays
    -- unconditional: it is a genuinely different signal (moodle level, not
    -- stat value) and a level 3+ moodle ends a run no matter how it started.
    local endurance = AutoPilot_Utils.safeStat(player, CharacterStat.ENDURANCE)
    local enduranceMoodle = safeMoodleLevel(player, MoodleType.ENDURANCE)
    local inRun     = AutoPilot_Exercise.isInTrainingRun(player)
    local endGate   = inRun and _exerciseEnduranceFloor()
                            or _exerciseEnduranceResume()
    if endurance < endGate or enduranceMoodle > 2 then
        -- Log once every 30s of game time, not every tick
        local ok, now = pcall(function()
            return getGameTime():getCalender():getTimeInMillis()
        end)
        local ms = ok and now or 0
        if ms >= exerciseWaitLogMs then
            print(string.format(
                "[Needs] Endurance %.0f%% under the %s gate %.0f%%;"
                .. " %s.",
                endurance * 100, inRun and "floor" or "resume",
                endGate * 100,
                inRun and "ending the training run" or "still recovering"))
            exerciseWaitLogMs = ms + 30000
        end
        -- Whether the run just ended on the floor or never started, the next
        -- attempt has to clear the RESUME gate: that is the hysteresis.
        AutoPilot_Exercise.endTrainingRun()
        AutoPilot_Needs.setActivity("resting (endurance recovering)")
        return false  -- no action queued; the sit branch in check() recovers
    end

    -- Once per day (strength/auto focus): fetch a dumbbell/barbell from home
    -- storage so the higher-XP equipment exercises unlock.  The fetch trip is
    -- itself this cycle's action.
    if focus ~= "fitness" and _equipFetchDay ~= _today
        and AutoPilot_Inventory.fetchExerciseEquipment
        and not AutoPilot_Inventory.hasExerciseEquipment(player) then
        _equipFetchDay = _today
        local okF, fetching = pcall(AutoPilot_Inventory.fetchExerciseEquipment, player)
        if okF and fetching then
            AutoPilot_Needs.setActivity("fetching exercise equipment")
            return true
        end
    end

    local candidates = _exerciseCandidates(player, focus)
    local exType, exeData
    for _, cand in ipairs(candidates) do
        local data = FitnessExercises and FitnessExercises.exercisesType
            and FitnessExercises.exercisesType[cand] or nil
        if data and _hasExerciseItem(player, data)
            and _exerciseStillProductive(player, cand, nowMs) then
            exType, exeData = cand, data
            break
        end
    end

    if not exeData then
        print("[Needs] All exercises for focus '" .. tostring(focus or "auto")
            .. "' are XP-fatigued — pausing training while they recover.")
        AutoPilot_Needs.setActivity("resting (exercises fatigued)")
        -- V5.7: XP fatigue ends the run too.  Without this the character
        -- would keep "being mid-run" while queueing nothing, and would then
        -- resume off the low floor instead of recovering to the resume gate.
        AutoPilot_Exercise.endTrainingRun()
        return false
    end
    print("[Needs] Exercise — focus: " .. tostring(focus or "auto")
        .. " -> " .. exType)

    -- Pre-initialize the Java Fitness object so currentExe is set before
    -- the action lifecycle starts (prevents exerciseRepeat NPE).
    pcall(function()
        local fitness = player:getFitness()
        fitness:init()
    end)

    -- 42.19 signature (shared/TimedActions/ISFitnessAction.lua:200, verified
    -- against the RUNNING game's stack trace):
    --   ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)
    -- The 5th arg feeds fitness:setCurrentExercise(exeDataType) — a String-typed
    -- Java call — so it must be the TYPE STRING, with the data table 4th.
    local ok, action = pcall(function()
        return ISFitnessAction:new(player, exType, EXERCISE_MINUTES, exeData, exeData.type)
    end)

    if ok and action then
        -- Equipment exercises: put the item in hand the same way vanilla's
        -- fitness UI does before starting (ISFitnessUI.lua:245-262) — prop
        -- "twohands" equips two-handed, "primary"/"switch" one-handed.
        if exeData.item then
            pcall(function()
                local twoHands = exeData.prop == "twohands"
                ISWorldObjectContextMenu.equip(player,
                    player:getPrimaryHandItem(), exeData.item, true, twoHands)
            end)
        end
        -- addGetUpAndThen (real 42.19 static, ISTimedActionQueue.lua:219):
        -- stands the character up from any furniture before exercising.
        -- V4.5: tag ownership BEFORE queueing, and remember the action so
        -- the intervention detector can tell a completed set from a
        -- player-cancelled one.
        AutoPilot_Utils.tagModAction(action)
        ISTimedActionQueue.addGetUpAndThen(player, action)
        _pendingSet = { action = action, exType = exType, ms = nowMs, who = player }
        -- Snapshot XP at set start so the NEXT attempt can judge whether this
        -- set actually produced XP (diminishing-returns detection).
        _exSetStart[exType] = {
            str = _perkXp(player, Perks.Strength),
            fit = _perkXp(player, Perks.Fitness),
            ms  = nowMs,
            who = player,
        }
        -- V5.7: a set is really queued, so a training RUN is now in progress.
        -- From here the low floor applies instead of the high resume gate,
        -- which is what lets the run keep going rep after rep off one rest.
        _runActive = true
        _runOwner  = player
        -- The counter keeps running even when uncapped: the F11 panel and
        -- the logs report it, it just no longer halts training on its own.
        _exerciseSetsToday = _exerciseSetsToday + 1
        AutoPilot_Needs.setActivity("training: " .. exType)
        if dailyCap > 0 then
            print(("[Needs] Exercise set %d/%d queued."):format(
                _exerciseSetsToday, dailyCap))
        else
            print(("[Needs] Exercise set %d queued (no daily cap)."):format(
                _exerciseSetsToday))
        end
        return true
    else
        print("[Needs] ISFitnessAction failed for: " .. exType .. " — " .. tostring(action))
        AutoPilot_Needs.setActivity("error: could not start " .. tostring(exType))
        AutoPilot_Exercise.endTrainingRun()
        return false
    end
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Trainer status for the F11 panel.
--- Returns { outcome = "training: squats" | "resting (...)" | "idle",
---           setsToday, cap, setsLine }.
--- V4.6: `cap` is 0 when training is uncapped (XP productivity is the
--- limiter), so the panel must never print "12/0".  `setsLine` is the
--- pre-formatted, honest rendering of the count and is what the UI draws
--- verbatim (same data-layer-formats-it convention as the program line);
--- `setsToday` and `cap` stay for callers that want the raw numbers.
--- V5.8: `outcome` is the needs layer's SINGLE activity string
--- (AutoPilot_Needs.getActivityOutcome), so it now also reports the rest
--- paths.  It can no longer say "training: x" while the character is sitting
--- down; the F11 panel and the V4.4 on-screen action HUD read this same
--- field through this same function.
function AutoPilot_Exercise.getExerciseStatus()
    local cap = tonumber(AutoPilot_Constants.EXERCISE_DAILY_CAP) or 0
    local setsLine
    if cap > 0 then
        setsLine = ("Sets today: %d/%d"):format(_exerciseSetsToday, cap)
    else
        setsLine = ("Sets today: %d (no cap)"):format(_exerciseSetsToday)
    end
    return {
        outcome   = AutoPilot_Needs.getActivityOutcome(),
        setsToday = _exerciseSetsToday,
        cap       = cap,
        setsLine  = setsLine,
    }
end

-- ── Player-intervention notifications (V4.5) ────────────────────────────────
-- Called by Main; all three are argument-light so no player object is ever
-- closed over across a Lua reload (the MP stale-closure lesson).

--- Main observed a FOREIGN exercise as the running action (player-initiated
--- or vanilla-queued; identity says it is not ours).  Refreshing the
--- backoff window every observed cycle keeps training away while the
--- manual exercise runs and for one full window after it ends, so the
--- trainer never re-queues over the player's own session.
function AutoPilot_Exercise.noteForeignExercise(_player)
    local ok, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if not ok or type(nowMs) ~= "number" then return end
    local windowMs = _backoffWindowMs()
    if windowMs <= 0 then return end
    _backoffUntilMs = nowMs + windowMs
    AutoPilot_Needs.setActivity("waiting (manual exercise in progress)")
    -- V5.7: the player is training by hand; our run is over.
    AutoPilot_Exercise.endTrainingRun()
end

--- The MOD itself cleared its own queued exercise (urgent-need interrupt,
--- threat response, or thrash guard).  Consume the pending record so the
--- vanish is NOT misread as a player cancel (no backoff: training may
--- resume as soon as the interrupting condition is handled).
function AutoPilot_Exercise.noteModExerciseCleared()
    -- V5.7: end the run FIRST, and unconditionally.  An urgent need, a threat
    -- response or the thrash guard all mean training stopped, whether or not
    -- there was still a pending record to consume.  Training may resume as
    -- soon as the interrupting condition is handled -- but as a NEW run, off
    -- the resume gate, not off the floor.
    AutoPilot_Exercise.endTrainingRun()
    local ps = _pendingSet
    if not ps then return end
    _pendingSet = nil
    AutoPilot_Utils.clearModAction(ps.action)
end

--- F10 panic stop: the player explicitly stopped a running exercise.
--- Consume the pending record (if the set was ours) and start the backoff
--- window immediately, so even a just-armed trainer cannot re-queue an
--- exercise right after the player asked for it to stop.
function AutoPilot_Exercise.notePanicStop()
    -- V5.7: the player asked for training to STOP; the run ends here.
    AutoPilot_Exercise.endTrainingRun()
    local ps = _pendingSet
    if ps then
        _pendingSet = nil
        AutoPilot_Utils.clearModAction(ps.action)
    end
    local ok, nowMs = pcall(function()
        return getGameTime():getCalender():getTimeInMillis()
    end)
    if not ok or type(nowMs) ~= "number" then return end
    _setBackoff(nowMs, "F10 panic stop")
end

--- Reset intervention state (tests only; mirrors Leveler.resetForTest).
function AutoPilot_Exercise.resetInterventionForTest()
    if _pendingSet then
        AutoPilot_Utils.clearModAction(_pendingSet.action)
    end
    _pendingSet     = nil
    _backoffUntilMs = 0
    AutoPilot_Exercise.endTrainingRun()
end

--- Return how many exercise sets have been performed today.
function AutoPilot_Exercise.getExerciseSetsToday()
    return _exerciseSetsToday
end

--- Return preferred exercise type based on STR vs FIT perk level.
--- Returns "strength", "fitness", or "either".
function AutoPilot_Exercise.preferredExerciseType(player)
    local ok, strLvl, fitLvl = pcall(function()
        return player:getPerkLevel(Perks.Strength),
               player:getPerkLevel(Perks.Fitness)
    end)
    if not ok or strLvl == nil or fitLvl == nil then return "either" end
    if strLvl < fitLvl then
        print(("[Needs] STR %d < FIT %d — preferring strength."):format(strLvl, fitLvl))
        return "strength"
    elseif fitLvl < strLvl then
        print(("[Needs] FIT %d < STR %d — preferring fitness."):format(fitLvl, strLvl))
        return "fitness"
    end
    return "either"
end
