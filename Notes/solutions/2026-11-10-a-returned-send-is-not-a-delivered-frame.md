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
---

# A returned send is not a delivered frame

## Problem

A #372 test awaited the join task and then read the test connection's frames for the expected `joinDenied` error. It passed in the PR's CI and locally, then failed once on exp/next's Linux CI: the connection had no error frame yet.

## Root cause

`WebSocketTransport.send(_:to:)` hands the frame to the session's send queue and returns. The queue's drain task calls the connection's `send` later. The router's join returns once the frame is queued, so the test's read raced the drain task. The router's ordering was correct: the frame was queued in order and delivered shortly after.

## Fix

The test connection resumes waiters from its `send`, through `waitForFrames(_:)`, a continuation rather than a poll. The test waits for the first frame before it reads the codes. A forced interleaving shows the difference: a test-only hold on the connection's `send` makes the old read fail every time, and the fixed test pass.

## Prevention

- A test that checks what a connection received waits for the connection to receive it: a waiter in the connection's `send`, or `awaitingClosed` for a close. It never treats the return of the router, adapter or transport call as delivery.
- To show such a test is sound, hold the connection's `send` (a gate) and check that the test still waits rather than reading too early. Don't rely on loops passing; the bad interleaving is rare on a fast machine.
