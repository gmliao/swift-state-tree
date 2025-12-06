// Tests/SwiftStateTreeTransportTests/TransportAdapterJoinTests.swift
//
// Tests for join request handling - verifying that connect and join are separated

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct JoinTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Test("Connect does not automatically join")
func testConnectDoesNotAutoJoin() async throws {
    // Arrange
    let definition = Land(
        "join-test",
        using: JoinTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JoinTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JoinTestState>(definition: definition, initialState: JoinTestState())
    let adapter = TransportAdapter<JoinTestState>(
        keeper: keeper,
        transport: transport,
        landID: "join-test"
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect (should NOT join)
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Assert: Player should NOT be in state (not joined yet)
    let state = await keeper.currentState()
    let playerID = PlayerID(sessionID.rawValue)
    #expect(state.players[playerID] == nil, "Player should not be in state after connect (not joined)")
}

@Test("Join request after connect successfully joins")
func testJoinRequestAfterConnect() async throws {
    // Arrange
    let definition = Land(
        "join-test",
        using: JoinTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JoinTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JoinTestState>(definition: definition, initialState: JoinTestState())
    let adapter = TransportAdapter<JoinTestState>(
        keeper: keeper,
        transport: transport,
        landID: "join-test"
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Send join request
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "join-test",
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for join to complete
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Player should be in state (joined)
    let state = await keeper.currentState()
    let playerID = PlayerID(sessionID.rawValue)
    #expect(state.players[playerID] == "Joined", "Player should be in state after join")
}

@Test("Messages from non-joined session are rejected")
func testMessagesFromNonJoinedSessionRejected() async throws {
    // Arrange
    let definition = Land(
        "join-test",
        using: JoinTestState.self
    ) {
        Rules { }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JoinTestState>(definition: definition, initialState: JoinTestState())
    let adapter = TransportAdapter<JoinTestState>(
        keeper: keeper,
        transport: transport,
        landID: "join-test"
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect (but don't join)
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Try to send event (should be rejected)
    let incrementEvent = AnyClientEvent(TestIncrementEvent())
    let transportMsg = TransportMessage.event(landID: "join-test", event: .fromClient(incrementEvent))
    let data = try JSONEncoder().encode(transportMsg)
    
    await adapter.onMessage(data, from: sessionID)
    
    // Assert: State should not change (event was rejected)
    let state = await keeper.currentState()
    #expect(state.ticks == 0, "State should not change if session has not joined")
}

@Test("Join request with mismatched landID is rejected")
func testJoinRequestMismatchedLandID() async throws {
    // Arrange
    let definition = Land(
        "join-test",
        using: JoinTestState.self
    ) {
        Rules { }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JoinTestState>(definition: definition, initialState: JoinTestState())
    let adapter = TransportAdapter<JoinTestState>(
        keeper: keeper,
        transport: transport,
        landID: "join-test"
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Send join request with wrong landID
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "wrong-land",
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit
    try await Task.sleep(for: .milliseconds(10))
    
    // Assert: Player should NOT be in state (join was rejected)
    let state = await keeper.currentState()
    let playerID = PlayerID(sessionID.rawValue)
    #expect(state.players[playerID] == nil, "Player should not be in state after rejected join")
}

@Test("Cannot send messages before join, can send after join")
func testMessagesBeforeAndAfterJoin() async throws {
    // Arrange
    let definition = Land(
        "join-test",
        using: JoinTestState.self
    ) {
        Rules {
            On(TestIncrementEvent.self) { (state: inout JoinTestState, event: TestIncrementEvent, _) in
                state.ticks += 1
            }
        }
        ClientEvents {
            Register(TestIncrementEvent.self)
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<JoinTestState>(definition: definition, initialState: JoinTestState())
    let adapter = TransportAdapter<JoinTestState>(
        keeper: keeper,
        transport: transport,
        landID: "join-test"
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Act: Try to send event before join (should be rejected)
    let incrementEvent = AnyClientEvent(TestIncrementEvent())
    let transportMsg = TransportMessage.event(landID: "join-test", event: .fromClient(incrementEvent))
    let data = try JSONEncoder().encode(transportMsg)
    
    await adapter.onMessage(data, from: sessionID)
    
    // Assert: State should not change
    var state = await keeper.currentState()
    #expect(state.ticks == 0, "State should not change before join")
    
    // Act: Join
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landID: "join-test",
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    // Wait a bit for join to complete
    try await Task.sleep(for: .milliseconds(50))
    
    // Act: Send event after join (should work)
    await adapter.onMessage(data, from: sessionID)
    
    // Assert: State should change
    state = await keeper.currentState()
    #expect(state.ticks == 1, "State should change after join")
}

