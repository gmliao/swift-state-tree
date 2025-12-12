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

@Test("OnLeave handler triggers syncBroadcastOnly, not syncNow")
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
    await mockTransport.reset()
    
    // Alice leaves
    try await keeper.leave(playerID: alice, clientID: ClientID("alice-client"))
    
    // Verify syncBroadcastOnly was called, not syncNow
    let syncNowCount = await mockTransport.syncNowCallCount
    let syncBroadcastOnlyCount = await mockTransport.syncBroadcastOnlyCallCount
    
    #expect(syncNowCount == 0, "syncNow should not be called on leave")
    #expect(syncBroadcastOnlyCount == 1, "syncBroadcastOnly should be called once on leave")
    
    // Verify Alice was removed from state
    let stateAfterLeave = await keeper.currentState()
    #expect(stateAfterLeave.players[alice] == nil)
    #expect(stateAfterLeave.players[bob] == "Guest", "Bob should still be in state")
}

@Test("syncBroadcastOnly is called when player leaves")
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
    await mockTransport.reset()
    
    // Alice leaves
    try await keeper.leave(playerID: alice, clientID: ClientID("alice-client"))
    
    // Verify syncBroadcastOnly was called
    let syncBroadcastOnlyCount = await mockTransport.syncBroadcastOnlyCallCount
    #expect(syncBroadcastOnlyCount == 1, "syncBroadcastOnly should be called once on leave")
    
    // Verify syncNow was NOT called
    let syncNowCount = await mockTransport.syncNowCallCount
    #expect(syncNowCount == 0, "syncNow should not be called on leave")
}
