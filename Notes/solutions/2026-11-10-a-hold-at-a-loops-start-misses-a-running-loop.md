---
module: SwiftStateTree
date: 2026-11-10
problem_type: testing_practice
component: keeper-input-drain
symptoms:
  - "a test installs a hold at .inputDrain, queues an input, and the hold is never entered"
  - "withinDeadline times out waiting for the hold; the input was applied anyway"
  - "passes in one run, fails in the next"
root_cause: a_running_loop_takes_new_work_without_passing_its_start_again
resolution_type: established_pattern
severity: low
tags:
  - testing
  - hold-points
  - keeper
  - input-drain
  - flaky
related:
  - "2026-11-05-hold-points-not-timing-in-race-tests.md"
  - "#382"
---

# A hold at a loop's start misses work a running loop picks up

## Problem

Two tests for the forced shutdown's turn (#382) held the keeper's input drain at `.inputDrain`, queued the shutdown input, and waited for the hold. Sometimes the hold was never entered and the test timed out: the shutdown had already been applied.

## Root cause

`.inputDrain` is at the start of `runInputDrain`, which loops over ready inputs until none is left. `scheduleInputDrain` starts a new drain only when none is scheduled (`inputDrainScheduled`). The test's previous step (a join or a leave) had started a drain that was still looping. The shutdown input joined that loop and was applied without the loop passing its start again, so the hold was skipped.

## Fix

Before installing the hold, wait until no drain is scheduled (`inputDrainScheduledForTesting() == false`). The next input then starts a fresh drain, which enters the hold.

## Prevention

- A hold at the start of a loop holds only a loop that starts after it is installed. Before relying on one, wait for the loop already running to end, through a test hook on its flag, not a sleep.
- Treat a hold that "sometimes isn't entered" as this trap first: some other runner took the work.
