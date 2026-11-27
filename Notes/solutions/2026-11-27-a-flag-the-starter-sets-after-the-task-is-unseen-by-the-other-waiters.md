---
title: "A flag the starter sets after awaiting a shared task is unseen by the task's other waiters"
module: SwiftStateTree
date: 2026-11-27
problem_type: bug_class
component: land-keeper-initialization
symptoms:
  - "awaitInitialization returns, but the keeper still reports didInitialize == false"
  - "A caller that waited for the initialization takes the slow path once more"
  - "A test that adds its own awaitInitialization Task counts an extra initialization waiter"
root_cause: completion_flag_written_by_one_waiter_after_its_own_wake
resolution_type: design_rule
severity: medium
tags:
  - land-keeper
  - initialization
  - waiter
  - lost-wakeup
  - reentrancy
  - hold-point
related:
  - "#934"
  - "#700"
---

# A flag the starter sets after awaiting a shared task is unseen by the task's other waiters

## Problem

`ensureInitialized` created the initialization task, awaited `task.value`, and then set `model.didInitialize = true` and resumed the initialization watchers. Every other caller awaited the same task. When the task ends, all of its waiters become runnable, and the actor runs them in any order. A waiter that ran before the starter read `didInitialize == false` after its own wait had returned (#934).

## Root cause

The completion was written by one of the waiters, the one that started the work, after its own wake, instead of by the work. "The task ended" and "the flag is set" were two events with an actor hop between them, and only the starter saw both in order.

## Fix

The initialization's last segment, `initializeDone`, sets `didInitialize` in a turn inside the task, after the loops are configured. Every exit sets it before the task ends: `initializeFail` does too. The watchers are resumed by the driver, also before the task ends. The starter only clears `initializationTask` (#700 K2-1b).

## Prevention

- Completion state for shared work belongs to the work: write it in the work's last step, before the task (or the continuation) completes, never in the awaiting caller after its `await`.
- To pin it, hold the starter after its `await task.value` (`LandKeeperHoldPoint.initializationStarterResumed`) and check that another waiter reads the state done. Without the hold, the order is the scheduler's and the test passes by chance.
- A keeper starts its initialization when it is created. A test that spawns its own `awaitInitialization` Task adds an initialization waiter of its own, so `waitForInitializationWaitersForTesting(n)` counts it. Wait on the resolver's gate, or on the caller under test, instead.
