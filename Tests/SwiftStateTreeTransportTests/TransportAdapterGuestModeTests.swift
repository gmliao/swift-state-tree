// Tests/SwiftStateTreeTransportTests/TransportAdapterGuestModeTests.swift
//
// Tests for guest mode functionality (connections without JWT token)

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct GuestModeTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: PlayerInfo] = [:]
}

struct PlayerInfo: Codable, Sendable {
    let playerID: String
    let isGuest: Bool
    let deviceID: String?
    let metadata: [String: String]
}

// MARK: - Tests

@Test("Guest session is created when no JWT token is provided")
func testGuestSessionCreation() async throws {
    // Arrange
    let definition = Land(
        "guest-test",
        using: GuestModeTestState.self
    ) {
        Rules {
            OnJoin { (state: inout GuestModeTestState, ctx: LandContext) in
                let isGuest = ctx.metadata["isGuest"] == "true"
                state.players[ctx.playerID] = PlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    isGuest: isGuest,
                    deviceID: ctx.deviceID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<GuestModeTestState>(definition: definition, initialState: GuestModeTestState())
    let adapter = TransportAdapter<GuestModeTestState>(
        keeper: keeper,
        transport: transport,
        landID: "guest-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-guest-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect without JWT payload (guest mode)
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Act: Send join request (without playerID, should use guest session)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "guest-test",
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Guest session should be created
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(joined, "Session should be joined")
    
    let state = await keeper.currentState()
    // Guest playerID should start with "guest-"
    let guestPlayers = state.players.filter { $0.key.rawValue.hasPrefix("guest-") }
    #expect(guestPlayers.count == 1, "Should have one guest player")
    
    if let guestPlayer = guestPlayers.first {
        #expect(guestPlayer.value.isGuest == true, "Player should be marked as guest")
        #expect(guestPlayer.value.deviceID == clientID.rawValue, "Device ID should come from clientID")
        #expect(guestPlayer.value.metadata["isGuest"] == "true", "Metadata should contain isGuest flag")
    }
}

@Test("Guest session uses custom createGuestSession closure")
func testCustomGuestSession() async throws {
    // Arrange
    let definition = Land(
        "guest-test",
        using: GuestModeTestState.self
    ) {
        Rules {
            OnJoin { (state: inout GuestModeTestState, ctx: LandContext) in
                let isGuest = ctx.metadata["isGuest"] == "true"
                state.players[ctx.playerID] = PlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    isGuest: isGuest,
                    deviceID: ctx.deviceID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<GuestModeTestState>(definition: definition, initialState: GuestModeTestState())
    
    var customGuestSessionCalled = false
    let adapter = TransportAdapter<GuestModeTestState>(
        keeper: keeper,
        transport: transport,
        landID: "guest-test",
        createGuestSession: { sessionID, clientID in
            customGuestSessionCalled = true
            return PlayerSession(
                playerID: "custom-guest-\(sessionID.rawValue.prefix(4))",
                deviceID: clientID.rawValue,
                metadata: [
                    "isGuest": "true",
                    "custom": "true"
                ]
            )
        }
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-guest-2")
    let clientID = ClientID("cli-2")
    
    // Act: Connect without JWT payload
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Act: Send join request
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "guest-test",
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Custom guest session should be used
    #expect(customGuestSessionCalled, "Custom createGuestSession should be called")
    
    let state = await keeper.currentState()
    let customGuestPlayers = state.players.filter { $0.key.rawValue.hasPrefix("custom-guest-") }
    #expect(customGuestPlayers.count == 1, "Should have one custom guest player")
    
    if let guestPlayer = customGuestPlayers.first {
        #expect(guestPlayer.value.metadata["custom"] == "true", "Custom metadata should be present")
    }
}

@Test("JWT payload takes precedence over guest session")
func testJWTPayloadOverridesGuestSession() async throws {
    // Arrange
    let definition = Land(
        "guest-test",
        using: GuestModeTestState.self
    ) {
        Rules {
            OnJoin { (state: inout GuestModeTestState, ctx: LandContext) in
                let isGuest = ctx.metadata["isGuest"] == "true"
                state.players[ctx.playerID] = PlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    isGuest: isGuest,
                    deviceID: ctx.deviceID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<GuestModeTestState>(definition: definition, initialState: GuestModeTestState())
    let adapter = TransportAdapter<GuestModeTestState>(
        keeper: keeper,
        transport: transport,
        landID: "guest-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-jwt-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect with JWT payload
    let authInfo = AuthenticatedInfo(
        playerID: "player-jwt-123",
        deviceID: "device-jwt-456",
        metadata: ["username": "alice"]
    )
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    
    // Act: Send join request (without playerID, should use JWT payload, not guest session)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "guest-test",
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Should use JWT payload, not guest session
    let state = await keeper.currentState()
    let playerID = PlayerID("player-jwt-123")
    guard let playerInfo = state.players[playerID] else {
        Issue.record("Player should be in state after join")
        return
    }
    
    #expect(playerInfo.isGuest == false, "Player should not be marked as guest (has JWT)")
    #expect(playerInfo.playerID == "player-jwt-123", "Player ID should come from JWT payload")
    #expect(playerInfo.deviceID == "device-jwt-456", "Device ID should come from JWT payload")
    #expect(playerInfo.metadata["username"] == "alice", "Username should come from JWT payload")
    #expect(playerInfo.metadata["isGuest"] == nil, "JWT players should not have isGuest flag")
}

@Test("Join message fields take precedence over both JWT and guest session")
func testJoinMessageOverridesAll() async throws {
    // Arrange
    let definition = Land(
        "guest-test",
        using: GuestModeTestState.self
    ) {
        Rules {
            OnJoin { (state: inout GuestModeTestState, ctx: LandContext) in
                let isGuest = ctx.metadata["isGuest"] == "true"
                state.players[ctx.playerID] = PlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    isGuest: isGuest,
                    deviceID: ctx.deviceID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<GuestModeTestState>(definition: definition, initialState: GuestModeTestState())
    let adapter = TransportAdapter<GuestModeTestState>(
        keeper: keeper,
        transport: transport,
        landID: "guest-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-override-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect without JWT payload (would normally be guest)
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Act: Send join request WITH playerID (should override guest session)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "guest-test",
        playerID: "override-player-999",  // Override guest session
        deviceID: "override-device-999",  // Override guest session
        metadata: ["override": "true"]
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Should use join message values, not guest session
    let state = await keeper.currentState()
    let playerID = PlayerID("override-player-999")
    guard let playerInfo = state.players[playerID] else {
        Issue.record("Player should be in state after join")
        return
    }
    
    #expect(playerInfo.playerID == "override-player-999", "Player ID should come from join message")
    #expect(playerInfo.deviceID == "override-device-999", "Device ID should come from join message")
    #expect(playerInfo.metadata["override"] == "true", "Metadata should come from join message")
    // Note: isGuest might still be true if guest session metadata is merged, but join message takes precedence
}

@Test("Multiple guest sessions can coexist")
func testMultipleGuestSessions() async throws {
    // Arrange
    let definition = Land(
        "guest-test",
        using: GuestModeTestState.self
    ) {
        Rules {
            OnJoin { (state: inout GuestModeTestState, ctx: LandContext) in
                let isGuest = ctx.metadata["isGuest"] == "true"
                state.players[ctx.playerID] = PlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    isGuest: isGuest,
                    deviceID: ctx.deviceID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<GuestModeTestState>(definition: definition, initialState: GuestModeTestState())
    let adapter = TransportAdapter<GuestModeTestState>(
        keeper: keeper,
        transport: transport,
        landID: "guest-test"
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    // Act: Connect and join multiple guests
    for i in 1...3 {
        let sessionID = SessionID("sess-guest-\(i)")
        let clientID = ClientID("cli-\(i)")
        
        await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
        
        let joinRequest = TransportMessage.join(
            requestID: "join-\(i)",
            landID: "guest-test",
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: sessionID)
    }
    
    // Wait a bit for async processing
    try await Task.sleep(for: .milliseconds(200))
    
    // Assert: All guests should be in state
    let state = await keeper.currentState()
    let guestPlayers = state.players.filter { $0.key.rawValue.hasPrefix("guest-") }
    #expect(guestPlayers.count == 3, "Should have three guest players")
    
    for (_, playerInfo) in guestPlayers {
        #expect(playerInfo.isGuest == true, "All should be marked as guests")
    }
}

