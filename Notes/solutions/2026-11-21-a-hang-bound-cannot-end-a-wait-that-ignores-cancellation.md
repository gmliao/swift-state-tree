---
module: Tests (SwiftStateTreeTestSupport)
date: 2026-11-21
problem_type: testing_practice
component: test-gates
symptoms:
  - "a test wrapped in withinHangBound hangs instead of failing by name when the code under test never reaches its hook"
  - "a hook that never fires stalls the whole test run; the bound's timeout never ends it"
  - "await withinHangBound { await gate.arrive() } returns only when someone opens the gate"
root_cause: testgate_arrive_is_a_checked_continuation_without_a_cancellation_handler
resolution_type: design_rule
severity: medium
tags:
  - testing
  - hang-bound
  - cancellation
  - test-gate
  - continuation
related:
  - "#719"
  - "#724"
---

# A hang bound can't end a wait that ignores cancellation

## Problem

A test waited for a hook to fire with `withinHangBound { await gate.arrive() }`, where the hook opened the gate. The bound is meant to turn "the code never got there" into a named failure after `testHangBound`. It didn't: when the hook never fired, the test sat until the run was killed. #719 and #724 each shipped this shape, and review caught it both times.

## Root cause

`withinHangBound` ends a wait by cancelling the task that runs it. `TestGate.arrive()` suspends in a plain `withCheckedContinuation`, with no cancellation handler, so cancelling its task changes nothing: it resumes only on `open()`. Any continuation-based wait without `withTaskCancellationHandler` behaves the same way under a bound.

## Fix

Wait with a call that ends on cancellation and on its own bound. `TestGate.waitForArrivals(_:)` is resumed by the arrival. It returns `false` when its task is cancelled, and `false` after `testHangBound`. The hook now arrives at an already-open gate, and the test waits with `waitForArrivals(1)` (`OutboundWriterIdleWaitTests.registeredWait`, #546 L2d-1).

## Prevention

- Never put `TestGate.arrive()`, or any other wait with no cancellation handler, inside `withinHangBound` to wait for code under test. Let the code under test arrive, and have the test wait with `waitForArrivals`, or with another event wait that handles cancellation.
- A mutant catches it: remove the hook call. The test must fail by name within the bound, not hang.
- Related: [Force the interleaving with hold points, not timing](2026-11-05-hold-points-not-timing-in-race-tests.md).
