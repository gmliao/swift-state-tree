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
related:
  - "#700"
---

# A deadline wrapper runs its check once: a Bool inside it doesn't wait

## Problem

K1b-2's tests waited for an action job's slot to be filled with `_ = try await withinDeadline("the slot is filled") { await keeper.actionSlotIsFilledForTesting(sequence) }`, then read the failure table. The read found 0 entries where the filled slot should have held 1. The tests-first commit's "waiting or late" cases passed only because `awaitActionResult` waits anyway, so neither case was pinned.

## Root cause

`withinDeadline` (`Tests/SwiftStateTreeTests/WithinDeadline.swift`) races one call of its closure against the deadline and returns the closure's value. It doesn't call the closure again. A closure that returns a `Bool` answers once, at once, and `_ =` drops the answer. The wrapper bounds a wait; it doesn't make one.

## Fix

The keeper gained two observation-only hooks, `waitUntilActionSlotFilledForTesting(_:)` and `waitUntilActionResultHasWaiterForTesting(_:)`. Each is resumed in the segment that fills the slot or registers the waiter. It returns early when its task is cancelled, so the deadline can end it (see the related entry), and it returns whether the condition holds. The tests write `#expect(try await withinDeadline("…") { await keeper.waitUntil…(sequence) } == true)`.

A `while !(await check()) { await Task.yield() }` loop inside the wrapper also waits, but `lint-wall-clock-tests` refuses it as a yield poll.

## Prevention

- Inside `withinDeadline` or `withinHangBound`, put a call that suspends until the event happens, never a check that returns a `Bool`. Don't discard the wrapper's result: assert it.
- A new event hook must end when its task is cancelled. Otherwise the bound can't end it either: [A hang bound can't end a wait that ignores cancellation](2026-11-21-a-hang-bound-cannot-end-a-wait-that-ignores-cancellation.md).
- A mutant that removes the step being waited for must fail the test by name.
