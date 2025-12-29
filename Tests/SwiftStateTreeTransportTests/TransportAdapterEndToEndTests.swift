// Tests/SwiftStateTreeTransportTests/TransportAdapterEndToEndTests.swift
//
// End-to-end tests for complete JWT and guest mode flows

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct EndToEndTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: EndToEndPlayerInfo] = [:]
    
    @Sync(.broadcast)
    var messageCount: Int = 0
}

struct EndToEndPlayerInfo: Codable, Sendable {
    let playerID: String
    let isGuest: Bool
    let username: String?
    let deviceID: String?
    let metadata: [String: String]
}

// MARK: - Tests

@Test("Complete flow: JWT authenticated user joins and interacts")
func testCompleteJWTFlow() async throws {
    // Arrange
    let definition = Land(
        "e2e-test",
        using: EndToEndTestState.self
    ) {
        Rules {
            OnJoin { (state: inout EndToEndTestState, ctx: LandContext) in
                let isGuest = ctx.metadata["isGuest"] == "true"
                let username = ctx.metadata["username"]
                state.players[ctx.playerID] = EndToEndPlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    isGuest: isGuest,
                    username: username,
                    deviceID: ctx.deviceID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<EndToEndTestState>(definition: definition, initialState: EndToEndTestState())
    let adapter = TransportAdapter<EndToEndTestState>(
        keeper: keeper,
        transport: transport,
        landID: "e2e-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-jwt-1")
    let clientID = ClientID("cli-1")
    
    // Step 1: Connect with JWT payload
    let authInfo = AuthenticatedInfo(
        playerID: "player-jwt-123",
        deviceID: "device-456",
        metadata: [
            "username": "alice",
            "schoolid": "school-789",
            "level": "10"
        ]
    )
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    
    // Step 2: Send join request
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "e2e-test",
        landInstanceId: nil,
        playerID: nil,  // Use JWT payload
        deviceID: nil,  // Use JWT payload
        metadata: nil  // Use JWT payload
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait for processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Step 3: Verify join
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(joined == true, "Session should be joined")
    
    let state = await keeper.currentState()
    let playerID = PlayerID("player-jwt-123")
    guard let playerInfo = state.players[playerID] else {
        Issue.record("Player should be in state after join")
        return
    }
    
    // Step 4: Verify JWT payload was used
    #expect(playerInfo.isGuest == false, "Player should not be guest (has JWT)")
    #expect(playerInfo.username == "alice", "Username should come from JWT payload")
    #expect(playerInfo.deviceID == "device-456", "Device ID should come from JWT payload")
    #expect(playerInfo.metadata["schoolid"] == "school-789", "School ID should come from JWT payload")
    #expect(playerInfo.metadata["level"] == "10", "Level should come from JWT payload")
}

@Test("Complete flow: Guest user joins and interacts")
func testCompleteGuestFlow() async throws {
    // Arrange
    let definition = Land(
        "e2e-test",
        using: EndToEndTestState.self
    ) {
        Rules {
            OnJoin { (state: inout EndToEndTestState, ctx: LandContext) in
                let isGuest = ctx.metadata["isGuest"] == "true"
                let username = ctx.metadata["username"]
                state.players[ctx.playerID] = EndToEndPlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    isGuest: isGuest,
                    username: username,
                    deviceID: ctx.deviceID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<EndToEndTestState>(definition: definition, initialState: EndToEndTestState())
    let adapter = TransportAdapter<EndToEndTestState>(
        keeper: keeper,
        transport: transport,
        landID: "e2e-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-guest-1")
    let clientID = ClientID("cli-guest-1")
    
    // Step 1: Connect without JWT payload (guest mode)
    await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil)
    
    // Step 2: Send join request
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "e2e-test",
        landInstanceId: nil,
        playerID: nil,  // Will use guest session
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait for processing
    try await Task.sleep(for: .milliseconds(100))
    
    // Step 3: Verify join
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(joined == true, "Guest session should be joined")
    
    let state = await keeper.currentState()
    let guestPlayerID = PlayerID(sessionID.rawValue)
    guard let guestPlayer = state.players[guestPlayerID] else {
        Issue.record("Guest player should be present after join")
        return
    }
    
    // Step 4: Verify guest session was used
    #expect(guestPlayer.isGuest == true, "Player should be marked as guest")
    #expect(guestPlayer.deviceID == clientID.rawValue, "Device ID should come from clientID")
    #expect(guestPlayer.metadata["isGuest"] == "true", "Metadata should contain isGuest flag")
}

@Test("Complete flow: Mixed JWT and guest users")
func testMixedJWTAndGuestUsers() async throws {
    // Arrange
    let definition = Land(
        "e2e-test",
        using: EndToEndTestState.self
    ) {
        Rules {
            OnJoin { (state: inout EndToEndTestState, ctx: LandContext) in
                let isGuest = ctx.metadata["isGuest"] == "true"
                let username = ctx.metadata["username"]
                state.players[ctx.playerID] = EndToEndPlayerInfo(
                    playerID: ctx.playerID.rawValue,
                    isGuest: isGuest,
                    username: username,
                    deviceID: ctx.deviceID,
                    metadata: ctx.metadata
                )
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<EndToEndTestState>(definition: definition, initialState: EndToEndTestState())
    let adapter = TransportAdapter<EndToEndTestState>(
        keeper: keeper,
        transport: transport,
        landID: "e2e-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    // Step 1: JWT user joins
    let jwtSessionID = SessionID("sess-jwt-1")
    let jwtClientID = ClientID("cli-jwt-1")
    let jwtAuthInfo = AuthenticatedInfo(
        playerID: "player-jwt-123",
        deviceID: "device-jwt-456",
        metadata: ["username": "alice"]
    )
    await adapter.onConnect(sessionID: jwtSessionID, clientID: jwtClientID, authInfo: jwtAuthInfo)
    
    let jwtJoinRequest = TransportMessage.join(
        requestID: "join-jwt-1",
        landType: "e2e-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let jwtJoinData = try encodeTransportMessage(jwtJoinRequest)
    await adapter.onMessage(jwtJoinData, from: jwtSessionID)
    
    // Step 2: Guest user joins
    let guestSessionID = SessionID("sess-guest-1")
    let guestClientID = ClientID("cli-guest-1")
    await adapter.onConnect(sessionID: guestSessionID, clientID: guestClientID, authInfo: nil)
    
    let guestJoinRequest = TransportMessage.join(
        requestID: "join-guest-1",
        landType: "e2e-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let guestJoinData = try encodeTransportMessage(guestJoinRequest)
    await adapter.onMessage(guestJoinData, from: guestSessionID)
    
    // Wait for processing
    try await Task.sleep(for: .milliseconds(200))
    
    // Step 3: Verify both users are in state
    let state = await keeper.currentState()
    #expect(state.players.count == 2, "Should have two players (one JWT, one guest)")
    
    let jwtPlayerID = PlayerID("player-jwt-123")
    guard let jwtPlayer = state.players[jwtPlayerID] else {
        Issue.record("JWT player should be in state")
        return
    }
    #expect(jwtPlayer.isGuest == false, "JWT player should not be guest")
    #expect(jwtPlayer.username == "alice", "JWT player should have username")
    
    let guestPlayerID = PlayerID(guestSessionID.rawValue)
    if let guestPlayer = state.players[guestPlayerID] {
        #expect(guestPlayer.isGuest == true, "Guest player should be marked as guest")
    } else {
        Issue.record("Guest player should be in state")
    }
}
