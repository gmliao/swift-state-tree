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
    _ = try await keeper.join(
        session: playerSession,
        clientID: clientID,
        sessionID: sessionID,
        services: LandServices()
    )
    
    // 2. Register with Adapter
    await adapter.registerSession(
        sessionID: sessionID,
        clientID: clientID,
        playerID: playerID,
        authInfo: authInfo
    )
}
