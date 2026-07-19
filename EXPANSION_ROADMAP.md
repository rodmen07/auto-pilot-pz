# AutoPilot V1.0+ Expansion Roadmap (SUPERSEDED)

> **SUPERSEDED 2026-07-18.** The current plan is [ROADMAP.md](ROADMAP.md). Direction is now STABILIZE around the V3.3 auto-exercise leveler identity.

This file planned V1.1-V2.0: smarter foraging, extended combat, advanced skills, vehicles, NPCs, base building, analytics, an LLM sidecar, economy, and quests. That arc is dead:

- Phase 1 (Foraging, Combat, Skills, Vehicles) was built on 2026-06-01 (commit 1962c8b) and then deliberately DELETED in V3.1 on 2026-07-18 as part of the pivot to the leveler identity.
- The LLM sidecar was retired; `release.yml` asserts no anthropic imports, and the Kahlua sandbox forbids HTTP.
- Splitscreen support (assumed throughout the old plan) was removed in V3.2.

None of the deleted modules or retired systems are to be resurrected without explicit user direction; ROADMAP.md records this as a standing non-goal.

The full original text of this plan is preserved in git history: the file existed from commit 1962c8b (2026-06-01) through eef62ec; recover it with `git show eef62ec:EXPANSION_ROADMAP.md`. `PHASE1_SUMMARY.md` documents the built-then-deleted phase, and `CHANGELOG.md` is the authoritative record of what actually shipped.
