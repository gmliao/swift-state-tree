# Full-state replay hash (#180)

The per-tick `stateHash` (and the initialize hash) is FNV-1a64 over the JSON of
`SyncEngine.snapshot(from:mode: .all)`, which is `state.snapshot(for: nil)`: the broadcast view.
Replay therefore never verifies server-only state (Hero Defense `players.*.lastFireTick`,
monster `pathProgress`/`reward`/`spawnPosition`, turret `lastFireTick`, root `nextMonsterID`) or
per-player and masked values. #180 makes the hash cover the full server state, for live
recording and replay alike, without touching any client path. It follows #178 (#175), which is
in the same code.

## 1. Where the full-state snapshot is built

A separate conversion that ignores every `@Sync` policy. It never goes through
`snapshot(for:)`, `broadcastSnapshot`, `snapshotForSync` or `SnapshotValue.make(from:for:)`, so
no policy, filter or mask can reach it, and no change to it can reach a client.

- **Per node:** `@StateNodeBuilder` generates `fullStateSnapshot() throws -> StateSnapshot`,
  with every `@Sync` field by name and its value converted by the full conversion below. The
  policy is not read. A default in a protocol extension is not provided, so a hand-written
  `StateNodeProtocol` conformance has to implement it (compile error, not a silent gap).
- **Per value:** `SnapshotValue.makeFull(from:)`, a sibling of `make(from:for:)` with one
  difference: a `StateNodeProtocol` value converts through its `fullStateSnapshot()`, at any
  depth (maps, arrays, optionals, nested nodes, `@SnapshotConvertible` nodes). Everything else
  (leaves, `SnapshotValueConvertible` value types, DeterministicMath types) converts as today,
  so leaf encodings match the client encoding.
- **One entry point:** `ReevaluationEngine.calculateStateHash` and
  `calculateStateHashAndSnapshot` hash `fullStateSnapshot()`. The keeper's live recording
  (`LandKeeper`, 3 call sites), the engine's replay and initialize check already call these.
  The monitor runner (`ReevaluationRunnerImpl`) builds its own hash from
  `syncEngine.snapshot(from:mode:)`; it moves to the same entry point, so there is exactly one
  definition. The recorded debug `fullSnapshot` and `--diff-with` use the same snapshot, so a
  field-level diff points at the field the hash saw.
- **`@Internal` properties (decision for Review):** they are server state too, not in any
  snapshot today. Proposal: include them when their type converts (`makeFull` succeeds), under
  the key `"@internal.<name>"`, so a nondeterministic internal (a `Date`, a cache keyed by an
  object identity) shows up as a replay mismatch instead of being silently skipped. Alternative:
  `@Sync` fields only, and say so in the docs. Hero Defense and visibility-test have no
  `@Internal` fields, so either choice gives the same pinned hashes for them.

## 2. Deterministic ordering

- Object keys: the snapshot is encoded with `JSONEncoder` `.sortedKeys`, as today, so field
  order and dictionary iteration order never reach the bytes. Dictionary keys are converted to
  strings the same way as for clients (`makeKeyString`), and two keys that collide as strings
  throw (they would hash ambiguously).
- Arrays keep their order (it is state).
- `Set` (and any other unordered collection found through `Mirror` `.set`): elements are
  sorted by their canonical encoding (sorted-keys JSON bytes) before hashing. Today's `make`
  path takes Mirror's order for sets; the full conversion does not.
- Floating point: values are encoded as today (`Double` via `JSONEncoder`); game state uses
  DeterministicMath, so no new float paths appear.
- A test hashes the same state built in different insertion orders (maps, sets) and gets one
  hash.

## 3. Record format 2.4 and the not-comparable rule

- `ReevaluationRecordVersion.current` becomes `"2.4"`.
- The hash definition changes for every land, so every record older than 2.4 is not
  comparable: a state or initialize hash mismatch is reported as
  "recorded before #180 (full-state hash), hash not comparable", and `ReevaluationRunner
  --verify` exits 10. This replaces #178's per-land rule for state and initialize hashes
  (`hashChangedByNestedNodePolicies` is removed with it: a 2.3 record has the broadcast-view
  hash too). A matching older record still verifies (a land whose state has no server-only,
  per-player, masked or internal data hashes the same both ways).
- Sync-output hashes are unchanged: they hash what clients receive, which #180 does not touch.
  Every sync-output failure stays a failure (exit 8), as in #178.
- Pinned: the full-state hash of the fixed Hero Defense state from #178's test, and of a fixed
  visibility-test state, plus a test that changing any server-only field changes the hash (the
  inverse of #178's test, which goes away).

## 4. Off every client path

- Nothing in `SyncEngine`, `TransportAdapter`, the encoders, the admin projection
  (`/debug/projection`) or the convergence check calls `fullStateSnapshot()` or `makeFull`.
- Test: a package-level counter of `fullStateSnapshot()` calls (test builds only, through
  `@testable`). A land with a server-only field runs joins, firstSync and diffs in all three
  encodings with live hash recording off: the counter stays 0 and every client output is
  byte-identical to a run on #178's head. With recording on, the counter equals ticks +
  initialize, and client outputs are still identical.
- The CLI schema-conformance check from #178 keeps checking the wire in E2E.

## 5. Cost measurement

- **Micro:** a release-build benchmark of `calculateStateHash` old vs new on Hero Defense states
  of 5/20/50 players × 0/20/100 monsters (and visibility-test with 40 entities), median of
  1000 calls, ns per hash and bytes hashed. In EncodingBenchmark as a `--hash-cost` mode, so it
  records toolchain and commit in its results metadata.
- **In the tick:** ServerLoadTest with live hash recording on, before vs after: tick duration
  p50/p99 and the share of the 50 ms tick budget the hash takes.
- Numbers from the 7600X devcontainer only (through Main); Mac runs check correctness.
- If the new hash costs much more than the old one, the fallback is to stream fields into the
  hasher instead of building a `StateSnapshot` and JSON. That is a follow-up, not part of #180,
  unless the numbers say otherwise.

## 6. Re-records and docs

- Re-record a `deep-research/replay-scale-fp-perturbation` batch with a 2.4 build, show 0
  mismatches, and rerun its perturbation detection. Detection can get faster: a perturbation in
  a server-only float (`pathProgress`) was invisible to the broadcast-view hash.
- Docs: `docs/core/reevaluation` (both languages) says what the hash covers, the 2.4 rule, and
  that the hash is not a client-visible value.

## Order

1. Macro + `makeFull` + the counter test (fails until wired).
2. Switch the entry point and the monitor runner; version 2.4; pins; ordering tests.
3. Cost benchmark mode; numbers via Main.
4. Replay-scale re-record; docs.

One PR for 1–2 and 4's docs; the benchmark mode and the re-record are Examples / deep-research
changes on main.
