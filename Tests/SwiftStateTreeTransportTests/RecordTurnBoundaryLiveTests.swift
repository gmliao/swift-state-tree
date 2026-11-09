import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// #327: a live keeper's 3.0 record is the same bytes whether or not the recorder's flush timer
// fires mid-turn. The timer is forced to fire after every recorder call (no timing), on tick
// and tickless lands, with in-turn sync on and off (the legacy paths).
//
// Fields that are not framing are pinned: player, client and session IDs, the land ID (and so
// the RNG seed), and the header's `createdAt`, the only wall-time field of a record (the
// footer has none).

@StateNodeBuilder
struct TurnBoundaryState: StateNodeProtocol {
    @Sync(.broadcast) var total: Int = 0
    @Sync(.broadcast) var ticks: Int = 0
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    init() {}
}

@Payload
struct TurnBoundaryAction: ActionPayload {
    typealias Response = SyncStreamSetResponse
    let value: Int
}

/// OnInitialize writes the state and emits an event; each action changes the broadcast and
/// per-player state and emits two events. With `tick`, a tick advances `ticks`, emits one event
/// and requests a sync. `replayTick` gives a tickless record a tick handler that changes
/// nothing, to replay on.
private func makeTurnBoundaryLand(tick: Bool, replayTick: Bool = false) -> LandDefinition<TurnBoundaryState> {
    let advances = tick
    guard tick || replayTick else {
        return Land("record-turn-boundary", using: TurnBoundaryState.self) {
            ServerEvents { Register(SyncStreamTestEvent.self) }
            Rules { turnBoundaryRule() }
            Lifetime { turnBoundaryInitialize() }
        }
    }
    return Land("record-turn-boundary", using: TurnBoundaryState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Rules { turnBoundaryRule() }
        Lifetime {
            turnBoundaryInitialize()
            Tick(every: .seconds(3600)) { (state: inout TurnBoundaryState, ctx: LandContext) in
                guard advances else { return }
                state.ticks += 1
                ctx.emitEvent(SyncStreamTestEvent(message: "tick-\(state.ticks)"), to: .all)
                ctx.requestSyncNow()
            }
        }
    }
}

private func turnBoundaryRule() -> AnyActionHandler<TurnBoundaryState> {
    HandleAction(TurnBoundaryAction.self) { (state: inout TurnBoundaryState, action: TurnBoundaryAction, ctx: LandContext) in
        state.total += action.value
        state.scores[ctx.playerID] = action.value
        // From 5 on, the action asks for a sync: in-turn, its turn's sync phase records sync
        // outputs before the turn record.
        if action.value >= 5 { ctx.requestSyncNow() }
        ctx.emitEvent(SyncStreamTestEvent(message: "to-\(ctx.playerID.rawValue)"), to: .player(ctx.playerID))
        ctx.emitEvent(SyncStreamTestEvent(message: "all-\(action.value)"), to: .all)
        return SyncStreamSetResponse(ok: true)
    }
}

private func turnBoundaryInitialize() -> LifetimeDirective<TurnBoundaryState> {
    OnInitialize { (state: inout TurnBoundaryState, ctx: LandContext) in
        state.total = 1
        ctx.emitEvent(SyncStreamTestEvent(message: "init"), to: .all)
    }
}

private let turnBoundaryLandID = "record-turn-boundary:local"

private struct TurnBoundaryRun {
    let bytes: Data
    let backstopCloses: Int
    let turns: [ReevaluationTickRecord]
    let inTurn: Bool
    /// Pending (open) records after the script, before the save.
    let openAtEnd: Int
}

/// Plays one fixed script on a fresh keeper and returns its saved record.
private func recordTurnBoundaryRun(tick: Bool, inTurn: Bool, forceTimer: Bool, path: String) async throws -> TurnBoundaryRun {
    let keeper = LandKeeper<TurnBoundaryState>(
        definition: makeTurnBoundaryLand(tick: tick),
        initialState: TurnBoundaryState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    if forceTimer { await recorder.forceTimerFlushAfterEverySubmitForTesting() }
    await keeper.setLandID(turnBoundaryLandID)
    let transport = VerifierTransport()
    let adapter = TransportAdapter<TurnBoundaryState>(
        keeper: keeper, transport: transport, landID: turnBoundaryLandID, inTurnSync: inTurn
    )
    await transport.setDelegate(adapter)
    await keeper.awaitInitialization()
    await keeper.setTransport(adapter)
    #expect(await keeper.isUsingInTurnSync() == (inTurn && InTurnSync.isEnabled()))
    // The header first, as `LandManager` sets it: the records stream into the file from here.
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: turnBoundaryLandID,
        landType: "record-turn-boundary",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "record-turn-boundary",
        rngSeed: DeterministicSeed.fromLandID(turnBoundaryLandID),
        recordsSyncStream: await keeper.recordsSyncStream,
        syncConfig: adapter.syncConfigForRecord
    ))

    // A tickless in-turn join goes through the adapter's join path: the land has no OnJoin, so
    // the join flips in the sync-only turn its registration requests, and `performJoin` returns
    // after that flip (a tickless sync-only turn that records a seed marker). A tick land's
    // join would wait for a tick, so it joins the direct way.
    let keeperInTurn = await keeper.isUsingInTurnSync()
    let joinsInTurn = !tick && keeperInTurn
    func join(_ n: Int) async throws {
        let session = SessionID("s\(n)"), client = ClientID("c\(n)")
        await adapter.onConnect(sessionID: session, clientID: client)
        if joinsInTurn {
            let result = try await adapter.performJoin(
                playerSession: PlayerSession(playerID: "p\(n)", deviceID: "dev", metadata: [:]),
                clientID: client, sessionID: session, authInfo: nil,
                joinResponse: { playerID, slot in
                    try? JSONEncoder().encode(TransportMessage.joinResponse(
                        requestID: "r-\(playerID.rawValue)", success: true,
                        playerID: playerID.rawValue, playerSlot: slot, encoding: "json"
                    ))
                }
            )
            #expect(result?.completedInTurn == true)
        } else {
            try await simulateRouterJoin(
                adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p\(n)")
            )
        }
        _ = await adapter.waitForOutboundDrain()
        await keeper.waitForRecorderSubmissionsForTesting()
    }
    func act(_ n: Int, _ value: Int) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: TurnBoundaryAction.self),
                payload: AnyCodable(TurnBoundaryAction(value: value))
            ),
            playerID: PlayerID("p\(n)"), clientID: ClientID("c\(n)"), sessionID: SessionID("s\(n)")
        )
        await keeper.waitForRecorderSubmissionsForTesting()
    }
    func step() async {
        guard tick else { return }
        await keeper.stepTickOnce()
        _ = await adapter.waitForOutboundDrain()
        await keeper.waitForRecorderSubmissionsForTesting()
    }

    try await join(1)
    await step()
    try await act(1, 3)
    try await act(1, 4)
    await step()
    try await join(2)
    try await act(2, 5)
    await step()
    try await act(1, 6)
    try await act(2, 7)
    await step()
    await step()
    if !tick {
        // A disconnect. The land has no OnLeave, so the leave records nothing; in-turn, the
        // player's clear marker is recorded after the leave, outside any keeper turn, and
        // ends a turn record of its own: nothing is left open for a later turn to close.
        await adapter.onDisconnect(sessionID: SessionID("s2"), clientID: ClientID("c2"))
        await keeper.waitForRecorderSubmissionsForTesting()
    }
    let openAtEnd = await recorder.bufferedStateForTesting().pendingRecords

    await keeper.waitForRecorderSubmissionsForTesting()
    try await recorder.save(to: path)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    return TurnBoundaryRun(
        bytes: bytes,
        backstopCloses: await recorder.backstopClosesForTesting,
        turns: try ReevaluationRecordLogReader.records(Array(bytes)),
        inTurn: keeperInTurn,
        openAtEnd: openAtEnd
    )
}

