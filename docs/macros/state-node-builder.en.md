[English](state-node-builder.en.md) | [中文版](state-node-builder.md)

# @StateNodeBuilder Detailed Guide

> `@StateNodeBuilder` is SwiftStateTree's core macro, used to mark and validate StateNode, automatically generating necessary metadata and methods.

## Overview

`@StateNodeBuilder` macro performs the following operations at compile time:

1. **Validation rules**: Ensure all stored properties are marked with `@Sync` or `@Internal`
2. **Generate sync metadata**: Generate `getSyncFields()` method
3. **Generate validation methods**: Generate `validateSyncFields()` method
4. **Generate snapshot methods**: Generate `snapshot(for:)` and `broadcastSnapshot()` methods
5. **Generate dirty tracking**: Generate `isDirty()`, `getDirtyFields()`, `clearDirty()` methods
6. **Generate field metadata**: Generate `getFieldMetadata()` method (for schema generation)

## Basic Usage

### Mark StateNode

```swift
import SwiftStateTree

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: HandState] = [:]
    
    @Sync(.serverOnly)
    var hiddenDeck: [Card] = []
    
    @Internal
    var lastProcessedTimestamp: Date = Date()
}
```

### Generated Code

Macro automatically generates the following methods (simplified):

```swift
// Auto-generated methods
extension GameState {
    // Get all @Sync fields
    func getSyncFields() -> [SyncFieldInfo] {
        return [
            SyncFieldInfo(name: "players", policyType: "broadcast"),
            SyncFieldInfo(name: "hands", policyType: "perPlayerSlice"),
            SyncFieldInfo(name: "hiddenDeck", policyType: "serverOnly")
        ]
    }
    
    // Validate all fields are marked
    func validateSyncFields() -> Bool {
        return true  // Validated at compile time
    }
    
    // Generate snapshot
    func snapshot(for playerID: PlayerID?) throws -> StateSnapshot {
        // Filter fields based on @Sync policy
        // ...
    }
    
    // Dirty tracking
    func isDirty() -> Bool { ... }
    func getDirtyFields() -> Set<String> { ... }
    mutating func clearDirty() { ... }
}
```

## Validation Rules

### Compile-Time Validation

`@StateNodeBuilder` performs strict validation at compile time:

#### ✅ Correct Marking

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)      // ✅ Correct
    var players: [PlayerID: PlayerState] = [:]
    
    @Internal              // ✅ Correct
    var tempData: String = ""
    
    var totalPlayers: Int {  // ✅ Computed property automatically skipped
        players.count
    }
}
```

#### ❌ Incorrect Marking

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    var score: Int = 0  // ❌ Compile error: Must mark with @Sync or @Internal
}
```

**Compile error message**:
```
error: Stored property 'score' in GameState must be marked with @Sync or @Internal
```

### Validation Rules Explained

1. **Stored properties**: Must be explicitly marked with `@Sync` or `@Internal`
2. **Computed properties**: Automatically skip validation, no marking needed
3. **Unmarked stored properties**: Compile error

## Generated Methods

### getSyncFields()

Get information for all fields marked with `@Sync`:

```swift
let fields = gameState.getSyncFields()
// Returns: [
//   SyncFieldInfo(name: "players", policyType: "broadcast"),
//   SyncFieldInfo(name: "hands", policyType: "perPlayerSlice")
// ]
```

### validateSyncFields()

Validate all stored properties are correctly marked:

```swift
let isValid = gameState.validateSyncFields()
// Returns: true (validated at compile time, always returns true)
```

### snapshot(for:)

Generate state snapshot for specific player:

```swift
// Generate snapshot for specific player
let snapshot = try gameState.snapshot(for: playerID)
// Only includes fields visible to that player (based on @Sync policy)

// Only generate broadcast fields
let broadcastSnapshot = try gameState.snapshot(for: nil)
```

### broadcastSnapshot(dirtyFields:)

High-performance broadcast snapshot generation:

```swift
// Only generate dirty broadcast fields
let dirtyFields = gameState.getDirtyFields()
let snapshot = try gameState.broadcastSnapshot(dirtyFields: dirtyFields)
```

## Dirty Tracking

### Mechanism Description

Dirty tracking is used to track which fields have been modified, optimizing sync performance:

- **Auto-marking**: Automatically mark as dirty when fields are modified
- **Batch clearing**: Can clear all dirty flags after sync completes
- **Performance optimization**: Only sync changed fields, reduce serialization costs

### Usage

```swift
// Check if there are changes
if gameState.isDirty() {
    // Get all dirty fields
    let dirtyFields = gameState.getDirtyFields()
    // Only sync changed fields
    try syncEngine.syncDirtyFields(gameState, dirtyFields: dirtyFields)
    
    // Clear dirty flags
    gameState.clearDirty()
}
```

### Auto-Marking

When fields are modified, they are automatically marked as dirty:

```swift
// Modify field
gameState.players[playerID] = newPlayer  // Automatically mark players as dirty

// Check
gameState.isDirty()  // true
gameState.getDirtyFields()  // Set(["players"])
```

## Nested Structure Support

### Recursive Processing

`@StateNodeBuilder` supports nested StateNodes:

```swift
@StateNodeBuilder
struct PlayerState: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String
    
    @Sync(.broadcast)
    var position: Position
}

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // Nested StateNode
}
```

When generating snapshots, nested structures are processed recursively:

```swift
// Will recursively process each PlayerState in players dictionary
let snapshot = try gameState.snapshot(for: playerID)
```

## Common Questions

### Q: Why must all stored properties be marked?

A: This ensures all state fields have explicit sync policies, avoiding accidental data leakage or bandwidth waste.

### Q: Do computed properties need marking?

A: No. Computed properties automatically skip validation because they don't store state.

### Q: Can @StateNodeBuilder be used on class?

A: No. `@StateNodeBuilder` only supports `struct` because StateNode must use value semantics.

### Q: How to handle optional types?

A: Optional types can be used normally, just need to mark with `@Sync` or `@Internal`:

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var optionalField: String? = nil  // ✅ Correct
}
```

## Best Practices

1. **Explicitly mark all fields**: Don't miss any stored properties
2. **Use @Internal appropriately**: Use `@Internal` for internal calculation fields
3. **Use @Sync(.serverOnly) instead of @Internal**: If sync engine needs to know but not sync to client
4. **Keep structure simple**: Avoid overly deep nested structures to improve performance

## Related Documentation

- [Macros Overview](README.en.md) - Understand usage of all macros
- [Sync Rules](../core/sync.en.md) - Deep dive into `@Sync` policies
- [StateNode Definition](../core/README.en.md) - Understand StateNode usage
