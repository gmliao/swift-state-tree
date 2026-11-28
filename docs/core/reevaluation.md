[English](reevaluation.md) | [中文版](reevaluation.zh-TW.md)

# Deterministic Re-evaluation

> SwiftStateTree's Re-evaluation capability allows you to record live game sessions and replay them deterministically for debugging, testing, and analysis.

## Overview

Re-evaluation is the ability to **re-execute state transition logic under fixed world conditions**. Unlike traditional replay (which just plays back recorded data), Re-evaluation actually runs the handlers again with the same inputs.

### Key Concepts

| Concept                  | Description                                                    |
| ------------------------ | -------------------------------------------------------------- |
| **Live Mode**            | Normal execution; records inputs and resolver outputs when `enableLiveStateHashRecording` is on (off by default) |
| **Reevaluation Mode**    | Replays recorded inputs, skips resolvers, verifies state hash  |
| **Deterministic Output** | Events and sync requests are queued and flushed at end of tick |

## How It Works

### Recording (Live Mode)

In Live mode, `LandKeeper` records only when `enableLiveStateHashRecording` is `true`; it is `false` by default, and then nothing is recorded. With it on, the keeper records these together:

1. **Actions** - `sequence`, `payload`, `resolverOutputs`, `resolvedAtTick`
2. **Client Events** - `sequence`, `payload`, `resolvedAtTick`
3. **Lifecycle Events** - `OnJoin`, `OnLeave`, `OnInitialize` with resolver outputs, and a forced shutdown (`"shutdown"`)
4. **Server Events** - Events emitted via `ctx.emitEvent()`
5. **State Hash** - A per-tick hash for verification

```swift
// Recording is on only with enableLiveStateHashRecording
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .live,
    enableLiveStateHashRecording: true  // Record inputs, server events and per-tick hashes
)
```

### Replay (Reevaluation Mode)

In Reevaluation mode, `LandKeeper`:

1. Loads recorded inputs from `ReevaluationSource`
2. Skips resolver execution, uses recorded `resolverOutputs`
3. Executes handlers with same inputs
4. Compares state hash after each tick

A keeper built by hand for replay takes the record's land ID and RNG seed, as below; without them both default to the land type. `ReevaluationEngine.run` and `ConcreteReevaluationRunner` do this for you. The keeper reads only the registered service's seed: it starts the land's generator from it and removes the service from the contexts it builds, so handlers draw through `ctx.random` and resolvers don't reach it.

