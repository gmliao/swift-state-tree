# Opcode 107 Performance Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate the opcode 107 merge bottleneck by encoding server events once and ensuring targeted events (including `.client`) are merged correctly, then validate load tests complete within default timeouts.

**Architecture:** Pre-encode server event bodies to MessagePack once when queued, store them with target metadata, and reuse them during sync to build the 107 frame. Preserve event order and ensure `.client` targets resolve to session IDs under opcode 107. Keep merge logic localized to `TransportAdapter` and add transport tests for the `.client` target behavior.

**Tech Stack:** Swift 6, Swift Testing, MessagePack (`SwiftStateTreeMessagePack`), `TransportAdapter`.

### Task 1: Add failing test for opcode 107 client-targeted events

**Files:**
- Create: `Tests/SwiftStateTreeTransportTests/TransportAdapterOpcode107Tests.swift`

**Step 1: Write the failing test**

```swift
@Test("TransportAdapter merges .client event into opcode 107 frame")
func testOpcode107MergesClientEvent() async throws {
    // Arrange: land with client event -> state change
    // Join session
    // Clear initial sync messages
    // Send client event to mutate state
    // Queue server event to .client
    // Call syncNow
    // Assert: one message, opcode 107, events array includes the server event payload
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter Opcode107`  
Expected: FAIL because events array is empty (opcode 107 not emitted for `.client` target).

### Task 2: Encode event bodies once and preserve target delivery

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter.swift`

**Step 1: Implement minimal fix**

```swift
// Add pending encoded event bodies
private struct PendingEventBody { let target: SwiftStateTree.EventTarget; let body: MessagePackValue }
private var pendingServerEventBodies: [PendingEventBody] = []

// Encode event body once when queued (for opcode 107)
private func encodeServerEventBody(_ event: AnyServerEvent) -> MessagePackValue? { ... }

// Queue in sendEvent when useStateUpdateWithEvents is true
// Resolve .client to sessionID immediately, or log+skip if missing

// Replace buildStateUpdateWithEvents to accept pre-encoded bodies
private func buildStateUpdateWithEventBodies(stateUpdateData: Data, eventBodies: [MessagePackValue]) -> Data? { ... }

// Use pendingEventBodies(for:) in sendEncodedUpdate/syncBroadcastOnly
```

**Step 2: Run test to verify it passes**

Run: `swift test --filter Opcode107`  
Expected: PASS.

### Task 3: Validate load test completion

**Files:**
- None (runtime verification)

**Step 1: Run default load test with timeout**

Run: `timeout 180 bash Examples/GameDemo/scripts/server-loadtest/run-server-loadtest.sh`  
Expected: completes within timeout and outputs results JSON.

