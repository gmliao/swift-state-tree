---
title: "A model copied while its input drain is scheduled carries the schedule, and no drain runs"
module: SwiftStateTree, tests
date: 2026-11-27
problem_type: testing_practice
component: keeper-differential
symptoms:
  - "A test core built from a keeper's model never answers a tickless input; its hold is never entered"
  - "A twin built after a join hangs only in some runs, or only when the suite runs in parallel"
  - "The keeper's work count is 0, yet `inputDrainScheduled` is still true"
  - "A twin's source keeper has a `ReleasedLandTransport`: it failed before it was copied"
root_cause: snapshot_taken_before_the_drain_ended
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - input-drain
  - snapshot
  - differential
  - keeper
  - turns
related:
  - "#700"
  - "#934"
---

**Problem.** #700 K2-1's differential builds a test core from a copy of a second keeper's model (`LandKeeper.coreTwinForTesting`). Cases that joined on the source keeper first and copied after hung: the core's action never got a drain. Another case, which queued a failure item on the source, found the source already failed when it was copied.

**Root cause.** The copy took `inputDrainScheduled == true` from a drain that hadn't ended. The core's `awaitCoreInputTurn` asks `scheduleInputDrain()`, which returns false while the flag is set, so the core never queued its own `.inputDrainDue`. `waitForInFlightWorkForTesting()` wasn't enough: a join's work count ends when its input turn answers it, inside the drain, and the drain ends in a later segment. The same unfinished drain could also take an item queued after the join (the failure case), in whichever run reached it first.

**Fix.** The cases wait for both, `waitForInFlightWorkForTesting()` and then `waitForInputDrainIdleForTesting()`, before they copy or queue. A case that needs a pending item in the copy holds the source's `.inputDrain` and the item's kick. `coreTwinForTesting` refuses a source whose drain is still scheduled (a precondition, so the hang becomes a stop with its reason). The twin also copies the side's per-player services, which live beside the model's entries.

**Prevention.** Copy, compare or hand off a keeper's model only at a quiescent point: no work in flight *and* no drain scheduled. Work count 0 isn't idleness. Whatever the copy depends on (a schedule flag, side tables beside the model) goes in the hook's checks, not in each test. The same class at the keeper's initialization: a waiter can see the task done before the flag is set (#934).
