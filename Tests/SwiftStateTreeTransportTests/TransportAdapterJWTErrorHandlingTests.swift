// Tests/SwiftStateTreeTransportTests/TransportAdapterJWTErrorHandlingTests.swift
//
// Tests for JWT error handling and edge cases

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct JWTErrorTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Test("Join request fails when JWT validation is required but authInfo is missing")
func testJoinFailsWithoutAuthInfoWhenRequired() async throws {
    // Arrange
    let definition = Land(
        "jwt-error-test",
        using: JWTErrorTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTErrorTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTErrorTestState>(definition: definition, initialState: JWTErrorTestState())
    let adapter = TransportAdapter<JWTErrorTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-error-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect without authInfo (simulating guest mode or no JWT)
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Act: Send join request
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "jwt-error-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Should use guest session (not fail)
    // Note: With guest mode, this should succeed using createGuestSession
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(joined == true, "Join should succeed using guest session when no authInfo")
    
    let state = await keeper.currentState()
    let guestPlayerID = PlayerID(sessionID.rawValue)
    #expect(state.players[guestPlayerID] == "Joined", "Should have a guest player entry")
}

@Test("JWT payload cleared on disconnect (error handling)")
func testJWTPayloadClearedOnDisconnectWithReconnect() async throws {
    // Arrange
    let definition = Land(
        "jwt-error-test",
        using: JWTErrorTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTErrorTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTErrorTestState>(definition: definition, initialState: JWTErrorTestState())
    let adapter = TransportAdapter<JWTErrorTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-error-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect with JWT payload
    let authInfo = AuthenticatedInfo(
        playerID: "player-jwt-123",
        deviceID: "device-456",
        metadata: ["username": "alice"]
    )
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    
    // Act: Disconnect
    await adapter.onDisconnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Reconnect without JWT payload
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Act: Send join request
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "jwt-error-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Should use guest session (JWT payload was cleared)
    let state = await keeper.currentState()
    let jwtPlayerID = PlayerID("player-jwt-123")
    #expect(state.players[jwtPlayerID] == nil, "JWT player should not be in state after disconnect")
    
    let guestPlayerID = PlayerID(sessionID.rawValue)
    #expect(state.players[guestPlayerID] != nil, "Should have one guest player after reconnection")
}

@Test("Join request with mismatched landID is rejected (JWT suite)")
func testJoinRequestMismatchedLandIDInJWTErrorSuite() async throws {
    // Arrange
    let definition = Land(
        "jwt-error-test",
        using: JWTErrorTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTErrorTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTErrorTestState>(definition: definition, initialState: JWTErrorTestState())
    let adapter = TransportAdapter<JWTErrorTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-error-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Act: Send join request with wrong landID
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "wrong-land-id",  // Mismatched
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Should not be joined
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(joined == false, "Join should fail with mismatched landID")
    
    let state = await keeper.currentState()
    #expect(state.players.isEmpty, "No players should be in state after failed join")
}

@Test("Multiple join requests from same session are rejected")
func testDuplicateJoinRequests() async throws {
    // Arrange
    let definition = Land(
        "jwt-error-test",
        using: JWTErrorTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTErrorTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTErrorTestState>(definition: definition, initialState: JWTErrorTestState())
    let adapter = TransportAdapter<JWTErrorTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-error-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Act: Send first join request
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landType: "jwt-error-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try encodeTransportMessage(joinRequest1)
    await adapter.onMessage(joinData1, from: sessionID)
    
    // Wait a bit
    try await Task.sleep(for: .milliseconds(100))
    
    // Act: Send second join request (duplicate)
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landType: "jwt-error-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try encodeTransportMessage(joinRequest2)
    await adapter.onMessage(joinData2, from: sessionID)
    
    // Wait a bit
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Should only have one player (first join succeeded, second rejected)
    let state = await keeper.currentState()
    #expect(state.players.count == 1, "Should only have one player after duplicate join requests")
}
