---
title: "A returned send is not a delivered frame"
module: SwiftStateTreeTransport
date: 2026-11-10
problem_type: testing_practice
component: transport-send-queue
symptoms:
  - "test reads a connection's frames right after the call that sends them and finds none"
  - "errorCodes is empty on Linux CI, passes locally"
  - "Expectation failed: await connection.errorCodes == [...]"
  - "a job's state is still empty after waitForFrames(before + 1) (InputDecodeOnceTests, #708)"
root_cause: send_enqueues_and_a_drain_task_delivers_later
resolution_type: established_pattern
severity: low
tags:
  - testing
  - send
  - send-queue
  - linux
  - ordering
  - frame-count-wait
related:
  - "#372"
  - "2026-11-05-hold-points-not-timing-in-race-tests.md"
  - "#418"
  - "#708"
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

## A second site: a count wait met by an earlier frame (#708)

`InputDecodeOnceTests.jobWalkedOnce` read the transport's frame count right after its join fixture, then waited for one more frame (`waitForFrames(before + 1)`) and took that frame as the job's answer. The join's frames reach the transport on the adapter's outbound writer task, so a join frame that landed after the count was read met the wait while the job's resolver was still running. It failed once on main's CI (ba646a75, "Tests, per-player sync tables off", argument `json`).

The fix waits for outbound idle before reading the count. It then waits for the job's answer by its requestID: it reads each frame as it arrives and skips any other. A proof test holds the join's delivery at the transport and the job's resolver at a gate (a task local the job's tasks inherit). It reads the count without the idle wait and releases the join's frames. It then asserts that the old wait's condition is met with nothing applied. A count-based mutant of the new wait fails it on all five codecs (json, opcode, messagepack and two foreign codecs). The test holds its resolver behind a gate, so it runs with `.resolverDeadlinesOff`: under the default 5 s deadline, a slow runner would end the job with a deadline error before the gate opens.

## Prevention

- Wait for the frame you mean, found by its content (a requestID, a type), not by a count. A count wait is met by any frame, including one sent earlier and delivered late.
- A baseline count taken right after a join, a connect or any call that sends is not stable until the outbound writer is idle (`waitForOutboundIdleForTesting`). `awaitJoined` waits for the join flip, not for delivery.

- A test that checks what a connection received waits for the connection to receive it: a waiter in the connection's `send`, or the session's send-queue drain task (`sendQueueDrainTaskForTesting`), captured before a disconnect and awaited after it. Returning from a router, adapter or transport call doesn't mean the frame was delivered.
- The adapter's test waits stop at the transport, not the connection. `waitForOutboundDrain` and `waitForSyncQuiescenceForTesting` return once the outbound writer has handed its frames to the transport. The session's drain task may still be inside `connection.send`. So a frame count taken right after them is not a stable baseline; add one of the delivery waits above.
- `awaitingClosed` shows that the close ran, not that earlier frames arrived. A direct `closeSession` cancels the queue first. Only `closeSessionAfterQueuedFrames` orders the close after the queued frames, and its timeout fallback doesn't.
- When a test asserts that every received frame has some property, first assert how many frames there are. An `allSatisfy` over frames still in the queue passes vacuously.
- To show such a test is sound, hold the connection's `send` with a gate, and check that the old read fails and the fixed test waits. Don't rely on loops passing: the bad interleaving is rare on a fast machine.
