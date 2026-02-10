# Incremental State Update Generation - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Generate state patches at mutation time instead of computing diff at sync time, reducing sync complexity from O(state_size) to O(mutation_count).

**Architecture:** 
- Add `PatchRecorder` class to accumulate patches during mutations
- Inject path context via `ReactiveDictionary` subscript getter (reference type propagation)
- Modify `@StateNodeBuilder` macro to generate `_$parentPath` and `_$patchRecorder` properties
- Integrate with existing sync flow using accumulated patches

**Tech Stack:** Swift 6, Swift Macros, SwiftSyntax, Swift Testing

---

## Phase 1: Core Infrastructure

### Task 1: Create PatchRecorder Protocol and Implementation

**Files:**
- Create: `Sources/SwiftStateTree/Sync/PatchRecorder.swift`
- Test: `Tests/SwiftStateTreeTests/PatchRecorderTests.swift`

**Step 1: Write the failing test**

```swift
// Tests/SwiftStateTreeTests/PatchRecorderTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

@Test("PatchRecorder records patches and takes them")
func testPatchRecorder_RecordAndTake() {
    // Arrange
    let recorder = LandPatchRecorder()
    
    // Act
    recorder.record(StatePatch(path: "/score", operation: .set(.int(100))))
    recorder.record(StatePatch(path: "/players/A/health", operation: .set(.int(90))))
    
    // Assert
    #expect(recorder.hasPatches == true)
    let patches = recorder.takePatches()
    #expect(patches.count == 2)
    #expect(patches[0].path == "/score")
    #expect(patches[1].path == "/players/A/health")
    
    // After take, should be empty
    #expect(recorder.hasPatches == false)
    #expect(recorder.takePatches().isEmpty == true)
}

@Test("PatchRecorder takePatches preserves capacity")
func testPatchRecorder_TakePreservesCapacity() {
    // Arrange
    let recorder = LandPatchRecorder()
    
    // Record many patches
    for i in 0..<100 {
        recorder.record(StatePatch(path: "/field\(i)", operation: .set(.int(i))))
    }
    
    // Act
    _ = recorder.takePatches()
    
    // Record again - should not need reallocation
    recorder.record(StatePatch(path: "/new", operation: .set(.int(999))))
    
    // Assert
    #expect(recorder.hasPatches == true)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter PatchRecorderTests`
Expected: FAIL - "cannot find 'LandPatchRecorder' in scope"

**Step 3: Write minimal implementation**

```swift
// Sources/SwiftStateTree/Sync/PatchRecorder.swift

import Foundation

/// Protocol for accumulating state patches during mutations.
///
/// Implementations should be reference types to enable patch recording
/// across struct copies (Swift COW semantics).
public protocol PatchRecorder: AnyObject {
    /// Record a single patch.
    func record(_ patch: StatePatch)
    
    /// Take all accumulated patches and clear the internal buffer.
    /// - Returns: All patches recorded since last take.
    func takePatches() -> [StatePatch]
    
    /// Check if there are any patches accumulated.
    var hasPatches: Bool { get }
}

/// Land-scoped patch recorder.
///
/// Thread-safety: Not required because all mutations happen synchronously
/// within the `LandKeeper` actor. Only one action handler executes at a time.
public final class LandPatchRecorder: PatchRecorder {
    private var patches: [StatePatch] = []
    
    public init() {}
    
    public func record(_ patch: StatePatch) {
        patches.append(patch)
    }
    
    public func takePatches() -> [StatePatch] {
        let result = patches
        patches.removeAll(keepingCapacity: true)
        return result
    }
    
    public var hasPatches: Bool {
        !patches.isEmpty
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter PatchRecorderTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Sync/PatchRecorder.swift Tests/SwiftStateTreeTests/PatchRecorderTests.swift
git commit -m "feat: add PatchRecorder for incremental state updates"
```

---

### Task 2: Create PatchableState Protocol

**Files:**
- Create: `Sources/SwiftStateTree/Sync/PatchableState.swift`

**Step 1: Write implementation (no test needed - protocol only)**

