# Atomic values: one declaration, positional encoding

Status: rev 1, for review. Core change (`Sources/`, `Tests/`, `sdk/ts`); implemented through PRs after review GO.

## Problem

Structured leaf values go out on the wire as keyed maps. A `Position2` patch value is `{"v":{"x":…,"y":…}}` and an `Angle` is `{"degrees":…}`, in every encoding. In a hero-defense `messagepack-pathhash` frame (1 room, 5 moving players, 10 frames around sync 100), 476 B per frame break down as:

| component | B/frame | share |
|---|---:|---:|
| Position2 values | 200.4 | 42.1 % |
| Angle values | 92.8 | 19.5 % |
| path hash | 109.5 | 23.0 % |
| patch array header, slot, op | 65.7 | 13.8 % |
| scalar values | 0.9 | 0.2 % |
| frame header | 7.0 | 1.5 % |

Of the 294 B of values, 137.6 B are key strings ("v", "x", "y", "degrees") and 34.2 B are map headers; 122.3 B are the numbers.

Three places decide what "atomic" means, each differently, and none of them by declaration:

- `SyncEngine.isAtomicType` (`Sources/SwiftStateTree/Sync/SyncEngine.swift:492-533`) guesses by key shape: `{x,y}` ints, `{x,y,z}` ints, `{degrees}` int, `{v:{x,y}}`. Any user struct of that shape is diffed as one value (`Tests/SwiftStateTreeTests/SyncEngineAtomicTypeTests.swift:125` pins this), and a new math type with another shape is not.
- `TypeToSchemaConverter.isAtomicType` (`Sources/SwiftStateTree/SchemaGen/TypeToSchemaConverter.swift:235-244`) matches type-name substrings, so `Optional<Position2>` matches (intended) and a user type named `Triangle` matches ("Angle").
- The TS SDK rebuilds math types from a hard-coded list of names and keys (`sdk/ts/src/core/view.ts:945-1002`, `:1435-1450`), and decodes `Velocity2`/`Acceleration2` as `Position2` (`:985-986`, `:1146-1147`).

The atomic value itself is still encoded as a keyed map: being atomic only changes the diff (one patch instead of one per leaf), not the value's encoding.

## Decision (from the maintainer)

Fix the encoding with one mechanism, not per-type patches. Report the R5-4(a) baseline before and after. Path indices and varint integers are out of scope; the remaining gap is explained by analysis.

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
- User types opt in by conforming. `@SnapshotConvertible` gets an `atomic` argument that generates `atomicLeafPaths` from the stored properties in declaration order (types that nest another atomic type flatten its leaves).
- Leaves are scalars (`Int`, `Double`, `Bool`, `String`) or nested atomic values; optional leaves and collections inside an atomic value are rejected at compile time by the macro and by a precondition in the table builder.

### 2. One table, built from the declaration

`AtomicLayoutTable` (Sync): path pattern → leaf paths, for one land's state type. Patterns use the same wildcard form as path hashes (`players.*.position`).

- Built once per state type, by the schema walk that already runs at registration (`StateTreeSchemaExtractor`, `LandTypeRegistry`), cached per `State` type.
- `TypeToSchemaConverter` sets `x-stateTree.atomic` from `type is AtomicSnapshotValue.Type` instead of name substrings, and writes `x-stateTree.leafOrder` (the leaf paths) for atomic types. `schemaHash` changes once, with this field.
- Consumers, all reading the same table:
  - **SyncEngine diff:** `TransportAdapter` passes the table to `SyncEngine(atomicLayouts:)`. `compareSnapshotValues` treats a path as atomic only when its pattern is in the table. The shape heuristic is deleted. A `SyncEngine()` without a table (benchmarks, standalone use) treats nothing as atomic: per-leaf patches, no guessing.
  - **Encoders:** the opcode encoders receive the table with the path hasher and look up the patch's path pattern (the hash already identifies it).
  - **SDK and tools:** they read `atomic` and `leafOrder` from the schema.

