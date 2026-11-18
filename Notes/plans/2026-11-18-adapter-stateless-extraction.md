# Extract TransportAdapter's stateless encoding and frame-building code (#554)

**Status:** rev 1, for review. **Issue:** #554 (part of #546, step 3 of its order). **Base:** `main` at fe1e5b52; line numbers below are `Sources/SwiftStateTreeTransport/TransportAdapter.swift` there.

## 1. Goal and rule

Move the code in `TransportAdapter` that holds no adapter state into its own types and files, and have the adapter call it as today. A plain refactor: no flag, no behaviour change, no public API change. It is a hot path (every sync cycle encodes through it), so it passes the instruction gate (§5).

**What counts as stateless here.** A function moves if it reads none of the adapter's `var`s. The adapter's `let` tools (the encoders, `landID`) move with it into a `Sendable` value. Per-cycle values the adapter keeps (`planSyncSeq`, `planResyncPlayers`) and the test fault hooks (`…FaultForTesting`) stay in the adapter and are passed in as arguments, or checked in the adapter before the call. A function that reads a `var` (the sync engine and its caches, membership, held events, the dirty-field carry) stays: it belongs to a later slice of #546, and moving it now would decide that slice's state groups early.

The inventory below comes from a script that lists, for every function in the file, the stored properties and instance methods its body uses. A function with no stored property in its body is a candidate. It was then read by hand.

## 2. Why these, against #551 and #546

- **#551's model** (`Notes/plans/2026-11-18-swift-state-turns-core.md`, and #546's settled design): the adapter's machine holds every decision, while "encoders, the transport and the recorder stay outside, as `let` Sendable tools that `perform` uses". `perform` is `@concurrent nonisolated`, so it can't reach actor state. The extracted encoder is that tool. It is a `Sendable` struct built once in `init`, its methods take every per-cycle value as an argument, and it never touches the adapter. So a turn version's effect can call the same functions unchanged. Its one side effect is the shared `UnmappedPathCounter` that the state-update encoders already write when they drop a patch for a path outside the schema. The encoders are built with it today, and it moves with them unchanged. Nothing #551's PR adds or names is touched here (#551 has no adopter changes), so there is no overlap with Code-1's implementation.
- **#546's order:** this is step 3, before the machine outline (step 4) and slice 1 (membership). It moves nothing that slice 1 or the sync-bookkeeping slice (#553) owns: no membership, joining-session, held-event, sync-engine, table or sync-lag code. Those are state groups the outline decides.

## 3. The extractions

### X1. Frame encoding: `EncodingPipeline` grows (hot)

Today's `EncodingPipeline` (already a `Sendable` struct, `Pipeline/EncodingPipeline.swift`, from #38) grows in place to hold these functions. A rename to `StateFrameEncoder`, if any, is a `git mv` in its own commit, so the move commits diff as moves. Fields: `stateUpdateEncoder`, `sequencedStateUpdateEncoder`, `messageEncoder`, `landID`.

| Moves | Lines | Change in the move |
|---|---|---|
| `encodeStateUpdate(update:playerID:playerSlot:scope:)` | 3315–3335 | takes `syncSeq: UInt64?` instead of reading `planSyncSeq` |
| `encodePerPlayerUpdate(_:playerID:playerSlot:)` | 5888–5902 | takes `syncSeq` and `resync: Bool`. The `syncEncodeFaultForTesting` check stays in the adapter's wrapper, before the call |
| `encodeMergedBroadcastFrame(update:playerID:eventBodies:)` | 5031–5073 | splits in two on the encoder, so the fault hooks stay in the adapter and are evaluated in today's order: `encodeMergedBroadcastUpdate(update:playerID:syncSeq:)` (the state part, as an array or as `Data`) and `mergeEvents(into:eventBodies:failsPack: Bool)` (the combined frame, or the state frame alone after `refuseLosingMergedEvents`). The adapter's wrapper checks `mergedBroadcastFrameFaultForTesting` first and throws as today, then encodes, then evaluates `mergedEventsPackFaultForTesting` and passes it as `failsPack`. So the pack hook is still not evaluated when the encode throws |
| `refuseLosingMergedEvents(_:)` | 5082–5089 | becomes `static`, unchanged |
| `buildStateUpdateWithEventBodies` (both overloads) | 3339–3361 | the adapter's forwarding wrappers are deleted; the encoder already has them |
| `encodeServerEventBody(_:)` | 3311–3313 | the forwarding wrapper is deleted |
| event frame pack (in `appendEventFrames`' loop: the opcode-103 array and its `pack`) | 3382–3383, 3388 | a `packEventFrame(_ body:) throws -> Data?` on the encoder (nil for a body that isn't an array, which the loop skips today). The loop, its fault hook and the `LandFailure` mapping stay in `appendEventFrames` |
| `PendingSyncUpdate`, `EncodedSyncUpdate` | 5827–5844 | from `private` nested types to internal file-level types beside the encoder |
| `describeUpdate(_:)` | 5846–5855 | becomes `StateUpdate.typeAndPatchCount` in the existing `extension StateUpdate` (:106) |

