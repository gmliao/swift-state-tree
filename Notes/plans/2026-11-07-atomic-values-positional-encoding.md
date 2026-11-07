# Atomic values: one declaration, positional encoding

Status: rev 2, review GO, maintainer approved the trade-offs (no wire version, `SyncEngine.init()` removed, look-alike structs per leaf) (2026-11-07; the two implementation notes from the GO are folded in below). rev 1 review: NO-GO, 2 must-fix, 5 should, 1 nit; all folded in, see "Changes in rev 2". Core change (`Sources/`, `Tests/`, `sdk/ts`); implemented through PRs after review GO.

## Problem

Structured leaf values go out on the wire as keyed maps. A `Position2` patch value is `{"v":{"x":…,"y":…}}` and an `Angle` is `{"degrees":…}`, in every encoding. In MessagePack, with int32-sized coordinates, a `Position2` value takes 18 B: two map headers (2 B), the keys "v", "x", "y" (6 B) and two 5-byte integers (10 B). An `Angle` takes 14 B: a map header, the key "degrees" (8 B) and the integer (5 B). So 8 of a Position2's 18 B, and 9 of an Angle's 14 B, are keys and headers. In hero-defense, where every moving player and monster changes its position and rotation each sync, these values are most of a state-update frame.

Three places decide what "atomic" means, each differently, and none of them by declaration:

- `SyncEngine.isAtomicType` (`Sources/SwiftStateTree/Sync/SyncEngine.swift:492-533`) guesses by key shape: `{x,y}` ints, `{x,y,z}` ints, `{degrees}` int, `{v:{x,y}}`. Any user struct of that shape is diffed as one value (`Tests/SwiftStateTreeTests/SyncEngineAtomicTypeTests.swift:125` pins this), and a new math type with another shape is not.
- `TypeToSchemaConverter.isAtomicType` (`Sources/SwiftStateTree/SchemaGen/TypeToSchemaConverter.swift:235-244`) matches type-name substrings, so `Optional<Position2>` matches (intended) and a user type named `Triangle` matches ("Angle").
- The TS SDK rebuilds math types from a hard-coded list of names and keys (`sdk/ts/src/core/view.ts:945-1002`, `:1435-1450`), and decodes `Velocity2`/`Acceleration2` as `Position2` (`:985-986`, `:1146-1147`).

The atomic value itself is still encoded as a keyed map: being atomic only changes the diff (one patch instead of one per leaf), not the value's encoding.

## Decision (from the maintainer)

Fix the encoding with one mechanism, not per-type patches. Measure the hero-defense bytes-per-sync baseline before and after. Path indices and varint integers are out of scope; the remaining cost is explained by analysis.

## Design

### 1. One declaration: `AtomicSnapshotValue`

A protocol in `SwiftStateTree` (Sync):

```swift
/// A value synchronized as one unit: a change replaces the whole value, and wire formats
/// that support it send its leaves positionally, in `atomicLeafPaths` order.
public protocol AtomicSnapshotValue: SnapshotValueConvertible {
    /// The value's leaf paths in wire order, e.g. Position2 → [["v","x"], ["v","y"]].
    static var atomicLeafPaths: [[String]] { get }
}
```

- Adopted by `IVec2`, `IVec3`, `Position2`, `Velocity2`, `Acceleration2`, `Angle` in `SwiftStateTreeDeterministicMath`. The collision types (`ICircle`, `IAABB2`, `IRay`, `ILineSegment`) aren't marked atomic today and aren't used in synced state in this repository; they stay non-atomic (a follow-up can adopt them).
- User types opt in by conforming. `@SnapshotConvertible` gets an `atomic` argument that generates `atomicLeafPaths` from the stored properties in declaration order (a property of another atomic type contributes its leaves, prefixed).
- Leaves are scalars (`Int`, `Double`, `Bool`, `String`) or nested atomic values; optional leaves and collections inside an atomic value are rejected at compile time by the macro and by a precondition in the table builder.

### 2. One table, owned by the state type

`AtomicLayoutTable` (Sync): path pattern → leaf paths, for one state type. Patterns use the same wildcard form as path hashes (`players.*.position`).

