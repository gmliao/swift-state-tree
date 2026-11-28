---
title: "A hang guard in a task group waits for the hang"
module: SwiftStateTreeNIO
date: 2026-11-17
problem_type: testing_practice
component: land-stop-teardown
symptoms:
  - "a deadlock mutant makes the run time out with no failure recorded"
  - "a bounded wait built on withTaskGroup never returns although its timer fired"
  - "the test records its issue, then hangs in the host's shutdown, and the killed run prints nothing"
root_cause: task_group_awaits_every_child_and_a_hung_teardown_hangs_cleanup
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - hang-bound
  - deadlock
  - task-group
  - mutants
related:
  - "#535"
  - "#974"
  - "Notes/solutions/2026-11-05-hold-points-not-timing-in-race-tests.md"
---

# A hang guard in a task group waits for the hang

## Problem

The tests for a failed land's host stop (#535 PR 1 part B2) check that the teardown and the stop don't wait on each other. A mutant that makes them do so should fail its test, but the run ran into its outer timeout with no recorded failure.

## Root cause

There were two causes:
- **The guard waited for the hang.** The guard raced the body against a sleep in `withTaskGroup` and took the first result, then cancelled the group. A task group doesn't return until every child has ended. A child awaiting a deadlocked `forceShutdown` ignores cancellation, so the guard's timer fired and the guard still never returned.
- **Cleanup hit the same hang.** Once the guard returned, the test went on to `host.shutdown()`. The shutdown destroys the deadlocked instance and hangs on it. The process was then killed, and its buffered output, including the recorded issue, was lost.

## Fix

The guard (`bounded` in `GracefulShutdownTests.swift`) runs the body and the timer as unstructured tasks. The first to settle resumes one continuation, so a body that never returns doesn't hold the caller. When the guard times out, the test records the issue and returns before the host's shutdown.

## Prevention

- A hang guard must not await the work it guards. Don't build it on `withTaskGroup`, `async let` or `Task.value` of the guarded work. Race unstructured tasks into a single continuation instead.
- When the guard fires, end the test there. Skip any cleanup that would touch the hung instance.
- Check a deadlock mutant by its recorded issue, not by the run's exit code. A timeout with no recorded issue means the guard itself hung.
- A `.timeLimit` doesn't bound a wait on an unstructured task's value. It cancels the test's task, and `await task.value` doesn't end until that task ends, which cancellation doesn't force. Have the task append an event when it ends, and bound the wait on that event (`EventLog.waitFor`) before reading the value (#974: a join under `timeout: .zero` whose resume never came ran past 200 s under a 1-minute limit).
