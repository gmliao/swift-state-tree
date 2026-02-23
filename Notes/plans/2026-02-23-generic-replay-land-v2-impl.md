# Generic Replay Land v2 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend `@StateNodeBuilder` to generate `init(fromBroadcastSnapshot:)`, enabling `GenericReplayLand<State>` to replay recorded game sessions without manual `+Decodable.swift` files and with correct dirty-flag tracking.

**Architecture:** New `SnapshotValueDecodable` protocol + `SnapshotKeyDecodable` protocol enable compile-time safe reverse decoding of `StateSnapshot`. `@StateNodeBuilder` macro generates `init(fromBroadcastSnapshot:)` using property setters (which trigger `_isDirty = true`). `@SnapshotConvertible` macro extended to also generate `init(fromSnapshotValue:)`. `GenericReplayLand<State>` runs in `.live` mode and uses `init(fromBroadcastSnapshot:)` each tick.

**Tech Stack:** Swift macros (`SwiftSyntax`, `SwiftSyntaxBuilder`), Swift Testing (`@Test`, `#expect`), Swift conditional conformances, `@StateNodeBuilder`, `@SnapshotConvertible`

---

## Key Files Reference

| Symbol | File |
|--------|------|
| `SnapshotValue` enum | `Sources/SwiftStateTree/Sync/SnapshotValue.swift` |
| `SnapshotValueConvertible` | `Sources/SwiftStateTree/Sync/SnapshotValue.swift` (bottom) |
| `StateNodeProtocol` | `Sources/SwiftStateTree/StateTree/StateNodeProtocol.swift` |
| `PlayerID` | `Sources/SwiftStateTree/Sync/PlayerID.swift` |
| `StateNodeBuilderMacro` | `Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift` |
| `SnapshotConvertibleMacro` | `Sources/SwiftStateTreeMacros/SnapshotConvertibleMacro.swift` |
| `IVec2` | `Sources/SwiftStateTreeDeterministicMath/Core/IVec2.swift` |
| `Position2` | `Sources/SwiftStateTreeDeterministicMath/Semantic/Semantic2.swift` |
| `ReevaluationFeature` | `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift` |
| `ReevaluationInterfaces` | `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift` |
| Macro tests | `Tests/SwiftStateTreeMacrosTests/` |

## Invariants — NEVER Violate

1. `LandKeeper.swift` — do NOT touch
2. `TransportAdapter.swift` — do NOT touch
3. `ReevaluationFeature.swift` — ONLY additive new overload in Phase 3, never modify existing functions
4. All property assignments in `init(fromBroadcastSnapshot:)` MUST go through property setters (not `_field.init`)
5. `SnapshotValue` reverse helpers throw on type mismatch, never return nil silently
6. Dictionary key failures use `compactMap` (skip unparseable keys, do not throw)

---

## PHASE 1 — POC: Protocol Layer + Macro Foundation

**Goal of Phase 1:** Verify that `@StateNodeBuilder` can generate `init(fromBroadcastSnapshot:)` with working dirty flags using a simple test state (no game dependencies).

---

### Task 1: Create `SnapshotValueDecodable.swift` — Protocol + Basic Conformances

**Files:**
- Create: `Sources/SwiftStateTree/Sync/SnapshotValueDecodable.swift`

**Step 1: Write the failing test first**

Create `Tests/SwiftStateTreeTests/SnapshotValueDecodableTests.swift`:

```swift
import Testing
@testable import SwiftStateTree

@Suite("SnapshotValueDecodable")
struct SnapshotValueDecodableTests {

    @Test("Int decodes from .int case")
    func intFromInt() throws {
        let v: Int = try Int(fromSnapshotValue: .int(42))
        #expect(v == 42)
    }

    @Test("Int throws on wrong type")
    func intThrowsOnWrongType() {
        #expect(throws: (any Error).self) {
            _ = try Int(fromSnapshotValue: .string("bad"))
        }
    }

    @Test("String decodes from .string case")
    func stringFromString() throws {
        let v: String = try String(fromSnapshotValue: .string("hello"))
        #expect(v == "hello")
    }

    @Test("Bool decodes from .bool case")
    func boolFromBool() throws {
        #expect(try Bool(fromSnapshotValue: .bool(true)) == true)
        #expect(try Bool(fromSnapshotValue: .bool(false)) == false)
    }

    @Test("Double decodes from .double case")
    func doubleFromDouble() throws {
        #expect(try Double(fromSnapshotValue: .double(3.14)) == 3.14)
    }

    @Test("Optional decodes .null as nil")
    func optionalNull() throws {
        let v = try Optional<Int>(fromSnapshotValue: .null)
        #expect(v == nil)
    }

    @Test("Optional decodes value as .some")
    func optionalValue() throws {
        let v = try Optional<Int>(fromSnapshotValue: .int(7))
        #expect(v == 7)
    }

    @Test("Array decodes .array case")
    func arrayDecode() throws {
        let v = try [Int](fromSnapshotValue: .array([.int(1), .int(2), .int(3)]))
        #expect(v == [1, 2, 3])
    }

    @Test("Dictionary decodes .object case with String keys")
    func dictionaryStringKey() throws {
        let v = try [String: Int](fromSnapshotValue: .object(["a": .int(1), "b": .int(2)]))
        #expect(v == ["a": 1, "b": 2])
    }

    @Test("Dictionary decodes .object case with Int keys")
    func dictionaryIntKey() throws {
        let v = try [Int: Int](fromSnapshotValue: .object(["1": .int(10), "2": .int(20)]))
        #expect(v == [1: 10, 2: 20])
    }

    @Test("Dictionary skips unparseable Int keys (compactMap)")
    func dictionaryIntKeySkipsBadKeys() throws {
        // key "bad" cannot be parsed as Int — must skip, not throw
        let v = try [Int: Int](fromSnapshotValue: .object(["1": .int(10), "bad": .int(99)]))
        #expect(v == [1: 10])
    }
}
```

