import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// #553: an in-turn sync phase returns its sync-stream entries as drafts, and the keeper numbers
// and submits them; a disconnect's clear stays outside the phase, after the leave returns and
// only for the player's last session. A live record of each leave case replays with every
// sync output, seed and event verified, on a tick land and on a tickless land.

/// How the second player's session ends in the script.
enum LeaveReplayCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The player's only session disconnects: a clear outside any turn.
    case lastSession
    /// A newer session of the player supersedes the first (its clear is in the join's
    /// admission); the first then disconnects while the newer one remains: no clear. Since
    /// #531 the superseded session has left the membership, so its disconnect runs no leave.
    case otherSessionRemains
    /// The player's only session disconnects and the player joins again right after.
    case rejoinAfterLeave

    var testDescription: String { rawValue }
}

private let leaveReplayLandID = "leave-replay:local"

/// Each action changes the broadcast and per-player state, emits two events and asks for a
/// sync. A leave does too: it changes `total` and the staying players' scores, emits an event
/// and asks for a sync, so its turn records outputs a clear placed too early would precede.
/// With `tick`, a tick advances `ticks`, emits an event and asks for a sync.
private func makeLeaveReplayLand(tick: Bool) -> LandDefinition<TurnBoundaryState> {
    let rule = HandleAction(TurnBoundaryAction.self) { (state: inout TurnBoundaryState, action: TurnBoundaryAction, ctx: LandContext) in
        state.total += action.value
        state.scores[ctx.playerID] = action.value
        ctx.requestSyncNow()
        ctx.emitEvent(SyncStreamTestEvent(message: "to-\(ctx.playerID.rawValue)"), to: .player(ctx.playerID))
        ctx.emitEvent(SyncStreamTestEvent(message: "all-\(action.value)"), to: .all)
        return SyncStreamSetResponse(ok: true)
    }
    let leave = OnLeave { (state: inout TurnBoundaryState, ctx: LandContext) in
        state.total += 100
        state.scores[ctx.playerID] = nil
        for playerID in state.scores.keys { state.scores[playerID, default: 0] += 1000 }
        ctx.emitEvent(SyncStreamTestEvent(message: "left-\(ctx.playerID.rawValue)"), to: .all)
        ctx.requestSyncNow()
    }
    guard tick else {
        return Land("leave-replay", using: TurnBoundaryState.self) {
            ServerEvents { Register(SyncStreamTestEvent.self) }
            Rules { rule; leave }
        }
    }
    return Land("leave-replay", using: TurnBoundaryState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Rules { rule; leave }
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout TurnBoundaryState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(SyncStreamTestEvent(message: "tick-\(state.ticks)"), to: .all)
                ctx.requestSyncNow()
            }
        }
    }
}

/// What one recorded leave case left in the sync stream.
private struct LeaveCaseRecord {
    /// p2's sync-stream markers in stream order.
    let markers: [ReevaluationRecordedSyncMarker]
    /// Every output, in stream order.
    let outputs: [ReevaluationRecordedSyncOutput]
    /// The last stream index recorded before p2's first disconnect, nil when there is none.
    let lastIndexBeforeLeave: UInt64?
}

