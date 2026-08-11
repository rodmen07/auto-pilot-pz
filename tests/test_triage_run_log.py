"""Unit tests for triage_run_log.py - run-log parser and triage summarizer.

The main fixture (tests/fixtures/run_log_v2_sample.log) is a synthetic
schema_version=2 excerpt matching the line format AutoPilot_Telemetry.logTick
wrote before V4.1: two sessions for player 0, the first ending in a death
marker, the second still open.  Field order, empty stage=/fail_reason=
values, and the class=idle fall-through for scavenge/barricade all mirror the
real writer.  V4.1 emitted schema_version=3, appending wood= and doc=
(Woodwork / Doctor perk levels) after fit=.  V5.0 removed barricading and
emits schema_version=4, which drops wood= again.  The v2 fixtures stay as the
backward-compat control (old logs must keep parsing) and the v3/v4 variants
are covered inline in TestSchemaV3WoodDoc and TestSchemaV4NoWood.

A second fixture (tests/fixtures/run_log_v2_suspicious.log) is a five-session
log written so each session trips exactly one suspicious-pattern detector: a
45-tick exercise streak, a 32-tick zero-XP training loop, a combat-bandage
oscillation with 4 re-entries, a 16-tick empty-loot scavenge spiral, and (added
2026-08-07) a 30-tick flee stall of 6 flee decisions with no evade_running
tick.  The zero-XP detector was RETIRED 2026-07-26 (see the tombstone note in
TestSuspiciousPatterns), so session 2 now doubles as a below-threshold training
control: 32 exercise ticks must NOT trip the streak detector.  Session 5 is
deliberately 30 ticks, under STREAK_MIN_TICKS (40), so it cannot also trip the
streak detector.  It stays schema v2 like the rest of the file (the
backward-compat control), which also exercises the detector's "speed not
recorded" branch; the v5 speed field is covered inline in
TestFleeStallDetector, the way TestSchemaV3WoodDoc covers v3-only fields.  The
main fixture doubles as the clean control: no detector may fire on it.
"""

from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

import triage_run_log as tr

FIXTURE = Path(__file__).parent / "fixtures" / "run_log_v2_sample.log"
FIXTURE_SUSPICIOUS = (Path(__file__).parent / "fixtures"
                      / "run_log_v2_suspicious.log")


# ── Helper ────────────────────────────────────────────────────────────────────

def _write_log(directory: str, lines: list[str]) -> Path:
    p = Path(directory) / "run.log"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


# ── parse_run_log tests ───────────────────────────────────────────────────────

class TestParseRunLog(unittest.TestCase):

    def test_missing_file_returns_empty(self) -> None:
        entries, skipped = tr.parse_run_log("does_not_exist.log")
        self.assertEqual(entries, [])
        self.assertEqual(skipped, 0)

    def test_empty_file_returns_empty(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "run.log"
            log.write_text("", encoding="utf-8")
            entries, skipped = tr.parse_run_log(log)
        self.assertEqual(entries, [])
        self.assertEqual(skipped, 0)

    def test_v5_speed_field_parses_as_int(self) -> None:
        # schema v5 (2026-07-24) adds `speed` = the real game multiplier, an
        # arbitrary positive integer in the log (this comment said *"1 normal,
        # 5/20/40 fast-forward"* until 2026-08-10; the mod floors the engine's
        # float before writing it -- AutoPilot_Telemetry.lua). It coerces to
        # int; `ff` stays a separate zombie-presence string, and later fields
        # still parse.
        line = (
            "schema_version=5,player=0,mode=autopilot,ff=normal,speed=20,"
            "run_tick=7,action=idle,reason=no_action,class=idle,stage=,"
            "fail_reason=,retry_count=0,hunger=10,thirst=10,fatigue=10,"
            "endurance=90,zombies=0,bleeding=0,str=5,fit=4,doc=0"
        )
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "run.log"
            log.write_text(line + "\n", encoding="utf-8")
            entries, skipped = tr.parse_run_log(log)
        self.assertEqual(skipped, 0)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["speed"], 20)     # coerced to int
        self.assertEqual(entries[0]["ff"], "normal")  # separate zombie flag
        self.assertEqual(entries[0]["run_tick"], 7)   # fields after speed parse

    def test_fixture_parses_all_lines(self) -> None:
        entries, skipped = tr.parse_run_log(FIXTURE)
        self.assertEqual(len(entries), 20)
        self.assertEqual(skipped, 0)

    def test_fixture_fields_parsed_correctly(self) -> None:
        entries, _ = tr.parse_run_log(FIXTURE)
        e = entries[0]
        self.assertEqual(e["schema_version"], 2)
        self.assertEqual(e["player"],      0)
        self.assertEqual(e["mode"],        "autopilot")
        self.assertEqual(e["ff"],          "normal")
        self.assertEqual(e["run_tick"],    1)
        self.assertEqual(e["action"],      "idle")
        self.assertEqual(e["reason"],      "no_action")
        self.assertEqual(e["class"],       "idle")
        self.assertEqual(e["stage"],       "")
        self.assertEqual(e["fail_reason"], "")
        self.assertEqual(e["retry_count"], 0)
        self.assertEqual(e["hunger"],      10)
        self.assertEqual(e["thirst"],      8)
        self.assertEqual(e["fatigue"],     12)
        self.assertEqual(e["endurance"],   95)
        self.assertEqual(e["zombies"],     0)
        self.assertEqual(e["bleeding"],    0)
        self.assertEqual(e["str"],         2)
        self.assertEqual(e["fit"],         3)

    def test_scavenge_line_carries_class_idle(self) -> None:
        """This v2 fixture predates PR #19, so its scavenge line carries the
        pre-fix class=idle value verbatim; the parser must not reinterpret
        it. The LIVE Lua REASON_CLASS table has classified scavenge as
        class=survival since PR #19 — this test is about historical-log
        parsing fidelity, not current runtime behavior."""
        entries, _ = tr.parse_run_log(FIXTURE)
        scavenge = [e for e in entries if e["action"] == "scavenge"]
        self.assertEqual(len(scavenge), 1)
        self.assertEqual(scavenge[0]["class"], "idle")

    def test_tolerates_malformed_and_truncated_lines(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "not_a_kv_line",
                # Truncated write missing action / run_tick entirely
                "schema_version=2,player=0,mode=autopil",
                # Valid line in the real v2 format
                "schema_version=2,player=0,mode=autopilot,ff=normal,run_tick=1,"
                "action=idle,reason=no_action,class=idle,stage=,fail_reason=,"
                "retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=90,"
                "zombies=0,bleeding=0,str=1,fit=1",
                # run_tick present but not numeric -> skipped
                "run_tick=abc,action=eat",
                "",
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["action"], "idle")
        self.assertEqual(skipped, 3)

    def test_lua_diagnostic_comments_are_ignored_not_skipped(self) -> None:
        """V5.5: AutoPilot_Options writes '#' diagnostics into this same log.

        They are comments, not damaged telemetry, so they must neither parse
        as entries nor inflate the skipped counter that signals a corrupt log.
        """
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "# AutoPilot V5.5: PZAPI.ModOptions never became available;"
                " the in-game mod options page did NOT register.",
                "schema_version=4,player=0,mode=autopilot,ff=normal,run_tick=1,"
                "action=idle,reason=no_action,class=idle,stage=,fail_reason=,"
                "retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=90,"
                "zombies=0,bleeding=0,str=1,fit=1,doc=0",
                "#another diagnostic",
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["action"], "idle")
        self.assertEqual(skipped, 0)

    def test_truncated_tail_with_action_still_parses(self) -> None:
        """A line cut off mid-write keeps its parsed prefix fields."""
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                "schema_version=2,player=0,mode=autopilot,ff=normal,run_tick=3,"
                "action=eat,reason=hun",
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["action"], "eat")
        self.assertEqual(entries[0]["run_tick"], 3)
        self.assertEqual(skipped, 0)


