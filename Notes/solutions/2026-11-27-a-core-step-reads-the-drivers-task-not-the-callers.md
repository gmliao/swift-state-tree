---
title: "A core step that reads `Task.isCancelled` or a task-local reads the driver's task, not the caller's"
module: SwiftStateTree
date: 2026-11-27
problem_type: bug_class
component: turn-core-adoption
symptoms:
  - "a cancelled caller's action job starts on the core but not on the keeper"
  - "an uncancelled caller fails with CancellationError after its sequence was taken"
  - "Task.checkCancellation() inside a turn body"
root_cause: ambient_task_state_read_in_a_step_that_runs_on_another_task
resolution_type: design_rule
severity: high
tags:
  - turn-core
  - cancellation
  - task-local
  - reentrancy
related:
  - "#700"
  - "#944"
  - "#948"
---

**Problem.** On the keeper, an entry's body runs in the caller's task, so `Task.isCancelled`, `Task.checkCancellation()` and `@TaskLocal` reads inside it see the caller. On a `TurnCore`, the same body runs in a step, and a step runs on whichever task drives the core: the sender's own `send`, another caller's `sendAndWait`, or an effect's completion. The read moves to a different task without any change in the code.

**Symptoms.** The action intake's `try Task.checkCancellation()` (before `startActionJob`) behaved differently on the two paths:
- a cancelled runner failed an uncancelled caller after `sequence.take()`;
- an uncancelled runner started a cancelled caller's job.

The keeper/core differential found it (`cancelledCallerJobNotStarted`). #944 had moved `initializeResolved`'s `Task.isCancelled` out of the segment for the same reason.

**Root cause.** The ambient state belongs to the task, not to the input. A machine step has no caller task to read.

**Fix.** The sender reads the state in its own segment and the input carries it. Here `.action(…, cancelled:)` and `.admitAction(…, cancelled:)` carry the read, the keeper's `submit` reads `Task.isCancelled` before its turn, and `actionIntake` takes `callerCancelled: Bool`.

**Prevention.**
- A turn body that a core step can run never reads `Task.isCancelled`, `Task.checkCancellation()`, `withUnsafeCurrentTask`, or a `@TaskLocal`. Each such value is read by the sender and rides the input, as the turn core's `now` comes from the core's clock and not from the step's task.
- Review new core-routed bodies with a grep for these names.
- Pin each carried value with a differential case where the two tasks differ: a cancelled caller with an uncancelled driver.
- An input that waits on the core (held at a barrier, parked behind a key) re-reads ambient state at the step that resumes it, not at the send. The keeper re-reads `Task.isCancelled` after `debugWaitWhileFrozen`, so a caller cancelled while held starts no job. The send's read can't see that cancellation. A cancellation the keeper reads synchronously can't be replaced by one delivered asynchronously: a hop from `onCancel` to the core (a cancellation entry, a machine hook) can lose to a step that resumes the input first. Carry a set-once flag set in the caller's `onCancel` with the input, and read it at the resuming step, as `awaitActionResult` does with `box.callerCancelled` (#948 rounds 2–3; `parkedCallerCancelledBeforeResume` sends the resume right after `cancel()` returns).
- A test watcher counts events; it doesn't read current state. A watcher installed after the event it waits for ("N callers wait") reads a state that has already moved on (one caller registered and timed out), and waits forever. Count registrations monotonically and compare against that (#948 round 3, `waitUntilFreezeRegistrationsForTesting`).
- Candidates still open: the resolver-deadline task-locals (`ResolverDeadline.overrideForTesting`) where a job's deadline is read in a step.
