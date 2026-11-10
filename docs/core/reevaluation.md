[English](reevaluation.md) | [中文版](reevaluation.zh-TW.md)

# Deterministic Re-evaluation

> SwiftStateTree's Re-evaluation capability allows you to record live game sessions and replay them deterministically for debugging, testing, and analysis.

## Overview

Re-evaluation is the ability to **re-execute state transition logic under fixed world conditions**. Unlike traditional replay (which just plays back recorded data), Re-evaluation actually runs the handlers again with the same inputs.

### Key Concepts

| Concept                  | Description                                                    |
| ------------------------ | -------------------------------------------------------------- |
| **Live Mode**            | Normal execution, records all inputs and resolver outputs      |
| **Reevaluation Mode**    | Replays recorded inputs, skips resolvers, verifies state hash  |
| **Deterministic Output** | Events and sync requests are queued and flushed at end of tick |

## How It Works

### Recording (Live Mode)

In Live mode, `LandKeeper` automatically records:

1. **Actions** - `sequence`, `payload`, `resolverOutputs`, `resolvedAtTick`
2. **Client Events** - `sequence`, `payload`, `resolvedAtTick`
3. **Lifecycle Events** - `OnJoin`, `OnLeave`, `OnInitialize` with resolver outputs
4. **Server Events** - Events emitted via `ctx.emitEvent()`
5. **State Hash** - Optional per-tick hash for verification

```swift
// Recording is automatic in Live mode
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .live,  // Recording enabled
    enableLiveStateHashRecording: true  // Enable per-tick hash
)
```

### Replay (Reevaluation Mode)

In Reevaluation mode, `LandKeeper`:

1. Loads recorded inputs from `ReevaluationSource`
2. Skips resolver execution, uses recorded `resolverOutputs`
3. Executes handlers with same inputs
4. Compares state hash after each tick

Inputs are recorded before their handler runs, so an input whose handler throws is in the record too, in order; replay runs it again and it fails the same way.

