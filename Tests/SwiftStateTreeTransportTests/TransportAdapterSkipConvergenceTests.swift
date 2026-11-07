// Tests/SwiftStateTreeTransportTests/TransportAdapterSkipConvergenceTests.swift
//
// Sync cycles skipped by the outbound back-pressure rule (#86) coalesce into the next cycle that
// runs. This checks with the patch-apply oracle (`SnapshotClientView`) that every client still
// converges with the server view, and pins the bytes sent, counted after the writer drained, with
// and without skips (#160: EncodingBenchmark counted bytes before the drain and divided by syncs
// that were skipped).

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct SkipConvergenceState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var scores: [PlayerID: Int] = [:]
    @Sync(.perPlayerSlice()) var hands: [PlayerID: [String]] = [:]
    /// Set only in round 3 (a skipped round with a held writer): lost unless the skip carries it.
    @Sync(.broadcast) var banner: String = ""
    /// Set only in round 4 (also skipped), for the acting player.
    @Sync(.perPlayerSlice()) var notes: [PlayerID: String] = [:]
    init() {}
}

@Payload
struct SkipConvergenceStepAction: ActionPayload {
    typealias Response = SkipConvergenceStepResponse
    let round: Int
}

@Payload
struct SkipConvergenceStepResponse: ResponsePayload {
    let ok: Bool
}

/// Tickless: cycles run only on `syncNow()`, and a skipped one again once the writer drained.
private func skipConvergenceLand(_ id: String) -> LandDefinition<SkipConvergenceState> {
    Land(id, using: SkipConvergenceState.self) {
        Rules {
            OnJoin { (state: inout SkipConvergenceState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
                state.hands[ctx.playerID] = []
            }
            HandleAction(SkipConvergenceStepAction.self) { (state: inout SkipConvergenceState, action: SkipConvergenceStepAction, ctx: LandContext) in
                state.round = action.round
                state.scores[ctx.playerID, default: 0] += action.round
                var hand = state.hands[ctx.playerID] ?? []
                hand.append("card-\(action.round)")
                if action.round % 3 == 0 { hand.removeFirst() }
                state.hands[ctx.playerID] = hand
                if action.round == 3 { state.banner = "set-in-round-3" }
                if action.round == 4 { state.notes[ctx.playerID] = "set-in-round-4" }
                return SkipConvergenceStepResponse(ok: true)
            }
        }
    }
}

private struct SkipConvergenceRun {
    /// Each session's view rebuilt from every state frame it received, by session.
    var views: [SessionID: SnapshotClientView] = [:]
    /// Each player's server view at the end, by session.
    var authoritative: [SessionID: [String: SnapshotValue]] = [:]
    /// Bytes of every frame sent to the players' sessions, counted after the writer drained.
    var totalBytes = 0
    var backlogSkips = 0
}

/// Joins two players and runs six rounds of one action and `syncNow()` each. With `holdWriter`,
/// the transport blocks before round 2's sync, so its element stays in the writer and the syncs
/// of rounds 3 to 5 are skipped; it is released after round 6's action, before its sync.
/// `useSnapshotForSync` picks the extraction path (one snapshot, or separate broadcast and
/// per-player extraction); both extract dirty fields only on the deferred cycle.
private func runSkipConvergence(holdWriter: Bool, useSnapshotForSync: Bool) async throws -> SkipConvergenceRun {
    let id = "skip-convergence-\(holdWriter ? "held" : "free")-\(useSnapshotForSync ? "snapshot" : "separate")"
    let transport = BlockingTransport()
    let keeper = LandKeeper<SkipConvergenceState>(definition: skipConvergenceLand(id), initialState: SkipConvergenceState())
    let adapter = TransportAdapter<SkipConvergenceState>(
        keeper: keeper,
        transport: transport,
        landID: id,
        transportEnvConfig: TransportEnvConfig(
            enableDirtyTracking: true,
            useSnapshotForSync: useSnapshotForSync,
            syncStrategy: .delta,
            enableChangeObjectMetrics: false,
            changeObjectMetricsLogEvery: 10,
            changeObjectMetricsEmaAlpha: 0.2,
            enableAutoDirtyTracking: false,
            autoDirtyOffThreshold: 0.55,
            autoDirtyOnThreshold: 0.30,
            autoDirtyRequiredConsecutiveSamples: 30,
            profilingConfig: nil
        ),
        encodingConfig: .json
    )
    await transport.setDelegate(adapter)

    var players: [(session: SessionID, client: ClientID, player: PlayerID)] = []
    for n in 1...2 {
        let entry = (SessionID("\(id)-s\(n)"), ClientID("\(id)-c\(n)"), PlayerID("\(id)-p\(n)"))
        await adapter.onConnect(sessionID: entry.0, clientID: entry.1)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: entry.0, clientID: entry.1, playerID: entry.2)
        players.append(entry)
    }
    try await waitUntilTransportIdle(transport)

    for round in 1...6 {
        let actor = players[round % 2]
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: SkipConvergenceStepAction.self),
            payload: AnyCodable(SkipConvergenceStepAction(round: round))
        )
        _ = try await keeper.handleActionEnvelope(envelope, playerID: actor.player, clientID: actor.client, sessionID: actor.session)
        if holdWriter, round == 2 { transport.block() }
        if holdWriter, round == 6 {
            // Round 6's change is already dirty when the deferred cycle runs, so that cycle
            // extracts dirty fields only: round 3's banner reaches the clients only if the
            // skipped cycles kept it. Wait for the deferred cycle, so round 6's own sync never
            // meets it in flight.
            transport.release()
            let first = players[0].session
            try await orderedWaitUntil("the deferred cycle to deliver round 3's banner") {
                transport.frames(for: first).contains { $0.range(of: Data("set-in-round-3".utf8)) != nil }
            }
            #expect(await adapter.waitForOutboundDrain())
        }
        await adapter.syncNow()
        // Outside the held window every cycle's frames leave the writer before the next cycle,
        // so the only skips are the held ones, whatever the scheduling.
        if !holdWriter || !(2...5).contains(round) {
            #expect(await adapter.waitForOutboundDrain())
        }
    }
    // Everything sent, and nothing left to send: the deferred cycle ran and a last cycle is empty.
    #expect(await adapter.waitForOutboundDrain())
    await adapter.syncNow()
    #expect(await adapter.waitForOutboundDrain())

    var run = SkipConvergenceRun()
    run.backlogSkips = await adapter.syncSkipCounts().outboundBacklog
    let state = await keeper.currentState()
    for entry in players {
        let frames = transport.frames(for: entry.session)
        run.totalBytes += frames.reduce(0) { $0 + $1.count }
        var view = SnapshotClientView()
        for update in decodeStateUpdates(frames) {
            switch update {
            case .firstSync(let patches), .diff(let patches): try view.apply(patches)
            case .noChange: break
            }
        }
        run.views[entry.session] = view
        run.authoritative[entry.session] = try SyncEngine(for: SkipConvergenceState.self).snapshot(for: entry.player, from: state).values
    }
    return run
}

