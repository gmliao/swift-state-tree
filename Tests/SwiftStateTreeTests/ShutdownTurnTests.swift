// Tests/SwiftStateTreeTests/ShutdownTurnTests.swift
//
// `forceShutdown` as a keeper turn (#382): the shutdown turn clears the players (no OnLeave),
// drops the inputs still queued and sets the drain flag in one synchronous segment, recorded
// as the lifecycle event "shutdown"; replay stops at it.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ShutdownTurnState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    /// What ran, in order: "join:<player>", "leave:<player>", "tick", "add", "finalize".
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@Payload
struct ShutdownAdd: ActionPayload {
    typealias Response = ShutdownAck
    let amount: Int
}

@Payload
struct ShutdownAck: ResponsePayload {
    let ok: Bool
}

/// Where a test's keeper applies its inputs.
enum ShutdownPath: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// Tickless, in-turn sync: the input drain.
    case inTurn
    /// Tickless, off in-turn sync: the legacy pass.
    case legacy
    /// A tick land (legacy tick path): the shutdown turn between ticks.
    case tick

    var testDescription: String { rawValue }
}

private func makeShutdownDefinition(tick: Bool, destroyWhenEmpty: Bool = false) -> LandDefinition<ShutdownTurnState> {
    if tick, destroyWhenEmpty {
        return Land("shutdown-turn", using: ShutdownTurnState.self) {
            Rules {
                OnJoin { (state: inout ShutdownTurnState, ctx: LandContext) in
                    state.log.append("join:\(ctx.playerID.rawValue)")
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (state: inout ShutdownTurnState, _: LandContext) in
                    state.log.append("tick")
                }
                DestroyWhenEmpty(after: .seconds(3600)) { (_: inout ShutdownTurnState, _: LandContext) in }
            }
        }
    }
    if tick {
        return Land("shutdown-turn", using: ShutdownTurnState.self) {
            Rules {
                OnJoin { (state: inout ShutdownTurnState, ctx: LandContext) in
                    state.log.append("join:\(ctx.playerID.rawValue)")
                }
                OnLeave { (state: inout ShutdownTurnState, ctx: LandContext) in
                    state.log.append("leave:\(ctx.playerID.rawValue)")
                }
                HandleAction(ShutdownAdd.self) {
                    (state: inout ShutdownTurnState, action: ShutdownAdd, _: LandContext) in
                    state.total += action.amount
                    state.log.append("add")
                    return ShutdownAck(ok: true)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (state: inout ShutdownTurnState, _: LandContext) in
                    state.log.append("tick")
                }
                OnFinalize { (state: inout ShutdownTurnState, _: LandContext) in
                    state.log.append("finalize")
                }
            }
        }
    }
    if destroyWhenEmpty {
        return Land("shutdown-turn", using: ShutdownTurnState.self) {
            Rules {
                OnJoin { (state: inout ShutdownTurnState, ctx: LandContext) in
                    state.log.append("join:\(ctx.playerID.rawValue)")
                }
                OnLeave { (state: inout ShutdownTurnState, ctx: LandContext) in
                    state.log.append("leave:\(ctx.playerID.rawValue)")
                }
            }
            Lifetime {
                // Started by the test (`runEmptyRoomShutdownForTesting`), not by the timer.
                DestroyWhenEmpty(after: .seconds(3600)) { (_: inout ShutdownTurnState, _: LandContext) in }
                OnFinalize { (state: inout ShutdownTurnState, _: LandContext) in
                    state.log.append("finalize")
                }
            }
        }
    }
    return Land("shutdown-turn", using: ShutdownTurnState.self) {
        Rules {
            OnJoin { (state: inout ShutdownTurnState, ctx: LandContext) in
                state.log.append("join:\(ctx.playerID.rawValue)")
            }
            OnLeave { (state: inout ShutdownTurnState, ctx: LandContext) in
                state.log.append("leave:\(ctx.playerID.rawValue)")
            }
            HandleAction(ShutdownAdd.self) {
                (state: inout ShutdownTurnState, action: ShutdownAdd, _: LandContext) in
                state.total += action.amount
                state.log.append("add")
                return ShutdownAck(ok: true)
            }
        }
        Lifetime {
            OnFinalize { (state: inout ShutdownTurnState, _: LandContext) in
                state.log.append("finalize")
            }
        }
    }
}

