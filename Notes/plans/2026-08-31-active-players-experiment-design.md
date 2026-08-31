# Experiment design: active-player workload for single-room entity scaling

Design run under `sst-experiment` (step 2b). Extends `deep-research/single-room-entity-scaling/`
with an active-player axis. Reviewed and approved by the maintainer in chat on 2026-08-31.

## Question

In one hero-defense room, when every player is *active* (produces a position change every
tick), does `bytesPerSync` grow with |changed nodes|, and does derived wire traffic
(`bytes_per_sync x players`) grow ~n^2?

## Design decisions

### D1: How players become active — inject actions via the official path

**Chosen:** the benchmark injects a deterministic `MoveAction` (movement target) per player
through `TransportAdapter.handleActionEnvelope` / the land's `HandleAction` rules, on a fixed
cadence, before ticking. Targets are derived from the player index and iteration counter
(deterministic, no RNG from outside the land).

**Rejected:** benchmark mutating `state.players[*].position` directly. That would bypass
action decoding, dirty tracking, and the land's own movement system — the measured bytes
would no longer correspond to any real client workload.

**Why this answers the Question:** with every player holding a moving target,
`MovementSystem.updatePlayerMovement` changes each player's position every tick, so
|changed nodes| genuinely scales with player count instead of staying monster-bound.

### D2: Metric semantics (mandatory line)

- `bytes_per_sync`: total bytes handed to `CountingTransport.send(_:to:)` per sync,
  averaged over iterations. A broadcast update counts **once**, regardless of player count
  (encode-once semantics). Identical to the existing single-room-entity-scaling runs.
- `wire_bytes_per_sync` (derived in regenerate.py, not measured): `bytes_per_sync x players`,
  an upper-bound estimate of downstream traffic assuming the whole payload is broadcast-scoped.
  Stated as derived in the README; per-player private diffs make the true value slightly lower.

### D3: Matrix

| axis | values | fixed |
|---|---|---|
| players (active) | 5, 10, 20, 50 | monster cap = 4 |
| joint cell | players 20 x cap 20 | both axes raised together |
| encoding | json-object, messagepack-pathhash | — |

Fixed: rooms=1, ticksPerSync=2, iterations=200, release build, `USE_SNAPSHOT_FOR_SYNC=false`.

### D4: Knob shape

`EncodingBenchmark --active-players` (bool flag, default off, hero-defense only).
Lives entirely under `Examples/GameDemo` → `sst-direct-change`, no core PR.

## Risks

- Action injection cost appears in timing metrics; only byte metrics will be cited.
- If auto-shoot kills monsters faster with more active players near them, the cap refill
  keeps the monster count stable (verified via `finalMonsterCount`).
