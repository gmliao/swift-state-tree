---
module: Tests (SwiftStateTreeTestSupport)
date: 2026-11-21
problem_type: testing_practice
component: test-gates
symptoms:
  - "a test wrapped in withinHangBound hangs instead of failing by name when the code under test never reaches its hook"
  - "a hook that never fires stalls the whole test run; the bound's timeout never ends it"
  - "await withinHangBound { await gate.arrive() } returns only when someone opens the gate"
  - "a routing change that skips a hold point parks the whole test run at WatermarkGate.waitUntilEntered()"
root_cause: testgate_arrive_is_a_checked_continuation_without_a_cancellation_handler
resolution_type: design_rule
severity: medium
tags:
  - testing
  - hang-bound
  - cancellation
  - test-gate
  - continuation
  - watermark-gate
related:
  - "#719"
  - "#724"
  - "#546"
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

## Recurrence: `WatermarkGate` in `SwiftStateTreeTests` (#546 L2d-2)

`WatermarkGate.waitUntilEntered()` had the same shape: a plain `withCheckedContinuation`, no cancellation handler, no bound, at 57 call sites in a target that can't use `testHangBound` (it doesn't import `SwiftStateTreeTestSupport`). L2d-2 sent every live keeper through turns, so two tests' holds on legacy-only points (`.legacyShutdownPass`, `.ticklessJobPass`) never fired. Each test parked at its entry wait, and the suite's `.timeLimit(.minutes(1))` reported them without ending them: the full run sat for 20 minutes until it was killed.

The entry wait is now bounded itself. `waitUntilEntered(_ step:deadline:)` (10 s by default) races the wait with `raceDeadline`. On a timeout it removes and resumes its registered wait, records "WatermarkGate never entered within …: <step>" at the caller's line, and returns `false`.

A bound alone isn't enough. The first version was `@discardableResult`, and review found callers that then parked at the next unbounded await: a freeze wait with nothing in flight, or `await shutdown.value` behind a `withinDeadline` wrapper whose `Bool?` was `.some(false)`. The result is now required. Each test-body site guards it (`guard await gate.waitUntilEntered() else { return }`), and the wrapped sites drop the wrapper and keep its label as `step`. A helper that waits returns an optional, so its callers guard too (`sendHeld`). Only a hook with nothing after it discards the result (`_ =`).

- Mutants: remove `holds.at(.turnRecord)` or `holds.at(.ticklessJobPass)` from `LandKeeper`. The tests that wait for those holds fail by name within the bound, and the run ends.
- Make the gate report success on a timeout. "A caller whose entry times out returns instead of parking at the next await" then fails by name instead of hanging.
- Rule: when a wait can fail, return on that failure whenever something unbounded follows. A bounded wait whose failure is ignored only moves the hang one step later.