Rejected alternative: a new `SnapshotValue.atomic` case. It would make the value carry its own declaration, but every `switch` over `SnapshotValue`, its `Equatable`/hash and its JSON round trip would need a rule for it, and values decoded from JSON would come back as `.object`.

### 3. Positional encoding, in the encoders only

For a patch whose path is atomic, the opcode encoders write the value as an array of its leaves in `atomicLeafPaths` order:

| type | keyed today | positional |
|---|---|---|
| Position2 / Velocity2 / Acceleration2 | `{"v":{"x":x,"y":y}}` (msgpack ~18 B) | `[x, y]` (~11 B) |
| IVec2 | `{"x":x,"y":y}` | `[x, y]` |
| IVec3 | `{"x":…,"y":…,"z":…}` | `[x, y, z]` |
| Angle | `{"degrees":d}` (~14 B) | `[d]` (~6 B) |

A one-leaf value stays an array (`[d]`), so the decoder never confuses a positional value with a scalar and a missing schema entry fails loudly. `null` (an absent `Optional<Position2>`) stays `null`. An array of atomic values (replaced whole today) encodes each element positionally.

- **Hook:** `OpcodeMessagePackStateUpdateEncoder.encodePatchWithHashDirect` and `encodePatchLegacyDirect` (the shared `encodeSnapshotValueToMessagePack` gets a layout parameter), and `OpcodeJSONStateUpdateEncoder` `OpcodePayloadArray.encodeOperation` and `encodePatchLegacyDirect`, which get their own value encoder instead of `container.encode(SnapshotValue)`.
- **Not touched:** `SnapshotValue.encode(to:)`, `SnapshotValue.hash(into:)`, `StatePatch` contents, and `MessagePackDirectEncoder`. The logical form stays keyed. That is what keeps every state hash, sync-output hash and record valid (see Compatibility).
- **Formats:** all opcode-array encodings change, `messagepack` and `opcodeJsonArray`, with or without path hashes, because the SDK decodes them through one decoder (`sdk/ts/src/core/protocol.ts:432-579`). `json` (keyed `StateUpdate` objects) stays keyed: it is the readable, self-describing format and is not used for byte measurements. Firstsync snapshots go through the same encoders and change with them.
- **Switch:** `TransportEncodingConfig.atomicValues: .positional | .keyed`, default `.positional`, so a deployment with old clients can keep the old wire form for one release. Removed in a later release.

### 4. SDK and tools

- `sdk/ts/src/core/view.ts` `decodeSnapshotValue` looks up the path's schema type **before** the `Array.isArray` branch (`:955-958`) and the primitive branch (`:950`). For a type with `atomic` and `leafOrder`, an array value is rebuilt from `leafOrder`; a keyed object is still accepted (the `.keyed` switch). The math classes are built from the schema's `$ref` name, so `Velocity2`/`Acceleration2` get their own classes (fixes the existing bug).
- Codegen (`sdk/ts/src/codegen/generateDefsFile.ts`) emits `leafOrder` and drops its hard-coded name list.
- `Tools/CLI/src/schema-conformance.ts` checks a positional value against `leafOrder` (length, scalar types) instead of `properties`; today it would report keys `0` and `1` as "not in schema" and fail E2E.
- Swift decoders used by tests and tools (`StateUpdateDecoder`, `MessagePackDirectDecoder` opcode paths) decode positional values with the same table.
- `Tools/Playground` shows raw patch values; it gets a note, no change.

## Compatibility

