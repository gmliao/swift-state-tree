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
        landID: "concurrency-test"
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
            landID: "concurrency-test",
            playerID: "player-\(index)", // Use unique playerID for each session
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: session)
        // Small delay to allow processing
        try await Task.sleep(for: .milliseconds(10))
    }
    
    // Wait for all joins to complete
    try await Task.sleep(for: .milliseconds(100))
    
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

@Test("Same playerID with multiple sessions")
func testSamePlayerIDMultipleSessions() async throws {
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
        landID: "concurrency-test"
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
    
    // Act: Join both with same playerID
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landID: "concurrency-test",
        playerID: sharedPlayerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try JSONEncoder().encode(joinRequest1)
    await adapter.onMessage(joinData1, from: session1)
    
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landID: "concurrency-test",
        playerID: sharedPlayerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try JSONEncoder().encode(joinRequest2)
    await adapter.onMessage(joinData2, from: session2)
    
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Both sessions should be joined
    let joined1 = await adapter.isJoined(sessionID: session1)
    let joined2 = await adapter.isJoined(sessionID: session2)
    #expect(joined1, "Session 1 should be joined")
    #expect(joined2, "Session 2 should be joined")
    
    // Assert: Both should map to same playerID
    let playerID1 = await adapter.getPlayerID(for: session1)
    let playerID2 = await adapter.getPlayerID(for: session2)
    #expect(playerID1 == playerID2, "Both sessions should map to same playerID")
    #expect(playerID1?.rawValue == sharedPlayerID, "PlayerID should match requested")
    
    // Assert: getSessions should return both sessions
    if let pid = playerID1 {
        let sessions = await adapter.getSessions(for: pid)
        #expect(sessions.count == 2, "PlayerID should map to 2 sessions")
        #expect(sessions.contains(session1), "Sessions should include session1")
        #expect(sessions.contains(session2), "Sessions should include session2")
    }
    
    // Assert: State should have the player (only once, as it's the same playerID)
    let state = await keeper.currentState()
    let playerID = PlayerID(sharedPlayerID)
    #expect(state.players[playerID] == "Joined", "Player should be in state")
    #expect(state.joinCount == 1, "Join count should be 1 (same playerID)")
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
        landID: "concurrency-test"
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
            landID: "concurrency-test",
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: session1)
        try await Task.sleep(for: .milliseconds(20))
        
        // Verify joined
        let joined = await adapter.isJoined(sessionID: session1)
        #expect(joined, "Session should be joined in iteration \(iteration)")
        
        // Disconnect
        await adapter.onDisconnect(sessionID: session1, clientID: client1)
        try await Task.sleep(for: .milliseconds(20))
        
        // Verify not joined
        let notJoined = await adapter.isJoined(sessionID: session1)
        #expect(!notJoined, "Session should not be joined after disconnect in iteration \(iteration)")
    }
    
    // Final state check
    let state = await keeper.currentState()
    #expect(state.players.isEmpty, "State should be empty after all disconnects")
}

