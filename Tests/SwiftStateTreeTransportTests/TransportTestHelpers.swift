// Tests/SwiftStateTreeTransportTests/TransportTestHelpers.swift

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// Simulate the join process usually handled by LandRouter.
/// This allows testing TransportAdapter in isolation without needing the full LandRouter stack.
///
/// Steps:
/// 1. Calls `keeper.join` to execute OnJoin rules and update Land state.
/// 2. Calls `adapter.registerSession` to bind the session in the adapter.
/// 3. Sends initial state snapshot (simulates what happens AFTER JoinResponse is sent).
///
/// Note: In production, the order is:
/// 1. performJoin() - keeper.join + registerSession
/// 2. sendJoinResponse() - client receives join confirmation
/// 3. syncStateForNewPlayer() - client receives initial state
///
/// In tests, we simulate this without the actual JoinResponse message.
func simulateRouterJoin<State: StateNodeProtocol>(
    adapter: TransportAdapter<State>,
    keeper: LandKeeper<State>,
    sessionID: SessionID,
    clientID: ClientID,
    playerID: PlayerID,
    authInfo: AuthenticatedInfo? = nil
) async throws {
    let playerSession = PlayerSession(
        playerID: playerID.rawValue,
        deviceID: "dev-mock-\(playerID.rawValue)",
        metadata: authInfo?.metadata ?? [:]
    )
    
    // 1. Join Keeper (executes OnJoin rules)
    // We explicitly call keeper.join here because TransportAdapter expects the keeper to be aware of the player
    // AND TransportAdapter.registerSession expects to be called AFTER a successful join.
    let decision = try await keeper.join(
        session: playerSession,
        clientID: clientID,
        sessionID: sessionID,
        services: LandServices()
    )
    
    guard case .allow(let finalPlayerID) = decision else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Join denied"])
    }
    
    // 2. Register with Adapter
    await adapter.registerSession(
        sessionID: sessionID,
        clientID: clientID,
        playerID: finalPlayerID,
        authInfo: authInfo
    )
    
    // 3. Allocate playerSlot (simulates what performJoin does)
    let playerSlot = await adapter.allocatePlayerSlot(accountKey: finalPlayerID.rawValue, for: finalPlayerID)
    
    // 4. Send initial state snapshot
    // In production this happens AFTER JoinResponse is sent to ensure correct message order.
    // In tests we call it directly since we don't have the actual WebSocket message flow.
    await adapter.syncStateForNewPlayer(playerID: finalPlayerID, sessionID: sessionID)
}