/// In-turn sync for every keeper; counts what would reach a client: sync phases that include
/// the sync, and server events. Not an actor: its synchronous calls need no isolation.
private final class ShutdownInTurnTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var syncs = 0
    private var events = 0

    /// Sync phases run with the sync included, plus server events handed over.
    var outputs: Int { lock.withLock { syncs + events } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        lock.withLock { events += 1 }
    }
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        lock.withLock {
            if includeSync { syncs += 1 }
            self.events += events.count
        }
        return includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

/// Counts arrivals at a hold point, so a test holds only the first.
private actor ArrivalCount {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")
private let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")

private func add(_ amount: Int) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: ShutdownAdd.self), payload: AnyCodable(ShutdownAdd(amount: amount)))
}

private func makeKeeper(
    _ path: ShutdownPath,
    destroyWhenEmpty: Bool = false,
    recording: Bool = false,
    transport: (any LandKeeperTransport)? = nil
) async throws -> LandKeeper<ShutdownTurnState> {
    let definition = makeShutdownDefinition(tick: path == .tick, destroyWhenEmpty: destroyWhenEmpty)
    let keeper = LandKeeper<ShutdownTurnState>(
        definition: definition,
        initialState: ShutdownTurnState(),
        enableLiveStateHashRecording: recording,
        autoStartLoops: false,
        transport: transport ?? (path == .inTurn ? ShutdownInTurnTransport() : nil)
    )
    // One land ID per keeper: parallel tests must not share a recorder spool.
    let landID = "\(definition.id):\(UUID().uuidString)"
    await keeper.setLandID(landID)
    if recording {
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: definition.id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: definition.id,
            rngSeed: DeterministicSeed.fromLandID(landID),
            version: ReevaluationRecordVersion.current
        ))
    }
    if transport == nil {
        #expect(await keeper.isUsingInTurnSync() == (path == .inTurn))
    }
    return keeper
}

/// Joins `players`; a tick land applies their OnJoin in a tick.
private func join(_ keeper: LandKeeper<ShutdownTurnState>, _ path: ShutdownPath, _ players: [(PlayerID, ClientID, SessionID)]) async throws {
    for (player, client, session) in players {
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
    }
    if path == .tick { await keeper.stepTickOnce() }
}

private func saveRecord(_ keeper: LandKeeper<ShutdownTurnState>, name: String) async throws -> String {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString).sstr").path
    try await recorder.save(to: path)
    return path
}

private func replayKeeper(tick: Bool, destroyWhenEmpty: Bool = false, frames: [ReevaluationTickFrame]) async -> LandKeeper<ShutdownTurnState> {
    let metadata = ReevaluationRecordMetadata(
        landID: "shutdown-turn:replay",
        landType: "shutdown-turn",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: "shutdown-turn",
        version: ReevaluationRecordVersion.current
    )
    let keeper = LandKeeper<ShutdownTurnState>(
        definition: makeShutdownDefinition(tick: tick, destroyWhenEmpty: destroyWhenEmpty),
        initialState: ShutdownTurnState(),
        mode: .reevaluation,
        reevaluationSource: JSONReevaluationSource(metadata: metadata, frames: frames),
        autoStartLoops: false
    )
    await keeper.setLandID("shutdown-turn:replay")
    return keeper
}

private func recordedLifecycle(_ kind: String, sequence: Int64, tickId: Int64, player: String? = nil) -> ReevaluationRecordedLifecycleEvent {
    ReevaluationRecordedLifecycleEvent(
        kind: kind,
        sequence: sequence,
        tickId: tickId,
        playerID: player,
        clientID: player.map { "c-\($0)" },
        sessionID: player.map { "s-\($0)" },
        deviceID: nil,
        isGuest: nil,
        metadata: [:],
        resolverOutputs: [:],
        resolvedAtTick: tickId - 1
    )
}

