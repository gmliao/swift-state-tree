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

    // S2 joins as the same player and supersedes S1 (newest wins): S1 leaves the membership,
    // and the player's sync state restarts with S2. Its initial sync is held (marked, not sent).
    let second = try await join(adapter, session: s2, client: c2, player: player)
    #expect(second.playerSlot == first.playerSlot)
    #expect(await adapter.membershipSessionIDs(for: player) == [s2])
    #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player) == false)
    await adapter.beginInitialSync(for: player)

    // S1's queued disconnect runs while S2 is in its initial sync: it clears nothing of S2's.
    await adapter.onDisconnect(sessionID: s1, clientID: c1)

    #expect(await adapter.isInitialSyncingForTesting(player))
    #expect(await adapter.getPlayerSlot(for: player) == first.playerSlot)
    #expect(await adapter.membershipSessionIDs(for: player) == [s2])

    // The last session's disconnect clears it all.
    await adapter.onDisconnect(sessionID: s2, clientID: c2)
    #expect(await adapter.isInitialSyncingForTesting(player) == false)
    #expect(await adapter.getPlayerSlot(for: player) == nil)
    #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player) == false)
}

@Test("A session of the player registered while the disconnect awaits keeper.leave keeps the player's state")
func sessionRegisteredDuringLeaveKeepsPlayerState() async throws {
    let (adapter, keeper) = await makeAdapter()
    let player = PlayerID("p1")
    let s1 = SessionID("s1"), c1 = ClientID("c1")
    let s2 = SessionID("s2"), c2 = ClientID("c2")

    let first = try await join(adapter, session: s1, client: c1, player: player)
    await adapter.syncStateForNewPlayer(playerID: player, sessionID: s1)

    // Hold S1's disconnect at `keeper.leave`; S1 is already unregistered, P has no session.
    let leaveGate = TestGate()
    await keeper.setLeaveHook { await leaveGate.arrive() }
    let disconnect = Task { await adapter.onDisconnect(sessionID: s1, clientID: c1) }
    #expect(await leaveGate.waitForArrivals(1))
    #expect(await adapter.membershipSessionIDs(for: player).isEmpty)

    // During the hold, S2 is registered for P (a re-join admitted meanwhile) and starts its
    // initial sync.
    await adapter.onConnect(sessionID: s2, clientID: c2)
    await adapter.registerSession(sessionID: s2, clientID: c2, playerID: player, authInfo: nil)
    await adapter.beginInitialSync(for: player)

    leaveGate.open()
    await disconnect.value

    // The ownership check runs after the await: S2 now owns P, so nothing is cleared.
    #expect(await adapter.isInitialSyncingForTesting(player))
    #expect(await adapter.getPlayerSlot(for: player) == first.playerSlot)
    #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player))
    #expect(await adapter.membershipSessionIDs(for: player) == [s2])
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
