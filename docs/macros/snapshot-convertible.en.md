[English](snapshot-convertible.en.md) | [中文版](snapshot-convertible.md)

# @SnapshotConvertible Performance Optimization Guide

> `@SnapshotConvertible` macro automatically generates `SnapshotValueConvertible` implementation, avoiding runtime reflection (Mirror), significantly improving conversion performance.

## Overview

`@SnapshotConvertible` is SwiftStateTree's performance optimization macro, used to mark types that need high-performance conversion. It automatically generates `SnapshotValueConvertible` protocol implementation, completely avoiding runtime reflection.

### Core Advantages

- **Avoid Mirror**: Don't use runtime reflection, significantly improve performance
- **Compile-time generation**: Type-safe, reduce runtime errors
- **Auto-generation**: Just mark, no need to write code manually
- **Recursive optimization**: Nested structures prioritize protocol checking, completely avoid Mirror

## Basic Usage

### Mark Types

```swift
import SwiftStateTree

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

### Generated Code

Macro automatically generates the following extension:

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

extension Position: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "x": .double(x),
            "y": .double(y)
        ])
    }
}
```

## Performance Advantages

### Comparison with Mirror

Using `@SnapshotConvertible` can significantly improve conversion performance:

| Method | Conversion Time | Description |
|------|---------|------|
| **@SnapshotConvertible** | ~0.15ms | Compile-time generation, direct conversion |
| **Mirror (runtime reflection)** | ~0.38ms | Uses runtime reflection, slower |

**Performance improvement**: Approximately **2.5x** performance improvement (based on actual tests)

### Conversion Priority

`SnapshotValue.make(from:)` processes in the following priority order:

1. **Priority 1: SnapshotValueConvertible** (best performance)
   - Check if implements `SnapshotValueConvertible`
   - Directly call `toSnapshotValue()`, completely avoid Mirror

2. **Priority 2: Basic types** (good performance)
   - String, Int, Bool, and other basic types convert directly

3. **Priority 3: Mirror fallback** (ensures complete functionality)
   - Other types use Mirror as fallback

```swift
// Internal implementation (simplified)
public extension SnapshotValue {
    static func make(from value: Any) throws -> SnapshotValue {
        // Priority 1: Check protocol (best performance)
        if let convertible = value as? SnapshotValueConvertible {
            return try convertible.toSnapshotValue()  // Completely avoid Mirror
        }
        
        // Priority 2: Handle basic types
        if let string = value as? String {
            return .string(string)
        }
        // ...
        
        // Priority 3: Fallback to Mirror
        // ...
    }
}
```

## Applicable Scenarios

### ✅ Recommended Use

1. **Frequently converted types**: Nested structures frequently used in StateTree
2. **Complex nested structures**: Multi-level nested structures
3. **Performance-critical paths**: Types that need high-performance conversion

### ❌ Not Needed

1. **Basic types**: String, Int, Bool, etc. are already optimized
2. **Simple types**: Simple structures with only one or two fields may not need it
3. **Rarely converted types**: Types that are rarely converted

## Usage Examples

### Example 1: Basic Usage

```swift
@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

// Use in StateNode
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // PlayerState uses @SnapshotConvertible
}
```

### Example 2: Nested Structures

```swift
@SnapshotConvertible
struct Position: Codable, Sendable {
    var x: Double
    var y: Double
}

@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var position: Position  // Nested structure
    var inventory: [Item]   // Array
}

@SnapshotConvertible
struct Item: Codable, Sendable {
    var id: String
    var name: String
    var count: Int
}
```

### Example 3: Complex Structures

```swift
@SnapshotConvertible
struct Card: Codable, Sendable {
    var id: String
    var name: String
    var cost: Int
    var effects: [Effect]
}

@SnapshotConvertible
struct Effect: Codable, Sendable {
    var type: String
    var value: Int
}

@SnapshotConvertible
struct HandState: Codable, Sendable {
    var cards: [Card]  // Nested array
    var ownerID: PlayerID
}
```

