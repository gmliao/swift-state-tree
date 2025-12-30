// Tests/SwiftStateTreeTransportTests/TransportAdapterJoinTests.swift
//
// Tests for join request handling - using manual registerSession to simulate LandRouter behavior.

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

// MARK: - Helper

// simulateRouterJoin is now provided by TransportTestHelpers.swift


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

    // Assert: Should be connected but not joined
    let connected = await adapter.isConnected(sessionID: sessionID)
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(connected, "Session should be connected")
    #expect(!joined, "Session should not be joined")

    // Assert: Player should NOT be in state (not joined yet)
    let state = await keeper.currentState()
    let playerID = PlayerID(sessionID.rawValue)
    #expect(state.players[playerID] == nil, "Player should not be in state after connect (not joined)")
}

@Test("Manual join (simulating Router) successfully joins")
func testManualJoinSimulatingRouter() async throws {
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
    let playerID = PlayerID("player-1")

    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)

    // Act: Simulate Router Join
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: sessionID, clientID: clientID, playerID: playerID)

    // Assert: Should be joined
    let joined = await adapter.isJoined(sessionID: sessionID)
    let playerIDFromAdapter = await adapter.getPlayerID(for: sessionID)
    #expect(joined, "Session should be joined")
    #expect(playerIDFromAdapter == playerID, "PlayerID should be set correct")

    // Assert: Player should be in state (joined)
    let state = await keeper.currentState()
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

    // Assert: Should be connected but not joined
    let connected = await adapter.isConnected(sessionID: sessionID)
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(connected, "Session should be connected")
    #expect(!joined, "Session should not be joined")

    // Act: Try to send event (should be rejected)
    let incrementEvent = AnyClientEvent(TestIncrementEvent())
    let transportMsg = TransportMessage.event(landID: "join-test", event: .fromClient(event: incrementEvent))
    let data = try JSONEncoder().encode(transportMsg)

    await adapter.onMessage(data, from: sessionID)

    // Assert: State should not change (event was rejected)
    let state = await keeper.currentState()
    #expect(state.ticks == 0, "State should not change if session has not joined")
}

@Test("Cannot send messages before join, can send after join")
func testMessagesBeforeAndAfterJoin() async throws {
    // Arrange
    let definition = Land(
        "join-test",
        using: JoinTestState.self
    ) {
        Rules {
            HandleEvent(TestIncrementEvent.self) { (state: inout JoinTestState, event: TestIncrementEvent, _) in
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
    let playerID = PlayerID("player-1")

    // Act: Connect
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)

    // Act: Try to send event before join (should be rejected)
    let incrementEvent = AnyClientEvent(TestIncrementEvent())
    let transportMsg = TransportMessage.event(landID: "join-test", event: .fromClient(event: incrementEvent))
    let data = try JSONEncoder().encode(transportMsg)

    await adapter.onMessage(data, from: sessionID)

    // Assert: State should not change
    var state = await keeper.currentState()
    #expect(state.ticks == 0, "State should not change before join")

    // Act: Join (Simulate Router)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: sessionID, clientID: clientID, playerID: playerID)

    // Assert: Should be joined
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(joined, "Session should be joined")

    // Act: Send event after join (should work)
    await adapter.onMessage(data, from: sessionID)

    // Assert: State should change
    // Note: We need to wait a tiny bit for async actor processing sometimes, but unit tests usually run fairly sequentially within actor context unless crossing boundaries.
    // TransportAdapter calls keeper.processEvent which is async.
    try await Task.sleep(for: .milliseconds(50))

    state = await keeper.currentState()
    #expect(state.ticks == 1, "State should change after join")
}

// NOTE: Duplicate login tests are removed as duplicate handling is strictly a Router/Keeper responsibility now,
// and TransportAdapter no longer manages kicks directly during join.
