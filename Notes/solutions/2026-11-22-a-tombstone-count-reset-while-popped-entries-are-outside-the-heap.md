---
module: SwiftStateTurns
date: 2026-11-22
problem_type: logic_error
component: deadline-heap
symptoms:
  - "closed entries stay in a lazily deleted heap past its documented bound"
  - "a stale-entry count falls below the number of stale entries left in the heap"
root_cause: tombstone_count_reset_while_counted_entries_are_outside_the_heap
resolution_type: code_fix
severity: medium
tags:
  - heap
  - lazy-deletion
  - tombstones
  - compaction
  - timers
  - turns
related:
  - "#621"
  - "#753"
---

# A tombstone count reset while popped entries are outside the heap

## Problem

The turn core's deadline heap uses lazy deletion: closing a request only counts its entry stale (`rt.staleDeadlines`), and a compaction rebuilds the heap once the stale entries are at least 64 and half of it, then sets the count to 0. A wake pops its due entries into a local list before stepping them. A step in that wake that armed a new entry ran a compaction. Entries already in the due list, closed or still to be closed, were counted but not in the heap, so the rebuild couldn't drop them, yet the reset forgot them. Their later decrements then took the count below the real number of stale entries in the heap, and closed entries with long deadlines stayed past the bound (#753 review).

## Root cause

A tombstone count is only exact while every counted entry is in the structure it counts. Popping entries into a work list moves them out without moving their counts, and a reset in between loses the difference.

## Fix

- No compaction while a wake services its due list (`sleeperAwake`); a compaction check runs at the start of each wake and right after its due list.
- A due entry already stale when the wake takes it is popped and uncounted there, so the due list only holds entries that were live.
- The stale pops of one wake are bounded (256) apart from its live fires (64), including the silent drop of stale heads after the wake.
- The bound is documented as holding after a compaction check, not at every instant.

## Prevention

- Keep a tombstone count tied to entries inside the structure. Anything popped for later processing either leaves the count when it leaves the structure, or blocks resets until it is processed.
- Budget live work and stale cleanup separately: a cap that counts stale pops can starve live entries, and an unbounded cleanup loop can stall the actor.
- Prior art: Go's runtime timers keep a zombie count for entries in the heap and clean up when it passes a fraction of the heap (`runtime/time.go`).
