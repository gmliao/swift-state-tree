// Tests/SwiftStateTreeTransportTests/TransportAdapterErrorHandlingTests.swift
//
// Tests for error handling and rollback mechanisms

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct ErrorHandlingTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]

    @Sync(.broadcast)
    var maxPlayers: Int = 2
}

// MARK: - Mock Transport that can fail (not used in current tests, but kept for future use)

// MARK: - Tests

@Test("Join failure rolls back sessionToPlayer")
func testJoinFailureRollback() async throws {
    // Arrange: Create a Land that denies join after first player
    let definition = Land(
        "error-handling-test",
        using: ErrorHandlingTestState.self
    ) {
        Rules {
            CanJoin { (state: ErrorHandlingTestState, session: PlayerSession, ctx: LandContext) in
                if state.players.count >= state.maxPlayers {
                    return .deny(reason: "Room is full")
                }
                return .allow(playerID: PlayerID(session.playerID))
            }

            OnJoin { (state: inout ErrorHandlingTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ErrorHandlingTestState>(
        definition: definition,
        initialState: ErrorHandlingTestState()
    )
    let adapter = TransportAdapter<ErrorHandlingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "error-handling-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let session2 = SessionID("sess-2")
    let client1 = ClientID("cli-1")
    let client2 = ClientID("cli-2")

    // Act: Join first player (should succeed)
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landType: "error-handling-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try JSONEncoder().encode(joinRequest1)
    await adapter.onMessage(joinData1, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Act: Join second player (should succeed)
    await adapter.onConnect(sessionID: session2, clientID: client2)
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landType: "error-handling-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try JSONEncoder().encode(joinRequest2)
    await adapter.onMessage(joinData2, from: session2)
    try await Task.sleep(for: .milliseconds(50))

    // Act: Try to join third player (should be denied)
    let session3 = SessionID("sess-3")
    let client3 = ClientID("cli-3")
    await adapter.onConnect(sessionID: session3, clientID: client3)
    let joinRequest3 = TransportMessage.join(
        requestID: "join-3",
        landType: "error-handling-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData3 = try JSONEncoder().encode(joinRequest3)
    await adapter.onMessage(joinData3, from: session3)
    try await Task.sleep(for: .milliseconds(50))

    // Assert: Third session should not be joined
    let joined3 = await adapter.isJoined(sessionID: session3)
    #expect(!joined3, "Session 3 should not be joined after denial")

    // Assert: First two sessions should still be joined
    let joined1 = await adapter.isJoined(sessionID: session1)
    let joined2 = await adapter.isJoined(sessionID: session2)
    #expect(joined1, "Session 1 should still be joined")
    #expect(joined2, "Session 2 should still be joined")

    // Assert: State should only have 2 players
    let state = await keeper.currentState()
    #expect(state.players.count == 2, "State should have exactly 2 players")
}

@Test("Duplicate join request is handled correctly")
func testDuplicateJoinRequest() async throws {
    // Arrange
    let definition = Land(
        "error-handling-test",
        using: ErrorHandlingTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ErrorHandlingTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ErrorHandlingTestState>(
        definition: definition,
        initialState: ErrorHandlingTestState()
    )
    let adapter = TransportAdapter<ErrorHandlingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "error-handling-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")

    // Act: Connect and join
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landType: "error-handling-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try JSONEncoder().encode(joinRequest1)
    await adapter.onMessage(joinData1, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Act: Try to join again (duplicate)
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landType: "error-handling-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try JSONEncoder().encode(joinRequest2)
    await adapter.onMessage(joinData2, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Assert: Should still be joined (only once)
    let joined1 = await adapter.isJoined(sessionID: session1)
    #expect(joined1, "Session 1 should still be joined")

    // Assert: State should only have 1 player
    let state = await keeper.currentState()
    #expect(state.players.count == 1, "State should have exactly 1 player")
}

@Test("Join after disconnect maintains state consistency")
func testJoinAfterDisconnect() async throws {
    // Arrange
    let definition = Land(
        "error-handling-test",
        using: ErrorHandlingTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ErrorHandlingTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }

            OnLeave { (state: inout ErrorHandlingTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ErrorHandlingTestState>(
        definition: definition,
        initialState: ErrorHandlingTestState()
    )
    let adapter = TransportAdapter<ErrorHandlingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "error-handling-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")

    // Act: Connect, join, disconnect
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landType: "error-handling-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try JSONEncoder().encode(joinRequest1)
    await adapter.onMessage(joinData1, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Verify joined
    let joined1Before = await adapter.isJoined(sessionID: session1)
    #expect(joined1Before, "Session 1 should be joined")

    // Disconnect
    await adapter.onDisconnect(sessionID: session1, clientID: client1)
    try await Task.sleep(for: .milliseconds(50))

    // Verify not joined
    let joined1After = await adapter.isJoined(sessionID: session1)
    #expect(!joined1After, "Session 1 should not be joined after disconnect")

    // Act: Reconnect and rejoin
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landType: "error-handling-test",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try JSONEncoder().encode(joinRequest2)
    await adapter.onMessage(joinData2, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Assert: Should be joined again
    let joined1Rejoin = await adapter.isJoined(sessionID: session1)
    #expect(joined1Rejoin, "Session 1 should be joined after rejoin")

    // Assert: State should have the player
    let state = await keeper.currentState()
    let playerID = PlayerID(session1.rawValue)
    #expect(state.players[playerID] == "Joined", "Player should be in state after rejoin")
}

@Test("Join request with mismatched landID is rejected")
func testJoinRequestWithMismatchedLandID() async throws {
    // Arrange
    let definition = Land(
        "error-handling-test",
        using: ErrorHandlingTestState.self
    ) {
        Rules {
            OnJoin { (state: inout ErrorHandlingTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }

    let transport = WebSocketTransport()
    let keeper = LandKeeper<ErrorHandlingTestState>(
        definition: definition,
        initialState: ErrorHandlingTestState()
    )
    let adapter = TransportAdapter<ErrorHandlingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "error-handling-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")

    // Act: Connect
    await adapter.onConnect(sessionID: session1, clientID: client1)

    // Act: Try to join with wrong landID
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "wrong-land-id",
            landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))

    // Assert: Should not be joined
    let joined1 = await adapter.isJoined(sessionID: session1)
    #expect(!joined1, "Session 1 should not be joined with wrong landID")

    // Assert: State should be empty
    let state = await keeper.currentState()
    #expect(state.players.isEmpty, "State should be empty")
}

