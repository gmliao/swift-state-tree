---
module: SwiftStateTreeTransport tests
date: 2026-11-20
problem_type: testing_practice
component: test-fixtures
symptoms:
  - "a test run that never ends although the suite has a .timeLimit"
  - "a mutant run that hangs instead of failing"
  - "a test parked at a held TestGate after a regression"
  - "a mutant's test process sits at 0% CPU for most of an hour"
  - "a stopped mutation run starts its next mutant seconds later"
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
  - mutation-run
related:
  - "#458"
  - "#674"
  - "#702"
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

## Recurrence: #702's follow-up tests

The first draft of `FollowUpTests` (the turn core's follow-ups and quiescence wait) broke the rule above in three ways. The suite had `.timeLimit(.minutes(1))`, and still one mutant held a test process at 0% CPU for 47 minutes:

- **An awaited task's value.** A case starts `Task { await a.waitForQuiescence() }` and later reads `await waiter.value`. The quiescence wait does return when *its* task is cancelled, but the time limit cancels the test's task, not an unstructured task the test made. So a mutant that never wakes the waiter parks `.value` for good.
- **The test waiting at a fixture gate.** The test side called `Fixture.wait(_:)`, a continuation that ignores cancellation, for an event such as "at gate a" that a mutant may never bring.
- **A reply awaited with `.ignoresCancel`.** A `sendAndWait` whose reply a mutant holds back parks the same way.

A `Task.yield()` loop on a count (`while count < 2 { await Task.yield() }`) has the same flaw, but it spins rather than parks, so it shows as a busy process instead.

The fix gives the test target its own hang-bound helpers (`Tests/SwiftStateTurnsTests/Support/HangBound.swift`, 60 s like `testHangBound`, since that target doesn't link SwiftStateTreeTestSupport):

- `Fixture.reach(_:)` for the test's own gate waits;
- `settled(_:)` for an awaited task's answer;
- `bounded { ... }` for a direct quiescence wait.

A count the test could only read became an event it reaches: the registration hook opens "registered #n", a foreign completion opens "foreign #n".

All three race the awaited work against the bound and **never await the loser**: a reader task and a timer resume one continuation, whichever comes first, and the work is cancelled and abandoned. Cancelling and then awaiting it would not be enough, because a regression in the wait's own cancellation path (its `onCancel` hop) parks it the same way. The first version did exactly that. Case 35's reply is now awaited with `.cancelsCall` under the bound. Each helper records an issue when the bound runs out (or the expectation on its fallback fails), so the mutant fails the test instead of parking it. Effects and checks keep the plain `Fixture.wait`, because a test may end with one of them parked at a gate on purpose.

## Recurrence: the other turn suites (#711)

Converting the other suites' waits by grep wasn't enough. An event-withholding mutant (successful replies withheld, or no effect launched) still ran the full suite past 900 s, for three reasons:

- **Waits hidden behind a helper.** `waitForLog(n)` is an `.ignoresCancel` call the test makes through the actor, and `await register(…).result` awaits a helper's call task. A grep for the call shape misses both. Run the mutant, not only the grep.
- **Bounds in series.** A test that makes 20 waits in turn costs 20 bounds under a mutant, and 32 generated seeds cost 32. Each test fails, but the run takes many minutes. Once one wait has run out its bound, give the later ones a short one (`HangBoundTrip`).
- **Lines that must stay verbatim.** A wait inside a `// docs:` block can't be wrapped, so the test's whole body runs under the bound instead (`withinTestHangBound`).

When the test process is killed at a timeout, its buffered output is lost. Run it under a pty (`script -qfec`) to see which tests never ended.

## Stopping a mutation run

The same 47 minutes showed a second trap. The run was stopped by killing its build and test processes by name, because a shared measurement needed the machine. The driver, a script that applies each mutant, builds and tests, was not among those names. It saw its test exit, restored the source and started the next mutant's build 15 seconds later.

- Stop a mutation run at its driver first, then the build and test processes, so nothing respawns.
- Give each mutant's test run its own timeout well past the suite's run time, and count a timeout as killed (a hang is a failure the tests detected). Report which mutant hung.
- Make the driver restore the mutated file on a termination signal as well as on normal exit, and start each run from a clean tree, so a run cut short can't leave a mutant in place for the next build.
