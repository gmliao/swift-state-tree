import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// #572: a player whose session sync lag pauses (`resyncPending`) gets no frame while paused, and
// the plan has no per-player entry for it. The output of each such round lists the player in
// `perPlayerUnverified`, so replay neither compares nor stages it there: the verdict is partial,
// with those scopes counted unverifiable, instead of a false per-player mismatch. A live record
// of each case replays on a tick land with in-turn sync.

/// How the script ends after p2's pause.
enum SyncLagReplayCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The same script without the clock move: p2 is never paused.
    case control
    /// p2 is paused, acts twice, then disconnects.
    case leave
    /// p2 is paused, acts twice, then acks again and is resynced.
    case resume

    var testDescription: String { rawValue }
}

private let syncLagReplayLandID = "sync-lag-replay:local"

/// Each action sets the broadcast `total` and the actor's per-player score; a tick advances
/// `ticks` and asks for a sync, so every tick records an output.
private func makeSyncLagReplayLand() -> LandDefinition<TurnBoundaryState> {
    Land("sync-lag-replay", using: TurnBoundaryState.self) {
        Rules {
            HandleAction(TurnBoundaryAction.self) { (state: inout TurnBoundaryState, action: TurnBoundaryAction, ctx: LandContext) in
                state.total += action.value
                state.scores[ctx.playerID] = action.value
                ctx.requestSyncNow()
                return SyncStreamSetResponse(ok: true)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                ctx.requestSyncNow()
            }
        }
    }
}

/// What one recorded case left behind.
private struct SyncLagCaseRecord {
    let outputs: [ReevaluationRecordedSyncOutput]
    /// p2's sync-stream markers in stream order.
    let p2Markers: [ReevaluationRecordedSyncMarker]
    let pendingMarks: Int
    let resyncs: Int
}

/// Plays the case live with in-turn sync, sync sequences (so sync lag is tracked), a manual
/// sync-lag clock and the sync stream recorded; saves the record to `path`.
private func recordSyncLagCase(_ lagCase: SyncLagReplayCase, path: String) async throws -> SyncLagCaseRecord {
    let keeper = LandKeeper<TurnBoundaryState>(
        definition: makeSyncLagReplayLand(),
        initialState: TurnBoundaryState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: syncLagReplayLandID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let transport = VerifierTransport()
    let adapter = TransportAdapter<TurnBoundaryState>(
        keeper: keeper, transport: transport, landID: syncLagReplayLandID,
        encodingConfig: TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray, syncSequence: true)
    )
    await transport.setDelegate(adapter)
    let clock = SyncLagManualClock()
    await adapter.setSyncLagClockForTesting { clock.now }
    await adapter.setSyncLagTimerIntervalForTesting(.seconds(3600))
    await keeper.awaitInitialization()
    await keeper.setTransport(adapter)
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: syncLagReplayLandID,
        landType: "sync-lag-replay",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "sync-lag-replay",
        rngSeed: DeterministicSeed.fromLandID(syncLagReplayLandID),
        recordsSyncStream: await keeper.recordsSyncStream,
        syncConfig: adapter.syncConfigForRecord
    ))
    #expect(await keeper.recordsSyncStream)

    func join(_ player: Int) async throws {
        let sessionID = SessionID("s\(player)"), clientID = ClientID("c-s\(player)")
        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper, sessionID: sessionID, clientID: clientID, playerID: PlayerID("p\(player)")
        )
        await keeper.waitForRecorderSubmissionsForTesting()
    }
    /// An ack past every frame sent: pops the session's whole FIFO and refreshes its ack clock.
    func ack(_ player: Int) async {
        await adapter.onMessage(SyncAckFrame.encode(seq: .max >> 1, binary: false), from: SessionID("s\(player)"))
    }
    /// One action of the player, then a tick, whose sync phase plans the change; p1 acks after.
    func act(_ player: Int, _ value: Int) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: TurnBoundaryAction.self),
                payload: AnyCodable(TurnBoundaryAction(value: value))
            ),
            playerID: PlayerID("p\(player)"), clientID: ClientID("c-s\(player)"), sessionID: SessionID("s\(player)")
        )
        await keeper.stepTickOnce()
        await keeper.waitForRecorderSubmissionsForTesting()
        let outbound = adapter
        #expect(await withinHangBound { await outbound.waitForOutboundIdleForTesting() })
        await ack(1)
    }

    try await join(1)
    try await join(2)
    await ack(1)
    await ack(2)
    // p2's last ack: the frames of this round stay unacked from here on.
    try await act(2, 6)
    if lagCase != .control {
        // Past `resyncAfter` with p2's acks stale: the next plan marks its session pending.
        clock.advance(3.5)
        await ack(1)
    }
    try await act(2, 7)
    try await act(2, 8)
    switch lagCase {
    case .control:
        break
    case .leave:
        await adapter.onDisconnect(sessionID: SessionID("s2"), clientID: ClientID("c-s2"))
        await keeper.waitForRecorderSubmissionsForTesting()
    case .resume:
        // Fresh acks while pending: the next plan resyncs p2.
        await ack(2)
    }
    try await act(1, 9)

    await keeper.waitForRecorderSubmissionsForTesting()
    try await recorder.save(to: path)
    let stream = ReevaluationSyncStreamEntry.stream(of: await recorder.getAllFrames())
    return SyncLagCaseRecord(
        outputs: stream.compactMap { entry in
            if case .output(let output) = entry { return output } else { return nil }
        },
        p2Markers: stream.compactMap { entry in
            if case .marker(let marker) = entry, marker.playerID == "p2" { return marker } else { return nil }
        },
        pendingMarks: await adapter.syncLagPendingMarks,
        resyncs: await adapter.syncLagResyncs
    )
}