> **Tickless lands.** A land without a tick handler records all its inputs under tick 0, and replay applies them there in order (#167, #268), so its server events are compared. From record format 3.1 its frame also records each live pass: the sequence counter before the pass and the inputs it applied, in order (`passes`). Replay runs each pass as an input turn after restoring its counter, so inputs apply in the live order even when one overtook another (an action waiting for its resolvers, #325) and the event sequence numbers match live (#321); the verdict is `passed` or `failed`. Passes that don't name every input of the frame exactly once, that name a sequence that isn't an input of the frame, or whose counters decrease, fail the tick: no input of the tick after the mismatch is found is applied (the check runs before any pass, so a record that fails it applies none). The hosted replay (`ReevaluationStepResult.recordedPassMismatch`) reports such a tick as not matching, and the replay land doesn't fall back to its recorded events. A 3.0 or 2.x tickless record has no passes: replay applies its inputs in sequence order, and the verdict is `passedIgnoringSequence` for that tick: types, payloads, targets and order are compared, but the numbers aren't. A tickless land records no per-tick state hash, so only its events are verified. An empty recorded list is compared too: a replay that emits events where the live run emitted none fails. A 2.5 or 2.6 record kept only the last list of server events recorded in a tick, so an old tickless record in which several passes emitted events fails replay; re-record it with the current server.

```swift
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .reevaluation,
    reevaluationSource: JSONReevaluationSource(filePath: "recording.jsonl")
)

// Step through ticks manually
await keeper.stepTickOnce()
```

## Recording Format

Recordings are saved as JSONL (JSON Lines) format:

```jsonl
{"kind":"metadata","landID":"game:abc123","landType":"game","createdAt":"2024-01-01T00:00:00Z"}
{"kind":"frame","tickId":0,"actions":[],"clientEvents":[],"lifecycleEvents":[{"kind":"initialize",...}]}
{"kind":"frame","tickId":1,"actions":[{"sequence":1,"typeIdentifier":"MoveAction",...}],...}
```

### Data Structures

| Structure                | Fields                                                                                                            |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `RecordedAction`         | `sequence`, `typeIdentifier`, `payload`, `playerID`, `clientID`, `sessionID`, `resolverOutputs`, `resolvedAtTick` |
| `RecordedClientEvent`    | `sequence`, `typeIdentifier`, `payload`, `playerID`, `clientID`, `sessionID`, `resolvedAtTick`                    |
| `RecordedLifecycleEvent` | `kind`, `sequence`, `tickId`, `playerID`, `resolverOutputs`, `resolvedAtTick`                                     |
| `RecordedServerEvent`    | `sequence`, `tickId`, `typeIdentifier`, `payload`, `target`                                                       |
| `ReevaluationTickFrame`  | `tickId`, `stateHash`, `actions`, `clientEvents`, `lifecycleEvents`, `serverEvents`, optional `sequenceBeforeInputs` / `sequenceBeforeTickHandler` |
| `ReevaluationRecordedPass` | `sequenceBefore`, `inputs` (sequences in apply order); in a tickless frame's optional `passes` (3.1) |
| `ReevaluationRecordedServerInput` | `sequence`, `typeIdentifier`, `payload`, `resolvedAtTick`; in a frame's optional `serverInputs` (3.2) |

## Using ReevaluationMonitor

The `SwiftStateTreeReevaluationMonitor` module provides a web-based UI for visualizing replay:

### Server Setup

```swift
import SwiftStateTreeReevaluationMonitor

// Create factory for your Land types
struct MyReevaluationFactory: ReevaluationTargetFactory {
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        switch landType {
        case "game":
            return try await ReevaluationRunnerImpl(
                definition: GameLand.definition,
                recordFilePath: recordFilePath
            )
        default:
            throw ReevaluationError.unknownLandType(landType)
        }
    }
}

// Register the monitor land
let monitorService = ReevaluationRunnerService(factory: MyReevaluationFactory())
server.registerLand(ReevaluationMonitor.makeLand(), services: [monitorService])
```

### WebClient

Connect to the monitor land and send actions:

```typescript
// Start verification
await client.sendAction("startVerification", {
  landType: "game",
  recordFilePath: "/path/to/recording.jsonl",
});

// Pause/Resume
await client.sendAction("pauseVerification", {});
await client.sendAction("resumeVerification", {});
```

## Verification

### State Hash Proves Reevaluation

The per-tick `stateHash` is a deterministic FNV-1a64 hash of the sorted-keys JSON of the full server state (`fullStateSnapshot()`, record format 2.4 and later): every `@Sync` field at every depth, whatever its policy. Server-only, per-player and masked fields are hashed with their real values, and nested state nodes contribute all their `@Sync` fields too, also when they sit inside a `@SnapshotConvertible` value (its generated `toFullSnapshotValue()`) or an enum payload. A value with only a hand-written `toSnapshotValue()` (for example the DeterministicMath types) is hashed as that conversion gives it. `@Internal` properties are not hashed: their documented use is values such as a wall-clock timestamp, which would make every replay mismatch; an internal that influences state shows up in `@Sync` fields anyway. When live and replay produce the same hash for every tick, the state transition logic is deterministic. Server events are derived from the same handlers and inputs; recording them allows an additional consistency check.

The hash is never sent to clients and no sync path computes it: client output is unchanged by it. Map keys become strings as for clients (two keys of one map that become the same string make the hash unavailable), and set elements are ordered by their canonical encoding, so insertion order never reaches the hash.

### Oldest Readable Record (2.5)

Record format 2.5 (#154) writes `PlayerID`, `ClientID`, `SessionID` and `LandID` as strings, and a dictionary keyed by one as an object keyed by the string, the shape every encoder now sends. A state holding a `ClientID`, `SessionID` or `LandID` therefore hashes differently from 2.4 (`PlayerID` was already a string there). Older records hold them as objects (`{"rawValue": ...}`), which no longer decode, and they are not converted: a reader rejects any record older than 2.5 as unsupported before replaying it (`ReevaluationRecordVersionError.unsupported`). `ReevaluationRunner --verify` prints "unsupported record version ...; re-record with the current server" and exits 10 (not comparable, never a mismatch), and the admin replay start route answers 409 `RECORD_VERSION_UNSUPPORTED`. Re-record such sessions with the current server. The sections below on older formats describe how those records were verified.

### Masked Fields Under a Broadcast Parent (2.6)

Record format 2.6 (#179) marks a change in what clients receive: a `.masked` field below a `.broadcast` field is now sent, masked, in broadcast snapshots and diffs; before, it was left out. The state hash is unchanged, so 2.5 records are still read and verified. A 2.5 record of a state with that shape (a state node with a `.masked` field, held at any depth by a `.broadcast` field) replays with sync-output mismatches (exit 8), which are not marked as not comparable: re-record such sessions with the current server. None of the example lands has the shape.

### Tickless Passes (3.1)

Record format 3.1 (#325, #321) adds the optional `passes` of a tickless land's frame, described under How It Works. The field is additive: a 3.1 reader reads 3.0 records, which replay as before. A 3.0 build reading a 3.1 record ignores the field and replays a tickless land in sequence order, as it always did. Tick lands record no passes, so their frames are unchanged.

### Server Inputs (3.2)

Record format 3.2 (#387) adds a frame's optional `serverInputs`: the inputs a land's server code submitted (`submitServerInput`, applied by `HandleServerInput`), in the record form the handlers received. They share the `sequence` counter with the other inputs, and a tickless land's passes list them like the others. Replay applies them from the record, so a replaying land takes no server inputs of its own. A 3.1 record has none and replays as before.

A reader from 3.2 on refuses a 3.x record whose minor is newer than its own, naming both versions (`ReevaluationRecordLogError.newerMinor`, `ReevaluationRecordVersion.isReadable`): replay it with a build at least as new as the one that recorded it. A 3.1 build predates that check: it reads a 3.2 record and replays it without its server inputs, so it can't match the live run where they were applied. Replay 3.2 records with 3.2 or later.

### Which Hash a Record Holds

| Record format | State and initialize hash | Verified against |
|---|---|---|
| 2.4 and later | full state (`ReevaluationHashDefinition.fullState`) | the full state, exactly |
| 2.3 | broadcast view, `snapshot(for: nil)` | the broadcast view, exactly |
| older than 2.3 | broadcast view, before #175 | the broadcast view, with the #175 rule below |

The reader picks the definition from the record's version (`ReevaluationRecordVersion.hashDefinition`), and `RunResult.hashDefinition` reports it, so older records verify as before and nothing is excused wholesale. Sync-output hashes hash what clients receive and are unchanged by 2.4.

### Unavailable State Hashes

If the state cannot be converted for the hash (a map whose keys collide as strings, a value of an unsupported type, a NaN or infinite floating-point value, which JSON cannot encode), the live tick is not stopped: its hash is recorded as `unavailable: <reason>`, the keeper logs an error and counts it (`LandKeeper.stateHashUnavailableCount`). Replay reports such a tick as unverifiable, never as a match (`RunResult.unverifiableStateHashes`; older builds recorded `"error"`, which is treated the same way), and the initialize check reports `unverifiable`. A valid recorded hash that the replay cannot compute is a divergence, reported as a mismatch. `ReevaluationRunner --verify` exits with code 11 for unverifiable hashes only after every definite failure: a state hash mismatch (5), server events (6), sync outputs (8) and OnInitialize (9) take precedence.

Unsigned integers above `Int.max` (`UInt`, `UInt64`) convert to their decimal digits as a string, on every path: before, they trapped. Values that fit in `Int` are unchanged on the wire.

### Records Older Than 2.3 (#175)

Before record format 2.3, a `@SnapshotConvertible` state node inside a `[String: X]` or `[PlayerID: X]` map was converted with every field, server-only ones included (Hero Defense's `players.*.lastFireTick`). Its state hash, its initialize hash and its sync-output hashes covered those fields. This build leaves them out, so such a record no longer reproduces its hashes.

Hashes are still compared for every record. Whether a land is affected is decided from its state type, not from the recording (`ReevaluationRecordVersion.hashChangedByNestedNodePolicies`): a `@SnapshotConvertible` state node as the value of a `[String: X]` or `[PlayerID: X]` map, at any depth, reached through `.broadcast` fields only, since the hash covers the broadcast view. Hero Defense is affected; visibility-test is not (its `entities` map is `.perPlayer`). When a record older than 2.3 of an affected land has a differing state or initialize hash, the reader reports it as not comparable ("recorded before #175, hash not comparable"), not as a replay difference: `RunResult.hashIncomparability` carries the reason, the initialize check reports `notComparable`, and `ReevaluationRunner --verify` exits with code 10. Re-record such sessions with a current build. Every other mismatch is a failure as before: any mismatch of an unaffected land, whatever its record version, and every sync-output failure (exit 8). Two consequences, both on the safe side: a pre-2.3 visibility-test record verifies its state hash but fails its sync outputs (exit 8), since its per-player patches changed; and a map inside a non-node `@SnapshotConvertible` value is not detected, so such a land's mismatch fails (exit 5). A 2.3 record of any land, and any 2.4 record, is compared exactly.

### Server Event Verification

When `enableLiveStateHashRecording: true`, the server also records server events (`ctx.emitEvent()`) per tick. During reevaluation with `--verify`, the runner compares recorded vs emitted server events. A mismatch indicates non-determinism in event emission (e.g., ordering or payload differences).

Actions, client events, lifecycle events and server events share one `sequence` counter. Live ticks of a ticked land record two watermarks of that counter on the tick frame (`sequenceBeforeInputs`, `sequenceBeforeTickHandler`), and reevaluation moves the counter forward to them, so replayed server events get the recorded `sequence` values. From record format 3.1, a tickless land's frame with recorded passes counts as watermarked too (`watermarkedTicks`): replay restores the counter before each pass. The comparison is decided per tick: a tick whose frame has watermarks must match exactly, including `sequence`, and is compared even when its recorded list is empty, so an extra replay event is reported. Ticks from older records without watermarks keep the previous rule: they are compared only when events were recorded, and a difference in `sequence` alone is reported as a warning, not a failure (`ReevaluationEngine.RunResult.serverEventVerification`).

### Sync-Output Verification

Each committed sync plan records, per scope (the broadcast scope and each player's), a hash of its canonical patch list, plus the events that rode with it. Encoded bytes are not compared: dynamic-key slots, frame order and the wire encoding are not canonical. Replay re-plans every recorded sync output with a shadow sync engine fed the replay state, and compares the hashes (`ReevaluationRunner --verify` exits with code 8 on a mismatch).

What it catches:

- dirty-tracking misses: the live plan extracts dirty fields only and the shadow extracts everything, so a changed field the live run did not mark shows up as a missing patch;
- nondeterminism in what reaches the sync phase (state, membership, the event queue);
- cache management: a cache the live run staged, unstaged or reset differently from what its plan committed (key-scope resets, recovery plans);
- event consumption: events consumed twice, skipped or reordered (opcode 107 mode).

A patch-apply oracle also applies each scope's patches to a reference client view and compares the result with the replay state's view of that scope, which catches a diff that produces wrong, missing or extra patches from correct snapshots.

What it does not prove: live and shadow run the same `SyncEngine` extraction and the same policy filters, so a field a filter wrongly shows or hides is wrong on both sides and in the expected view too. It verifies that the sync phase is deterministic and consistent with its own projection, not that the projection is right.

For diagnosis, `REEVALUATION_RECORD_SYNC_DETAILS=true` records each committed player's hash, so a per-player mismatch names the player, and `REEVALUATION_RECORD_SYNC_PATCHES=true` records each scope's canonical patch list, so a mismatch names the first differing path. Both are off by default; the patch lists are as large as the state updates, so use them for short runs only.

### Field-Level State Diff (Debug)

For deep debugging of hash mismatches, you can record the full per-tick state snapshot alongside the main record and then use `--diff-with` to produce field-level diffs during reevaluation. The recorded snapshot is the one the hash covers (the full state from 2.4), so a diff names the field the hash saw.

**Step 1 – Enable state snapshot recording on the server:**

```bash
ENABLE_STATE_SNAPSHOT_RECORDING=true ./YourServer
```

When this env var is set, the recorder writes a `*-state.jsonl` file alongside the main `.json` record. Each line is:

```json
{"tickId": 42, "stateSnapshot": { ... }}
```

**Step 2 – Run reevaluation with `--diff-with`:**

```bash
swift run ReevaluationRunner \
  --input path/to/recording.json \
  --diff-with path/to/recording-state.jsonl
```

Any field-level differences between recorded and computed state are printed to stderr:

```
[tick 42] DIFF at players.p1.position.v.x: recorded=98100 computed=0
[tick 42] DIFF at players.p1.position.v.y: recorded=35689 computed=0
```

> **Note:** `ENABLE_STATE_SNAPSHOT_RECORDING` is intended for debug sessions only. It increases memory usage and I/O per tick.

## Best Practices

1. **Keep handlers deterministic** - Avoid using `Date()`, `random()`, external API calls directly in handlers
2. **Use Resolvers for non-deterministic data** - Move async/non-deterministic operations to Resolvers
3. **Enable state hash recording** - Set `enableLiveStateHashRecording: true` for verification
4. **Use `emitEvent` not `spawn + sendEvent`** - Ensures deterministic event ordering

## Related Documentation

- [Runtime Mechanism](runtime.md) - Event Queue and Tick execution model
- [Resolver Mechanism](resolver.md) - How to handle non-deterministic operations
- [Design: Re-evaluation vs Traditional Replay](../../Notes/design/DESIGN_REEVALUATION_REPLAY.md) - Conceptual deep dive
