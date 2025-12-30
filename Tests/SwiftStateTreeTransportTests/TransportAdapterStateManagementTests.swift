// Tests/SwiftStateTreeTransportTests/TransportAdapterStateManagementTests.swift
//
// Tests for state management consistency - verifying computed properties and state synchronization

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct StateManagementTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Test("Connected sessions computed property correctly reflects connected but not joined sessions")
func testConnectedSessionsComputedProperty() async throws {
    // Arrange
    let definition = Land(
        "state-management-test",
        using: StateManagementTestState.self
    ) {
        Rules {
            OnJoin { (state: inout StateManagementTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<StateManagementTestState>(
        definition: definition,
        initialState: StateManagementTestState()
    )
    let adapter = TransportAdapter<StateManagementTestState>(
        keeper: keeper,
        transport: transport,
        landID: "state-management-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let session2 = SessionID("sess-2")
    let client1 = ClientID("cli-1")
    let client2 = ClientID("cli-2")

    // Act: Connect two sessions
    await adapter.onConnect(sessionID: session1, clientID: client1)
    await adapter.onConnect(sessionID: session2, clientID: client2)

    // Assert: Both should be connected but not joined
    let connected1 = await adapter.isConnected(sessionID: session1)
    let connected2 = await adapter.isConnected(sessionID: session2)
    let joined1 = await adapter.isJoined(sessionID: session1)
    let joined2 = await adapter.isJoined(sessionID: session2)

    #expect(connected1, "Session 1 should be connected")
    #expect(connected2, "Session 2 should be connected")
    #expect(!joined1, "Session 1 should not be joined")
    #expect(!joined2, "Session 2 should not be joined")
}

@Test("Joined sessions computed property correctly reflects joined sessions")
func testJoinedSessionsComputedProperty() async throws {
    // Arrange
    let definition = Land(
        "state-management-test",
        using: StateManagementTestState.self
    ) {
        Rules {
            OnJoin { (state: inout StateManagementTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<StateManagementTestState>(
        definition: definition,
        initialState: StateManagementTestState()
    )
    let adapter = TransportAdapter<StateManagementTestState>(
        keeper: keeper,
        transport: transport,
        landID: "state-management-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let session2 = SessionID("sess-2")
    let client1 = ClientID("cli-1")
    let client2 = ClientID("cli-2")

    // Act: Connect and join both sessions
    await adapter.onConnect(sessionID: session1, clientID: client1)
    await adapter.onConnect(sessionID: session2, clientID: client2)

    // Join session 1
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landType: "state-management-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try JSONEncoder().encode(joinRequest1)
    await adapter.onMessage(joinData1, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Join session 2
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landType: "state-management-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try JSONEncoder().encode(joinRequest2)
    await adapter.onMessage(joinData2, from: session2)
    try await Task.sleep(for: .milliseconds(50))

    // Assert: Both should be joined
    #expect(await adapter.isJoined(sessionID: session1), "Session 1 should be joined")
    #expect(await adapter.isJoined(sessionID: session2), "Session 2 should be joined")
    #expect(await adapter.isConnected(sessionID: session1), "Session 1 should still be connected")
    #expect(await adapter.isConnected(sessionID: session2), "Session 2 should still be connected")
}

@Test("Session to player mapping syncs with keeper players")
func testSessionToPlayerSyncWithKeeperPlayers() async throws {
    // Arrange
    let definition = Land(
        "state-management-test",
        using: StateManagementTestState.self
    ) {
        Rules {
            OnJoin { (state: inout StateManagementTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<StateManagementTestState>(
        definition: definition,
        initialState: StateManagementTestState()
    )
    let adapter = TransportAdapter<StateManagementTestState>(
        keeper: keeper,
        transport: transport,
        landID: "state-management-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")

    // Act: Connect and join
    await adapter.onConnect(sessionID: session1, clientID: client1)

    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "state-management-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Assert: Player should be in both adapter and keeper
    let playerID = await adapter.getPlayerID(for: session1)
    #expect(playerID != nil, "PlayerID should be set for session")

    let state = await keeper.currentState()
    if let pid = playerID {
        #expect(state.players[pid] == "Joined", "Player should be in keeper state")
    }
}

@Test("State query methods return correct values")
func testStateQueryMethods() async throws {
    // Arrange
    let definition = Land(
        "state-management-test",
        using: StateManagementTestState.self
    ) {
        Rules {
            OnJoin { (state: inout StateManagementTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<StateManagementTestState>(
        definition: definition,
        initialState: StateManagementTestState()
    )
    let adapter = TransportAdapter<StateManagementTestState>(
        keeper: keeper,
        transport: transport,
        landID: "state-management-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let session2 = SessionID("sess-2")
    let client1 = ClientID("cli-1")
    let client2 = ClientID("cli-2")

    // Act: Connect both, join only session1
    await adapter.onConnect(sessionID: session1, clientID: client1)
    await adapter.onConnect(sessionID: session2, clientID: client2)

    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "state-management-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Assert: Query methods should return correct values
    let connected1 = await adapter.isConnected(sessionID: session1)
    let connected2 = await adapter.isConnected(sessionID: session2)
    let joined1 = await adapter.isJoined(sessionID: session1)
    let joined2 = await adapter.isJoined(sessionID: session2)

    #expect(connected1, "Session 1 should be connected")
    #expect(connected2, "Session 2 should be connected")
    #expect(joined1, "Session 1 should be joined")
    #expect(!joined2, "Session 2 should not be joined")

    let playerID1 = await adapter.getPlayerID(for: session1)
    let playerID2 = await adapter.getPlayerID(for: session2)
    #expect(playerID1 != nil, "Session 1 should have a playerID")
    #expect(playerID2 == nil, "Session 2 should not have a playerID")

    if let pid1 = playerID1 {
        let sessions = await adapter.getSessions(for: pid1)
        #expect(sessions.contains(session1), "PlayerID should map to session1")
        #expect(sessions.count == 1, "PlayerID should map to exactly one session")
    }
}