/// Plays the case's script live with in-turn sync and the sync stream recorded, saves the
/// record to `path`, and returns what its sync stream holds.
private func recordLeaveCase(_ leaveCase: LeaveReplayCase, tick: Bool, path: String) async throws -> LeaveCaseRecord {
    let keeper = LandKeeper<TurnBoundaryState>(
        definition: makeLeaveReplayLand(tick: tick),
        initialState: TurnBoundaryState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: leaveReplayLandID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let transport = VerifierTransport()
    let adapter = TransportAdapter<TurnBoundaryState>(
        keeper: keeper, transport: transport, landID: leaveReplayLandID
    )
    await transport.setDelegate(adapter)
    await keeper.awaitInitialization()
    await keeper.setTransport(adapter)
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: leaveReplayLandID,
        landType: "leave-replay",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "leave-replay",
        rngSeed: DeterministicSeed.fromLandID(leaveReplayLandID),
        recordsSyncStream: await keeper.recordsSyncStream,
        syncConfig: adapter.syncConfigForRecord
    ))
    #expect(await keeper.recordsSyncStream)

    // A tickless join goes through the adapter's join path and flips in a sync-only turn; a
    // tick land's join would wait for a tick, so it joins the direct way.
    func join(_ player: Int, session: String) async throws {
        let sessionID = SessionID(session), clientID = ClientID("c-\(session)")
        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        if !tick {
            let result = try await adapter.performJoin(
                playerSession: PlayerSession(playerID: "p\(player)", deviceID: "dev", metadata: [:]),
                clientID: clientID, sessionID: sessionID, authInfo: nil,
                joinResponse: { playerID, slot in
                    try? JSONEncoder().encode(TransportMessage.joinResponse(
                        requestID: "r-\(session)", success: true,
                        playerID: playerID.rawValue, playerSlot: slot, encoding: "json"
                    ))
                }
            )
            #expect(result?.completedInTurn == true)
        } else {
            try await simulateRouterJoin(
                adapter: adapter, keeper: keeper, sessionID: sessionID, clientID: clientID, playerID: PlayerID("p\(player)")
            )
        }
        await keeper.waitForRecorderSubmissionsForTesting()
    }
    func act(_ player: Int, session: String, _ value: Int) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: TurnBoundaryAction.self),
                payload: AnyCodable(TurnBoundaryAction(value: value))
            ),
            playerID: PlayerID("p\(player)"), clientID: ClientID("c-\(session)"), sessionID: SessionID(session)
        )
        await keeper.waitForRecorderSubmissionsForTesting()
    }
    func step() async {
        guard tick else { return }
        await keeper.stepTickOnce()
        await keeper.waitForRecorderSubmissionsForTesting()
    }
    var lastIndexBeforeLeave: UInt64?
    func disconnect(_ session: String) async {
        if lastIndexBeforeLeave == nil {
            lastIndexBeforeLeave = ReevaluationSyncStreamEntry.stream(of: await recorder.getAllFrames()).map(\.streamIndex).max()
        }
        await adapter.onDisconnect(sessionID: SessionID(session), clientID: ClientID("c-\(session)"))
        await keeper.waitForRecorderSubmissionsForTesting()
    }

    try await join(1, session: "s1")
    try await join(2, session: "s2")
    try await act(1, session: "s1", 5)
    await step()
    try await act(2, session: "s2", 6)
    await step()
    switch leaveCase {
    case .lastSession:
        await disconnect("s2")
        try await act(1, session: "s1", 7)
        await step()
    case .otherSessionRemains:
        try await join(2, session: "s2b")
        await disconnect("s2")
        try await act(2, session: "s2b", 7)
        await step()
    case .rejoinAfterLeave:
        await disconnect("s2")
        try await join(2, session: "s2")
        try await act(2, session: "s2", 7)
        await step()
    }
    try await act(1, session: "s1", 8)
    await step()

    await keeper.waitForRecorderSubmissionsForTesting()
    try await recorder.save(to: path)
    let stream = ReevaluationSyncStreamEntry.stream(of: await recorder.getAllFrames())
    let markers = stream.compactMap { entry -> ReevaluationRecordedSyncMarker? in
        if case .marker(let marker) = entry, marker.playerID == "p2" { return marker } else { return nil }
    }
    let outputs = stream.compactMap { entry -> ReevaluationRecordedSyncOutput? in
        if case .output(let output) = entry { return output } else { return nil }
    }
    return LeaveCaseRecord(markers: markers, outputs: outputs, lastIndexBeforeLeave: lastIndexBeforeLeave)
}