## Generated Conversion Logic

### Basic Types

For basic types, macro generates direct conversion:

```swift
@SnapshotConvertible
struct SimpleState: Codable {
    var name: String
    var count: Int
    var isActive: Bool
}

// Generated (simplified)
extension SimpleState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "name": .string(name),        // Direct conversion
            "count": .int(count),         // Direct conversion
            "isActive": .bool(isActive)   // Direct conversion
        ])
    }
}
```

### Optional Types

For optional types, use `SnapshotValue.make(from:)` to handle:

```swift
@SnapshotConvertible
struct OptionalState: Codable {
    var name: String?
    var count: Int?
}

// Generated (simplified)
extension OptionalState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "name": try SnapshotValue.make(from: name),   // Handle nil
            "count": try SnapshotValue.make(from: count)  // Handle nil
        ])
    }
}
```

### Nested Structures

For nested structures, recursively call `toSnapshotValue()`:

```swift
@SnapshotConvertible
struct NestedState: Codable {
    var position: Position
    var items: [Item]
}

// Generated (simplified)
extension NestedState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "position": try position.toSnapshotValue(),  // Recursive processing
            "items": try SnapshotValue.make(from: items) // Array processing
        ])
    }
}
```

## Performance Test Results

Based on actual tests (single core, 100 iterations):

| Scenario | Using Mirror | Using @SnapshotConvertible | Performance Improvement |
|------|------------|---------------------------|---------|
| Tiny (5 players, 3 cards) | 0.378ms | 0.154ms | **2.45x** |
| Small (10 players, 5 cards) | 0.306ms | 0.167ms | **1.83x** |
| Medium (100 players, 10 cards) | 1.768ms | 0.935ms | **1.89x** |

**Conclusion**: Using `@SnapshotConvertible` can achieve approximately **2x** performance improvement.

## Best Practices

### 1. Mark All Nested Structures

Ensure entire conversion path uses macro:

```swift
// ✅ Correct: All nested structures are marked
@SnapshotConvertible
struct PlayerState: Codable {
    var position: Position  // Position is also marked with @SnapshotConvertible
}

@SnapshotConvertible
struct Position: Codable {
    var x: Double
    var y: Double
}
```

### 2. Prefer Basic Types

Basic types are already optimized, no need for additional marking:

```swift
@SnapshotConvertible
struct SimpleState: Codable {
    var name: String      // ✅ Basic type, already optimized
    var count: Int        // ✅ Basic type, already optimized
    var isActive: Bool    // ✅ Basic type, already optimized
}
```

### 3. Avoid Overuse

Simple types may not need this macro:

```swift
// ⚠️ Consider: Simple structure with only one field
@SnapshotConvertible  // May not be needed
struct SimpleWrapper: Codable {
    var value: String
}
```

### 4. Types Frequently Used in StateTree

Prioritize marking types frequently used in StateTree:

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // PlayerState should be marked @SnapshotConvertible
    
    @Sync(.broadcast)
    var items: [ItemID: Item] = [:]  // Item should be marked @SnapshotConvertible
}
```

## Common Questions

### Q: When should @SnapshotConvertible be used?

A: Recommended when types meet the following conditions:
- Frequently used in StateTree
- Contains multiple fields or nested structures
- Needs high-performance conversion

### Q: What happens if not marked?

A: Unmarked types will use Mirror as fallback, worse performance but functionally complete.

### Q: Can SnapshotValueConvertible be manually implemented?

A: Yes, but recommend using macro auto-generation to avoid manual errors.

### Q: Do nested structures all need marking?

A: Recommend marking all nested structures to ensure entire conversion path uses macro.

## Related Documentation

- [Macros Overview](README.en.md) - Understand usage of all macros
- [StateNode Definition](../core/README.en.md) - Understand StateNode usage
- [Sync Rules](../core/sync.en.md) - Understand state synchronization mechanism
