# NIO WebSocket Transport Design

## Overview

Replace Hummingbird WebSocket layer with pure SwiftNIO WebSocket for improved performance at high connection counts (500+ rooms / 2500+ connections).

## Problem Statement

Current performance bottleneck observed in ws-loadtest:

| Rooms | Connections | RTT p95 (steady) | Result |
|-------|-------------|------------------|--------|
| 300 | 1,500 | 11ms | ✅ Pass |
| 500 | 2,500 | 366ms | ❌ Fail |
| 700 | 3,500 | 36,213ms | ❌ Fail |

The non-linear RTT explosion indicates queuing/saturation at the transport layer, not core logic (ServerLoadTest shows good performance without real WebSocket).

## Goals

1. **Reduce transport overhead** - Remove Hummingbird abstraction layer
2. **Enable zero-copy path** - Use ByteBuffer directly without Data conversion
3. **Validate performance improvement** - Target 500+ rooms with acceptable RTT

## Non-Goals

- Admin HTTP routes (can be added later)
- Health check endpoints (can be added later)
- Full feature parity with Hummingbird integration initially

## Architecture

### Current Stack (Hummingbird)

```
Client ──WS──► Hummingbird ──► HummingbirdStateTreeAdapter ──► WebSocketTransport
                   │                      │
                   │              Data ↔ ByteBuffer copy
                   │                      │
              HTTP routing            Actor hop
```

### New Stack (Pure NIO)

```
Client ──TCP──► NIO EventLoop ──► ChannelPipeline
                                       │
                    ┌──────────────────┼──────────────────┐
                    ▼                  ▼                  ▼
              HTTPDecoder    NIOWebSocketServerUpgrader   WebSocketFrameDecoder
                                       │                  (auto-added)
                                       ▼
                              GameWebSocketHandler
                                       │
                              ByteBuffer direct ──► WebSocketTransport
```

### Key Components

#### 1. NIOWebSocketServer

Bootstrap and lifecycle management:

```swift
public actor NIOWebSocketServer {
    let group: MultiThreadedEventLoopGroup
    let transport: WebSocketTransport
    
    public func start(host: String, port: Int) async throws -> Channel
    public func shutdown() async throws
}
```

#### 2. NIOWebSocketServerUpgrader (NIO Built-in)

NIO provides this out of the box:
- Handles HTTP → WebSocket upgrade handshake
- Automatically adds `WebSocketFrameEncoder` and `WebSocketFrameDecoder`
- `shouldUpgrade` callback for path matching
- `upgradePipelineHandler` callback for adding custom handler

#### 3. GameWebSocketHandler

Custom ChannelInboundHandler for business logic:

```swift
final class GameWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    
    let transport: WebSocketTransport
    let sessionID: SessionID
    var context: ChannelHandlerContext?
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            // Zero-copy: pass ByteBuffer directly
            Task { await transport.handleIncomingBuffer(sessionID, frame.unmaskedData) }
        case .ping:
            // Respond with pong
        case .connectionClose:
            // Handle close
        }
    }
}
```

#### 4. NIOWebSocketConnection

Implements `WebSocketConnection` protocol:

```swift
struct NIOWebSocketConnection: WebSocketConnection {
    let channel: Channel
    
    func send(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        try await channel.writeAndFlush(frame)
    }
}
```

### Zero-Copy Opportunities

| Path | Current | Optimized |
|------|---------|-----------|
| Inbound | ByteBuffer → Data → decode | ByteBuffer → decode |
| Outbound | encode → Data → ByteBuffer | encode → ByteBuffer |
| Broadcast | Same Data to multiple ByteBuffers | Same ByteBuffer (COW) to multiple channels |

## Implementation Plan

### Phase 1: Minimal PoC (1-2 days) ✅ COMPLETED

- [x] Create `SwiftStateTreeNIO` module
- [x] Implement `NIOWebSocketServer` with basic bootstrap
- [x] Implement `WebSocketSessionHandler` (GameWebSocketHandler)
- [x] Single path support (/game/counter for testing)
- [x] Integrate with existing `WebSocketTransport`
- [x] Run E2E tests

