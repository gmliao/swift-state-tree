---
title: "A range checked at open can't bound later arithmetic whose count comes from code"
module: SwiftStateTree (replay)
date: 2026-11-21
problem_type: bug_class
component: reevaluation-record-replay
symptoms:
  - "a replay traps with an arithmetic overflow although the record passed its range checks at open"
  - "a recorded sequence of Int64.max - 1 crashes the replay at `nextSequence += 1`"
  - "signal 4 (SIGILL) in a replay exit test after a range check was added"
root_cause: a_check_at_open_bounds_the_recorded_start_not_the_number_of_increments_land_code_makes
resolution_type: design_rule
severity: medium
tags:
  - replay
  - record
  - overflow
  - integer-range
  - decoding
  - crash
related:
  - "#729"
  - "#741"
  - "#640"
---

# A range checked at open can't bound later arithmetic whose count comes from code

## Problem

A replay took its recorded initialize `sequence` (or a sequence watermark) as the start of its counter and added 1 for every event the land emitted. A record with `Int64.max` trapped at `nextSequence += 1`. #741 refused out-of-range values when the record is opened, as tick IDs already were since #727. That closed `Int64.max`, but `Int64.max - 1` still trapped: the record was in range, and the land emitted two events.

## Root cause

A check at open bounds the value the record holds. It can't bound the arithmetic that follows when the number of steps comes from code instead of from the record. Here the number of `+= 1` calls is the number of events the land's handlers emit during the replay, which the record doesn't state and the checker can't know. Any open-time limit short of "leave room for every event the land could emit" either refuses valid records or leaves the edge reachable.

## Fix

Both checks, each for what it can bound (#741):
- At open: every recorded sequence is in `0 ..< Int64.max` and every `afterPass` is 0 or more, refused with a typed `ReevaluationRecordContentError`. These are the ranges a live keeper writes.
- At the increment: a `.reevaluation` keeper takes its sequences with `addingReportingOverflow`. On overflow it sets a set-once flag instead of trapping, and the runner reads the flag at its step boundaries (after initialize, after each tick step) and ends the run with `sequenceExhausted`. Live keepers keep the plain add, since their counter starts at 0.

## Prevention

- **Ask where the count comes from.** A range check on a recorded value protects arithmetic whose number of steps the record also fixes. When the number of steps comes from code (handlers, loops over land state, retries), check at the increment: a checked add whose overflow is a typed failure.
- **Report it like a failure found outside a turn.** The increment site can't throw out of the land's emit, so it notes the failure in a set-once flag that a step boundary reads, the same shape as the failure mailbox (`2026-11-21-a-gate-checked-per-send-site-leaks-at-the-next-site.md`).
- **Test the edge past the open check.** Besides the out-of-range values the open check refuses, test an accepted value at the edge with enough emits to pass the limit (`Int64.max - 1` and two emits), as an exit test that expects `.success`. Run its failing-first form on Linux (a trap raises the Mac's crash dialog).
- Extends [Wire-fed integer conversions must be exact and throwing](2026-11-09-wire-fed-integer-conversions-must-be-exact-and-throwing.md), whose "check the range when the record is opened, or use `addingReportingOverflow`" is an either-or only when the record fixes the count.
