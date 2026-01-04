[English](payload.en.md) | [中文版](payload.md)

# @Payload Detailed Guide

> `@Payload` macro is used to mark Action, Event, and Response payloads, automatically generating field metadata and response type information.

## Overview

`@Payload` macro performs the following operations at compile time:

1. **Generate field metadata**: Generate `getFieldMetadata()` method
2. **Generate response type**: Action payloads additionally generate `getResponseType()` method
3. **Schema generation support**: Provide metadata for automatic JSON Schema generation

## Basic Usage

### Action Payload

```swift
import SwiftStateTree

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

### Event Payload

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

## Generated Code

### getFieldMetadata()

All `@Payload` types generate `getFieldMetadata()` method:

```swift
// Auto-generated (simplified)
extension JoinAction {
    static func getFieldMetadata() -> [FieldMetadata] {
        return [
            FieldMetadata(
                name: "playerID",
                type: PlayerID.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "name",
                type: String.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "deviceID",
                type: String?.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: SnapshotValue.null
            )
        ]
    }
}
```

### getResponseType()

Only `ActionPayload` generates `getResponseType()` method:

```swift
// Auto-generated (simplified)
extension JoinAction {
    static func getResponseType() -> Any.Type {
        return JoinResponse.self
    }
}
```

## Payload Types

### ActionPayload

Action payload must define `Response` typealias:

```swift
@Payload
struct PurchaseAction: ActionPayload {
    typealias Response = PurchaseResponse  // Must define
    let productID: String
    let quantity: Int
}

@Payload
struct PurchaseResponse: ResponsePayload {
    let success: Bool
    let totalCost: Double
}
```

**Features**:
- Must define `typealias Response`
- Generates `getResponseType()` method
- Used for operations that need immediate feedback

### ResponsePayload

Response payload doesn't need additional typealias:

```swift
@Payload
struct PurchaseResponse: ResponsePayload {
    let success: Bool
    let message: String
    let orderID: String?
}
```

**Features**:
- Doesn't need to define typealias
- Only generates `getFieldMetadata()` method
- Used for Action responses

### ServerEventPayload

Events sent from Server to Client:

```swift
@Payload
struct GameStartedEvent: ServerEventPayload {
    let gameID: String
    let startTime: Date
    let players: [PlayerID]
}
```

**Features**:
- Doesn't need Response
- Only generates `getFieldMetadata()` method
- Used for Server → Client notifications

### ClientEventPayload

Events sent from Client to Server:

```swift
@Payload
struct HeartbeatEvent: ClientEventPayload {
    let timestamp: Date
    let clientVersion: String
}
```

**Features**:
- Doesn't need Response
- Only generates `getFieldMetadata()` method
- Used for Client → Server notifications

## Validation Rules

### Compile-Time Validation

`@Payload` performs validation at compile time:

#### ✅ Correct Usage

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse  // ✅ Correct
    let playerID: PlayerID
    let name: String
}
```

#### ❌ Incorrect Usage

```swift
// ❌ Error 1: ActionPayload didn't define Response
@Payload
struct JoinAction: ActionPayload {
    let playerID: PlayerID
    // Missing typealias Response
}

// ❌ Error 2: Using on class
@Payload  // Compile error: Only supports struct
class JoinAction: ActionPayload {
    // ...
}

// ❌ Error 3: Optional types (currently not supported)
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID?
    // Compile error: Optional types not supported
}
```

### Limitations

1. **Only supports struct**: Doesn't support class or enum
2. **Doesn't support optional types**: Fields cannot be optional types (`String?`)
3. **Must mark @Payload**: Unmarked payloads will trap at runtime

## Use Cases

### Use Case 1: Simple Action

```swift
@Payload
struct GetPlayerInfoAction: ActionPayload {
    typealias Response = PlayerInfoResponse
    let playerID: PlayerID
}

@Payload
struct PlayerInfoResponse: ResponsePayload {
    let playerID: PlayerID
    let name: String
    let level: Int
}
```

### Use Case 2: Complex Action

```swift
@Payload
struct PurchaseItemAction: ActionPayload {
    typealias Response = PurchaseItemResponse
    let playerID: PlayerID
    let itemID: String
    let quantity: Int
    let paymentMethod: String
}

@Payload
struct PurchaseItemResponse: ResponsePayload {
    let success: Bool
    let orderID: String
    let remainingBalance: Double
    let purchasedItems: [PurchasedItem]
}
```

### Use Case 3: Event Notifications

```swift
@Payload
struct PlayerLevelUpEvent: ServerEventPayload {
    let playerID: PlayerID
    let oldLevel: Int
    let newLevel: Int
    let rewards: [Reward]
}
```

## Common Errors

### Error 1: Forgot to Mark @Payload

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

### Error 2: Action Didn't Define Response

```swift
@Payload
struct JoinAction: ActionPayload {
    // ❌ Error: Missing typealias Response
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

### Error 3: Using Optional Types

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID?
    // ❌ Compile error: Optional types not supported
}
```

**Solution**: Use non-optional types, or use default values:

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let deviceID: String  // Use non-optional, handle empty values in handler
}
```

## Best Practices

### 1. Mark All Payloads with @Payload

Ensure all Actions, Events, Responses are marked with `@Payload`:

```swift
// ✅ Correct: All Payloads are marked
@Payload struct JoinAction: ActionPayload { ... }
@Payload struct JoinResponse: ResponsePayload { ... }
@Payload struct PlayerJoinedEvent: ServerEventPayload { ... }
```

### 2. Use Explicit Types

Avoid overly generic types:

```swift
// ✅ Correct: Explicit types
@Payload
struct PurchaseAction: ActionPayload {
    typealias Response = PurchaseResponse
    let productID: String
    let quantity: Int
}

// ❌ Wrong: Too generic
@Payload
struct GenericAction: ActionPayload {
    typealias Response = GenericResponse
    let data: [String: Any]  // Too generic
}
```

### 3. Keep Payloads Simple

Avoid overly complex nested structures:

```swift
// ✅ Correct: Simple structure
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
}

// ⚠️ Note: Complex nested structures may need additional processing
@Payload
struct ComplexAction: ActionPayload {
    typealias Response = ComplexResponse
    let nestedData: NestedStructure  // Ensure NestedStructure is also marked with @Payload or @SnapshotConvertible
}
```

## Relationship with Schema Generation

`@Payload` generated metadata is used for automatic JSON Schema generation:

```swift
// Payload definition
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
}

// Auto-generated Schema (simplified)
{
  "defs": {
    "JoinAction": {
      "type": "object",
      "properties": {
        "playerID": { "type": "string" },
        "name": { "type": "string" }
      },
      "required": ["playerID", "name"]
    }
  }
}
```

## Related Documentation

- [Macros Overview](README.en.md) - Understand usage of all macros
- [Schema Generation](../schema/README.en.md) - Understand schema generation mechanism
- [Land DSL](../core/land-dsl.en.md) - Understand how to use Payload in Land DSL
