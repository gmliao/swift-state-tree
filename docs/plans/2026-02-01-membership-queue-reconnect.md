# Membership Queue & Reconnection Semantics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Serialize join/leave transitions and guard in-flight work with internal membership tokens so stale work is dropped after leave/rejoin; reconnection always performs a fresh firstSync.

**Architecture:** Join/leave operations run through a serial membership queue in `TransportAdapter` to make ordering explicit while allowing actor reentrancy. Each join/leave bumps a per-player membership version; send/receive paths capture a `MembershipStamp` and verify it before delivery. Reconnection is treated as a new membership: caches are cleared on disconnect and `syncStateForNewPlayer` always sends a firstSync snapshot after join.

**Tech Stack:** Swift 6, Swift Testing, `TransportAdapter` + `LandKeeper` actors, MessagePack opcode 107 for event+state bundling.

---

### Task 1: Add failing membership edge-case test (stale targeted event after rejoin)

**Files:**
- Create: `Tests/SwiftStateTreeTransportTests/TransportAdapterMembershipTests.swift`

**Step 1: Write the failing test**

```swift
import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct MembershipTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var tick: Int = 0
}

@Payload
private struct MembershipMessageEvent: ServerEventPayload {
    let message: String
    init(message: String) { self.message = message }
}

private actor RecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(EventTarget, Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws { }
    func stop() async throws { }
    func send(_ message: Data, to target: EventTarget) async throws {
        sent.append((target, message))
    }

    func recordedMessages() async -> [(EventTarget, Data)] { sent }
    func clear() async { sent.removeAll() }
}

@Test("Queued targeted event is dropped after leave + rejoin")
func testQueuedTargetedEventDroppedAfterRejoin() async throws {
    let definition = Land("membership-test", using: MembershipTestState.self) {
        ServerEvents { Register(MembershipMessageEvent.self) }
        Rules { }
    }
    let transport = RecordingTransport()
    let keeper = LandKeeper<MembershipTestState>(definition: definition, initialState: MembershipTestState())
    let encodingConfig = TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
    let adapter = TransportAdapter<MembershipTestState>(
        keeper: keeper,
        transport: transport,
        landID: "membership-test",
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    let player = PlayerID("p1")

    await adapter.onConnect(sessionID: session1, clientID: client1)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session1, clientID: client1, playerID: player)
    await transport.clear()

    // Queue a targeted event for the current membership.
    await adapter.sendEvent(AnyServerEvent(MembershipMessageEvent(message: "old")), to: .player(player))

    // Leave and rejoin quickly.
    await adapter.onDisconnect(sessionID: session1, clientID: client1)

    let session2 = SessionID("sess-2")
    let client2 = ClientID("cli-2")
    await adapter.onConnect(sessionID: session2, clientID: client2)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session2, clientID: client2, playerID: player)

    await adapter.syncNow()

    let messages = await transport.recordedMessages()
    var opcode103Count = 0
    for (_, data) in messages {
        let unpacked = try unpack(data)
        guard case .array(let array) = unpacked,
              case .int(let opcode) = array.first else { continue }
        if opcode == 103 { opcode103Count += 1 }
    }

    #expect(opcode103Count == 0, "Stale targeted event should not be delivered after rejoin")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter TransportAdapterMembershipTests.testQueuedTargetedEventDroppedAfterRejoin`  
Expected: FAIL (opcode 103 appears because stale targeted event is sent)

---

### Task 2: Implement membership queue + membership stamps in `TransportAdapter`

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter.swift`

**Step 1: Add membership stamp tracking**

```swift
private struct MembershipStamp: Sendable, Equatable {
    let playerID: PlayerID
    let version: UInt64
}

private var membershipVersionByPlayer: [PlayerID: UInt64] = [:]
private var membershipVersionBySession: [SessionID: UInt64] = [:]

private func nextMembershipVersion(for playerID: PlayerID) -> UInt64 {
    let next = (membershipVersionByPlayer[playerID] ?? 0) + 1
    membershipVersionByPlayer[playerID] = next
    return next
}

private func bindMembership(sessionID: SessionID, playerID: PlayerID) -> MembershipStamp {
    let version = nextMembershipVersion(for: playerID)
    membershipVersionBySession[sessionID] = version
    return MembershipStamp(playerID: playerID, version: version)
}

private func invalidateMembership(sessionID: SessionID, playerID: PlayerID) {
    _ = nextMembershipVersion(for: playerID)
    membershipVersionBySession.removeValue(forKey: sessionID)
}

private func isSessionCurrent(_ sessionID: SessionID, expected: UInt64) -> Bool {
    membershipVersionBySession[sessionID] == expected
}

private func isPlayerCurrent(_ playerID: PlayerID, expected: UInt64) -> Bool {
    membershipVersionByPlayer[playerID] == expected
}
```

**Step 2: Add a serial membership queue**

```swift
private var membershipQueueTail: Task<Void, Never>?

private func enqueueMembership<T>(
    _ operation: @escaping @Sendable () async throws -> T
) async rethrows -> T {
    let previous = membershipQueueTail
    let task = Task {
        if let previous { _ = await previous.result }
        return try await operation()
    }
    membershipQueueTail = Task { _ = try? await task.value }
    return try await task.value
}
```

**Step 3: Wire queue + membership version into join/leave**

```swift
// In performJoin(...) success path:
let stamp = bindMembership(sessionID: joinResult.sessionID, playerID: joinResult.playerID)
// store stamp if needed for initial sync / send gating

// In onDisconnect(...) after mapping removal:
invalidateMembership(sessionID: sessionID, playerID: playerID)

// In join handler (Router + legacy):
try await enqueueMembership {
    // performJoin / sendJoinResponse / syncStateForNewPlayer
}

