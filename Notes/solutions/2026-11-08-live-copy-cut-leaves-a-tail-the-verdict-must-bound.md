---
module: SwiftStateTree
date: 2026-11-08
problem_type: bug_class
component: sync-output-verifier
symptoms:
  - "sync output not verified: partial [...]; N events after the last output"
  - "supersede re-evaluation record+verify fails intermittently in game E2E"
  - "Record: 3.0, incomplete (closed before the end of the run (copy of a live record))"
root_cause: verdict_rule_for_complete_records_applied_to_a_live_copy_cut_between_an_event_and_its_output
resolution_type: code_fix
severity: medium
tags:
  - reevaluation
  - verification
  - live-record
  - flaky
  - e2e
related:
  - "#306"
  - "#307"
---

# A live copy can end between an event and its output: bound the tail by the read sequence, not the tick

## Problem

The game E2E's supersede re-evaluation step downloads the record while the land still runs: a
copy of the live recorder, with an incomplete footer, whose newest tick the reader leaves out.
Every scope compared, but the verdict was `partial` with "1 events after the last output", and
the step failed intermittently.

## Root cause

`SyncOutputReplayDriver.finish()` passed only when no replayed server event was left unconsumed.
That holds for a complete record. A copy cut between a tick that emitted an event and the next
output (which the copy leaves out with the newest tick) always leaves those events unconsumed.
Whether it does depends on where the copy is cut, so the step flaked.

## Fix

#307 (merge ff912253). The driver takes the record's completeness. In an incomplete record only, the unconsumed events
emitted after the newest recorded output read state are a tail: keeper sequence at or above that
output's `sequence` (the keeper's next sequence at the read, from the same counter as event
sequences). They are reported as "N tail events not yet synced (incomplete record)"
(`tailEventsNotSynced`, also parsed by the CLI's `parseSyncOutput`) without making the verdict
`partial`. An unconsumed event below it, or any in a complete record, still makes it `partial`.

A first version bounded the tail by tick (events at or after the last output's tick). That also
excused an event emitted in that same tick before the output read state, which the output should
have carried: a real loss would pass. The tick is too coarse for a boundary that falls inside a
tick.

## Prevention

- When a check runs on a copy of live state, list what the cut alone can explain and allow only
  that, bounded by the exact position the copy records (here the last output's read sequence).
  A coarser position (the tick) also covers work done before the boundary in the same unit. Don't relax the
  rule for the whole incomplete record: an event lost before the last output must still fail.
- Report the excused count on its own line, so a reader sees it rather than a clean pass.
- Test the boundary both ways: a tail in a live copy passes, the same events in a complete record
  stay partial, and an unmatched event before the last output stays partial even in a live copy
  (`SyncOutputVerifierTests`, the #306 tests, including a live copy whose last kept output
  lost its same-tick events unlisted; a mutant that excuses every unconsumed event fails them).
