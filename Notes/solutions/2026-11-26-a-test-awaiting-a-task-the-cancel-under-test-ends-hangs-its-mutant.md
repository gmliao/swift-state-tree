---
title: "A test that awaits a task only the cancel under test ends hangs under its mutant instead of failing"
module: SwiftStateTree
date: 2026-11-26
problem_type: testing_practice
component: keeper-action-jobs
symptoms:
  - "a mutant run times out instead of reporting a failed expectation"
  - "the expect fails, then the test hangs at await task.value"
root_cause: test_awaits_a_task_that_ends_only_on_the_behavior_under_test
resolution_type: established_pattern
severity: low
tags:
  - testing
  - mutants
  - cancellation
  - hang
related:
  - "#895"
---

**Problem.** The action job box's tests (`KeeperActionJobBoxTests`) start a task that waits until it is cancelled, hand it to the box, ask the box to cancel it, `#expect(task.isCancelled)`, then `await task.value`. Under the mutants that break the cancel (the install ignores the early-cancel flag; the cancel sets the flag without cancelling the installed task), the expect fails as it should, but the task is never cancelled, so `await task.value` never returns. The mutant run then hangs until its time limit, which reads as an environment problem rather than a caught mutant.

**Root cause.** The test's own cleanup depends on the behavior under test. Once that behavior is broken, the test can't finish.

**Fix.** After the expect, the test cancels the task itself (`task.cancel()`) before awaiting it. A second cancel of a cancelled task changes nothing, so the passing run doesn't change; under the mutant, the expect fails and the test ends.

**Prevention.** When a test awaits something that ends only because of the behavior it checks (a cancel, a resume, a gate opening), end that thing in the test itself after the check: cancel the task, resume the continuation, open the gate. Run at least one mutant of the behavior and confirm that it fails, not that it times out. A mutant that deadlocks inside the code under test (a lock held across a callback that takes it) still hangs; that one is run one case per process with a timeout.