- **Records and replay: no re-recording, no record-version bump.** Records hold inputs, per-tick state hashes over the logical `StateSnapshot` JSON (`ReevaluationEngine.swift:373-441`), and sync-output hashes over canonical logical patches (`CanonicalPatchList.swift`, `SyncOutputVerifier.swift`); none holds wire bytes. The replay land (`-replay`) sends through a normal adapter, so its clients get the new wire form like any other. Pinned by `HeroDefenseStateHashPinTests` and the sync-output goldens, which must stay unchanged.
- **Diff behaviour changes for user structs that only looked atomic.** A user struct shaped `{x:Int,y:Int}` now produces per-leaf patches unless it adopts `AtomicSnapshotValue`. That is the intended fix; it is listed in the release note, and `SyncEngineAtomicTypeTests` is rewritten to pin the declared behaviour.
- **Old clients:** there is no wire version. An old SDK given `[x, y]` silently keeps a plain array. The SDK ships with the server in this repository, so the release note says the SDK must be updated with the server; `atomicValues: .keyed` covers mixed deployments. The schema hash changes (new `leafOrder`), so a deployment that enables `expectedSchemaHash` rejects old clients at join instead of misdecoding.
- **Benchmarks and paper data:** wire bytes change for every opcode-array run. Numbers before and after are recorded as separate runs, never merged.

## Expected bytes

From the breakdown above: each Position2 value saves about 7 B and each Angle about 8 B (keys and map headers out, one array header in). That is about 161 B of the 476 B frame (−34 %), so about 315 B per frame. Scaled to the 200-sync trace mean (426 B per player per sync), about 280 B: about 1.6× Colyseus (172 B) and 1.9× the Q3-style delta (147 B), instead of 2.5–2.9×. The rest is path addressing (hash, slot, op, patch header: 37 % of the frame) and fixed-width integers, which this change leaves alone. These are estimates; the measurement is step 5.

## Tests (written first, in each PR)

- **Declaration:** `SyncEngine` with a table diffs a declared atomic value as one patch and an undeclared `{x,y}` struct per leaf; without a table, nothing is atomic. Schema: `atomic`/`leafOrder` from conformance; `Triangle` isn't atomic.
- **Encoders:** round trip through the Swift decoders for each math type, `Optional` (null and value), arrays of atomic values, firstsync snapshots, path-hash and legacy paths, msgpack and opcode JSON.
- **Logical form unchanged:** `HeroDefenseStateHashPinTests`, the sync-output goldens and `CanonicalPatchList` hashes stay byte for byte the same.
- **Bytes regression:** a transport test encodes a fixed hero-defense patch list and asserts the exact frame size, and one asserts that a Position2 patch value is at most 11 B in msgpack. A GameDemo test runs the 200-sync active workload and asserts the mean bytes per changed leaf stays below a threshold set from the measured value.
- **SDK:** positional decode for every math type and arrays of them, keyed still accepted, Velocity2/Acceleration2 classes, and a pathhash frame carrying math values (the gap today).
- **CLI:** schema conformance accepts positional values and rejects a wrong length.
- **E2E:** `test-e2e-ci.sh` and `test-e2e-game.sh`, all encodings, including `assertConverged`.

## Steps

1. **PR 1, declaration and diff (no wire change):** the protocol, conformances, macro argument, `AtomicLayoutTable`, schema `atomic`/`leafOrder` from conformance, SyncEngine on the table, heuristic removed. Diff benchmark (`DiffBenchmarkRunner`) before and after, release, on the measurement host.
2. **PR 2, positional encoding:** the encoders, the switch, the Swift decoders, the SDK decoder and codegen, CLI conformance, the bytes tests.
3. **Examples and docs (direct to main):** regenerate `Examples/*/schema.json` and generated clients; `docs/transport/README.md` (+ `.zh-TW.md`) describes the positional form and the switch; release note.
4. **Solutions entry:** "Structured leaf values encoded as keyed maps", with the shape-guessing and name-substring heuristics as the root cause and the declaration rule as prevention.
5. **Before/after measurement:** the R5-4(a) baseline at the commit before PR 2 and at PR 2's merge, same host, same toolchain, both recorded.

## Open questions for review

- Is one table per state type enough, or does any land sync the same type under two atomic layouts? (None found in this repository.)
- `[d]` for one-leaf values costs 1 B per Angle against a bare int. The plan keeps the array for decoder safety; say if bare scalars are preferred.
- `atomicValues: .keyed` for one release, or no switch at all.
