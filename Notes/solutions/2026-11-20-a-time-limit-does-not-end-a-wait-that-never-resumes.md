---
module: SwiftStateTreeTransport tests
date: 2026-11-20
problem_type: testing_practice
component: test-fixtures
symptoms:
  - "a test run that never ends although the suite has a .timeLimit"
  - "a mutant run that hangs instead of failing"
  - "a test parked at a held TestGate after a regression"
root_cause: time_limit_records_a_failure_but_cannot_end_an_unbounded_await
resolution_type: design_rule
severity: medium
tags:
  - testing
  - time-limit
  - hang-bound
  - test-gate
  - mutants
  - hold-points
related:
  - "#458"
  - "#674"
---

# A time limit does not end a wait that never resumes

## Problem

`LandManagerSingleFlightTests.shutdownRejectsNewCreations` holds a creation at the `.creation` hold point (a `TestGate`), starts `shutdownAllLands`, and checks that a second creation is rejected. It awaited the second creation directly. Under a mutant that left `isShuttingDown` unset in `beginShutdown`, that creation was not rejected. It reached the held gate and parked there, so the test's `await` never returned. The suite had no time limit, and the run sat for 43 minutes.

Adding `.timeLimit(.minutes(2))` to the suite didn't help. The next run under the same mutant hung for 38 minutes as well.

## Root cause

Swift Testing's time limit records a failure and cancels the test's task. It can't end a wait that ignores cancellation. A `CheckedContinuation` nobody resumes, such as a `TestGate.arrive()` before `open()`, never returns, and the test process keeps waiting on it. So a time limit reports a slow test, but it isn't a bound on a test that can park forever.

## Fix

The test now observes the failure path itself instead of waiting through it:

- The `.creation` hold appends `creation` to the test's `EventLog` before it arrives at the gate.
- The late call runs in its own task, which appends `late-ended` when the call ends.
- The test waits for either event: `late-ended`, or a second `creation`. `EventLog.waitFor` is bounded by `testHangBound`.
- Then it counts the creations **from the log**, not from the gate's `arrivalCount`. The hold appends to the log before it arrives at the gate, so at that moment the gate's count can still read 1 with a second creation on its way.
- It opens the gate. Only if the wait settled does it read the late call's result; if the bound ran out, it cancels the call instead of awaiting something that may never end.

Under the mutant, the second `creation` entry ends the wait, and the test fails at once with "a creation started during the shutdown".

The waits on hooks that only resume on an event, such as `LandKeeper.waitUntilDrainStartedForTesting` and `LandRouter.waitForNoPendingFlipForTesting`, return when their task is cancelled. Tests run them under `withinHangBound` (in `SwiftStateTreeTestSupport`), which cancels them after `testHangBound` and reports `false`.

## Prevention

- When a regression can park the test at its own hold or gate, wait through a bounded event wait that ends on **either** outcome: the expected one, or the arrival that shows the regression. Never await an operation the test itself may be holding.
- A suite's `.timeLimit` is a report, not a bound. Every wait the test makes must already be bounded: `EventLog.waitFor`, `TestGate.waitForArrivals`, `RecordingConnection`'s waits (all `testHangBound`), a hook wait run under `withinHangBound`, or a value that can't park.
- Read the outcome from the record the test's own hook writes first, not from a counter the hook updates later in the same path.
- Prove it with the mutant that parks the operation. The mutant must fail in seconds on every run, not hang.

#674's inbound backlog suite was checked for the same assumption, and it doesn't rely on it. The test's own waits are `EventLog` waits bounded by `testHangBound`, and loop tasks always run. The delegate's held `onMessage` parks on the handler's chain, not in the test, so a test that ends leaves it parked without hanging. Its comment says a wait that runs out "reports its own message before the time limit ends the test". That reads as if the limit ended the test. The bound that actually ends it is `testHangBound`.