```swift
// Sources/SwiftStateTree/Sync/PatchableState.swift

import Foundation

/// Protocol for state types that support incremental patch recording.
///
/// Types conforming to this protocol can receive path context injection
/// from parent containers (like `ReactiveDictionary`) to enable
/// automatic patch recording during mutations.
///
/// This protocol is automatically conformed by `@StateNodeBuilder` macro.
public protocol PatchableState {
    /// The JSON Pointer path to this state node from the root.
    /// Injected by parent container during access.
    var _$parentPath: String { get set }
    
    /// Reference to the shared patch recorder.
    /// Injected by parent container during access.
    var _$patchRecorder: PatchRecorder? { get set }
}
```

**Step 2: Run build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/SwiftStateTree/Sync/PatchableState.swift
git commit -m "feat: add PatchableState protocol for path context injection"
```

---

## Phase 2: ReactiveDictionary Integration

### Task 3: Add Path Context Properties to ReactiveDictionary

**Files:**
- Modify: `Sources/SwiftStateTree/State/ReactiveDictionary.swift`
- Test: `Tests/SwiftStateTreeTests/ReactiveDictionaryTests.swift`

**Step 1: Write the failing test**

Add to `Tests/SwiftStateTreeTests/ReactiveDictionaryTests.swift`:

```swift
// MARK: - Patch Recording Tests

/// Test state for patch recording
struct TestPatchableState: PatchableState {
    var _$parentPath: String = ""
    var _$patchRecorder: PatchRecorder? = nil
    var value: Int = 0
}

@Test("ReactiveDictionary subscript get injects path context into PatchableState")
func testReactiveDictionary_SubscriptGet_InjectsPathContext() {
    // Arrange
    var dict = ReactiveDictionary<String, TestPatchableState>()
    dict._$parentPath = "/players"
    let recorder = LandPatchRecorder()
    dict._$patchRecorder = recorder
    
    // Set up initial value
    dict["A"] = TestPatchableState(value: 100)
    dict.clearDirty()
    
    // Act
    let retrieved = dict["A"]
    
    // Assert
    #expect(retrieved != nil)
    #expect(retrieved?._$parentPath == "/players/A")
    #expect(retrieved?._$patchRecorder === recorder)
}