# ── Schema v3/v4 wood/doc tolerance tests ─────────────────────────────────────

V3_LINE = (
    "schema_version=3,player=0,mode=autopilot,ff=normal,run_tick={tick},"
    "action={action},reason=maintenance,class=idle,stage=,fail_reason=,"
    "retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=90,"
    "zombies=0,bleeding=0,str=1,fit=2,wood=4,doc=3"
)

# V5.0 removed barricading and with it the wood= field: the writer emits
# schema_version=4 lines ending str,fit,doc.  Same shape otherwise.
V4_LINE = (
    "schema_version=4,player=0,mode=autopilot,ff=normal,run_tick={tick},"
    "action={action},reason=maintenance,class=idle,stage=,fail_reason=,"
    "retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=90,"
    "zombies=0,bleeding=0,str=1,fit=2,doc=3"
)


class TestSchemaV3WoodDoc(unittest.TestCase):
    """V4.1 telemetry appends wood=/doc= after fit=; parsing must be tolerant
    in both directions: v3 lines coerce the new ints, v2 lines without them
    still parse."""

    def test_v3_line_parses_wood_doc_as_ints(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                V3_LINE.format(tick=1, action="barricade"),
                V3_LINE.format(tick=2, action="bandage"),
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 2)
        self.assertEqual(skipped, 0)
        e = entries[0]
        self.assertEqual(e["schema_version"], 3)
        self.assertEqual(e["wood"], 4)
        self.assertEqual(e["doc"], 3)
        self.assertIsInstance(e["wood"], int)
        self.assertIsInstance(e["doc"], int)

    def test_v2_fixture_lacks_wood_doc_but_parses(self) -> None:
        """The legacy fixture has no wood/doc keys and must stay parseable."""
        entries, skipped = tr.parse_run_log(FIXTURE)
        self.assertEqual(skipped, 0)
        self.assertTrue(entries)
        self.assertNotIn("wood", entries[0])
        self.assertNotIn("doc", entries[0])

    def test_v3_entries_summarize_without_error(self) -> None:
        """Extra v3 fields ride through summarize/format_report untouched."""
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                V3_LINE.format(tick=1, action="barricade"),
                V3_LINE.format(tick=2, action="exercise"),
            ])
            entries, skipped = tr.parse_run_log(log)
        summary = tr.summarize(entries, skipped)
        self.assertEqual(summary.total_ticks, 2)
        self.assertEqual(summary.action_counts.get("barricade"), 1)
        report = tr.format_report(summary)
        self.assertIn("Parsed 2 tick(s)", report)

    def test_mixed_v2_v3_log_parses_both(self) -> None:
        """A log spanning the V4.1 upgrade mixes v2 and v3 lines."""
        v2_line = (
            "schema_version=2,player=0,mode=autopilot,ff=normal,run_tick=1,"
            "action=idle,reason=no_action,class=idle,stage=,fail_reason=,"
            "retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=90,"
            "zombies=0,bleeding=0,str=1,fit=1"
        )
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                v2_line,
                V3_LINE.format(tick=2, action="barricade"),
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 2)
        self.assertEqual(skipped, 0)
        self.assertNotIn("wood", entries[0])
        self.assertEqual(entries[1]["wood"], 4)


class TestSchemaV4NoWood(unittest.TestCase):
    """V5.0 drops wood= (schema_version=4).  This is the first NON-additive
    telemetry change, so it is the one that needs empirical proof: the user's
    real ~2.6MB v3 log must keep parsing verbatim alongside new v4 lines.

    The parser is key=value based and requires only action and run_tick, and
    "wood" is coerced when present but never consumed, which is exactly why
    dropping the field is safe rather than merely convenient."""

    def test_v4_line_parses_without_wood(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                V4_LINE.format(tick=1, action="exercise"),
                V4_LINE.format(tick=2, action="bandage"),
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 2)
        self.assertEqual(skipped, 0)
        e = entries[0]
        self.assertEqual(e["schema_version"], 4)
        self.assertNotIn("wood", e)
        self.assertEqual(e["doc"], 3)
        self.assertEqual(e["fit"], 2)

    def test_v3_with_wood_and_v4_without_both_parse(self) -> None:
        """The upgrade boundary: one file, a v3 line carrying wood= and a v4
        line without it, both parsed and both counted."""
        with tempfile.TemporaryDirectory() as td:
            log = _write_log(td, [
                V3_LINE.format(tick=1, action="barricade"),
                V4_LINE.format(tick=2, action="exercise"),
            ])
            entries, skipped = tr.parse_run_log(log)

        self.assertEqual(len(entries), 2)
        self.assertEqual(skipped, 0)
        self.assertEqual(entries[0]["schema_version"], 3)
        self.assertEqual(entries[0]["wood"], 4)
        self.assertIsInstance(entries[0]["wood"], int)
        self.assertEqual(entries[1]["schema_version"], 4)
        self.assertNotIn("wood", entries[1])

        summary = tr.summarize(entries, skipped)
        self.assertEqual(summary.total_ticks, 2)
        # The retired barricade label still triages as base upkeep, so a
        # historical log does not silently lose ticks to "idle".
        self.assertEqual(summary.action_counts.get("barricade"), 1)
        self.assertEqual(summary.category_counts.get("survival"), 1)
        self.assertEqual(summary.category_counts.get("training"), 1)
        self.assertIn("Parsed 2 tick(s)", tr.format_report(summary))

    def test_retired_barricade_label_still_categorized(self) -> None:
        """triage reads HISTORICAL logs, so ACTION_CATEGORY keeps barricade
        even though the runtime no longer emits it (unlike benchmark's
        sync-guarded _ACTION_CLASS_MAP, which had to drop it)."""
        self.assertEqual(tr.categorize_action("barricade"), "survival")


# ── Category mapping tests ────────────────────────────────────────────────────

