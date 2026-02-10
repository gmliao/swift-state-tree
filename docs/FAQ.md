[English](FAQ.md) | [中文版](FAQ.zh-TW.md)

# Frequently Asked Questions (FAQ)

> Common questions and answers when using SwiftStateTree

## Installation & Setup

### Q: How do I get started with SwiftStateTree?

A: Currently, we recommend cloning the repository to try it out:

```bash
git clone https://github.com/your-username/SwiftStateTree.git
cd SwiftStateTree
swift build
```

For detailed instructions, please refer to [README.md](../README.md#quick-start).

### Q: What are the system requirements?

A: 
- Swift 6.0+
- macOS 14.0+ (development environment)
- Platforms supporting Swift 6 (deployment environment)

### Q: How do I verify the project runs correctly?

A: Run the tests:

```bash
swift test
```

If the tests pass, the project runs correctly. You can also try running the examples:

```bash
cd Examples/Demo
swift run DemoServer
```

## StateTree Definition

### Q: Why must all stored properties be marked with `@Sync` or `@Internal`?

A: This is a validation rule of `@StateNodeBuilder` to ensure all state fields have explicit sync strategies. This helps:

- Avoid accidentally leaking sensitive data
- Explicitly control sync behavior
- Improve code readability

**Example**:

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:] // ✅ Correct
    
    @Internal
    var lastProcessedTimestamp: Date = Date() // ✅ Correct
    
    // var tempData: String = "" // ❌ Error: Not marked
}
```

### Q: Do computed properties need to be marked?

A: No. Computed properties automatically skip validation because they don't store state.

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    // Computed property doesn't need marking
    var totalPlayers: Int {
        players.count
    }
}
```

### Q: What's the difference between `@Sync(.serverOnly)` and `@Internal`?

A: 
- **`@Sync(.serverOnly)`**: Not synced to client, but sync engine knows about this field (for validation and tracking)
- **`@Internal`**: Sync engine doesn't need to know, purely for server internal use

**Usage recommendations**:
- Need sync engine tracking but not synced to client → use `@Sync(.serverOnly)`
- Purely internal calculation temporary values → use `@Internal`

## Sync Rules

### Q: How do I choose the appropriate sync strategy?

A: Choose based on data characteristics:

| Strategy | Use Case | Example |
|----------|----------|---------|
| `.broadcast` | All players need same data | Game status, room info |
| `.perPlayerSlice()` | Dictionary only syncs that player's portion | Hand cards, personal data |
| `.perPlayer(...)` | Need to filter by player | Personal quest progress |
| `.serverOnly` | Server internal use, not synced | Hidden deck, internal counter |
| `.custom(...)` | Fully custom filter logic | Complex permission control |

### Q: How do I optimize sync performance?

A: 
1. **Use `@SnapshotConvertible`**: Mark nested structures with this macro to avoid runtime reflection
2. **Enable dirty tracking**: Only sync changed fields (enabled by default)
3. **Use `@Internal` appropriately**: Don't mark `@Sync` for internal calculation fields

For detailed information, please refer to [Sync Rules](core/sync.md).

## Land DSL

### Q: How do I execute async operations in handlers?

A: Handlers are synchronous by design (for determinism). **Do not run async I/O inside handlers**.

Use a Resolver to load async data *before* the handler executes, then emit deterministic outputs via `ctx.emitEvent(...)`:

```swift
struct LoadSomethingResolver: ContextResolver {
    struct Output: ResolverOutput { let value: Int }
    static func resolve(ctx: ResolverContext) async throws -> Output {
        let value = try await someAsyncOperation()
        return Output(value: value)
    }
}

Rules {
    HandleAction(SomeAction.self, resolvers: LoadSomethingResolver.self) { state, action, ctx in
        let output: LoadSomethingResolver.Output? = ctx.loadSomething
        state.someField = output?.value ?? 0

        ctx.emitEvent(SomeEvent(result: state.someField), to: .player(ctx.playerID))
        return SomeResponse()
    }
}
```

### Q: How do I handle errors?

A: Throw errors in handlers, they will be automatically wrapped as `ErrorPayload` and returned to client:

```swift
Rules {
    HandleAction(JoinAction.self) { state, action, ctx in
        // Validation
        guard action.playerID != nil else {
            throw LandError.invalidAction("playerID is required")
        }
        
        // Check if room is full
        if state.players.count >= 4 {
            throw LandError.joinDenied("Room is full")
        }
        
        // Normal processing
        state.players[action.playerID] = PlayerState(name: action.name)
        return JoinResponse(status: "ok")
    }
}
```

### Q: What's the difference between CanJoin and OnJoin?

A: 
- **`CanJoin`**: Validation before joining, can deny join (return `.deny`)
- **`OnJoin`**: Processing after joining, always executes (unless CanJoin denies)

**Example**:

```swift
Rules {
    CanJoin { state, ctx in
        // Validation logic
        if state.players.count >= 4 {
            return .deny(reason: "Room is full")
        }
        return .allow
    }
    
    OnJoin { state, ctx in
        // Initialization after joining
        state.players[ctx.playerID] = PlayerState(name: ctx.playerID.rawValue)
    }
}
```

## Error Handling

### Q: What are the common error codes?

A: Main error codes include:

**Join errors**:
- `JOIN_SESSION_NOT_CONNECTED`: Connection not established
- `JOIN_ALREADY_JOINED`: Already joined
- `JOIN_DENIED`: Join denied
- `JOIN_ROOM_FULL`: Room is full
- `JOIN_ROOM_NOT_FOUND`: Room not found

**Action errors**:
- `ACTION_NOT_REGISTERED`: Action not registered
- `ACTION_INVALID_PAYLOAD`: Payload format error
- `ACTION_HANDLER_ERROR`: Handler execution error