@Test("ReactiveDictionary subscript set records patch")
func testReactiveDictionary_SubscriptSet_RecordsPatch() {
    // Arrange
    var dict = ReactiveDictionary<String, Int>()
    dict._$parentPath = "/scores"
    let recorder = LandPatchRecorder()
    dict._$patchRecorder = recorder
    
    // Act
    dict["player1"] = 100
    
    // Assert
    #expect(recorder.hasPatches == true)
    let patches = recorder.takePatches()
    #expect(patches.count == 1)
    #expect(patches[0].path == "/scores/player1")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter "ReactiveDictionary.*PathContext\|ReactiveDictionary.*RecordsPatch"`
Expected: FAIL - "_$parentPath" not found

**Step 3: Modify ReactiveDictionary**

Edit `Sources/SwiftStateTree/State/ReactiveDictionary.swift`:

```swift
// Add after line 30 (after onChange property):

    // MARK: - Patch Recording Context
    
    /// Path to this dictionary from root state.
    /// Injected by parent container or LandKeeper.
    public var _$parentPath: String = ""
    
    /// Shared patch recorder reference.
    /// Injected by parent container or LandKeeper.
    public var _$patchRecorder: PatchRecorder? = nil
```

```swift
// Replace subscript (lines 50-61) with:

    /// Accesses the value associated with the given key for reading and writing.
    ///
    /// - Getting: Returns the value with injected path context if it's a `PatchableState`.
    /// - Setting: Marks the dictionary as dirty, records patch, and triggers onChange.
    public subscript(key: Key) -> Value? {
        get {
            guard var value = _storage[key] else { return nil }
            
            // Inject path context for PatchableState values
            if var patchable = value as? (any PatchableState) {
                patchable._$parentPath = "\(_$parentPath)/\(key)"
                patchable._$patchRecorder = _$patchRecorder
                // Cast back - this works because PatchableState is a protocol
                if let castedValue = patchable as? Value {
                    return castedValue
                }
            }
            return value
        }
        set {
            _storage[key] = newValue
            _isDirty = true
            _dirtyKeys.insert(key)
            
            // Record patch if recorder is available
            if let recorder = _$patchRecorder {
                let path = "\(_$parentPath)/\(key)"
                if let newValue = newValue {
                    // Convert value to SnapshotValue
                    // For now, use AnyCodable wrapper
                    let snapshotValue = SnapshotValue.from(AnyCodable(newValue))
                    recorder.record(StatePatch(path: path, operation: .set(snapshotValue)))
                } else {
                    recorder.record(StatePatch(path: path, operation: .delete))
                }
            }
            
            onChange?()
        }
    }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter "ReactiveDictionary.*PathContext\|ReactiveDictionary.*RecordsPatch"`
Expected: PASS

**Step 5: Run all ReactiveDictionary tests**

Run: `swift test --filter ReactiveDictionaryTests`
Expected: All PASS

**Step 6: Commit**

```bash
git add Sources/SwiftStateTree/State/ReactiveDictionary.swift Tests/SwiftStateTreeTests/ReactiveDictionaryTests.swift
git commit -m "feat: add path context injection to ReactiveDictionary"
```

---

### Task 4: Update mutateValue to Propagate Path Context

**Files:**
- Modify: `Sources/SwiftStateTree/State/ReactiveDictionary.swift`
- Test: `Tests/SwiftStateTreeTests/ReactiveDictionaryTests.swift`

**Step 1: Write the failing test**

Add to `Tests/SwiftStateTreeTests/ReactiveDictionaryTests.swift`:

```swift
@Test("ReactiveDictionary mutateValue injects path context during mutation")
func testReactiveDictionary_MutateValue_InjectsPathContext() {
    // Arrange
    var dict = ReactiveDictionary<String, TestPatchableState>()
    dict._$parentPath = "/players"
    let recorder = LandPatchRecorder()
    dict._$patchRecorder = recorder
    
    dict["A"] = TestPatchableState(value: 100)
    _ = recorder.takePatches() // Clear initial set patch
    
    // Act
    var capturedPath: String = ""
    var capturedRecorder: PatchRecorder? = nil
    
    dict.mutateValue(for: "A") { state in
        capturedPath = state._$parentPath
        capturedRecorder = state._$patchRecorder
        state.value = 200
    }
    
    // Assert
    #expect(capturedPath == "/players/A")
    #expect(capturedRecorder === recorder)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter "mutateValue_InjectsPathContext"`
Expected: FAIL - path not injected

**Step 3: Modify mutateValue**

Edit `Sources/SwiftStateTree/State/ReactiveDictionary.swift`, replace lines 103-110:

```swift
    /// Safely mutates a value for the given key with path context injection.
    ///
    /// If the value conforms to `PatchableState`, path context is injected
    /// before the mutation closure is called, enabling automatic patch recording.
    ///
    /// - Parameters:
    ///   - key: The key to mutate
    ///   - body: Closure that mutates the value
    public mutating func mutateValue(for key: Key, _ body: (inout Value) -> Void) {
        guard var value = _storage[key] else { return }
        
        // Inject path context for PatchableState values
        if var patchable = value as? (any PatchableState) {
            patchable._$parentPath = "\(_$parentPath)/\(key)"
            patchable._$patchRecorder = _$patchRecorder
            if let castedValue = patchable as? Value {
                value = castedValue
            }
        }
        
        body(&value)
        
        _storage[key] = value
        _isDirty = true
        _dirtyKeys.insert(key)
        onChange?()
    }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter "mutateValue_InjectsPathContext"`
Expected: PASS

**Step 5: Run all ReactiveDictionary tests**

Run: `swift test --filter ReactiveDictionaryTests`
Expected: All PASS

**Step 6: Commit**

```bash
git add Sources/SwiftStateTree/State/ReactiveDictionary.swift Tests/SwiftStateTreeTests/ReactiveDictionaryTests.swift
git commit -m "feat: inject path context in ReactiveDictionary.mutateValue"
```

---

## Phase 3: Macro Integration (Complex)

### Task 5: Research Macro Generation Patterns

**Files:**
- Read: `Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift`

**Step 1: Study existing macro patterns**

Read and understand:
1. How `_propertyName` storage is generated
2. How `getSyncFields()` is generated  
3. How `isDirty()` / `clearDirty()` are generated

**Step 2: Document findings**

Create notes in the plan about:
- Where to add `_$parentPath` and `_$patchRecorder` generation
- How to generate path-aware setters

**Step 3: No commit needed (research only)**

---

### Task 6: Generate _$parentPath and _$patchRecorder Properties

**Files:**
- Modify: `Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift`
- Test: `Tests/SwiftStateTreeMacrosTests/StateNodeBuilderMacroTests.swift` (if exists)

**Step 1: Add property generation**

In `StateNodeBuilderMacro.swift`, add to the `expansion` function return array:

```swift
// Add before return statement in expansion():

// Generate _$parentPath property
let parentPathProperty = try VariableDeclSyntax(
    """
    public var _$parentPath: String = ""
    """
)

// Generate _$patchRecorder property
let patchRecorderProperty = try VariableDeclSyntax(
    """
    public var _$patchRecorder: PatchRecorder? = nil
    """
)

// Return array should include these
return [
    DeclSyntax(parentPathProperty),
    DeclSyntax(patchRecorderProperty),
    DeclSyntax(getSyncFieldsMethod),
    // ... existing items
]
```

**Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 3: Test with a sample StateNode**

Create a test that uses `@StateNodeBuilder` and verifies the properties exist.

**Step 4: Commit**

```bash
git add Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift
git commit -m "feat: generate _\$parentPath and _\$patchRecorder in @StateNodeBuilder"
```

---

### Task 7: Generate PatchableState Conformance

**Files:**
- Modify: `Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift`

**Step 1: Add extension conformance**

The macro needs to also generate a conformance extension:

```swift
// In StateNodeBuilderMacro, implement ExtensionMacro protocol

extension StateNodeBuilderMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let patchableConformance = try ExtensionDeclSyntax(
            """
            extension \(type): PatchableState {}
            """
        )
        return [patchableConformance]
    }
}
```

**Step 2: Update macro plugin registration**

Ensure the macro is registered with both `MemberMacro` and `ExtensionMacro` capabilities.

**Step 3: Build and test**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift
git commit -m "feat: add PatchableState conformance in @StateNodeBuilder"
```

---

## Phase 4: LandKeeper Integration

### Task 8: Initialize PatchRecorder in LandKeeper

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/LandKeeper.swift`
- Test: `Tests/SwiftStateTreeTests/LandKeeperTests.swift` (create if needed)

**Step 1: Add PatchRecorder property**

In `LandKeeper.swift`, add after existing properties:

```swift
/// Patch recorder for incremental state updates.
private let patchRecorder = LandPatchRecorder()
```

**Step 2: Inject into state at initialization**

Find where state is initialized and add:

```swift
// After state initialization
state._$parentPath = ""
state._$patchRecorder = patchRecorder
```

**Step 3: Build and test**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/LandKeeper.swift
git commit -m "feat: initialize PatchRecorder in LandKeeper"
```

---

### Task 9: Create Integration Test

**Files:**
- Create: `Tests/SwiftStateTreeTests/IncrementalPatchTests.swift`

**Step 1: Write end-to-end test**

```swift
// Tests/SwiftStateTreeTests/IncrementalPatchTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// Test state with nested structure
@StateNodeBuilder
struct IncrementalTestState: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var players: ReactiveDictionary<String, TestPlayerState> = .init()
}

