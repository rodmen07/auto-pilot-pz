-- tests/lua_mock_pz.lua
-- Mocks essential Project Zomboid Build 42 APIs for off-game Lua testing.
--
-- Load this file with dofile() before loading any AutoPilot module under test.
-- All globals declared here mirror the real PZ engine surface so that the
-- production Lua modules can be executed without launching the game client.
--
-- ===========================================================================
-- VERIFIED 42.19 API SURFACE (V3.4 PR2 mock audit, 2026-07-19)
-- ===========================================================================
-- Authoritative map of every PZ API the mod calls, the runtime-verified
-- signature it must honor, and how the test harness covers it.  Signature
-- sources: ROADMAP.md, CHANGELOG.md (the V2.1 live-install sweep and the
-- V3.2 running-game stack-trace verification), and in-module code comments.
-- NEVER a fresh read of the game install: the phantom-file incident shipped
-- a wrong ISFitnessAction signature from a stale copy while tests stayed
-- green.  This mock, not the install, is the guard.
--
-- Coverage legend:
--   [MA] mocked here, assertion-bearing (wrong arity/types fail loudly)
--   [M]  mocked here, no argument assertions
--   [S]  suite-local mock in the named test file (shadows any global here)
--   [G]  gap: not mocked anywhere; the production callsite is pcall or
--        existence guarded, or the path is unreachable in the suites
--
-- Timed-action queue statics (client/TimedActions/ISTimedActionQueue.lua,
-- verified via shell against the live install: add, addAfter,
-- addGetUpAndThen, clear, hasAction, hasActionType, isPlayerDoingAction,
-- getTimedActionQueue, queueActions; isAllDone does NOT exist):
--   [MA] ISTimedActionQueue.add(action)
--   [MA] ISTimedActionQueue.addGetUpAndThen(character, action)
--          line 219; EXISTS in 42.19 (V2.1 wrongly removed it; V3.2 restored)
--   [M]  ISTimedActionQueue.clear(character)
--   [M]  ISTimedActionQueue.isPlayerDoingAction(character)
--   [M]  ISTimedActionQueue.getTimedActionQueue(character)
--          V4.5: the mod-action ownership registry (AutoPilot_Utils
--          tagModAction/isModAction/queueModAction) rides these existing
--          statics plus plain Lua table writes on action objects the mod
--          itself constructs; NO new engine surface was added for it, and
--          suites exercise the REAL AutoPilot_Utils against this mock.
--
-- Timed-action constructors:
--   [MA] ISFitnessAction:new(character, exercise, timeToExe, exeData, exeDataType)
--          shared/TimedActions/ISFitnessAction.lua:200; exeData TABLE 4th,
--          exeDataType STRING 5th (feeds the String-typed setCurrentExercise
--          call at line 217); verified against the RUNNING game's stack
--          trace after the phantom-file mixup (V3.2).
--   [MA] ISRestAction:new(character, bed, useAnimations)
--          exactly 3 args (shared/TimedActions/ISRestAction.lua:245, V3.2).
--          V5.8: no longer the furniture rest path's action -- it does no
--          pathing, and behind pathToSitOnFurniture it was a second action
--          queued on top of a sit.  It survives as the fallback for when
--          the seat action is unavailable, and useAnimations is now `true`
--          (nil is falsy, i.e. a rest with the sitting animation disabled).
--   [MA] ISApplyBandage:new(character, patient, bandage, bodyPart, doIt)
--          as shipped through the V2.1 and V3.2 live verification sweeps.
--          Pre-audit, this mock had the args in the wrong slots (patient
--          landed in a "bodyPart" parameter); fixed by this audit.
--          2026-07-20 mock-surface drift audit: the 5th arg (doIt) was
--          undocumented as "..." and uncaptured by the mock function, so it
--          silently vanished and was never asserted -- doIt=true applies the
--          bandage, doIt=false/nil REMOVES it (ISApplyBandage.lua:39, :71,
--          :111). Now captured, asserted boolean, and returned on the action
--          table so test_medical_logic can assert AutoPilot always applies.
--   [MA] ISEatFoodAction:new(character, item, percentage)   asserts item only;
--          2026-07-20 mock-surface sweep: the real 3rd param
--          (shared/TimedActions/ISEatFoodAction.lua:294) is `percentage`, how
--          much of the item to consume (0.0-1.0; falls back to 1 when falsy),
--          NOT a count of items. AutoPilot always passes 1 (eat the whole
--          item), which matches the real constructor's own default -- not a
--          bug, just a naming mismatch between this project's "count" and the
--          engine's "percentage". Corrected the name here so a future reader
--          does not read "1" as "eat 1 item" and reason about it wrongly.
--          PZ uses this for drinks and the painkiller fallback too
--   [M]  ISSitOnGround:new(character, square)
--   [M]  ISWalkToTimedAction:new(character, square) + :setOnComplete(fn, ...)
--   [MA] ISPathFindAction:pathToSitOnFurniture(character, furniture, cb)
--          walks the character to the furniture AND seats them; since V5.8
--          it is the ONLY action the furniture rest path queues (see the
--          stub below and doRest's comment for why queueing a rest action
--          behind it defeated the sit)
--   [M]  ISReadABook:new(character, book)   unexercised: doRead's literacy
--          gate fails in the suites (see Perks.Literacy below)
--   [S]  ISEquipWeaponAction:new(character, item, time, primary)
--          test_threat_logic / test_combat_policy / test_container_search
--          (ISBarricadeAction left this record in V5.0 with the barricading
--          feature; the mod has no barricade callsite to model any more)
--   [S]  ISInventoryTransferAction:new(character, item, srcContainer, destContainer)
--          test_medical_logic / test_resource_economy; the constructor is
--          never reached at runtime by current suites (pcall-guarded paths)
--   [S]  ISTakeWaterAction:new(character, containerOrNil, waterObject, isTainted)
--          test_resource_economy; unreached at runtime (pcall-guarded)
--   [G]  ISWearClothing:new(character, item, time)   adjustClothing is
--          never driven past its temperature gate in the suites
--   [G]  ISTakePillAction:new(character, item)   rawget-guarded in Needs;
--          the ISEatFoodAction fallback is the path the suites exercise
--
-- Sleep / world-object context:
--   [MA] ISWorldObjectContextMenu.onSleepWalkToComplete(playerIndex, bed)
--          numeric 0-based player index, NOT the player object (V2.1);
--          bed may be nil (vehicle sleep re-checks getVehicle()).
--          ISGetOnBedAction does NOT exist in B42 and stays absent here.
--   [MA] ISWorldObjectContextMenu.equip(character, currentItem, itemType, flag, twoHands)
--          ISFitnessUI.lua:245-262 pattern; itemType STRING, twoHands BOOLEAN
--   [M]  AdjacentFreeTileFinder.Find(square, character)
--   [M]  AdjacentFreeTileFinder.isTileOrAdjacent(squareA, squareB)
--
-- Engine accessors:
--   [MA] getSpecificPlayer(n)   numeric index; the real accessor (getPlayer(n)
--          ignores its argument and always returns player 0, V2.1)
--   [MA] getFileWriter(name, createIfNotExist, append)   append=false
--          TRUNCATES (the V2.1 telemetry one-line-log bug); this mock counts
--          truncates vs appends so tests can verify the log actually grows.
--          V4.2 (C5): AutoPilot_SessionHistory rides this same surface for
--          auto_pilot_sessions.log (append-only summary/checkpoint lines;
--          the once-per-session rotation rewrite is its ONLY truncate);
--          test_session_history.lua asserts the discipline via the
--          appends/truncates counters.  No new mock surface.
--   [MA] getFileReader(name, createIfNotExist) with :readLine()/:close()
--          V4.2 (C5): also the SessionHistory read path (same pattern as
--          DeathLog.readLines)
--   [M]  getCell()   stub cell whose getGridSquare() returns nil
--          (getZombieList is suite-local: test_threat_logic overrides getCell)
--   [M]  getGameTime():getCalender():getTimeInMillis() / :getDay()
--          "getCalender" is the real PZ Java API spelling (not "Calendar").
--          V4.3 (C3): AutoPilot_Leveler.getWeekday derives the weekly
--          training-program day from getTimeInMillis ONLY (epoch millis;
--          epoch day zero, 1970-01-01, was a Thursday).  No day-of-week
--          calendar API is in the verified record, so none is called and
--          none is mocked; the pcall-guarded absence path falls back to
--          the always-on focus behavior.  No new mock surface: the suites
--          drive the weekday through MockTime.set on this same clock.
--   [M]  GameTime.getInstance()
--   [M]  getTimestampMs()   real-time wall clock, driven by MockRealTime
--   [M]  PerkFactory.getPerk(perk):getTotalXpForLevel(n)   cumulative XP
--          threshold (client/XpSystem/ISUI/ISSkillProgressBar.lua)
--   [S]  Events.OnTick / OnKeyPressed / OnMainMenuEnter / OnQueueNewGame (.Add)
--          capture harness in test_main_logic; OnQueueNewGame can be ABSENT
--          during the 42.19 MP server-connect reload (V3.2), so Main guards
--          both session-end registrations with existence checks.
--          V5.5: AutoPilot_Options now rides OnMainMenuEnter and OnTick too
--          (its mod-options registration retry), with the same existence
--          guards, and test_options_registration adds a second capture
--          harness for exactly those two.  Only .Add is in the verified
--          record, so nothing is ever unregistered: the tick retry early-
--          outs on a boolean instead of calling a .Remove that this project
--          has never verified
--   [S]  Keyboard.KEY_F10 / KEY_F11   test_main_logic
--   [S]  getPlayer()   test_main_logic (Main's fallback resolver only)
--   [S]  instanceof(item, className)   V5.1: now modelled, because the carried
--          -inventory walk type-checks with it before probing a container.
--          Models "InventoryContainer" (bag items) and "HandWeapon".  The
--          gap it replaced is exactly why V4.8's error spam reached a live
--          client: a mock CAN NOT reproduce PZ logging a Java exception that
--          pcall swallows, so the type check has to be asserted directly
--   [G]  luautils.walkAdj(character, square, keepActions)
--          suite-local stubs exist in test_home_map and
--          test_resource_economy but no suite reaches the calls at runtime;
--          production callsites are pcall-guarded (walkAdj failure falls
--          back to ISWalkToTimedAction).  walkAdjWindowOrDoor left this
--          record in V5.0 with the barricade scan that was its only caller
--   [G]  getClimateManager()   existence-guarded in Needs.isRaining
--   [G]  HaloTextHelper.addText/addGoodText/addBadText   rawget-guarded (Main)
--   [S]  PZAPI.ModOptions   :create / :addTitle / :addSlider / :addKeyBind /
--          getOption(id):getValue() / per-instance apply() / :load
--          (42.19-verified surface per AutoPilot_Options header,
--          client/PZAPI/ModOptions.lua).  V4.7: test_options_mapping now
--          loads AutoPilot_Options against a SUITE-LOCAL mock of exactly
--          these calls (nothing new), asserting that every DEFS slider
--          registers seeded from its compiled-in default and that a saved
--          value lands in the right constant through the right scale.  The
--          WIDGETS remain playtest-only (a mock cannot prove the real page
--          draws), and the registration stays pcall plus existence guarded
--          so it falls back to compiled-in defaults.  PARTIAL GAP.
--          V5.7: the "Min endurance to start a set" slider became a PAIR
--          ("Resume training when endurance reaches" / "Keep training until
--          endurance falls to").  Nothing new on the engine surface -- both
--          are addSlider, same as everything else here -- but the reason is
--          worth recording next to the widget gap: a SINGLE endurance
--          threshold was serving as both the start gate and the stop gate,
--          which thrashes at any value (user, from live play: "only a single
--          rep would be completed after a period of resting").  The suite
--          asserts the pair, the run-state machine that makes two gates
--          possible, and every path that ends a run.
--          V4.3 (C3): the training-program selector rides this same gap.
--          addComboBox is NOT in the verified record.  V5.7 (BUG FIX):
--          "not in the verified record" turned out to mean the control was
--          BROKEN IN GAME, not merely unproven.  The pre-V5.7 registration
--          existence-checked addComboBox inside its own pcall and treated a
--          successful pcall as proof the widget worked; on a real 42.19
--          client the method EXISTS and the call SUCCEEDS, so the guard
--          passed, the addSlider fallback never fired, and a user screenshot
--          of the working (V5.5) options page shows the dropdown rendered
--          with ZERO items in it.  The lesson is the V5.1 one again: an
--          unverified call that does not throw is not an unverified call
--          that works, and a mock cannot tell the difference.  The combo
--          call is gone; the program picker is now unconditionally the
--          addSlider over the 1-based program indices (verified surface),
--          and test_options_mapping's suite-local mock now PROVIDES an
--          addComboBox that accepts the call and populates nothing, so the
--          suite finally models the live client instead of the one shape of
--          page that always took the fallback.  It asserts the module never
--          calls it.  Restoring a dropdown requires a verified signature
--          AND a positive population check, not just a call that returns.
--          The picked value is copied into the live-read
--          AutoPilot_Constants.TRAINING_PROGRAM, and the Leveler side of
--          that seam (validation, day resolution, rest-day yield) is what
--          test_leveler_metrics covers.  The widget itself stays
--          playtest-only, like every control on the page.
--          V5.5 (BUG FIX): the assumption written into this record and into
--          AutoPilot_Options' own header, that PZAPI is vanilla client lua
--          and therefore always present when a mod file loads, was FALSE on
--          a real 42.19 client (console.txt: 'require("pzapi/ui/ui")
--          failed').  PZAPI was nil at load, the load-time registration
--          returned silently, and EVERY option this mod ever shipped was
--          inert in game while test_options_mapping stayed green (it puts
--          PZAPI in _G before the dofile, so it could only ever test the
--          happy path).  Registration is now retried on OnMainMenuEnter and
--          OnTick behind one _registered flag, and
--          test_options_registration models PZAPI as ABSENT AT LOAD AND
--          APPEARING LATER, the state no suite could previously express.
--          No new engine surface: same create/addTitle/addSlider/addKeyBind/
--          getOption/apply/load calls, plus the [MA] getFileWriter append
--          used to record the failure in the run log.
--   [G]  ISCollapsableWindow / ISButton / UIFont / require("ISUI/...")
--          The F11 panel's widgets are vanilla ISUI and stay playtest-only:
--          nothing here instantiates or draws the panel.  DOCUMENTED GAP.
--          Three suites do dofile AutoPilot_UI with suite-local [S] stubs
--          for its LOAD-time surface only (require("ISUI/...") plus
--          ISCollapsableWindow:derive), so its pure string helpers can be
--          tested for real: test_version_constant (V5.3 formatTitle),
--          test_options_registration (V5.5 optionsWarningLine) and
--          test_main_logic (V5.8 statusText/statusLine/trainedExerciseFrom,
--          asserted against the real AutoPilot.getActionIntention so the
--          F11 panel and the V4.4 action HUD are proved to agree).
--
-- Enums and definition tables:
--   [M]  CharacterStat   HUNGER/THIRST/FATIGUE/ENDURANCE/PAIN/BOREDOM/SANITY;
--          PANIC/SICKNESS/STRESS are suite-local (test_threat_logic);
--          safeStat degrades missing keys to 0 by design
--   [M]  MoodleType   ENDURANCE/Unhappy (PAIN absent; the only callsite is
--          nil-guarded in safeMoodleLevel)
--   [M]  BodyPartType   MAX / ToIndex (getDisplayName is suite-local in
--          test_medical_logic; leg-part keys like UpperLeg_L are absent, so
--          the squat-stiffness gate pcall-degrades to "not stiff")
--   [M]  Perks   42.19 naming verified against server/XpSystem/
--          XPSystem_SkillBook.lua: Carpentry=Woodwork, FirstAid=Doctor,
--          Foraging=PlantScavenging.  Perks.Literacy is intentionally ABSENT
--          (not in the verified record; doRead's illiterate fallback is what
--          the suites exercise).  The stale "Carpentry" alias was removed by
--          this audit so Perks.Carpentry resolves nil here, as in-game.
--          V4.1 (C6): Perks.Doctor is a production callsite
--          (AutoPilot_XP.sample at the Medical action site plus getPerkLevel
--          in Telemetry's schema-v4 doc field), riding surfaces already in
--          this record (no new mock surface); the sampling callsite is
--          asserted via a suite-local AutoPilot_XP recording stub in
--          test_medical_logic.  Perks.Woodwork was a production callsite in
--          V4.1-V4.9 and is NOT one any more (V5.0 removed barricading), but
--          it stays in this table because 42.19 really does define it: the
--          V5.0 scope guards assert the mod ignores a Woodwork perk that the
--          engine still offers.
--   [M]  IsoFlagType.bed
--   [M]  FitnessExercises.exercisesType   mirrors shared/Definitions/
--          FitnessExercises.lua including the V3.3 equipment item/prop fields
--   [G]  Fluid.Water / ItemType.LITERATURE / ItemTag.UNINTERESTING
--          all callsites pcall-guarded.  V4.9: ItemType.LITERATURE and
--          ItemTag.UNINTERESTING now have a SUITE-LOCAL definition in
--          test_container_search (the getReadable case needs the guarded
--          branch to succeed); the gap stands for every other suite.
--
-- MockPlayer surface (builder at the bottom of this file): getStats():get
-- plus the V3.2 engagement counters (getNumChasingZombies /
-- getNumVeryCloseZombies / getNumVisibleZombies), getMoodles():getMoodleLevel,
-- getBodyDamage():getBodyParts, getInventory() (getItems / contains /
-- getFirstTypeRecurse / getItemCount), getPerkLevel, getPlayerNum,
-- getX/getY/getZ, getCurrentSquare, getXp():getXP/:getMultiplier,
-- getHoursSurvived, getModData/transmitModData,
-- getFitness():init/:setCurrentExercise, tooDarkToRead, isDead/isAsleep,
-- getVehicle, setVariable, getPrimaryHandItem.
-- Intentionally ABSENT (every production callsite is pcall-guarded, so the
-- guarded fallback is what the suites exercise): getHealth, getNutrition,
-- HasTrait / getDescriptor():hasTrait, getBodyDamage():getBodyPart /
-- :getThermoregulator, getFitness():getRegularity.
-- ===========================================================================

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
-- Perks.Carpentry and Perks.Literacy are intentionally ABSENT: neither key
-- exists under the verified 42.19 naming, so lookups resolve nil here exactly
-- as in-game (the old "Carpentry" alias served AutoPilot_Skills, deleted V3.1).
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
        -- A nil action would make table.insert a silent no-op and let a test
        -- read the PREVIOUS queue entry as if it were new; fail loudly instead.
        assert(type(action) == "table",
            "ISTimedActionQueue.add expects an action table, got " .. type(action))
        table.insert(ISTimedActionQueue_calls, action)
    end,
    -- Real 42.19 static (ISTimedActionQueue.lua:219): stands the character up
    -- from any furniture, then queues the action.  Takes (character, action);
    -- a 1-arg call would previously have inserted nil silently; now it asserts.
    addGetUpAndThen = function(character, action)
        assert(type(character) == "table",
            "ISTimedActionQueue.addGetUpAndThen expects the character as 1st arg, got "
            .. type(character))
        assert(type(action) == "table",
            "ISTimedActionQueue.addGetUpAndThen expects an action table as 2nd arg, got "
            .. type(action))
        table.insert(ISTimedActionQueue_calls, action)
    end,
    clear = function(_) end,
    isPlayerDoingAction = function(_player) return false end,
    getTimedActionQueue = function(_player) return { queue = {} } end,
}

-- ── Timed-action constructors ─────────────────────────────────────────────────
-- (character, item, percentage); PZ routes drinks and the painkiller fallback
-- through this action too.
ISEatFoodAction = {
    new = function(_, player, item, _percentage)
        assert(item ~= nil, "ISEatFoodAction:new expects an item as 2nd arg")
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
    -- Equipment equip used before equipment exercises (ISFitnessUI.lua:245-262
    -- pattern): equip(character, currentItem, itemType, flag, twoHands).
    -- itemType is the full-type STRING ("Base.DumbBell"); twoHands is the
    -- boolean derived from the exercise prop ("twohands" vs "switch"/"primary").
    equip = function(_player, _current, itemType, _flag, twoHands)
        assert(type(itemType) == "string",
            "ISWorldObjectContextMenu.equip expects a full-type STRING as 3rd arg, got "
            .. type(itemType))
        assert(type(twoHands) == "boolean",
            "ISWorldObjectContextMenu.equip expects boolean twoHands as 5th arg, got "
            .. type(twoHands))
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

-- (character, patient, bandage, bodyPart, ...): the mod's self-treatment
-- call ISApplyBandage:new(player, player, bandage, bodyPart, true) shipped
-- unchanged through the V2.1 live-install sweep and the V3.2 re-verification.
-- AUDIT FIX (V3.4 PR2): the previous mock declared (character, bodyPart,
-- bandage), stale slots that silently received the PATIENT in the bodyPart
-- parameter.  Tests stayed green because they only inspect .type; the params
-- now mirror the verified callsite and assert on it.
-- Real 42.19 signature (shared/TimedActions/ISApplyBandage.lua:173, verified
-- 2026-07-20 against the live install): ISApplyBandage:new(character,
-- otherPlayer, item, bodyPart, doIt). doIt is not cosmetic: the constructor
-- stores it as self.doIt, and isValid()/perform() branch on it to decide
-- whether the action APPLIES the bandage or REMOVES it (line 39's UI label
-- literally toggles "Bandage" vs "Remove Bandage" on this flag). Found
-- unmocked and unasserted: the mock captured only 4 of the 5 constructor
-- params, so a 5th argument silently vanished (Lua truncates extra args
-- rather than erroring) and no test could have caught doIt ever being wrong
-- -- which would mean AutoPilot_Medical.doTreatWound queues a bandage
-- REMOVAL instead of an application, on a real wound, with a passing suite.
ISApplyBandage = {
    new = function(_, character, patient, bandage, bodyPart, doIt)
        assert(type(character) == "table",
            "ISApplyBandage:new expects the treating character as 1st arg, got "
            .. type(character))
        assert(type(patient) == "table",
            "ISApplyBandage:new expects the patient as 2nd arg, got "
            .. type(patient))
        assert(type(bandage) == "table",
            "ISApplyBandage:new expects the bandage item as 3rd arg, got "
            .. type(bandage))
        assert(type(doIt) == "boolean",
            "ISApplyBandage:new expects a boolean doIt as 5th arg, got "
            .. type(doIt) .. " (doIt=true applies the bandage; "
            .. "doIt=false/nil REMOVES it -- see ISApplyBandage.lua:39)")
        return { type = "bandage", bodyPart = bodyPart, bandage = bandage, doIt = doIt }
    end,
}

-- pathToSitOnFurniture(character, furniture, cb) walks the character to the
-- furniture AND seats them: it is the one recorded call that produces a
-- SEATED character, which is why V5.8 made it the furniture rest path's only
-- action.  The stub records the furniture it was handed (V5.8) so tests can
-- assert WHICH seat was chosen, and its type says "seated", not "walked".
ISPathFindAction = {
    pathToSitOnFurniture = function(_, player, furniture, _)
        -- Return a stub path-to-seat action; callbacks are ignored in tests.
        local action = { type = "sit_furniture", target = furniture }
        action.setOnComplete = function(self, ...) end
        action.setOnFail     = function(self, ...) end
        action.addAfter      = function(self, _) return nil end
        return action
    end,
}

-- Real 42.19 signature (shared/TimedActions/ISRestAction.lua:245):
-- ISRestAction:new(character, bed, useAnimations): exactly 3 args (the V2.1
-- phantom pass wrongly changed this; V3.2 restored the 3-arg form).  The mock
-- asserts the arity so a regrown 4th argument fails loudly here.
-- V5.8: the useAnimations argument is RECORDED on the returned stub.  The mod
-- passed nil for it through V5.7, i.e. a rest with its animations suppressed,
-- which is a rest performed standing up; tests assert on the value now rather
-- than only on the arity.
ISRestAction = {
    new = function(_, player, bed, useAnimations, ...)
        assert(type(player) == "table",
            "ISRestAction:new expects the character as 1st arg, got " .. type(player))
        assert(bed ~= nil, "ISRestAction:new expects a furniture object as 2nd arg")
        assert(select("#", ...) == 0,
            "ISRestAction:new takes exactly 3 args (character, bed, useAnimations)")
        return { type = "rest_furniture", target = bed,
                 useAnimations = useAnimations }
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

-- ── instanceof (V5.1) ─────────────────────────────────────────────────────────
-- The real PZ global performs a Java-level type check.  It matters here for
-- the reason V5.1 exists: calling a container-only method on an ordinary item
-- raises a Java exception that pcall does NOT stop PZ from logging, so
-- production code must type-check FIRST.  This mock models the two classes the
-- mod actually asks about:
--   "InventoryContainer"  true for MockContainer.bag items (they carry _container)
--   "HandWeapon"          true for items a suite marks with _isHandWeapon
-- Anything else is false, so a test that relies on an unmodelled class fails
-- loudly rather than silently passing.
function instanceof(item, className)
    if type(item) ~= "table" then return false end
    if className == "InventoryContainer" then
        return item._container ~= nil
    end
    if className == "HandWeapon" then
        return item._isHandWeapon == true
    end
    return false
end

-- ── Splitscreen player registry ───────────────────────────────────────────────
-- getSpecificPlayer(n) is the real B42 accessor (getPlayer() ignores args and
-- returns player 0).  Tests populate MockPlayers[n] as needed.
MockPlayers = {}

function getSpecificPlayer(n)
    assert(type(n) == "number",
        "getSpecificPlayer expects a numeric 0-based index, got " .. type(n))
    return MockPlayers[n]
end

-- ── File writer/reader (telemetry, death log) ─────────────────────────────────
-- Real signatures: getFileWriter(name, createIfNotExist, append) and
-- getFileReader(name, createIfNotExist) with reader:readLine()/close().
-- MockFiles captures truncate-vs-append behaviour so tests can verify the
-- telemetry log actually grows, and lets reader tests round-trip content.
MockFiles = {}

function getFileWriter(name, _create, append)
    assert(type(name) == "string",
        "getFileWriter expects a filename string, got " .. type(name))
    -- append=false TRUNCATES (the V2.1 one-line-log bug); an accidental nil
    -- would truncate in-game, so the flag must be an explicit boolean.
    assert(type(append) == "boolean",
        "getFileWriter expects an explicit boolean append flag, got " .. type(append))
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
    assert(type(name) == "string",
        "getFileReader expects a filename string, got " .. type(name))
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
-- getTotalXpForLevel is the ONLY method in the verified record; nothing else
-- is mocked so unverified PerkFactory calls fail loudly here (audit removed a
-- stray getXpForLevel that no module or suite used).
PerkFactory = {
    getPerk = function(_perk)
        return {
            getTotalXpForLevel = function(_self, level)
                return level * 100
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
-- Mirrors shared/Definitions/FitnessExercises.lua: equipment exercises carry
-- item (full type gated via inventory:contains) and prop (how it is held).
FitnessExercises = {
    exercisesType = {
        pushups       = { type = "pushups" },
        squats        = { type = "squats" },
        situp         = { type = "situp" },
        burpees       = { type = "burpees" },
        dumbbellpress = { type = "dumbbellpress", item = "Base.DumbBell",
                          prop = "switch" },
        bicepscurl    = { type = "bicepscurl", item = "Base.DumbBell",
                          prop = "switch" },
        barbellcurl   = { type = "barbellcurl", item = "Base.BarBell",
                          prop = "twohands" },
    },
}

-- ── Inventory containers (V4.8) ───────────────────────────────────────────────
-- Models the real B42 surface the mod's carried-inventory walk relies on:
--
--   ItemContainer:getItems()        -> ArrayList with size() / get(i)   (0-based)
--   InventoryItem:getItemContainer() -> ItemContainer, ONLY on bag items
--
-- A plain item deliberately does NOT define getItemContainer, exactly like a
-- non-container item in-game: the mod's pcall guard reads the missing method
-- as "not a container".  MockContainer.new doubles as a main-inventory mock
-- (it carries the same contains / getFirstTypeRecurse / getItemCount surface
-- the default MockPlayer inventory exposes), so tests can hand it straight to
-- player.getInventory.

MockContainer = {}

--- An ItemContainer holding `items` (a plain array of item tables).
function MockContainer.new(items)
    local arr = items or {}
    return {
        _items   = arr,
        getItems = function(_self)
            return {
                size = function(_s) return #arr end,
                get  = function(_s, i) return arr[i + 1] end,
            }
        end,
        add = function(_self, item)
            table.insert(arr, item)
            return item
        end,
        -- Recursive lookups (the exercise gate uses contains).  Defaults
        -- model "nothing found".
        contains            = function(_self, _fullType, _recurse) return false end,
        getFirstTypeRecurse = function(_self, _itemType) return nil end,
        getItemCount        = function(_self, _fullType, _recurse) return 0 end,
    }
end

--- A bag ITEM: an inventory item that itself carries a container.
--- `contents` is an array of items placed inside it.
function MockContainer.bag(name, contents)
    local inner = MockContainer.new(contents or {})
    return {
        _container       = inner,
        getType          = function(_self) return name end,
        getName          = function(_self) return name end,
        -- Bags are not food/weapons/bandages; selectors must skip them.
        isFood           = function(_self) return false end,
        isRotten         = function(_self) return false end,
        isCanBandage     = function(_self) return false end,
        getItemContainer = function(_self) return inner end,
    }
end

--- Use `container` as the player's main inventory.  Returns the player.
function MockContainer.attach(player, container)
    player.getInventory = function(_self) return container end
    return player
end

-- ── MockPlayer builder ────────────────────────────────────────────────────────
-- Creates a lightweight mock IsoPlayer with configurable state.
--
-- Parameters (all optional):
--   cfg.stats    table  CharacterStat key → value (0.0–1.0)
--   cfg.moodles  table  MoodleType key → integer level
--   cfg.perks    table  Perks key → integer level
--   cfg.bleeding bool   true if a body part is actively bleeding
--   cfg.dead / cfg.asleep          bool  isDead() / isAsleep() results
--   cfg.vehicle                    any   getVehicle() result (nil = on foot)
--   cfg.primaryHandItem            any   getPrimaryHandItem() result
--   cfg.numChasing / cfg.numVeryClose / cfg.numVisible
--                                  int   V3.2 engagement counters on Stats
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
        -- Engagement counters (real Stats surface; the V3.2 engagement gate in
        -- AutoPilot_Threat reads these, the same signals vanilla uses to gate
        -- sleeping).  Default 0 so mere radius presence is not danger.
        getNumChasingZombies   = function(self) return cfg.numChasing   or 0 end,
        getNumVeryCloseZombies = function(self) return cfg.numVeryClose or 0 end,
        getNumVisibleZombies   = function(self) return cfg.numVisible   or 0 end,
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
        -- Vanilla equipment-exercise gate; tests set cfg.hasItems or override.
        contains = function(self, _fullType, _recurse)
            return cfg.hasItems == true
        end,
        -- Recursive type/count lookups (V2.1-verified surface).  Retained
        -- after V5.0 removed their last production caller: they are real
        -- engine methods and the defaults model an empty inventory.
        getFirstTypeRecurse = function(self, _itemType) return nil end,
        getItemCount        = function(self, _fullType, _recurse) return 0 end,
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
        -- Real IsoPlayer surface previously missing here; pcall guards in
        -- production masked the divergence (calls failed in tests, succeeded
        -- in-game).  Defaults preserve the same observable behavior.
        isDead   = function(self) return cfg.dead   or false end,
        isAsleep = function(self) return cfg.asleep or false end,
        getVehicle = function(self) return cfg.vehicle end,
        getPrimaryHandItem = function(self) return cfg.primaryHandItem end,
        -- Sleep flow writes ExerciseStarted/ExerciseEnded (vanilla mirror);
        -- recorded so future bed-path tests can assert on them.
        setVariable = function(self, name, value)
            self._variables = self._variables or {}
            self._variables[name] = value
        end,
    }

    return player
end
