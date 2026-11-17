// Examples/GameDemo/Sources/EncodingBenchmark/Rejoin.swift
//
// `--rejoin-every <k>`: every k-th measured iteration, player 0 of each Hero Defense room leaves
// and joins again, so the iteration's sync carries a full view of a populated room (the joiner's
// firstSync). Without it, every join happens before any monster spawns, and the measured
// iterations plan no full view with entries in the room's maps. Unset, nothing here runs.
//
// The leave and the admission run before the iteration's timed span (and its perf window); the
// joiner's firstSync runs inside it, with the room's `syncNow()`. It is the standalone firstSync
// (`syncStateForNewPlayer`, a late-join snapshot), not an in-turn joiner's: the admission passes no
// JoinResponse builder, so the join doesn't complete in a turn.

import Foundation
@_spi(Testing) import SwiftStateTree
import SwiftStateTreeTransport

enum RejoinRun {
    /// Rejoin every k-th measured iteration (0: never).
    nonisolated(unsafe) static var every = 0

    /// Why `--rejoin-every` can't run as given, or nil. Only the serial hero-defense multi-room
    /// runner, with the rooms joined directly, rejoins.
    static func refusal(_ config: BenchmarkConfig) -> String? {
        guard config.rejoinEvery > 0 else { return nil }
        let unsupported = [
            (config.gameType != .heroDefense, "--game-type other than hero-defense"),
            (!config.parallelGiven || config.parallel || config.compareParallel, "parallel runs (pass --parallel false)"),
            (config.runAll, "--all"),
            (config.scalabilityTest, "--scalability"),
            (config.hashCost, "--hash-cost"),
            (config.compareWorkerPool, "--compare-worker-pool"),
            (config.useWorkerPool, "--use-worker-pool"),
            (config.joinThroughRouter, "--join-through-router on"),
            (config.inputsFromWire, "--inputs-from-wire"),
            // The move injection addresses player 0 by its first session, which the rejoin replaces.
            (config.activePlayers, "--active-players"),
            (config.captureViews != nil, "--capture-views (its players are the rooms' first sessions)"),
            (config.entityDeltaBaseline, "--baseline entity-delta"),
        ].filter(\.0).map(\.1)
        guard !unsupported.isEmpty else { return nil }
        return "--rejoin-every doesn't support \(unsupported.joined(separator: ", "))"
    }
}

/// One room's player 0: its current session, and a rejoin whose firstSync is still to run.
struct RejoiningPlayer {
    let roomIndex: Int
    private(set) var sessionID: SessionID
    private(set) var clientID: ClientID
    private(set) var rejoins = 0
    /// FirstSyncs sent to a rejoined session: the run's `done`.
    private(set) var firstSyncsSent = 0
    /// Admitted, not yet sent its firstSync.
    private(set) var pendingFirstSync: (PlayerID, SessionID)?

    init(roomIndex: Int) {
        self.roomIndex = roomIndex
        sessionID = SessionID(fixed: "room\(roomIndex)-session-0")
        clientID = ClientID("room\(roomIndex)-client-0")
    }

    /// Outside the timed span: the leave, then the admission of a new session for the same player.
    /// Exits if the join is refused or the room's player count changes.
    mutating func leaveAndAdmit(room: HeroDefenseRoomContext, playersPerRoom: Int) async {
        await room.adapter.onDisconnect(sessionID: sessionID, clientID: clientID)
        // The leave is applied here, not in the next (timed) tick.
        let afterLeave = await room.keeper.playerCount()
        guard afterLeave == playersPerRoom - 1 else {
            fail("room \(roomIndex): \(afterLeave)/\(playersPerRoom) players after the leave before rejoin \(rejoins + 1)")
        }
        rejoins += 1
        sessionID = SessionID(fixed: "room\(roomIndex)-session-0-r\(rejoins)")
        clientID = ClientID("room\(roomIndex)-client-0-r\(rejoins)")
        await room.adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil as AuthenticatedInfo?)
        let playerSession = PlayerSession(playerID: "room\(roomIndex)-player-0", deviceID: "device-\(roomIndex)-0", metadata: [:])
        guard let result = try? await room.adapter.performJoin(
            playerSession: playerSession,
            clientID: clientID,
            sessionID: sessionID,
            authInfo: nil as AuthenticatedInfo?
        ), !result.completedInTurn else {
            fail("room \(roomIndex): rejoin \(rejoins) was refused or completed in a turn")
        }
        let players = await room.keeper.playerCount()
        guard players == playersPerRoom else {
            fail("room \(roomIndex): \(players)/\(playersPerRoom) players after rejoin \(rejoins)")
        }
        pendingFirstSync = (result.playerID, sessionID)
    }

    /// Inside the timed span, before the room's `syncNow()`: the joiner's firstSync, a full view.
    mutating func sendFirstSync(room: HeroDefenseRoomContext) async {
        guard let (playerID, sessionID) = pendingFirstSync else { return }
        pendingFirstSync = nil
        await room.adapter.syncStateForNewPlayer(playerID: playerID, sessionID: sessionID)
        firstSyncsSent += 1
    }

    /// Every admission was followed by its firstSync.
    var allFirstSyncsSent: Bool { pendingFirstSync == nil && firstSyncsSent == rejoins }

    private func fail(_ message: String) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data("error: --rejoin-every: \(message)\n".utf8))
        exit(1)
    }
}