### Phase 2: Performance Validation (1 day) 🔄 IN PROGRESS

- [ ] Run ws-loadtest at 300, 500 rooms
- [ ] Compare RTT with Hummingbird version
- [ ] Profile to confirm reduced copies

### Phase 3: Production Ready (2-3 days) ✅ COMPLETED

- [x] Multi-path support (/game/{land-type})
- [x] JWT auth from query parameter (via LandRouter)
- [x] Proper error handling
- [x] Graceful shutdown
- [x] Ping/Pong handling
- [x] Admin HTTP routes (NIOAdminRoutes)
- [x] Health check endpoints (/health)
- [x] Schema endpoint (/schema)
- [x] NIOLandServer + NIOLandHost for LandRealm integration
- [x] NIO HTTP Router with path parameter support
- [x] Admin authentication (X-API-Key)

## Risks and Mitigations

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Performance gain less than expected | Medium | High | Phase 2 validates early |
| NIO learning curve | Low | Medium | NIO WebSocket is well-documented |
| Actor bottleneck still exists | Medium | Medium | This change isolates transport layer |
| Breaking existing tests | Low | Low | Keep Hummingbird as fallback |

## Dependencies

- `NIOCore` (already in use via Hummingbird)
- `NIOHTTP1` (for upgrade handling)
- `NIOWebSocket` (built-in upgrader and frame codec)
- `NIOPosix` (for `MultiThreadedEventLoopGroup`)

## Success Criteria

1. ✅ E2E tests pass with NIO transport
2. 🔄 ws-loadtest 500 rooms: RTT p95 < 100ms (currently 366ms) - Pending validation
3. ✅ No increase in memory usage
4. ✅ Clean integration with existing `WebSocketTransport`

## Implementation Status (2026-02-03)

### Completed Components

| Component | Description | Tests |
|-----------|-------------|-------|
| `NIOWebSocketServer` | Core WebSocket server with HTTP upgrade | ✅ |
| `WebSocketSessionHandler` | Session handling with ping/pong keepalive | ✅ |
| `NIOWebSocketConnection` | Connection abstraction | ✅ |
| `NIOHTTPRouter` | Lightweight HTTP routing with path params | 21 tests |
| `NIOAdminAuth` | API key authentication | ✅ |
| `NIOAdminRoutes` | Admin endpoints (lands, stats, reevaluation) | ✅ |
| `NIOLandServer` | LandServerProtocol implementation | ✅ |
| `NIOLandHost` | High-level API with LandRealm integration | ✅ |

### Test Results

| Test Suite | Status |
|------------|--------|
| Unit tests (702 tests) | ✅ All pass |
| NIO unit tests (21 tests) | ✅ All pass |
| DemoServer E2E (json) | ✅ Pass |
| DemoServer E2E (messagepack) | ✅ Pass |
| GameServer E2E (messagepack) | ✅ Pass |
| GameServer Reevaluation E2E | ✅ Pass |

### Key Files

```
Sources/SwiftStateTreeNIO/
├── HTTP/
│   ├── NIOHTTPRouter.swift           # Lightweight HTTP routing
│   ├── NIOHTTPRequestHandler.swift   # NIO channel handler
│   ├── NIOAdminAuth.swift            # API key authentication
│   └── NIOAdminRoutes.swift          # Admin HTTP endpoints
├── NIOLandServer.swift               # LandServerProtocol impl
├── NIOLandHost.swift                 # High-level API
├── NIOWebSocketServer.swift          # Core WebSocket server
├── WebSocketSessionHandler.swift     # Session handling
└── NIOWebSocketConnection.swift      # Connection abstraction

Tests/SwiftStateTreeNIOTests/
├── NIOHTTPRouterTests.swift          # 21 tests
└── NIOAdminAuthTests.swift
```

### Usage

GameServer now uses NIO by default:

```swift
// Examples/GameDemo/Sources/GameServer/main.swift
let useNIO = ProcessInfo.processInfo.environment["USE_NIO"]?.lowercased() != "false"
// Default: true (NIO), set USE_NIO=false for Hummingbird
```