Inputs are recorded before their handler runs, so an input whose `validate` throws is in the record too, in order, and is listed as rejected ([Rejected Inputs](#rejected-inputs-35)). Replay runs its `validate` again, which must therefore be deterministic, and checks that it refuses the same inputs.

> **Tickless lands.** A land without a tick handler records all its inputs under tick 0, and replay applies them there in order (#167, #268), so its server events are compared. From record format 3.1 its frame also records each live pass: the sequence counter before the pass and the inputs it applied, in order (`passes`). Replay runs each pass as an input turn after restoring its counter, so inputs apply in the live order even when one overtook another (an action waiting for its resolvers, #325) and the event sequence numbers match live (#321); the verdict is `passed` or `failed`. Passes that don't name every input of the frame exactly once, that name a sequence that isn't an input of the frame, or whose counters decrease, fail the tick: no input of the tick after the mismatch is found is applied (the check runs before any pass, so a record that fails it applies none). The hosted replay (`ReevaluationStepResult.recordedPassMismatch`) reports such a tick as not matching, and the replay land doesn't fall back to its recorded events. A 3.0 or 2.x tickless record has no passes: replay applies its inputs in sequence order, and the verdict is `passedIgnoringSequence` for that tick: types, payloads, targets and order are compared, but the numbers aren't. A tickless land records no per-tick state hash, so only its events are verified. An empty recorded list is compared too: a replay that emits events where the live run emitted none fails. A 2.5 or 2.6 record kept only the last list of server events recorded in a tick, so an old tickless record in which several passes emitted events fails replay; re-record it with the current server.

```swift
let source = try JSONReevaluationSource(filePath: "recording.jsonl")
let metadata = try await source.getMetadata()
var services = LandServices()
services.register(DeterministicRngService(seed: metadata.replayRngSeed), as: DeterministicRngService.self)
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .reevaluation,
    reevaluationSource: source,
    services: services,
    landID: metadata.landID
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
| `ReevaluationTickFrame`  | `tickId`, `stateHash`, `actions`, `clientEvents`, `lifecycleEvents`, `serverEvents`, optional `sequenceBeforeInputs` / `sequenceBeforeTickHandler`, optional `landFailure` (3.4), optional `rejected` (3.5) |
| `ReevaluationRecordedPass` | `sequenceBefore`, `inputs` (sequences in apply order), optional `ordinal` (3.4), optional `rejected` (3.5); in a tickless frame's optional `passes` (3.1) |
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

The per-tick `stateHash` is a deterministic FNV-1a64 hash of the sorted-keys JSON of the full server state (`fullStateSnapshot()`, record format 2.4 and later): every `@Sync` field at every depth, whatever its policy. Server-only, per-player and masked fields are hashed with their real values, and nested state nodes contribute all their `@Sync` fields too, also when they sit inside a `@SnapshotConvertible` value (its generated `toFullSnapshotValue()`) or an enum payload. A value with only a hand-written `toSnapshotValue()` (for example the DeterministicMath types) is hashed as that conversion gives it. `@Internal` properties are not hashed: their documented use is values such as a wall-clock timestamp, which would make every replay mismatch; an internal that influences state shows up in `@Sync` fields anyway. When live and replay produce the same hash for every tick, the state transition logic is deterministic. Server events are derived from the same handlers and inputs; recording them allows an additional consistency check. This holds for the same program build: a record is guaranteed to replay to the same hashes only with the build that recorded it, since a build whose handlers or their dependencies differ can compute different state from the same inputs.

The hash is never sent to clients and no sync path computes it: client output is unchanged by it. Map keys become strings as for clients (two keys of one map that become the same string make the hash unavailable), and set elements are ordered by their canonical encoding, so insertion order never reaches the hash.

### Oldest Readable Record (2.5)

Record format 2.5 (#154) writes `PlayerID`, `ClientID`, `SessionID` and `LandID` as strings, and a dictionary keyed by one as an object keyed by the string, the shape every encoder now sends. A state holding a `ClientID`, `SessionID` or `LandID` therefore hashes differently from 2.4 (`PlayerID` was already a string there). Older records hold them as objects (`{"rawValue": ...}`), which no longer decode, and they are not converted: a reader rejects any record older than 2.5 as unsupported before replaying it (`ReevaluationRecordVersionError.unsupported`). `ReevaluationRunner --verify` prints "unsupported record version ...; re-record with the current server" and exits 10 (not comparable, never a mismatch), and the admin replay start route answers 409 `RECORD_VERSION_UNSUPPORTED`. Re-record such sessions with the current server. The sections below on older formats describe how those records were verified.

### Masked Fields Under a Broadcast Parent (2.6)

Record format 2.6 (#179) marks a change in what clients receive: a `.masked` field below a `.broadcast` field is now sent, masked, in broadcast snapshots and diffs; before, it was left out. The state hash is unchanged, so 2.5 records are still read and verified. A 2.5 record of a state with that shape (a state node with a `.masked` field, held at any depth by a `.broadcast` field) replays with sync-output mismatches (exit 8), which are not marked as not comparable: re-record such sessions with the current server. None of the example lands has the shape.

### Tickless Passes (3.1)

Record format 3.1 (#325, #321) adds the optional `passes` of a tickless land's frame, described under How It Works. The field is additive: a 3.1 reader reads 3.0 records, which replay as before. A 3.0 build reading a 3.1 record ignores the field and replays a tickless land in sequence order, as it always did. Tick lands record no passes, so their frames are unchanged.

### Server Inputs (3.2)

Record format 3.2 (#387) adds a frame's optional `serverInputs`: the inputs a land's server code submitted (`submitServerInput`, applied by `HandleServerInput`), in the record form the handlers received. They share the `sequence` counter with the other inputs, and a tickless land's passes list them like the others. Replay applies them from the record, so a replaying land takes no server inputs of its own. A 3.1 record has none and replays as before.

A forced shutdown (`LandKeeper.forceShutdown()`, #382) is recorded in 3.2 too, as a lifecycle event of kind `"shutdown"` with no player. It is the keeper turn that clears the players still in the land (without OnLeave), drops the inputs not yet applied and closes intake. On a tickless land it is an input of its pass, after the inputs queued before it. On a tick land it is a frame of its own after the last tick, with that tick's state hash: the turn runs no tick handler and changes no state. Replay applies it as the end of the replay: no input after it is applied and no tick after it runs, but the replay land's viewers stay and it stays open until its own empty-room destroy. A lifecycle event kind the replaying build doesn't know fails that tick (`recordedPassMismatches`) instead of being replayed as something else.

A reader from 3.2 on refuses a 3.x record whose minor is newer than its own, naming both versions (`ReevaluationRecordLogError.newerMinor`, `ReevaluationRecordVersion.isReadable`): replay it with a build at least as new as the one that recorded it. A 3.1 build predates that check: it reads a 3.2 record and replays it without its server inputs, so it can't match the live run where they were applied. Replay 3.2 records with 3.2 or later.

### NFC Keys and Player IDs (3.3)

From record format 3.3 (#446), map keys and `PlayerID`s are in Unicode normalization form C wherever the state is converted: on the wire, in the state hash and in the sync-output hashes. The file's shape does not change. Text that is NFC already, which includes all ASCII, converts as before, so a 3.2 record of such a run replays with the same hashes.

A record older than 3.3 that holds a string or a key in another form (NFD, for example) can hash differently on replay, because this build reads its IDs and writes its keys in NFC. The reader checks the record's text while it loads it (`ReevaluationSource.getHoldsNonNFCText()`); for such a record a state hash mismatch is reported as not comparable (`RunResult.hashIncomparability`), not as a failure. The sync-output digests hash path strings and values, which hold the same keys, so a sync-output mismatch in such a record is reported as skipped with that reason. A record that matches is verified as usual. Re-record the run with the current server to verify it. A 3.2 build refuses a 3.3 record (a newer minor).

### Pass Ordinals and the Land Failure (3.4)

Record format 3.4 (#563, #535) adds three optional keys. A tickless land numbers its passes from 1 (`ReevaluationRecordedPass.ordinal`), and each sync output and sync marker records the pass it read after (`afterPass`; 0 is before any pass). The number is taken in the turn segment that applies the pass, before the sync phase reads, so a seed committed outside a turn (a joiner's standalone firstSync) names the pass whose state it read. A read sequence can't place an output: an output of a pass that emitted no event reads at the sequence its own pass started at, so the same value stands for before and after that pass. Replay checks that the ordinals continue its own count with no gap (a mismatch fails the tick, as other pass mismatches do), and locates each tickless output and seed by its `afterPass`, so a tickless land's sync outputs are verified. A tickless record older than 3.4 has no ordinals: its sync-output verdict is `skipped`, with the reason. Tick lands locate outputs by tick, as before.

A land that ends on a failure (#535) records it in the frame of its tick (`ReevaluationTickFrame.landFailure`, a `LandFailure`: kind, field, detail, and the position: tick, pass, sequence and stage). It is recorded once, in the same turn segment that ends the land. The sync stream ends there: nothing after the failure is recorded in it, neither a sync output nor a seed or a clear, including the clears of the sessions the failure's teardown closes and a firstSync whose state read the failure overtook. The failing turn's entries from before it are kept. A failure a transport reported is applied as an input and ends its turn's batch there; its position says so (`LandFailurePosition.endsInputs`), and replay ends that tick the same way: no tick handler, none of the turn's events (on a tickless land, none of that pass's events). A tick land that fails before its first tick records the failure in frame 0 the same way, wherever it failed: no tick ran live, so replay runs no tick handler either (#901). Replay stops at that tick, as the live run did, and reports the failure (`RunResult.liveFailure`, `ReevaluationSource.getLandFailure()`); what came before it is verified as usual. A 3.3 build refuses a 3.4 record (a newer minor).

### Rejected Inputs (3.5)

Record format 3.5 (#586) lists the inputs whose `validate` threw as `rejected`: on `ReevaluationRecordedPass.rejected` for a tickless land, on `ReevaluationTickFrame.rejected` for a tick land, omitted when empty. From 3.5 a missing list means nothing was rejected. Replay runs `validate` again, so it must be deterministic ([Land DSL: What the Compiler Can't Stop](land-dsl.md#what-the-compiler-cant-stop)). Replay compares the sequences it refuses with the recorded ones and reports a difference as a pass mismatch for that tick: "input <seq> was rejected live and applied in replay", or "applied live and rejected in replay". A malformed list, one that names a sequence that isn't an input of its pass or tick or names one twice, is a mismatch too. A 3.4 record has no lists; a 3.5 build replayed it without the comparison, and from 3.6 replay refuses it (below). A 3.4 build refuses a 3.5 record (a newer minor).

### Schema Fingerprint (3.6)

Record format 3.6 (#521) records the land's schema fingerprint (`ReevaluationRecordMetadata.schemaFingerprint`): 16 hex digits hashing what the record's payloads and snapshots are decoded against. It covers the state tree (fields, types, sync policies, and whether a field has a default), the actions and which response each returns, the client and server events, the server inputs, a `Set`'s element type and the raw values of a `CaseIterable` raw-value enum. It doesn't cover behavior (handlers, tick logic, the tick interval, services, configuration) or a default's value, which a macro computes when the process runs (`UUID()`, `Date()`). `ReevaluationEngine.run` and the monitor's runner check those by comparing the state hash per tick. A payload field's default isn't part of the shape: a synthesized `Decodable` reads a `var`'s key either way. It is strict: an added action, event or field changes it too. Documentation, field order and a property renamed under the same wire key don't (`ReevaluationSchemaFingerprint.compute(for:)`).

What it doesn't see: a field of a type read through the `Codable` sample fallback, or of a `@Payload` type whose `CodingKeys` are declared in an extension or that has its own `encode(to:)`, is named by its Swift property name. There a property rename changes the fingerprint, and a change to the wire key alone isn't seen. The cases of a raw-value enum that isn't `CaseIterable` aren't seen either. Nor is a `let` with an initial value in a `@Payload` type: a synthesized `Decodable` doesn't decode it, so the action replays with the initializer, not the recorded value, and a changed initializer changes what a record replays as (#611).

Replay refuses a record before its first step when the fingerprint is missing or differs from the current definition's (`ReevaluationSchemaFingerprint.checkRecord`), at every entry point except a directly built `LandKeeper(mode: .reevaluation, reevaluationSource:)`:

- `ReevaluationEngine.run` throws `ReevaluationRecordFingerprintError`.
- The monitor's runner reports `ReevaluationReplayCompatibilityError` code 2004 (`RECORD_SCHEMA_FINGERPRINT_MISMATCH`) or 2005 (`RECORD_SCHEMA_FINGERPRINT_MISSING`).
- The admin replay start answers 409 with the same code strings and the values (recorded and current fingerprints, or the recorded and minimum versions). It also refuses any record, with 409 `RECORD_SCHEMA_FINGERPRINT_UNAVAILABLE` (details `landType` and `reason`), when the land type has no fingerprint to compare with: its land server reports none (the protocol's default) or isn't registered, or its definition has a type the fingerprint can't list.
- `ReevaluationRunner --verify` exits 10 for a record without a fingerprint and 13 for one of another schema.

Every record before 3.6 has no fingerprint, so replay refuses it (`ReevaluationRecordVersion.minimumReplayable`); readers that don't replay still read records from 2.5 on (`minimumSupported`). Re-record such a run with the current server.

The fingerprint must list every field. A land that records (`enableLiveStateHashRecording`) or is registered for reevaluation is refused at registration when it can't: a payload or server input without `@Payload` that has fields, or a nested value no sample of which can be built (required fields, no `@SnapshotConvertible`), named in `LandRegistrationError.schemaFingerprint` (`SchemaFingerprintError.unbuildableType`). So is a `@Payload` type with two fields under one wire key (`.wireKeyCollision`), and a `Set` whose element can't be listed. Field-less types, collections, raw-value types, Foundation scalars, values with their own snapshot conversion and `AnyCodable` are hashed as they are. The fingerprint is computed once per definition value and cached on it, off the tick path: at registration for a host that serves one value to every land (`NIOLandHost`), and at land creation, when recording, for a `LandManager` factory that builds a definition per land (the admin start's check calls the factory too).

### Server Events in Replay

The replay land shows each recorded server event typed (#521, #538). The runner resolves every tick before it queues it: each recorded event, and each event the replay emitted, is looked up by name in the base land's registry, and its payload is decoded with the record's own codec (`CanonicalMessagePack`, the one the recorder wrote with). A `Date` is read from its ISO string, `Data` and `URL` from their own `Codable` forms. A saved record decodes strictly. The JSON view lost the float/integer split, so there an integer decodes into `Double` or `Float` when it converts exactly. The replay land registers its base land's server events and emits each event with `emitEvent`.

Inside the record's domain the re-emitted event encodes to the live frame's bytes: `Bool`, `String`, integers from `Int.min` to `Int.max`, a `Date` at a whole second, finite `Float` and `Double` values, `Data`, `URL`, optionals, arrays and string-keyed maps of these, and nested `@Payload` types. Outside it:

- a `Date` with a fractional second: the record keeps whole seconds, so it replays truncated toward negative infinity;
- an unsigned value above `Int.max`: a saved record holding one can't be read (#628); on the JSON view the value is a `Double` and fails the decode;
- `-0.0` on the JSON view reads back as `+0.0` (a saved record keeps it);
- a map with two keys that are canonically equivalent (an NFC and an NFD spelling of one text): the record's encoder refuses it as a duplicate key, and a record that holds one can't be read (#805).

A tick that doesn't resolve fails the replay run with `ReevaluationReplayResolutionError`. The error names the tick, the event's origin (recorded or replayed), its sequence and name, and the cause. These ticks don't resolve: a server event whose name isn't registered, whose payload doesn't decode, or whose recorded target isn't one a live run writes (an unknown kind, a player, client or session target without exactly one ID, or an `all` target with IDs; #641), a record read error, a state snapshot that doesn't encode, and a state that can't be rebuilt from it. The run reaches `failed` in the admin status. The ticks before it stay queued and are shown; the replay land stays up and is sent nothing after them.

A record that a live run can't have written is refused when it is opened, before the run's first tick: one with two frames for the same tick, with a tick outside `0 ..< Int64.max`, with an output sequence outside `0 ..< Int64.max` (the initialize record's, a sequence watermark, or a pass's `sequenceBefore`), or with an `afterPass` below 0 on a sync output or seed marker (`ReevaluationRecordContentError`, #639, #640, #729). A live run can't write these. A record that stays inside these ranges can still run a replay out of numbers: a replay on a re-evaluation keeper takes its output sequences with a checked add, and when the land emits more events than the record's counter leaves room for, the run ends with `ReevaluationRecordContentError.sequenceExhausted` instead of trapping. The run reaches `failed`, its error names the value or the cause, and the server goes on. The checks are on the record as it is assembled: the 3.x source checks each assembled frame, after the reader has merged and trimmed the turn's records, and the JSON source checks the frames as written. The standalone engine (`ReevaluationEngine.run`) and the hosted runner's OnInitialize check also report a recorded event target a live run doesn't write as that error, not as a mismatch with the replayed event. A custom runner that reports `Int64.max` as its last tick fails its run the same way, before its first step.

A replay steps every tick from 0 to the record's last tick, the ticks without a frame included, so its length is the last tick + 1, not the number of frames. The bound counts these outer steps (ticks); it doesn't cap the work inside a step, so a tickless land, which records its passes in few frames, isn't capped by how many passes a tick holds. A record's size is bounded separately, when it is read. A record whose last tick + 1 is past a limit is refused when it is opened, before the run's first step, with `ReevaluationRecordContentError.replayTooLong(lastTick:limit:)` (#728); a record with frames at tick 0 and tick 10^12 would otherwise never finish. The default limit is `ReevaluationRecordFile.defaultMaxReplayTicks`, 1,000,000 ticks, about 13.9 hours at 50 ms ticks. It covers a session with a wide margin, but a land kept alive for days records every tick, so a valid long-lived record can pass it: a host with such lands raises the limit. Every way of opening a record takes `maxReplayTicks:` (`JSONReevaluationSource`, `ReevaluationRecordLogSource`, `ReevaluationRecordFile.openSource`, `ReevaluationEngine.run`, `ConcreteReevaluationRunner`), and each public entry point stops the process for a limit below 1. `ReevaluationRunnerService(factory:maxReplayTicks:)` fails a run whose runner reports a longer one before its first step, whatever runner the factory made, and fails a run that takes more steps than the limit even when its runner reported fewer; the step count can only be checked after a step, so such a runner runs at most one step past the limit, and the failure message says the runner produced more than the limit's number of results (a count of steps, not a record tick). A runner that opens a record file applies its own limit when it opens it, so a host that allows longer records raises both. The admin replay start (`/admin/reevaluation/start` and `/admin/reevaluation/replay/start`) checks a record against `ReevaluationFeatureConfiguration.maxReplayTicks`, which a host sets to the same value as its service's, and refuses a longer one with a 400 that names the last tick and the limit; it is the limit `NIOLandHost.registerWithGenericReplay` records for the land type, and a mismatch with the service's is safe (the admin start refuses early, or the run fails with `replayTooLong`). Two details follow from how a host registers its lands. The reevaluation monitor land is registered once, by the first `registerWithGenericReplay` call with re-evaluation enabled (a disabled call registers no monitor), with that call's service and limit, while `/admin/reevaluation/start` checks a record against the limit of the land type in the request: with lands at different limits, a record accepted for the higher one can still fail in the monitor, with `phase == .failed` and the `replayTooLong` description in `errorMessage` (reported, not silent), so lands that share a monitor should share a limit when the monitor route needs to honor it. And `NIOAdminRoutes` takes a snapshot of the per-type limits when `registerAdminRoutes()` runs (`NIOLandHost.run` does so after the registrations): a land registered with `registerWithGenericReplay` after that keeps the default limit for the admin start. The `ReevaluationRunner` command-line tools of the Demo and GameDemo examples take `--max-replay-ticks <n>`. The in-memory `JSONReevaluationSource(metadata:frames:)`, and a `LandKeeper` built directly in `.reevaluation` mode with a custom `ReevaluationSource`, are not bounded: both are host code, so a host that passes externally supplied frames reads them with a checked source such as `ReevaluationRecordFile.openSource`.

A run that feeds a replay land also fails on a result the land can't show: one without a frame (`unresolvedResult`, a custom runner that didn't call `ReevaluationReplayFrame.resolve`), a frame of another state type (`stateTypeMismatch`), or a frame without a state (`stateUnavailable`). A tick whose state hash can't be computed (§ Unavailable State Hashes) has no state, so its reason is the hash error. A run that feeds no replay land, the monitor's verification, reports such a tick as unverifiable and goes on. `registerWithGenericReplay` refuses these results before they are queued. A land built with `GenericReplayLand.makeLand` alone checks each result as it reads it and fails the run, so a result is never dropped silently.

A land whose records will replay is refused at registration when one of its server event types has no decoder (`LandRegistrationError.serverEventsWithoutDecoder`). Every type the DSL registers has one. This check runs in the stock runner's init and the engine, after the record's checks. A custom runner (`ReevaluationTargetFactory`) skips it and meets the same case in `resolve`.

Each step of the stock runner rebuilds the state and decodes every server event of the tick, for the monitor's verification too: a monitor run costs one state rebuild and the event decodes per tick.

### Resolver Outputs in Replay

A replayed handler receives a recorded resolver output (its `productInfo` parameter) the way the replay land reads a recorded server event: with the record's own codec (#707). This holds for an action's resolvers, `OnJoin` and `OnLeave`, and `OnInitialize`. A `Date`, `Data`, `URL` or `Decimal` field reads back as the live handler saw it, a `Decimal` NaN included. A saved record decodes strictly. On the JSON view an integer decodes into `Double` or `Float` when it converts exactly. The domain limits above apply too: a `Date` with a fractional second replays truncated. An output that doesn't decode into the requested type reads as `nil`, and the land's logger records a warning that names the output, the recorded and requested types, and the error.

Limit: a recorded action's own payload is still decoded with a JSON round trip, so replay drops an action whose payload has a `Date`, `Data` or `URL` field (#709).

### OnInitialize in Replay

Replay runs OnInitialize again with its recorded resolver outputs: a body that doesn't throw, or `validate` and then `apply` (#593). The record holds an initialize entry only when the live `validate` passed, because a live refusal ends the land before anything is recorded. So a replayed `validate` that throws means `validate` was not deterministic: it read something other than the state and the context, such as a clock or a mutable global.

Replay then writes nothing, as the live run would, and the initialize check fails, with a reason that names OnInitialize and the error (`InitializeVerification.failed`). This holds for a record without an initialize record too, whose OnInitialize replays inside tick 0. The replay goes on, so the later state hashes report what follows.

A hosted replay (the reevaluation monitor and the replay land) fails its run when the initialize check fails, even when every tick hash matches. A refused initialization can leave the tick hashes equal, for example when `apply` writes nothing, or only what a later tick overwrites. The run's error message names OnInitialize and the error. Only `.failed` fails the run: a check that is `.unverifiable` or `.notComparable` lets it complete. A custom runner reports its check through `ReevaluationRunnerProtocol.initializeVerification()`, which has no default. A runner that doesn't check OnInitialize returns `.notRecorded`, which never fails a run, and a wrapper around another runner forwards that runner's answer.

### Which Hash a Record Holds

| Record format | State and initialize hash | Verified against |
|---|---|---|
| 2.4 and later | full state (`ReevaluationHashDefinition.fullState`) | the full state, exactly |
| 2.3 | broadcast view, `snapshot(for: nil)` | the broadcast view, exactly |
| older than 2.3 | broadcast view, before #175 | the broadcast view, with the #175 rule below |

The reader picks the definition from the record's version (`ReevaluationRecordVersion.hashDefinition`), and `RunResult.hashDefinition` reports it, so older records verify as before and nothing is excused wholesale. Sync-output hashes hash what clients receive and are unchanged by 2.4.

### Unavailable State Hashes

If the state cannot be converted for the hash (a map whose keys collide as strings, a value of an unsupported type, a NaN or infinite floating-point value, which JSON cannot encode), the live tick is not stopped: its hash is recorded as `unavailable: <reason>`, the keeper logs an error and counts it (`LandKeeper.stateHashUnavailableCount`). Replay reports such a tick as unverifiable, never as a match (`RunResult.unverifiableStateHashes`; older builds recorded `"error"`, which is treated the same way), and the initialize check reports `unverifiable`. A replay land has no state to show for such a tick, so a run that feeds one fails there (`stateUnavailable`, with the hash error; § Server Events in Replay). A valid recorded hash that the replay cannot compute is a divergence, reported as a mismatch. `ReevaluationRunner --verify` exits with code 11 for unverifiable hashes only after every definite failure: a state hash mismatch (5), server events (6), sync outputs (8) and OnInitialize (9) take precedence.

Unsigned integers above `Int.max` (`UInt`, `UInt64`) convert to their decimal digits as a string, on every path: before, they trapped. Values that fit in `Int` are unchanged on the wire.

### Records Older Than 2.3 (#175)

Before record format 2.3, a `@SnapshotConvertible` state node inside a `[String: X]` or `[PlayerID: X]` map was converted with every field, server-only ones included (Hero Defense's `players.*.lastFireTick`). Its state hash, its initialize hash and its sync-output hashes covered those fields. This build leaves them out, so such a record no longer reproduces its hashes.

Hashes are still compared for every record. Whether a land is affected is decided from its state type, not from the recording (`ReevaluationRecordVersion.hashChangedByNestedNodePolicies`): a `@SnapshotConvertible` state node as the value of a `[String: X]` or `[PlayerID: X]` map, at any depth, reached through `.broadcast` fields only, since the hash covers the broadcast view. Hero Defense is affected; visibility-test is not (its `entities` map is `.perPlayer`). When a record older than 2.3 of an affected land has a differing state or initialize hash, the reader reports it as not comparable ("recorded before #175, hash not comparable"), not as a replay difference: `RunResult.hashIncomparability` carries the reason, the initialize check reports `notComparable`, and `ReevaluationRunner --verify` exits with code 10. Re-record such sessions with a current build. Every other mismatch is a failure as before: any mismatch of an unaffected land, whatever its record version, and every sync-output failure (exit 8). Two consequences, both on the safe side: a pre-2.3 visibility-test record verifies its state hash but fails its sync outputs (exit 8), since its per-player patches changed; and a map inside a non-node `@SnapshotConvertible` value is not detected, so such a land's mismatch fails (exit 5). A 2.3 record of any land, and any 2.4 record, is compared exactly.

### Server Event Verification

When `enableLiveStateHashRecording: true`, the server also records server events (`ctx.emitEvent()`) per tick. During reevaluation with `--verify`, the runner compares recorded vs emitted server events. A mismatch indicates non-determinism in event emission (e.g., ordering or payload differences).

A recorded payload is in the record's form, and an emitted one is the replay's typed value, so the verifier puts the emitted payload in the record's form first (`CanonicalMessagePack`, as the recorder writes it) and then compares the two (#633). A `Date`, `Data`, `URL` or `Float` field matches on both record forms; a `Date` with a fractional second matches too, since the record keeps whole seconds on both sides. Limit: the JSON view has lost the sign of `-0.0` ([Server Events in Replay](#server-events-in-replay)), so on the JSON view a `-0.0` in an event payload reports its tick; a saved record matches.

Actions, client events, lifecycle events and server events share one `sequence` counter. Live ticks of a ticked land record two watermarks of that counter on the tick frame (`sequenceBeforeInputs`, `sequenceBeforeTickHandler`), and reevaluation moves the counter forward to them, so replayed server events get the recorded `sequence` values. From record format 3.1, a tickless land's frame with recorded passes counts as watermarked too (`watermarkedTicks`): replay restores the counter before each pass. The comparison is decided per tick: a tick whose frame has watermarks must match exactly, including `sequence`, and is compared even when its recorded list is empty, so an extra replay event is reported. Ticks from older records without watermarks keep the previous rule: they are compared only when events were recorded, and a difference in `sequence` alone is reported as a warning, not a failure (`ReevaluationEngine.RunResult.serverEventVerification`).

### Sync-Output Verification

Each committed sync plan records, per scope (the broadcast scope and each player's), a hash of its canonical patch list, plus the events that rode with it. Encoded bytes are not compared: dynamic-key slots, frame order and the wire encoding are not canonical. Replay re-plans every recorded sync output with a shadow sync engine fed the replay state, and compares the hashes (`ReevaluationRunner --verify` exits with code 8 on a mismatch). A tick land's output is compared with the state of the tick it read; a tickless land's, from 3.4, with the state after the pass it read after (see Pass Ordinals and the Land Failure). Replay checks what the server produced: a player an output didn't address is listed in its `perPlayerUnverified` and is neither compared nor staged there. That includes a player all of whose sessions sync lag has paused (`resyncPending`) in that round; the pause ends in a resync's clear and seed, or in a leave's clear (#572). Each scope left out this way counts in the result's `perPlayer.unverifiable`, so a record with a pause reads `partial`: the count shows where coverage dropped instead of skipping it silently. Records made before the fix for #572 hold no such entry and still report a mismatch for a pause. On a tickless land a leave's own turn syncs before the player's clear, after the player's sessions ended, so that output lists the departed player and a record with such a leave reads `partial`.

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
