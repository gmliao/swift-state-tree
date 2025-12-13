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
    
    // Assert: Should be joined
    let joined = await adapter.isJoined(sessionID: sessionID)
    let playerIDFromAdapter = await adapter.getPlayerID(for: sessionID)
    #expect(joined, "Session should be joined")
    #expect(playerIDFromAdapter != nil, "PlayerID should be set")
    
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
    
    // Assert: Should not be joined
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(!joined, "Session should not be joined after rejected join")
    
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
    
    // Assert: Should be joined
    let joined = await adapter.isJoined(sessionID: sessionID)
    #expect(joined, "Session should be joined")
    
    // Act: Send event after join (should work)
    await adapter.onMessage(data, from: sessionID)
    
    // Assert: State should change
    state = await keeper.currentState()
    #expect(state.ticks == 1, "State should change after join")
}

@Test("Duplicate playerID login kicks old connection and calls OnLeave")
func testDuplicatePlayerIDKicksOldConnection() async throws {
    // Arrange
    let onLeaveCallCount = ManagedCounter()
    let onJoinCallCount = ManagedCounter()
    
    let definition = Land(
        "join-test",
        using: JoinTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JoinTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
                Task {
                    await onJoinCallCount.increment()
                }
            }
            
            OnLeave { (state: inout JoinTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
                Task {
                    await onLeaveCallCount.increment()
                }
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
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let playerID = "player-1"
    let session1 = SessionID("sess-1")
    let session2 = SessionID("sess-2")
    let client1 = ClientID("cli-1")
    let client2 = ClientID("cli-2")
    
    // Act: Connect and join first session
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest1 = TransportMessage.join(
        requestID: "join-1",
        landID: "join-test",
        playerID: playerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData1 = try JSONEncoder().encode(joinRequest1)
    await adapter.onMessage(joinData1, from: session1)
    
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: First session should be joined
    let joined1 = await adapter.isJoined(sessionID: session1)
    #expect(joined1, "Session 1 should be joined")
    #expect(await onJoinCallCount.value == 1, "OnJoin should be called once")
    #expect(await onLeaveCallCount.value == 0, "OnLeave should not be called yet")
    
    // Act: Connect and join second session with same playerID
    await adapter.onConnect(sessionID: session2, clientID: client2)
    let joinRequest2 = TransportMessage.join(
        requestID: "join-2",
        landID: "join-test",
        playerID: playerID,
        deviceID: nil,
        metadata: nil
    )
    let joinData2 = try JSONEncoder().encode(joinRequest2)
    await adapter.onMessage(joinData2, from: session2)
    
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: First session should be kicked
    let joined1After = await adapter.isJoined(sessionID: session1)
    #expect(!joined1After, "Session 1 should be kicked after duplicate login")
    
    // Assert: Second session should be joined
    let joined2 = await adapter.isJoined(sessionID: session2)
    #expect(joined2, "Session 2 should be joined")
    
    // Assert: OnLeave should be called for old session
    #expect(await onLeaveCallCount.value == 1, "OnLeave should be called once when old session is kicked")
    
    // Assert: OnJoin should be called twice (first join + second join)
    #expect(await onJoinCallCount.value == 2, "OnJoin should be called twice (first join + second join)")
    
    // Assert: State should have player (only one, as old was removed and new was added)
    let state = await keeper.currentState()
    let pid = PlayerID(playerID)
    #expect(state.players[pid] == "Joined", "Player should be in state")
    #expect(state.players.count == 1, "State should have exactly 1 player")
}

@Test("Rapid duplicate logins maintain state consistency")
func testRapidDuplicateLogins() async throws {
    // Arrange
    let definition = Land(
        "join-test",
        using: JoinTestState.self
    ) {
        Rules {
            OnJoin { (state: inout JoinTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
            
            OnLeave { (state: inout JoinTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
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
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let playerID = "player-1"
    
    // Act: Rapidly connect and join multiple sessions with same playerID
    for i in 1...3 {
        let sessionID = SessionID("sess-\(i)")
        let clientID = ClientID("cli-\(i)")
        
        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        let joinRequest = TransportMessage.join(
            requestID: "join-\(i)",
            landID: "join-test",
            playerID: playerID,
            deviceID: nil,
            metadata: nil
        )
        let joinData = try JSONEncoder().encode(joinRequest)
        await adapter.onMessage(joinData, from: sessionID)
        try await Task.sleep(for: .milliseconds(20))
    }
    
    try await Task.sleep(for: .milliseconds(100))
    
    // Assert: Only last session should be joined
    let session1 = SessionID("sess-1")
    let session2 = SessionID("sess-2")
    let session3 = SessionID("sess-3")
    
    let joined1 = await adapter.isJoined(sessionID: session1)
    let joined2 = await adapter.isJoined(sessionID: session2)
    let joined3 = await adapter.isJoined(sessionID: session3)
    
    #expect(!joined1, "Session 1 should be kicked")
    #expect(!joined2, "Session 2 should be kicked")
    #expect(joined3, "Session 3 should be joined")
    
    // Assert: State should have exactly one player
    let state = await keeper.currentState()
    let pid = PlayerID(playerID)
    #expect(state.players[pid] == "Joined", "Player should be in state")
    #expect(state.players.count == 1, "State should have exactly 1 player")
    
    // Assert: getSessions should return only last session
    let sessions = await adapter.getSessions(for: pid)
    #expect(sessions.count == 1, "PlayerID should map to 1 session")
    #expect(sessions.contains(session3), "Sessions should include session3")
}