- **Built once per state type** by the schema walk (`StateTreeSchemaExtractor`), and cached per `State` type (a lock-protected cache keyed by `ObjectIdentifier(State.self)`). The cache's miss path runs the walk itself, so `SyncEngine(for:)` gets the real table also where no registration ran (unit tests, benchmarks, a standalone engine); there is no empty-table fallback.
- **Checked when built** (rev 1 review, 5): for every atomic type, the leaf paths must equal the leaf paths of the type's schema `properties` (same set, every path ending at a scalar). A hand-written `atomicLeafPaths` that misses, adds or misspells a key fails the build of the table with the type and the difference, at registration, not on the wire.
- **Schema:** `TypeToSchemaConverter` sets `x-stateTree.atomic` from `type is AtomicSnapshotValue.Type` instead of name substrings, and writes `x-stateTree.leafOrder` (the leaf paths) for atomic types.
- **SyncEngine gets the table from its state type, so no engine can be without it** (rev 1 review, 1). `SyncEngine(for: State.self)` becomes the only initializer; `init()` is removed. Every engine therefore diffs with the same table: the adapter's (`TransportAdapter.swift:454`), the replay shadow's (`SyncOutputShadow`, `SyncOutputVerifier.swift:239`), `debugProjection`'s (`TransportAdapter.swift:5292`), and the benchmarks' (`Sources/SwiftStateTreeBenchmarks`). The hot diff entry points (`computeDiff`, `computeBroadcastDiffFromSnapshot`) take snapshots, not a typed state, so the engine has to carry the table from construction. `compareSnapshotValues` treats a path as atomic only when its pattern is in the table. The shape heuristic is deleted.
- **Encoders** receive the same table with the path hasher (`TransportEncodingConfig`), from the adapter's state type.
- **SDK and tools** read `atomic` and `leafOrder` from the schema.

Rejected alternative: a new `SnapshotValue.atomic` case. It would make the value carry its own declaration, but every `switch` over `SnapshotValue`, its `Equatable`/hash and its JSON round trip would need a rule for it, and values decoded from JSON would come back as `.object`.

### 3. Positional encoding, in the encoders only

For a value at an atomic path, the opcode encoders write an array of its leaves in `atomicLeafPaths` order:

| type | keyed today (msgpack, int32 leaves) | positional |
|---|---|---|
| Position2 / Velocity2 / Acceleration2 | `{"v":{"x":x,"y":y}}`, 18 B | `[x, y]`, 11 B |
| IVec2 | `{"x":x,"y":y}`, 15 B | `[x, y]`, 11 B |
| IVec3 | `{"x":…,"y":…,"z":…}`, 22 B | `[x, y, z]`, 16 B |
| Angle | `{"degrees":d}`, 14 B | `[d]`, 6 B |

A one-leaf value stays an array (`[d]`), so the decoder never confuses a positional value with a scalar, and a missing schema entry fails loudly. `null` (an absent `Optional<Position2>`) stays `null`.

- **Nested atomic values** (rev 1 review, 4). The encoder doesn't only look at the patch's own path: when a patch value is an object or array (a firstSync snapshot, a player added with a `Position2` inside, a dictionary entry replaced, an array replaced whole), it recurses and resolves each child's pattern from its parent's (`players.*` → `players.*.position`), encoding every atomic descendant positionally. The table keeps a pattern trie so a child lookup is one step from its parent.
- **The key set is checked again on encode:** when the object's keys don't equal the leaf paths (a value built by hand, a custom `toSnapshotValue`), the encoder throws, and the adapter's existing drop-and-record path for an unencodable patch reports it (`encodeDropScopes`). Nothing is dropped silently.
- **Hook:** `OpcodeMessagePackStateUpdateEncoder.encodePatchWithHashDirect` and `encodePatchLegacyDirect` (the shared `encodeSnapshotValueToMessagePack` gets the table and the current pattern), and `OpcodeJSONStateUpdateEncoder` `OpcodePayloadArray.encodeOperation` and `encodePatchLegacyDirect`. The JSON encoder gets its own value writer instead of `container.encode(SnapshotValue)`.
- **Not touched:** `SnapshotValue.encode(to:)`, `SnapshotValue.hash(into:)`, `StatePatch` contents, and `MessagePackDirectEncoder`. The logical form stays keyed. That is what keeps every state hash and record valid (see Compatibility).
- **Formats:** all opcode-array encodings change, `messagepack` and `opcodeJsonArray`, with or without path hashes, because the SDK decodes them through one decoder (`sdk/ts/src/core/protocol.ts:432-579`). `json` (keyed `StateUpdate` objects) stays keyed: it is the readable, self-describing format and is not used for byte measurements. FirstSync snapshots go through the same encoders and change with them.
- **Switch:** `TransportEncodingConfig.atomicValues: .positional | .keyed`, default `.positional`, for one release, then removed. See Compatibility for how it interacts with the schema hash.

