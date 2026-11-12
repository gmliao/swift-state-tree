---
module: Examples/GameDemo EncodingBenchmark
date: 2026-11-12
problem_type: measurement_pitfall
component: capture-views
symptoms:
  - "Two capture passes of the same binary give different hashes of room-0.ndjson"
  - "A base-vs-head frame digest differs although every frame's bytes are the same"
root_cause: frames_to_different_sessions_are_listed_in_send_order
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - measurement
  - capture
  - digest
  - determinism
  - send-order
  - ab-test
related:
  - "#515"
  - "Notes/plans/2026-11-12-atomic-node-once-per-pattern.md"
  - "Notes/solutions/2026-11-04-same-session-frames-overtake-each-other.md"
---

# A hash of a whole capture depends on the send order across sessions

## Problem

A frame-identity check for an A/B (#515) was planned as a hash of a capture file, `--capture-views <dir>`, with the header line (it records the commit) skipped. The check must give the same hash for two runs of the same binary before it can compare base and head. It didn't: on the Mac, two runs of the same binary differed in all six cells (messagepack and opcode JSON, router off, router on, row addressing on).

## Root cause

A capture line lists one sync's frames in the order the room's transport was handed them. Within one sync, the frames to different sessions are sent concurrently, and the order between sessions changes from run to run. In the default messagepack cell, every one of 301 syncs listed the sessions in a different order in the two runs, e.g. sessions 2, 4, 1, 3, 0 in one and 3, 2, 1, 4, 0 in the other. Every frame's bytes were equal, and so was each session's own order. Only the interleaving across sessions moved, and a hash over the file sees it.

## Fix

Digest what each session receives instead of the file as written:

- per session (sorted), per sync, the frames that reach it, in capture order;
- a broadcast (`*`), a broadcast-except (`!<session>`) and a player target (`p:<player>`) count for every session they reach;
- plus each sync's projections.

`Examples/GameDemo/scripts/capture-digest.py` (#515) computes it.

A first version grouped frames by target string. That is also deterministic, but it would hide a change in the order in which one session sees a broadcast and its own frames, since the two groups never mix.

With the per-session digest, base = base again = head in all six cells.

## Prevention

- A frame-identity check runs base against base first. A check that differs there measures the run's scheduling, not the change.
- Only order that a receiver can observe goes into the digest: each session's own stream. The interleaving across sessions isn't part of what a client sees. Per-session order is guaranteed by the outbound writer (see the 2026-11-04 entry).
- Bytes per sync don't replace the digest: they are averages, so equal counts don't mean equal frames.
