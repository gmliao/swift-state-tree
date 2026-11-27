---
title: "A waiter table's entry leaves in the step its waiter leaves, and a wait takes a budget, not an absolute deadline"
module: SwiftStateTurns
date: 2026-11-27
problem_type: design_pattern
component: turn-core-barrier
symptoms:
  - "a waiter count includes a caller that has already thrown CancellationError"
  - "a timeout fires long after its caller left, and takes a mail ordinal for a reply nobody waits for"
  - "a large wait budget is answered as expired at once"
root_cause: the_wait_entry_and_the_waiter_had_separate_lifetimes_and_the_deadline_was_computed_by_the_caller_with_wrapping_arithmetic
resolution_type: design_change
severity: medium
tags:
  - turn-core
  - barrier
  - cancellation
  - deadline
  - reentrancy
related:
  - "#953"
  - "#948"
  - "#958"
---

## Problem

Revision 0 of #953's barrier design left a withdrawn caller's entry in the table until the next release or timeout. The withdraw had already resumed the caller with `CancellationError`, so the entry was a zombie:
- the counts included it;
- its timer stayed live, and later took a mail ordinal for a stale reply;
- on a key released rarely, entries piled up.

A caller that was already cancelled, or that had no waiter (a pre-cancelled control input), could register an entry that nothing would ever remove.

The same revision took an absolute deadline, so each caller computed `now + budget`. `TurnInstant.+` wraps, so a large budget came out as a past instant: #948 round 1's overflow, again.

## Root cause

The wait entry and the waiter it stood for had separate lifetimes, and only some of the paths that end a waiter (release, timeout, but not withdraw) removed the entry. The deadline arithmetic sat with every caller instead of in one place that saturates.

## Fix

The design's rules (revision 1):
- The core owns both tables, the waiters and the barrier entries. The step that ends a waiter removes its entry and cancels its timer, whichever ends it: release, timeout or withdraw. A reverse index `[InputID: key]` makes the withdraw's removal direct.
- A caller that can't wait (its cancellation flag is set, or it has no waiter) never registers.
- A wait takes a `Duration` budget. The core adds it with saturation, and `<= .zero` is expired: answered in the waiting step, with no zero timer.

## Prevention

- Any table that stands for waiting callers: list every path that ends a caller (answer, timeout, cancel, close, drain), and check that each removes the entry in the same step. Prior art: the kernel wait queue's `finish_wait`, where a waiter removes itself on wake-up or interrupt.
- Check "can't wait" before registering: an already-cancelled caller, or one with no continuation.
- An API that waits takes a budget, not an instant. The callee does the arithmetic once, saturating, with a stated boundary.
- Counts for tests are of events (a diagnostic, a stats counter), never a per-key total that only grows.