**Stays in the adapter, and why:**
- `encodeUpdatesSerially` (5860–5885): the loop is the adapter's, since it applies the per-player fault hook. It calls the encoder per update.
- `encodeMergedBroadcastFrameOrFail` (5011–5027): it writes `plan.encodesBroadcastPatches`.
- `stateFrameEncodeFailure` (4998–5007): it records into `unmappedPathCounter`.
- The `plan…` functions: they assemble the plan and read the tables.

### X2. Pure sync-plan parts: `SyncPlanning` (hot)

A caseless `enum SyncPlanning` with `static` functions, in a new file `SyncPlanning.swift`. It is not generic over `State`, except where noted.

| Moves | Lines | Change |
|---|---|---|
| `replacingRows(of:with:)` | 4918–4939 | already `static`; moved |
| `keyScopeResetUpdate(_:)` | 4943–4950 | `static` |
| `withoutDroppedFields(_ patches:dropped:baseline:)` | 5679–5689 | `static`. The overload over `[PendingSyncUpdate]` (5695–5718) stays: it rebuilds updates with `makePendingSyncUpdate`, which reads the player slot |
| `computeSyncModes(for:extractAll:)` | 5169–5191 | `static`, generic over the state type, and takes `dirtyFields: Set<String>?` (nil when dirty tracking is off or the state isn't dirty). The adapter computes it from `enableDirtyTracking`, `planIsDirty` and `planDirtyFields`, which read `carriedDirtyFields` and stay |
| `modesBesideTables(for:extractAll:broadcastMode:perPlayerMode:)` | 5196–5207 | `static`, with `useSnapshotForSync` and the same `dirtyFields` as arguments |
| `putResyncSnapshotsFirst(_:)` | 3720–3731 | a `mutating` method on `SyncPhasePlan`: it reads only the plan |
| `heldEventFramesPacked(by:)` | 3367–3372 | a method on `SyncPhasePlan`, for the same reason |

### X3. Sync-stream recording helpers (sync path when recording)

`canonicalEvent`, `clearDraft`, `scopeHash` and `sortedIDs` (4242–4281) are already `static` and pure. They move to an `enum SyncStreamCanonical` in `SyncStreamCanonical.swift`. `recordSyncStream` and `recordSyncStreamClear` stay: they read the recording state and the keeper.

### X4. Plain types and helpers (not hot)

- The file-level sync-phase types (30–293: `SyncPhaseConsumedEvents` through `SyncOutputRead`, and the `StateUpdate` extension at 106) move to `SyncPhaseTypes.swift` unchanged. `TransportAdapterHoldPoint` (294–339) and `SessionPerPlayerPolicy` (341–360) stay, since they are the adapter's own.
- `missingStateUpdateFeatures` and `missingFeaturesMessage` (1466–1486, `nonisolated static`) move to an `enum StateUpdateFeatureNegotiation`. Its callers are the adapter (6496, 6502) and `LandRouter` (809, 820, 898, 909), which drops the `TransportAdapter<State>.` prefix. This is internal: neither function is public.
- `mapActionError` and `mapJoinFailure` (6384–6395, 6634–6639) become `static` on an `enum AdapterErrorMapping`.
- `HexEncoding` (6–27) moves to `Support/` beside the other helpers. It is used once, at trace level (3235).
- **Deleted:** `messagePackValueToJSON` and `messagePackMapToJSON` (6739–6766). Nothing calls them except each other.

### Not extracted (and why)

- **Event sending:** already in `EventSendingPipeline`.
- **The snapshot extraction, the diff and the pending-update collectors** (`extractSyncSnapshots`, `collect…PendingUpdates`, `lateJoinSnapshot`, `planFullViewUpdate`, `extractAndComputeBroadcastDiff`): they read `syncEngine` (a `var` holding the caches), the tables and the per-player extraction hooks. They are sync bookkeeping, #553's slice.
- **`makePlan`:** it advances `lastSyncSeq`.
- **The join and error response builders** (`sendJoinError`, `sendJoinResponse`, 6664–6738): they encode and also send.

## 4. Size and shape of the change

- About 450 lines move out of `TransportAdapter.swift`, and about 30 are deleted (the dead helpers and the forwarding wrappers). `Pipeline/EncodingPipeline.swift` grows (X1). New files: `SyncPlanning.swift`, `SyncStreamCanonical.swift`, `SyncPhaseTypes.swift`, `StateUpdateFeatureNegotiation.swift`, plus the small `Support/` and error-mapping moves.
- **One PR, one commit per extraction, X1 to X4, X4 last.** Each commit builds and passes the tests, so a gate regression can be bisected by commit without another PR.
- **Tests:** no new behaviour, so no new behavioural tests. The moved pure functions get unit tests that need no adapter: `replacingRows`, `keyScopeResetUpdate` and `computeSyncModes`, with and without dirty fields. None has a direct test today; the sync suites cover them only through the adapter. One test is written **before** the move, on `main`'s code, and must pass unchanged after it: the bytes of the opcode-103 frame `appendEventFrames` packs for a targeted event, in opcode MessagePack (the only encoding that packs them: opcode JSON never reaches `appendEventFrames`), so `packEventFrame` is pinned by bytes where the gate can't reach it (§5). The existing suites are the proof of equal behaviour:
  - the sync and encoding suites, the #535 failure rows (every fault hook still fires through the adapter's wrappers), and the row and field-merge tests;
  - `swift test` in the three modes (`USE_SYNC_TABLES=false`, `IN_TURN_SYNC=true` and `false`), and E2E in the three encodings.
- **Bytes equal:** the gate's runs compare encoded bytes per cell between base and head (§5).

## 5. Gate: one run for the PR (instructions on the sync path)

The rule is #517's (`Notes/plans/2026-11-13-off-path-instruction-gate.md`): mean `instructions:u` per cell, a REGRESSION when head's mean is above base's by more than max(0.5 %, 3 × base's spread), a GAIN below base's min. Time is reported. The window is `ENCODING_BENCHMARK_PERF_WINDOW=iteration`, which includes `syncNow()`, where this change runs; `nonsync` would leave it out. As in #392's A/B, each result's `perfWindow.mode` must be `iteration`, with `toggles == 2 × iterations` (one room).

**Why one run.** X1 and X2 are on the same path (the sync phase), and X3 and X4 are off it or rarely run. A run per extraction would cost four host sets for changes the bisectable commits can already attribute. If the run shows a regression, the next run is per commit, on the regressing cells only.

**Base:** `main` at run time. **Head:** the PR merged with that `main`. Release builds, both sides in one container from the pinned image (`swift:6.2.4-noble`), with `swift --version` and the image digest recorded beside each side. ABBA, one warm-up pair discarded, then 5 pairs, with `SWIFT_DETERMINISTIC_HASHING=1` on both sides.

**Common flags,** as #392's:
```
EncodingBenchmark --game-type hero-defense --rooms 1 --players-per-room 5 --monster-cap 100 \
  --ticks-per-sync 2 --parallel false --iterations <n> --output json
```
`<n>` is chosen so that a run takes at least 20 s, the same on both sides.

**Proposed cells**, with the switches otherwise at their defaults:

| Cell | Flags | Covers |
|---|---|---|
| rows-mp | `--format messagepack-pathhash --join-through-router on --row-addressing on` | the sequenced encoder; the merged broadcast frame (opcode 107) through `encodeToMessagePackArray` |
| rows-json | `--format opcode-json-pathhash --join-through-router on --row-addressing on` | the sequenced encoder in opcode JSON. No merged frame: opcode 107 is used only with opcode MessagePack (`useStateUpdateWithEvents`, `TransportAdapter.swift:1104`) |
| router-mp | `--format messagepack-pathhash --join-through-router on --row-addressing off` | the per-player and table paths without rows; `computeSyncModes` with dirty tracking |
| rows-mp-100 | rows-mp with `--players-per-room 100` | the per-recipient loop `encodeUpdatesSerially` at many recipients |
| json-control | `--format json-object` (router join off) | the unsequenced encoder (`encodingPipeline.encodeStateUpdate`); must not move |

**Not measured by any cell.** hero-defense emits only broadcast events, so no cell reaches the per-recipient event frame pack (`packEventFrame`) or the held event frames (`heldEventFramesPacked`). No cell is added for them: those moves rest on byte equality (the test written before the move, §4) and the suites, not on the gate.

**Checked per result** (reported, not judged):
- the resolved metadata: router join and rows as asked, the encoding, `syncSequence` in effect on the rows cells and off on json-control;
- encoded bytes per cell equal to the other side's;
- the run's patch and event counts equal to the other side's.

## 6. Order and coordination

- **After #601**, because X4 edits two of `LandRouter`'s join checks, which #601 also touches.
- It is independent of #551's PR, which adds a new target and doesn't touch the adapter. The extracted encoder's shape (a `Sendable` value, per-cycle values as arguments) is the one §2 gives for `perform`. If Code-1's implementation shows a different need (for example, the encoder as a protocol so the differential harness, #555, can inject one), that is a follow-up, not a reason to hold this.
- Host brief: drafted from §5 once the PR has a head.

## 7. Decisions (from review)

1. **`EncodingPipeline` grows in place.** A rename, if any, is a `git mv` in its own commit (X1).
2. **The fault hooks stay booleans,** evaluated in the adapter in today's order: the merged frame hook before the encode, the pack hook only after it (X1).
3. **X4 stays in this PR,** as its last commit.
