---
module: SwiftStateTree
date: 2026-11-09
problem_type: testing_practice
component: land-keeper-tests
symptoms:
  - "swift test never finishes; the process sleeps at low CPU while lands keep ticking"
  - "a test awaits a keeper effect (a run started, a recorder flushed) that never comes"
  - "an OnJoin effect is missing right after keeper.join returns"
root_cause: test_awaits_effect_of_unapplied_lifecycle_input
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - keeper
  - tick
  - lifecycle-input
  - hang
  - time-limit
related:
  - "#385"
---

# A test on a ticking land awaits a join's effect without stepping the turn that applies it

## Problem

A test of the reevaluation monitor land joined a player and then awaited the run that the land's `OnJoin` requests (`waitForRunsStartedForTesting(1)`). The run never started, so the await never resumed. The suite had no time limit, so `swift test` hung for over an hour instead of failing, and held the shared build machine while it did.

## Root cause

On a land with a `Tick`, `LandKeeper.join` doesn't run `OnJoin`. It queues the join as a lifecycle input (`PendingItem.lifecycle`, `.join`), and the next tick turn applies it, in sequence order with the land's other inputs. The test built the keeper with `autoStartLoops: false` and never called `stepTickOnce()` after the join, so no turn applied it. The effect the test awaited was waiting for that turn.

A wait with no bound turns that mistake into a hang: the test can't fail, and the output says nothing about which test is stuck.

## Fix

- Step the turn: `await keeper.stepTickOnce()` after each `join` (and `leave`) whose effect the test checks.
- Assert the effect isn't there before that turn. That pins the input-turn semantics, and makes a missing step fail at an `#expect` instead of a wait.
- Put `.timeLimit(.minutes(1))` on every suite that awaits keeper or runner effects, and make the waits honor cancellation. When the limit passes, Swift Testing records the failure and cancels the test's task; it doesn't stop a wait that ignores cancellation. A `withCheckedContinuation` with no cancellation handler kept the process alive after the failure was recorded. `waitForRunsStartedForTesting` now resumes on cancellation (`withTaskCancellationHandler`), and the tests' polling loops call `Task.checkCancellation()`.

## Prevention

- On a ticking land, a lifecycle input (join, leave) and an action are turn inputs. A test that checks their effect steps the tick first, or drives the land's loops.
- Every await on a keeper effect in a test is bounded: a suite `.timeLimit` over waits that end on cancellation, or a `TestGate`/`HoldPoints` the test itself releases. A test-only wait helper built on a continuation needs a cancellation handler, or the time limit only records the failure. A test that hangs instead of failing is a defect in the test.
- When a test run stalls, sample the test helper process: the stacks name the land types still ticking, which narrows the suite.

## Candidates

Suites in `Tests/` that await keeper or adapter effects (`waitFor…ForTesting`) and have no `.timeLimit`, to bound in a later change (check, too, that the helper they await ends on cancellation):
- `SwiftStateTreeTests/FullStateHashTests.swift` (`waitForRecorderSubmissionsForTesting`)
- `SwiftStateTreeTests/ReevaluationRecordLogReplayTests.swift` (`waitForRecorderSubmissionsForTesting`)
- `SwiftStateTreeTests/LandKeeperClientEventQueueTests.swift` (`waitForInFlightWorkForTesting`)
- `SwiftStateTreeTransportTests/RecordLogLiveRunTests.swift` (`waitForRecorderSubmissionsForTesting`)
- `SwiftStateTreeTransportTests/RecordTurnBoundaryLiveTests.swift` (`waitForRecorderSubmissionsForTesting`)
- `SwiftStateTreeTransportTests/TransportAdapterSyncLagTests.swift` (`waitForSyncQuiescenceForTesting`)
- `SwiftStateTreeTransportTests/JoinPendingInboundTests.swift` (`waitForInboundDrainForTesting`, `waitForSyncQuiescenceForTesting`, `waitForActionResponsesFinishedForTesting`)