class TestCategoryMapping(unittest.TestCase):

    def test_training_category(self) -> None:
        self.assertEqual(tr.categorize_action("exercise"), "training")

    def test_resting_category(self) -> None:
        self.assertEqual(tr.categorize_action("sleep"), "resting")
        self.assertEqual(tr.categorize_action("rest"),  "resting")

    def test_survival_category(self) -> None:
        for action in ("eat", "drink", "shelter", "bandage", "clothing",
                       "scavenge", "barricade", "combat", "flee"):
            self.assertEqual(tr.categorize_action(action), "survival", action)

    def test_idle_category(self) -> None:
        for action in ("idle", "busy", "cooldown", "blocked", "dead"):
            self.assertEqual(tr.categorize_action(action), "idle", action)

    def test_unknown_action_maps_to_idle(self) -> None:
        self.assertEqual(tr.categorize_action("unknown_action_xyz"), "idle")

    def test_every_live_lua_action_label_is_categorized(self) -> None:
        """Every label the RUNTIME can emit must be known to this map.

        Drift guard reading BOTH sources rather than a hand-kept list: the Lua
        REASON_CLASS table in AutoPilot_Telemetry.lua is the writer, this map is
        the reader, and an unknown label silently falls through to "idle" -- so a
        brand-new behaviour is triaged as the character having done NOTHING.
        That had already happened: `media` shipped 2026-07-25 and was invisible
        to triage until this test was written, which also broke the follow-up
        that planned to measure the media arm with this very tool.

        Deliberately ONE-DIRECTIONAL.  The reverse check would be wrong here:
        this tool reads HISTORICAL logs and keeps retired labels (`barricade`,
        removed from the mod in V5.0) that the Lua table no longer defines.
        """
        import re

        lua_path = (
            Path(__file__).parent.parent
            / "42" / "media" / "lua" / "client"
            / "AutoPilot_Telemetry.lua"
        )
        if not lua_path.exists():
            self.skipTest("AutoPilot_Telemetry.lua not found")

        pattern = re.compile(r'^\s+(\w+)\s*=\s*"(\w+)"')
        lua_keys: set[str] = set()
        in_table = False
        for line in lua_path.read_text(encoding="utf-8").splitlines():
            if "REASON_CLASS" in line and "=" in line and "{" in line:
                in_table = True
                continue
            if in_table:
                match = pattern.match(line)
                if match:
                    lua_keys.add(match.group(1))
                if "}" in line and "{" not in line:
                    break

        self.assertTrue(lua_keys, "could not parse REASON_CLASS from the Lua source")
        missing = sorted(lua_keys - set(tr.ACTION_CATEGORY))
        self.assertEqual(
            missing, [],
            f"action labels the runtime emits but triage cannot categorize: {missing}",
        )


# ── split_sessions tests ──────────────────────────────────────────────────────

class TestSplitSessions(unittest.TestCase):

    def test_fixture_splits_on_run_tick_reset(self) -> None:
        entries, _ = tr.parse_run_log(FIXTURE)
        sessions = tr.split_sessions(entries)
        self.assertEqual(len(sessions), 2)
        self.assertEqual(len(sessions[0]), 14)
        self.assertEqual(len(sessions[1]), 6)
        self.assertEqual(sessions[0][-1]["action"], "dead")
        self.assertEqual(sessions[1][0]["run_tick"], 1)

    def test_no_entries_yields_no_sessions(self) -> None:
        self.assertEqual(tr.split_sessions([]), [])


# ── summarize tests ───────────────────────────────────────────────────────────

