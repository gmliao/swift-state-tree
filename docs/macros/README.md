[English](README.md) | [中文版](README.zh-TW.md)

# Macros

SwiftStateTree provides three main macros for generating metadata and improving performance.

## Design Notes

Macros execute at compile time, providing the following advantages:

- **Reduce runtime costs**: Generate metadata at compile time, avoid runtime reflection
- **Early validation**: Compile-time error checking, avoid runtime errors
- **Type safety**: Compile-time type checking, ensure correctness
- **Auto-generation**: Reduce handwritten code, lower error rate

## @StateNodeBuilder

`@StateNodeBuilder` is used to mark **StateTree nodes** (StateNode), automatically generating necessary metadata and validation logic.

### Functions

- **Validation rules**: Ensure all stored properties are marked with `@Sync` or `@Internal`
- **Generate sync metadata**: Generate `getSyncFields()` method
- **Generate dirty tracking**: Generate `isDirty()`, `getDirtyFields()`, `clearDirty()` methods
- **Generate snapshot methods**: Generate `snapshot(for:)` and `broadcastSnapshot()` methods

### Use Cases

`@StateNodeBuilder` is used to define **state tree nodes**, which need to:
- Define sync rules (which fields sync to which players)
- Act as root or child nodes of StateTree
- Need dirty tracking and snapshot functionality

**Example**: `GameState` is root state, needs to define sync rules

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)  // Need to define sync rules
    var players: [PlayerID: PlayerState] = [:]
}
```

### Usage Examples

```swift
import SwiftStateTree

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    // Must mark with @Sync or @Internal
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: HandState] = [:]
    
    @Sync(.serverOnly)
    var hiddenDeck: [Card] = []
    
    @Internal
    var lastProcessedTimestamp: Date = Date()
    
    // Computed properties don't need marking
    var totalPlayers: Int {
        players.count
    }
}
```

### Validation Rules

- ✅ **Stored properties**: Must be marked with `@Sync` or `@Internal`
- ✅ **Computed properties**: Automatically skip validation
- ❌ **Unmarked stored properties**: Compile error

### Common Errors

#### Error 1: Forgot to mark stored property

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    var score: Int = 0  // ❌ Compile error: Must mark with @Sync or @Internal
}
```

**Solution**:

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.broadcast)  // ✅ Correct
    var score: Int = 0
}
```

#### Error 2: Using on class

```swift
@StateNodeBuilder  // ❌ Compile error: Only supports struct
class GameState: StateNodeProtocol {
    // ...
}
```

**Solution**: Use `struct` instead of `class`.

### Best Practices

1. **Explicitly mark all stored properties**: Don't miss any fields
2. **Use `@Internal` appropriately**: Use `@Internal` for internal calculation fields
3. **Use `@Sync(.serverOnly)` instead of `@Internal`**: If sync engine needs to know but not sync to client

## @Payload

`@Payload` is used to mark Action, Event, and Response payloads, automatically generating metadata.

### Functions

- **Generate field metadata**: Generate `getFieldMetadata()` method
- **Generate response type**: Action payloads additionally generate `getResponseType()` method
- **Schema generation**: Used for automatic JSON Schema generation

### Usage Examples

#### Action Payload

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
    let deviceID: String?
}

@Payload
struct JoinResponse: ResponsePayload {
    let success: Bool
    let message: String
    let landID: String?
}
```

#### Event Payload

```swift
@Payload
struct PlayerJoinedEvent: ServerEventPayload {
    let playerID: PlayerID
    let name: String
    let timestamp: Date
}

@Payload
struct ChatMessageEvent: ClientEventPayload {
    let playerID: PlayerID
    let message: String
    let timestamp: Date
}
```

### Generated Code

Macro automatically generates the following methods:

```swift
// Auto-generated (simplified)
extension JoinAction {
    static func getFieldMetadata() -> [FieldMetadata] {
        return [
            FieldMetadata(name: "playerID", type: "PlayerID"),
            FieldMetadata(name: "name", type: "String"),
            FieldMetadata(name: "deviceID", type: "String?")
        ]
    }
    
    static func getResponseType() -> Any.Type {
        return JoinResponse.self
    }
}
```

### Common Errors

#### Error 1: Forgot to mark @Payload

```swift
// ❌ Error: Not marked with @Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
}

// Will trap at runtime
let responseType = JoinAction.getResponseType()  // ❌ Runtime error
```

**Solution**:

```swift
@Payload  // ✅ Correct
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
}
```

#### Error 2: Action didn't define Response

```swift
@Payload
struct JoinAction: ActionPayload {
    // ❌ Error: ActionPayload must define Response
    let playerID: PlayerID
}
```

**Solution**:

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse  // ✅ Correct
    let playerID: PlayerID
}
```

### Best Practices

1. **Mark all Payloads with `@Payload`**: Ensure metadata is correctly generated
2. **Use explicit types**: Avoid using `Any` or overly generic types
3. **Keep Payloads simple**: Avoid overly complex nested structures

## @SnapshotConvertible

`@SnapshotConvertible` is used to mark **nested data structures**, automatically generating `SnapshotValueConvertible` implementation to optimize conversion performance.

### Functions

- **Auto-generate conversion methods**: Generate `toSnapshotValue()` method
- **Avoid runtime reflection**: Don't use Mirror, significantly improve performance
- **Support nested structures**: Automatically handle nested `@SnapshotConvertible` types

### Use Cases

`@SnapshotConvertible` is used for **value types nested in StateNode**, these types:
- **As property containers**: Encapsulate related state properties, organize into meaningful data structures
- **Don't need sync rules**: Sync rules are determined by parent StateNode's `@Sync`
- **Only need high-performance conversion**: Optimize serialization performance
- **Are value types**: Nested in dictionaries, arrays, and other containers

**Example**: `PlayerState` is a value nested in `GameState.players` dictionary, as a container for player properties

```swift
// PlayerState as container for player properties
@SnapshotConvertible  // Doesn't need StateNodeProtocol
struct PlayerState: Codable, Sendable {
    var name: String        // Player name
    var hpCurrent: Int      // Current HP
    var hpMax: Int          // Max HP
    var position: Position  // Position (also a property container)
}