private func recordedAdd(_ amount: Int, sequence: Int64, tickId: Int64, player: String) -> ReevaluationRecordedAction {
    ReevaluationRecordedAction(
        kind: "action",
        sequence: sequence,
        typeIdentifier: String(describing: ShutdownAdd.self),
        payload: AnyCodable(ShutdownAdd(amount: amount)),
        playerID: player,
        clientID: "c-\(player)",
        sessionID: "s-\(player)",
        resolverOutputs: [:],
        resolvedAtTick: tickId - 1
    )
}

@Suite("Forced shutdown as a turn (#382)", .timeLimit(.minutes(1)))
struct ShutdownTurnTests {
    @Test("The clear, the drop and the drain flag are seen together right after the shutdown turn, before the destroy", arguments: ShutdownPath.allCases)
    func oneTurn(path: ShutdownPath) async throws {
        let keeper = try await makeKeeper(path)
        try await join(keeper, path, [(p1, c1, s1), (p2, c2, s2)])
        #expect(await keeper.playerCount() == 2)

        let gate = WatermarkGate()
        await keeper.installHolds(HoldRegistry.at(.shutdownTurnApplied) { await gate.enterAndWait() })
        let shutdown = Task { await keeper.forceShutdown() }
        guard try await withinDeadline("the shutdown turn applies", { await gate.waitUntilEntered() }) != nil else { return }

        #expect(await keeper.playerCount() == 0, "the players are cleared in the turn")
        #expect(await keeper.pendingItemSequencesForTesting().isEmpty, "nothing is left queued")
        #expect(keeper.isDraining, "the drain flag is set in the turn")
        #expect(keeper.destructionCause == .forceShutdown)
        #expect(await !keeper.currentState().log.contains("finalize"), "the destroy runs after the turn")
        #expect(await !keeper.currentState().log.contains { $0.hasPrefix("leave:") }, "no OnLeave runs")

        gate.release()
        await shutdown.value
        #expect(await keeper.currentState().log.last == "finalize")
    }

    @Test("A frozen land's forceShutdown ends the freeze and returns; the intake it held is rejected", arguments: ShutdownPath.allCases)
    func frozenLand(path: ShutdownPath) async throws {
        let keeper = try await makeKeeper(path)
        try await join(keeper, path, [(p1, c1, s1)])
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)

        // Tickless intake waits while frozen; a tick land only queues the action.
        let held = Task {
            try await keeper.handleActionEnvelope(add(7), playerID: p1, clientID: c1, sessionID: s1)
        }
        guard await signals.wait(for: path == .tick ? "action-queued" : "input-held-frozen") else { return }