**Step 2: Run the test to confirm it fails**

```bash
swift test --filter "SnapshotValueDecodableTests"
```

Expected: compile error — `SnapshotValueDecodable` not defined, `Int` has no `init(fromSnapshotValue:)`.

**Step 3: Implement `SnapshotValueDecodable.swift`**

Create `Sources/SwiftStateTree/Sync/SnapshotValueDecodable.swift`:

```swift
// SnapshotValueDecodable.swift
// Reverse-decode protocol for SnapshotValue → Swift types.
// Used by @StateNodeBuilder-generated init(fromBroadcastSnapshot:).

import Foundation

// MARK: - Errors

public enum SnapshotDecodeError: Error, Sendable {
    case typeMismatch(expected: String, got: SnapshotValue)
    case missingKey(String)
    case invalidKeyString(String, targetType: String)
}

// MARK: - SnapshotKeyDecodable

/// Types that can decode themselves from a String snapshot key.
/// All dictionary key types used with @Sync must conform.
public protocol SnapshotKeyDecodable: Hashable {
    init?(snapshotKey: String)
}

extension String: SnapshotKeyDecodable {
    public init?(snapshotKey: String) { self = snapshotKey }
}

extension Int: SnapshotKeyDecodable {
    public init?(snapshotKey: String) {
        guard let v = Int(snapshotKey) else { return nil }
        self = v
    }
}

// PlayerID is defined in SwiftStateTree/Sync/PlayerID.swift
extension PlayerID: SnapshotKeyDecodable {
    public init?(snapshotKey: String) { self.init(snapshotKey) }
}

// MARK: - SnapshotValueDecodable

/// Types that can decode themselves from a SnapshotValue.
/// All value types used with @Sync(.broadcast) must conform.
public protocol SnapshotValueDecodable {
    init(fromSnapshotValue value: SnapshotValue) throws
}

// MARK: - Primitive Conformances

extension Int: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .int(let v) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Int (.int)", got: value)
        }
        self = v
    }
}

extension Bool: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .bool(let v) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Bool (.bool)", got: value)
        }
        self = v
    }
}

extension String: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .string(let v) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "String (.string)", got: value)
        }
        self = v
    }
}

extension Double: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .double(let v) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Double (.double)", got: value)
        }
        self = v
    }
}

// MARK: - Collection Conformances

extension Optional: SnapshotValueDecodable where Wrapped: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        if case .null = value {
            self = .none
        } else {
            self = .some(try Wrapped(fromSnapshotValue: value))
        }
    }
}

extension Array: SnapshotValueDecodable where Element: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .array(let arr) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Array (.array)", got: value)
        }
        self = try arr.map { try Element(fromSnapshotValue: $0) }
    }
}

extension Dictionary: SnapshotValueDecodable
    where Key: SnapshotKeyDecodable, Value: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .object(let dict) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Dictionary (.object)", got: value)
        }
        // Invariant: unparseable keys are skipped (compactMap), not a throw
        self = try Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in
            guard let key = Key(snapshotKey: k) else { return nil }
            let val = try Value(fromSnapshotValue: v)
            return (key, val)
        })
    }
}

// MARK: - Codable Bridge Helper

/// Decodes a SnapshotValue to a Decodable type via JSON.
/// Use this for complex types that are Codable but not SnapshotValueDecodable via direct extraction.
public extension SnapshotValue {
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}
```

**Step 4: Run tests**

```bash
swift test --filter "SnapshotValueDecodableTests"
```

Expected: all tests PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Sync/SnapshotValueDecodable.swift \
        Tests/SwiftStateTreeTests/SnapshotValueDecodableTests.swift
git commit -m "feat: add SnapshotValueDecodable and SnapshotKeyDecodable protocols with primitive conformances"
```

---

### Task 2: Add `require*()` Helpers to `SnapshotValue`

**Files:**
- Modify: `Sources/SwiftStateTree/Sync/SnapshotValue.swift`

**Step 1: Write failing test**

Add to the test file `Tests/SwiftStateTreeTests/SnapshotValueDecodableTests.swift`:

```swift
// Add to existing test suite:

@Test("SnapshotValue.requireInt extracts int")
func requireInt() throws {
    #expect(try SnapshotValue.int(5).requireInt() == 5)
}

@Test("SnapshotValue.requireInt throws on mismatch")
func requireIntThrows() {
    #expect(throws: (any Error).self) {
        _ = try SnapshotValue.string("x").requireInt()
    }
}

@Test("SnapshotValue.requireBool extracts bool")
func requireBool() throws {
    #expect(try SnapshotValue.bool(true).requireBool() == true)
}

@Test("SnapshotValue.requireString extracts string")
func requireString() throws {
    #expect(try SnapshotValue.string("hi").requireString() == "hi")
}

@Test("SnapshotValue.requireDouble extracts double")
func requireDouble() throws {
    #expect(try SnapshotValue.double(1.5).requireDouble() == 1.5)
}
```

**Step 2: Run test, confirm fails**

```bash
swift test --filter "requireInt\|requireBool\|requireString\|requireDouble"
```

Expected: compile error — `requireInt()` method not found.

**Step 3: Add helpers to `SnapshotValue.swift`**

At the end of `Sources/SwiftStateTree/Sync/SnapshotValue.swift`, add:

```swift
// MARK: - Strict Extraction Helpers (for SnapshotValueDecodable implementations)

public extension SnapshotValue {
    func requireInt() throws -> Int {
        guard case .int(let v) = self else {
            throw SnapshotDecodeError.typeMismatch(expected: "Int (.int)", got: self)
        }
        return v
    }

    func requireBool() throws -> Bool {
        guard case .bool(let v) = self else {
            throw SnapshotDecodeError.typeMismatch(expected: "Bool (.bool)", got: self)
        }
        return v
    }