class TestSummarize(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        cls.entries, cls.skipped = tr.parse_run_log(FIXTURE)
        cls.summary = tr.summarize(cls.entries, cls.skipped)

    def test_total_ticks(self) -> None:
        self.assertEqual(self.summary.total_ticks, 20)
        self.assertEqual(self.summary.skipped_lines, 0)

    def test_action_counts(self) -> None:
        counts = self.summary.action_counts
        self.assertEqual(counts.get("exercise",  0), 7)
        self.assertEqual(counts.get("idle",      0), 2)
        self.assertEqual(counts.get("combat",    0), 2)
        self.assertEqual(counts.get("sleep",     0), 2)
        self.assertEqual(counts.get("rest",      0), 1)
        self.assertEqual(counts.get("eat",       0), 1)
        self.assertEqual(counts.get("scavenge",  0), 1)
        self.assertEqual(counts.get("bandage",   0), 1)
        self.assertEqual(counts.get("dead",      0), 1)
        self.assertEqual(counts.get("cooldown",  0), 1)
        self.assertEqual(counts.get("barricade", 0), 1)
        self.assertEqual(sum(counts.values()), 20)

    def test_category_counts(self) -> None:
        cats = self.summary.category_counts
        self.assertEqual(cats.get("training", 0), 7)
        self.assertEqual(cats.get("resting",  0), 3)   # rest + 2x sleep
        self.assertEqual(cats.get("survival", 0), 6)   # eat,bandage,2x combat,scavenge,barricade
        self.assertEqual(cats.get("idle",     0), 4)   # 2x idle, dead, cooldown
        self.assertEqual(sum(cats.values()), 20)

    def test_transitions_counted_within_sessions(self) -> None:
        t = self.summary.transition_counts
        # exercise streaks: 2 pairs in each session
        self.assertEqual(t.get(("exercise", "exercise"), 0), 4)
        # both sessions open with idle -> exercise
        self.assertEqual(t.get(("idle", "exercise"), 0), 2)
        self.assertEqual(t.get(("sleep", "dead"), 0), 1)
        # 13 pairs in session 1 + 5 pairs in session 2
        self.assertEqual(sum(t.values()), 18)

    def test_no_cross_session_transition(self) -> None:
        """The death marker must not chain into the next session's first tick."""
        self.assertNotIn(("dead", "idle"), self.summary.transition_counts)

    def test_threat_summary(self) -> None:
        s = self.summary
        self.assertEqual(s.threat_ticks,    3)   # run_tick 9, 10, 14 of session 1
        self.assertEqual(s.threat_episodes, 2)   # ticks 9-10, then tick 14
        self.assertEqual(s.max_zombies,     5)
        self.assertEqual(s.combat_ticks,    2)
        self.assertEqual(s.bleeding_ticks,  3)   # ticks 10, 11, 14
        self.assertEqual(s.deaths,          1)

    def test_session_str_fit_deltas(self) -> None:
        sessions = self.summary.sessions
        self.assertEqual(len(sessions), 2)

        s1 = sessions[0]
        self.assertEqual(s1.player,    0)
        self.assertEqual(s1.ticks,     14)
        self.assertEqual(s1.str_start, 2)
        self.assertEqual(s1.str_end,   3)
        self.assertEqual(s1.fit_start, 3)
        self.assertEqual(s1.fit_end,   3)
        self.assertEqual(s1.ended,     "dead")

        s2 = sessions[1]
        self.assertEqual(s2.ticks,     6)
        self.assertEqual(s2.str_start, 5)
        self.assertEqual(s2.str_end,   5)
        self.assertEqual(s2.fit_start, 5)
        self.assertEqual(s2.fit_end,   6)
        self.assertEqual(s2.ended,     "open")

    def test_empty_entries_summary(self) -> None:
        summary = tr.summarize([])
        self.assertEqual(summary.total_ticks, 0)
        self.assertEqual(summary.action_counts, {})
        self.assertEqual(summary.sessions, [])


# ── Suspicious-pattern tests ──────────────────────────────────────────────────

class TestSuspiciousPatterns(unittest.TestCase):
    """Each detector fires on the suspicious fixture, stays silent on clean."""

    @classmethod
    def setUpClass(cls) -> None:
        clean_entries, _ = tr.parse_run_log(FIXTURE)
        bad_entries, cls.bad_skipped = tr.parse_run_log(FIXTURE_SUSPICIOUS)
        cls.clean_sessions = tr.split_sessions(clean_entries)
        cls.bad_sessions = tr.split_sessions(bad_entries)
        cls.bad_total = len(bad_entries)

    def test_suspicious_fixture_parses(self) -> None:
        self.assertEqual(self.bad_total, 141)
        self.assertEqual(self.bad_skipped, 0)
        self.assertEqual(len(self.bad_sessions), 5)

    def test_streak_fires_on_bad_fixture(self) -> None:
        findings = tr.detect_action_streaks(self.bad_sessions)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f.pattern, "action streak")
        self.assertIn("session 1", f.detail)
        self.assertIn("'exercise' held 45 consecutive tick(s)", f.detail)
        self.assertIn("45 of them counted", f.detail)
        self.assertTrue(f.hint)

    def test_streak_silent_on_clean_fixture(self) -> None:
        self.assertEqual(tr.detect_action_streaks(self.clean_sessions), [])

    # ── Tombstone: detect_zero_xp_training (retired 2026-07-26) ──────────────
    # The zero-XP training detector read the run log's str/fit LEVEL fields,
    # and PZ levels essentially never move within one session (PR #89: all
    # fourteen recorded sessions were level-flat, healthy ones included), so
    # it fired on every session ever logged — a guard that cries wolf by
    # construction.  The run log deliberately carries no XP field (schema 5,
    # pinned by tests/test_session_xp.lua Test 4); XP evidence lives in
    # auto_pilot_sessions.log schema 3 and the F11 panel.  Its three tests
    # (fires-on-bad-fixture, silent-on-clean, needs-both-levels-flat) were
    # deleted with it.  Re-adding a training-yield detector requires run-log
    # XP fields (schema 6) first — see the backlog follow-up opened by PR #89.

    def test_zero_xp_detector_stays_retired(self) -> None:
        """The retired detector must not resurface without schema-6 XP data.

        Guards both the API (no detect_zero_xp_training attribute) and the
        output (no zero-XP pattern from detect_suspicious on the fixture
        that used to trip it).
        """
        self.assertFalse(hasattr(tr, "detect_zero_xp_training"))
        patterns = [f.pattern for f in tr.detect_suspicious(self.bad_sessions)]
        self.assertNotIn("zero-XP training", patterns)

    def test_below_threshold_training_run_is_silent(self) -> None:
        """Session 2's 32 consecutive exercise ticks stay under the streak
        threshold (40), so the retired detector's old fixture session now
        proves the streak detector does not absorb its false positive."""
        findings = tr.detect_action_streaks(self.bad_sessions)
        self.assertNotIn("session 2", findings[0].detail)
        self.assertEqual(len(findings), 1)

    def test_combat_cycle_fires_on_bad_fixture(self) -> None:
        findings = tr.detect_combat_cycles(self.bad_sessions)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f.pattern, "flee/combat cycle")
        self.assertIn("session 3", f.detail)
        self.assertIn("re-entered 4 time(s)", f.detail)
        self.assertIn("5 combat episode(s)", f.detail)
        self.assertTrue(f.hint)

    def test_combat_cycle_silent_on_clean_fixture(self) -> None:
        """One combat burst then death is normal play, not oscillation."""
        self.assertEqual(tr.detect_combat_cycles(self.clean_sessions), [])

    def test_loot_spiral_fires_on_bad_fixture(self) -> None:
        findings = tr.detect_loot_spirals(self.bad_sessions)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f.pattern, "empty-loot spiral")
        self.assertIn("session 4", f.detail)
        self.assertIn("16 scavenge tick(s)", f.detail)
        self.assertIn("hunger moved +35", f.detail)
        self.assertIn("thirst +27", f.detail)
        self.assertTrue(f.hint)

    def test_loot_spiral_silent_on_clean_fixture(self) -> None:
        self.assertEqual(tr.detect_loot_spirals(self.clean_sessions), [])

    def test_flee_stall_fires_on_bad_fixture(self) -> None:
        findings = tr.detect_flee_stalls(self.bad_sessions)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f.pattern, "flee stall")
        self.assertIn("session 5", f.detail)
        self.assertIn("re-issued 6 flee decision(s)", f.detail)
        self.assertIn("0 'evade_running' tick(s)", f.detail)
        self.assertIn("24 'evade_cooldown' tick(s)", f.detail)
        self.assertTrue(f.hint)

    def test_flee_stall_silent_on_clean_fixture(self) -> None:
        self.assertEqual(tr.detect_flee_stalls(self.clean_sessions), [])

    def test_flee_stall_session_stays_under_streak_threshold(self) -> None:
        """Session 5 must trip ONLY the new detector.

        Its 30 combat ticks are deliberately below STREAK_MIN_TICKS (40), so
        the action-streak detector still reports exactly one finding, on
        session 1.  If this ever fails, the fixture session grew and the two
        detectors have started overlapping.
        """
        streaks = tr.detect_action_streaks(self.bad_sessions)
        self.assertEqual(len(streaks), 1)
        self.assertIn("session 1", streaks[0].detail)
        self.assertEqual(len(self.bad_sessions[4]), 30)
        self.assertLess(len(self.bad_sessions[4]), tr.STREAK_MIN_TICKS)

    def test_detect_suspicious_combines_all_detectors(self) -> None:
        findings = tr.detect_suspicious(self.bad_sessions)
        self.assertEqual(
            [f.pattern for f in findings],
            ["action streak", "flee/combat cycle", "empty-loot spiral",
             "flee stall"],
        )

    def test_summarize_populates_suspicious(self) -> None:
        entries, skipped = tr.parse_run_log(FIXTURE_SUSPICIOUS)
        summary = tr.summarize(entries, skipped)
        self.assertEqual(len(summary.suspicious), 4)

    def test_clean_summary_has_no_findings(self) -> None:
        entries, skipped = tr.parse_run_log(FIXTURE)
        self.assertEqual(tr.summarize(entries, skipped).suspicious, [])

    def test_empty_log_has_no_findings(self) -> None:
        self.assertEqual(tr.summarize([]).suspicious, [])


# ── Persistent-state exemption tests (the guard-cries-wolf fix, 2026-07-26) ──
# The 2026-07-26 in-game session was mechanically clean (zero mod errors,
# zero fail_reasons, zero retries), yet the old action-keyed streak detector
# produced 19 findings on it: sleep held 723 ticks (the character was
# ASLEEP), busy held up to 854 (the PLAYER owned the queue, V4.5), idle held
# 80 (armed with nothing to do).  Each synthetic session below is shaped
# after a measured run from that log, so these are regression tests for the
# MED bug "the guard cries wolf", and each of the three exemption tests
# FAILS against the pre-fix detector.

def _ticks(action: str, reason: str, count: int) -> list[dict[str, object]]:
    """Build *count* synthetic session entries for one (action, reason)."""
    return [{"action": action, "reason": reason, "run_tick": i, "player": 0}
            for i in range(count)]