### 4. SDK and tools

- `sdk/ts/src/core/view.ts` `decodeSnapshotValue` looks up the path's schema type **before** the `Array.isArray` branch (`:955-958`) and the primitive branch (`:950`), and it does so **at every nested path**, not only at the patch's own path (rev 1 review, 4): a player object or a firstSync snapshot is walked with the schema, and each atomic descendant is rebuilt.
- For a type with `atomic` and `leafOrder`, an array value of the right length is rebuilt from `leafOrder`. A keyed object is still accepted (an older server, or `.keyed`).
- **The SDK rejects bad values instead of keeping them** (rev 1 review, 7): an array of the wrong length, or with a non-scalar leaf, at an atomic path throws a decode error; so does an array of scalars at a path the schema says is a non-atomic object. The error goes through the existing `decodeErrors` count.
- The math classes are built from the schema's `$ref` name, so `Velocity2`/`Acceleration2` get their own classes (fixes the existing bug).
- Codegen (`sdk/ts/src/codegen/generateDefsFile.ts`) emits `leafOrder` and drops its hard-coded name list.
- `Tools/CLI/src/schema-conformance.ts` checks a positional value against `leafOrder` (length, scalar types) instead of `properties`, also at nested paths; today it would report keys `0` and `1` as "not in schema" and fail E2E.
- Swift decoders used by tests and tools (`StateUpdateDecoder`, `MessagePackDirectDecoder` opcode paths) decode positional values with the same table.
- `Tools/Playground` shows raw patch values; it gets a note, no change.

## Compatibility