    func requireString() throws -> String {
        guard case .string(let v) = self else {
            throw SnapshotDecodeError.typeMismatch(expected: "String (.string)", got: self)
        }
        return v
    }

    func requireDouble() throws -> Double {
        guard case .double(let v) = self else {
            throw SnapshotDecodeError.typeMismatch(expected: "Double (.double)", got: self)
        }
        return v
    }
}
```

**Step 4: Run tests**

```bash
swift test --filter "SnapshotValueDecodableTests"
```

Expected: all PASS.

**Step 5: Run full test suite (regression check)**

```bash
swift test
```

Expected: all existing tests pass.

**Step 6: Commit**

```bash
git add Sources/SwiftStateTree/Sync/SnapshotValue.swift \
        Tests/SwiftStateTreeTests/SnapshotValueDecodableTests.swift
git commit -m "feat: add require*() strict extraction helpers to SnapshotValue"
```

---

### Task 3: Extend `StateNodeBuilderMacro` to Generate `init(fromBroadcastSnapshot:)`

**Files:**
- Modify: `Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift`

**Context:** The macro currently generates `broadcastSnapshot(dirtyFields:)` by iterating `@Sync(.broadcast)` properties. We add a parallel method that does the reverse: `init(fromBroadcastSnapshot:)`.

**Step 1: Write the macro expansion test (TDD)**

Create `Tests/SwiftStateTreeMacrosTests/StateNodeBuilderSnapshotDecodeTests.swift`:

```swift
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

// NOTE: We only test macro EXPANSION here (what code the macro generates).
// Runtime behavior (dirty flags, round-trip) is tested in Task 4.

private let testMacros: [String: Macro.Type] = [
    "StateNodeBuilder": StateNodeBuilderMacro.self
]

@Suite("StateNodeBuilder fromBroadcastSnapshot generation")
final class StateNodeBuilderSnapshotDecodeMacroTests {

    @Test("macro generates init(fromBroadcastSnapshot:) for broadcast-only state")
    func generatesFromBroadcastSnapshotInit() throws {
        assertMacroExpansion(
            """
            @StateNodeBuilder
            struct SimpleState: StateNodeProtocol {
                @Sync(.broadcast)
                var score: Int = 0
                @Sync(.broadcast)
                var name: String = ""
            }
            """,
            expandedSource: """
            struct SimpleState: StateNodeProtocol {
                @Sync(.broadcast)
                var score: Int = 0
                @Sync(.broadcast)
                var name: String = ""
            }

            extension SimpleState: StateFromSnapshotDecodable {
                public init(fromBroadcastSnapshot snapshot: StateSnapshot) throws {
                    self.init()
                    if let _v = snapshot.values["score"] { self.score = try _snapshotDecode(_v) }
                    if let _v = snapshot.values["name"] { self.name = try _snapshotDecode(_v) }
                }
            }
            """,
            macros: testMacros
        )
        // Note: the expanded source will also contain the existing generated methods
        // (isDirty, getDirtyFields, broadcastSnapshot, etc.) — assertMacroExpansion
        // checks for the presence of specific sections; adjust expected source to match actual full expansion.
        // Run swift test once to capture the actual expansion and update this test.
    }
}
```

> **Note:** The first run of this test will likely fail due to the expanded source not matching exactly (the macro generates many other methods too). Run `swift test --filter "StateNodeBuilderSnapshotDecodeMacroTests"` once, look at the actual output, then update the `expandedSource` to match. This is the standard workflow for macro expansion tests.

**Step 2: Run to see actual expansion (expected: fail initially)**

```bash
swift test --filter "StateNodeBuilderSnapshotDecodeMacroTests" 2>&1 | head -80
```

Expected: compile error — `StateFromSnapshotDecodable` not found (we haven't added the protocol yet).

**Step 3: Add `StateFromSnapshotDecodable` protocol to SwiftStateTree**

Create `Sources/SwiftStateTree/Sync/StateFromSnapshotDecodable.swift`:

```swift
// StateFromSnapshotDecodable.swift
// Protocol for StateNodeProtocol types that support snapshot-based initialization.
// Automatically conformed to by @StateNodeBuilder macro for all broadcast-@Sync states.

/// A StateNodeProtocol type that can reconstruct itself from a broadcast StateSnapshot.
///
/// The @StateNodeBuilder macro automatically generates conformance for types that
/// have only @Sync(.broadcast) properties whose value types conform to SnapshotValueDecodable.
///
/// Usage in GenericReplayLand:
/// ```swift
/// let decoded = try State(fromBroadcastSnapshot: snapshot)
/// self.state = decoded
/// requestSyncBroadcastOnly()
/// ```
public protocol StateFromSnapshotDecodable: StateNodeProtocol {
    init(fromBroadcastSnapshot snapshot: StateSnapshot) throws
}
```

**Step 4: Add `_snapshotDecode` helper function to `SwiftStateTree`**

Append to `Sources/SwiftStateTree/Sync/SnapshotValueDecodable.swift`:

```swift
// MARK: - Generic Helper (used by macro-generated init(fromBroadcastSnapshot:))

/// Type-inferred decode helper. The macro generates calls like:
///   self.score = try _snapshotDecode(v)
/// Swift infers T from the left-hand side type.
@inline(__always)
public func _snapshotDecode<T: SnapshotValueDecodable>(_ value: SnapshotValue) throws -> T {
    return try T(fromSnapshotValue: value)
}
```

**Step 5: Add `init(fromBroadcastSnapshot:)` generation to `StateNodeBuilderMacro.swift`**

In `StateNodeBuilderMacro.swift`, find the section that generates `broadcastSnapshot(dirtyFields:)`. The macro likely calls something like `generateBroadcastSnapshotMethod(syncProperties:)`. Add a call to a new function `generateFromBroadcastSnapshotInit(syncProperties:)` in the same extension generation.

Locate in `StateNodeBuilderMacro.swift` where `ExtensionDeclSyntax` blocks are returned (there will be multiple extensions generated). Add a new extension block:

```swift
// Add this function to StateNodeBuilderMacro:

private static func generateFromBroadcastSnapshotInit(
    typeName: String,
    syncProperties: [PropertyInfo]
) throws -> ExtensionDeclSyntax {
    // Only include .broadcast properties (same filter as broadcastSnapshot)
    let broadcastProperties = syncProperties.filter { $0.policyType == .broadcast }

    var assignmentLines: [String] = []
    for prop in broadcastProperties {
        assignmentLines.append(
            "        if let _v = snapshot.values[\"\(prop.name)\"] { self.\(prop.name) = try _snapshotDecode(_v) }"
        )
    }
    let body = assignmentLines.joined(separator: "\n")

    return try ExtensionDeclSyntax(
        """
        extension \(raw: typeName): StateFromSnapshotDecodable {
            public init(fromBroadcastSnapshot snapshot: StateSnapshot) throws {
                self.init()
        \(raw: body)
            }
        }
        """
    )
}
```

Then in the main `expansion` function of `StateNodeBuilderMacro`, add the call:

```swift
// Inside the expansion function, add to the returned extensions array:
let fromSnapshotInitExtension = try generateFromBroadcastSnapshotInit(
    typeName: typeName,
    syncProperties: syncProperties
)
// Append to existing extensions array
```

> **Note:** The exact location depends on the macro's structure. Find where the array of `ExtensionDeclSyntax` is built and append the new extension.

**Step 6: Run macro test**

```bash
swift test --filter "StateNodeBuilderSnapshotDecodeMacroTests" 2>&1 | head -80
```

Look at the actual expanded source. Update the `expandedSource` in the test to match the actual output (the test failure output shows the actual vs expected). Then re-run.

**Step 7: Run full test suite**

```bash
swift test
```

Expected: all PASS (no regressions in existing macro tests).

**Step 8: Commit**

```bash
git add Sources/SwiftStateTree/Sync/StateFromSnapshotDecodable.swift \
        Sources/SwiftStateTree/Sync/SnapshotValueDecodable.swift \
        Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift \
        Tests/SwiftStateTreeMacrosTests/StateNodeBuilderSnapshotDecodeTests.swift
git commit -m "feat: @StateNodeBuilder generates init(fromBroadcastSnapshot:) with StateFromSnapshotDecodable conformance"
```

---

### Task 4: POC Runtime Tests — Verify Dirty Flags + Round-Trip

**Files:**
- Create: `Tests/SwiftStateTreeTests/StateNodeSnapshotDecodeRuntimeTests.swift`

**Context:** These are RUNTIME tests (not macro expansion tests). They verify that the generated `init(fromBroadcastSnapshot:)` correctly:
1. Decodes values
2. Sets dirty flags via property setters
3. Round-trips correctly through `broadcastSnapshot` → `init(fromBroadcastSnapshot:)`

**Step 1: Write failing tests**

```swift
import Testing
@testable import SwiftStateTree

// Minimal test state using only Int, String, Bool (Phase 1 supported types)
@StateNodeBuilder
private struct MockReplayState: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var name: String = ""
    @Sync(.broadcast) var active: Bool = false
    @Sync(.broadcast) var tags: [String: Int] = [:]
    @Sync(.serverOnly) var internalCounter: Int = 0  // NOT included in broadcast snapshot
}

@Suite("StateNode fromBroadcastSnapshot runtime")
struct StateNodeSnapshotDecodeRuntimeTests {

    @Test("init(fromBroadcastSnapshot:) decodes primitive values correctly")
    func decodesPrimitiveValues() throws {
        let snapshot = StateSnapshot(values: [
            "score": .int(42),
            "name": .string("test-player"),
            "active": .bool(true)
        ])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(state.score == 42)
        #expect(state.name == "test-player")
        #expect(state.active == true)
    }

    @Test("missing snapshot fields keep default values")
    func missingFieldsKeepDefaults() throws {
        let snapshot = StateSnapshot(values: ["score": .int(99)])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(state.score == 99)
        #expect(state.name == "")   // default
        #expect(state.active == false)  // default
    }

    @Test("dirty flags are set for all decoded fields")
    func dirtyFlagsSetAfterDecode() throws {
        let snapshot = StateSnapshot(values: [
            "score": .int(10),
            "name": .string("player"),
            "active": .bool(false)
        ])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(state.isDirty() == true)
        let dirty = state.getDirtyFields()
        #expect(dirty.contains("score"))
        #expect(dirty.contains("name"))
        #expect(dirty.contains("active"))
    }

    @Test("fields not present in snapshot are NOT dirty")
    func fieldsAbsentFromSnapshotAreNotDirty() throws {
        let snapshot = StateSnapshot(values: ["score": .int(5)])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        let dirty = state.getDirtyFields()
        #expect(dirty.contains("score"))
        #expect(!dirty.contains("name"))
        #expect(!dirty.contains("active"))
    }

    @Test("[String: Int] dictionary decodes correctly")
    func stringIntDictionaryDecode() throws {
        let snapshot = StateSnapshot(values: [
            "tags": .object(["kills": .int(3), "deaths": .int(1)])
        ])
        let state = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(state.tags["kills"] == 3)
        #expect(state.tags["deaths"] == 1)
    }

    @Test("broadcastSnapshot round-trip preserves values")
    func broadcastSnapshotRoundTrip() throws {
        var original = MockReplayState()
        original.score = 77
        original.name = "roundtrip"
        original.active = true
        original.tags = ["x": 5]

        let snapshot = try original.broadcastSnapshot(dirtyFields: nil)
        let decoded = try MockReplayState(fromBroadcastSnapshot: snapshot)

        #expect(decoded.score == 77)
        #expect(decoded.name == "roundtrip")
        #expect(decoded.active == true)
        #expect(decoded.tags["x"] == 5)
    }

