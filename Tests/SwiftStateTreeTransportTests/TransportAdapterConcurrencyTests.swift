// Tests/SwiftStateTreeTransportTests/TransportAdapterConcurrencyTests.swift
//
// Tests for concurrency scenarios - multiple sessions, same playerID, rapid connect/disconnect

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct ConcurrencyTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]

    @Sync(.broadcast)
    var joinCount: Int = 0
}

// MARK: - Helper Types

actor ManagedCounter {
    private var count: Int = 0

    func increment() {
        count += 1
    }

    var value: Int {
        count
    }
}

actor LeaveTracker {
    private var called = false
    private var playerID: PlayerID?

    func record(playerID: PlayerID) {
        self.called = true
        self.playerID = playerID
    }

    func getInfo() -> (called: Bool, playerID: PlayerID?) {
        (called: called, playerID: playerID)
    }
}

// MARK: - Tests

@Test("Multiple sessions join in rapid succession")
func testMultipleSessionsJoinInRapidSuccession() async throws {
    // Arrange
    let definition = Land(
        "concurrency-test",
        using: ConcurrencyTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
                state.joinCount += 1
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ConcurrencyTestState>(
        definition: definition,
        initialState: ConcurrencyTestState()
    )
    let adapter = TransportAdapter<ConcurrencyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "concurrency-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    // Act: Connect and join multiple sessions in rapid succession
    let sessions = (1...5).map { SessionID("sess-\($0)") }
    let clients = (1...5).map { ClientID("cli-\($0)") }

    for (session, client) in zip(sessions, clients) {
        await adapter.onConnect(sessionID: session, clientID: client)
    }

    // Join all sessions rapidly (not truly concurrent, but rapid succession)
    for (index, session) in sessions.enumerated() {
        let joinRequest = TransportMessage.join(
            requestID: "join-\(index)",
            landType: "concurrency-test",
            landInstanceId: nil,
            playerID: "player-\(index)", // Use unique playerID for each session
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: session)
        // Small delay to allow processing
        // Increased delay for CI stability (was 10ms, now 30ms)
        try await Task.sleep(for: .milliseconds(30))
    }

    // Wait for all joins to complete
    // Increased delay for CI stability (was 100ms, now 150ms)
    try await Task.sleep(for: .milliseconds(150))

    // Assert: All sessions should be joined
    for session in sessions {
        let joined = await adapter.isJoined(sessionID: session)
        #expect(joined, "Session \(session.rawValue) should be joined")
    }

    // Assert: State should have all players
    let state = await keeper.currentState()
    let expectedPlayerIDs = (0..<5).map { PlayerID("player-\($0)") }
    for playerID in expectedPlayerIDs {
        #expect(state.players[playerID] == "Joined", "Player \(playerID.rawValue) should be in state")
    }
    #expect(state.players.count == 5, "State should have 5 players, got \(state.players.count)")
    #expect(state.joinCount == 5, "Join count should be 5, got \(state.joinCount)")
}

@Test("Duplicate playerID login kicks old session (Kick Old strategy)")
func testDuplicatePlayerIDKicksOldSession() async throws {
    // Arrange
    let onLeaveTracker = LeaveTracker()

    let definition = Land(
        "concurrency-test",
        using: ConcurrencyTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
                state.joinCount += 1
            }

            OnLeave { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
                Task {
                    await onLeaveTracker.record(playerID: ctx.playerID)
                }
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ConcurrencyTestState>(
        definition: definition,
        initialState: ConcurrencyTestState()
    )
    let adapter = TransportAdapter<ConcurrencyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "concurrency-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let sharedPlayerID = "shared-player"
    let session1 = SessionID("sess-1")
    let session2 = SessionID("sess-2")
    let client1 = ClientID("cli-1")
    let client2 = ClientID("cli-2")

    // Act: Connect both sessions
    await adapter.onConnect(sessionID: session1, clientID: client1)
    await adapter.onConnect(sessionID: session2, clientID: client2)

    // Act: Join first session with playerID
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landType: "concurrency-test",
        landInstanceId: nil,
        playerID: sharedPlayerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try JSONEncoder().encode(joinRequest1)
    await adapter.onMessage(joinData1, from: session1)

    try await Task.sleep(for: .milliseconds(50))

    // Assert: First session should be joined
    let joined1 = await adapter.isJoined(sessionID: session1)
    #expect(joined1, "Session 1 should be joined")

    // Act: Join second session with same playerID (should kick first session)
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landType: "concurrency-test",
        landInstanceId: nil,
        playerID: sharedPlayerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try JSONEncoder().encode(joinRequest2)
    await adapter.onMessage(joinData2, from: session2)

    try await Task.sleep(for: .milliseconds(100))

    // Assert: First session should be kicked (not joined)
    let joined1After = await adapter.isJoined(sessionID: session1)
    #expect(!joined1After, "Session 1 should be kicked after duplicate login")

    // Assert: Second session should be joined
    let joined2 = await adapter.isJoined(sessionID: session2)
    #expect(joined2, "Session 2 should be joined")

    // Assert: OnLeave should be called for the old session
    let leaveInfo = await onLeaveTracker.getInfo()
    #expect(leaveInfo.called, "OnLeave should be called when old session is kicked")
    #expect(leaveInfo.playerID?.rawValue == sharedPlayerID, "OnLeave should be called with correct playerID")

    // Assert: Only second session should map to playerID
    let playerID1 = await adapter.getPlayerID(for: session1)
    let playerID2 = await adapter.getPlayerID(for: session2)
    #expect(playerID1 == nil, "Session 1 should not map to playerID after being kicked")
    #expect(playerID2?.rawValue == sharedPlayerID, "Session 2 should map to playerID")

    // Assert: getSessions should return only second session
    let playerID = PlayerID(sharedPlayerID)
    let sessions = await adapter.getSessions(for: playerID)
    #expect(sessions.count == 1, "PlayerID should map to 1 session")
    #expect(sessions.contains(session2), "Sessions should include session2")
    #expect(!sessions.contains(session1), "Sessions should not include session1")

    // Assert: State should have the player (only once)
    let state = await keeper.currentState()
    #expect(state.players[playerID] == "Joined", "Player should be in state")
    #expect(state.joinCount == 2, "Join count should be 2 (first join + second join)")
}

@Test("Rapid connect and disconnect maintains state consistency")
func testRapidConnectDisconnect() async throws {
    // Arrange
    let definition = Land(
        "concurrency-test",
        using: ConcurrencyTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
                state.joinCount += 1
            }

            OnLeave { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ConcurrencyTestState>(
        definition: definition,
        initialState: ConcurrencyTestState()
    )
    let adapter = TransportAdapter<ConcurrencyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "concurrency-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    // Act: Rapidly connect, join, disconnect, reconnect, rejoin
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")

    for iteration in 1...3 {
        // Connect
        await adapter.onConnect(sessionID: session1, clientID: client1)

        // Join
        let joinRequest = TransportMessage.join(
            requestID: "join-\(iteration)",
            landType: "concurrency-test",
            landInstanceId: nil,
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: session1)
        // Increased delay for CI stability (was 20ms, now 50ms)
        try await Task.sleep(for: .milliseconds(50))

        // Verify joined
        let joined = await adapter.isJoined(sessionID: session1)
        #expect(joined, "Session should be joined in iteration \(iteration)")

        // Disconnect
        await adapter.onDisconnect(sessionID: session1, clientID: client1)
        // Increased delay for CI stability (was 20ms, now 50ms)
        try await Task.sleep(for: .milliseconds(50))

        // Verify not joined
        let notJoined = await adapter.isJoined(sessionID: session1)
        #expect(!notJoined, "Session should not be joined after disconnect in iteration \(iteration)")
    }

    // Final state check
    let state = await keeper.currentState()
    #expect(state.players.isEmpty, "State should be empty after all disconnects")
}

@Test("Join during leave maintains state consistency")
func testJoinDuringLeave() async throws {
    // Arrange
    let onJoinCallCount = ManagedCounter()
    let onLeaveCallCount = ManagedCounter()

    let definition = Land(
        "concurrency-test",
        using: ConcurrencyTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
                state.joinCount += 1
                Task {
                    await onJoinCallCount.increment()
                }
            }

            OnLeave { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
                Task {
                    await onLeaveCallCount.increment()
                }
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ConcurrencyTestState>(
        definition: definition,
        initialState: ConcurrencyTestState()
    )
    let adapter = TransportAdapter<ConcurrencyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "concurrency-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let playerID = "player-1"
    let session1 = SessionID("sess-1")
    let session2 = SessionID("sess-2")
    let client1 = ClientID("cli-1")
    let client2 = ClientID("cli-2")

    // Act: Connect and join first session
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landType: "concurrency-test",
        playerID: playerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try JSONEncoder().encode(joinRequest1)
    await adapter.onMessage(joinData1, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Act: Start leave, then immediately try to join with same playerID
    // Since LandKeeper is an actor, operations are serialized, so leave will complete before join
    let leaveTask = Task {
        await adapter.onDisconnect(sessionID: session1, clientID: client1)
    }

    // Immediately try to join with same playerID (should wait for leave to complete)
    await adapter.onConnect(sessionID: session2, clientID: client2)
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landType: "concurrency-test",
        landInstanceId: nil,
        playerID: playerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try JSONEncoder().encode(joinRequest2)
    await adapter.onMessage(joinData2, from: session2)

    await leaveTask.value
    try await Task.sleep(for: .milliseconds(100))

    // Assert: First session should be disconnected
    let joined1After = await adapter.isJoined(sessionID: session1)
    #expect(!joined1After, "Session 1 should not be joined")

    // Assert: Second session should be joined
    let joined2 = await adapter.isJoined(sessionID: session2)
    #expect(joined2, "Session 2 should be joined")

    // Assert: OnLeave should be called
    #expect(await onLeaveCallCount.value == 1, "OnLeave should be called once")

    // Assert: OnJoin should be called twice (first join + second join)
    #expect(await onJoinCallCount.value == 2, "OnJoin should be called twice")

    // Assert: State should have player (only one)
    let state = await keeper.currentState()
    let pid = PlayerID(playerID)
    #expect(state.players[pid] == "Joined", "Player should be in state")
    #expect(state.players.count == 1, "State should have exactly 1 player")
}

@Test("Rapid leave and join maintains state consistency")
func testRapidLeaveAndJoin() async throws {
    // Arrange
    let definition = Land(
        "concurrency-test",
        using: ConcurrencyTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
                state.joinCount += 1
            }

            OnLeave { (state: inout ConcurrencyTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ConcurrencyTestState>(
        definition: definition,
        initialState: ConcurrencyTestState()
    )
    let adapter = TransportAdapter<ConcurrencyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "concurrency-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let playerID = "player-1"
    let session = SessionID("sess-1")
    let client = ClientID("cli-1")

    // Act: Rapidly leave and join multiple times
    for iteration in 1...3 {
        // Connect
        await adapter.onConnect(sessionID: session, clientID: client)

        // Join
        let joinRequest = TransportMessage.join(
            requestID: "join-\(iteration)",
            landType: "concurrency-test",
            landInstanceId: nil,
            playerID: playerID,
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: session)
        // Increased delay for CI stability (was 20ms, now 50ms)
        try await Task.sleep(for: .milliseconds(50))

        // Verify joined
        let joined = await adapter.isJoined(sessionID: session)
        #expect(joined, "Session should be joined in iteration \(iteration)")

        // Disconnect
        await adapter.onDisconnect(sessionID: session, clientID: client)
        // Increased delay for CI stability (was 20ms, now 50ms)
        try await Task.sleep(for: .milliseconds(50))

        // Verify not joined
        let notJoined = await adapter.isJoined(sessionID: session)
        #expect(!notJoined, "Session should not be joined after disconnect in iteration \(iteration)")
    }

    // Final state check
    let state = await keeper.currentState()
    #expect(state.players.isEmpty, "State should be empty after all disconnects")
}

