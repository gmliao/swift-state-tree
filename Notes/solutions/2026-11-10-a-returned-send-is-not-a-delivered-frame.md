---
module: SwiftStateTreeTransport
date: 2026-11-10
problem_type: testing_practice
component: transport-send-queue
symptoms:
  - "test reads a connection's frames right after the call that sends them and finds none"
  - "errorCodes is empty on Linux CI, passes locally"
  - "Expectation failed: await connection.errorCodes == [...]"
root_cause: send_enqueues_and_a_drain_task_delivers_later
resolution_type: established_pattern
severity: low
tags:
  - testing
  - send
  - send-queue
  - linux
  - ordering
related:
  - "#372"
  - "2026-11-05-hold-points-not-timing-in-race-tests.md"
  - "#418"
---

# A returned send is not a delivered frame

## Problem

A #372 test awaited the join task and then read the test connection's frames for the expected `joinDenied` error. It passed in the PR's CI and locally, then failed once on exp/next's Linux CI: the connection had no error frame yet.

## Root cause

`WebSocketTransport.send(_:to:)` hands the frame to the session's send queue and returns. The queue's drain task calls the connection's `send` later. The router's join returns once the frame is queued, so the test's read raced the drain task. The router's ordering was correct: the frame was queued in order and delivered shortly after.

## Fix

The test connection resumes waiters from its `send`, through `waitForFrames(_:)`, a continuation rather than a poll. The test waits for the first frame before it reads the codes. A forced interleaving shows the difference: a test-only hold on the connection's `send` makes the old read fail every time, and the fixed test pass.

Three sibling tests in `JoinPendingInboundTests` had the same gap, and got the same fix:
- One read the frames after a keeper-state poll. It now waits for the frames it checks and asserts their count before an `allSatisfy`.
- Two took a frame-count baseline right after a disconnect, or after `waitForSyncQuiescenceForTesting`. A frame already inside `send` could land after the baseline. They now await the session's drain task after the disconnect, then take the count.

## Prevention

- A test that checks what a connection received waits for the connection to receive it: a waiter in the connection's `send`, or the session's send-queue drain task (`sendQueueDrainTaskForTesting`), captured before a disconnect and awaited after it. Returning from a router, adapter or transport call doesn't mean the frame was delivered.
- The adapter's test waits stop at the transport, not the connection. `waitForOutboundDrain` and `waitForSyncQuiescenceForTesting` return once the outbound writer has handed its frames to the transport. The session's drain task may still be inside `connection.send`. So a frame count taken right after them is not a stable baseline; add one of the delivery waits above.
- `awaitingClosed` shows that the close ran, not that earlier frames arrived. A direct `closeSession` cancels the queue first. Only `closeSessionAfterQueuedFrames` orders the close after the queued frames, and its timeout fallback doesn't.
- When a test asserts that every received frame has some property, first assert how many frames there are. An `allSatisfy` over frames still in the queue passes vacuously.
- To show such a test is sound, hold the connection's `send` with a gate, and check that the old read fails and the fixed test waits. Don't rely on loops passing: the bad interleaving is rare on a fast machine.