    @Test("serverOnly field is NOT included in broadcastSnapshot (and thus not decoded)")
    func serverOnlyFieldExcluded() throws {
        var original = MockReplayState()
        original.internalCounter = 999
        let snapshot = try original.broadcastSnapshot(dirtyFields: nil)
        // internalCounter should not be in the broadcast snapshot
        #expect(snapshot.values["internalCounter"] == nil)
        // After decode, internalCounter stays at default
        let decoded = try MockReplayState(fromBroadcastSnapshot: snapshot)
        #expect(decoded.internalCounter == 0)
    }
}
```

**Step 2: Run tests (should fail — MockReplayState doesn't have `init(fromBroadcastSnapshot:)` yet)**

```bash
swift test --filter "StateNodeSnapshotDecodeRuntimeTests"
```

Expected: compile error — `MockReplayState` does not conform to `StateFromSnapshotDecodable`.

**Step 3: (After Task 3 is implemented)** Re-run

```bash
swift test --filter "StateNodeSnapshotDecodeRuntimeTests"
```

Expected: all PASS.

**Step 4: Run full test suite**

```bash
swift test
```

Expected: all existing tests PASS, new tests PASS.

**Step 5: Commit**

```bash
git add Tests/SwiftStateTreeTests/StateNodeSnapshotDecodeRuntimeTests.swift
git commit -m "test: add runtime POC tests for init(fromBroadcastSnapshot:) — dirty flags and round-trip"
```

---

## PHASE 2 — DeterministicMath + SnapshotConvertible Bidirectional

**Goal of Phase 2:** Enable `Position2`, `IVec2`, `Angle`, and all `@SnapshotConvertible` types to be decoded from snapshots. After this phase, a `MockGameState` with `Position2` fields can round-trip through `init(fromBroadcastSnapshot:)`.

---

### Task 5: `IVec2` and `Angle` — `SnapshotValueDecodable` Extensions

**Files:**
- Create: `Sources/SwiftStateTreeDeterministicMath/IVec2+SnapshotDecodable.swift`
- Create: `Sources/SwiftStateTreeDeterministicMath/Angle+SnapshotDecodable.swift`

**Context:**
- `IVec2` is `Codable` (synthesized: `{x: Int32, y: Int32}` → `{"x": 64000, "y": 64000}`)
- `IVec2` snapshot format: `.object(["x": .int(64000), "y": .int(64000)])` (from Mirror fallback in `SnapshotValue.make`)
- `Angle` snapshot format: `.object(["degrees": .int(90)])` (from its `SnapshotValueConvertible`)

**Step 1: Write failing tests**

Create `Tests/SwiftStateTreeDeterministicMathTests/SnapshotDecodableTests.swift`:

```swift
import Testing
@testable import SwiftStateTreeDeterministicMath

@Suite("DeterministicMath SnapshotValueDecodable")
struct DeterministicMathSnapshotDecodableTests {

    @Test("IVec2 decodes from object snapshot")
    func ivec2Decode() throws {
        let v = SnapshotValue.object(["x": .int(64000), "y": .int(36000)])
        let ivec = try IVec2(fromSnapshotValue: v)
        #expect(ivec.x == 64000)
        #expect(ivec.y == 36000)
    }

    @Test("IVec2 throws on wrong type")
    func ivec2ThrowsOnWrongType() {
        #expect(throws: (any Error).self) {
            _ = try IVec2(fromSnapshotValue: .string("bad"))
        }
    }

    @Test("Position2 decodes from nested object snapshot")
    func position2Decode() throws {
        // Position2 snapshot format: {"v": {"x": 64000, "y": 36000}}
        let v = SnapshotValue.object(["v": .object(["x": .int(64000), "y": .int(36000)])])
        let pos = try Position2(fromSnapshotValue: v)
        #expect(pos.v.x == 64000)
        #expect(pos.v.y == 36000)
    }

    @Test("Angle decodes from object snapshot")
    func angleDecode() throws {
        // Angle snapshot format: {"degrees": 90} (check actual format from toSnapshotValue())
        let v = SnapshotValue.object(["degrees": .int(90)])
        let angle = try Angle(fromSnapshotValue: v)
        // Verify angle value (exact check depends on Angle's internal representation)
        #expect(angle != Angle.zero)  // at least not zero
    }

    @Test("IVec2 round-trip through SnapshotValue")
    func ivec2RoundTrip() throws {
        let original = IVec2(x: Float(12.5), y: Float(34.0))
        let snapshotValue = try SnapshotValue.make(from: original)
        let decoded = try IVec2(fromSnapshotValue: snapshotValue)
        #expect(decoded == original)
    }

    @Test("Position2 round-trip through broadcastSnapshot")
    func position2RoundTrip() throws {
        let pos = Position2(x: 10.0, y: 20.0)
        let snapshotValue = try pos.toSnapshotValue()
        let decoded = try Position2(fromSnapshotValue: snapshotValue)
        #expect(decoded == pos)
    }
}
```

**Step 2: Run, confirm fails**

```bash
swift test --filter "DeterministicMathSnapshotDecodableTests"
```

Expected: compile error — `IVec2` has no `init(fromSnapshotValue:)`.

**Step 3: Implement IVec2 extension**

First check the actual `Angle.toSnapshotValue()` format by reading `Sources/SwiftStateTreeDeterministicMath/` to find the Angle type.

Create `Sources/SwiftStateTreeDeterministicMath/IVec2+SnapshotDecodable.swift`:

```swift
import SwiftStateTree

