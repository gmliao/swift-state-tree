---
title: "A test on a ticking land awaits a join's effect without stepping the turn that applies it"
module: SwiftStateTree
date: 2026-11-09
problem_type: testing_practice
component: land-keeper-tests
symptoms:
  - "swift test never finishes; the process sleeps at low CPU while lands keep ticking"
  - "a test awaits a keeper effect (a run started, a recorder flushed) that never comes"
  - "an OnJoin effect is missing right after keeper.join returns"
  - "a test's in-turn join is already flipped (no longer joining) when the test freezes or checks it, in about 1 run in 3"
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
  - tickless
  - join-flip
  - input-drain
related:
  - "#385"
  - "#546"
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

## The tickless counterpart: the OnJoin turn can flip a registered join

On a land without a `Tick`, the join's `OnJoin` is an input too: the keeper's input drain runs it in an input turn, and that turn's output step runs the sync phase while joins wait (`!hasPeriodicSync && transportHasJoinsAwaitingSync`). The adapter's join registers the session with the transport after the keeper join returns, and that input turn can run before or after the registration. When it runs after, its phase flips the join. That is by design: the turn that consumed a join's input completes the join.

A test that wanted a join that is ready but not flipped (#546 L2b, the resume's cases) held the join only at `.joinSyncRequested`, after the registration. In about one run in three, the OnJoin turn had not run yet. It ran between the hold and the test's freeze, and flipped the join early. A keeper probe (the turn kind and `transportHasJoinsAwaitingSync` before and after each phase) showed the turn.

Fix: hold the join at `.keeperJoinReturned` (admitted, not registered), wait for `keeper.waitForInputDrainIdleForTesting()` under `withinHangBound`, then open the hold and wait at `.joinSyncRequested`. The OnJoin turn has then run while the join couldn't flip, and nothing else flips it until the test acts. `TransportAdapterJoinFlipTests` has the helper (`readyUnflippedJoin`). On a tick land the same order applies with `stepTickOnce()` in place of the drain wait: the tick consumes OnJoin while the join is held before its registration.

Rule: a test that needs a join ready but unflipped lets the join's own input turn finish before the join registers. A hold after the registration alone races that turn.

Two limits of the construction: both join holds are inside the adapter's membership queue, which runs one join at a time, so only one join can wait at them. And `setJoinFlipHeldForTesting(true)` on a tickless land makes every commit schedule another join-sync turn while the joins wait, a busy loop, so it can't stand in for the holds.

## Candidates

Suites in `Tests/` that await keeper or adapter effects (`waitFor…ForTesting`) and have no `.timeLimit`, to bound in a later change (check, too, that the helper they await ends on cancellation):
- `SwiftStateTreeTests/FullStateHashTests.swift` (`waitForRecorderSubmissionsForTesting`)
- `SwiftStateTreeTests/ReevaluationRecordLogReplayTests.swift` (`waitForRecorderSubmissionsForTesting`)
- `SwiftStateTreeTests/LandKeeperClientEventQueueTests.swift` (`waitForInFlightWorkForTesting`)
- `SwiftStateTreeTransportTests/RecordLogLiveRunTests.swift` (`waitForRecorderSubmissionsForTesting`)
- `SwiftStateTreeTransportTests/RecordTurnBoundaryLiveTests.swift` (`waitForRecorderSubmissionsForTesting`)
- `SwiftStateTreeTransportTests/TransportAdapterSyncLagTests.swift` (`waitForSyncQuiescenceForTesting`)
- `SwiftStateTreeTransportTests/JoinPendingInboundTests.swift` (`waitForInboundDrainForTesting`, `waitForSyncQuiescenceForTesting`, `waitForActionResponsesFinishedForTesting`)
