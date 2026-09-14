# Same-testbed full-snapshot baseline: design

Date: 2026-09-15
Status: approved in discussion, pending spec review

## 1. Goal

Provide a controlled baseline for the delta synchronization strategy: the same
hero-defense Land, the same workload, the same encoder, on the same machine, with
the only variable being *what* is sent per sync — the full visible view of each
recipient (snapshot) versus only the changed fields (delta). The result is one
extra column in the RQ1 payload table and two extra rows of the single-room
entity-scaling sweeps, plus a proof that both strategies produce identical
client-side views.

This is deliberately **not** a cross-framework comparison. See
`deep-research/related-systems-matrix.md` for the capability-based comparison the
paper uses for other systems.

## 2. Scope

In scope:

1. Core: a `SyncStrategy` setting on `TransportAdapter` (`delta` | `fullSnapshot`),
   configurable by init parameter and `SYNC_STRATEGY` env var.
2. Core: `SyncEngine` diff entry points accept a baseline choice — the cached
   previous snapshot (delta) or an empty snapshot (full).
3. Core: an equivalence test proving both strategies reconstruct the same client
   views sync by sync.
4. Examples: `EncodingBenchmark --sync-strategy delta|full-snapshot`, run-id
   suffix, and the strategy recorded in result JSON.
5. Experiment topic `deep-research/snapshot-baseline/` with the matrix in §6.

Out of scope (explicitly rejected):

- JSON × full-snapshot cells (a worst-case × worst-case cell adds no evidence).
- `DiffBenchmarkRunner` CPU numbers (synthetic `BenchmarkState`, different
  scenario — would invite "why compare across scenarios").
- Any change to the late-join / `firstSync` path.
- Any change to the default behaviour: with the env var unset and the init
  parameter defaulted, every byte sent is identical to today.

## 3. Semantics of `fullSnapshot`

For every `syncNow()`:

- Each joined recipient (excluding players still in initial sync) receives its
  complete visible view: all broadcast fields plus that player's per-player
  fields, every field as a `.set` patch.
- The update is sent **even when nothing changed** — this is what a naive
  snapshot protocol does and is the point of the baseline.
- Pending events are attached exactly as in delta mode.
- The `SyncEngine` caches are neither read nor written; dirty flags are still
  cleared via `keeper.endSync` so switching strategies at runtime cannot leave
  stale flags (runtime switching is not a supported feature, only a non-goal
  that must not corrupt state).
- Encoding is unchanged: the same `StateUpdateEncoder` (opcode + MessagePack +
  PathHash + slot compression in the benchmark) encodes the `.set` patches.

`bytesPerSync` keeps the room-level aggregate convention (sum over recipients of
the per-recipient merged update), so the two strategies are directly comparable
cell by cell.

## 4. Core design

### 4.1 `SyncStrategy`

```swift
public enum SyncStrategy: String, Sendable {
    case delta
    case fullSnapshot = "full-snapshot"
}
```

Lives in `SwiftStateTreeTransport` next to `TransportEnvConfig`.

### 4.2 Configuration

- `TransportEnvKeys.syncStrategy = "SYNC_STRATEGY"`.
- `TransportEnvConfig` gains `syncStrategy: SyncStrategy`, parsed with the same
  init-default / env-override pattern as `enableDirtyTracking`
  (`fromEnvironment(enableDirtyTrackingDefault:syncStrategyDefault:)`).
  Unrecognised values fall back to the init default and log a warning.
- `TransportAdapter.init` gains `syncStrategy: SyncStrategy = .delta`.
- The adapter's startup log line that already prints `dirtyTracking` /
  `snapshotForSync` also prints `syncStrategy`.

### 4.3 `SyncEngine` baseline parameter

Add to `SyncEngine`:

```swift
public enum DiffBaseline: Sendable {
    case cached   // compare with the last snapshot, update the cache (today)
    case empty    // compare with an empty snapshot, leave the cache untouched
}
```

`computeBroadcastDiffFromSnapshot`, `computePerPlayerDiffFromSnapshot` and
`generatePerPlayerUpdateFromSnapshot` gain `baseline: DiffBaseline = .cached`.
With `.empty` they call the existing `compareSnapshots(from: StateSnapshot(values: [:]), to: current, onlyPaths: nil, dirtyFields: nil)`
and return; no cache read, no cache write, no first-call "seed and return []".

`.cached` is byte-for-byte the existing code path.

### 4.4 `TransportAdapter` sync path

In the regular sync path (`computeSyncModes` → `extractSyncSnapshots` → diff →
send):

- `computeSyncModes` returns `(.all, .all)` when `syncStrategy == .fullSnapshot`
  (dirty tracking cannot narrow a full view).
- Both diff call sites pass `baseline: syncStrategy == .fullSnapshot ? .empty : .cached`.
- The existing "skip when diff is empty and no events" guard stays: with
  `.empty` the diff is never empty for a non-empty view, so a full update goes
  out every sync, which is the intended semantics.
- The `useSnapshotForSync` legacy extraction path gets the same treatment (mode
  forced to `.all`, baseline forwarded). It is exercised by the benchmark's
  default configuration, so it cannot be skipped.