extension IVec2: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .object(let dict) = value,
              let xVal = dict["x"], case .int(let x) = xVal,
              let yVal = dict["y"], case .int(let y) = yVal
        else {
            throw SnapshotDecodeError.typeMismatch(
                expected: "IVec2 (.object with x:int, y:int)",
                got: value
            )
        }
        self = IVec2(rawX: Int32(x), rawY: Int32(y))
        // NOTE: Use the internal raw initializer IVec2(rawX:rawY:) if available,
        // or the public init that accepts Int32 directly. Check IVec2.swift for exact init name.
    }
}
```

> **Note:** After writing, check `IVec2.swift` for the exact internal initializer signature. It may be `init(x: Int32, y: Int32)` (the internal init documented in the file) or `init(rawX:rawY:)`. Use whichever accepts raw Int32 values without re-quantizing.

**Step 4: Implement Angle extension**

First read `Sources/SwiftStateTreeDeterministicMath/` to find `Angle.swift` and check:
1. What does `Angle.toSnapshotValue()` produce? (inspect the type)
2. What initializer can reconstruct Angle from raw stored value?

Create `Sources/SwiftStateTreeDeterministicMath/Angle+SnapshotDecodable.swift` based on findings.

**Step 5: Add Position2 conformance via @SnapshotConvertible extension** (see Task 6)

**Step 6: Run tests**

```bash
swift test --filter "DeterministicMathSnapshotDecodableTests"
```

Expected: IVec2 and Position2 tests PASS (Position2 after Task 6).

**Step 7: Run full suite**

```bash
swift test
```

**Step 8: Commit**

```bash
git add Sources/SwiftStateTreeDeterministicMath/IVec2+SnapshotDecodable.swift \
        Sources/SwiftStateTreeDeterministicMath/Angle+SnapshotDecodable.swift \
        Tests/SwiftStateTreeDeterministicMathTests/SnapshotDecodableTests.swift
git commit -m "feat: add SnapshotValueDecodable conformance for IVec2 and Angle"
```

---

### Task 6: Extend `@SnapshotConvertible` to Generate `init(fromSnapshotValue:)`

**Files:**
- Modify: `Sources/SwiftStateTreeMacros/SnapshotConvertibleMacro.swift`

**Context:** Currently `@SnapshotConvertible` generates only `toSnapshotValue()` via extension `SnapshotValueConvertible`. We extend it to also generate `init(fromSnapshotValue:)` + `SnapshotValueDecodable` conformance.

The existing macro:
1. Collects stored properties (`collectStoredProperties`)
2. Generates `toSnapshotValue()` via `generateToSnapshotValueMethod`
3. Returns one `ExtensionDeclSyntax` for `SnapshotValueConvertible`

We add: a second `ExtensionDeclSyntax` for `SnapshotValueDecodable`.

**Step 1: Write macro expansion test**

Add to `Tests/SwiftStateTreeMacrosTests/SnapshotConvertibleMacroTests.swift`:

```swift
@Test("SnapshotConvertible macro generates init(fromSnapshotValue:) for basic types")
func testSnapshotConvertible_GeneratesFromSnapshotValueInit() throws {
    assertMacroExpansion(
        """
        @SnapshotConvertible
        struct PlayerState: Codable {
            var name: String
            var hpCurrent: Int
            var hpMax: Int
        }
        """,
        expandedSource: """
        struct PlayerState: Codable {
            var name: String
            var hpCurrent: Int
            var hpMax: Int
        }

        extension PlayerState: SnapshotValueConvertible {
            public func toSnapshotValue() throws -> SnapshotValue {
                return .object([
                    "name": .string(name),
                    "hpCurrent": .int(hpCurrent),
                    "hpMax": .int(hpMax)
                ])
            }
        }

        extension PlayerState: SnapshotValueDecodable {
            public init(fromSnapshotValue value: SnapshotValue) throws {
                guard case .object(let _dict) = value else {
                    throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
                }
                self.init()
                if let _v = _dict["name"] { self.name = try _snapshotDecode(_v) }
                if let _v = _dict["hpCurrent"] { self.hpCurrent = try _snapshotDecode(_v) }
                if let _v = _dict["hpMax"] { self.hpMax = try _snapshotDecode(_v) }
            }
        }
        """,
        macros: testMacros
    )
}
```

**Step 2: Run test (expected: fail — second extension not generated yet)**

```bash
swift test --filter "testSnapshotConvertible_GeneratesFromSnapshotValueInit"
```

**Step 3: Implement in `SnapshotConvertibleMacro.swift`**

Add a new function `generateFromSnapshotValueInit` and call it from `expansion`:

```swift
/// Generate init(fromSnapshotValue:) method for SnapshotValueDecodable conformance
private static func generateFromSnapshotValueInit(
    properties: [PropertyInfo]
) throws -> FunctionDeclSyntax {
    var assignmentLines: [String] = []
    for prop in properties {
        assignmentLines.append(
            "        if let _v = _dict[\"\(prop.name)\"] { self.\(prop.name) = try _snapshotDecode(_v) }"
        )
    }
    let body = assignmentLines.joined(separator: "\n")
    return try FunctionDeclSyntax(
        """
        public init(fromSnapshotValue value: SnapshotValue) throws {
            guard case .object(let _dict) = value else {
                throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
            }
            self.init()
        \(raw: body)
        }
        """
    )
}
```

In `expansion`, after creating the `SnapshotValueConvertible` extension, add a second extension:

```swift
let fromSnapshotMethod = try generateFromSnapshotValueInit(properties: properties)
let decodableExtension = try ExtensionDeclSyntax(
    """
    extension \(type.trimmed): SnapshotValueDecodable {
        \(fromSnapshotMethod)
    }
    """
)
return [extensionDecl, decodableExtension]
```

**Step 4: Run macro test**

```bash
swift test --filter "SnapshotConvertibleMacroTests"
```

Adjust expected expansion if needed based on actual output.

**Step 5: Run integration test for Position2**

```bash
swift test --filter "DeterministicMathSnapshotDecodableTests"
```

`position2RoundTrip` should now PASS because `@SnapshotConvertible` generates `init(fromSnapshotValue:)` for `Position2`.

**Step 6: Run full suite**

```bash
swift test
```

**Step 7: Commit**

```bash
git add Sources/SwiftStateTreeMacros/SnapshotConvertibleMacro.swift \
        Tests/SwiftStateTreeMacrosTests/SnapshotConvertibleMacroTests.swift
