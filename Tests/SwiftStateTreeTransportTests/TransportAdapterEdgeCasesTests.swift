// Tests/SwiftStateTreeTransportTests/TransportAdapterEdgeCasesTests.swift
//
// Tests for edge cases - invalid metadata, custom playerID, deviceID handling, etc.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct EdgeCasesTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var metadata: [PlayerID: [String: String]] = [:]
}

// MARK: - Tests

@Test("Join with custom playerID is handled correctly")
func testJoinWithCustomPlayerID() async throws {
    // Arrange
    let definition = Land(
        "edge-cases-test",
        using: EdgeCasesTestState.self
    ) {
        Rules {
            OnJoin { (state: inout EdgeCasesTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<EdgeCasesTestState>(
        definition: definition,
        initialState: EdgeCasesTestState()
    )
    let adapter = TransportAdapter<EdgeCasesTestState>(
        keeper: keeper,
        transport: transport,
        landID: "edge-cases-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    let customPlayerID = "custom-player-123"
    
    // Act: Connect and join with custom playerID
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "edge-cases-test",
        landInstanceId: nil,
        playerID: customPlayerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Should be joined with custom playerID
    let joined = await adapter.isJoined(sessionID: session1)
    #expect(joined, "Session should be joined")
    
    let playerID = await adapter.getPlayerID(for: session1)
    #expect(playerID?.rawValue == customPlayerID, "PlayerID should match custom value")
    
    // Assert: State should have the custom playerID
    let state = await keeper.currentState()
    let expectedPlayerID = PlayerID(customPlayerID)
    #expect(state.players[expectedPlayerID] == "Joined", "Custom playerID should be in state")
}

@Test("Join with deviceID is accepted")
func testJoinWithDeviceID() async throws {
    // Arrange
    let definition = Land(
        "edge-cases-test",
        using: EdgeCasesTestState.self
    ) {
        Rules {
            OnJoin { (state: inout EdgeCasesTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<EdgeCasesTestState>(
        definition: definition,
        initialState: EdgeCasesTestState()
    )
    let adapter = TransportAdapter<EdgeCasesTestState>(
        keeper: keeper,
        transport: transport,
        landID: "edge-cases-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    let deviceID = "device-abc-123"
    
    // Act: Connect and join with deviceID
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "edge-cases-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: deviceID,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Should be joined (deviceID is accepted even if not stored in state)
    let joined = await adapter.isJoined(sessionID: session1)
    #expect(joined, "Session should be joined with deviceID")
    
    // Assert: Player should be in state
    let state = await keeper.currentState()
    let playerID = PlayerID(session1.rawValue)
    #expect(state.players[playerID] == "Joined", "Player should be in state")
}

@Test("Join with metadata is accepted")
func testJoinWithMetadata() async throws {
    // Arrange
    let definition = Land(
        "edge-cases-test",
        using: EdgeCasesTestState.self
    ) {
        Rules {
            OnJoin { (state: inout EdgeCasesTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<EdgeCasesTestState>(
        definition: definition,
        initialState: EdgeCasesTestState()
    )
    let adapter = TransportAdapter<EdgeCasesTestState>(
        keeper: keeper,
        transport: transport,
        landID: "edge-cases-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    let metadata: [String: AnyCodable] = [
        "level": .init(10),
        "team": .init("red"),
        "score": .init(1000)
    ]
    
    // Act: Connect and join with metadata
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "edge-cases-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: metadata
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Should be joined (metadata is accepted even if not stored in state)
    let joined = await adapter.isJoined(sessionID: session1)
    #expect(joined, "Session should be joined with metadata")
    
    // Assert: Player should be in state
    let state = await keeper.currentState()
    let playerID = PlayerID(session1.rawValue)
    #expect(state.players[playerID] == "Joined", "Player should be in state")
}

@Test("Join request without connection is rejected")
func testJoinRequestWithoutConnection() async throws {
    // Arrange
    let definition = Land(
        "edge-cases-test",
        using: EdgeCasesTestState.self
    ) {
        Rules {
            OnJoin { (state: inout EdgeCasesTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<EdgeCasesTestState>(
        definition: definition,
        initialState: EdgeCasesTestState()
    )
    let adapter = TransportAdapter<EdgeCasesTestState>(
        keeper: keeper,
        transport: transport,
        landID: "edge-cases-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    
    // Act: Try to join without connecting first
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "edge-cases-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Should not be joined
    let joined = await adapter.isJoined(sessionID: session1)
    #expect(!joined, "Session should not be joined without connection")
    
    // Assert: State should be empty
    let state = await keeper.currentState()
    #expect(state.players.isEmpty, "State should be empty")
}

@Test("Join with empty metadata is handled correctly")
func testJoinWithEmptyMetadata() async throws {
    // Arrange
    let definition = Land(
        "edge-cases-test",
        using: EdgeCasesTestState.self
    ) {
        Rules {
            OnJoin { (state: inout EdgeCasesTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
                state.metadata[ctx.playerID] = ctx.metadata
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<EdgeCasesTestState>(
        definition: definition,
        initialState: EdgeCasesTestState()
    )
    let adapter = TransportAdapter<EdgeCasesTestState>(
        keeper: keeper,
        transport: transport,
        landID: "edge-cases-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    
    // Act: Connect and join with empty metadata
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "edge-cases-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: [:]
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Should be joined
    let joined = await adapter.isJoined(sessionID: session1)
    #expect(joined, "Session should be joined")
    
    // Assert: State should have empty metadata
    let state = await keeper.currentState()
    let playerID = PlayerID(session1.rawValue)
    let storedMetadata = state.metadata[playerID]
    #expect(storedMetadata != nil, "Metadata should exist")
    #expect(storedMetadata?.isEmpty == true, "Metadata should be empty")
}

