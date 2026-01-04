[English](README.md) | [中文版](README.zh-TW.md)

# Core

This section organizes SwiftStateTree's core concepts and APIs: StateNode, Sync, Land DSL, Runtime, Resolver, SchemaGen.

## Core Design Goals

- Single authoritative state (StateNode) as server's single source of truth
- Separation of sync logic and business logic (SyncPolicy + Land DSL)
- Compile-time metadata generation (macro) reduces runtime reflection costs
- Land DSL doesn't depend on Transport, maintains portability

## Main Components

- StateNode + `@StateNodeBuilder`
- SyncPolicy + `@Sync` / `@Internal`
- Land DSL (AccessControl / Rules / Lifetime)
- Runtime: `LandKeeper`
- Resolver: pre-handler data fetching
- SchemaGen: Output JSON Schema

## Recommended Reading Order

1. **[Land DSL](land-dsl.md)** - Learn how to define domain logic
2. **[Sync Rules](sync.md)** - Understand state synchronization mechanisms
3. **[Runtime Operation](runtime.md)** - Deep dive into LandKeeper's operation
4. **[Resolver Usage Guide](resolver.md)** - Learn how to use Resolver to load data

## Runtime (LandKeeper)

`LandKeeper` is SwiftStateTree's core runtime executor, responsible for managing state and executing handlers.

### Core Features

- **Actor Serialization**: All state changes go through actor serialization, ensuring thread safety
- **Snapshot Sync Mode**: Uses snapshot mode for synchronization, doesn't block state changes
- **Sync Deduplication**: Concurrent sync requests are deduplicated, avoiding duplicate work
- **Request-Scoped Context**: New `LandContext` created for each request, released after processing

### Main Functions

- **Player Lifecycle Management**: Handle join/leave, execute `CanJoin`/`OnJoin`/`OnLeave` handlers
- **Action/Event Processing**: Execute corresponding handlers, manage state changes
- **Tick Mechanism**: Manage scheduled tasks, execute `OnTick` handler
- **State Synchronization**: Coordinate SyncEngine for state synchronization
- **Auto-Destruction**: Automatically destroy empty rooms based on conditions

### Detailed Description

For detailed operation mechanisms, please refer to [Runtime Operation](runtime.md).

## Resolver

Resolver mechanism allows parallel loading of external data before Action/Event handler execution, keeping handlers synchronous.

### Core Features

- **Parallel Execution**: Multiple resolvers execute in parallel, improving performance
- **Error Handling**: Any resolver failure aborts the entire processing flow
- **Type Safety**: Provides type-safe access through `@dynamicMemberLookup`
- **Data Loading**: Load data from external sources like databases, Redis, APIs, etc.

### Usage

Declare resolver in Land DSL:

```swift
Rules {
    HandleAction(UpdateCartAction.self, resolvers: ProductInfoResolver.self) { state, action, ctx in
        // Resolver has already executed, can use directly
        let productInfo = ctx.productInfo  // Type: ProductInfo?
        // ...
    }
}
```

### Detailed Description

For detailed usage guide, please refer to [Resolver Usage Guide](resolver.md).

## SchemaGen

SchemaGen is used to generate JSON Schema from LandDefinition and StateNode for client SDK generation.

### Core Functions

- **Metadata Generation**: `@StateNodeBuilder` and `@Payload` generate field metadata
- **Schema Extraction**: `SchemaExtractor` generates complete JSON schema from `LandDefinition`
- **Auto Endpoint**: Hummingbird provides `/schema` endpoint to output schema

### Use Cases

- Client SDK generation (TypeScript, Kotlin, etc.)
- Version alignment and tool validation
- API documentation generation

For detailed information, please refer to [Schema Generation](../schema/README.md).
