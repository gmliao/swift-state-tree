// Tests/SwiftStateTreeTransportTests/TransportAdapterJWTPayloadTests.swift
//
// Tests for JWT payload passing to Land layer, including custom fields (username, schoolid, etc.)

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeHummingbird

// MARK: - Test State

@StateNodeBuilder
struct JWTPayloadTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: JWTPayloadPlayerInfo] = [:]
}

struct JWTPayloadPlayerInfo: Codable, Sendable {
    let playerID: String
    let username: String?
    let schoolID: String?
    let metadata: [String: String]
}

// MARK: - Tests

@Test("JWT payload with custom fields is passed to OnJoin handler")
func testJWTPayloadWithCustomFields() async throws {
    // Arrange
    let definition = Land(
        "jwt-test",
        using: JWTPayloadTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTPayloadTestState, ctx: LandContext) in
                // Extract custom fields from metadata
                let username = ctx.metadata["username"]
                let schoolID = ctx.metadata["schoolid"]
                
                state.players[ctx.playerID] = JWTPayloadPlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    username: username,
                    schoolID: schoolID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTPayloadTestState>(definition: definition, initialState: JWTPayloadTestState())
    let adapter = TransportAdapter<JWTPayloadTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Create JWT payload with custom fields
    let authInfo = AuthenticatedInfo(
        playerID: "player-123",
        deviceID: "device-456",
        metadata: [
            "username": "alice",
            "schoolid": "school-789",
            "level": "10"
        ]
    )
    
    // Act: Connect with JWT payload
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    
    // Act: Send join request (without playerID, should use JWT payload)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "jwt-test",
        playerID: nil, // Not provided, should use JWT payload
        deviceID: nil, // Not provided, should use JWT payload
        metadata: nil // Not provided, should use JWT payload
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Player should be joined with JWT payload information
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(joined, "Session should be joined")
    
    let state = await keeper.currentState()
    let playerID = PlayerID("player-123")
    guard let playerInfo = state.players[playerID] else {
        Issue.record("Player should be in state after join")
        return
    }
    
    #expect(playerInfo.playerID == "player-123", "Player ID should come from JWT payload")
    #expect(playerInfo.username == "alice", "Username should come from JWT payload metadata")
    #expect(playerInfo.schoolID == "school-789", "School ID should come from JWT payload metadata")
    #expect(playerInfo.metadata["level"] == "10", "Level should come from JWT payload metadata")
}

@Test("Join message metadata overrides JWT payload metadata")
func testJoinMessageMetadataOverridesJWTPayload() async throws {
    // Arrange
    let definition = Land(
        "jwt-test",
        using: JWTPayloadTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTPayloadTestState, ctx: LandContext) in
                let username = ctx.metadata["username"]
                let schoolID = ctx.metadata["schoolid"]
                
                state.players[ctx.playerID] = JWTPayloadPlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    username: username,
                    schoolID: schoolID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTPayloadTestState>(definition: definition, initialState: JWTPayloadTestState())
    let adapter = TransportAdapter<JWTPayloadTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Create JWT payload with initial metadata
    let authInfo = AuthenticatedInfo(
        playerID: "player-123",
        deviceID: "device-456",
        metadata: [
            "username": "alice",
            "schoolid": "school-789"
        ]
    )
    
    // Act: Connect with JWT payload
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    
    // Act: Send join request with overriding metadata
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "jwt-test",
        playerID: nil,
        deviceID: nil,
        metadata: [
            "username": AnyCodable("bob"), // Override JWT payload username
            "level": AnyCodable("20") // Additional field
        ]
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Join message metadata should override JWT payload metadata
    let state = await keeper.currentState()
    let playerID = PlayerID("player-123")
    guard let playerInfo = state.players[playerID] else {
        Issue.record("Player should be in state after join")
        return
    }
    
    #expect(playerInfo.username == "bob", "Username should be overridden by join message")
    #expect(playerInfo.schoolID == "school-789", "School ID should still come from JWT payload (not overridden)")
    #expect(playerInfo.metadata["level"] == "20", "Level should come from join message")
}

