# Server Integration Guide

[English](server-integration.md) | [中文版](server-integration.zh-TW.md)

This guide describes how to integrate SwiftStateTree with **any** HTTP/WebSocket framework (NIO, Vapor, Hummingbird, Kitura, etc.). The transport layer is framework-agnostic; you only need to wire a few extension points.

## Contract: What Any Server Must Do

1. **Create a `WebSocketTransport`** per land type (or per path) and connect it to a `LandRouter` or `TransportAdapter`.
2. **On WebSocket upgrade**: resolve auth from the handshake (path + URI), then call `WebSocketTransport.handleConnection(sessionID:connection:authInfo:)`.
3. **Optionally** expose HTTP endpoints: `/schema` (for clients/codegen) and `/admin/*` (for management).

Auth and schema are **optional**; the only requirement is to call `handleConnection` with a `WebSocketConnection` and optional `AuthenticatedInfo`.

## Extension Points (SwiftStateTreeTransport)

All types below live in **SwiftStateTreeTransport** so that server implementations only depend on the transport module.

### 1. Auth: `AuthInfoResolverProtocol`

Resolves authenticated info from the WebSocket handshake **before** accepting the connection.

```swift
public protocol AuthInfoResolverProtocol: Sendable {
    func resolve(path: String, uri: String) async throws -> AuthenticatedInfo?
}
```

- **path**: Normalized path (e.g. `/game/counter`).
- **uri**: Full request URI (e.g. `/game/counter?token=eyJ...`) so you can read query or pass to a token validator.
- **Returns**: `AuthenticatedInfo` for authenticated users, `nil` for allowed guest, or **throw** to reject the upgrade.

**Convenience**: Use `ClosureAuthInfoResolver { path, uri in ... }` to wrap a closure when your server only accepts a function.

### 2. Token validation: `TokenValidatorProtocol`

Validates a token string (e.g. JWT) and returns `AuthenticatedInfo`. Use this when you extract a token from URI/headers and want to validate it in a reusable way.

```swift
public protocol TokenValidatorProtocol: Sendable {
    func validate(token: String) async throws -> AuthenticatedInfo
}
```

- **SwiftStateTreeNIO** provides `DefaultJWTAuthValidator` (HS256/384/512, optional RS/ES) and conforms to `TokenValidatorProtocol`. You can use it from any framework: extract the token from your request, then call `validator.validate(token:)`.
- You can implement your own (e.g. API keys, custom JWT claims) and pass the result into `handleConnection(..., authInfo:)`.

### 3. Connection: `WebSocketConnection`

Your server must provide a type that conforms to `WebSocketConnection` (send/receive and close). The transport only uses this interface; it does not care whether the backing is NIO, Vapor, or something else.

### 4. Schema and admin (optional)

- **Schema**: If you expose `GET /schema`, return JSON from your Land definitions (e.g. via `SchemaGenCLI.generateSchema`). The NIO host uses a `schemaProvider: () -> Data?` closure; other frameworks can implement the same contract.
- **Admin**: Implement the routes your product needs (list lands, stats, reevaluation record, etc.). The NIO implementation uses `NIOAdminRoutes`; you can mirror the same API or a subset.

## Minimal Integration Checklist

| Step | Action |
|------|--------|
| 1 | Create `WebSocketTransport` and set its `delegate` to your `TransportAdapter` (or equivalent). |
| 2 | On WebSocket upgrade: build `SessionID`, get path and full URI, then call your `AuthInfoResolverProtocol.resolve(path:uri:)` (or skip auth and pass `nil`). |
| 3 | Call `transport.handleConnection(sessionID: sessionID, connection: yourConnection, authInfo: resolvedAuthInfo)`. |
| 4 | (Optional) Expose `/schema` and admin routes using your framework’s router. |
| 5 | (Optional) Use `TokenValidatorProtocol` (e.g. `DefaultJWTAuthValidator` from SwiftStateTreeNIO) inside your auth resolver if you need JWT. |

## Reference Implementation

**SwiftStateTreeNIO** is the reference: it uses pure SwiftNIO, implements `AuthInfoResolverProtocol` via `ClosureAuthInfoResolver` and per-path JWT config, and passes the result into `WebSocketTransport.handleConnection`. You can copy the same pattern for Vapor or another framework: implement `AuthInfoResolverProtocol` (or wrap a closure), create a `WebSocketConnection` adapter for your framework’s WebSocket type, and call `handleConnection` on upgrade.

## See Also

- [Transport README](README.md) – transport layer overview and data flow
- [SwiftStateTreeNIO](../../Sources/SwiftStateTreeNIO/) – NIO WebSocket server and `NIOLandHost`
