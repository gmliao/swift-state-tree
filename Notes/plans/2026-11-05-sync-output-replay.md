# Sync-output replay verification

Status: plan, revision 3 (2026-11-05), after two adversarial checks against #114 at 358f6c2 (all
findings accepted; record at the end). Approved for implementation after #114 merges.
Depends on: in-turn sync (#114) being on. Builds on the Replay section of
`2026-11-04-room-transaction-architecture.md` ("Replay readiness for sync output").

## Goal

Reevaluation already compares, per tick, the state hash and the server events. It does not check
what the sync phase sent: the patches each client received and the events that rode with them.

This plan adds, per committed sync plan, a hash of the **canonical patch list** of each committed
scope. The reevaluation run recomputes the lists with a shadow sync engine and compares the
hashes, and applies its own lists to a shadow client view that it compares with the replay state.
Encoded bytes are never compared: DynamicKeyTable slots, per-player frame order and the wire
encoding are not canonical.

## What it catches, and what it does not

Both the live sync phase and the shadow run the same `SyncEngine` diff code, so the hash
comparison alone cannot find a bug in that code: both sides would produce the same wrong patch.

The hash comparison catches:
- **dirty-tracking misses**: the live plan extracts dirty fields only, the shadow extracts
  everything, so a changed field the live run did not mark shows up as a missing patch;
- **nondeterminism** in what reaches the sync phase (state, membership, event queue);
- **cache management**: a cache that the live run staged, unstaged or reset differently from
  what its plan committed (key-scope resets, nil frames, recovery plans);
- **event consumption**: events consumed twice, skipped or reordered (opcode 107 mode).

The **patch-apply oracle** covers part of the diff code: the shadow applies each scope's canonical
patches to a shadow client view and compares the result with the replay state's snapshot of that
scope.
- It catches **diff-from-snapshot bugs**: given correct snapshots, a diff that produces wrong,
  missing or extra patches on both sides.
- It does not catch **extraction or filter bugs**: the snapshot it compares against comes from
  the same extraction and view filters on both sides, so a field the filter wrongly shows or hides
  is wrong in the expected view too.
- The applier must not reuse the diff's path encoding or escaping helpers; it parses paths itself,
  so a shared encoding bug cannot cancel out.

## Locating a sync point

With in-turn sync, sync runs in two kinds of turn:
- a tick turn, when a handler requested a sync or a coincident sync folded in (one output, with
  `turnKind: tick`);
- a sync-only turn, at the sync loop's own interval.

How many sync-only turns fall between two ticks depends on wall-clock timing, and each sync diffs
against the caches the previous one left. A per-tick hash of "what was sent" is therefore not
reproducible; each output records **where** its plan read state.

Each output records `observedTickId`, the keeper's `lastCommittedTickId` when the plan read
state, and the keeper's output sequence at that point.

### Sync-stream counter

The output sequence does not advance in sync-only turns, legacy cycles, seeds or clears, so it
cannot order the sync stream. A dedicated monotonic `syncStreamCounter` does:
- one owner: the adapter, on the executor it shares with the keeper while in-turn sync is on;
- incremented synchronously, in the same segment as each committed plan and each seed or clear
  marker;
- recorded on every output and marker as `streamIndex`.

Replay orders outputs and markers by `streamIndex`. The output sequence stays as a cross-check:
it must be non-decreasing along the stream, or the result is `malformed`.

### One read for state and position

The firstSync and the legacy-cycle copy read state outside a turn. Both use one keeper call that
returns `(state, lastCommittedTickId, syncStreamCounter)` from a single keeper job, so the three
values describe the same point. A read that does not go through it records
`observedTickId == nil`, which stays the guard (`unverifiable(fromTick)`). On tick lands, state changes only in tick
turns (see Invariant), so the state a plan read is the state after `observedTickId`. Replay runs
the shadow plan for that output after it applies `observedTickId`, in recorded order.

`index` (the position of the output among those after the same tick) is recorded only as a
consistency check: replay verifies that outputs arrive in index order and stops with a
`malformed record` result if they do not.

### Invariant: tick lands change state only in tick turns

The plan depends on this. Before implementation, verify each path that can mutate state on a tick
land with in-turn sync on:
- join and leave (OnJoin, OnLeave);
- resolver completions;
- OnInitialize;
- admin and debug routes (freeze, settle, state edits if any).

Every path found must either run inside a tick turn or record a state-change marker that replay
can place. In debug builds, the keeper asserts the invariant: a state mutation outside a tick
turn on a tick land with recording on traps (`assertionFailure`) with the path name.

The assertion applies only to lands with recording on; that is the stated requirement for a
verifiable recording. First implementation step: grep the tests for tick lands that write state
outside tick turns (direct state writes from tests, OnJoin/OnLeave mutations, resolver
completions). Tests among them that enable recording are moved into tick turns; the others are
unaffected because the assertion is off for them. A path that
cannot meet it is listed in Out of scope, and its land kinds are reported `skipped`.

### Invariant audit (at #114 head cf2207b)

Every state write in `LandKeeper` goes through `withMutableStateSync` or a handler call on `state`:

| Site | Path | In a tick turn on tick lands? |
|---|---|---|
| `applyPendingItem` (action, client event, join/leave lifecycle, initialize lifecycle) | `applyInputsInTurn` / `applyInputBatchInTurn` from `runTickTurn`; `processPendingActions` from `runTick` | yes |
| `processPendingActions` from `join`, `leave`, `handleActionEnvelope`, `handleClientEvent` | guarded by `tickHandler == nil` | not reached on tick lands |
| `runTick`, `runTickTurn` (tick handler) | tick loop | yes |
| `performInitialization` (OnInitialize, after its resolvers) | `ensureInitialized`, before tick 0 | **no**: its own turn at `lastCommittedTickId == -1`, with its own sync phase under in-turn sync; recorded as a lifecycle event in frame 0 |
| `shutdownIfIdle` (OnFinalize, destroy-when-empty) | after the tick and sync loops are cancelled | no, but no sync output follows it |
| `executeOnInitialize` | no caller | dead code; remove in the implementation PR |

There is no admin or debug route that writes state, and no test writes state outside a handler, so no test has to move.

The one violation is OnInitialize. Live, it runs at tick -1: a sync output from its own turn, or from a sync-only turn before tick 0, already sees its effects. Replay applies it as the first lifecycle item of frame 0. Worse, a sync-only turn while its resolvers are awaited sees the state before it, also with `observedTickId == -1`. So the producer records an **initialize marker** in the sync stream: a `streamIndex`, taken in the same segment as the `withMutableStateSync` call. Replay applies the recorded initialize when it reaches the marker in stream order, and no longer as part of frame 0. The verifier then knows whether a `-1` output read the state before or after OnInitialize. The marker is a third kind, `initialize`, of `ReevaluationRecordedSyncMarker` (`seed`, `clear`, `initialize`).

This overlaps #115 (OnInitialize server events are not recorded). PR 2 records an initialize
record on both paths, in-turn sync on and off: the server events OnInitialize emitted and the
post-initialize state hash, written by the keeper and independent of the sync stream. With
in-turn sync on, the sync stream's `initialize` marker refers to it. PR 3 verifies its events
and hash, and closes #115. Because both paths record it, on and off recordings stay alike, which
was #115's objection to recording it only in frame 0.

## Canonical form

Scopes of one committed plan, recorded only if the commit wrote them:
- **broadcast**: the broadcast diff the plan computed, after `withoutDroppedFields`. Omitted when
  the plan unstaged the broadcast cache (a nil opcode 107 merged frame).
- **per player**: for each player whose per-player cache the commit wrote, the per-player part of
  its update (the per-player diff, without the broadcast patches it may share in combined mode).
  A player whose frame encoded nil, and whose staged cache and mark were therefore dropped, is not
  listed.
- **events** (opcode 107 merged-frame mode only): the broadcast and targeted events the commit
  removed from the queue (`SyncPhaseConsumedEvents` prefixes).

### Patch list

1. Take the scope's `StatePatch` values (`path`, `PatchOperation`, value).
2. Group them into **prefix classes**: two patches are in one class when one path equals the
   other or is an ancestor of it (component-wise, on `/`). Patches in one class keep their
   relative order from the diff; that order matters (`set /a` then `set /a/b` differs from the
   reverse).
3. Order the classes by their smallest path (byte-wise UTF-8 comparison of components). Classes
   on unrelated paths commute, so their order is not part of the canonical form.
4. Feed each patch, in that order, to a streaming FNV-1a 64 hasher (new: `DeterministicHash.FNV1a64`):
   path, operation tag, and the value walked by a new `SnapshotValue` walker (tagged kinds, sorted
   keys, no intermediate JSON strings).
5. The result is a `UInt64`.

This hash is **independent of the state hash**. The state hash is FNV-1a over the JSON encoding of
a snapshot (`ReevaluationEngine`); the patch hash uses its own walker and is only ever compared
with another patch hash, never with a state hash.

The diff should never put a path and one of its descendants in one scope. The canonical list
reports it (`hasPrefixPairs`) instead of trapping, so the prefix-pair hash stays unit-testable; the
producer (PR 2) asserts in debug builds that it is false. Step 2 keeps the hash well-defined if the
assertion is ever wrong.

### Events

A list of `(sequence, type, payload hash)` in **consumed order**, not sorted; event order is
observable by clients. The sequence is the keeper's output sequence, attached at queue time from
the `ReevaluationRecordedServerEvent` the keeper already creates for each emitted event, and
stored next to the queued body in `PendingEventManager`. Event targets are not part of this hash:
they are already recorded and compared through `ReevaluationEventTargetRecord`.

In json and opcodeJsonArray modes events are not queued; each one is sent when emitted and is
covered by the existing server-event comparison. There is then no events scope.

## Per-player lifecycle markers

The firstSync runs outside the turn and may read state ticks after the join. Per-player
comparison needs the point where the client view was seeded, so the producer records markers in
the tick record of the turn that observed them:

- **seed**: `playerID`, `observedTickId` and sequence of the firstSync's state read, the
  per-player hash of the firstSync view, and whether it was a firstSync or a rejoin
  (reconnection). The shadow seeds the player's per-player cache and client view from the replay
  state at `observedTickId` and compares the seed hash with its own full view. A mismatch there
  is reported as a firstSync mismatch.
- **clear**: `playerID` and sequence, when the live run drops the player's per-player cache and
  firstSync mark (disconnect, leave, or a nil frame that dropped the mark). The shadow drops the
  same state. The next seed marker reseeds it.

A per-player scope that became unverifiable (an encode drop) becomes verifiable again at that
player's next seed marker, which reseeds its cache and view.

A per-player output for a player with no seed in the shadow is a `malformed record` result, not a
skip.

## What is recorded

```swift
public struct ReevaluationRecordedSyncOutput: Codable, Sendable {
    /// Consistency check only: position among the outputs after the same tick (0-based).
    public let index: Int
    /// `tick`, `syncOnly`, or `legacyCycle` (a cycle committed through `commitSyncPhase`
    /// outside a turn while in-turn sync is on: freeze settle, deferred `syncNow` on resume).
    public let turnKind: String
    /// `lastCommittedTickId` when the plan read state; nil when the read cannot be located.
    public let observedTickId: Int64?
    /// Position in the sync stream (`syncStreamCounter`); replay orders by it.
    public let streamIndex: UInt64
    /// Keeper output sequence when the plan read state (cross-check only).
    public let sequence: Int64
    /// Nil when the broadcast scope was not committed.
    public let broadcastHash: UInt64?
    /// One hash over (playerID, hash) pairs sorted by player ID, for committed players.
    public let perPlayerHash: UInt64?
    /// Committed players' hashes; present only with `recordSyncDetails`.
    public let perPlayerHashes: [String: UInt64]?
    /// Opcode 107 mode only.
    public let eventsHash: UInt64?
    /// Top-level fields the plan's extraction dropped, per scope ("broadcast" or a player ID).
    public let extractionDrops: [String: [String]]
    /// Scopes whose patches did not encode and were dropped (`droppedUpdates`).
    public let encodeDropScopes: [String]
    /// Canonical patch lists per scope; present only with `recordSyncPatches`.
    public let patches: [String: [StatePatch]]?
}

public struct ReevaluationRecordedSyncMarker: Codable, Sendable {
    public let kind: String            // "seed", "clear" or "initialize"
    public let playerID: String?       // seed and clear only
    public let observedTickId: Int64?  // seed only
    public let streamIndex: UInt64
    public let sequence: Int64
    public let rejoin: Bool            // seed only
    public let viewHash: UInt64?       // seed only
}
```

Both lists are stored in `ReevaluationTickRecord` (the per-turn submission, #114) and in
`ReevaluationTickFrame` (the file format), as `syncOutputs` and `syncMarkers`, decoded with
`decodeIfPresent ?? []`. Replay processes them in one stream ordered by `streamIndex`.

Submission: one recorder entry, `ReevaluationRecorder.recordSyncStream(_:)`, takes the outputs
and markers of a commit or marker point. It goes through the same chained submission as
`recordTick`, so it cannot overtake or be overtaken by the turn records. It merges into the frame
of the entry's `observedTickId`; a clear marker, which has none, merges into the current tick's
frame.

A plan that throws commits nothing and records nothing.

`perPlayerHash` is one combined value by default, to keep records small. A per-player mismatch
then names no player; the report says to rerun with `recordSyncDetails` (per-player hashes) or
`recordSyncPatches` (patch lists, which name the exact path).

## Live producer

- Counter owner (adapter or keeper) is decided in PR 2 and written back here. Either way, the
  counter is incremented only on the executor the keeper and adapter share under in-turn sync,
  and with in-turn sync off nothing is recorded: no `assumeIsolated` is reachable on that path.
- Recording runs only when the land records reevaluation data. The adapter holds a synchronous
  flag, `recordsSyncStream`, set once when the keeper's recorder is attached. With it off,
  `SyncOutputDigestInput` stays nil, the counter does not advance, and nothing is hashed or
  submitted.
- The producer is in the shared `commitSyncPhase`, so every commit records an output: tick and
  sync-only turns, and the legacy cycles that still commit while in-turn sync is on (freeze
  settle, `deferredSyncNow` on resume). A legacy cycle's plan reads a state copy; it records the
  `lastCommittedTickId` of that copy when the copy is taken at a turn boundary, and nil otherwise.
- `SyncPhasePlan` keeps the scope patch lists it already builds (the broadcast diff and the
  per-player `StateUpdate`s before encoding) plus the extraction drop sets in a
  `SyncOutputDigestInput`, filled only when recording is on. The commit hashes only the scopes it
  writes, in the same synchronous segment as the commit, so commit order is record order.
- The firstSync path records the seed marker from the state read it sends (the one-read call
  above). The per-player cache
  drop paths record the clear marker.
- No re-encoding: the hash input is the patch values, not the frames.

## Reevaluation side

The replay keeper's own adapter syncs to replay viewers, not to the recorded players, and on the
viewers' wall-clock cadence; its caches cannot serve as the verifier. Verification uses a
**shadow sync engine**, driven by the runner.

### Construction

- A `SyncEngine` with its own caches.
- Its sync configuration comes from the replay land's `LandDefinition`, the same definition the
  live land used (`registerWithReevaluationSameLand`): sync strategy and modes, the
  `useStateUpdateWithEvents` choice, view filters, and the per-player context used for
  per-player extraction. The record's `landConfig` is checked against the definition; a
  difference is `skipped("sync config differs from record")`.
- `deletePatchesForVanishedTopLevelKeys` is `SyncEngine` behaviour, so it is the same on both
  sides.
- The construction path is one function next to the existing reevaluation `SyncEngine()` uses in
  `ReevaluationEngine`, so the live and shadow configuration cannot drift by duplicated code.

### Stepping

For each recorded tick N, after applying it, the runner processes the outputs and markers whose
`observedTickId` is N, in `streamIndex` order:
- a marker: seed or clear, as above;
- an output with `observedTickId == nil`: verification stops, and the result is
  `unverifiable from tick N (unlocated legacy cycle)`;
- an output: one shadow plan, then commit into the shadow caches:
  - full extraction, so it does not depend on the live dirty tracking;
  - the recorded `extractionDrops` are applied as the same drop set (`withoutDroppedFields`), so
    a field the live extraction dropped is dropped in the shadow too;
  - a scope in `encodeDropScopes` stops being verified from this output on, since its live cache
    and the client's view diverged by design. It is counted as unverifiable;
  - only the scopes the output lists are diffed and committed.

Then:
- compare the broadcast, per-player and events hashes;
- apply the shadow's canonical patches to the shadow client views and compare each view with the
  replay state's view of that scope (broadcast snapshot, per-player snapshot) at `observedTickId`.

A field marked dirty whose value did not change produces no patch on either side, so full
extraction and dirty extraction agree for a correct live run.

### Applier

The patch applier for `SnapshotValue` exists only in tests today. Two copies are generic
JSON-pointer appliers (`SyncStrategyEquivalenceTests`, `TransportAdapterSyncPhaseTests`); two are
typed projections onto their own client models (`SyncEngineEndToEndTests`,
`TransportAdapterSyncDirtyWindowTests`) and stay as they are. This work adds one package-level
applier in `SwiftStateTree/Sync` and moves the two generic copies onto it. It follows the client
where a correct diff can lead (a set below a missing parent creates it as an empty object) and
throws where only a wrong diff can (a set below a non-object parent, a delete of a missing field).
The oracle mirrors the client contract in `sdk/ts/src/core/view.ts`; if that contract changes, the
oracle changes with it. `SnapshotPatchApplierTests` pins the contract (a set below a missing parent
creates `{}`). Two deliberate differences, both client path-parsing bugs tracked in #121: the
applier unescapes `~1`/`~0`, which the TS client does not yet do, and it reads a component such as
`items[0]` as a dictionary key, where `view.ts` reads it as an array element. The Swift diff never
emits array-index paths (arrays are replaced whole), so the applier is right about the diff; a
passing oracle does not show that the client converges for keys containing `/`, `~` or `[n]`.
It has its own path parsing (no shared
helpers with the diff), and its own unit tests against hand-written patches and expected values,
independent of the diff.

### Mismatch report

The first mismatch stops verification:

```
sync output mismatch at tick 1234, output 2 (syncOnly, sequence 98765)
  check: hash | apply
  scope: broadcast | per-player (player p7) | per-player (combined) | events | seed (player p7)
  rerun with recordSyncPatches for the exact path
```

The summary always shows the counts of compared outputs, unverifiable outputs or scopes, and
skipped outputs, so "0 mismatches" cannot hide "0 compared". The result is a new `syncOutput`
section in the reevaluation report (`ReevaluationRunnerImpl` / `ReevaluationEngine`), next to the
state-hash and server-event results: `passed`, `failed(firstMismatch)`, `unverifiable(fromTick)`,
`skipped(reason)` or `malformed(reason)`.

## Format version and compatibility

The runner (`ReevaluationRunnerImpl`, `requiredRecordVersion`) and the replay start route
(`NIOAdminRoutes`, `expectedRecordVersion`) compare the record version with an exact `!=`. A bump
to "2.1" would make every new record fail against an older runner and every old record against
a newer one. So:

- The version check becomes major/minor: a runner accepts any record with the same major version.
  A newer minor is accepted and its unknown keys are ignored; an older minor is accepted and the
  features it lacks are reported `skipped`.
- The producer writes "2.1".
- A 2.0 record decodes unchanged (empty lists) and reports `syncOutput: skipped("record has no
  sync outputs")`, never `passed`.
- A record made with in-turn sync off carries no outputs, so it is skipped the same way.
- A 2.1 record read by a 2.0-era runner fails that runner's exact check. That is accepted: the
  runner and the record producer ship in one package version.

## Out of scope (revision 2)

- **The legacy path (in-turn sync off).** Its plan runs on a copy across awaits; sync points are
  not turn boundaries.
- **Tickless lands.** A sync can fall between two inputs of one recorded frame. This needs
  per-input replay stepping or a recorded input watermark per sync. Follow-up.
- **Join as a captured input (#69).** Revision 2 handles the firstSync with seed markers instead;
  after #69 the seed point becomes the join turn and the marker's `observedTickId` is that turn.
- **Encoded bytes, DynamicKeyTable slots, per-player frame order**: never compared, by design.
- **Encode failures**: the affected scope becomes unverifiable; not reproduced.
- Any tick-land mutation path that fails the Invariant check.

## Tests

- **Canonical form, unit**:
  - patches on unrelated paths in two orders hash equal;
  - two patches on the same path in swapped order hash differently;
  - a prefix pair (`set /a`, `set /a/b`) in swapped order hashes differently, and trips the debug
    assertion in a debug-assertion test;
  - a changed value, a changed operation or a missing patch each hash differently;
  - reordered events hash differently.
- **Deterministic run equal**: a tick land with recording on, two players joined before the first
  tick, several sync-only turns between ticks, and a third player joining and reconnecting
  mid-run (seed and clear markers). Reevaluation compares every output and passes the apply
  oracle: 0 mismatches, compared > 0.
- **Perturbation, must be detected**: a test-only fault hook in the live plan perturbs the frames
  actually committed (not only the hash input). Reevaluation must report the first mismatching
  tick, output index and scope. Variants:
  - drop one broadcast patch;
  - change one per-player value;
  - drop one consumed event (opcode 107 mode);
  - swap two consumed events;
  - skip marking a changed field dirty (dirty-tracking miss).
- **Diff-engine bug, caught by the apply oracle only**: a test-only fault in `SyncEngine` that
  produces a wrong patch on both sides. The hashes match and the apply check fails.
- **Perturbation, must not be detected**: reorder patches on unrelated paths. Prefix pairs are
  excluded from this test.
- **Drops**: an extraction drop is recorded and the shadow applies it (passes); an encode drop
  makes that scope unverifiable and is counted.
- **Legacy cycle while on**: a freeze settle and a resume `deferredSyncNow` are recorded and
  verified; a forced unlocated cycle produces `unverifiable(fromTick)`.
- **Compatibility, both directions**: a 2.0 record on the new runner reports `skipped`; a 2.1
  record on a runner that requires 2.0 passes the major/minor check, ignores the new keys and runs
  the state-hash and server-event checks; an in-turn-off record reports `skipped`.
- **Off path records nothing**: in-turn sync off with a recorder on produces zero sync-stream
  entries (outputs and markers), while the initialize record (#115) is still written.
- **No recorder, no work**: a land without a recorder runs syncs with in-turn sync on; a
  test-only counter on the digest path stays 0, `SyncOutputDigestInput` is nil on every plan, and
  `syncStreamCounter` does not advance.
- **Stream order**: a seed, a clear, a sync-only output and a legacy-cycle output between two
  ticks replay in `streamIndex` order; a record with a decreasing sequence along the stream is
  `malformed`.
- **Applier, unit**: hand-written patches against expected values, including escaped path
  components, independent of the diff.
- **Invariant**: the debug assertion trips for a deliberate out-of-turn mutation on a tick land.
- **Replay E2E**: `test-e2e-game.sh` reevaluation step with in-turn sync on, all three encodings:
  sync output 0 mismatches, with the compared count printed. The CI steps assert `compared > 0`.

## Cost

- Live, with recording on: per committed scope, prefix grouping and a sort, O(p log p) for p
  patches, plus a streaming walk of each value. No JSON strings are built. Nothing without a
  recorder.
- Record size: per output a few `UInt64`s plus drop lists, which are usually empty. Per-player
  detail and patch lists are only recorded behind flags.
- To measure when implemented, with recording on and off:
  - the hero-defense load test;
  - the 50-player json room;
  - sync-turn p50/p99, and record bytes per tick.
- Budget: under 10% added to the sync-only turn p99. If it is exceeded, hash lazily per scope or
  sample outputs, and say so in the report.
- Replay: one full-extraction shadow plan plus one apply per output, off the hot path.

## Adversarial check record

All findings accepted; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| B1 | blocking | Per-player seed markers (firstSync and rejoin) with the observed tick of the state read, and clear markers at disconnect/leave/mark drop; the shadow seeds from replay state at that tick and compares the seed view |
| B2 | blocking | Producer in the shared `commitSyncPhase`: every commit records, including freeze settle and resume `deferredSyncNow` (`turnKind: legacyCycle`); an unlocated read gives `unverifiable(fromTick)`, shown in the counts |
| B3 | blocking | Extraction drops recorded per scope and applied as the same drop set in the shadow; encode-drop scopes become unverifiable from that output |
| B4 | blocking | Prefix classes keep parent/child relative order; debug assertion that a scope has no prefix pair; unit test for the prefix pair; prefix pairs excluded from the must-not-detect test |
| S1 | should | "What it catches" section; patch-apply oracle against the replay state, with a package-level applier replacing the test copies; a diff-engine fault test |
| S2 | should | Only committed scopes are hashed: no broadcast hash when the broadcast cache was unstaged, per-player hash only for committed players |
| S3 | should | Shadow configuration from the replay land's `LandDefinition`, one construction function shared with the existing reevaluation `SyncEngine` use; `landConfig` check |
| S4 | should | Invariant section: paths to verify, debug assertion, test |
| S5 | should | Version check becomes major/minor; tests in both directions |
| S6 | should | `UInt64` hashes, one combined per-player hash with details behind a flag, streaming `SnapshotValue` walker; 50-player json room added to the measurement |
| N1 | nit | `index` is a consistency check only |
| N2 | nit | Event targets covered by `ReevaluationEventTargetRecord` |
| Q1 | — | Only committed plans and scopes are recorded |
| Q2 | — | A folded sync is one output with `turnKind: tick` |
| Q3 | — | Event sequence attached at queue time from the keeper's recorded server event |
| Q4 | — | No field hashes in revision 2; the report hints at `recordSyncDetails` / `recordSyncPatches` |
| R2-B1 (rev 2 pass) | blocking | `syncStreamCounter`: one owner, incremented synchronously at each committed plan and seed/clear, recorded as `streamIndex`; replay orders by it, sequence is a cross-check |
| R2-B1c (rev 2 pass) | condition | One keeper call returns `(state, lastCommittedTickId, syncStreamCounter)` from a single job for firstSync and the legacy-cycle copy; `observedTickId == nil` stays the guard |
| R2-S1 (rev 2 pass) | should | Adapter flag `recordsSyncStream`; without a recorder no digest, counter or submission; test |
| R2-S2 (rev 2 pass) | should | `recordSyncStream(_:)` through the same chained submission as `recordTick`, merged into the `observedTickId` frame or the current tick for clears |
| R2-S3 (rev 2 pass) | should | Oracle scope stated (diff-from-snapshot yes; extraction and filter no); applier has its own path parsing and hand-written-patch tests |
| R2-S4 (rev 2 pass) | should | Assertion limited to recording-on lands; first step greps tests for out-of-turn tick-land writes |
| R2-N1 (rev 2 pass) | nit | A per-player scope becomes verifiable again at its next seed marker |
| P1 (prep) | — | Invariant audit at #114 cf2207b: OnInitialize is the one out-of-turn write on tick lands; `initialize` marker added; dead `executeOnInitialize` removed in PR 1 as its own commit |
| P2 (prep) | — | Patch hash independent of the state hash (no shared encoding claim) |
| P3 (prep) | — | Counter owner decided in PR 2; shared-executor increments only; off path records nothing, with a test |
| P4 (prep) | — | Initialize record on both paths (events + post-initialize hash) in PR 2, verified in PR 3; closes #115 |
| I1 (PR 1) | — | Prefix-pair assertion moves from the hasher to the producer; only the two generic test appliers move onto the package applier |

## Implementation PRs

1. Hash primitives (`FNV1a64`, `SnapshotValue` walker), canonical patch list, package-level
   applier (the two generic test copies move onto it); removal of `executeOnInitialize` as its own
   commit. No behaviour change.
2. Record format (`syncOutputs`, `syncMarkers`, initialize record), producer, markers, stream
   counter, version check. Recording only; the verifier reports `skipped`.
3. Shadow verifier, apply oracle, report, perturbation tests, initialize verification (closes
   #115), E2E `compared > 0` assertion.