git commit -m "feat: @SnapshotConvertible now generates bidirectional init(fromSnapshotValue:) for SnapshotValueDecodable"
```

---

### Task 7: `PlayerID: SnapshotKeyDecodable` — Already Done in Task 1

`PlayerID: SnapshotKeyDecodable` was added in Task 1 via `Sources/SwiftStateTree/Sync/SnapshotValueDecodable.swift`. No additional work needed.

**Verify:**

```bash
swift test --filter "dictionaryIntKey\|dictionaryStringKey"
```

Expected: PASS.

---

## PHASE 3 — GenericReplayLand Integration

**Goal of Phase 3:** Wire up `GenericReplayLand<State>` to replay from a `ReevaluationRunnerService`, broadcasting decoded state to connected clients each tick.

---

### Task 8: Implement `GenericReplayLand.swift`

**Files:**
- Create: `Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift`

**Step 1: Read relevant interfaces first**

Before implementing, read:
- `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift` — `ReevaluationStepResult`, `ReevaluationRunnerService`
- `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerService.swift` — `consumeNextResult()`, `getStatus()`
- One existing `LandDefinition` usage in `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationMonitorLand.swift` — understand how Tick handlers are structured

**Step 2: Write integration test (using existing replay record)**

Decide: does a unit test exist for `GenericReplayLand`? For Phase 3 POC, rely on the existing E2E test infrastructure (`verify-replay-record.ts`).

Write a compile-only test first:

```swift
// Tests/SwiftStateTreeNIOTests/GenericReplayLandCompileTests.swift
import SwiftStateTree
import SwiftStateTreeReevaluationMonitor
import Testing

// This test just verifies the API compiles correctly.
@Suite("GenericReplayLand compile check")
struct GenericReplayLandCompileTests {
    @Test("GenericReplayLand.makeLand compiles for StateFromSnapshotDecodable type")
    func compilesForDecodableState() {
        // This test passes if it compiles.
        // Actual replay behavior is tested via E2E.
        _ = GenericReplayLand<ReevaluationMonitorState>.self
        // Note: ReevaluationMonitorState uses @StateNodeBuilder, should conform to
        // StateFromSnapshotDecodable after Phase 1. If it doesn't (server-only fields, etc.),
        // use a test-specific state type instead.
    }
}
```

**Step 3: Implement `GenericReplayLand.swift`**

```swift
// Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift
// Generic replay land that broadcasts recorded game state to connected clients.
// Runs in .live mode — no changes to LandKeeper required.

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// A factory for creating replay LandDefinitions.
///
/// GenericReplayLand replays a recorded session to connected clients using the existing
/// ReevaluationRunnerService infrastructure. Each tick, it:
/// 1. Steps the runner (re-computes one tick of game logic)
/// 2. Decodes the resulting StateSnapshot → State via macro-generated init
/// 3. Broadcasts the decoded state to all connected clients
///
/// The land runs in `.live` mode — no changes to LandKeeper are needed.
public enum GenericReplayLand<State: StateFromSnapshotDecodable> {

    /// Creates a replay LandDefinition based on an existing land definition.
    ///
    /// - Parameters:
    ///   - definition: The original live land definition (same State type)
    ///   - replayRunnerServiceKey: Service key used to retrieve the ReevaluationRunnerService
    ///     from the land's service container. Default: ReevaluationRunnerService.self
    public static func makeLand(
        basedOn definition: LandDefinition<State>
    ) -> LandDefinition<State> {
        return LandDefinition(
            id: definition.id,
            access: definition.access
        ) { (ctx: LandContext<State>) in

            // Get the runner service injected into this land's services
            guard let runnerService = ctx.services.get(ReevaluationRunnerService.self) else {
                return  // Replay not started yet; wait for next tick
            }

            // Consume next replay step result
            guard let result = runnerService.consumeNextResult() else {
                return  // No more frames (replay complete or not started)
            }

            // Decode the StateSnapshot from actualState
            guard let actualState = result.actualState else { return }

            // actualState.base is a JSON string containing the StateSnapshot
            guard let jsonString = actualState.base as? String,
                  let data = jsonString.data(using: .utf8) else { return }

            // Decode the outer wrapper: {"values": {...}}
            struct SnapshotWrapper: Decodable {
                let values: [String: SnapshotValue]
            }
            guard let wrapper = try? JSONDecoder().decode(SnapshotWrapper.self, from: data) else {
                return
            }
            let snapshot = StateSnapshot(values: wrapper.values)

            // Decode to typed State using macro-generated init (dirty flags = true)
            guard let decoded = try? State(fromBroadcastSnapshot: snapshot) else { return }

            ctx.state = decoded
            ctx.requestSyncBroadcastOnly()
        }
    }
}
```

> **Important:** The `actualState.base` access pattern (extracting JSON string from `AnyCodable`) must match the actual `AnyCodable` implementation. Read `Sources/SwiftStateTree/AnyCodable.swift` or similar to confirm how to extract the base value. Adjust accordingly.

**Step 4: Run compile test**

```bash
swift build
```

Expected: builds cleanly.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift \
        Tests/SwiftStateTreeNIOTests/GenericReplayLandCompileTests.swift
git commit -m "feat: add GenericReplayLand<State> — replays recorded sessions to clients in live mode"
```

---

### Task 9: Add `registerWithGenericReplay` Overload to `ReevaluationFeature.swift`

**Files:**
- Modify: `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift` (ADDITIVE ONLY — do not modify existing functions)

**Step 1: Read the existing file structure**

```
Read Sources/SwiftStateTreeNIO/ReevaluationFeature.swift
```

Understand the pattern of `registerWithReevaluationSameLand` to mirror for the new overload.

**Step 2: Write the new overload at the end of the file**