@StateNodeBuilder
struct TestPlayerState: StateNodeProtocol {
    @Sync(.broadcast) var health: Int = 100
    @Sync(.broadcast) var name: String = ""
}

@Test("Incremental patch generation for root field")
func testIncrementalPatch_RootField() async throws {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = IncrementalTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    
    // Act
    state.score = 100
    
    // Assert
    let patches = recorder.takePatches()
    #expect(patches.count == 1)
    #expect(patches[0].path == "/score")
}

@Test("Incremental patch generation for nested field via mutateValue")
func testIncrementalPatch_NestedField() async throws {
    // Arrange
    let recorder = LandPatchRecorder()
    var state = IncrementalTestState()
    state._$parentPath = ""
    state._$patchRecorder = recorder
    
    // Add a player
    state.players["A"] = TestPlayerState(health: 100, name: "Alice")
    _ = recorder.takePatches() // Clear
    
    // Act
    state.players.mutateValue(for: "A") { player in
        player.health = 50
    }
    
    // Assert
    let patches = recorder.takePatches()
    #expect(patches.count >= 1)
    // Should have patch for /players/A/health
    let healthPatch = patches.first { $0.path == "/players/A/health" }
    #expect(healthPatch != nil)
}
```

**Step 2: Run test**

Run: `swift test --filter IncrementalPatchTests`
Expected: PASS (after macro changes)

**Step 3: Commit**

```bash
git add Tests/SwiftStateTreeTests/IncrementalPatchTests.swift
git commit -m "test: add integration tests for incremental patch generation"
```

---

## Phase 5: Sync Integration (Future)

### Task 10: Use Accumulated Patches in Sync Flow

**Note:** This task is more complex and may require additional design work.

**Files:**
- Modify: Transport layer sync implementation (location TBD)

**Step 1: Identify sync entry point**

Find where `syncNowFromTransport()` is implemented.

**Step 2: Add patch-based sync path**

```swift
// Pseudocode
func syncNow() async {
    let patches = await landKeeper.takeAccumulatedPatches()
    
    if !patches.isEmpty {
        // Fast path: use accumulated patches
        await sendPatches(patches)
    } else {
        // Fallback: use computeDiff (for compatibility)
        await computeAndSendDiff()
    }
}
```

**Step 3: Expose patch recorder from LandKeeper**

Add method to `LandKeeper`:

```swift
public func takeAccumulatedPatches() -> [StatePatch] {
    patchRecorder.takePatches()
}
```

**Step 4: Test and commit**

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| 1. Core Infrastructure | Tasks 1-2 | Ready |
| 2. ReactiveDictionary | Tasks 3-4 | Ready |
| 3. Macro Integration | Tasks 5-7 | Complex - needs research |
| 4. LandKeeper Integration | Tasks 8-9 | Ready after Phase 3 |
| 5. Sync Integration | Task 10 | Future - needs design |

## Testing Commands

```bash
# Run all new tests
swift test --filter "PatchRecorder\|ReactiveDictionary.*Patch\|IncrementalPatch"

