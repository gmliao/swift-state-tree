---
module: SwiftStateTreeNIO tests, Support/Lifecycle
date: 2026-11-25
problem_type: bug_class
component: shutdown-tests
symptoms:
  - "GracefulShutdownTests failed once on the nightly build (variants) job and passed on PR runs"
  - "await f.players() == [\"p1\"] failed right after the router's .afterAdmit hold arrived"
  - "lifecyclePhaseForTesting was .stopping right after run() returned"
root_cause: a_signal_that_a_step_ended_was_read_as_the_end_of_work_that_another_continuation_does_after_it
resolution_type: design_rule
severity: low
tags:
  - testing
  - flaky
  - join
  - input-drain
  - lifecycle
  - reentrancy
related:
  - "#833"
  - "#194"
  - "#683"
---

# A step that ended doesn't mean what runs after it has run

## Problem

Two tests failed rarely, on the loaded `build (variants)` job only. Both read a result right after a signal that the step had ended, and the result is written by a continuation that runs after the signal, on the same executor.

1. **`.afterAdmit` doesn't imply OnJoin ran.** On a tickless land the keeper's in-turn join admits the session, schedules the input drain and returns. OnJoin runs in that drain's turn, in a task of its own. The router's `.afterAdmit` hold comes after the keeper's join returned, but the drain may not have run. A read of the land's state there returned `[]`.
2. **A joiner of a `Lifecycle` stop returned before the phase was written.** The runner awaits the stop's task and then calls `finishStop(token)`; a joiner only awaited the task. When the task ends, both continuations are ready on the actor, and either may run first. `NIOLandHost.run()` joins the stop another caller runs (the cancel handler's), so it could return while the phase was `.stopping`.

## Root cause

Awaiting a task or a hold resumes you in a segment of your own. Bookkeeping that another party does after the same event (a drain's turn, the runner's finish call) is a separate continuation: the order of the two isn't defined, and a loaded machine shows the other order.

## Fix

- Test: wait for the keeper's input drain (`waitForInputDrainIdleForTesting`) before reading OnJoin's state, never for the state itself.
- `Lifecycle`: the task records its own end (the shape of `SingleFlight`'s flights: the producer resolves, the waiters only await). `beginStart`/`beginStop` mint the token and hand it to `make`; `NIOLandHost`'s task bodies (`runStart`, `runShutdown`) call `finishStart(token, succeeded:)` / `finishStop(token)` as their last actor-isolated step. A runner and a joiner then only await the task, and both see the phase it wrote, if that start is still current: a stop that took over before the start's task ended makes the start's finish a stale no-op. (A first version had each waiter call the finish after `await task.value`; the tests then drove a test-local copy of that recipe and the shipped joiner was unwitnessed. A recipe the caller must follow is a recipe a test can't pin from outside.)

## Prevention

- When a result is written by a continuation other than the one you await, wait on that continuation's own signal (the drain, the flip, a gate), not on the first event.
- A helper that lets callers join an in-flight task must make a joiner's return mean what the runner's means. Prefer the task doing its own bookkeeping as its last step over asking every waiter to repeat it: nothing is left for a caller to forget, and a host-level test of any waiter witnesses the shipped code.
- Pin the guards a finish relies on: a start's token must not stop the lifecycle (the phase guard is the only barrier, `finishStart` leaves the token set), a late finish of an earlier start must leave a retry alone, and a second finish of the same start or stop is a no-op.
- Force the losing order with a hold (`.inputDrain` for the drain; a runner held before its finish call, in an actor test, for `Lifecycle`) so the test is red without the fix, with no timing. `GracefulShutdownTests` (`onJoinRunsInTheInputDrainAfterAfterAdmit`) and `ReentrancyHelpersTests` (the finish-guard tests) and `GracefulShutdownTests` (`startReturnsAfterTheRunningPhase`, `shutdownReturnsAfterTheStoppedPhase`: a held start or shutdown, whose runner, joiner and `run()` must all return in the phase) pin both.

See also [A ticking land applies a join in its next turn](2026-11-09-a-ticking-land-applies-a-join-in-its-next-turn.md) (the tickless OnJoin turn) and [A helper that returns on state leaves its operation running](2026-11-20-a-helper-that-returns-on-state-leaves-its-operation-running.md).