@Test(
    "A live record is the same bytes with the flush timer firing after every recorder call (#327)",
    arguments: [(true, true), (true, false), (false, true), (false, false)]
)
func liveRecordBytesDoNotDependOnTheTimer(tick: Bool, inTurn: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-turn-boundary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let plain = try await recordTurnBoundaryRun(
        tick: tick, inTurn: inTurn, forceTimer: false, path: directory.appendingPathComponent("plain.sstr").path
    )
    let forcedPath = directory.appendingPathComponent("forced.sstr").path
    let forced = try await recordTurnBoundaryRun(tick: tick, inTurn: inTurn, forceTimer: true, path: forcedPath)

    #expect(plain.bytes == forced.bytes, "\(plain.bytes.count) B against \(forced.bytes.count) B")
    #expect(plain.turns.count == forced.turns.count)
    #expect(plain.backstopCloses == 0 && forced.backstopCloses == 0)
    let turns = forced.turns
    if tick {
        // One turn record per tick (OnInitialize and the first join are tick 0): the sync
        // outputs of a tick turn are in its record, not a second one.
        let maxTick = try await ReevaluationRecordFile.openSource(filePath: forcedPath).getMaxTickId()
        #expect(turns.map(\.tickId) == Array(0...maxTick))
    } else {
        // One turn record per keeper turn: OnInitialize, then each action's input turn (its
        // sync outputs, when it asked for a sync, in the same record: the turn record is the
        // turn's last enqueue), and in-turn each join's sync-only turn (its seed marker).
        #expect(turns.allSatisfy { $0.tickId == 0 })
        #expect(turns.first?.initialize != nil)
        let actionTurns = turns.filter { !$0.actions.isEmpty }
        #expect(actionTurns.map(\.actions.count) == [1, 1, 1, 1, 1])
        let joinTurns = turns.filter { $0.syncMarkers.contains { $0.kind == .seed } }
        // Every turn closed itself: none waits for the save.
        #expect(plain.openAtEnd == 0 && forced.openAtEnd == 0)
        if forced.inTurn {
            // OnInitialize, 2 join sync-only turns, 5 input turns, and the clear marker's own
            // record.
            #expect(turns.count == 9)
            #expect(actionTurns.filter { !$0.syncOutputs.isEmpty }.count == 3, "the actions with a value from 5 on")
            #expect(joinTurns.count == 2 && joinTurns.allSatisfy { $0.actions.isEmpty && $0.syncOutputs.count == 1 })
            #expect(turns.last.map { $0.syncMarkers.map(\.kind) == [.clear] && $0.lifecycleEvents.isEmpty } == true)
        } else {
            // OnInitialize and 5 passes; no sync stream.
            #expect(turns.count == 6)
            #expect(turns.allSatisfy { $0.syncMarkers.isEmpty })
        }
    }

    // The forced record replays clean (a tickless one on the land with an empty tick handler).
    let result = try await ReevaluationEngine.run(
        definition: makeTurnBoundaryLand(tick: tick, replayTick: !tick),
        initialState: TurnBoundaryState(),
        recordFilePath: forcedPath
    )
    #expect(result.recordCompleteness == .complete)
    if tick {
        #expect(!result.recordedStateHashes.isEmpty)
        #expect(result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil } == result.recordedStateHashes)
        #expect(result.serverEventVerification == .passed, "\(result.serverEventMismatches.map(\.tickId))")
    }
    // A tickless record carries no per-tick state hash, and replaying its inputs is #322 /
    // #325 (on main it doesn't reproduce the live sequence numbers); here the bytes are the check.
}
