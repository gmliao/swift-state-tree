// Tests/SwiftStateTreeTransportTests/TransportAdapterBroadcastOnlySyncTests.swift

import Testing
import Foundation
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// Test state with broadcast fields
@StateNodeBuilder
struct BroadcastOnlyTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var gameTime: Int = 0
    
    public init() {}
}

@Test("OnLeave's sync runs in the leave's turn")
func testOnLeaveTriggersSyncBroadcastOnly() async throws {
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    let mockTransport = MockLandKeeperTransport()
    
    let definition = Land(
        "broadcast-only-test",
        using: BroadcastOnlyTestState.self
    ) {
        Rules {
            OnJoin { (state: inout BroadcastOnlyTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Guest"
            }
            
            OnLeave { (state: inout BroadcastOnlyTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }
        }
    }
    
    let keeper = LandKeeper<BroadcastOnlyTestState>(
        definition: definition,
        initialState: BroadcastOnlyTestState(),
        transport: mockTransport
    )
    
    // Join two players
    try await keeper.join(playerID: alice, clientID: ClientID("alice-client"), sessionID: SessionID("alice-session"))
    try await keeper.join(playerID: bob, clientID: ClientID("bob-client"), sessionID: SessionID("bob-session"))
    
    // Verify both players are in state
    let stateAfterJoin = await keeper.currentState()
    #expect(stateAfterJoin.players[alice] == "Guest")
    #expect(stateAfterJoin.players[bob] == "Guest")
    
    // Reset counters
    mockTransport.reset()
    
    // Alice leaves
    try await keeper.leave(playerID: alice, clientID: ClientID("alice-client"))
    
    // The leave's broadcast-only request is a sync request of its turn (#546 L2d): one phase.
    #expect(mockTransport.syncPhaseCount == 1, "one sync phase in the leave's turn")
    
    // Verify Alice was removed from state
    let stateAfterLeave = await keeper.currentState()
    #expect(stateAfterLeave.players[alice] == nil)
    #expect(stateAfterLeave.players[bob] == "Guest", "Bob should still be in state")
}

@Test("A leave's turn runs one sync phase and hands over no event")
func testSyncBroadcastOnlyIsCalledOnLeave() async throws {
    let alice = PlayerID("alice")
    let bob = PlayerID("bob")
    
    let mockTransport = MockLandKeeperTransport()
    
    let definition = Land(
        "broadcast-only-test",
        using: BroadcastOnlyTestState.self
    ) {
        Rules {
            OnJoin { (state: inout BroadcastOnlyTestState, ctx: LandContext) in
                state.players[ctx.playerID] = "Guest"
            }
            
            OnLeave { (state: inout BroadcastOnlyTestState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }
        }
    }
    
    let keeper = LandKeeper<BroadcastOnlyTestState>(
        definition: definition,
        initialState: BroadcastOnlyTestState(),
        transport: mockTransport
    )
    
    // Join two players
    try await keeper.join(playerID: alice, clientID: ClientID("alice-client"), sessionID: SessionID("alice-session"))
    try await keeper.join(playerID: bob, clientID: ClientID("bob-client"), sessionID: SessionID("bob-session"))
    
    // Reset counters
    mockTransport.reset()
    
    // Alice leaves
    try await keeper.leave(playerID: alice, clientID: ClientID("alice-client"))
    
    #expect(mockTransport.syncPhaseCount == 1, "one sync phase in the leave's turn")
    #expect(mockTransport.sendEventCallCount == 0, "the leave emits no event")
}