        guard try await withinDeadline("forceShutdown returns on a frozen land", { await keeper.forceShutdown() }) != nil else {
            return
        }
        #expect(await !keeper.isDebugFrozen())
        let result = try #require(try await withinDeadline("the held action returns", { await held.result }))
        if path == .tick {
            // The queue ACK, then dropped by the shutdown turn.
            #expect((try? result.get()) != nil)
        } else {
            #expect(result.failureRejection == .landClosed)
        }
        #expect(await keeper.currentState().total == 0)
        #expect(await keeper.currentState().log.last == "finalize")
    }

    @Test("Tick land: no tick starts between the wait for the tick in flight and the shutdown turn")
    func tickStopGate() async throws {
        // In-turn tick land: a tick holds at its record, still in flight.
        let keeper = try await makeKeeper(.tick, transport: ShutdownInTurnTransport())
        try await join(keeper, .tick, [(p1, c1, s1)])
        let ticksBefore = await keeper.currentState().log.filter { $0 == "tick" }.count

        let gate = WatermarkGate()
        let arrivals = ArrivalCount()
        await keeper.installHolds { point in
            if point == .turnRecord, await arrivals.next() == 1 { await gate.enterAndWait() }
        }
        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)
        let tickInFlight = Task { await keeper.stepTickOnce() }
        guard try await withinDeadline("the tick holds at its record", { await gate.waitUntilEntered() }) != nil else { return }

        let shutdown = Task { await keeper.forceShutdown() }
        guard await signals.wait(for: "shutdown-stop-gate") else { return }
        // A tick asked for now doesn't start.
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log.filter { $0 == "tick" }.count == ticksBefore + 1)
        #expect(!keeper.isDraining)

        gate.release()
        await tickInFlight.value
        await shutdown.value
        #expect(await keeper.currentState().log.filter { $0 == "tick" }.count == ticksBefore + 1)
        #expect(await keeper.currentState().log.last == "finalize")
    }

    @Test("Concurrent forceShutdown calls queue one shutdown input and all return")
    func concurrentCallsShareOneShutdown() async throws {
        let keeper = try await makeKeeper(.inTurn)
        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)
        try await join(keeper, .inTurn, [(p1, c1, s1)])
        // The join's drain has ended, so the shutdown's drain starts at the hold.
        guard await signals.waitForInputDrainIdle(keeper) else { return }

        let gate = WatermarkGate()
        await keeper.installHolds(HoldRegistry.at(.inputDrain) { await gate.enterAndWait() })
        let first = Task { await keeper.forceShutdown() }
        let second = Task { await keeper.forceShutdown() }
        // Both calls have joined the flight, and the shutdown's drain holds.
        guard await signals.wait(for: "force-shutdown-joined", count: 2) else { return }
        guard try await withinDeadline("the shutdown's input drain holds", { await gate.waitUntilEntered() }) != nil else { return }
        #expect(await keeper.pendingItemSequencesForTesting().count == 1)

        await keeper.installHolds(nil)
        gate.release()
        guard try await withinDeadline("both calls return", { () async -> Void in
            await first.value
            await second.value
        }) != nil else { return }
        #expect(await keeper.currentState().log == ["join:p1", "finalize"])
    }

    @Test("Tickless: a leave queued before the shutdown runs its OnLeave; a join after it is rejected", arguments: [ShutdownPath.inTurn, .legacy])
    func arrivalOrder(path: ShutdownPath) async throws {
        let keeper = try await makeKeeper(path)
        try await join(keeper, path, [(p1, c1, s1), (p2, c2, s2)])
        try await keeper.leave(playerID: p2, clientID: c2, sessionID: s2)
        await keeper.forceShutdown()

        await #expect(throws: JoinError.self) {
            try await keeper.join(playerID: PlayerID("late"), clientID: ClientID("cl"), sessionID: SessionID("sl"))
        }
        #expect(await keeper.currentState().log == ["join:p1", "join:p2", "leave:p2", "finalize"])
    }

    @Test("Legacy tickless: another caller's pass applies the shutdown first; that caller's input, behind it, gets landClosed")
    func legacyCallerPassAppliesTheShutdown() async throws {
        let keeper = try await makeKeeper(.legacy)
        try await join(keeper, .legacy, [(p1, c1, s1)])

        let gate = WatermarkGate()
        await keeper.installHolds(HoldRegistry.at(.legacyShutdownPass) { await gate.enterAndWait() })
        let shutdown = Task { await keeper.forceShutdown() }
        guard try await withinDeadline("the shutdown's own pass holds", { await gate.waitUntilEntered() }) != nil else { return }

        // This caller's pass applies every ready input: the shutdown, then the batch ends.
        do {
            _ = try await keeper.handleActionEnvelope(add(5), playerID: p1, clientID: c1, sessionID: s1)
            Issue.record("Expected landClosed")
        } catch {
            #expect(error as? LandInputRejection == .landClosed)
        }
        guard try await withinDeadline("forceShutdown returns", { await shutdown.value }) != nil else { return }
        await keeper.installHolds(nil)
        gate.release()
        await keeper.waitForInFlightWorkForTesting()
        #expect(await keeper.currentState().total == 0)
        #expect(await keeper.currentState().log == ["join:p1", "finalize"])
    }

    @Test("Tick land: a join after the shutdown turn gets landShuttingDown")
    func tickJoinAfterShutdown() async throws {
        let keeper = try await makeKeeper(.tick)
        try await join(keeper, .tick, [(p1, c1, s1)])
        await keeper.forceShutdown()
        do {
            try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
            Issue.record("Expected landShuttingDown")
        } catch let error as JoinError {
            guard case .landShuttingDown = error else {
                Issue.record("Unexpected join error: \(error)")
                return
            }
        }
    }

    @Test("The shutdown turn sends nothing: no sync phase with the sync, no server event")
    func shutdownTurnSendsNoFrame() async throws {
        let transport = ShutdownInTurnTransport()
        let keeper = try await makeKeeper(.inTurn, transport: transport)
        try await join(keeper, .inTurn, [(p1, c1, s1)])
        await keeper.waitForInFlightWorkForTesting()

        let gate = WatermarkGate()
        await keeper.installHolds(HoldRegistry.at(.shutdownTurnApplied) { await gate.enterAndWait() })
        let before = transport.outputs
        let shutdown = Task { await keeper.forceShutdown() }
        guard try await withinDeadline("the shutdown turn applies", { await gate.waitUntilEntered() }) != nil else { return }
        #expect(transport.outputs == before)
        gate.release()
        await shutdown.value
    }

    @Test("Tickless: an empty-room drain that starts before the shutdown turn drops its input; forceShutdown waits for that drain")
    func emptyRoomDrainBeforeTheTurn() async throws {
        let keeper = try await makeKeeper(.inTurn, destroyWhenEmpty: true)
        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)
        try await join(keeper, .inTurn, [(p1, c1, s1)])
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.playerCount() == 0)
        // The leave's input drain has ended, so the shutdown's drain starts at the hold.
        guard await signals.waitForInputDrainIdle(keeper) else { return }

        let gate = WatermarkGate()
        await keeper.installHolds(HoldRegistry.at(.inputDrain) { await gate.enterAndWait() })
        let shutdown = Task { await keeper.forceShutdown() }
        // The shutdown input is queued, and the drain it scheduled holds.
        guard await signals.wait(for: "shutdown-queued") else { return }
        guard try await withinDeadline("the shutdown's input drain holds", { await gate.waitUntilEntered() }) != nil else { return }

        await keeper.runEmptyRoomShutdownForTesting()
        guard try await withinDeadline("forceShutdown returns after that drain", { await shutdown.value }) != nil else { return }
        #expect(keeper.destructionCause == .emptyTimeout)
        #expect(await keeper.currentState().log == ["join:p1", "leave:p1", "finalize"])
        await keeper.installHolds(nil)
        gate.release()
    }

    // MARK: - Record and replay

    @Test("Record, shut down, replay: 0 mismatches, and the record holds one shutdown event", arguments: ShutdownPath.allCases)
    func recordAndReplay(path: ShutdownPath) async throws {
        let keeper = try await makeKeeper(path, recording: true)
        try await join(keeper, path, [(p1, c1, s1), (p2, c2, s2)])
        _ = try await keeper.handleActionEnvelope(add(3), playerID: p1, clientID: c1, sessionID: s1)
        if path == .tick {
            await keeper.stepTickOnce()
            // Queued for a tick that never comes: the shutdown turn drops it.
            _ = try await keeper.handleActionEnvelope(add(100), playerID: p2, clientID: c2, sessionID: s2)
        }
        await keeper.forceShutdown()

        let file = try await saveRecord(keeper, name: "shutdown-turn-\(path.rawValue)")
        defer { try? FileManager.default.removeItem(atPath: file) }

        // The public reader decodes the event's kind as its string.
        let source = try ReevaluationRecordFile.openSource(filePath: file)
        #expect(try await source.getMetadata().version == "3.2")
        let maxTickId = try await source.getMaxTickId()
        var shutdownEvents: [(tickId: Int64, event: ReevaluationRecordedLifecycleEvent)] = []
        for tickId in 0...max(maxTickId, 0) {
            for event in try await source.getLifecycleEvents(for: tickId) where event.kind == "shutdown" {
                shutdownEvents.append((tickId, event))
            }
        }
        #expect(shutdownEvents.count == 1)
        #expect(shutdownEvents.first?.event.playerID == nil)
        #expect(try await source.getActions(for: maxTickId).allSatisfy { $0.sequence < (shutdownEvents.first?.event.sequence ?? 0) })

        let result = try await ReevaluationEngine.run(
            definition: makeShutdownDefinition(tick: path == .tick),
            initialState: ShutdownTurnState(),
            recordFilePath: file
        )
        #expect(result.recordedPassMismatches.isEmpty)
        // A tick land records a hash per tick; a tickless one records none per tick.
        if path == .tick { #expect(!result.recordedStateHashes.isEmpty) }
        #expect(result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil } == result.recordedStateHashes)
        if path == .tick {
            // The shutdown's own frame, after the last tick: the same state, so the same hash.
            let frameTick = try #require(shutdownEvents.first?.tickId)
            #expect(frameTick == maxTickId)
            let shutdownHash = try #require(result.recordedStateHashes[frameTick])
            #expect(result.recordedStateHashes[frameTick - 1] == shutdownHash)
        }
    }

    @Test("Replay: the shutdown ends the replay only; a viewer stays, a new viewer joins, and the last leave arms the empty-room destroy")
    func replayShutdownKeepsTheViewers() async throws {
        let keeper = await replayKeeper(tick: true, destroyWhenEmpty: true, frames: [
            ReevaluationTickFrame(
                tickId: 0,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [recordedLifecycle("join", sequence: 1, tickId: 0, player: "p1")]
            ),
            ReevaluationTickFrame(
                tickId: 1,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [recordedLifecycle("shutdown", sequence: 2, tickId: 1)]
            ),
        ])
        let viewer = PlayerID("viewer"), viewerClient = ClientID("cv"), viewerSession = SessionID("sv")
        try await keeper.join(playerID: viewer, clientID: viewerClient, sessionID: viewerSession)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.takeRecordedPassMismatch(for: 1) == nil)
        #expect(await keeper.currentState().log == ["join:p1", "tick"])
        #expect(await keeper.playerCount() == 1, "the viewer stays")
        #expect(!keeper.isDraining, "the replay land stays open")

        let late = PlayerID("late"), lateClient = ClientID("cl"), lateSession = SessionID("sl")
        try await keeper.join(playerID: late, clientID: lateClient, sessionID: lateSession)
        try await keeper.leave(playerID: late, clientID: lateClient, sessionID: lateSession)
        #expect(await keeper.destroyTimerForTesting() == nil)
        try await keeper.leave(playerID: viewer, clientID: viewerClient, sessionID: viewerSession)
        #expect(await keeper.destroyTimerForTesting() != nil, "the last leave arms the empty-room destroy")
    }

    @Test("Replay: inputs recorded after the shutdown event are not applied, and the shutdown frame runs no tick handler")
    func replayStopsAtShutdown() async throws {
        let keeper = await replayKeeper(tick: true, frames: [
            ReevaluationTickFrame(
                tickId: 0,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [recordedLifecycle("join", sequence: 1, tickId: 0, player: "p1")]
            ),
            ReevaluationTickFrame(
                tickId: 1,
                actions: [recordedAdd(5, sequence: 3, tickId: 1, player: "p1")],
                clientEvents: [],
                lifecycleEvents: [recordedLifecycle("shutdown", sequence: 2, tickId: 1)]
            ),
            ReevaluationTickFrame(
                tickId: 2,
                actions: [recordedAdd(7, sequence: 4, tickId: 2, player: "p1")],
                clientEvents: [],
                lifecycleEvents: []
            ),
        ])
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.takeRecordedPassMismatch(for: 1) == nil)
        #expect(await keeper.currentState().log == ["join:p1", "tick"])
        #expect(await keeper.currentState().total == 0)
        #expect(await keeper.playerCount() == 0)
    }

    @Test("Replay: a lifecycle kind this build doesn't know fails the tick, instead of being replayed as initialize")
    func unknownLifecycleKindFails() async throws {
        let keeper = await replayKeeper(tick: true, frames: [
            ReevaluationTickFrame(
                tickId: 0,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [recordedLifecycle("someFutureKind", sequence: 1, tickId: 0, player: "p1")]
            ),
        ])
        await keeper.stepTickOnce()
        let mismatch = try #require(await keeper.takeRecordedPassMismatch(for: 0))
        #expect(mismatch.contains("someFutureKind"))
    }
}

private extension Result where Failure == any Error {
    var failureRejection: LandInputRejection? {
        if case .failure(let error) = self { return error as? LandInputRejection }
        return nil
    }
}
