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
--   [S]  ISReadABook:new(character, book)   test_mood_during_rest.
--          Was "unexercised: doRead's literacy gate fails in the suites" until
--          2026-07-25, when that dead gate turned out to be a PRODUCTION bug
--          rather than a test-surface gap: doRead asked for a Perks.Literacy
--          SKILL level, which does not exist in 42.19 (see Perks below), so it
--          returned false in-game too.  It now reads the real trait via
--          hasTrait(CharacterTrait.ILLITERATE) and the suites reach the action.
--   [MA] ISRadioAction:new(mode, character, device, secondaryItem)
--          television/radio device action.  Real 42.19 signature verified live
--          at client/RadioCom/ISRadioAction.lua:173; the mode string is the
--          FIRST argument, not the character, and the engine dispatches on it
--          ("ToggleOnOff" -> performToggleOnOff, :43).  The mock asserts a
--          string first and a table third so a transposed call fails loudly
--          here instead of silently doing nothing in-game.  Exercised by
--          test_media_relief.
--   [MA] ISDryMyself:new(character, item)
--          the engine's own towel action, verified live at
--          shared/TimedActions/ISDryMyself.lua:112.  It is FINITE (duration
--          derived from the cloth's remaining uses, :104) and clears wetness
--          outright on :complete (:65), which is what makes it safe as an
--          AutoPilot arm.  Exercised by test_dry_off.
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
--   [MA] ISWorldObjectContextMenu.getBedQuality(playerObj, bed)
--          the engine's own bed-quality resolver (ISWorldObjectContextMenu.lua
--          :2917, verified live), the same call onSleepWalkToComplete makes at
--          line 1070 to score a sleep.  Returns "goodBed"/"averageBed"/"badBed"
--          /"floor", each optionally suffixed "Pillow".  V0.2:
--          AutoPilot_Sleep.bedComfort ranks candidate beds with it so the mod
--          and the engine agree on what "more comfortable" means.  PARTIAL:
--          the vehicle and tent branches are not modelled, and the engine's
--          scan for a pillow lying on the bed's sprite-grid squares is stood in
--          for by a `_pillow = true` field on a mock bed
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
--          Models "InventoryContainer" (bag items), "HandWeapon" and
--          "IsoWaveSignal" (world tv/radio, added 2026-07-25 with
--          AutoPilot_Media; the engine's own world-device menu tests for that
--          same parent class at ISRadioAndTvMenu.lua:7).  The
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
--   [M]  CharacterStat   HUNGER/THIRST/FATIGUE/ENDURANCE/PAIN/BOREDOM/SANITY/
--          PANIC/SICKNESS/STRESS (the last three were suite-local in
--          test_threat_logic until 2026-07-25; a suite-local enum key hides the
--          member from the enum-drift guard, so every member production reads
--          now lives here); safeStat degrades missing keys to 0 by design
--   [M]  MoodleType   ENDURANCE/UNHAPPY/PAIN/PANIC/HEAVY_LOAD/HUNGRY/THIRST/
--          STRESS
--          (PAIN and PANIC
--          added for AutoPilot_Sleep.canSleepNow, which mirrors the engine
--          sleep gate; HEAVY_LOAD for AutoPilot_Utils.hasCarryRoom, which
--          mirrors the vanilla fitness gate at ISFitnessUI.lua:219;
--          HUNGRY/THIRST for the V6.2 C1 moodle-aligned triggers, verified in
--          the jar constant pool — see the enum note below; STRESS for the
--          V6.3 C2-D4 read-arm trigger, verified in the install's own Lua at
--          ISReloadWeaponAction.lua:476;
--          getMoodleLevel returns 0 for any key a test does not set).  B42
--          spells these SCREAMING_SNAKE_CASE — modelling "Unhappy" here kept a
--          nil-in-game read looking alive in the suites until 2026-07-25
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
-- getFirstTypeRecurse / getItemCount / getCapacityWeight /
-- getEffectiveCapacity / hasRoomFor), getPerkLevel, getPlayerNum,
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
-- Every key here is a name the live 42.19 install actually uses; test_engine_symbols
-- asserts production code never reads one that is absent.
CharacterStat = {
    HUNGER    = "HUNGER",
    THIRST    = "THIRST",
    FATIGUE   = "FATIGUE",
    ENDURANCE = "ENDURANCE",
    PAIN      = "PAIN",
    BOREDOM   = "BOREDOM",
    SANITY    = "SANITY",
    -- Read by AutoPilot_Threat's NEGATIVE_STAT_CHECKS and by
    -- AutoPilot_Needs.getMoodleSnapshot.  These used to be added suite-locally
    -- by test_threat_logic, which hid them from the enum-drift guard; verified
    -- present in the live install (CharacterStat.PANIC, .SICKNESS and .STRESS
    -- all appear in media/lua) and modelled globally now.
    PANIC     = "PANIC",
    SICKNESS  = "SICKNESS",
    STRESS    = "STRESS",
    -- Read by AutoPilot_Comfort.wetness.  Verified present in the live install
    -- (client/ISUI/ISInventoryPaneContextMenu.lua:190,
    -- shared/TimedActions/ISDryMyself.lua:8).  SCALE: 0-100, not 0-1 --
    -- ISStatsAndBody.lua:75 registers it with an EXPLICIT slider step of 1, the
    -- marker every 0-100 stat there carries, while the 0.0-1.0 stats
    -- (STRESS/SICKNESS/SANITY) take addSliderOptionEnum's default step of 0.01.
    -- Suites therefore set this stat in 0-100 units, exactly as the game does.
    WETNESS   = "WETNESS",
}

