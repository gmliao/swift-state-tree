[English](README.md) | [中文版](README.zh-TW.md)

# Hummingbird

Hummingbird module provides WebSocket hosting, with `LandHost` as the main entry point.

## Architecture Overview

### LandHost vs LandServer

`LandHost` is the unified host entry point, responsible for managing HTTP server and all game logic. `LandServer` is responsible for game logic implementation of a single land type.

**Relationship Description**:

- **`LandHost`**: Unified management of HTTP server (Hummingbird Application), shared Router, and `LandRealm` (unified game logic management). One `LandHost` can register multiple `LandServer` instances.
- **`LandServer`**: Responsible for game logic of a single land type, including runtime, transport, WebSocket adapter. Doesn't directly manage HTTP server or Router, but is unified managed by `LandHost`.
- **`LandRealm`**: Internally managed by `LandHost`, responsible for unified management and coordination of multiple `LandServer`s.

## Quick Start

### Basic Usage

Use `LandHost` to create server and register land type:

```swift
import SwiftStateTreeHummingbird

@main
struct DemoServer {
    static func main() async throws {
        // Create LandHost with HTTP server configuration
        let host = LandHost(configuration: LandHost.HostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger
        ))

        // Register land type - router is automatically used
        try await host.register(
            landType: "cookie",
            land: CookieGame.makeLand(),
            initialState: CookieGameState(),
            webSocketPath: "/game/cookie",
            configuration: LandServerConfiguration(
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true,
                allowAutoCreateOnJoin: true
            )
        )

        // Run unified server
        try await host.run()
    }
}
```

### Multi Land Type Support

Register multiple games in the same `LandHost`:

```swift
let host = LandHost(configuration: .init(
    host: "localhost",
    port: 8080,
    logger: logger
))

// Register Cookie Game
try await host.register(
    landType: "cookie",
    land: CookieGame.makeLand(),
    initialState: CookieGameState(),
    webSocketPath: "/game/cookie",
    configuration: serverConfig
)

// Register Counter Demo
try await host.register(
    landType: "counter",
    land: CounterDemo.makeLand(),
    initialState: CounterState(),
    webSocketPath: "/game/counter",
    configuration: serverConfig
)

try await host.run()
```

## Configuration Options

### LandHost.HostConfiguration

HTTP server-level configuration:

```swift
public struct HostConfiguration: Sendable {
    public var host: String              // Server host (default: "localhost")
    public var port: UInt16             // Server port (default: 8080)
    public var healthPath: String        // Health check path (default: "/health")
    public var enableHealthRoute: Bool   // Enable health check route (default: true)
    public var logStartupBanner: Bool   // Enable startup banner (default: true)
    public var logger: Logger?           // Logger instance (optional)
}
```

### LandServerConfiguration

Game logic-level configuration:

```swift
public struct LandServerConfiguration: Sendable {
    public var logger: Logger?
    public var jwtConfig: JWTConfiguration?
    public var jwtValidator: JWTAuthValidator?
    public var allowGuestMode: Bool              // Allow connections without JWT (default: false)
    public var allowAutoCreateOnJoin: Bool       // Auto-create rooms on join (default: false)
}
```

**Important Configuration Notes**:

- `allowGuestMode`: When enabled, allows connections without JWT token (uses guest session)
- `allowAutoCreateOnJoin`: When enabled, clients can automatically create new rooms by specifying `landID`. **Note**: Should be set to `false` in production, only enable for demo/testing.

## Built-in Routes

`LandHost` automatically provides the following routes:

- **WebSocket**: Specified by `webSocketPath` parameter (e.g., `/game/cookie`, `/game/counter`)
- **Health Check**: `healthPath` (default `/health`, can be disabled via `enableHealthRoute`)
- **Schema**: `/schema` (automatically outputs JSON schema for all registered Lands, with CORS support)

On startup, `LandHost` automatically prints connection information, including all registered WebSocket endpoints.

## Room Management

### Multi-Room Mode

`LandHost` supports multi-room mode by default:

- Clients can specify which room to join via `landID` parameter in `JoinRequest`
- `landID` format: `"landType:instanceId"` (e.g., `"cookie:room-123"`)
- If only `instanceId` is provided (e.g., `"room-123"`), codegen automatically adds `landType` prefix

### Auto-Create Rooms

When `allowAutoCreateOnJoin: true`:

- Clients can create new rooms by specifying non-existent `landID`
- Example: Connecting to `"cookie:my-room"` automatically creates a new cookie game room

### Single-Room Behavior

Even with multi-room mode enabled, single-room behavior can be achieved by:

- Clients don't specify `landID` (or use default value), all clients connect to the same room
- Or all clients specify the same `landID`

## Advanced Usage

### Custom Routes

`LandHost` internally manages Router. If you need to add custom routes, it can be achieved through `LandHost` extensions (future versions may provide more direct API).

### Admin Routes

`LandHost` provides `registerAdminRoutes` method to register admin routes:

```swift
try await host.registerAdminRoutes(
    adminAuth: adminAuth,
    enableAdminRoutes: true
)
```

## Environment Variable Configuration

Server can be configured via environment variables:

```bash
# Set port
PORT=3000 swift run DemoServer

# Set host and port
HOST=0.0.0.0 PORT=3000 swift run DemoServer
```

## Related Documentation

- [JWT and Guest Mode](auth.md) - Understand authentication and authorization mechanisms
- [Quick Start](../quickstart.md) - Build your first server from scratch
- [Transport Layer](../transport/README.md) - Understand network transport mechanisms