@Suite("TransportAdapter: skipped sync cycles converge", .timeLimit(.minutes(1)))
struct TransportAdapterSkipConvergenceTests {
    @Test(
        "cycles skipped while the writer holds one coalesce, and every client converges with the server view",
        arguments: [true, false]
    )
    func skippedCyclesConverge(useSnapshotForSync: Bool) async throws {
        let free = try await runSkipConvergence(holdWriter: false, useSnapshotForSync: useSnapshotForSync)
        let held = try await runSkipConvergence(holdWriter: true, useSnapshotForSync: useSnapshotForSync)

        #expect(free.backlogSkips == 0, "without a held writer no cycle is skipped")
        #expect(held.backlogSkips >= 3, "rounds 3 to 5 are skipped while round 2's element waits: \(held.backlogSkips)")
        for run in [free, held] {
            #expect(run.views.count == 2)
            #expect(run.views.values.contains { $0.fields["banner"] == .string("set-in-round-3") }, "round 3's change reached the clients")
            for (session, view) in run.views {
                #expect(view.fields == run.authoritative[session], "\(session.rawValue): client view != server view")
            }
        }
        // The held run sends the skipped rounds coalesced into one cycle.
        #expect(held.totalBytes < free.totalBytes, "coalesced cycles send fewer bytes: \(held.totalBytes) vs \(free.totalBytes)")
    }
}
