---
title: "A waiter table's entry leaves in the step its waiter leaves, every leftover (flag, payload, timer) has an owner on every exit, and a wait takes a budget"
module: SwiftStateTurns
date: 2026-11-27
problem_type: design_pattern
component: turn-core-barrier
symptoms:
  - "a waiter count includes a caller that has already thrown CancellationError"
  - "a timeout fires long after its caller left, and takes a mail ordinal for a reply nobody waits for"
  - "a large wait budget is answered as expired at once"
  - "a cancellation flag outlives its call when the cancel lands after the reply"
  - "a held reservation is never undone because the wait ended by a timeout, a withdraw or the core's end"
  - "a caller wakes before the cleanup hook's outputs are flushed, or before its hook has run at all"
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

Revision 1 still lost leftovers on the paths other than a release: the flag set had no owner once the reply was out, a payload was dropped on the withdraw, the timeout and `close`, and a timer was only a side map that the heap's liveness check couldn't see. Revision 2 (code-first):
- **The flag:** the cancellation's hop removes it on every exit, the stale ones included. Replies never touch the set.
- **The payload:** it comes back through `WaitOutcome` when the wait doesn't register, through `release(where:)`, or through `handleWaitEnded` when a registered wait ends any other way. That includes a published reply, the hook stepping before the caller's answer leaves.
- **The timer:** it has a kind on its heap entry, with a fresh generation per registration.

Revision 2 still let the answer overtake the cleanup:
- **The withdraw and a claiming reply** resumed their caller right after the hook's step, before the drain flushed the hook's outputs.
- **After `endAll`,** a reply from an abandonment or from an earlier hook reached a caller whose own hook was still queued.

Revision 3 makes such a caller *settling* from the end of its wait until its hook has stepped:
- the first reply for it is held as its answer;
- the answer is published in the drain's replies phase, after the hook's outputs;
- the hook's own reply is dropped when an answer was already fixed.

## Prevention

- Any table that stands for waiting callers: list every path that ends a caller (answer, timeout, cancel, close, drain), and check that each removes the entry in the same step. Prior art: the kernel wait queue's `finish_wait`, where a waiter removes itself on wake-up or interrupt.
- Check "can't wait" before registering: an already-cancelled caller, or one with no continuation.
- An API that waits takes a budget, not an instant. The callee does the arithmetic once, saturating, with a stated boundary.
- Counts for tests are of events (a diagnostic, a stats counter), never a per-key total that only grows.
- For every leftover a waiter carries (a cancellation flag, a payload that holds a reservation, a timer), name the owner that removes it on each exit, the stale exits included: release, withdraw, timeout, an answer by another path, teardown. A table of exits by leftover is the review aid. Prior art: Erlang's `gen_server` deferred `reply/2` with monitors, which tells the server when a waiting caller dies so it can clean up.
- When the design's edge cases keep moving in review, write the code and the tests for every exit first. A second semantics NOT GO on a plan means code-first.
- A cleanup hook's contract, "before the caller's answer leaves", has two halves:
  - **the hook has stepped:** a caller counts as claimed from the moment its end is decided until its hook runs, whoever replies in between;
  - **its outputs are flushed:** the answer goes through the same publication phase as every reply, never a direct resume next to the hook's step.

  Pin both halves from inside the segment, never from the resumed caller. An ordering inside one actor segment can only be observed from inside that segment: a resumed task runs after the actor's job ends, by which time the segment has flushed either way. So rev 3's first ordering tests passed with the bug restored. Record the order on the driver: a test hook at each resume site, and the fixture's `flush`, both writing one trace. Assert the exact answers too. Prior art: Erlang's `gen_server` with monitors, where the server's cleanup runs before anything else observes the caller's end.