struct SyncStreamLeaveReplayTests {
    @Test(
        "A leave's clear stays after the leave, for the last session only; the live record replays with every check passed (#553)",
        arguments: [true, false], LeaveReplayCase.allCases
    )
    func leaveRecordReplays(tick: Bool, leaveCase: LeaveReplayCase) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("leave-replay-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = try await recordLeaveCase(leaveCase, tick: tick, path: path)
        let markers = record.markers

        // p2's markers in stream order: the clear sits between the views it ends and starts.
        let kinds = markers.map { "\($0.kind.rawValue)\($0.rejoin == true ? "-rejoin" : "")" }
        switch leaveCase {
        case .lastSession:
            #expect(kinds == ["seed", "clear"])
        case .otherSessionRemains:
            // The superseding join's clear, then its seed; the older session's disconnect
            // records nothing.
            #expect(kinds == ["seed", "clear", "seed-rejoin"])
        case .rejoinAfterLeave:
            #expect(kinds == ["seed", "clear", "seed-rejoin"])
        }
        let indices = markers.map(\.streamIndex)
        #expect(indices == indices.sorted())
        // A leave that runs OnLeave (the player's last session ends). Tickless, its turn's sync
        // phase records an output before the clear (#553 placement); p2's session is gone, so
        // the output doesn't address p2 and lists it as unverified, and replay neither compares
        // nor stages p2 there. On a tick land the leave's sync runs in the next tick, after the
        // clear, where its changes are verified. The superseded session's disconnect runs no leave.
        if leaveCase != .otherSessionRemains {
            let before = try #require(record.lastIndexBeforeLeave)
            let clear = try #require(markers.first { $0.kind == .clear })
            let leaveOutputs = record.outputs.filter { $0.streamIndex > before && $0.streamIndex < clear.streamIndex }
            let summary = "outputs \(record.outputs.map(\.streamIndex)), clear \(clear.streamIndex), before \(before)"
            if tick {
                #expect(leaveOutputs.isEmpty, "\(summary)")
            } else {
                #expect(leaveOutputs.count == 1, "\(summary)")
                #expect(leaveOutputs.allSatisfy { $0.perPlayerUnverified == ["p2"] }, "\(leaveOutputs.map(\.perPlayerUnverified))")
            }
            // p2 is unverified only there: every other output addresses the players it lists.
            let others = record.outputs.filter { !leaveOutputs.map(\.streamIndex).contains($0.streamIndex) }
            #expect(others.allSatisfy { $0.perPlayerUnverified == nil }, "\(others.map(\.perPlayerUnverified))")
        }

        let result = try await ReevaluationEngine.run(
            definition: makeLeaveReplayLand(tick: tick),
            initialState: TurnBoundaryState(),
            recordFilePath: path
        )
        #expect(result.recordCompleteness == .complete)
        #expect(result.serverEventVerification == .passed, "\(result.serverEventMismatches.map(\.tickId))")
        let sync = result.syncOutput
        if !tick {
            #expect(result.recordedPassMismatches.isEmpty, "\(result.recordedPassMismatches)")
        }
        // From record 3.4 a tickless land's entries are located by pass ordinal (#563), so both
        // land kinds verify. A tickless leave's output doesn't address the departed p2: that one
        // per-player scope is unverifiable, so the verdict is partial, never a mismatch.
        if !tick && leaveCase != .otherSessionRemains {
            #expect(sync.verdict == .partial, "\(sync.summary)")
            #expect(sync.perPlayer.unverifiable == 1, "\(sync.summary)")
        } else {
            #expect(sync.verdict == .passed, "\(sync.summary)")
            #expect(sync.perPlayer.unverifiable == 0, "\(sync.summary)")
        }
        #expect(sync.broadcast.compared > 0)
        #expect(sync.perPlayer.compared > 0)
        #expect(sync.seed.compared == (leaveCase == .lastSession ? 2 : 3))
    }
}