- **State hashes: unchanged.** Records hold inputs, per-tick state hashes over the logical `StateSnapshot` JSON (`ReevaluationEngine.swift:373-441`), and sync-output hashes over canonical logical patches (`CanonicalPatchList.swift`, `SyncOutputVerifier.swift`); none holds wire bytes. Pinned by `HeroDefenseStateHashPinTests`.
- **Sync-output hashes: unchanged for every land in this repository, by test** (rev 1 review, 3). They depend on the diff, and the diff now follows the table instead of the shape heuristic. An equivalence test runs both over the state of every land in this repository (Sources, Tests and Examples): for each state, the set of paths the heuristic treats as atomic equals the table's. With that, the replay shadow and the live adapter plan the same patches as before, the sync-output goldens don't change, and no record in this repository needs re-recording. The record version stays.
- **Sync-output hashes for user lands can change.** A land whose state holds a user struct that only looked atomic (shape `{x:Int,y:Int}` and similar) and doesn't adopt the protocol now diffs it per leaf, so its existing records fail sync-output verification. The release note says: adopt `AtomicSnapshotValue` for that type, or re-record. `SyncEngineAtomicTypeTests` is rewritten to pin the declared behaviour.
- **API break:** the public `SyncEngine.init()` is removed in favour of `SyncEngine(for:)`. The release note lists it next to the look-alike structs, so users who build an engine directly don't find it only by a compile error.
- **Replay:** the replay land (`-replay`) sends through a normal adapter, so its clients get the new wire form like any other, and its shadow verifier diffs with the same table (section 2).
- **Old clients:** there is no wire version (deferred to #246, where the `.keyed` switch is meant to grow into the general "previous version supported" mechanism). An old SDK given `[x, y]` silently keeps a plain array. The SDK ships with the server in this repository, so the release note says the SDK must be updated with the server, and links #246.
- **The switch and the schema hash** (rev 1 review, 6). `leafOrder` is part of the schema, so the schema hash changes in both modes. Under `.keyed`, an old client still decodes correctly, but a deployment that enables `expectedSchemaHash` refuses it at join. The release note says so: a mixed deployment that runs `.keyed` for old clients keeps `expectedSchemaHash` off until they are updated. Under `.positional` with `expectedSchemaHash` on, old clients are refused at join instead of misdecoding.
- **Benchmark results:** wire bytes change for every opcode-array run. Numbers before and after are recorded as separate runs, never merged.

## Expected bytes

From the per-value sizes in section 3 (int32-sized leaves): each Position2 value saves 7 B and each Angle 8 B. The frame header, the path hashes, the dynamic-key slots, the operations and the patch array headers don't change, so the saving per frame is 7 B per changed position plus 8 B per changed rotation; for a frame dominated by moving players and monsters that is roughly a third of its size. The measured before and after are step 5; the rest of the frame (path addressing and fixed-width integers) is outside this change.

## Tests (written first, in each PR)

- **Declaration and table:** `SyncEngine(for:)` diffs a declared atomic value as one patch and an undeclared `{x,y}` struct per leaf. Schema: `atomic`/`leafOrder` from conformance; `Triangle` isn't atomic. A type whose `atomicLeafPaths` miss, add or misspell a key fails the table build with the type named.
- **Heuristic equivalence:** for the state of every land in this repository, the heuristic's atomic path set equals the table's (run once in PR 1, before the heuristic is deleted, and kept as a fixed expected list afterwards). The heuristic decides from values, so the states are populated, with at least one entry in every collection (from the tracked records' replayed states, the E2E scenarios, or a fixture per land), and each state's atomic set must be non-empty wherever its type has a math field; an empty collection would make the comparison trivially equal.
- **No registration needed:** in a process where no land was registered, `SyncEngine(for: HeroDefenseState.self)` diffs a Position2 change as one patch.
- **Encoders:** round trip through the Swift decoders for each math type, `Optional` (null and value), arrays of atomic values, **a player added with a Position2 inside it, and a firstSync snapshot**, each on the path-hash and the legacy path, in msgpack and opcode JSON. An object at an atomic path whose keys don't match is reported as unencodable, not sent.
- **Logical form unchanged:** `HeroDefenseStateHashPinTests`, the sync-output goldens and `CanonicalPatchList` hashes stay byte for byte the same.
- **Replay:** reevaluating a hero-defense record with the sync stream (the tracked record `3-hero-defense.json`) gives 0 sync-output mismatches with the shadow (rev 1 review, 1).
- **Bytes regression:** a transport test encodes a fixed hero-defense patch list with fixed coordinates (int32-sized, so the sizes are exact) and asserts the exact frame size, and that a Position2 patch value is 11 B and an Angle 6 B. A GameDemo test runs the 200-sync active workload and asserts the mean bytes per changed leaf stays below a threshold set from the measured value.
- **SDK:** positional decode for every math type, arrays of them, and nested values in a player object and a firstSync; keyed still accepted; Velocity2/Acceleration2 classes; a pathhash frame carrying math values (the gap today); a wrong-length array, a non-scalar leaf and an array at a non-atomic path each throw.
- **CLI:** schema conformance accepts positional values, also nested, and rejects a wrong length.
- **E2E (gate):** `test-e2e-ci.sh` and `test-e2e-game.sh`, all encodings, including `assertConverged` and the reevaluation replay with 0 mismatches.

## Steps

1. **PR 1, declaration, table and diff (no wire change):** the protocol, conformances, macro argument, `AtomicLayoutTable` with its build check, schema `atomic`/`leafOrder` from conformance, `SyncEngine(for:)` everywhere, the equivalence test, then the heuristic removed. Diff benchmark (`DiffBenchmarkRunner`) before and after, release, on the measurement host.
2. **PR 2, positional encoding:** the encoders (with nesting and the key check), the switch, the Swift decoders, the SDK decoder and codegen, CLI conformance, the bytes tests.
3. **Examples and docs (direct to main):** regenerate `Examples/*/schema.json` and generated clients; `docs/transport/README.md` (+ `.zh-TW.md`) describes the positional form, the switch and its schema-hash interaction; release note.
4. **Solutions entry:** "Structured leaf values encoded as keyed maps", with the shape-guessing and name-substring heuristics as the root cause and the declaration rule as prevention.
5. **Before/after measurement:** the hero-defense bytes-per-sync baseline at the commit before PR 2 and at PR 2's merge, same host, same toolchain, both recorded.

## Resolved questions (rev 1 review)

- One table per state type is enough; no land syncs one type under two layouts.
- One-leaf values stay arrays (`[d]`): 1 B more per Angle than a bare int, and the decoder stays unambiguous.
- `atomicValues: .keyed` stays for one release, with its schema-hash interaction documented.

## Changes in rev 2

1. SyncEngine's only initializer is `SyncEngine(for: State.self)`, so the replay shadow, `debugProjection` and benchmarks use the same table; a replay test with 0 sync-output mismatches and the reevaluation E2E join the gate.
2. Neutral wording; the expected bytes come from MessagePack sizes, not from comparisons outside this repository.
3. Heuristic-equivalence test over every in-repo land; release note for look-alike user structs.
4. Nested atomic values in the encoder and the SDK, with test rows for an added player and a firstSync.
5. Leaf paths checked against the schema when the table is built, and the key set on encode.
6. The `.keyed` switch and `expectedSchemaHash` interaction documented.
7. The SDK throws on a wrong-length or misplaced positional array.
8. Fixed int32 coordinates in the size test.