-- ── CharacterStat SCALE record ────────────────────────────────────────────────
-- The scale each stat is measured on, machine-readable so a test can check it.
--
-- WHY THIS EXISTS.  test_engine_symbols guards that a stat member EXISTS.  It
-- cannot guard that production reads it on the right SCALE, and B42 mixes the
-- two: some CharacterStat members are 0.0-1.0 fractions, others are 0-100
-- integers, and safeStat returns whichever the engine holds without comment.
-- Comparing a 0-1 stat against a 0-100 threshold yields a gate that can never
-- fire; comparing a 0-100 stat against a 0-1 threshold yields one that always
-- fires.  Neither crashes, neither lints, and neither fails a suite whose
-- fixture happens to leave the stat at 0 -- exactly how three entries of
-- AutoPilot_Threat.NEGATIVE_STAT_CHECKS stayed wrong from the B42 port until
-- 2026-07-26.  tests/test_stat_scales.lua reads this table and the production
-- table together, so the two can no longer drift silently.
--
-- HOW EACH VALUE WAS ESTABLISHED, against the live 42.19 install:
--
--   * The debug stat editor is the enumerating source.  In
--     client/DebugUIs/DebugMenu/General/ISStatsAndBody.lua every stat is
--     registered with addSliderOptionEnum(stat [, step]); the helper (:153-164)
--     defaults `step` to 0.01 and takes min/max from the Java enum itself.
--     Every stat that really is a 0-100 integer is registered with an EXPLICIT
--     step of 1 (PAIN :53, PANIC :55, BOREDOM :65, UNHAPPINESS :69,
--     DISCOMFORT :73, WETNESS :75, ZOMBIE_INFECTION/:87 ZOMBIE_FEVER :89,
--     FOOD_SICKNESS :91, INTOXICATION :49, POISON :103); every 0.0-1.0 stat
--     takes the default (HUNGER :35, THIRST :39, FATIGUE :41, ENDURANCE :43,
--     STRESS :59, SANITY :71, SICKNESS :85).
--   * Corroborated independently for the three that were wrong in this mod:
--     - SICKNESS: shared/Foraging/forageSystem.lua:1741-1746 (getBodyPenalty)
--       reads SICKNESS UNDIVIDED while dividing PAIN, FOOD_SICKNESS and
--       INTOXICATION by 100 on the adjacent lines, then math.max-es all four
--       into a 0-1 penalty.  And shared/TimedActions/ISDrinkFromBottle.lua:88
--       compares `stats:getSickness() < 0.3` on the same line as
--       `stats:get(CharacterStat.POISON) < 20`.
--     - STRESS: forageSystem.lua:1762-1768 (getPanicPenalty) divides PANIC by
--       100 and does NOT divide STRESS, then math.max-es the two.
--     - SANITY: default slider step, and no other Lua consumer exists in the
--       whole install (a grep of media/lua for CharacterStat.SANITY returns the
--       single ISStatsAndBody registration).  This mod's own in-game
--       observation is recorded at AutoPilot_Needs.doMoodRelief: sanity reads
--       HIGH when healthy, so it is polarity-inverted relative to every other
--       entry here and cannot be used with a `>=` "this is bad" threshold.
--
-- Adding a CharacterStat member therefore has TWO costs, not one: verify the
-- name against the install (test_engine_symbols) and record its scale here
-- (test_stat_scales).  Suites set fixture values in these units.
CharacterStatScale = {
    HUNGER    = "0-1",
    THIRST    = "0-1",
    FATIGUE   = "0-1",
    ENDURANCE = "0-1",
    SICKNESS  = "0-1",
    STRESS    = "0-1",
    SANITY    = "0-1",
    PAIN      = "0-100",
    PANIC     = "0-100",
    BOREDOM   = "0-100",
    WETNESS   = "0-100",
}