Late-join (`_syncStateForNewPlayer`) is untouched: it already sends a full
snapshot and `markFirstSyncReceived` semantics stay as they are.

### 4.5 Equivalence test (`Tests/SwiftStateTreeTransportTests`)

`SyncStrategyEquivalenceTests`:

1. Build two `TransportAdapter<HeroDefenseState>`-equivalent fixtures — the
   transport test target cannot depend on `Examples/`, so use the existing
   transport test Land with broadcast + per-player + server-only fields and
   dictionary-keyed collections (extend it if it lacks a keyed collection).
   Both adapters wrap `CountingTransport`-style capture transports that record
   every `StateUpdate` per session.
2. Drive both with the identical script: join 3 players, N syncs with
   mutations touching broadcast, per-player and keyed-collection fields, one
   leave, one late join, more syncs.
3. Maintain one *client model* per (adapter, session): a `StateSnapshot`
   updated by applying every received patch list in order (`.set` / `.remove`
   as the existing patch semantics define).
4. After every sync, assert for every session that the delta client model
   equals the full-snapshot client model, and that both equal the
   authoritative view obtained via `syncEngine.snapshot(for:from:)` on the
   current state.
5. Assert the delta transport's total bytes ≤ the full-snapshot transport's
   total bytes (sanity, not a performance claim).

A second small test checks `SYNC_STRATEGY` parsing: unset → init default,
`full-snapshot` → `.fullSnapshot`, garbage → init default.

## 5. Benchmark changes (`Examples/GameDemo/Sources/EncodingBenchmark`)

- `BenchmarkConfig.syncStrategy: SyncStrategy = .delta`; `--sync-strategy
  delta|full-snapshot`; `--help` line.
- Both the `BenchmarkRunner` method and its duplicated free function in
  `EncodingBenchmarkMain` construct `TransportAdapter` with `syncStrategy:` —
  both call sites must be patched (known duplication, see
  `Notes/plans/2026-08-31-active-players-experiment-design.md`).
- Result JSON gains `"syncStrategy"`; table output gains a column.
- Run-id convention for the topic: `<cell>-<strategy>.json`, e.g.
  `p5-r10-msgpack-delta.json`, `p5-r10-msgpack-full.json`.

## 6. Experiment (`deep-research/snapshot-baseline/`)

Design run under `sst-experiment` (new metric semantics for the `full` cells).

Question: at equal encoding, how much does delta synchronization save over a
per-sync full snapshot, and does the saving track |ΔSt| / |S| as Eq. (6)
predicts?

Fixed: `messagepack-pathhash`, `ticksPerSync = 2`, `iterations = 200`, release
build, single machine (Apple M2 / macOS, same as the entity-scaling topic).

| Axis | Cells | Strategy |
|---|---|---|
| RQ1 rooms | players 5 × rooms 10, 30, 50 | delta, full |
| Monster axis | rooms 1, players 5, `--monster-cap` 4, 10, 50, 100 | delta, full |
| Active-player axis | rooms 1, `--monster-cap 4`, `--active-players` = players = 5, 10, 20, 50 | delta, full |

22 result files. Delta cells are re-run (not copied) so both strategies share
the same git SHA and toolchain; the README cross-checks the re-run delta cells
against the archived entity-scaling numbers and reports any drift.

Metrics: `bytesPerSync` (primary), `avgCostPerSyncMs` (secondary, same runs,
reported as one column, no strong claim), derived `savingRatio = 1 −
delta/full`.

`regenerate.py --check` additionally asserts `full ≥ delta` for every cell
pair.

Expected shape (to be confirmed by data, not asserted in advance): the monster
axis saving ratio stays high and roughly flat (most of the tree is unchanged
each tick); the active-player axis saving ratio shrinks toward the cost of the
unchanged fields only, since |ΔSt| → |S|.

## 7. Delivery

1. Core PR via `sst-core-change` (`Sources/`, `Tests/`): §4. Verification:
   `swift test`, `./Tools/CLI/test-e2e-game.sh`, and one manual
   `SYNC_STRATEGY=full-snapshot` GameServer smoke run confirming clients still
   render. Reviewed with `sst-pr-review`, merged by the user.
2. Benchmark flag via `sst-direct-change` on `main` after (1) merges: §5.
   Verification: `./Tools/CLI/test-e2e-game.sh`.
3. Experiment PR via `sst-experiment` step 7: §6 plus this spec's companion
   design note under `Notes/plans/` (the step-2b artefact).
4. Paper: RQ1 Table VI gains a `full snapshot` column; §IV-B2 gains one
   sentence tying the saving ratio to Eq. (6); the conclusion's
   `ENABLE_DIRTY_TRACKING` sentence is replaced by the measured result.

## 8. Risks

- The `useSnapshotForSync` legacy path and the non-legacy path must both honour
  the strategy; the benchmark uses the legacy path. The equivalence test runs
  both paths (parametrised) to catch a one-sided implementation.
- Full-snapshot mode multiplies encoder work; at 50 rooms × 5 players the
  benchmark still finishes in seconds, no timeout concern.
- Re-run delta cells may drift from the archived entity-scaling numbers if
  `main` moved (e.g. the sorted-iteration determinism fix). Drift is reported,
  not hidden; the comparison that matters is within-topic.
