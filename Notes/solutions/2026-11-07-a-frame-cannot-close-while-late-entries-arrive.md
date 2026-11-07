---
module: re-evaluation recorder, record format
date: 2026-11-07
problem_type: design_flaw
component: ReevaluationRecorder
symptoms:
  - "A late sync entry (a late seed) filed under an older tick is missing from a streamed record, or forces the whole record to stay in memory"
  - "A record cut mid-run reads as complete, or its sync stream has a gap the verifier rejects"
root_cause: per_tick_frames_closed_before_their_late_entries
resolution_type: format_change
severity: high
tags:
  - recording
  - record-format
  - streaming
  - truncation
  - late-entries
related:
  - "Sources/SwiftStateTree/Runtime/ReevaluationRecorder.swift"
  - "Sources/SwiftStateTree/Runtime/ReevaluationRecordLog.swift"
  - "Tests/SwiftStateTreeTests/ReevaluationRecordLogTests.swift"
  - "Notes/plans/2026-11-07-streaming-record-format.md"
  - "https://github.com/gmliao/swift-state-tree/pull/266"
---

# A per-tick frame can't be closed while late entries for its tick still arrive

## Problem

The 2.6 recorder kept one frame per tick and wrote the whole record at `save`. Streaming it means writing a frame once it is done. But a tick is never done for certain: a late sync entry (a seed for a player whose join completed after the tick ran) is filed under the tick it observed, possibly several ticks back. Closing a frame when the next tick starts loses that entry, and holding every frame open until the end is the 2.6 memory problem again.

## Root cause

The frame is the unit the reader wants, not the unit the writer has. The writer has turns: what one keeper turn produced, for one tick, which may be an old one.

## Fix

- Write turns, not frames: an append-only log of length-prefixed `turn` records, each for one tick. The reader merges a tick's turns with the same rules the in-memory frame used (`recordTick`), so a late entry is just a later `turn` record for an older tick.
- Close with a `footer` that says whether the record is complete. A record is complete only when every turn reached the file: a turn that fails to encode, a write that fails (also on the final buffer or the footer itself) or submissions still pending at shutdown give an incomplete footer or none, and `save` throws.
- A record is saved only once it is at its destination. A failed move leaves the closed log at its spool path, and the next `save` retries the move; it never reports success without a file.
- On reading an incomplete record, leave out its newest tick (more turns for it may be past the cut), and cut the sync stream with it: drop every entry from the smallest stream index of that tick on, since a late entry filed under an older tick can come later in stream order. The stream stays gapless.

## Prevention

- When a stream is written while it is still being produced, ask which unit can arrive late, and make that unit the record. Merge on read.
- Every "closed" or "complete" marker is written only after checking that nothing before it was lost, including errors reported asynchronously by the writer. Test each loss (encode failure, write failure on the last buffer, failed move) and assert the marker.
- A cut file is read as a prefix of every stream it holds, not only of its ticks: test truncation with a late entry after the newest tick's own.
