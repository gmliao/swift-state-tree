# Generic Replay Land v2 — POC Design

**Date:** 2026-02-23
**Branch:** `feature/generic-replay-land-v2`
**Status:** Approved for implementation
**Supersedes:** v1 (abandoned), see `generic-replay-land-v2-design.md` for v1 learnings

---

## Core Principle

**Zero changes to `LandKeeper.swift`, `TransportAdapter.swift`, `ReevaluationFeature.swift`.**

All new code lives in:
- `Sources/SwiftStateTree/Sync/` — `SnapshotValueDecodable` protocol and `SnapshotValue` helpers
- `Sources/SwiftStateTreeMacros/` — macro extensions for reverse decode generation
- `Sources/SwiftStateTreeDeterministicMath/` — `+SnapshotDecodable.swift` extensions (new files only)
- `Sources/SwiftStateTreeReevaluationMonitor/` — `GenericReplayLand.swift`, `StateFromSnapshotDecodable.swift`

`ReevaluationFeature.swift` gets one **additive** new overload (`registerWithGenericReplay`);
the existing `registerWithReevaluationSameLand` is not modified.

---

## Problem With v1 JSON Approach

v1 used a double-wrapped JSON path:

```
Record file (JSON)
  └─ stateSnapshot.values = {"health": 100, ...}

ConcreteReevaluationRunner.step()
  └─ actualState = AnyCodable("{\"values\":{\"health\":100,...}}")
                   ↑ already JSON but wrapped as string inside AnyCodable

decodeReplayState(State.self, from: actualState)
  └─ AnyCodable → String → JSONDecoder.decode()
```

Problems:
1. Double-encoding: value is JSON → string → AnyCodable → string → JSON decode
2. Requires manual `+Decodable.swift` per game state type
3. After `JSONDecoder` creates state, `@Sync` property wrappers have `_isDirty = false`
   (init path does not trigger setter), falling through to `.all` broadcast mode

---

## v2 Solution: Macro-Generated Snapshot Decoder

### Protocol Layer

```swift
// SnapshotKeyDecodable — types that can decode from String snapshot keys
public protocol SnapshotKeyDecodable: Hashable {
    init?(snapshotKey: String)
}

// SnapshotValueDecodable — types that can decode from SnapshotValue
public protocol SnapshotValueDecodable {
    init(fromSnapshotValue value: SnapshotValue) throws
}

// StateFromSnapshotDecodable — StateNodeProtocol types with macro-generated init
public protocol StateFromSnapshotDecodable: StateNodeProtocol {
    init(fromBroadcastSnapshot snapshot: StateSnapshot) throws
}
```

### Built-in Conformances

| Type | Protocol | Note |
|------|----------|------|
| `Int`, `Bool`, `String`, `Double` | `SnapshotKeyDecodable` + `SnapshotValueDecodable` | direct extraction |
| `PlayerID` | `SnapshotKeyDecodable` | `init?(snapshotKey:)` wraps String |
| `Array<T: SVD>` | `SnapshotValueDecodable` | maps `.array` case |
| `Optional<T: SVD>` | `SnapshotValueDecodable` | `.null` → `.none` |
| `Dictionary<K: SKD, V: SVD>` | `SnapshotValueDecodable` | conditional conformance, handles all key types |
| `IVec2`, `Position2`, `Angle` | `SnapshotValueDecodable` | new extension files in DeterministicMath |
| `@SnapshotConvertible` struct | `SnapshotValueDecodable` | macro generates `init(fromSnapshotValue:)` |

*(SVD = SnapshotValueDecodable, SKD = SnapshotKeyDecodable)*

### Why Dirty Flags Work

When `@StateNodeBuilder` macro generates `init(fromBroadcastSnapshot:)`:

```swift
init(fromBroadcastSnapshot snapshot: StateSnapshot) throws {
    self.init()  // all _isDirty = false (defaults)
    if let v = snapshot.values["score"] {
        self.score = try _snapshotDecode(v)
        // ↑ uses wrappedValue.set → _isDirty = true automatically
    }
    // ...
}
```