class TestPersistentStateExemption(unittest.TestCase):
    """Expected persistent states never fire; re-issued decisions still do."""

    def test_full_night_asleep_is_silent(self) -> None:
        """One sleep decision plus 722 asleep state lines is a normal night
        (measured shape of the 2026-07-26 session), not a stuck rotation."""
        session = (_ticks("sleep", "fatigue_thresh", 1)
                   + _ticks("sleep", "asleep", 722))
        self.assertEqual(tr.detect_action_streaks([session]), [])

    def test_long_foreign_action_is_silent(self) -> None:
        """854 busy/foreign_action lines: the player owns the queue and the
        V4.5 guarantee forbids interrupting — correct behaviour, no flag."""
        session = _ticks("busy", "foreign_action", 854)
        self.assertEqual(tr.detect_action_streaks([session]), [])

    def test_armed_idle_is_silent(self) -> None:
        """80 idle/no_action lines: armed with nothing queued and nothing
        needed is the designed idle loop, not a defect."""
        session = _ticks("idle", "no_action", 80)
        self.assertEqual(tr.detect_action_streaks([session]), [])

    def test_reissued_sleep_decision_fires(self) -> None:
        """45 consecutive sleep/fatigue_thresh DECISIONS is the pre-PR-#67
        sleep-starvation signature (the mod queued sleep every cycle while
        the engine refused it) and must keep firing."""
        findings = tr.detect_action_streaks(
            [_ticks("sleep", "fatigue_thresh", 45)])
        self.assertEqual(len(findings), 1)
        self.assertIn("'sleep'", findings[0].detail)
        self.assertIn("fatigue_thresh", findings[0].detail)

    def test_stuck_action_running_fires(self) -> None:
        """busy/action_running is NOT exempt: the thrash guard clears the
        mod's own action after MAX_ACTION_STREAK (15) consecutive busy
        evaluations (measured max in the clean session: exactly 15), so a
        45-tick run means the guard is not engaging — the docs/triage.md
        defect signature."""
        findings = tr.detect_action_streaks(
            [_ticks("busy", "action_running", 45)])
        self.assertEqual(len(findings), 1)
        self.assertIn("action_running", findings[0].detail)

    def test_mixed_reason_combat_streak_fires(self) -> None:
        """A 264-tick combat stretch with alternating reasons (the shape of
        the 2026-07-24 death session) is ONE action run and must fire: the
        run is keyed by ACTION, so reason changes inside it cannot reset the
        count."""
        session: list[dict[str, object]] = []
        for block in range(12):
            reason = ("engage_running" if block % 2 == 0
                      else "engage_cooldown")
            session += _ticks("combat", reason, 22)
        findings = tr.detect_action_streaks([session])
        self.assertEqual(len(findings), 1)
        self.assertIn("'combat' held 264 consecutive tick(s)", findings[0].detail)

    def test_threshold_counts_only_non_persistent_lines(self) -> None:
        """The threshold applies to COUNTED (non-persistent) lines, not run
        length: 39 re-issued decisions inside a long night stay silent, 40
        fire, even though both runs are 700+ lines long."""
        below = (_ticks("sleep", "fatigue_thresh", 39)
                 + _ticks("sleep", "asleep", 700))
        at = (_ticks("sleep", "fatigue_thresh", 40)
              + _ticks("sleep", "asleep", 700))
        self.assertEqual(tr.detect_action_streaks([below]), [])
        findings = tr.detect_action_streaks([at])
        self.assertEqual(len(findings), 1)
        self.assertIn("40 of them counted", findings[0].detail)

    def test_exemption_is_pair_scoped_not_action_scoped(self) -> None:
        """Only the exact (action, reason) pair is exempt: 45 idle lines
        with an unexpected reason still fire, so a new idle-flavoured state
        cannot silently inherit the exemption."""
        findings = tr.detect_action_streaks(
            [_ticks("idle", "mystery_state", 45)])
        self.assertEqual(len(findings), 1)

    def test_real_log_shapes_all_sessions_combined(self) -> None:
        """The full measured 2026-07-26 shape in one session list: every
        streak the old detector flagged, silent; nothing else fires."""
        sessions = [
            _ticks("idle", "no_action", 80)
            + _ticks("sleep", "fatigue_thresh", 1)
            + _ticks("sleep", "asleep", 722)
            + _ticks("busy", "foreign_action", 147),
            _ticks("busy", "foreign_action", 854)
            + _ticks("idle", "no_action", 45),
        ]
        self.assertEqual(tr.detect_action_streaks(sessions), [])


class TestPersistentStateDriftGuard(unittest.TestCase):
    """EXPECTED_PERSISTENT_STATES must stay in lockstep with the Lua (L-003).

    The exemption table lives in triage_run_log.py; the states it names are
    written by literal-label logTick() calls in the production Lua.  This
    guard parses BOTH sources so that (a) a typo'd exemption pair the mod
    never writes fails the build (the MoodleType.Unhappy class: a wrong
    name that silently never matches), and (b) a NEW state label added to
    the Lua fails the build until it is adjudicated as exempt or flagged.
    Decision labels are unaffected: they reach logTick via setDecision, so
    the literal-pair regex never matches them (combat's reason is a
    variable at the callsite, which is why it stays flagged).
    """

    LUA_CLIENT_DIR = (Path(__file__).parent.parent
                      / "42" / "media" / "lua" / "client")
    LOGTICK_LITERAL = re.compile(
        r'logTick\(\s*\w+\s*,\s*"([a-z_]+)"\s*,\s*"([a-z_]+)"\s*\)')

    # State pairs deliberately NOT exempt: each is bounded by design, so a
    # 40+ run of it IS the defect the streak detector exists to catch.
    FLAGGED_STATE_PAIRS = {
        # Thrash guard caps the mod's own action at MAX_ACTION_STREAK (15).
        ("busy", "action_running"),
        # Post-action cooldown is a few cycles (measured max 4).
        ("cooldown", "post_action"),
        # Written once per death by Telemetry.onDeath; 40+ = death loop.
        ("dead", "player_died"),
    }

    def _literal_pairs(self) -> set[tuple[str, str]]:
        files = sorted(self.LUA_CLIENT_DIR.glob("AutoPilot_*.lua"))
        self.assertGreater(
            len(files), 0,
            "blind guard: no production Lua modules found — fix the path "
            "before trusting this guard's silence")
        found: set[tuple[str, str]] = set()
        for f in files:
            for m in self.LOGTICK_LITERAL.finditer(
                    f.read_text(encoding="utf-8")):
                found.add((m.group(1), m.group(2)))
        self.assertGreaterEqual(
            len(found), 4,
            "blind guard: the logTick literal-pair regex matched almost "
            "nothing; if the callsite shape changed, update the regex "
            "rather than trusting silence")
        return found

    def test_every_lua_state_pair_is_adjudicated(self) -> None:
        found = self._literal_pairs()
        adjudicated = tr.EXPECTED_PERSISTENT_STATES | self.FLAGGED_STATE_PAIRS
        self.assertEqual(
            found - adjudicated, set(),
            "state pair(s) written by the production Lua are not "
            "adjudicated — add each to EXPECTED_PERSISTENT_STATES or to "
            "FLAGGED_STATE_PAIRS with a recorded reason")

    def test_every_exempt_pair_is_real(self) -> None:
        found = self._literal_pairs()
        self.assertEqual(
            tr.EXPECTED_PERSISTENT_STATES - found, set(),
            "exempt pair(s) the production Lua never writes — a typo here "
            "would silently reopen the crying-wolf bug for the real pair")

    def test_every_flagged_pair_is_real(self) -> None:
        found = self._literal_pairs()
        self.assertEqual(
            self.FLAGGED_STATE_PAIRS - found, set(),
            "flagged pair(s) the production Lua never writes — retire the "
            "entry or fix the spelling")

    def test_exempt_and_flagged_do_not_overlap(self) -> None:
        self.assertEqual(
            tr.EXPECTED_PERSISTENT_STATES & self.FLAGGED_STATE_PAIRS, set())