// Position as container for position properties
@SnapshotConvertible
struct Position: Codable, Sendable {
    var x: Double  // X coordinate
    var y: Double  // Y coordinate
}
```

**Key Differences**:
- `@StateNodeBuilder`: Used for **state tree nodes**, need to define sync rules
- `@SnapshotConvertible`: Used for **property containers/data structures**, encapsulate related properties, only need conversion performance optimization

**Design Philosophy**:
- `@SnapshotConvertible` organizes related properties into meaningful containers (like `PlayerState`, `Position`, `Item`)
- These containers as value types can be nested in StateNode's dictionaries, arrays, and other collections
- Sync rules are unified managed by parent StateNode's `@Sync`, containers themselves don't need to define sync rules

### Usage Examples

#### Basic Usage

```swift
@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
    var position: Position
}

@SnapshotConvertible
struct Position: Codable, Sendable {
    var x: Double
    var y: Double
}
```

#### Using in StateNode

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // PlayerState as property container, uses @SnapshotConvertible
    
    @Sync(.broadcast)
    var items: [ItemID: Item] = [:]  // Item is also a property container
}

// PlayerState as container for player properties
@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
    var position: Position
}

// Item as container for item properties
@SnapshotConvertible
struct Item: Codable, Sendable {
    var id: String
    var name: String
    var count: Int
}
```

**Important Differences**:

- **`@StateNodeBuilder + StateNodeProtocol`**: Used for **state tree nodes** (like `GameState`), need to define sync rules (`@Sync`)
- **`@SnapshotConvertible`**: Used for **property containers/data structures** (like `PlayerState`, `Item`), encapsulate related properties, only need high-performance conversion

**Why doesn't `PlayerState` need `StateNodeProtocol`?**

1. **It's a property container**: `PlayerState` encapsulates player-related properties (name, hp, position), as a value type container
2. **Sync rules determined by parent**: `GameState.players`'s `@Sync(.broadcast)` determines sync rules for the entire dictionary
3. **Only need conversion performance**: As a value type, only needs high-performance serialization, doesn't need independent sync rules

### Generated Code

Macro automatically generates:

```swift
// Auto-generated (simplified)
extension PlayerState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "name": .string(name),
            "hpCurrent": .int(hpCurrent),
            "hpMax": .int(hpMax),
            "position": try position.toSnapshotValue()  // Recursively process nested structures
        ])
    }
}
```

### Performance Advantages

Using `@SnapshotConvertible` can significantly improve conversion performance:

- **Avoid Mirror**: Don't use runtime reflection
- **Compile-time optimization**: Compiler can perform more optimizations
- **Type safety**: Compile-time checking, avoid runtime errors

### Applicable Scenarios

Recommended to use `@SnapshotConvertible` in the following scenarios:

- ✅ **Frequently converted types**: Nested structures frequently used in StateTree
- ✅ **Complex nested structures**: Multi-level nested structures
- ✅ **Performance-critical paths**: Types that need high-performance conversion

### Common Errors

#### Error 1: Forgot to mark nested structures

```swift
@SnapshotConvertible
struct PlayerState: Codable {
    var name: String
    var position: Position  // ❌ Position not marked with @SnapshotConvertible
}

struct Position: Codable {  // Will use Mirror, worse performance
    var x: Double
    var y: Double
}
```

**Solution**:

```swift
@SnapshotConvertible
struct PlayerState: Codable {
    var name: String
    var position: Position
}

@SnapshotConvertible  // ✅ Correct
struct Position: Codable {
    var x: Double
    var y: Double
}
```

#### Error 2: Using on protocol

```swift
@SnapshotConvertible  // ❌ Compile error: Only supports struct
protocol GameEntity {
    var id: String { get }
}
```

**Solution**: Use concrete struct types.

### Best Practices

1. **Mark all nested structures**: Ensure entire conversion path uses macro
2. **Prefer basic types**: String, Int, Bool, and other basic types are already optimized
3. **Avoid overuse**: Simple types may not need this macro

## Performance Impact

### @StateNodeBuilder

- **Compile-time cost**: Increases compile time (usually negligible)
- **Runtime cost**: Reduces runtime cost (avoids reflection)

### @Payload

- **Compile-time cost**: Increases compile time (usually negligible)
- **Runtime cost**: Reduces runtime cost (avoids reflection)

### @SnapshotConvertible

- **Compile-time cost**: Increases compile time (usually negligible)
- **Runtime cost**: Significantly reduces runtime cost (avoids Mirror)

**Performance Test Results** (reference):

- Using `@SnapshotConvertible`: Conversion time is approximately 1/10 of using Mirror
- For complex nested structures, performance improvement is more significant

## Related Documentation

- [StateNode Definition](../core/README.md) - Understand StateNode usage
- [Sync Rules](../core/sync.md) - Understand `@Sync` usage
- [Schema Generation](../schema/README.md) - Understand schema generation mechanism
