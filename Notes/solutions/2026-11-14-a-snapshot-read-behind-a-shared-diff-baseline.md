---
module: SwiftStateTreeTransport
date: 2026-11-14
problem_type: bug_class
component: initial-sync
symptoms:
  - "a convergence check after a join or reconnect finds a broadcast field one change behind on that client only (e.g. `client=-144118 server=-144120`)"
  - "only with in-turn sync off; a rerun passes"
root_cause: firstsync_built_from_a_state_read_that_a_shared_broadcast_commit_passed
resolution_type: code_fix
severity: high
tags:
  - reentrancy
  - initial-sync
  - broadcast-cache
  - legacy-sync
related:
  - "#564"
  - "#98"
  - "#474"
---

# A snapshot read behind a shared diff baseline

## Problem

A standalone firstSync (a join not completed in a turn, which is every join with in-turn sync off) reads the land's state, awaits, and then sends the joiner its view of that read. During the await, a sync cycle that skips the joiner can commit and move the shared broadcast cache past the read. The next diff starts from the cache, so every broadcast field that changed in between stays stale on the joiner until it changes again. A field that changes only once stays wrong for good (#564).

## Symptoms

- E2E convergence after a reconnect is off by one change on one client, on the legacy leg only, and a rerun passes.
- Other clients and the server agree. Per-player fields are right, because their cache is staged from the same read as the firstSync.

## Root cause

The read was checked after the await for the session (ticket, membership, #98), but not for the other input its result depends on: the shared broadcast cache, which the next diff uses as the joiner's baseline. A snapshot and a diff baseline that live in different places must be read at the same point, or the gap between them must be detected.

## Fix

- The firstSync captures a count of sync-phase commits before its read, and commits only if the count is unchanged after it.
- Otherwise the firstSync is dropped and counted (`initialSyncsDroppedBehindCommit`). The player stays unmarked, so the next cycle sends its whole view from that cycle's own state.
- A land without periodic sync starts the failed-plan follow-up for that cycle, without counting a failed plan, since nothing failed.
- Pinned by `InitialSyncBehindCommitTests`, which holds the firstSync at `initialSyncAfterRead` while a cycle commits, with periodic sync and without.

## Prevention

- When code after an `await` sends a value computed from a read, list everything the receiver will combine it with later (a diff baseline, a cache, a sequence). Each is state read before the `await`, even if this code never touches it.
- A full loop of the E2E scenario didn't reproduce this locally (30 of 30 passed); a hold at the `await` did on the first run. Force the interleaving before looping.