# ── Flee-stall detector (added 2026-08-07 by the QA triage of session 4) ──────
# The live log held three 40+ combat streaks that the action-streak detector
# reported identically, with one hint ("the rotation is stuck").  They were
# not one phenomenon: two ran at game speed x1 with 25 and 24 evade_running
# ticks (the queued escape walk survived across cycles - a real pursuit, and
# expected behaviour), while the third had ZERO, meaning every walk was gone
# 0.75 s later.  Separating them needs the evade_running count, which is why
# this detector exists.  It also found a FOURTH episode the streak detector
# could not see at all: 33 ticks at run_tick 3523-3555, under the 40-tick
# streak threshold, 7 flee decisions, 0 evade_running, at game speed x1.

def _flee_cycles(count: int, cooldown: int = 4,
                 reason: str = "flee_default") -> list[dict[str, object]]:
    """One decision tick plus *cooldown* evade_cooldown ticks, *count* times."""
    out: list[dict[str, object]] = []
    for _ in range(count):
        out.extend(_ticks("combat", reason, 1))
        out.extend(_ticks("combat", tr.EVADE_COOLDOWN_REASON, cooldown))
    return out


class TestFleeStallDetector(unittest.TestCase):
    """A flee stall is 'no escape walk survived a cycle', not 'lots of combat'."""

    def test_stalled_episode_fires(self) -> None:
        session = _one_session(_flee_cycles(6))
        findings = tr.detect_flee_stalls([session])
        self.assertEqual(len(findings), 1)
        self.assertIn("re-issued 6 flee decision(s)", findings[0].detail)

    def test_healthy_evade_is_silent(self) -> None:
        """The discriminating property: one surviving walk clears the episode.

        Shaped after the live 126-tick streak (21 decisions, 25
        evade_running, 80 evade_cooldown) which is a real pursuit at x1.
        Identical decision count to the firing case above; only the
        evade_running ticks differ.
        """
        session: list[dict[str, object]] = []
        for _ in range(6):
            session.extend(_ticks("combat", "flee_default", 1))
            session.extend(_ticks("combat", tr.EVADE_RUNNING_REASON, 2))
            session.extend(_ticks("combat", tr.EVADE_COOLDOWN_REASON, 4))
        self.assertEqual(tr.detect_flee_stalls([_one_session(session)]), [])

    def test_stall_beside_a_healthy_episode_in_one_session_still_fires(
            self) -> None:
        """Episode-scoped, not session-scoped.

        This is exactly the live session-4 shape: healthy pursuits and a
        stalled episode in the SAME session.  A session-scoped
        implementation counts the healthy episode's evade_running ticks and
        reports nothing, which is the whole defect this test pins.
        """
        healthy: list[dict[str, object]] = []
        for _ in range(6):
            healthy.extend(_ticks("combat", "flee_default", 1))
            healthy.extend(_ticks("combat", tr.EVADE_RUNNING_REASON, 2))
            healthy.extend(_ticks("combat", tr.EVADE_COOLDOWN_REASON, 4))
        session = _one_session(
            healthy + _ticks("idle", "no_action", 5) + _flee_cycles(6))
        findings = tr.detect_flee_stalls([session])
        self.assertEqual(len(findings), 1)
        self.assertIn("re-issued 6 flee decision(s)", findings[0].detail)

    def test_below_threshold_is_silent(self) -> None:
        session = _one_session(_flee_cycles(tr.FLEE_STALL_MIN_DECISIONS - 1))
        self.assertEqual(tr.detect_flee_stalls([session]), [])

    def test_trapped_without_cooldown_is_silent(self) -> None:
        """flee_blocked queues no walk, so it sets no cooldown.

        A trapped character holding position is a separate, self-labelled
        condition; firing the stall detector on it would report a walk that
        never happened.
        """
        session = _one_session(_ticks("combat", "flee_blocked", 20))
        self.assertEqual(tr.detect_flee_stalls([session]), [])

    def test_post_fix_stall_shape_still_fires(self) -> None:
        """The detector must survive the fix it helped find.

        Since the stall fix (AutoPilot_Threat: an escape walk that moved the
        character less than FLEE_PROGRESS_MIN tiles pays no cooldown), a
        STILL-stalling episode reads flee_default / evade_stalled on a stride
        of 2 with ZERO evade_cooldown ticks.  The pre-fix detector required an
        evade_cooldown tick, so it would have gone silent on exactly the
        condition it exists to report -- the character still not escaping,
        just failing twice as fast.
        """
        episode: list[dict[str, object]] = []
        for _ in range(6):
            episode.extend(_ticks("combat", "flee_default", 1))
            episode.extend(_ticks("combat", tr.EVADE_STALLED_REASON, 1))
        findings = tr.detect_flee_stalls([_one_session(episode)])
        self.assertEqual(len(findings), 1)
        self.assertIn("re-issued 6 flee decision(s)", findings[0].detail)
        self.assertIn("6 'evade_stalled' tick(s)", findings[0].detail)
        self.assertIn("0 'evade_cooldown' tick(s)", findings[0].detail)

    def test_pre_fix_detail_does_not_mention_the_stalled_label(self) -> None:
        """A log with no evade_stalled ticks reads exactly as it always did.

        The stalled count is additive, not a reformat: an old log triaged
        after the fix must not grow a '0 evade_stalled tick(s)' clause that a
        reader would take as evidence the fix was running.
        """
        findings = tr.detect_flee_stalls([_one_session(_flee_cycles(6))])
        self.assertNotIn(tr.EVADE_STALLED_REASON, findings[0].detail)

    def test_varying_speed_is_reported_as_a_range(self) -> None:
        """The speed range is the datum that tells the two readings apart."""
        session = _one_session(_flee_cycles(6))
        for index, entry in enumerate(session):
            entry["speed"] = 15 + (index % 3)
        findings = tr.detect_flee_stalls([session])
        self.assertEqual(len(findings), 1)
        self.assertIn("game speed x15-x17", findings[0].detail)

    def test_constant_speed_is_reported_as_a_single_value(self) -> None:
        session = _one_session(_flee_cycles(6))
        for entry in session:
            entry["speed"] = 1
        findings = tr.detect_flee_stalls([session])
        self.assertIn("game speed x1", findings[0].detail)
        self.assertNotIn("x1-x", findings[0].detail)

    def test_missing_speed_is_reported_not_guessed(self) -> None:
        """Pre-v5 logs carry no speed field; say so rather than imply x1."""
        findings = tr.detect_flee_stalls([_one_session(_flee_cycles(6))])
        self.assertIn("speed not recorded (pre-v5 log)", findings[0].detail)