-- ── MoodleType enum ───────────────────────────────────────────────────────────
-- B42 names every MoodleType constant in SCREAMING_SNAKE_CASE.  Verified live in
-- the 42.19 install: MoodleType.UNHAPPY and .DRUNK at
-- shared/TimedActions/ISBaseTimedAction.lua:102-105, .ENDURANCE/.HEAVY_LOAD/.PAIN
-- at client/ISUI/ISFitnessUI.lua:215-234, .PAIN/.PANIC at
-- client/ISUI/ISWorldObjectContextMenu.lua:1054-1058, .FOOD_EATEN at
-- shared/TimedActions/ISEatFoodAction.lua:14.  A whole-install grep of media/lua
-- finds no CamelCase MoodleType constant at all — only the TRANSLATION keys
-- (Moodles_Unhappy_lvl1..4) keep the old spelling, and those are not the enum.
-- This mock previously modelled "Unhappy", a name the engine does not have, so
-- AutoPilot_Needs read nil in-game while the suites read a live moodle.
MoodleType = {
    ENDURANCE = "ENDURANCE",
    UNHAPPY   = "UNHAPPY",
    -- Real engine moodle types read by the sleep gate
    -- (ISWorldObjectContextMenu.onSleepWalkToComplete); AutoPilot_Sleep.canSleepNow
    -- mirrors that gate, so tests set these to drive it.
    PAIN      = "PAIN",
    PANIC     = "PANIC",
    -- Read by AutoPilot_Utils.hasCarryRoom: the engine's own verdict on "the
    -- character is carrying too much".  Verified live at
    -- client/ISUI/ISFitnessUI.lua:219, which disables the vanilla fitness OK
    -- button (Tooltip_TooHeavyFitness) at level > 2 — i.e. vanilla will not let
    -- an overloaded character exercise, which is this mod's main job.
    HEAVY_LOAD = "HEAVY_LOAD",
    -- V6.2 C1 (moodle-aligned hunger/thirst triggers): neither name appears in
    -- the install's LUA at all, so these two were verified one level deeper
    -- than the members above — read straight out of the 42.19 jar's constant
    -- pool (python zipfile over projectzomboid.jar ->
    -- zombie/scripting/objects/MoodleType.class: ... TIRED, HUNGRY, PANIC,
    -- SICK, BORED, UNHAPPY, ... STRESS, THIRST, INJURED, PAIN, HEAVY_LOAD ...;
    -- re-verified live 2026-08-04).  Same enum that provides every member
    -- above, all five of which behave in-game.  Note the asymmetric spelling
    -- is the engine's own: HUNGRY but THIRST, not HUNGER/THIRSTY.
    HUNGRY = "HUNGRY",
    THIRST = "THIRST",
    -- V6.3 C2-D4 (the stress trigger on the read arm).  Unlike HUNGRY/THIRST
    -- this one IS present in the install's Lua -- MoodlesUI.getInstance():wiggle(
    -- MoodleType.STRESS) at shared/TimedActions/ISReloadWeaponAction.lua:476 --
    -- and it is the same constant-pool member the note above already lists
    -- ("... SICK, BORED, UNHAPPY, ... STRESS, THIRST, INJURED ...").
    STRESS = "STRESS",
}

