---
module: SwiftStateTreeTransport
date: 2026-11-09
problem_type: bug_class
component: sync-stream-recording
symptoms:
  - "sync output mismatch at the resync tick, check: hash, scope: per-player (combined)"
  - "seed compared 2 of 3: a resync's seed isn't compared"
  - "replay verification fails only on the tick a view restarts on a live connection"
root_cause: view_restart_recorded_without_clear
resolution_type: design_rule
severity: medium
tags:
  - recording
  - replay
  - sync-stream
  - resync
  - verifier
related:
  - "#332"
---

# A view restart on a live connection, recorded without a clear

## Problem

An in-place resync (#332) sends a player its whole view on the live connection, with no leave and no join. The recording had a seed marked as a rejoin, but no clear before it. In the json and opcodeJsonArray encodings, replay verification failed at the resync's tick: the per-player hash didn't match, and the resync's seed was never compared.

## Root cause

The verifier's shadow keeps a cached view for each player. It drops that view only on a clear marker, which a disconnect or reconnect records. Without the clear, the shadow still held the player's old view. So it diffed the resync plan's output against the old view, while the server had treated the player as unsynced, and hashed a different patch list. The seed that followed came too late to change that output's comparison.

The adapter test passed: it checked that a seed marked as a rejoin was recorded, which was true. Only a replay through `ReevaluationEngine.run` exercised the shadow.

## Fix

In the plan that resyncs a player, the adapter records a clear before the plan's output, using the existing `.clear` kind. It does this only for players whose snapshot committed, since a seed follows only for those. The stream then reads like a reconnect: clear, output, seed (rejoin). The record format is unchanged. A deterministic replay test (`SyncOutputVerifierTests`, "An in-place resync replays") runs a resync through `ReevaluationEngine.run` in every encoding. It expects the sync outputs passed, every seed compared, and no server event mismatch.

## Prevention

- Anything that makes the server forget what a client has, on a live connection or a new one, records a clear before the output that depends on it. The rule covers resyncs and any future "restart the view" path.
- Test a new recorded path by replaying it through the verifier, not only by checking which markers it records. A marker test pins the producer; only a replay pins that the consumer reads the stream as the producer meant.
