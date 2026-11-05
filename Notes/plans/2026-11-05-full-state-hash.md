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
- **`@Internal` properties are not hashed** (decided in the design check). The documented use
  of `@Internal` is a wall-clock value (`var lastProcessedTimestamp: Date = Date()` in
  `StateNodeProtocol`'s doc), which would make every replay mismatch for a reason that is not a
  game-logic divergence, and an internal that influences state shows up in `@Sync` fields
  anyway. The docs say so. An opt-in (`@Internal(hashed)`) can come later if someone needs it.
- **API break:** with no protocol default, a hand-written `StateNodeProtocol` conformance no
  longer compiles until it implements `fullStateSnapshot()` (every field by name, values through
  `SnapshotValue.makeFull(from:)`). The release note and the changelog say this and show the
  implementation. `@StateNodeBuilder` types need nothing.

## 2. Deterministic ordering

- Object keys: the snapshot is encoded with `JSONEncoder` `.sortedKeys`, as today, so field
  order and dictionary iteration order never reach the bytes. Dictionary keys are converted to
  strings the same way as for clients (`makeKeyString`), and two keys that collide as strings
  throw (they would hash ambiguously).
- Arrays keep their order (it is state).
- `Set` (and any other unordered collection found through `Mirror` `.set`): elements are
  sorted by their canonical encoding under the full conversion (sorted-keys JSON bytes of
  `makeFull`), not the broadcast one, so two elements that differ only in server-only fields
  never sort as equal. Today's `make`
  path takes Mirror's order for sets; the full conversion does not.
- Floating point: values are encoded as today (`Double` via `JSONEncoder`); game state uses
  DeterministicMath, so no new float paths appear.
- A test hashes the same state built in different insertion orders (maps, sets) and gets one
  hash.

## 3. Record format 2.4, and how older records are verified

- `ReevaluationRecordVersion.current` becomes `"2.4"`; a 2.4 record holds full-state hashes.
- **No record is excused wholesale** (design check). The broadcast-view hash stays in code as
  `ReevaluationEngine.calculateBroadcastViewHash` (today's definition). Replay picks the
  definition by the record's version:
  - 2.4 and later: the full-state hash, compared exactly.
  - 2.3: the broadcast-view hash, compared exactly.
  - Older than 2.3: the broadcast-view hash, with #178's rule: a mismatch is "recorded before
    #175, hash not comparable" (exit 10) only for a land with the #175 shape reached through
    `.broadcast` fields (`hashChangedByNestedNodePolicies`, kept); any other mismatch fails.
  The initialize hash follows the same choice. A 2.4 build verifies every older record it
  verified before, and nothing more is excused.
- Sync-output hashes are unchanged: they hash what clients receive, which #180 does not touch.
  Every sync-output failure stays a failure (exit 8).
- Pinned: the full-state hash of the fixed Hero Defense state from #178's test and of a fixed
  visibility-test state, the broadcast-view hash of the same Hero Defense state (#178's pin
  stays, now for `calculateBroadcastViewHash`), and a test that changing any server-only field
  changes the full-state hash.

### When the full-state conversion throws

`makeFull` throws on a map whose keys collide as strings (and on any value it cannot convert).
Today a throwing conversion records `stateHash: "error"`, and replay compares `"error"` with
`"error"` as a match. #180 changes that:
- **Live keeper:** the throw never crashes or stalls the tick. It is logged with the tick and
  the error, counted (`stateHashUnavailable` in the land's metrics), and the tick is recorded
  without a hash plus a 2.4 key `stateHashUnavailable: "<reason>"`.
- **Replay:** a tick with that key, or whose replayed conversion throws, is unverifiable, never
  a match. `RunResult` lists those ticks, and `ReevaluationRunner --verify` fails on them with
  its own exit code (11), naming the first tick and the reason.

## 4. Off every client path

- Nothing in `SyncEngine`, `TransportAdapter`, the encoders, the admin projection
  (`/debug/projection`) or the convergence check calls `fullStateSnapshot()` or `makeFull`.
- Test: a package-level counter of `fullStateSnapshot()` calls (test builds only, through
  `@testable`). A land with a server-only field runs joins, firstSync and diffs in all three
  encodings with live hash recording off: the counter stays 0 and every client output is
  byte-identical to a run on #178's head. With recording on, the counter equals ticks +
  initialize, and client outputs are still identical.
- Also with recording on: `snapshotForSync`, `lateJoinSnapshot` and `generateDiff` called
  directly leave the counter unchanged; only the recorder's entry point moves it.
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

## 6. Floats, re-records and docs

- **Server-only floats are hashed now.** Hero Defense's `MonsterState.pathProgress: Float` is
  `.serverOnly`; it was outside the broadcast-view hash. Before any full-state pin goes in:
  - record on arm64 (Mac) and verify on the 7600X (x86_64), and the reverse, not only on the
    same machine. If FMA contraction or library math makes a value differ across
    architectures, that is a determinism finding and is reported as one, before the pin;
  - scan the example lands for server-only `Float`/`Double` fields and for `Date` or other
    clock-derived values in `@Sync` fields.
- Re-record a `deep-research/replay-scale-fp-perturbation` batch with a 2.4 build, show 0
  mismatches (same-machine and cross-architecture), and rerun its perturbation detection.
  Detection can get faster: a perturbation in a server-only float (`pathProgress`) was
  invisible to the broadcast-view hash.
- Docs: `docs/core/reevaluation` (both languages) says what the hash covers (every `@Sync` field
  at every depth, not `@Internal`), how 2.4, 2.3 and older records are verified, the
  unavailable-hash marker, and that the hash is not a client-visible value. The release note
  covers the `StateNodeProtocol` source break.

## Design check (2026-11-05)

Review: go, with these changes, now folded in: `@Sync` fields only (no `@Internal`); older
records verified against the broadcast-view hash instead of being excused (§3); the live-keeper
throw path (§3); the API break note (§1); cross-architecture float check (§6); the sort key of
unordered collections under the full conversion (§2); and the counter assertion for
`snapshotForSync`/`lateJoinSnapshot` with recording on (§4).

## Order

1. Macro + `makeFull` + the counter test (fails until wired).
2. Switch the entry point and the monitor runner; version 2.4; pins; ordering tests.
3. Cost benchmark mode; numbers via Main.
4. Replay-scale re-record; docs.

One PR for 1–2 and 4's docs; the benchmark mode and the re-record are Examples / deep-research
changes on main.
