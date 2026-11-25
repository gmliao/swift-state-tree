---
title: "A deadline wrapper runs its check once: a Bool inside it doesn't wait"
module: Tests (SwiftStateTreeTests)
date: 2026-11-25
problem_type: testing_practice
component: test-waits
symptoms:
  - "_ = try await withinDeadline(\"the slot is filled\") { await keeper.actionSlotIsFilledForTesting(sequence) } passes, and the next check sees the slot empty"
  - "a waiting-or-late test passes both cases without either being the case it names"
  - "a count read right after a withinDeadline check is 0 when the step it waited for should have made it 1"
root_cause: withindeadline_races_one_call_of_its_closure_and_returns_its_value_it_does_not_poll
resolution_type: design_rule
severity: medium
tags:
  - testing
  - deadline
  - hang-bound
  - test-hooks
  - continuation
  - registration-order
related:
  - "#700"
---

# A deadline wrapper runs its check once: a Bool inside it doesn't wait

## Problem

K1b-2's tests waited for an action job's slot to be filled with `_ = try await withinDeadline("the slot is filled") { await keeper.actionSlotIsFilledForTesting(sequence) }`, then read the failure table. The read found 0 entries where the filled slot should have held 1. The tests-first commit's "waiting or late" cases passed only because `awaitActionResult` waits anyway, so neither case was pinned.

## Root cause

`withinDeadline` (`Tests/SwiftStateTreeTests/WithinDeadline.swift`) races one call of its closure against the deadline and returns the closure's value. It doesn't call the closure again. A closure that returns a `Bool` answers once, at once, and `_ =` drops the answer. The wrapper bounds a wait; it doesn't make one.

## Fix

The keeper gained an observation-only hook, `watchActionSlotForTesting(_:waiter:)`. The call registers a watcher before it returns, and gives back an `AsyncStream` that yields once, in the segment that fills the slot or registers the waiter (or at once, if that already happened).

The test registers first, then releases what fills the slot, so the event can't come before the watcher. It then waits on the stream with `withinCancellingDeadline`. On a timeout, that bound records the failure, cancels the observer and waits for it to end. A cancelled stream ends its iteration, and its watcher is removed. The test returns on `nil`, with its gates released in a `defer`.

`withinDeadline` alone isn't enough here. `raceDeadline` leaves its work task running on a timeout and never cancels it (`Sources/SwiftStateTree/Support/Deadline.swift`, `DeadlineOutcome.timedOut`). A hook that ends on cancellation is necessary, but the bound must also cancel it.

A `while !(await check()) { await Task.yield() }` loop inside the wrapper also waits, but `lint-wall-clock-tests` refuses it as a yield poll.

## Prevention

- Inside `withinDeadline` or `withinHangBound`, put a call that suspends until the event happens, never a check that returns a `Bool`. Don't discard the wrapper's result: assert it.
- Register the watcher before releasing the step it watches. Otherwise the step can win, the hook's first lookup returns at once, and a mutant that never resumes the watcher passes.
- A new event hook must end when its task is cancelled, and the bound around it must cancel it: `withinCancellingDeadline`, not `withinDeadline`. See also [A hang bound can't end a wait that ignores cancellation](2026-11-21-a-hang-bound-cannot-end-a-wait-that-ignores-cancellation.md).
- A mutant that removes the step being waited for must fail the test by name.
