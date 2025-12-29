// Tests/SwiftStateTreeTransportTests/TransportAdapterStateTransitionTests.swift
//
// Tests for state transitions - all transition paths

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct StateTransitionTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Test("Connected to joined transition")
func testConnectedToJoinedTransition() async throws {
    // Arrange
    let definition = Land(
        "state-transition-test",
        using: StateTransitionTestState.self
    ) {
        Rules {
            OnJoin { (state: inout StateTransitionTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<StateTransitionTestState>(
        definition: definition,
        initialState: StateTransitionTestState()
    )
    let adapter = TransportAdapter<StateTransitionTestState>(
        keeper: keeper,
        transport: transport,
        landID: "state-transition-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: session1, clientID: client1)
    
    // Assert: Should be connected but not joined
    let connected1 = await adapter.isConnected(sessionID: session1)
    let joined1Before = await adapter.isJoined(sessionID: session1)
    #expect(connected1, "Session should be connected")
    #expect(!joined1Before, "Session should not be joined yet")
    
    // Act: Join
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "state-transition-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Should now be joined
    let joined1After = await adapter.isJoined(sessionID: session1)
    let connected1After = await adapter.isConnected(sessionID: session1)
    #expect(joined1After, "Session should be joined")
    #expect(connected1After, "Session should still be connected")
    
    // Assert: State should have player
    let state = await keeper.currentState()
    let playerID = PlayerID(session1.rawValue)
    #expect(state.players[playerID] == "Joined", "Player should be in state")
}

@Test("Joined to disconnected transition")
func testJoinedToDisconnectedTransition() async throws {
    // Arrange
    let definition = Land(
        "state-transition-test",
        using: StateTransitionTestState.self
    ) {
        Rules {
            OnJoin { (state: inout StateTransitionTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
            
            OnLeave { (state: inout StateTransitionTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<StateTransitionTestState>(
        definition: definition,
        initialState: StateTransitionTestState()
    )
    let adapter = TransportAdapter<StateTransitionTestState>(
        keeper: keeper,
        transport: transport,
        landID: "state-transition-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    
    // Act: Connect and join
    await adapter.onConnect(sessionID: session1, clientID: client1)
    let joinRequest = TransportMessage.join(
        requestID: "join-1",
        landType: "state-transition-test",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let joinData = try encodeTransportMessage(joinRequest)
    await adapter.onMessage(joinData, from: session1)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Should be joined
    let joined1Before = await adapter.isJoined(sessionID: session1)
    #expect(joined1Before, "Session should be joined")
    
    // Act: Disconnect
    await adapter.onDisconnect(sessionID: session1, clientID: client1)
    try await Task.sleep(for: .milliseconds(50))
    
    // Assert: Should not be joined or connected
    let joined1After = await adapter.isJoined(sessionID: session1)
    let connected1After = await adapter.isConnected(sessionID: session1)
    #expect(!joined1After, "Session should not be joined after disconnect")
    #expect(!connected1After, "Session should not be connected after disconnect")
    
    // Assert: State should not have player
    let state = await keeper.currentState()
    let playerID = PlayerID(session1.rawValue)
    #expect(state.players[playerID] == nil, "Player should not be in state after disconnect")
}

@Test("Connected to disconnected without join transition")
func testConnectedToDisconnectedWithoutJoin() async throws {
    // Arrange
    let definition = Land(
        "state-transition-test",
        using: StateTransitionTestState.self
    ) {
        Rules {
            OnJoin { (state: inout StateTransitionTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<StateTransitionTestState>(
        definition: definition,
        initialState: StateTransitionTestState()
    )
    let adapter = TransportAdapter<StateTransitionTestState>(
        keeper: keeper,
        transport: transport,
        landID: "state-transition-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    
    // Act: Connect
    await adapter.onConnect(sessionID: session1, clientID: client1)
    
    // Assert: Should be connected but not joined
    let connected1Before = await adapter.isConnected(sessionID: session1)
    let joined1Before = await adapter.isJoined(sessionID: session1)
    #expect(connected1Before, "Session should be connected")
    #expect(!joined1Before, "Session should not be joined")
    
    // Act: Disconnect without joining
    await adapter.onDisconnect(sessionID: session1, clientID: client1)
    
    // Assert: Should not be connected or joined
    let connected1After = await adapter.isConnected(sessionID: session1)
    let joined1After = await adapter.isJoined(sessionID: session1)
    #expect(!connected1After, "Session should not be connected after disconnect")
    #expect(!joined1After, "Session should not be joined after disconnect")
    
    // Assert: State should be empty
    let state = await keeper.currentState()
    #expect(state.players.isEmpty, "State should be empty")
}

@Test("Multiple state transitions maintain consistency")
func testMultipleStateTransitions() async throws {
    // Arrange
    let definition = Land(
        "state-transition-test",
        using: StateTransitionTestState.self
    ) {
        Rules {
            OnJoin { (state: inout StateTransitionTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Joined"
            }
            
            OnLeave { (state: inout StateTransitionTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }
        }
    }
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<StateTransitionTestState>(
        definition: definition,
        initialState: StateTransitionTestState()
    )
    let adapter = TransportAdapter<StateTransitionTestState>(
        keeper: keeper,
        transport: transport,
        landID: "state-transition-test",
        enableLegacyJoin: true
    )
    await keeper.setTransport(adapter)
    await transport.setDelegate(adapter)
    
    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    
    // Perform multiple transitions: connect -> join -> disconnect -> connect -> join
    for iteration in 1...2 {
        // Connect
        await adapter.onConnect(sessionID: session1, clientID: client1)
        let connected = await adapter.isConnected(sessionID: session1)
        #expect(connected, "Session should be connected in iteration \(iteration)")
        
        // Join
        let joinRequest = TransportMessage.join(
            requestID: "join-\(iteration)",
            landType: "state-transition-test",
            landInstanceId: nil,
            playerID: nil,
            deviceID: nil,
            metadata: nil
        )
        let joinData = try encodeTransportMessage(joinRequest)
        await adapter.onMessage(joinData, from: session1)
        try await Task.sleep(for: .milliseconds(50))
        
        let joined = await adapter.isJoined(sessionID: session1)
        #expect(joined, "Session should be joined in iteration \(iteration)")
        
        // Verify state
        let state = await keeper.currentState()
        let playerID = PlayerID(session1.rawValue)
        #expect(state.players[playerID] == "Joined", "Player should be in state in iteration \(iteration)")
        
        // Disconnect (except on last iteration)
        if iteration < 2 {
            await adapter.onDisconnect(sessionID: session1, clientID: client1)
            try await Task.sleep(for: .milliseconds(50))
            
            let notJoined = await adapter.isJoined(sessionID: session1)
            #expect(!notJoined, "Session should not be joined after disconnect in iteration \(iteration)")
        }
    }
    
    // Final state check
    let finalState = await keeper.currentState()
    let playerID = PlayerID(session1.rawValue)
    #expect(finalState.players[playerID] == "Joined", "Player should be in final state")
}

