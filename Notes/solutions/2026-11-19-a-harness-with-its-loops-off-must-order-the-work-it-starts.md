---
module: SwiftStateTreeNIOTests
date: 2026-11-19
problem_type: testing_practice
component: differential-harness
symptoms:
  - "a golden differs between processes: a client's first-sync sequence number is 4 in one run and 5 in another"
  - "a connection has 5 frames in one recording and 6 in the next"
  - "the record's syncOutputs list syncOnly and legacyCycle turns in a different order"
root_cause: work_started_by_the_runtime_outside_the_runners_steps
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - differential
  - determinism
  - golden
  - sync
  - hold-points
related:
  - "#555"
  - "#652"
---

# A harness with its loops off must order the work it starts

## Problem

The adapter differential harness (#555) turns the tick and sync loops off, and its runner drives every tick and sync itself, so each recording is the same in every process. Three rows still changed between processes, in a client's first-sync sequence number, its frame count and the record's turn order.

## Root cause

With the loops off, the runtime still starts work of its own, outside the runner's steps:
- A sync that finds a cycle in flight, or a writer backlog, is skipped, and the adapter schedules a retry in a background task (`deferSyncForOutboundBacklog`). After a busy skip it sleeps 1 ms, waits for the writer's drain, then syncs. Nothing the runner awaited covered it.
- `LandKeeper.endSync` starts the sync-only turn that a turn left to the legacy cycle in an unstructured `Task`. The adapter's own work after `endSync` returns runs at the same time, so the two record entries come in either order.
- A join that is only observed at a hold point, not held there, goes on as soon as the hold it waits behind is released, and races whatever runs next.

## Fix

- The runner's sync is `syncNow` followed by `TransportAdapter.waitForBackgroundSyncsForTesting()` (package). Under a held cycle the retry can't finish, so that step doesn't wait for it. The step after the release does.
- A keeper hold point, `syncOnlyAfterLegacyCycle`, at the start of that `Task`. The row holds it until the cycle's caller has returned.
- The joins in those rows are held, not observed, until the cycle and its retry are done. An in-turn row asks for no adapter `syncNow` under the hold: on an in-turn land a sync request is a turn.

## Prevention

- When a row records different bytes in two processes, compare the record's `syncOutputs` (`turnKind`, `sequence`) between the two runs first. The step where they diverge names the work no step awaited.
- For every task the runtime starts by itself (a retry, a follow-up, a `Task` in a callback), the harness either awaits it with a package wait, or holds it at a hold point. It never sleeps.
- Rows record through `scripts/record-differential-goldens.sh`, whose five processes must agree byte for byte. One process can't show this class.
