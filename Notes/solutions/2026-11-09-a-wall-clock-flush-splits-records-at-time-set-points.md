---
module: SwiftStateTree
date: 2026-11-09
problem_type: bug_class
component: reevaluation-recorder
symptoms:
  - "Two recordings of the same input give different .sstr bytes, but the same decoded content"
  - "Long recordings differ and short ones (under the flush delay) match"
  - "File sizes differ by one record's framing, and the first differing offset moves between runs"
root_cause: wall_clock_timer_closes_a_record_still_being_merged
resolution_type: design_rule
severity: medium
tags:
  - recording
  - record-format
  - determinism
  - timers
  - tickless
related:
  - "#327"
  - "Notes/plans/2026-11-09-recorder-turn-boundary-flush.md"
  - "2026-11-07-a-frame-cannot-close-while-late-entries-arrive.md"
---

# A wall-clock flush that closes a record still being merged splits it at points set by time

## Problem

The 3.0 recorder merged a tick's calls into one pending record. A 1 s timer handed the write buffer to the writer, and before that it appended the pending record. The keeper makes several recorder calls per tick: inputs, state hash, server events, the watermark frame. When the timer fired between two of them, it wrote the tick's first part as a `turn` record. The rest became a second record for the same tick. The reader merges turns of one tick, so content, replay and `--verify` were unaffected. The bytes and the footer's `turnCount` were not, so records couldn't be listed by sha256.

## Root cause

The timer did two jobs:
- a durability flush: getting closed bytes to disk;
- a framing decision: closing the open record.

The second job made the framing depend on wall time. Taking it away naively fails too. A tickless land records every turn under tick 0, so "close only when a newer tick arrives" would keep the whole recording in memory.

## Fix

- The timer only hands off records that are already closed. A record closes on a signal from the recording, never from time:
  - a newer tick (tick lands);
  - the keeper's end of turn (tickless lands, `recordTick(_:endsTurn:)` / `endTurn()`);
  - `save`;
  - a deterministic backstop on the number of merged calls.
- On the in-turn path the end-of-turn signal is the turn's last enqueue, in its synchronous segment.
- Tests force the timer body after every recorder call and compare bytes with an unforced run, for tick and tickless lands with in-turn sync on and off.

## Prevention

- A timer may move bytes that are already decided. It must not decide them: no split, merge, sequence number or count that a timer can change.
- When a stream of records must be byte-reproducible, name the event that closes each record. It has to be something the input determines: a tick, a turn end, a count. Test it by firing the timer at every possible point, not by waiting for it.
- For a land without ticks, check that a "per tick" rule still bounds memory: tick 0 never closes.