-- ── CharacterTrait enum ───────────────────────────────────────────────────────
-- [MA] CharacterTrait.ILLITERATE, read via character:hasTrait(...).  This is
-- the engine's REAL literacy gate: verified live in the 42.19 install at
-- client/ISUI/ISInventoryPaneContextMenu.lua:549 plus nine sibling callsites
-- (ISInventoryPane.lua:1102, ISWorldMapSymbols.lua:1312, ...).  CharacterTrait
-- is Java-bound, so there is no Lua definition to compare field-by-field; only
-- the member this mod reads is modelled.  PARTIAL: every other trait constant
-- is unmodelled, and hasTrait here answers only from cfg.traits.
CharacterTrait = {
    ILLITERATE = "Illiterate",
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
-- Literacy is not a skill in this build AT ALL: a whole-install grep of
-- media/lua for "Literacy" returns zero hits.  Reading is gated by the
-- ILLITERATE TRAIT instead (see CharacterTrait above).  Keeping this key absent
-- is what finally exposed the production bug in doRead, which had been asking
-- for a perk level that could never exist (fixed 2026-07-25).
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
    -- Real 42.19 surface (client/ISUI/ISWorldObjectContextMenu.lua:2917,
    -- verified live): getBedQuality(playerObj, bed) returns the engine's own
    -- bed-quality string.  Modelled here are exactly the two branches
    -- AutoPilot_Sleep.bedComfort rides: a nil bed is "floor", and a bed resolves
    -- through its BedType property defaulting to "averageBed" (the engine's own
    -- line 2958).  The vehicle and tent branches are NOT modelled, and the
    -- engine's pillow scan over the bed's sprite-grid squares is stood in for by
    -- a `_pillow = true` field on the mock bed.
    getBedQuality = function(playerObj, bed)
        assert(type(playerObj) == "table",
            "getBedQuality expects the player object as 1st arg, got "
            .. type(playerObj))
        if not bed then return "floor" end
        local bedType = "averageBed"
        local ok, prop = pcall(function()
            return bed:getProperties():get("BedType")
        end)
        if ok and type(prop) == "string" then bedType = prop end
        if bed._pillow then return bedType .. "Pillow" end
        return bedType
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

-- Real 42.19 signature (client/RadioCom/ISRadioAction.lua:173):
--   ISRadioAction:new(mode, character, device, secondaryItem)
-- The engine dispatches on `mode` (self["perform"..self.mode]), so a call that
-- transposes mode and character does nothing at all in-game while still
-- constructing a perfectly valid-looking action object.  Assert the slots.
ISRadioAction = {
    new = function(_, mode, character, device, secondaryItem)
        assert(type(mode) == "string",
            "ISRadioAction:new expects the mode string first (got "
            .. type(mode) .. ")")
        assert(type(device) == "table",
            "ISRadioAction:new expects the device object third (got "
            .. type(device) .. ")")
        return {
            type      = "radio",
            mode      = mode,
            character = character,
            device    = device,
            secondary = secondaryItem,
        }
    end,
}

-- Real 42.19 signature (shared/TimedActions/ISDryMyself.lua:112):
--   ISDryMyself:new(character, item)
-- The item is a BathTowel or DishCloth and is CONSUMED: :update consumes uses
-- and force-stops when they run out, :complete calls
-- decreaseBodyWetness(WETNESS) for a full clear.  isValid additionally requires
-- the item to be in the character's own inventory, which is why both the
-- engine's menu path (ISInventoryPaneContextMenu.dryMyself, :2758) and
-- AutoPilot_Comfort transfer it to the main inventory first.  Asserting the
-- item catches a transposed call here rather than in-game.
ISDryMyself = {
    new = function(_, character, item)
        assert(item ~= nil, "ISDryMyself:new expects the cloth as 2nd arg")
        return { type = "dry", character = character, item = item }
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
    pathToSitOnFurniture = function(_, player, furniture, _anyGrid)
        -- Stub path-to-seat action.  It exposes goalFurnitureObject (the furniture
        -- the pathfinder resolved) and RECORDS setOnComplete so a test can fire the
        -- ISRestAction chaser the mod binds (AutoPilot_Rest._seatAfterPath), which
        -- is what actually seats the character per the engine.
        local action = { type = "sit_furniture", target = furniture,
                         goalFurnitureObject = furniture }
        action.setOnComplete = function(self, fn, ...) self.onComplete = { fn = fn, args = { ... } } end
        action.setOnFail     = function(self, ...) end
        action.addAfter      = function(self, _) return nil end
        return action
    end,
}

-- SeatingManager: the engine's registry of sit positions per furniture object.
-- AutoPilot_Rest.findRestFurniture prefers furniture the character can actually
-- sit on (getTilePositionCount > 0).  Mock furniture carries an _seatData count
-- (see mockFurniture in the test files); a test sets seatData=false for a dining
-- chair the engine has no sit data for.
SeatingManager = {
    getInstance = function()
        return {
            getTilePositionCount = function(_self, obj)
                return (obj and obj._seatData) or 0
            end,
        }
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
    -- "IsoWaveSignal" is the engine's parent class for world televisions AND
    -- radios; it is the exact class the engine's own world-device menu tests
    -- for (client/ISUI/ISRadioAndTvMenu.lua:7), which is why AutoPilot_Media
    -- asks about it rather than about "IsoRadio".
    if className == "IsoWaveSignal" then
        return item._isWaveSignal == true
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
    -- V6.0-3: settable decision-reason read side (mirrors the _pendingLabel
    -- pattern test_main_logic uses for getPendingAction).  Suites that never
    -- set _reasonLabel keep the pre-V6 "" and render the plain action string.
    _reasonLabel = nil,
    getDecisionReason = function(_player)
        return AutoPilot_Telemetry._reasonLabel or ""
    end,
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

-- Game-speed multiplier: an ARBITRARY POSITIVE NUMBER, 1 at normal speed.  This
-- comment claimed *"1 = normal, 5/20/40 = fast-forward x1/x2/x3"* until
-- 2026-08-10; those three values are only SpeedControlsHandler's keyboard
-- buttons (client/ISUI/SpeedControlsHandler.lua:28-40).  setMultiplier also
-- takes FRACTIONS -- the engine's debug panel binds a 0..1000 slider with step
-- 0.1 to it (client/DebugUIs/DebugMenu/General/ISGameDebugPanel.lua:42) -- and
-- auto_pilot_run.log records 1, 4, 9..20, 23, 30..33, 80 and 100.  The setter
-- deliberately passes the value through UNCHANGED (no rounding, no clamp) so a
-- test can reach the values the buttons cannot; the 5/20/40 belief is exactly
-- what left AutoPilot_Telemetry formatting it with %d.  Default 1 so existing
-- tests are unaffected; a test calls MockGameSpeed.set(m) to simulate
-- fast-forward and exercise the FF-aware evaluation cadence in AutoPilot_Main.
local _mockGameSpeed = 1

-- Game-speed INDEX, a SEPARATE engine number from the multiplier above:
-- 0 paused, 1 normal, 2/3/4 the three fast-forward steps.  getGameSpeed() /
-- setGameSpeed() are real 42.19 client globals (the engine calls them bare at
-- client/TimedActions/WalkToTimedAction.lua:7 and
-- client/Vehicles/ISUI/ISVehicleDashboard.lua:503-504), and the walk gate the
-- mod now honours reads the INDEX, never the multiplier -- so a test that only
-- set the multiplier would exercise nothing.  Default 1 (normal) so every
-- existing suite is unaffected.
local _mockGameSpeedIndex = 1

MockGameSpeed = {
    set      = function(m) _mockGameSpeed = m end,
    setIndex = function(i) _mockGameSpeedIndex = i end,
    getIndex = function() return _mockGameSpeedIndex end,
}

function getGameSpeed()
    return _mockGameSpeedIndex
end

function setGameSpeed(i)
    _mockGameSpeedIndex = i
end

local _mockGameTimeInstance = {
    getCalender = function(self) return _mockCalender end,
    getDay      = function(self) return 1 end,
    getMultiplier = function(self) return _mockGameSpeed end,
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
--
-- xpMod added 2026-08-11 (V6.3 C1): the auto pool is now DERIVED from this
-- table rather than hardcoded, so the field the derivation orders by has to be
-- mirrored or every exercise would look equally rewarding here.  Values read
-- live out of the 42.19 install at
-- media/lua/shared/Definitions/FitnessExercises.lua rather than invented --
-- verified-surface discipline: the field is confirmed present in the install,
-- and burpees' 0.8 carries vanilla's own explanation ("few less xp as it gives
-- xp for 3 body parts"), which is exactly why the mod promotes it anyway.
-- The remaining vanilla fields (name, tooltip, stiffness, metabolics) stay out
-- because no mod code reads them.
FitnessExercises = {
    exercisesType = {
        pushups       = { type = "pushups", xpMod = 1 },
        squats        = { type = "squats", xpMod = 1 },
        situp         = { type = "situp", xpMod = 1 },
        burpees       = { type = "burpees", xpMod = 0.8 },
        dumbbellpress = { type = "dumbbellpress", item = "Base.DumbBell",
                          prop = "switch", xpMod = 1.8 },
        bicepscurl    = { type = "bicepscurl", item = "Base.DumbBell",
                          prop = "switch", xpMod = 1.8 },
        barbellcurl   = { type = "barbellcurl", item = "Base.BarBell",
                          prop = "twohands", xpMod = 1.2 },
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
--- `cap` is an optional carry-capacity config for the Heavy Load gate:
---   cap.carried   number  current getCapacityWeight()      (default 0)
---   cap.capacity  number  getEffectiveCapacity(character)  (default 50)
---   cap.hasRoom   boolean forced hasRoomFor() answer       (default computed)
--- Defaults model an empty pack with room to spare, so every suite written
--- before the gate existed keeps looting exactly as it did.
function MockContainer.new(items, cap)
    local arr = items or {}
    cap = cap or {}
    return {
        _items   = arr,
        getItems = function(_self)
            return {
                size = function(_s) return #arr end,
                get  = function(_s, i) return arr[i + 1] end,
            }
        end,
        -- ── Carry-capacity surface (verified live in the 42.19 install) ──
        -- ItemContainer:getCapacityWeight() and :getEffectiveCapacity(chr) are
        -- the pair the engine itself compares to decide a character is
        -- overloaded: shared/ActionManager.lua:11 drops a picked-up item on the
        -- ground when getCapacityWeight() > getEffectiveCapacity(character),
        -- and client/Foraging/ISBaseIcon.lua:105 uses the same comparison as
        -- its "player inventory has space" test.
        getCapacityWeight    = function(_self) return cap.carried or 0 end,
        getEffectiveCapacity = function(_self, _chr) return cap.capacity or 50 end,
        -- ItemContainer:hasRoomFor(character, item) — the engine's per-item
        -- capacity test, used by the foraging pickup menu at
        -- client/Foraging/ISBaseIcon.lua:127 and by the inventory pane at
        -- client/ISUI/ISInventoryPane.lua:2057.  It is overloaded in the engine
        -- (a raw weight is also accepted: ISWorldObjectContextMenu.lua:1298).
        hasRoomFor = function(_self, _chr, item)
            if cap.hasRoom ~= nil then return cap.hasRoom end
            local w = 0
            pcall(function() w = item:getActualWeight() or 0 end)
            return ((cap.carried or 0) + w) <= (cap.capacity or 50)
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
--   cfg.stats    table  CharacterStat key → value, in that stat's OWN units.
--                       B42 mixes two scales and so does this mock: see
--                       CharacterStatScale above for which member is a 0.0-1.0
--                       fraction (HUNGER/THIRST/FATIGUE/ENDURANCE/SICKNESS/
--                       STRESS/SANITY) and which is a 0-100 integer
--                       (PAIN/PANIC/BOREDOM/WETNESS).  Setting one in the wrong
--                       units yields a fixture that silently exercises nothing.
--   cfg.moodles  table  MoodleType key → integer level
--   cfg.perks    table  Perks key → integer level
--   cfg.traits   table  CharacterTrait value → true (e.g. { Illiterate = true })
--   cfg.tooDark  bool   tooDarkToRead() result (default false)
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
--       moodles = { ENDURANCE = 0, UNHAPPY = 0 },
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
        -- Carry-capacity surface, same engine citations as MockContainer.new
        -- above (ActionManager.lua:11, ISBaseIcon.lua:105/127).  Defaults model
        -- an unencumbered character: cfg.carriedWeight / cfg.carryCapacity /
        -- cfg.hasRoom drive AutoPilot_Utils.hasCarryRoom.
        getCapacityWeight    = function(self) return cfg.carriedWeight or 0 end,
        getEffectiveCapacity = function(self, _chr) return cfg.carryCapacity or 50 end,
        hasRoomFor = function(self, _chr, item)
            if cfg.hasRoom ~= nil then return cfg.hasRoom end
            local w = 0
            pcall(function() w = item:getActualWeight() or 0 end)
            return ((cfg.carriedWeight or 0) + w) <= (cfg.carryCapacity or 50)
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
        -- Real engine API read by AutoPilot_Sleep.canSleepNow: a strong sleeping
        -- tablet effect (>= 2000) bypasses the pain/panic sleep gate.  Default 0.
        getSleepingTabletEffect = function(self) return cfg.sleepingTablet or 0 end,
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
        tooDarkToRead = function(self) return cfg.tooDark or false end,
        -- [MA] hasTrait(CharacterTrait.X): the engine's real literacy gate,
        -- verified live (ISInventoryPaneContextMenu.lua:549).  Answers from
        -- cfg.traits, so a test opts a character into Illiterate with
        -- traits = { Illiterate = true }.  Default: no traits, i.e. literate.
        hasTrait = function(self, trait)
            return (cfg.traits or {})[trait] == true
        end,
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
