# TransportAdapter Pipeline Refactoring

**Date**: 2026-02-10  
**Status**: Design Phase  
**Author**: AI Assistant

## Overview

This document describes a refactoring plan for `TransportAdapter` to introduce a pipeline architecture while maintaining 100% API compatibility and zero performance overhead.

### Problem Statement

The current `TransportAdapter` (2600+ lines) has accumulated too many responsibilities:
- Message decoding and routing (200+ lines in `onMessage`)
- Membership management (join/leave, session tracking, membership queue)
- State synchronization (syncNow, syncBroadcastOnly, dirty tracking)
- Encoding management (JSON/MessagePack switching, parallel encoding)
- Event queueing (pending events, merge logic)
- Profiling and metrics

This leads to:
- ❌ Poor code readability (hard to navigate 2600+ line file)
- ❌ Difficult to support multiple encoding formats (logic scattered across methods)
- ❌ Hard to test individual components (requires full transport setup)
- ❌ Difficult to extend (adding new message types requires changes in multiple places)

### Goals

1. **Improve code readability** by separating concerns into logical components
2. **Simplify encoding format support** through unified encoding pipeline
3. **Maintain 100% API compatibility** (zero breaking changes for users)
4. **Guarantee zero performance regression** (no actor hopping overhead)
5. **Enable incremental migration** (each step is independently verifiable)

---

## Design Principles

### 1. Value Types Over Actors

**Rationale**: In Swift Actor model, every actor boundary crossing requires `await` suspension (actor hopping), which adds overhead (~200-500ns per hop). For message processing hot paths, this overhead is unacceptable.

**Solution**: Use value types (struct) or Sendable classes for pipeline components, keeping all logic within the same actor isolation domain.

```swift
// ❌ Bad: Multiple actors (3-4 actor hops per message)
actor MessageRouter { ... }
actor MembershipManager { ... }
actor SyncOrchestrator { ... }

// Message processing requires multiple hops:
await router.decode(data)         // hop 1
await membership.validate()       // hop 2
await orchestrator.sync()         // hop 3

// ✅ Good: Value types in single actor (zero hops)
actor TransportAdapter {
    private let decodingPipeline: MessageDecodingPipeline  // struct
    private let membershipCoordinator: MembershipCoordinator  // class
    
    func onMessage() {
        let decoded = decodingPipeline.decode()  // ✅ Synchronous
        membershipCoordinator.validate()         // ✅ Synchronous
    }
}
```

### 2. Internal Refactoring, Public API Unchanged

All changes are internal implementation details. Public API surface remains 100% compatible:

```swift
// ✅ Public API: Completely unchanged
public actor TransportAdapter<State: StateNodeProtocol>: TransportDelegate {
    public init(
        keeper: LandKeeper<State>,
        transport: any Transport,
        landID: String,
        // ... all existing parameters unchanged
    )
    
    public func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async
    public func onMessage(_ message: Data, from sessionID: SessionID) async
    public func syncNow() async
    // ... all other public methods unchanged
}
```

### 3. Gradual File Decomposition

Instead of creating separate actors, we use Swift extensions to split the large file into manageable pieces:

```
TransportAdapter.swift                    # Public API + core state
TransportAdapter+MessageHandling.swift    # Message processing logic
TransportAdapter+Membership.swift         # Membership management
TransportAdapter+Sync.swift               # Synchronization logic
Pipeline/
├── MessageDecodingPipeline.swift         # Decoding logic (value type)
├── MessageRoutingTable.swift             # Routing logic (value type)
└── EncodingPipeline.swift                # Encoding logic (value type)
```

---