The macro uses property setters (not direct `_field.init`), so `@Sync._isDirty = true` is triggered for every decoded field. This fixes v1 Learning #6 (dirty flags not set after JSONDecoder).

### Dictionary Key Mapping (No Macro-Level Heuristics)

The macro generates uniform code for all dictionary properties:

```swift
if let v = snapshot.values["players"] { self.players = try _snapshotDecode(v) }
if let v = snapshot.values["monsters"] { self.monsters = try _snapshotDecode(v) }
```

Swift's conditional conformance resolves the key mapping:

```swift
// [PlayerID: PlayerState]: SnapshotValueDecodable
// ← Dictionary<PlayerID, PlayerState> where PlayerID: SnapshotKeyDecodable, PlayerState: SnapshotValueDecodable
// ← PlayerID.init?(snapshotKey: "EF198066-...") handles UUID → PlayerID

// [Int: MonsterState]: SnapshotValueDecodable
// ← Int.init?(snapshotKey: "1") handles "1" → 1
```

Compile-time safety: if a key type is not `SnapshotKeyDecodable` or a value type is not
`SnapshotValueDecodable`, the generated code does not compile.

---

## Macro Changes

### `@StateNodeBuilder` — New Generation

Adds `init(fromBroadcastSnapshot:) throws` to the generated conformance.

- Iterates all `@Sync` stored properties (same property collection logic as existing `broadcastSnapshot`)
- For each property: generates `if let v = snapshot.values["<name>"] { self.<name> = try _snapshotDecode(v) }`
- Uses `_snapshotDecode<T: SnapshotValueDecodable>(_ v: SnapshotValue) throws -> T` helper
- Resulting type conforms to `StateFromSnapshotDecodable`

Compile error if any `@Sync` property's value type does not conform to `SnapshotValueDecodable`.

### `@SnapshotConvertible` — Bidirectional Extension

Currently generates only `toSnapshotValue()`. Extended to also generate `init(fromSnapshotValue:)`.

```swift
// Before (v1): only toSnapshotValue()
// After (v2): generates both directions
@SnapshotConvertible
struct PlayerState {
    var name: String
    var hp: Int
}
// Generated: toSnapshotValue() + init(fromSnapshotValue:) + SnapshotValueDecodable conformance
```

---

## GenericReplayLand

```swift
// Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift

public enum GenericReplayLand<State: StateFromSnapshotDecodable> {

    /// Creates a replay LandDefinition that:
    /// 1. Runs in `.live` mode (no LandKeeper changes needed)
    /// 2. Steps a ReevaluationRunner each tick
    /// 3. Decodes the computed StateSnapshot → State via macro-generated init
    /// 4. Broadcasts state diff to connected clients
    public static func makeLand(
        basedOn definition: LandDefinition<State>,
        replayRunnerService: ReevaluationRunnerService
    ) -> LandDefinition<State>
}
```

**Tick handler flow:**

```
runner.step() → ReevaluationStepResult
    ↓
result.actualState (AnyCodable) → decode to StateSnapshot (one JSON decode)
    ↓
State(fromBroadcastSnapshot: snapshot)   ← macro-generated, dirty flags = true
    ↓
self.state = decoded
    ↓
requestSyncBroadcastOnly()  → client receives correct state diff
```

**Registration (additive overload in `ReevaluationFeature.swift`):**

```swift
public extension NIOLandHost {
    /// New overload — does NOT modify registerWithReevaluationSameLand
    func registerWithGenericReplay<State: StateFromSnapshotDecodable>(
        landType: String,
        liveLand: LandDefinition<State>,
        liveInitialState: @autoclosure @escaping @Sendable () -> State,
        liveWebSocketPath: String,
        configuration: NIOLandServerConfiguration,
        reevaluation: ReevaluationFeatureConfiguration
    ) async throws
}
```

---

## POC Unit Tests (Phase 1)

Location: `Tests/SwiftStateTreeMacrosTests/StateNodeBuilderSnapshotDecodeTests.swift`

Test state (no game dependencies):