// In leave path:
_ = try? await enqueueMembership {
    try await keeper.leave(playerID: playerID, clientID: clientID)
}
```

**Step 4: Attach stamps to queued targeted events**

```swift
private struct PendingEventBody: Sendable {
    let target: SwiftStateTree.EventTarget
    let body: MessagePackValue
    let stamp: MembershipStamp?
}

// When queueing targeted events:
let stamp = membershipStamp(for: target)
pendingServerEventBodies.append(PendingEventBody(target: target, body: body, stamp: stamp))
```

**Step 5: Filter pending targeted events by current stamp**

```swift
private func pendingTargetedEventBodies(for sessionID: SessionID, playerID: PlayerID) -> [MessagePackValue] {
    guard !pendingServerEventBodies.isEmpty else { return [] }
    let currentPlayerVersion = membershipVersionByPlayer[playerID]
    let currentSessionVersion = membershipVersionBySession[sessionID]
    return pendingServerEventBodies.compactMap { entry in
        switch entry.target {
        case .player(let p) where p == playerID:
            guard let stamp = entry.stamp, stamp.version == currentPlayerVersion else { return nil }
            return entry.body
        case .session(let s) where s == sessionID:
            guard let stamp = entry.stamp, stamp.version == currentSessionVersion else { return nil }
            return entry.body
        // existing cases unchanged...
        default:
            return nil
        }
    }
}
```

**Step 6: Guard outbound sends for `.session` / `.player`**

```swift
private func sendEventBody(_ body: MessagePackValue, to target: SwiftStateTree.EventTarget, stamp: MembershipStamp?) async {
    // ... pack frame ...
    switch target {
    case .player(let playerID):
        guard let stamp, isPlayerCurrent(playerID, expected: stamp.version) else { return }
        try? await transport.send(data, to: .player(playerID))
    case .session(let sessionID):
        guard let stamp, isSessionCurrent(sessionID, expected: stamp.version) else { return }
        try? await transport.send(data, to: .session(sessionID))
    default:
        // unchanged
    }
}
```

**Step 7: Guard inbound processing**

```swift
guard let playerID = sessionToPlayer[sessionID],
      let clientID = sessionToClient[sessionID],
      let sessionVersion = membershipVersionBySession[sessionID] else { return }

guard isSessionCurrent(sessionID, expected: sessionVersion) else { return }
```

**Step 8: Minimal English comment to document intent**

Add 1–2 lines near membership queue/stamps:  
`// Membership queue + version stamps prevent stale join/leave work from delivering after rejoin. See docs/plans/2026-02-01-membership-queue-reconnect.md.`

---

### Task 3: Update documentation (design note in this plan)

**Files:**
- Update: `docs/plans/2026-02-01-membership-queue-reconnect.md` (this file, keep as design reference)

**Step 1: Add a short “Edge Cases” section**

```markdown
## Edge Cases Covered
- join + leave reorder → serialized queue order
- leave while async send in-flight → version stamp drops stale send
- leave then rejoin quickly → old targeted events not delivered
- reevaluation/resolver results → commit only if membership version unchanged
```

---

### Task 4: Run tests

**Step 1: Run new test**

Run: `swift test --filter TransportAdapterMembershipTests.testQueuedTargetedEventDroppedAfterRejoin`  
Expected: PASS

**Step 2: Run related transport tests**

Run: `swift test --filter TransportAdapterJoinTests`  
Run: `swift test --filter TransportAdapterOpcode107Tests`  
Expected: PASS

---

### Task 5: Update transport evolution docs (dynamic keys + broadcast/per-player strategy)

**Files:**
- Update: `docs/transport_evolution.md`
- Update: `docs/transport_evolution.zh-TW.md`

**Step 1: Add opcode 107 broadcast merge note (English)**

Add a short subsection explaining:
- Broadcast updates are encoded once and sent to all sessions.
- Per-player updates and targeted events remain per-session.
- Dynamic key tables are scoped: broadcast (land) vs per-player (player).
- Broadcast dynamic keys must be defined for late-joiners (force definition or broadcast firstSync).

**Step 2: Apply the same content in zh-TW**

**Step 3: Review for consistency**

---

## Notes / Decisions Locked

- Join/leave run through a serial membership queue.
- Membership version stamps are internal (no client changes required).
- Reconnection always triggers a firstSync; client may keep local cache only for UX, not correctness.
- Reevaluation consistency is guaranteed by queue + stamp validation at commit time.

## Problem Summary & Root Cause

- **Symptom**: DemoGame 500-room load tests exceed timeout and hang; logs show repeated warnings about sending to players that are not joined.
- **Root Cause 1**: Opcode 107 path previously merged **per-player** updates/events in a way that re-encoded shared broadcast payloads per session, creating O(players) work per tick.
- **Root Cause 2**: Targeted event queues were not guarded by membership versions, so stale events could still deliver after leave/rejoin, causing warnings and extra send attempts under load.
- **Fix**: Encode broadcast updates once (shared), keep per-player updates separate, and guard targeted sends with membership stamps.

## Capacity Estimation Notes

You can approximate per-tick CPU cost as:

`cost_per_tick ≈ cost_broadcast_encode + (cost_per_player_encode × players) + cost_targeted_events`

When `cost_per_tick × rooms` exceeds the system’s tick budget, the backlog grows and the test exceeds timeout. This change reduces the broadcast component from O(players) to O(1) per room.

## Edge Cases Covered
- join + leave reorder → serialized queue order
- leave while async send in-flight → version stamp drops stale send
- leave then rejoin quickly → old targeted events not delivered
- reevaluation/resolver results → commit only if membership version unchanged
