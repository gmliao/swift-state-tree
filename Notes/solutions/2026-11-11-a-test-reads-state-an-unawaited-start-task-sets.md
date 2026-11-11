---
module: SwiftStateTree, tests
date: 2026-11-11
problem_type: testing_practice
component: keeper-initialization
symptoms:
  - "A test passes on the default configuration and fails on CI's `IN_TURN_SYNC=false` (or another) leg"
  - "`hasTickLoopForTesting()` / `hasSyncLoopForTesting()` is false right after `getOrCreateLand` returns"
  - "A test reads state right after a call returns, and that state is set by a task the call started but didn't await"
  - "A \"nothing happened\" assertion (no loop, no ack, no frame) can pass even with the code that should cause it removed"
root_cause: assertion_reads_state_set_by_an_unawaited_task
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - initialization
  - in-turn-sync
  - configurations
  - vacuous-assertion
related:
  - "#505"
  - "#504"
---

# A test reads state that an unawaited start task sets

## Problem

`LandKeeper.init` starts its initialization in a `Task` it doesn't await. `performInitialization` runs `OnInitialize` and only then starts the tick and sync loops. So when `LandManager.getOrCreateLand` returns, the keeper exists, but its loops may not have started yet.

A test that read `hasTickLoopForTesting()` right after `getOrCreateLand` passed on the default configuration and failed on CI's `IN_TURN_SYNC=false` leg. The code under test was correct (#505). Whether the read came before or after the task's end depended on what else that configuration's path awaited first.

The race didn't show on macOS: with the await removed, the suite passed three runs alone and two full-target runs under `IN_TURN_SYNC=false`. A local pass says nothing about a read like this; the code does.

The same read weakened the opposite test: "with `autoStartLoops: false`, no loop runs" could pass whether or not the flag did anything, whenever the read came before the loops would have started.

A test reading the ack state before the land's first sync had committed (#504) was the same class: it read a result that a step not yet awaited would produce.

## Fix

Await the event that sets the state, not the call that started it:

```swift
let container = try await manager.getOrCreateLand(...)
await container.keeper.awaitInitialization()   // returns after the loops are started
#expect(await container.keeper.hasTickLoopForTesting())
```

`awaitInitialization()` (package) waits for `ensureInitialized`, whose task ends after the loops are configured. No sleep, no poll. It swallows an initialization failure, though: for a land that can fail to initialize, a "no loop" assertion after it is vacuous again, so assert the initialization succeeded too.

## Rule

- Before asserting on state, find what sets it. If that is a task the call under test started and didn't await, await that task's own completion (an `await…` accessor, a hold point, a `TestGate` arrival), never the returning call.
- A "nothing happened" assertion needs the same anchor: assert it after the point where the thing would have happened. Check it with a mutant: remove the code that prevents it, and the test must fail. (In #505, a manager that ignores `autoStartLoops: false` fails the test on every configuration once the test awaits initialization.)
- A test that reads state a task sets must pass on every configuration CI runs (default, `IN_TURN_SYNC=false`, `USE_SYNC_TABLES=true`). Run them all locally before reporting it green.