```swift
@StateNodeBuilder
struct MockReplayState: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var name: String = ""
    @Sync(.broadcast) var tags: [String: Int] = [:]
    @Sync(.broadcast) var active: Bool = false
}
// @StateNodeBuilder generates StateFromSnapshotDecodable conformance automatically
```

Test cases:

1. `init(fromBroadcastSnapshot:)` decodes values correctly
2. Dirty flags are set after decode (all decoded fields should appear in `getDirtyFields()`)
3. `broadcastSnapshot` round-trip (encode → snapshot → decode → encode → same snapshot)
4. Missing fields in snapshot keep default values
5. `[String: Int]` dictionary with string keys decoded correctly
6. Compile-time error: `@Sync` property with non-SnapshotValueDecodable type → build fails

---

## Files to Create/Modify

| File | Change | Prohibited? |
|------|--------|-------------|
| `Sources/SwiftStateTree/Sync/SnapshotValueDecodable.swift` | **New** | No |
| `Sources/SwiftStateTree/Sync/SnapshotValue.swift` | **Modify** — add `requireInt()`, `requireBool()`, etc. | No |
| `Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift` | **Modify** — add `init(fromBroadcastSnapshot:)` generation | No |
| `Sources/SwiftStateTreeMacros/SnapshotConvertibleMacro.swift` | **Modify** — add `init(fromSnapshotValue:)` generation | No |
| `Sources/SwiftStateTreeDeterministicMath/IVec2+SnapshotDecodable.swift` | **New** | No |
| `Sources/SwiftStateTreeDeterministicMath/Position2+SnapshotDecodable.swift` | **New** | No |
| `Sources/SwiftStateTreeDeterministicMath/Angle+SnapshotDecodable.swift` | **New** | No |
| `Sources/SwiftStateTreeReevaluationMonitor/StateFromSnapshotDecodable.swift` | **New** | No |
| `Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift` | **New** | No |
| `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift` | **Additive overload only** | Additive OK |
| `LandKeeper.swift` | **NOT touched** | Prohibited |
| `TransportAdapter.swift` | **NOT touched** | Prohibited |

---

## Implementation Phases

### Phase 1 — POC: Protocol + Macro Layer

Goal: verify that `@StateNodeBuilder` can generate `init(fromBroadcastSnapshot:)` with working dirty flags.

1. `SnapshotValueDecodable.swift` — protocol + built-in conformances (`Int`, `Bool`, `String`, `Double`, `Array`, `Optional`, `Dictionary`)
2. `SnapshotValue.swift` — add `requireInt()`, `requireBool()`, `requireString()`, `requireDouble()` helpers
3. `SnapshotKeyDecodable` — add to `SnapshotValueDecodable.swift`, implement for `String`, `Int`
4. `StateNodeBuilderMacro.swift` — generate `init(fromBroadcastSnapshot:)` for `@Sync(.broadcast)` properties
5. Unit tests with `MockReplayState` — verify values, dirty flags, round-trip

### Phase 2 — DeterministicMath + SnapshotConvertible

6. `IVec2+SnapshotDecodable.swift`, `Position2+SnapshotDecodable.swift`, `Angle+SnapshotDecodable.swift`
7. Extend `@SnapshotConvertible` macro to also generate `init(fromSnapshotValue:)`
8. `PlayerID: SnapshotKeyDecodable` (game-specific, in GameContent or GameServer)

### Phase 3 — GenericReplayLand Integration

9. `GenericReplayLand.swift` — Tick handler, runner stepping, state decode + sync
10. `ReevaluationFeature.swift` — additive `registerWithGenericReplay` overload
11. E2E test via `verify-replay-record.ts`

---

## Key Invariants (Do Not Violate)

- All property assignments in `init(fromBroadcastSnapshot:)` go through `wrappedValue.set` (setter), never direct `_field.init`
- `SnapshotValue` reverse helpers are strict (throw on type mismatch), not silently nil
- Dictionary key failures use `compactMap` (skip unparseable keys, do not throw entire decode)
- `GenericReplayLand` runs in `.live` mode; no changes to reevaluation output modes
- `registerWithGenericReplay` is a new overload; `registerWithReevaluationSameLand` signature is unchanged