class TestEvadeReasonDriftGuard(unittest.TestCase):
    """The three evade lifecycle labels must stay in lockstep with the Lua (L-003).

    detect_flee_stalls is built entirely on EVADE_RUNNING_REASON,
    EVADE_COOLDOWN_REASON and EVADE_STALLED_REASON.  If any of them is renamed
    in the Lua the way engage_* -> evade_* was renamed in V6.1-2 (PR #95), the
    detector would silently stop discriminating: every episode would read as
    having zero evade_running ticks, and it would fire on healthy pursuits
    forever.  Files are glob-discovered and the token is searched across ALL of
    them, so a future module split cannot quietly move the emitter out of range.
    """

    LUA_CLIENT_DIR = (Path(__file__).parent.parent
                      / "42" / "media" / "lua" / "client")
    ENGAGE_REASON_LITERAL = re.compile(
        r'_engageReason\s*=\s*"([a-z_]+)"')

    def _emitted_reasons(self) -> set[str]:
        files = sorted(self.LUA_CLIENT_DIR.glob("AutoPilot_*.lua"))
        self.assertGreater(
            len(files), 0,
            "blind guard: no production Lua modules found — fix the path "
            "before trusting this guard's silence")
        found: set[str] = set()
        for f in files:
            found.update(self.ENGAGE_REASON_LITERAL.findall(
                f.read_text(encoding="utf-8")))
        self.assertGreaterEqual(
            len(found), 2,
            "blind guard: the _engageReason literal regex matched almost "
            "nothing; if the assignment shape changed, update the regex "
            "rather than trusting silence")
        return found

    def test_both_evade_lifecycle_labels_are_emitted_by_the_lua(self) -> None:
        found = self._emitted_reasons()
        self.assertIn(
            tr.EVADE_RUNNING_REASON, found,
            "the production Lua no longer emits this label — the flee-stall "
            "detector would read every episode as stalled")
        self.assertIn(
            tr.EVADE_COOLDOWN_REASON, found,
            "the production Lua no longer emits this label — the flee-stall "
            "detector would never fire again")
        self.assertIn(
            tr.EVADE_STALLED_REASON, found,
            "the production Lua no longer emits this label — a still-stalling "
            "episode under the stall fix pays no cooldown, so the detector "
            "would read it as 'trapped' and stay silent")

    def test_lifecycle_labels_are_distinct(self) -> None:
        self.assertEqual(
            len({tr.EVADE_RUNNING_REASON, tr.EVADE_COOLDOWN_REASON,
                 tr.EVADE_STALLED_REASON}), 3)


# ── build stamp (schema v6) ───────────────────────────────────────────────────

# v5 (2026-07-24) added the real game-speed field; v6 (2026-08-10) appends the
# mod_version build stamp after doc.  The pair below differ ONLY in those two
# respects, so every assertion about the stamp is about the stamp.
V5_LINE = (
    "schema_version=5,player=0,mode=autopilot,ff=normal,speed=1,"
    "run_tick={tick},action=exercise,reason=training,class=exercise,stage=,"
    "fail_reason=,retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=95,"
    "zombies=0,bleeding=0,str=1,fit=1,doc=0"
)

V6_LINE = (
    "schema_version=6,player=0,mode=autopilot,ff=normal,speed=1,"
    "run_tick={tick},action=exercise,reason=training,class=exercise,stage=,"
    "fail_reason=,retry_count=0,hunger=5,thirst=5,fatigue=5,endurance=95,"
    "zombies=0,bleeding=0,str=1,fit=1,doc=0,mod_version={build}"
)