## Architecture Design

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│          TransportAdapter (Actor)                           │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │  Public API Surface (Unchanged)                    │    │
│  │  - onMessage(), syncNow(), sendEvent()             │    │
│  │  - TransportDelegate conformance                   │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │  Inbound Pipeline (Value Types)                    │    │
│  │                                                     │    │
│  │  MessageDecodingPipeline (struct)                  │    │
│  │    ├─ codecDetection()                             │    │
│  │    ├─ decodeJSON()                                 │    │
│  │    ├─ decodeMessagePack()                          │    │
│  │    └─ decodeOpcodeArray()                          │    │
│  │                                                     │    │
│  │  MessageRoutingTable (struct)                      │    │
│  │    ├─ routeAction()                                │    │
│  │    ├─ routeEvent()                                 │    │
│  │    ├─ routeJoin() [if enableLegacyJoin]            │    │
│  │    └─ routeUnknown()                               │    │
│  │                                                     │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │  Outbound Pipeline (Value Types)                   │    │
│  │                                                     │    │
│  │  EncodingPipeline (struct)                         │    │
│  │    ├─ encodeStateUpdate()                          │    │
│  │    ├─ encodeServerEvent()                          │    │
│  │    ├─ mergeEventsWithUpdate() [opcode 107]         │    │
│  │    └─ parallelEncodingDecision()                   │    │
│  │                                                     │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │  Membership Coordinator (Sendable class)           │    │
│  │    ├─ sessionToPlayer mapping                      │    │
│  │    ├─ membershipQueue coordination                 │    │
│  │    ├─ playerSlot allocation                        │    │
│  │    └─ membership versioning                        │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

#### 1. MessageDecodingPipeline (struct)

**Responsibility**: Detect encoding format and decode raw Data into TransportMessage.

**Why struct**: Stateless transformation, thread-safe, zero allocation overhead.

```swift
struct MessageDecodingPipeline: Sendable {
    let codec: any TransportCodec
    let opcodeDecoder: OpcodeTransportMessageDecoder
    let enableLegacyJoin: Bool
    
    func decode(_ data: Data) throws -> TransportMessage {
        // Unified decoding logic (currently scattered in onMessage)
        
        // Special handling for legacy join mode:
        // In legacy mode, join messages are always JSON (even if server is MessagePack-configured)
        // So we need to detect JSON format first before falling back to codec
        if enableLegacyJoin {
            // Try JSON detection first (for join handshake compatibility)
            if let json = try? JSONSerialization.jsonObject(with: data) {
                if let array = json as? [Any],
                   array.count >= 1,
                   let opcode = array[0] as? Int,
                   opcode >= 101 && opcode <= 106 {
                    // JSON opcode array format
                    return try opcodeDecoder.decode(from: data)
                } else {
                    // Standard JSON object format (includes Join messages)
                    return try JSONTransportCodec().decode(TransportMessage.self, from: data)
                }
            }
            // Not JSON, fall back to configured codec (MessagePack)
            return try codec.decode(TransportMessage.self, from: data)
        }
        
        // Non-legacy mode: use codec-first approach (for performance)
        if codec.encoding == .messagepack {
            return try codec.decode(TransportMessage.self, from: data)
        }
        
        // Detect JSON opcode array format
        if let json = try? JSONSerialization.jsonObject(with: data),
           let array = json as? [Any],
           array.count >= 1,
           let opcode = array[0] as? Int,
           opcode >= 101 && opcode <= 106 {
            return try opcodeDecoder.decode(from: data)
        }
        
        // Standard JSON object format
        return try codec.decode(TransportMessage.self, from: data)
    }
}
```

**⚠️ Important: Join/JoinResponse Encoding Special Case**

Join and JoinResponse messages have special encoding rules for handshake protocol:

1. **Join Request** (Client → Server): **Always JSON** (client doesn't know server encoding yet)
2. **JoinResponse** (Server → Client): **Always JSON** + includes `encoding` field for negotiation
3. **JoinError** (Server → Client): **Always JSON** (handshake phase)
4. **All other messages**: Use negotiated encoding (after join completes)

**Encoding Negotiation Flow**:
```
Client                          Server
  │                              │
  │─── Join (JSON) ────────────>│  ✅ Always JSON (handshake)
  │                              │
  │<── JoinResponse (JSON) ─────│  ✅ Always JSON + encoding field
  │    { encoding: "messagepack" }│    tells client what to use
  │                              │
  │─── Action (MessagePack) ───>│  ✅ Now uses negotiated encoding
  │                              │
  │<── StateUpdate (MessagePack)│  ✅ Uses negotiated encoding
```

**Implementation Note**: LandRouter manages this via `sessionHandshakePhase`:
```swift
// LandRouter.swift (line 585-592)
let encoder: any TransportMessageEncoder
if handshakePhase == .awaitingJoin {
    encoder = TransportEncodingConfig.json.makeMessageEncoder()  // Force JSON
} else {
    encoder = messageEncoder  // Use configured encoding
}
```

This ensures backward compatibility and allows clients to discover server encoding dynamically.

**Benefits**:
- ✅ Centralizes all encoding format detection logic
- ✅ Easy to add new encoding formats (e.g., Protobuf)
- ✅ Testable in isolation (no need for full TransportAdapter)
- ✅ Zero performance overhead (inlined by compiler)
- ✅ Preserves join/joinResponse special handling (handshake protocol)
- ✅ **Fixes legacy mode bug**: Correctly handles JSON join even when server is MessagePack-configured

**Testing Note**: Ensure E2E tests cover:
- Legacy mode + JSON config + JSON join ✅
- Legacy mode + MessagePack config + JSON join ✅ (fixed by this design)
- Multi-room mode + all encoding configs ✅ (handled by LandRouter)

#### 2. MessageRoutingTable (struct)

**Responsibility**: Route decoded messages to appropriate handlers.

**Why struct**: Simplifies the large switch statement in `onMessage`.

```swift
struct MessageRoutingTable: Sendable {
    func route(
        _ message: TransportMessage,
        from sessionID: SessionID,
        to adapter: TransportAdapter
    ) async {
        switch message.kind {
        case .join:
            if let payload = message.payload.asJoinPayload() {
                await adapter.handleJoinRequest(payload, sessionID: sessionID)
            }
        case .action:
            if let payload = message.payload.asActionPayload() {
                await adapter.handleActionRequest(payload, sessionID: sessionID)
            }
        case .event:
            if let event = message.payload.asClientEvent() {
                await adapter.handleClientEvent(event, sessionID: sessionID)
            }
        default:
            await adapter.handleUnknownMessage(message, sessionID: sessionID)
        }
    }
}
```

**Benefits**:
- ✅ Simplifies `onMessage` from 200 lines to ~10 lines
- ✅ Clear separation of routing logic from message handling
- ✅ Easy to add new message types (single place to modify)

#### 3. EncodingPipeline (struct)

**Responsibility**: Unified encoding logic for state updates and events.

**Why struct**: Stateless transformation, supports both serial and parallel encoding.

```swift
struct EncodingPipeline: Sendable {
    let stateUpdateEncoder: any StateUpdateEncoder
    let messageEncoder: any TransportMessageEncoder
    
    func encodeStateUpdate(
        _ update: StateUpdate,
        landID: String,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope
    ) throws -> Data {
        if let scopedEncoder = stateUpdateEncoder as? StateUpdateEncoderWithScope {
            return try scopedEncoder.encode(
                update: update,
                landID: landID,
                playerID: playerID,
                playerSlot: playerSlot,
                scope: scope
            )
        }
        
        return try stateUpdateEncoder.encode(
            update: update,
            landID: landID,
            playerID: playerID,
            playerSlot: playerSlot
        )
    }
    
    func mergeEventsWithStateUpdate(
        stateUpdateData: Data,
        eventBodies: [MessagePackValue]
    ) -> Data? {
        // Opcode 107 merging logic (currently in TransportAdapter)
        // ...
    }
}
```

**⚠️ Important: Join/JoinResponse Encoding Handled by LandRouter**

Join and JoinResponse encoding is **NOT** handled by TransportAdapter's EncodingPipeline:
- **LandRouter** handles join handshake and encoding negotiation
- **TransportAdapter** only handles join in legacy mode (single-room, deprecated)
- EncodingPipeline focuses on **state updates and events** (after join completes)

**Encoding Responsibilities**:
- **LandRouter**: Join/JoinResponse/JoinError (always JSON during handshake)
- **TransportAdapter/EncodingPipeline**: State updates, server events, actions (uses negotiated encoding)

**Benefits**:
- ✅ Centralizes all encoding format logic (except join handshake)
- ✅ Simplifies syncNow/syncBroadcastOnly (reuse encoding logic)
- ✅ Easy to switch encoding formats (single configuration point)
- ✅ Supports both serial and parallel encoding strategies
- ✅ Preserves join/joinResponse special handling (LandRouter responsibility)

#### 4. MembershipCoordinator (Sendable class)

**Responsibility**: Manage player sessions and membership versioning.

**Why class**: Needs to maintain mutable state, but isolated to TransportAdapter actor.

```swift
final class MembershipCoordinator: Sendable {
    // Isolated to TransportAdapter actor, no separate concurrency
    private var sessionToPlayer: [SessionID: PlayerID] = [:]
    private var sessionToClient: [SessionID: ClientID] = [:]
    private var sessionToAuthInfo: [SessionID: AuthenticatedInfo] = [:]
    private var membershipVersionByPlayer: [PlayerID: UInt64] = [:]
    private var membershipVersionBySession: [SessionID: UInt64] = [:]
    private var slotToPlayer: [Int32: PlayerID] = [:]
    private var playerToSlot: [PlayerID: Int32] = [:]
    
    func registerSession(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?
    ) -> MembershipStamp {
        sessionToPlayer[sessionID] = playerID
        sessionToClient[sessionID] = clientID
        if let authInfo = authInfo {
            sessionToAuthInfo[sessionID] = authInfo
        }
        return bindMembership(sessionID: sessionID, playerID: playerID)
    }
    
    func allocatePlayerSlot(accountKey: String, for playerID: PlayerID) -> Int32 {
        // Deterministic slot allocation logic
        // ...
    }
    
    // ... other membership management methods
}
```

**Benefits**:
- ✅ Encapsulates all membership-related state
- ✅ Simplifies TransportAdapter (removes 500+ lines of session tracking)
- ✅ Testable in isolation
- ✅ Zero performance overhead (no actor hopping)

---

## Migration Plan

### Phase 1: Extract MessageDecodingPipeline (1-2 days)

**Goal**: Centralize message decoding logic.

**Steps**:
1. Create `Sources/SwiftStateTreeTransport/Pipeline/MessageDecodingPipeline.swift`
2. Move decoding logic from `onMessage` to `MessageDecodingPipeline.decode()`
3. Update `onMessage` to use pipeline:
   ```swift
   func onMessage(_ message: Data, from sessionID: SessionID) async {
       do {
           let decoded = try decodingPipeline.decode(message)
           // ... rest of routing logic
       } catch {
           await handleDecodingError(error, sessionID: sessionID)
       }
   }
   ```
4. Run tests: `swift test --filter TransportAdapterTests`
5. Verify E2E tests: `cd Tools/CLI && npm test`

**Verification**:
- ✅ All existing tests pass
- ✅ No performance regression (benchmark with DemoServer)
- ✅ Message decoding works for JSON, MessagePack, and opcode array formats

### Phase 2: Extract MessageRoutingTable (1-2 days)

**Goal**: Simplify message routing logic.

**Steps**:
1. Create `Sources/SwiftStateTreeTransport/Pipeline/MessageRoutingTable.swift`
2. Move routing switch statement to `MessageRoutingTable.route()`
3. Update `onMessage` to use routing table:
   ```swift
   func onMessage(_ message: Data, from sessionID: SessionID) async {
       do {
           let decoded = try decodingPipeline.decode(message)
           await routingTable.route(decoded, from: sessionID, to: self)
       } catch {
           await handleDecodingError(error, sessionID: sessionID)
       }
   }
   ```
4. Run tests: `swift test --filter TransportAdapterTests`
5. Verify E2E tests: `cd Tools/CLI && npm test`

**Verification**:
- ✅ All message types are correctly routed
- ✅ Join, Action, Event, ActionResponse handling works correctly
- ✅ No performance regression

### Phase 3: Extract EncodingPipeline (2-3 days)

**Goal**: Unify encoding logic for state updates and events.

**Steps**:
1. Create `Sources/SwiftStateTreeTransport/Pipeline/EncodingPipeline.swift`
2. Move encoding logic from `syncNow`/`syncBroadcastOnly` to pipeline
3. Implement encoding strategy methods:
   - `encodeStateUpdate()`
   - `encodeServerEvent()`
   - `mergeEventsWithStateUpdate()`
4. Update `syncNow` and `syncBroadcastOnly` to use pipeline
5. Run tests: `swift test --filter SyncTests`
6. Verify E2E tests: `cd Tools/CLI && npm test`

**Verification**:
- ✅ State updates are correctly encoded in all formats (JSON, MessagePack, opcode)
- ✅ Event merging (opcode 107) works correctly
- ✅ Parallel encoding decision logic works correctly
- ✅ No performance regression (benchmark sync operations)

### Phase 4: Extract MembershipCoordinator (2-3 days)

**Goal**: Encapsulate membership management logic.

**Steps**:
1. Create `MembershipCoordinator` class with all session tracking state
2. Move membership-related methods from TransportAdapter to coordinator
3. Update TransportAdapter to use coordinator for all membership operations
4. Run tests: `swift test --filter MembershipTests`
5. Verify E2E tests: `cd Tools/CLI && npm test`

**Verification**:
- ✅ Join/leave operations work correctly
- ✅ Membership versioning prevents stale operations
- ✅ PlayerSlot allocation is deterministic
- ✅ No performance regression

### Phase 5: Split TransportAdapter into Files (1 day)

**Goal**: Improve code readability by splitting into logical files.

**Steps**:
1. Create extension files:
   - `TransportAdapter+MessageHandling.swift` (message handling methods)
   - `TransportAdapter+Membership.swift` (membership queue, join/leave)
   - `TransportAdapter+Sync.swift` (syncNow, syncBroadcastOnly)
2. Move corresponding methods to each file
3. Keep core state and public API in main `TransportAdapter.swift`
4. Verify compilation: `swift build`
5. Run full test suite: `swift test`

**Verification**:
- ✅ Project compiles without errors
- ✅ All tests pass
- ✅ File sizes are manageable (~300-500 lines each)

---

## Special Encoding Rules: Join Handshake Protocol

### Critical Design Constraint

**Join and JoinResponse messages ALWAYS use JSON encoding**, regardless of the configured transport encoding. This is a fundamental protocol design for encoding negotiation.

### Why This Special Rule Exists

1. **Client doesn't know server encoding at connection time**
   - When a client first connects, it doesn't know if the server uses JSON, MessagePack, or other encoding
   - Client must use a "safe" default encoding (JSON) for the initial join request

2. **Server must respond in the same encoding as the request**
   - Server receives Join in JSON → must respond with JoinResponse in JSON
   - This ensures the client can parse the response

3. **Encoding negotiation happens in JoinResponse**
   - JoinResponse includes `encoding` field (e.g., `"messagepack"`)
   - Client learns the server's encoding and switches to it for subsequent messages

### Handshake State Machine

```
┌─────────────────────────────────────────────────────────────────┐
│                    Join Handshake Protocol                       │
└─────────────────────────────────────────────────────────────────┘

State: awaitingJoin
│
│  Client sends Join in JSON:
│  { "kind": "join", "requestID": "...", "landType": "..." }
│
▼
Server receives Join (JSON)
│
│  Server validates and processes join
│
▼
State: Still awaitingJoin (handshake not complete yet)
│
│  Server sends JoinResponse in JSON:
│  {
│    "kind": "joinResponse",
│    "requestID": "...",
│    "success": true,
│    "encoding": "messagepack",  ← Tells client what to use next
│    "playerSlot": 42
│  }
│
▼
State: joined (handshake complete)
│
│  Client switches to MessagePack encoding
│  Server uses MessagePack for all subsequent messages
│
▼
All subsequent messages use MessagePack
```

### Implementation Details

**LandRouter manages handshake state** (not TransportAdapter):

```swift
// LandRouter.swift (line 585-592)
private func sendJoinResponse(...) async {
    // Use JSON encoder for handshake phase
    let handshakePhase = sessionHandshakePhase[sessionID] ?? .awaitingJoin
    let encoder: any TransportMessageEncoder
    if handshakePhase == .awaitingJoin {
        encoder = TransportEncodingConfig.json.makeMessageEncoder()  // ✅ Force JSON
    } else {
        encoder = messageEncoder  // Use configured encoding
    }
    
    let responseData = try encoder.encode(response)
    await transport.send(responseData, to: .session(sessionID))
}
```

**Handshake state transitions**:
```swift
enum SessionHandshakePhase {
    case awaitingJoin    // Waiting for join (only accepts JSON join)
    case joined          // Join complete (uses configured encoding)
}

// State transition happens AFTER sending JoinResponse:
await sendJoinResponse(...)  // Send in JSON
sessionHandshakePhase[sessionID] = .joined  // Now switch to configured encoding
```

### Impact on Pipeline Design

**MessageDecodingPipeline**:
- Must accept JOIN messages in JSON format (even if server is configured for MessagePack)
- No special logic needed (JOIN is always JSON, decoder already handles multi-format)

**EncodingPipeline**:
- Does NOT handle Join/JoinResponse encoding (LandRouter's responsibility)
- Only handles state updates and events (after join completes)

**MessageRoutingTable**:
- Routes JOIN messages to appropriate handler
- In legacy mode (single-room), TransportAdapter handles join directly
- In multi-room mode, LandRouter handles join before forwarding to TransportAdapter

### Testing Implications

When testing encoding formats, ensure:
1. **Join phase always uses JSON** (test with all server encodings: JSON, MessagePack, opcodeArray)
2. **Subsequent messages use negotiated encoding** (verify encoding switch works)
3. **JoinResponse includes correct encoding field** (verify client gets right encoding info)

### Example: Server Configured with MessagePack

```
1. Client connects (doesn't know server encoding yet)
   ↓
2. Client sends Join in JSON:
   {"kind":"join","requestID":"abc","landType":"lobby"}
   ↓
3. Server (configured for MessagePack) receives Join
   - Decodes as JSON (MessageDecodingPipeline handles multi-format)
   - Processes join request
   ↓
4. Server sends JoinResponse in JSON (handshake phase):
   {"kind":"joinResponse","requestID":"abc","success":true,"encoding":"messagepack"}
   ↓
5. Server marks session as joined
   sessionHandshakePhase[sessionID] = .joined
   ↓
6. Client receives JoinResponse (JSON)
   - Parses encoding field: "messagepack"
   - Switches to MessagePack for all subsequent messages
   ↓
7. All subsequent messages use MessagePack:
   - Client sends Actions in MessagePack
   - Server sends StateUpdates in MessagePack
```

### Why This Matters for Refactoring

1. **MessageDecodingPipeline must remain format-agnostic**
   - Cannot assume all messages use configured encoding
   - Must detect and handle JSON even if server is MessagePack-configured

2. **EncodingPipeline doesn't touch join encoding**
   - LandRouter owns handshake encoding logic
   - TransportAdapter/EncodingPipeline only handles post-join messages

3. **Testing must verify handshake protocol**
   - E2E tests should verify JOIN works with all encoding configurations
   - Unit tests should verify encoding negotiation flow

---

## Performance Considerations

### Actor Hopping Analysis

**Current Design** (Single Actor):
```swift
actor TransportAdapter {
    func onMessage() {
        decode()      // ✅ No await
        validate()    // ✅ No await
        route()       // ✅ No await
    }
}
```
**Overhead**: 0 actor hops per message

**Alternative Design** (Multi-Actor, NOT RECOMMENDED):
```swift
actor MessageRouter { ... }
actor MembershipManager { ... }
actor SyncOrchestrator { ... }

// Processing requires:
await router.decode()         // ❌ Actor hop 1
await membership.validate()   // ❌ Actor hop 2
await orchestrator.sync()     // ❌ Actor hop 3
```
**Overhead**: 3-4 actor hops per message (~1-2μs additional latency)

**Our Design** (Value Types in Single Actor):
```swift
actor TransportAdapter {
    private let pipeline: MessageDecodingPipeline  // struct
    private let coordinator: MembershipCoordinator // class
    
    func onMessage() {
        pipeline.decode()      // ✅ No await (inlined)
        coordinator.validate() // ✅ No await (same actor)
    }
}
```
**Overhead**: 0 actor hops per message (same as current)

### Benchmark Targets

To ensure zero performance regression, we will benchmark:

1. **Message Processing Latency**:
   - Measure: Time from `onMessage` to handler invocation
   - Target: ≤ 5% variance from current implementation
   - Test: Process 10,000 messages in DemoServer

2. **Sync Operation Throughput**:
   - Measure: `syncNow` duration for 50 players
   - Target: ≤ 5% variance from current implementation
   - Test: Run benchmark with parallel encoding enabled/disabled

3. **Memory Allocation**:
   - Measure: Total allocations during 1000 sync operations
   - Target: ≤ 10% increase (struct overhead negligible)
   - Test: Instruments memory profiler

---

## Testing Strategy

### Unit Tests

Each pipeline component will have dedicated unit tests:

```swift
// MessageDecodingPipelineTests.swift
@Test("Decode JSON object format")
func testDecodeJSONObject() throws {
    let pipeline = MessageDecodingPipeline(codec: JSONTransportCodec())
    let message = try pipeline.decode(jsonData)
    #expect(message.kind == .action)
}

@Test("Decode MessagePack format")
func testDecodeMessagePack() throws {
    let pipeline = MessageDecodingPipeline(codec: MessagePackTransportCodec())
    let message = try pipeline.decode(messagePackData)
    #expect(message.kind == .action)
}

@Test("Decode opcode array format")
func testDecodeOpcodeArray() throws {
    let pipeline = MessageDecodingPipeline(codec: JSONTransportCodec())
    let message = try pipeline.decode(opcodeArrayData)
    #expect(message.kind == .action)
}
```

### Integration Tests

Existing `TransportAdapterTests` will verify end-to-end behavior:
- Join/leave operations
- Action handling
- Event processing
- State synchronization
- Encoding format switching

### E2E Tests

CLI E2E tests will verify production scenarios:
```bash
cd Tools/CLI && npm test  # All encoding modes (json, jsonOpcode, messagepack)
```

---

## Rollback Plan

Each phase is independently verifiable and reversible:

1. **If Phase 1 fails**: Revert `MessageDecodingPipeline` changes, restore original `onMessage` logic
2. **If Phase 2 fails**: Revert routing table changes, restore original switch statement
3. **If Phase 3 fails**: Revert encoding pipeline changes, restore original encoding logic
4. **If Phase 4 fails**: Revert membership coordinator, restore original state management
5. **If Phase 5 fails**: Merge extension files back into main file

**Git Strategy**:
- Each phase is a separate PR with full test coverage
- Each PR is merge-ready before starting the next phase
- Rollback is as simple as reverting the PR

---

## Benefits Summary

### Code Quality
- ✅ **Readability**: 2600 lines → ~500 lines per file
- ✅ **Maintainability**: Clear separation of concerns
- ✅ **Testability**: Each component is independently testable
- ✅ **Extensibility**: Easy to add new message types or encoding formats

### Performance
- ✅ **Zero overhead**: All components are value types or actor-isolated
- ✅ **No actor hopping**: All hot paths remain in single actor
- ✅ **Parallel encoding**: Unchanged (still supported for JSON encoders)
- ✅ **Memory efficiency**: Structs have minimal allocation overhead

### API Compatibility
- ✅ **Zero breaking changes**: All public APIs unchanged
- ✅ **Zero migration effort**: Existing code works without modification
- ✅ **Backward compatible**: All tests pass without changes

### Risk Mitigation
- ✅ **Incremental migration**: Each phase is independently verifiable
- ✅ **Rollback friendly**: Each phase can be reverted if needed
- ✅ **Test coverage**: Full unit, integration, and E2E test suite

---

## Future Enhancements

After this refactoring, we can more easily:

1. **Add new encoding formats** (e.g., Protobuf):
   - Implement new codec in `MessageDecodingPipeline`
   - Add corresponding encoder in `EncodingPipeline`
   - No changes to TransportAdapter core logic

2. **Add middleware support**:
   - Introduce `MessageMiddleware` protocol in routing table
   - Allow custom pre/post processing of messages
   - Examples: rate limiting, logging, metrics

3. **Optimize sync operations**:
   - Extract `SyncStrategy` protocol
   - Implement specialized strategies (e.g., `DirtyTrackingStrategy`, `FullSyncStrategy`)
   - Easy to A/B test different sync algorithms

4. **Improve observability**:
   - Extract profiling logic to `ProfilingPipeline`
   - Add structured metrics collection
   - Enable distributed tracing support

---

## References

- Current Implementation: `Sources/SwiftStateTreeTransport/TransportAdapter.swift`
- Related Docs:
  - `docs/plans/2026-02-01-membership-queue-reconnect.md` (Membership queue design)
  - `Notes/guides/DEBUGGING_TECHNIQUES.md` (Debugging patterns)
- Testing:
  - Unit Tests: `Tests/SwiftStateTreeTransportTests/`
  - E2E Tests: `Tools/CLI/scenarios/`

---

## Appendix: Code Examples

### Example 1: Simplified onMessage

**Before** (200+ lines):
```swift
func onMessage(_ message: Data, from sessionID: SessionID) async {
    // 50 lines of decoding logic
    do {
        let transportMsg: TransportMessage
        if codec.encoding == .messagepack {
            transportMsg = try codec.decode(TransportMessage.self, from: message)
        } else if let json = try? JSONSerialization.jsonObject(with: message),
                  let array = json as? [Any],
                  array.count >= 1,
                  let firstElement = array[0] as? Int,
                  firstElement >= 101 && firstElement <= 106 {
            let decoder = OpcodeTransportMessageDecoder()
            transportMsg = try decoder.decode(from: message)
        } else {
            transportMsg = try codec.decode(TransportMessage.self, from: message)
        }
        
        // 150+ lines of routing logic
        switch transportMsg.kind {
        case .join:
            if enableLegacyJoin {
                if case .join(let payload) = transportMsg.payload {
                    await handleJoinRequest(...)
                }
            } else {
                logger.warning("Received Join message in TransportAdapter")
            }
        case .action:
            if case .action(let payload) = transportMsg.payload {
                await handleActionRequest(...)
            }
        // ... many more cases
        }
    } catch {
        // Error handling
    }
}
```

**After** (~10 lines):
```swift
func onMessage(_ message: Data, from sessionID: SessionID) async {
    do {
        let decoded = try decodingPipeline.decode(message)
        await routingTable.route(decoded, from: sessionID, to: self)
    } catch {
        await handleDecodingError(error, sessionID: sessionID)
    }
}
```

### Example 2: Simplified Encoding

**Before** (scattered across syncNow, syncBroadcastOnly):
```swift
func syncNow() async {
    // ... 500+ lines of sync logic
    
    // Encoding logic buried in the middle
    if let mpEncoder = stateUpdateEncoder as? OpcodeMessagePackStateUpdateEncoder {
        let updateArray = try mpEncoder.encodeToMessagePackArray(...)
        if let combined = buildStateUpdateWithEventBodies(...) {
            dataToSend = combined
        } else {
            dataToSend = try pack(.array(updateArray))
        }
    } else {
        let updateData = try encodeStateUpdate(...)
        if let combined = buildStateUpdateWithEventBodies(...) {
            dataToSend = combined
        } else {
            dataToSend = updateData
        }
    }
    
    // ... more sync logic
}
```

**After** (centralized in EncodingPipeline):
```swift
func syncNow() async {
    // ... sync logic
    
    // Encoding is a simple method call
    let encoded = try encodingPipeline.encode(
        update: update,
        landID: landID,
        playerID: playerID,
        eventBodies: pendingEventBodies
    )
    
    // ... send logic
}
```

---

## Questions & Answers

**Q: Why not use separate actors for each component?**  
A: Actor hopping overhead. Each actor boundary crossing requires `await` (~200-500ns). For message processing hot paths (1000+ msg/s), this adds significant latency. Value types in a single actor have zero overhead.

**Q: Won't this make the TransportAdapter actor even larger?**  
A: No. We split it into multiple files using extensions. Each file is ~300-500 lines, much more manageable than the current 2600-line monolith.

**Q: How do we test pipeline components in isolation?**  
A: Since they're value types (structs) or Sendable classes, they can be instantiated and tested directly without needing a full TransportAdapter setup.

**Q: What about thread safety?**  
A: All pipeline components are either:
- Value types (structs): Immutable, inherently thread-safe
- Sendable classes: Marked as Sendable and isolated to TransportAdapter actor
- Actor-isolated state: Accessed only within TransportAdapter actor

**Q: Can we add middleware support in the future?**  
A: Yes! The routing table can be extended to support middleware:
```swift
protocol MessageMiddleware {
    func process(_ message: TransportMessage) async -> TransportMessage?
}

struct MessageRoutingTable {
    var middlewares: [MessageMiddleware] = []
    
    func route(...) async {
        var message = originalMessage
        for middleware in middlewares {
            guard let processed = await middleware.process(message) else { return }
            message = processed
        }
        // ... route to handler
    }
}
```

---

## Approval & Next Steps

**Approval**: Pending review  
**Implementation Start**: After design approval  
**Estimated Duration**: 2-3 weeks (5 phases, 1-3 days each)  
**Risk Level**: Low (incremental, reversible, fully tested)

**Next Steps**:
1. Review this design doc with team
2. Address feedback and concerns
3. Approve design
4. Create GitHub issue for tracking
5. Begin Phase 1 implementation
