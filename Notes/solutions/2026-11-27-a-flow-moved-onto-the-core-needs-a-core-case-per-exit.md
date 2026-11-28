---
title: "A flow moved onto the turn core needs a core case for each exit, and its owner sends must be `.control`"
module: SwiftStateTree
date: 2026-11-27
problem_type: testing_practice
component: turn-core-adoption
symptoms:
  - "a differential case passes with the core's answer step removed, because the harness never sends the owner's reply"
  - "a race case run N times compares a finished keeper with a core still mid-job"
  - "a full or closed queue refuses the only input that answers a flow's waiters"
  - "a stored flag made computed from a phase enum: mutants on the phase where the two differ survive the whole suite"
  - "a test for a dropped await passes a fraction of runs: the read races the caller's resumption after a hold"
root_cause: core_path_covered_by_its_happy_path_only
resolution_type: design_rule
severity: high
tags:
  - turn-core
  - differential
  - testing
  - reentrancy
related:
  - "#700"
  - "#948"
  - "#966"
---

**Problem.** K2-2 commit 1a (#966) moved the keeper's initialization onto `TurnCore`. Its differential had one core case: the happy path, with no loops, an unheld recorder and one waiter. Review found mutants that survived it:
- the record effect returned without awaiting the hand-off;
- `.initializeDone`'s answer step dropped. The harness's `flush` ignored `.startLoops`, so no case ever reached that step.
- the failure exits answering nobody.

A race case (`Task { cancel() }` against a resume, run 8 times) wasn't forced either. On one branch, it waited for a result name that the harness notes inside `perform`, before the core steps that result. So it compared the two paths while the core still had `.inputDrainDue` → `.recordTaken` ahead of it.

The owner's two sends, `.initialize` and `.initializeDone`, kept the default `.normal` policy, so a full or closed queue could refuse the only step that answers the initialization's waiters. That is the same rule #948 applied to `.resume`.

**Fix.** These were found in round 1 on #966. Each was fixed:
- **One core case per exit, compared on both paths:** a held record with two early waiters, a failure (an early and a late waiter both get the failure), and `autoStartLoops: true`, where the twin answers `.startLoops` with `.initializeDone`.
- **Two forced orders instead of the free race.** The resume-first order holds the job at its resolver while the caller is cancelled. The comparison waits for the core's own end event (`input-drain-end`), not for a name noted before the step.
- **`.control`** for both owner sends.

**Rule.**
- When a flow moves onto the core, list its exits (each terminal phase, each answer site, each owner reply the harness must play) and give every one a core case. A mutant that deletes an answer step must fail a case.
- If the harness stands in for the owner, it must send every reply the owner sends, or the steps after that reply are dead in the tests.
- A comparison waits for the slower path's last event. `perform` noting a result is not that event: the result hasn't stepped yet.
- An owner send that is the only way to answer a flow's waiters is `.control`.
- A doc that names an exception to an assert must make the exception not trap, or say that it traps. Round 1's `markDrainingForTesting` doc called itself "the one exception" to the OnJoin assert, which still trapped in debug. Round 2 makes the hook clear players and services in one turn, as every production drain start does. The only caller inside a turn body gets a flag-only hook, `setDrainFlagInBodyForTesting`, whose doc says why it can't reach that assert.
- Before writing a twin's expectation from the review's wording, check the keeper's answer. T11's twin was asked to expect "the phase isn't `.done`", but on the keeper the initialization ends `.done` and the land fails after it. The case pins what both paths do.
- When a stored flag becomes computed from a phase, list the phases where the old and the new value differ, and pin each one with a case that reads the flag there. Round 2 made #952's `initializationApplied` the computed `phase.applied`. It differs from `didInitialize` in `.recording`, `.finishing` and `.startingLoops` (and the other way in the two failed phases, which another guard covers). The keeper awaits only in `.recording`, and no case ran a drain to its destroy handlers while the record was held: the keeper's T2b released the record first. So `applied` false for `.recording`, and `initializationApplied = didInitialize`, both survived. Round 3 holds the record until the failure's drain has finished, asserts the destroy handlers ran, and reads `applied && !didInitialize` at the hold on both paths.
- A wait in a test whose call ignores cancellation is bounded by an event the task's end appends, not by a task group or the suite's time limit: either one waits for the child that never returns.
- A dropped `await` whose only effect is what the caller does in the segment after a hold can't be caught by a read from the hold's own task. The hook is nonisolated, so its return enqueues the caller's resumption from another thread, and the read races it: T2c's first form killed cloud mutant (a) in 17 of 20 runs. Force the read after that segment with a hook that runs on the caller's executor (`HoldPoints.installResumed`): a task it starts there, capturing the `isolated` parameter, runs only at the caller's next suspension. Then the kill is 20 of 20.
