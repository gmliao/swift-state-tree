// Tests/SwiftStateTreeTransportTests/TransportAdapterDisconnectOwnershipTests.swift
//
// A disconnect clears the player's per-player state (sync cache and firstSync mark, initial-sync
// marker, player slot) only when it ends the player's last session (#92).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct DisconnectOwnershipTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
}

private func makeAdapter() async -> (TransportAdapter<DisconnectOwnershipTestState>, LandKeeper<DisconnectOwnershipTestState>) {
    let definition = Land("disconnect-ownership", using: DisconnectOwnershipTestState.self) {
        Rules {
            OnJoin { (state: inout DisconnectOwnershipTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
    let transport = RecordingTransport()
    let keeper = LandKeeper(definition: definition, initialState: DisconnectOwnershipTestState())
    let adapter = TransportAdapter<DisconnectOwnershipTestState>(
        keeper: keeper,
        transport: transport,
        landID: "disconnect-ownership"
    )
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)
    return (adapter, keeper)
}

private func join(
    _ adapter: TransportAdapter<DisconnectOwnershipTestState>,
    session: SessionID,
    client: ClientID,
    player: PlayerID
) async throws -> TransportAdapter<DisconnectOwnershipTestState>.JoinResult {
    await adapter.onConnect(sessionID: session, clientID: client)
    let result = try await adapter.performJoin(
        playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev-\(client.rawValue)", metadata: [:]),
        clientID: client,
        sessionID: session,
        authInfo: nil
    )
    return try #require(result)
}

@Test("An older session's disconnect keeps the player's state while a newer session is in its initial sync")
func olderSessionDisconnectKeepsPlayerState() async throws {
    let (adapter, _) = await makeAdapter()
    let player = PlayerID("p1")
    let s1 = SessionID("s1"), c1 = ClientID("c1")
    let s2 = SessionID("s2"), c2 = ClientID("c2")

    let first = try await join(adapter, session: s1, client: c1, player: player)
    await adapter.syncStateForNewPlayer(playerID: player, sessionID: s1)
    #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player))

    // S2 joins as the same player; its initial sync is held (marked, not yet sent).
    let second = try await join(adapter, session: s2, client: c2, player: player)
    #expect(second.playerSlot == first.playerSlot)
    await adapter.beginInitialSync(for: player)

    // S1's queued disconnect runs while S2 is in its initial sync.
    await adapter.onDisconnect(sessionID: s1, clientID: c1)

    #expect(await adapter.isInitialSyncingForTesting(player))
    #expect(await adapter.getPlayerSlot(for: player) == first.playerSlot)
    #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player))
    #expect(await adapter.membershipSessionIDs(for: player) == [s2])

    // The last session's disconnect clears it all.
    await adapter.onDisconnect(sessionID: s2, clientID: c2)
    #expect(await adapter.isInitialSyncingForTesting(player) == false)
    #expect(await adapter.getPlayerSlot(for: player) == nil)
    #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player) == false)
}

@Test("A player's only session clears the player's state on disconnect")
func onlySessionDisconnectClearsPlayerState() async throws {
    let (adapter, _) = await makeAdapter()
    let player = PlayerID("p1")
    let s1 = SessionID("s1"), c1 = ClientID("c1")

    _ = try await join(adapter, session: s1, client: c1, player: player)
    await adapter.syncStateForNewPlayer(playerID: player, sessionID: s1)
    await adapter.onDisconnect(sessionID: s1, clientID: c1)

    #expect(await adapter.getPlayerSlot(for: player) == nil)
    #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player) == false)
    #expect(await adapter.membershipSessionIDs(for: player).isEmpty)
}