```swift
// MARK: - Generic Replay Registration (additive — does not modify existing functions)

public extension NIOLandHost {
    /// Registers a live land and a corresponding generic replay land.
    ///
    /// Unlike registerWithReevaluationSameLand, this variant does not require
    /// game-state-specific Decodable conformances. Instead it uses the macro-generated
    /// init(fromBroadcastSnapshot:) from StateFromSnapshotDecodable.
    ///
    /// The replay land type is "{landType}{reevaluation.replayLandSuffix}" (default: "{landType}-replay").
    ///
    /// - Parameters:
    ///   - landType: The base land type identifier (e.g. "hero-defense")
    ///   - liveLand: The LandDefinition for the live land
    ///   - liveInitialState: Factory for initial live state
    ///   - liveWebSocketPath: WebSocket path for the live land
    ///   - configuration: Server configuration
    ///   - reevaluation: Reevaluation feature configuration
    func registerWithGenericReplay<State: StateFromSnapshotDecodable>(
        landType: String,
        liveLand: LandDefinition<State>,
        liveInitialState: @autoclosure @escaping @Sendable () -> State,
        liveWebSocketPath: String,
        configuration: NIOLandServerConfiguration,
        reevaluation: ReevaluationFeatureConfiguration
    ) async throws {
        // Register live land (same as standard registration)
        try await register(
            landType: landType,
            land: liveLand,
            initialState: liveInitialState(),
            webSocketPath: liveWebSocketPath,
            configuration: configuration
        )

        guard reevaluation.enabled else { return }

        // Create the replay land using GenericReplayLand factory
        let replayLandType = landType + reevaluation.replayLandSuffix
        let replayLand = GenericReplayLand<State>.makeLand(basedOn: liveLand)
        let replayWebSocketPath = reevaluation.replayWebSocketPathResolver(landType)

        // Configure replay land server with runner service injection
        var replayConfig = configuration
        let runnerServiceFactory = reevaluation.runnerServiceFactory
        let existingServicesFactory = configuration.servicesFactory
        replayConfig = replayConfig.injectingRunnerService(
            runnerServiceFactory: runnerServiceFactory,
            existingServicesFactory: existingServicesFactory,
            recordsDir: ReevaluationEnvConfig.fromEnvironment().recordsDir,
            replayLandType: replayLandType
        )

        try await register(
            landType: replayLandType,
            land: replayLand,
            initialState: liveInitialState(),
            webSocketPath: replayWebSocketPath,
            configuration: replayConfig
        )

        // Register reevaluation monitor if enabled
        // (same pattern as registerWithReevaluationSameLand)
    }
}
```

> **Note:** The exact implementation of `injectingRunnerService` depends on how the existing `registerWithReevaluationSameLand` injects runner services. Read that function to understand the pattern and mirror it.

**Step 3: Build**

```bash
swift build
```

**Step 4: Commit**

```bash
git add Sources/SwiftStateTreeNIO/ReevaluationFeature.swift
git commit -m "feat: add registerWithGenericReplay overload — additive, does not modify existing API"
```

---

### Task 10: E2E Verification

**Files:**
- Read: `Tools/CLI/src/verify-replay-record.ts`
- Read: `Examples/GameDemo/Sources/GameServer/main.swift`

**Step 1: Update `GameServer/main.swift` to use `registerWithGenericReplay`**

In `main.swift`, find the `registerWithReevaluationSameLand` call and add an alternative:

```swift
// Option 1: existing (keep for comparison)
// try await nioHost.registerWithReevaluationSameLand(...)

// Option 2: new generic replay (after Phase 2 makes HeroDefenseState conform)
// try await nioHost.registerWithGenericReplay(
//     landType: "hero-defense",
//     liveLand: HeroDefense.makeLand(),
//     liveInitialState: HeroDefenseState(),
//     liveWebSocketPath: "/game/hero-defense",
//     configuration: heroDefenseServerConfig,
//     reevaluation: reevaluationFeature
// )
```

> **Note:** `HeroDefenseState` needs `StateFromSnapshotDecodable` conformance, which requires all its `@Sync(.broadcast)` field types (including `PlayerState`, `MonsterState`, `BaseState`, `TurretState`) to conform to `SnapshotValueDecodable` via `@SnapshotConvertible`. Verify each type has `@SnapshotConvertible` or add it. Do NOT touch `HeroDefenseState` itself — add separate `+SnapshotDecodable.swift` extension files if needed.

**Step 2: Run E2E test**

```bash
cd Tools/CLI && ./test-e2e-ci.sh
```

Or with a specific replay record:

```bash
cd Tools/CLI && npx tsx src/verify-replay-record.ts \
    --record reevaluation-records/hero-defense-*.json \
    --land-type hero-defense-replay
```

**Step 3: Commit if all pass**

```bash
git add Examples/GameDemo/Sources/GameServer/main.swift
git commit -m "feat: wire up GenericReplayLand for hero-defense via registerWithGenericReplay"
```

---

## Running All Tests

After completing all phases:

```bash
# All Swift tests
swift test

# TypeScript SDK tests
cd sdk/ts && npm test

# E2E tests (requires DemoServer running)
cd Tools/CLI && ./test-e2e-ci.sh
```

---

## Common Pitfalls

| Pitfall | Solution |
|---------|----------|
| Macro expansion test fails with unexpected output | Run once, read actual output, update `expandedSource` to match exactly |
| `_snapshotDecode` type inference fails | Ensure property has explicit type annotation; the compiler needs it to infer `T` |
| `IVec2` init: using Float init re-quantizes | Use the raw Int32 internal init `IVec2(x:y:)` with explicit Int32 casting |
| `actualState.base` is nil or wrong type | Read `AnyCodable` source to confirm how base value is accessed |
| Dictionary conditional conformance not resolved | Ensure both Key and Value types are in scope and imported where the conformance is needed |
| `@StateNodeBuilder` macro test: expanded source too long | Use `assertMacroExpansion` with `indentationWidth:` parameter; or test only the new extension separately using `#externalMacro` |