class TestBuildStampParsing(unittest.TestCase):
    """v6 appends mod_version; v2-v5 lines keep parsing exactly as before."""

    def test_a_v6_line_parses_and_keeps_the_stamp_as_a_string(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "run.log"
            path.write_text(V6_LINE.format(tick=1, build="0.2.1") + "\n",
                            encoding="utf-8")
            entries, skipped = tr.parse_run_log(path)
        self.assertEqual(skipped, 0)
        self.assertEqual(entries[0]["schema_version"], 6)
        # Not in _INT_FIELDS: "0.2.1" must survive as text.  Coercing it would
        # turn every stamp into a truncated float and collapse 0.2.1 onto 0.2.9.
        self.assertEqual(entries[0]["mod_version"], "0.2.1")

    def test_a_pre_v6_line_is_unstamped_not_broken(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "run.log"
            path.write_text(V5_LINE.format(tick=1) + "\n", encoding="utf-8")
            entries, skipped = tr.parse_run_log(path)
        self.assertEqual(skipped, 0)
        self.assertNotIn("mod_version", entries[0])
        self.assertEqual(tr.session_build(entries), tr.UNSTAMPED_BUILD)

    def test_a_mixed_v5_v6_session_reports_the_stamp_it_has(self) -> None:
        """The real upgrade shape: one file spanning the schema change."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "run.log"
            path.write_text(
                V5_LINE.format(tick=1) + "\n"
                + V6_LINE.format(tick=2, build="0.2.1") + "\n",
                encoding="utf-8")
            entries, skipped = tr.parse_run_log(path)
        self.assertEqual(skipped, 0)
        sessions = tr.split_sessions(entries)
        self.assertEqual(len(sessions), 1)
        self.assertEqual(tr.session_build(sessions[0]), "0.2.1")
        self.assertEqual(tr.summarize(entries).sessions[0].mod_version, "0.2.1")

    def test_findings_for_build_selects_by_exact_equality(self) -> None:
        findings = [
            tr.SuspiciousFinding("flee stall", "d", "h", mod_version="0.2.1"),
            tr.SuspiciousFinding("flee stall", "d", "h", mod_version="0.2.10"),
            tr.SuspiciousFinding("flee stall", "d", "h"),
        ]
        self.assertEqual(
            [f.mod_version for f in tr.findings_for_build(findings, "0.2.1")],
            ["0.2.1"],
            "0.2.10 must not match 0.2.1 by prefix, and an unstamped finding "
            "must not match a stamped build")
        self.assertEqual(
            len(tr.findings_for_build(findings, tr.UNSTAMPED_BUILD)), 1,
            "the unstamped sentinel selects exactly the unstamped findings")


class TestBuildStampDriftGuard(unittest.TestCase):
    """The stamp this parser reads must be the one the Lua writes (L-003).

    Both sides are read here, not just this one: a key rename or a schema bump
    on the Lua side would leave every session silently unstamped, which reads
    as "pre-v6" — the exact state the field was added to end, arriving without
    a single test going red.
    """

    TELEMETRY_LUA = (Path(__file__).parent.parent / "42" / "media" / "lua"
                     / "client" / "AutoPilot_Telemetry.lua")

    def _lua(self) -> str:
        self.assertTrue(
            self.TELEMETRY_LUA.exists(),
            f"blind guard: {self.TELEMETRY_LUA} not found — fix the path "
            "before trusting this guard's silence")
        return self.TELEMETRY_LUA.read_text(encoding="utf-8")

    def test_the_lua_writes_the_key_this_parser_reads(self) -> None:
        # assertTrue, not assertIn: assertIn's default message renders the
        # WHOLE haystack, and a 400-line Lua module dumped into a failure
        # buries the one sentence that says what broke.
        self.assertTrue(
            "mod_version=%s" in self._lua(),
            f"{self.TELEMETRY_LUA.name}'s run-log format string no longer "
            "emits mod_version=%s — session_build would report every v6 "
            "session as unstamped, silently undoing build attribution")

    def test_the_declared_schema_version_matches_the_stamped_format(self) -> None:
        lua = self._lua()
        match = re.search(r"^local SCHEMA_VERSION = (\d+)", lua, re.MULTILINE)
        self.assertIsNotNone(
            match, "blind guard: no SCHEMA_VERSION assignment matched")
        self.assertGreaterEqual(
            int(match.group(1)), 6,
            "mod_version arrived in schema v6; a lower declared version means "
            "the writer and this parser disagree about what a stamped line is")

    def test_the_stamp_comes_from_the_one_version_home(self) -> None:
        """No second version constant: the stamp is Constants.VERSION."""
        lua = self._lua()
        self.assertIn(
            "AutoPilot_Constants.VERSION", lua,
            "the build stamp must read the version constant that "
            "tests/test_version_constant.lua binds to both mod.info files, "
            "not a literal minted here")


# ── attributed activity tests ─────────────────────────────────────────────────
# Regression tests for the MED measurement-integrity bug found 2026-08-05: the
# Action mix and Time split count DECISION ticks only, while a queued action
# executes over many busy/action_running ticks (thrash-guard cap 15/streak),
# all filed under "idle".  Measured live on the 2026-08-01 sessions: exercise
# was 2.0% of session 2 by decision ticks but 1185 of its 3907 ticks (30.3%)
# were mod-queued exercise sets executing — the "1.5% exercise share" shape
# that drove the V6.1-1 retune reads ~15x low against attributed time.  Every
# test here fails against the pre-fix module (no attribute_activity, no
# report section).

def _one_session(entries: list[dict[str, object]]) -> list[dict[str, object]]:
    """Renumber run_tick monotonically so split_sessions sees ONE session.

    ``_ticks`` restarts run_tick at 0 on every call, which ``summarize``'s
    session splitter reads as a new session; the direct
    ``attribute_activity([...])`` tests are unaffected because they hand the
    splitter nothing.
    """
    for index, entry in enumerate(entries, start=1):
        entry["run_tick"] = index
    return entries


class TestAttributedActivity(unittest.TestCase):
    """busy/action_running ticks are credited to the queueing decision."""

    def test_running_ticks_credit_the_preceding_decision(self) -> None:
        """The measured live shape: decision, 15-tick running streak,
        post-action cooldown, repeat.  Running ticks belong to exercise;
        cooldown stays overhead."""
        session = (_ticks("exercise", "training", 1)
                   + _ticks("busy", "action_running", 15)
                   + _ticks("cooldown", "post_action", 4)
                   + _ticks("exercise", "training", 1)
                   + _ticks("busy", "action_running", 15))
        decisions, running = tr.attribute_activity([session])
        self.assertEqual(decisions, {"exercise": 2})
        self.assertEqual(running, {"exercise": 30})

    def test_persistent_states_are_not_decisions(self) -> None:
        """A night of sleep is ONE decision: the asleep state lines and the
        walk-to-bed running ticks both hang off sleep/fatigue_thresh."""
        session = (_ticks("sleep", "fatigue_thresh", 1)
                   + _ticks("busy", "action_running", 6)
                   + _ticks("sleep", "asleep", 700))
        decisions, running = tr.attribute_activity([session])
        self.assertEqual(decisions, {"sleep": 1})
        self.assertEqual(running, {"sleep": 6})

    def test_foreign_action_is_neither_credited_nor_disturbing(self) -> None:
        """busy/foreign_action is someone else's queue: not attributed, and
        it does not steal ownership from the mod's last decision."""
        session = (_ticks("exercise", "training", 1)
                   + _ticks("busy", "foreign_action", 50)
                   + _ticks("busy", "action_running", 10))
        decisions, running = tr.attribute_activity([session])
        self.assertEqual(decisions, {"exercise": 1})
        self.assertEqual(running, {"exercise": 10})

    def test_orphan_running_ticks_are_unattributed(self) -> None:
        """A log rotated mid-session loses the owning decision; the running
        ticks must be reported, not silently credited to anything."""
        session = (_ticks("busy", "action_running", 8)
                   + _ticks("exercise", "training", 1))
        decisions, running = tr.attribute_activity([session])
        self.assertEqual(running, {tr.UNATTRIBUTED: 8})

    def test_attribution_never_crosses_sessions(self) -> None:
        """A run_tick reset ends ownership: session B's leading running
        ticks are unattributed even though session A ended on a decision."""
        session_a = _ticks("exercise", "training", 1)
        session_b = _ticks("busy", "action_running", 5)
        decisions, running = tr.attribute_activity([session_a, session_b])
        self.assertEqual(decisions, {"exercise": 1})
        self.assertEqual(running, {tr.UNATTRIBUTED: 5})

    def test_summarize_populates_attribution_fields(self) -> None:
        session = _one_session(_ticks("exercise", "training", 1)
                               + _ticks("busy", "action_running", 15))
        summary = tr.summarize(session)
        self.assertEqual(summary.decision_ticks, {"exercise": 1})
        self.assertEqual(summary.attributed_running, {"exercise": 15})

    def test_report_renders_attributed_activity_section(self) -> None:
        """The section must expose the decision-vs-running split, because
        the Action mix alone reads a training-heavy session as idle."""
        session = _one_session(_ticks("exercise", "training", 2)
                               + _ticks("busy", "action_running", 30)
                               + _ticks("cooldown", "post_action", 8))
        report = tr.format_report(tr.summarize(session))
        self.assertIn("Attributed activity", report)
        self.assertIn(f"decisions {2:6d}", report)
        self.assertIn(f"running {30:6d}", report)
        self.assertIn(f"total {32:6d}", report)
        self.assertIn("80.0%", report)   # 32 of 40 ticks, no longer "idle"

    def test_report_attributed_section_empty_log(self) -> None:
        report = tr.format_report(tr.summarize([]))
        self.assertIn("Attributed activity", report)


# ── format_report tests ───────────────────────────────────────────────────────

class TestFormatReport(unittest.TestCase):

    def test_report_contains_all_sections(self) -> None:
        entries, skipped = tr.parse_run_log(FIXTURE)
        report = tr.format_report(tr.summarize(entries, skipped), FIXTURE)
        self.assertIn("Action mix", report)
        self.assertIn("Top action transitions", report)
        self.assertIn("Time split", report)
        self.assertIn("Attributed activity", report)
        self.assertIn("Threat events", report)
        self.assertIn("Sessions (STR/FIT deltas)", report)
        self.assertIn("exercise -> exercise", report)
        self.assertIn("STR 2 -> 3 (+1)", report)
        self.assertIn("FIT 5 -> 6 (+1)", report)
        self.assertIn("ended: dead", report)
        self.assertIn("Suspicious patterns", report)

    def test_clean_report_says_none_detected(self) -> None:
        entries, skipped = tr.parse_run_log(FIXTURE)
        report = tr.format_report(tr.summarize(entries, skipped), FIXTURE)
        self.assertIn("none detected", report)

    def test_suspicious_report_lists_findings_and_hints(self) -> None:
        entries, skipped = tr.parse_run_log(FIXTURE_SUSPICIOUS)
        report = tr.format_report(tr.summarize(entries, skipped),
                                  FIXTURE_SUSPICIOUS)
        self.assertIn("[action streak]", report)
        self.assertIn("[flee/combat cycle]", report)
        self.assertIn("[empty-loot spiral]", report)
        self.assertIn("[flee stall]", report)
        # The retired zero-XP detector must not resurface in the report.
        self.assertNotIn("[zero-XP training]", report)
        self.assertEqual(report.count("hint:"), 4)
        self.assertNotIn("none detected", report)

    def test_empty_summary_report_does_not_raise(self) -> None:
        report = tr.format_report(tr.summarize([]))
        self.assertIn("Parsed 0 tick(s)", report)

    def test_missing_str_fit_prints_na(self) -> None:
        """Old-schema entries without str/fit fields report n/a deltas."""
        entries = [
            {"action": "idle", "run_tick": 1, "player": 0},
            {"action": "idle", "run_tick": 2, "player": 0},
        ]
        report = tr.format_report(tr.summarize(entries))
        self.assertIn("STR n/a", report)
        self.assertIn("FIT n/a", report)


if __name__ == "__main__":
    unittest.main()