struct SyncLagReplayTests {
    @Test(
        "A player paused by sync lag is listed unverified in the rounds that left it out; the record replays without a false mismatch (#572)",
        arguments: SyncLagReplayCase.allCases
    )
    func pausedPlayerReplays(lagCase: SyncLagReplayCase) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sync-lag-replay-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = try await recordSyncLagCase(lagCase, path: path)

        // The script did what the case says.
        #expect(record.pendingMarks == (lagCase == .control ? 0 : 1))
        #expect(record.resyncs == (lagCase == .resume ? 1 : 0))
        let kinds = record.p2Markers.map(\.kind)
        switch lagCase {
        case .control: #expect(kinds == [.seed], "\(kinds)")
        case .leave: #expect(kinds == [.seed, .clear], "\(kinds)")
        case .resume: #expect(kinds == [.seed, .clear, .seed], "\(kinds)")
        }

        // The paused rounds, and only they, list p2 as unverified: p2 acted twice while paused.
        let unaddressed = record.outputs.filter { $0.perPlayerUnverified?.contains("p2") == true }
        let lists = "\(record.outputs.map { "\($0.streamIndex): \($0.perPlayerUnverified ?? [])" })"
        if lagCase == .control {
            #expect(unaddressed.isEmpty, "\(lists)")
        } else {
            #expect(unaddressed.count >= 2, "\(lists)")
            #expect(unaddressed.allSatisfy { $0.perPlayerUnverified == ["p2"] }, "\(lists)")
        }

        let result = try await ReevaluationEngine.run(
            definition: makeSyncLagReplayLand(),
            initialState: TurnBoundaryState(),
            recordFilePath: path
        )
        #expect(result.recordCompleteness == .complete)
        let sync = result.syncOutput
        // Coverage drops where p2 was left out, and the count says so: each such scope is
        // unverifiable, not silently skipped. p1 stays compared throughout.
        #expect(sync.perPlayer.unverifiable == unaddressed.count, "\(sync.summary)")
        #expect(sync.verdict == (lagCase == .control ? .passed : .partial), "\(sync.summary)")
        #expect(sync.perPlayer.compared > 0, "\(sync.summary)")
        #expect(sync.broadcast.compared > 0, "\(sync.summary)")
        // Resume: the resync's seed is compared like the join's.
        #expect(sync.seed.compared == (lagCase == .resume ? 3 : 2), "\(sync.summary)")
    }
}