**Event errors**:
- `EVENT_NOT_REGISTERED`: Event not registered
- `EVENT_INVALID_PAYLOAD`: Payload format error

**Message format errors**:
- `INVALID_MESSAGE_FORMAT`: Invalid message format
- `INVALID_JSON`: JSON parsing failed
- `MISSING_REQUIRED_FIELD`: Missing required field

### Q: How do I handle Resolver errors?

A: Resolver errors are automatically wrapped and returned to client:

```swift
struct ProductInfoResolver: ContextResolver {
    typealias Output = ProductInfo
    
    static func resolve(ctx: ResolverContext) async throws -> ProductInfo {
        guard let productID = ctx.actionPayload.productID else {
            throw ResolverError.missingParameter("productID")
        }
        
        // If product not found, throw error
        guard let product = await fetchProduct(productID) else {
            throw ResolverError.dataLoadFailed("Product not found")
        }
        
        return product
    }
}
```

Errors are wrapped in `ResolverExecutionError`, including resolver name and original error.

## Performance Issues

### Q: How do I improve sync performance?

A: 
1. **Use `@SnapshotConvertible`**: Mark frequently used nested structures with this macro
2. **Enable dirty tracking**: Only sync changed fields (enabled by default)
3. **Design StateTree appropriately**: Avoid overly deep nested structures
4. **Use `@Internal`**: Don't sync fields used for internal calculations

For detailed information, please refer to [Macros](macros/README.md).

### Q: When should I disable dirty tracking?

A: When most fields change on every update, disabling dirty tracking might be faster. However, it's generally recommended to keep it enabled.

```swift
// Set when initializing TransportAdapter
let adapter = TransportAdapter(
    keeper: keeper,
    transport: transport,
    landID: landID,
    enableDirtyTracking: false // Disable dirty tracking
)
```

## Multi-Room Architecture

### Q: How do I implement multi-room architecture?

A: Use `LandManager` and `LandRouter`:

```swift
// Create LandManager
let landManager = LandManager<GameState>(
    landFactory: { landID in
        createGameLand(landID: landID)
    },
    initialStateFactory: { landID in
        GameState()
    }
)

// Create LandRouter
let router = LandRouter<GameState>(
    landManager: landManager,
    landTypeRegistry: landTypeRegistry
)
```

For detailed information, please refer to [Transport Layer](transport/README.md).

### Q: How do I manage room lifecycle?

A: Use `Lifetime` block in Land DSL:

```swift
Lifetime {
    // Auto-destroy room after 60 seconds of being empty
    DestroyWhenEmpty(after: .seconds(60))
    
    // Destroy room after existing for more than 1 hour
    DestroyAfter(duration: .hours(1))
}
```

## Authentication & Security

### Q: How do I configure JWT authentication?

A: Use `LandServerConfiguration` and register through `LandHost`:

```swift
// Create JWT configuration
let jwtConfig = JWTConfiguration(
    secretKey: "your-secret-key",
    algorithm: .HS256,
    validateExpiration: true
)

// Create LandHost
let host = LandHost(configuration: LandHost.HostConfiguration(
    host: "localhost",
    port: 8080
))

// Register land type with JWT configuration
try await host.register(
    landType: "demo",
    land: demoLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: LandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: true // Allow Guest mode
    )
)

try await host.run()
```

For detailed information, please refer to [Authentication](hummingbird/auth.md).

### Q: What's the priority order between Guest mode and JWT?

A: PlayerSession field priority order:

1. join request content
2. JWT payload
3. guest session

## Debugging Tips

### Q: How do I debug sync issues?

A: 
1. Check if `@Sync` markers are correct
2. Confirm if dirty tracking is enabled
3. Check SyncEngine logs
4. Use `ctx.requestSyncNow()` to request deterministic sync (flushed at end of tick)

### Q: How do I view state changes?

A: Add logs in handlers using `ctx.logger`:

```swift
Rules {
    HandleAction(SomeAction.self) { state, action, ctx in
        ctx.logger.debug("Before state change", metadata: [
            "field": "\(state.someField)"
        ])
        state.someField = action.value
        ctx.logger.debug("After state change", metadata: [
            "field": "\(state.someField)"
        ])
        return SomeResponse()
    }
}
```

**Note**: `ctx.logger` is a Swift Logging framework `Logger` instance, supporting different log levels (`.debug`, `.info`, `.warning`, `.error`) and structured metadata.

### Q: How do I test Land definitions?

A: Use Swift Testing framework:

```swift
import Testing
@testable import SwiftStateTree

@Test("Test Land behavior")
func testLand() async throws {
    let land = createTestLand()
    let keeper = LandKeeper(definition: land, initialState: TestState())
    
    // Test logic
    // ...
}
```

## Other Questions

### Q: Can I use multiple Lands simultaneously?

A: Yes. In multi-room mode, each room is an independent Land instance.

### Q: How do I migrate from an older version of StateTree?

A: Use `@Since` markers and Persistence layer to handle version differences. For detailed information, please refer to design documents.

### Q: Does it support distributed deployment?

A: Current version focuses on single-node deployment. Distributed deployment is a planned future feature.

## Related Documentation

- [Quick Start](quickstart.md) - Basic usage examples
- [Core Concepts](core/README.md) - Deep dive into system design
- [Sync Rules](core/sync.md) - Sync mechanism details
- [Land DSL](core/land-dsl.md) - Land definition guide
- [Transport Layer](transport/README.md) - Network transport details

## Seeking Help

If the above questions don't resolve your issues, please:

1. Check [Design Documents](../Notes/design/) to understand system design
2. Check [Example Code](../Examples/) for implementation references
3. Submit an [Issue](https://github.com/your-username/SwiftStateTree/issues) for assistance