@Test("JWT payload playerID is used when join message doesn't provide one")
func testJWTPayloadPlayerIDUsedWhenNotProvided() async throws {
    // Arrange
    let definition = Land(
        "jwt-test",
        using: JWTPayloadTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTPayloadTestState, ctx: LandContext) in
                state.players[ctx.playerID] = JWTPayloadPlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    username: ctx.metadata["username"],
                    schoolID: ctx.metadata["schoolid"],
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTPayloadTestState>(definition: definition, initialState: JWTPayloadTestState())
    let adapter = TransportAdapter<JWTPayloadTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Create JWT payload with playerID
    let authInfo = AuthenticatedInfo(
        playerID: "jwt-player-123",
        deviceID: "jwt-device-456",
        metadata: ["username": "alice"]
    )
    
    // Act: Connect with JWT payload
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    
    // Act: Send join request WITHOUT playerID (should use JWT payload)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "jwt-test",
        playerID: nil, // Not provided, should use JWT payload
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Player ID from JWT payload should be used
    let state = await keeper.currentState()
    let playerID = PlayerID("jwt-player-123")
    #expect(state.players[playerID] != nil, "Player with JWT payload playerID should be in state")
    
    // Assert: Session should be mapped to JWT payload playerID
    let joinedPlayerID = await adapter.getPlayerID(for: sessionID)
    #expect(joinedPlayerID == playerID, "Session should be mapped to JWT payload playerID")
}

@Test("Join message playerID overrides JWT payload playerID")
func testJoinMessagePlayerIDOverridesJWTPayload() async throws {
    // Arrange
    let definition = Land(
        "jwt-test",
        using: JWTPayloadTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTPayloadTestState, ctx: LandContext) in
                state.players[ctx.playerID] = JWTPayloadPlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    username: ctx.metadata["username"],
                    schoolID: ctx.metadata["schoolid"],
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTPayloadTestState>(definition: definition, initialState: JWTPayloadTestState())
    let adapter = TransportAdapter<JWTPayloadTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Create JWT payload with playerID
    let authInfo = AuthenticatedInfo(
        playerID: "jwt-player-123",
        deviceID: "jwt-device-456",
        metadata: ["username": "alice"]
    )
    
    // Act: Connect with JWT payload
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    
    // Act: Send join request WITH playerID (should override JWT payload)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "jwt-test",
        playerID: "join-player-999", // Override JWT payload
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Player ID from join message should be used
    let state = await keeper.currentState()
    let playerID = PlayerID("join-player-999")
    #expect(state.players[playerID] != nil, "Player with join message playerID should be in state")
    
    // Assert: JWT payload playerID should NOT be used
    let jwtPlayerID = PlayerID("jwt-player-123")
    #expect(state.players[jwtPlayerID] == nil, "JWT payload playerID should not be in state")
    
    // Assert: Session should be mapped to join message playerID
    let joinedPlayerID = await adapter.getPlayerID(for: sessionID)
    #expect(joinedPlayerID == playerID, "Session should be mapped to join message playerID")
}

@Test("JWT payload cleared on disconnect falls back to guest session")
func testJWTPayloadClearedOnDisconnectFallsBackToGuest() async throws {
    // Arrange
    let definition = Land(
        "jwt-test",
        using: JWTPayloadTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JWTPayloadTestState, ctx: LandContext) in
                state.players[ctx.playerID] = JWTPayloadPlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    username: ctx.metadata["username"],
                    schoolID: ctx.metadata["schoolid"],
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JWTPayloadTestState>(definition: definition, initialState: JWTPayloadTestState())
    let adapter = TransportAdapter<JWTPayloadTestState>(
        keeper: keeper,
        transport: transport,
        landID: "jwt-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Create JWT payload
    let authInfo = AuthenticatedInfo(
        playerID: "player-123",
        deviceID: "device-456",
        metadata: ["username": "alice"]
    )
    
    // Act: Connect with JWT payload
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    
    // Act: Disconnect
    await adapter.onDisconnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Reconnect (without JWT payload this time)
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Act: Send join request (should use createGuestSession, not JWT payload)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "jwt-test",
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Should use default playerID (sessionID), not JWT payload playerID
    let state = await keeper.currentState()
    let defaultPlayerID = PlayerID(sessionID.rawValue)
    #expect(state.players[defaultPlayerID] != nil, "Should use default playerID after disconnect (JWT payload cleared)")
    
    let jwtPlayerID = PlayerID("player-123")
    #expect(state.players[jwtPlayerID] == nil, "JWT payload playerID should not be used after disconnect")
}