# Run full test suite
swift test

# Run E2E tests (after all changes)
cd Tools/CLI && npm test
```

## Rollback Plan

If issues are found:
1. Revert macro changes first (most likely source of issues)
2. Keep PatchRecorder and PatchableState (safe additions)
3. ReactiveDictionary changes are backward compatible

---

## Additional Requirement (2026-02-07)

Add a compile-time macro guard in `@StateNodeBuilder` to reject containers that cannot be reliably tracked by incremental patching.

Planned rule (default):
- Disallow plain Swift containers in `@Sync` fields when used for mutable state graphs that need fine-grained patch tracking:
  - `[Key: Value]` (Dictionary)
  - `[Element]` (Array)
  - `Set<Element>`
- Allow reactive containers:
  - `ReactiveDictionary<Key, Value>`
  - `ReactiveSet<Element>`

Implementation notes:
- Emit a macro diagnostic error with actionable guidance (e.g., "Use `ReactiveDictionary`/`ReactiveSet` or explicit update methods").
- Add macro tests for both reject and allow cases.

---

## Two-path separation and validate mode (2026-02-07)

**Requirement:** Use incremental as the primary path; keep diff path separate (fallback or verification only).

**Implemented:**

1. **IncrementalSyncMode**
   - `on`: Use incremental for broadcast when patches exist and pass safety check; otherwise fall back to diff. Two paths are separate in code (incremental path vs diff path).
   - `validate`: Same as `on`, but also compute diff-based broadcast diff and log a warning when it differs from the incremental result (correctness verification). Env: `SST_INCREMENTAL_SYNC_MODE=validate`.

2. **Code structure (TransportAdapter sync)**
   - `needDiffPath = (incrementalBroadcastDiff == nil) || (incrementalSyncMode == .validate)`.
   - Diff path: `diffBasedBroadcastDiff = computeBroadcastDiffFromSnapshot(...)` only when `needDiffPath`.
   - Broadcast diff for send: `broadcastDiff = incrementalBroadcastDiff ?? diffBasedBroadcastDiff`.
   - When using incremental: `updateBroadcastCacheFromSnapshot(...)` so cache matches sent state.
   - When `validate` and incremental was used: compare sorted patch arrays; log warning with path sets if they differ.
