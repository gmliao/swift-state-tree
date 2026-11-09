// Tests/SwiftStateTreeTests/TicklessReplayPassTests.swift
//
// A tickless land's replay applies its inputs pass by pass, in the order the live run applied
// them, and restores the sequence counter before each pass (record format 3.1, #325, #321).
// Interleavings are forced with gates and hold points, never with timing.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

@StateNodeBuilder
struct PassOrderState: StateNodeProtocol {
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@Payload
struct PassGatedAction: ActionPayload {
    typealias Response = PassAck
    /// Also the key of the action's resolver gate (`PassGates`).
    let key: Int
    let tag: String
}

@Payload
struct PassPlainAction: ActionPayload {
    typealias Response = PassAck
    let tag: String
}

@Payload
struct PassSyncAction: ActionPayload {
    typealias Response = PassAck
    let tag: String
}

@Payload
struct PassAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct PassNoteEvent: ClientEventPayload {
    let tag: String
}

/// Emitted by every handler with the log after it, so a replay in another order fails on the
/// events' payloads (a tickless land records no state hash).
@Payload
struct PassLogged: ServerEventPayload {
    let entry: String
    let length: Int
}

struct PassResolverOutput: ResolverOutput {
    let key: Int
}

/// One gate per key: resolvers are static, and parallel tests must not share a gate.
enum PassGates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [Int: WatermarkGate] = [:]

    static func gate(_ key: Int) -> WatermarkGate {
        lock.withLock {
            if let gate = gates[key] { return gate }
            let gate = WatermarkGate()
            gates[key] = gate
            return gate
        }
    }
}

struct PassGatedResolver: ContextResolver {
    typealias Output = PassResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> PassResolverOutput {
        let key = (ctx.actionPayload as? PassGatedAction)?.key ?? -1
        await PassGates.gate(key).enterAndWait()
        return PassResolverOutput(key: key)
    }
}

struct PassInitResolver: ContextResolver {
    typealias Output = PassResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> PassResolverOutput {
        for _ in 0..<5 { await Task.yield() }
        return PassResolverOutput(key: 7)
    }
}

private func appendEntry(_ entry: String, to state: inout PassOrderState, ctx: LandContext) {
    state.log.append(entry)
    ctx.emitEvent(PassLogged(entry: entry, length: state.log.count), to: .all)
}

private func makePassDefinition(initializeWithResolver: Bool = false) -> LandDefinition<PassOrderState> {
    guard initializeWithResolver else {
        return Land("pass-order", using: PassOrderState.self) {
        ClientEvents { Register(PassNoteEvent.self) }
        ServerEvents { Register(PassLogged.self) }
        Rules {
            OnJoin { (state: inout PassOrderState, ctx: LandContext) in
                appendEntry("join:\(ctx.playerID.rawValue)", to: &state, ctx: ctx)
            }
            OnLeave { (state: inout PassOrderState, ctx: LandContext) in
                appendEntry("leave:\(ctx.playerID.rawValue)", to: &state, ctx: ctx)
            }
            HandleAction(PassGatedAction.self, resolvers: PassGatedResolver.self) {
                (state: inout PassOrderState, action: PassGatedAction, ctx: LandContext) in
                appendEntry(action.tag, to: &state, ctx: ctx)
                return PassAck(ok: true)
            }
            HandleAction(PassPlainAction.self) {
                (state: inout PassOrderState, action: PassPlainAction, ctx: LandContext) in
                appendEntry(action.tag, to: &state, ctx: ctx)
                return PassAck(ok: true)
            }
            HandleAction(PassSyncAction.self) {
                (state: inout PassOrderState, action: PassSyncAction, ctx: LandContext) in
                appendEntry(action.tag, to: &state, ctx: ctx)
                ctx.requestSyncNow()
                return PassAck(ok: true)
            }
            HandleEvent(PassNoteEvent.self) { (state: inout PassOrderState, event: PassNoteEvent, ctx: LandContext) in
                appendEntry(event.tag, to: &state, ctx: ctx)
            }
        }
        }
    }
    let onInitialize: LifetimeDirective<PassOrderState> = OnInitialize(resolvers: PassInitResolver.self) {
        (state: inout PassOrderState, ctx: LandContext) in
        appendEntry("init", to: &state, ctx: ctx)
    }
    return Land("pass-order", using: PassOrderState.self) {
        ClientEvents { Register(PassNoteEvent.self) }
        ServerEvents { Register(PassLogged.self) }
        Rules {
            OnJoin { (state: inout PassOrderState, ctx: LandContext) in
                appendEntry("join:\(ctx.playerID.rawValue)", to: &state, ctx: ctx)
            }
            HandleAction(PassGatedAction.self, resolvers: PassGatedResolver.self) {
                (state: inout PassOrderState, action: PassGatedAction, ctx: LandContext) in
                appendEntry(action.tag, to: &state, ctx: ctx)
                return PassAck(ok: true)
            }
            HandleAction(PassPlainAction.self) {
                (state: inout PassOrderState, action: PassPlainAction, ctx: LandContext) in
                appendEntry(action.tag, to: &state, ctx: ctx)
                return PassAck(ok: true)
            }
            HandleAction(PassSyncAction.self) {
                (state: inout PassOrderState, action: PassSyncAction, ctx: LandContext) in
                appendEntry(action.tag, to: &state, ctx: ctx)
                ctx.requestSyncNow()
                return PassAck(ok: true)
            }
            HandleEvent(PassNoteEvent.self) { (state: inout PassOrderState, event: PassNoteEvent, ctx: LandContext) in
                appendEntry(event.tag, to: &state, ctx: ctx)
            }
        }
        Lifetime { onInitialize }
    }
}

/// A legacy (not in-turn) transport that counts `syncNowFromTransport` calls.
private actor PassSyncCountingTransport: LandKeeperTransport {
    private(set) var syncNowCount = 0
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async { syncNowCount += 1 }
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
}

/// A legacy (not in-turn) transport that logs its delivery calls in order: `broadcast` for a
/// broadcast-only sync, `event:<entry>` for a `PassLogged` event.
private actor PassDeliveryLogTransport: LandKeeperTransport {
    private(set) var log: [String] = []
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        let data = (try? JSONEncoder().encode(event.payload)) ?? Data()
        let entry = (try? JSONDecoder().decode(PassLogged.self, from: data))?.entry ?? event.type
        log.append("event:\(entry)")
    }
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async { log.append("broadcast") }
    func onLandDestroyed() async {}
}

/// Reports in-turn sync for every keeper, so a keeper attached to it takes the input-drain
/// path (`usesInTurnSync`) whatever `IN_TURN_SYNC` says.
private final class PassInTurnTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

private let passLandID = "pass-order:local"
private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")
private let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")
private let p3 = PlayerID("p3"), c3 = ClientID("c3"), s3 = SessionID("s3")

private func makePassKeeper(inTurn: Bool, initializeWithResolver: Bool = false) async throws -> LandKeeper<PassOrderState> {
    let definition = makePassDefinition(initializeWithResolver: initializeWithResolver)
    let keeper = LandKeeper<PassOrderState>(
        definition: definition,
        initialState: PassOrderState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        transport: inTurn ? PassInTurnTransport() : nil
    )
    // One land ID per keeper: parallel tests must not share a recorder spool.
    let landID = "pass-order:\(UUID().uuidString)"
    await keeper.setLandID(landID)
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID,
        landType: "pass-order",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: definition.id,
        rngSeed: DeterministicSeed.fromLandID(landID),
        version: ReevaluationRecordVersion.current
    ))
    return keeper
}

private func gatedAction(key: Int, tag: String) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: PassGatedAction.self), payload: AnyCodable(PassGatedAction(key: key, tag: tag)))
}

private func plainAction(_ tag: String) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: PassPlainAction.self), payload: AnyCodable(PassPlainAction(tag: tag)))
}

/// Gate key per parameterized case, so parallel cases never share a gate.
private func passGateKey(_ base: Int, inTurn: Bool) -> Int { base * 10 + (inTurn ? 1 : 0) }

/// Saves the keeper's record to a temporary file and returns its path (removed by the caller).
private func savePassRecord(_ keeper: LandKeeper<PassOrderState>, name: String) async throws -> String {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString).sstr").path
    try await recorder.save(to: path)
    return path
}

private func replayPassRecord(_ path: String, initializeWithResolver: Bool = false) async throws -> ReevaluationEngine.RunResult {
    try await ReevaluationEngine.run(
        definition: makePassDefinition(initializeWithResolver: initializeWithResolver),
        initialState: PassOrderState(),
        recordFilePath: path
    )
}

/// Collects the replayed server events with their tick.
private actor PassReplaySink: ReevaluationSink {
    private(set) var events: [(tickId: Int64, event: ReevaluationRecordedServerEvent)] = []

    func onEmittedServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) async {
        self.events += events.map { (tickId, $0) }
    }
}

/// A replay keeper on `path`'s record, initialized, with its tick 0 not yet run.
private func makePassReplayKeeper(_ path: String, sink: PassReplaySink) async throws -> LandKeeper<PassOrderState> {
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    let keeper = LandKeeper<PassOrderState>(
        definition: makePassDefinition(),
        initialState: PassOrderState(),
        mode: .reevaluation,
        reevaluationSource: source,
        reevaluationSink: sink,
        autoStartLoops: false
    )
    await keeper.setLandID(try await source.getMetadata().landID)
    await keeper.awaitInitialization()
    return keeper
}

@Suite("Tickless replay in recorded apply order (#325, #321)", .timeLimit(.minutes(1)))
struct TicklessReplayPassTests {
    @Test("An input overtaking a pending action replays in live order, across sessions and kinds", arguments: [false, true])
    func overtakingInputsReplayInLiveOrder(inTurn: Bool) async throws {
        let key = passGateKey(1, inTurn: inTurn)
        let keeper = try await makePassKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)

        // A (p1) takes its sequence first and waits in its resolver.
        let actionA = Task {
            try await keeper.handleActionEnvelope(gatedAction(key: key, tag: "A"), playerID: p1, clientID: c1, sessionID: s1)
        }
        await PassGates.gate(key).waitUntilEntered()
        // A client event, an action and a join overtake it.
        try await keeper.handleClientEvent(AnyClientEvent(PassNoteEvent(tag: "E")), playerID: p2, clientID: c2, sessionID: s2)
        _ = try await keeper.handleActionEnvelope(plainAction("B"), playerID: p2, clientID: c2, sessionID: s2)
        try await keeper.join(playerID: p3, clientID: c3, sessionID: s3)
        PassGates.gate(key).release()
        _ = try await actionA.value

        #expect(await keeper.currentState().log == ["join:p1", "join:p2", "E", "B", "join:p3", "A"])
        let path = try await savePassRecord(keeper, name: "pass-overtake")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        // A has the lowest sequence of the four that came after the joins, but its pass is last.
        let gatedSequence = try #require(try await source.getActions(for: 0).first { $0.typeIdentifier.hasSuffix("PassGatedAction") }?.sequence)
        #expect(try await source.getPasses(for: 0).last?.inputs == [gatedSequence])

        let result = try await replayPassRecord(path)
        #expect(result.recordedPassMismatches.isEmpty)
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("A pass that applies several inputs restores its counter; replayed sequences equal live ones")
    func multiInputPassReplaysExactSequences() async throws {
        let keeper = try await makePassKeeper(inTurn: true)
        // The join's drain must have ended before the hold goes in: a drain still in its loop
        // (past its `.inputDrain` hold, yielding between turns) would take x itself.
        let (drainEnds, drainEnded) = AsyncStream.makeStream(of: Void.self)
        await keeper.setInTurnProbeForTesting { point in
            if point == "input-drain-end" { drainEnded.yield() }
        }
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        var ends = drainEnds.makeAsyncIterator()
        _ = await ends.next()
        await keeper.setInTurnProbeForTesting(nil)
        // Hold the next drain at its start, so three client events queue for one input turn.
        let gate = WatermarkGate()
        await keeper.installHolds { point in
            if point == .inputDrain { await gate.enterAndWait() }
        }
        try await keeper.handleClientEvent(AnyClientEvent(PassNoteEvent(tag: "x")), playerID: p1, clientID: c1, sessionID: s1)
        await gate.waitUntilEntered()
        try await keeper.handleClientEvent(AnyClientEvent(PassNoteEvent(tag: "y")), playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.handleClientEvent(AnyClientEvent(PassNoteEvent(tag: "z")), playerID: p1, clientID: c1, sessionID: s1)
        await keeper.installHolds(nil)
        // Wait for this drain's end, not for time: x, y and z go in its one turn.
        await keeper.setInTurnProbeForTesting { point in
            if point == "input-drain-end" { drainEnded.yield() }
        }
        gate.release()
        _ = await ends.next()
        await keeper.setInTurnProbeForTesting(nil)
        #expect(await keeper.currentState().log == ["join:p1", "x", "y", "z"])
        _ = try await keeper.handleActionEnvelope(plainAction("after"), playerID: p1, clientID: c1, sessionID: s1)

        let path = try await savePassRecord(keeper, name: "pass-multi")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let passes = try await source.getPasses(for: 0)
        #expect(passes.contains { $0.inputs.count == 3 }, "\(passes)")
        let recordedSequences = try await source.getServerEvents(for: 0).map(\.sequence)

        let result = try await replayPassRecord(path)
        #expect(result.watermarkedTicks == [0])
        #expect(result.serverEventMismatches.isEmpty, "recorded \(recordedSequences)")
        #expect(result.serverEventVerification == .passed)
    }

    @Test("Legacy passes interleaving at the record hold are recorded in apply order")
    func legacyPassesRecordInApplyOrder() async throws {
        let keeper = try await makePassKeeper(inTurn: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        // Hold the first pass after its record is enqueued; the second runs to its end.
        let gate = WatermarkGate()
        let held = ManagedFlag()
        await keeper.installHolds { point in
            if point == .turnRecord, held.setOnce() { await gate.enterAndWait() }
        }
        let first = Task {
            try await keeper.handleActionEnvelope(plainAction("first"), playerID: p1, clientID: c1, sessionID: s1)
        }
        await gate.waitUntilEntered()
        _ = try await keeper.handleActionEnvelope(plainAction("second"), playerID: p2, clientID: c2, sessionID: s2)
        gate.release()
        _ = try await first.value
        #expect(await keeper.currentState().log == ["join:p1", "join:p2", "first", "second"])

        let path = try await savePassRecord(keeper, name: "pass-interleave")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let passes = try await ReevaluationRecordFile.openSource(filePath: path).getPasses(for: 0)
        #expect(passes.map(\.sequenceBefore) == passes.map(\.sequenceBefore).sorted(), "\(passes)")
        let result = try await replayPassRecord(path)
        #expect(result.recordedPassMismatches.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("Replay runs each pass as an input turn: observable at the turn hold, nothing left over, tick 0")
    func replayRunsPassesAsTurns() async throws {
        let keeper = try await makePassKeeper(inTurn: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        for tag in ["a", "b", "c"] {
            _ = try await keeper.handleActionEnvelope(plainAction(tag), playerID: p1, clientID: c1, sessionID: s1)
        }
        let liveLog = await keeper.currentState().log
        let path = try await savePassRecord(keeper, name: "pass-turns")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let recorded = try await source.getServerEvents(for: 0)
        let passCount = try await source.getPasses(for: 0).count

        let sink = PassReplaySink()
        let replay = try await makePassReplayKeeper(path, sink: sink)
        let seen = PassLogLengths()
        await replay.installHolds { point in
            if point == .turnRecord { await seen.append(await replay.currentState().log.count) }
        }
        await replay.stepTickOnce()

        // One turn per pass, each seen at its record hold with its input applied.
        try #require(passCount > 0)
        #expect(await seen.values == Array(1...passCount))
        #expect(await replay.currentState().log == liveLog)
        #expect(await replay.pendingItemSequencesForTesting().isEmpty)
        #expect(await replay.inputTurnResultCountForTesting() == 0)
        let replayed = await sink.events
        #expect(replayed.allSatisfy { $0.tickId == 0 })
        #expect(replayed.map(\.event.sequence) == recorded.map(\.sequence))
    }

    @Test("A legacy pass's sync request runs in its own finish, not in a pass that ran during its hold")
    func legacySyncRequestStaysWithItsPass() async throws {
        let transport = PassSyncCountingTransport()
        let keeper = LandKeeper<PassOrderState>(
            definition: makePassDefinition(),
            initialState: PassOrderState(),
            autoStartLoops: false,
            transport: transport
        )
        await keeper.setLandID("pass-order:\(UUID().uuidString)")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let before = await transport.syncNowCount
        // Pass 1 requests a sync and is held at its record; pass 2 requests none and runs to its end.
        let gate = WatermarkGate()
        let held = ManagedFlag()
        await keeper.installHolds { point in
            if point == .turnRecord, held.setOnce() { await gate.enterAndWait() }
        }
        let first = Task {
            try await keeper.handleActionEnvelope(
                ActionEnvelope(typeIdentifier: String(describing: PassSyncAction.self), payload: AnyCodable(PassSyncAction(tag: "sync"))),
                playerID: p1, clientID: c1, sessionID: s1
            )
        }
        await gate.waitUntilEntered()
        _ = try await keeper.handleActionEnvelope(plainAction("plain"), playerID: p2, clientID: c2, sessionID: s2)
        #expect(await transport.syncNowCount == before, "pass 2 ran pass 1's sync request")
        gate.release()
        _ = try await first.value
        #expect(await transport.syncNowCount == before + 1, "pass 1's sync request was lost")
    }

    @Test("Legacy passes deliver in apply order: record, broadcast-only sync, then events, behind the earlier pass")
    func legacyDeliveryKeepsApplyOrder() async throws {
        let transport = PassDeliveryLogTransport()
        let keeper = LandKeeper<PassOrderState>(
            definition: makePassDefinition(),
            initialState: PassOrderState(),
            autoStartLoops: false,
            transport: transport
        )
        await keeper.setLandID("pass-order:\(UUID().uuidString)")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let base = await transport.log.count
        // Pass 1 (a leave: a broadcast-only sync and an event) is held at its delivery's start;
        // pass 2 (an action) applies and is held at its record hold, its delivery queued.
        let firstDelivery = WatermarkGate(), secondFrame = WatermarkGate()
        let deliveries = PassHoldCounter(), frames = PassHoldCounter()
        let seenAtSecondDelivery = PassDeliverySnapshot()
        await keeper.installHolds { point in
            switch point {
            case .legacyDelivery:
                let n = await deliveries.next()
                if n == 1 { await firstDelivery.enterAndWait() }
                if n == 2 { await seenAtSecondDelivery.set(await transport.log) }
            case .turnRecord:
                if await frames.next() == 2 { await secondFrame.enterAndWait() }
            default:
                break
            }
        }
        let leave = Task { try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1) }
        await firstDelivery.waitUntilEntered()
        let action = Task {
            try await keeper.handleActionEnvelope(plainAction("plain"), playerID: p2, clientID: c2, sessionID: s2)
        }
        await secondFrame.waitUntilEntered()
        #expect(await keeper.currentState().log.suffix(2) == ["leave:p1", "plain"])
        #expect(await transport.log.count == base, "a pass delivered while the earlier pass's delivery was held")
        firstDelivery.release()
        secondFrame.release()
        try await leave.value
        _ = try await action.value

        #expect(Array(await transport.log.dropFirst(base)) == ["broadcast", "event:leave:p1", "event:plain"])
        // Pass 2's delivery started only after pass 1's had sent everything.
        #expect(await seenAtSecondDelivery.value.map { Array($0.dropFirst(base)) } == ["broadcast", "event:leave:p1"])
    }

    @Test("OnInitialize with resolvers, a join and actions replay exactly; OnInitialize is outside the passes", arguments: [false, true])
    func initializeWithResolverStaysOutsidePasses(inTurn: Bool) async throws {
        let keeper = try await makePassKeeper(inTurn: inTurn, initializeWithResolver: true)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        _ = try await keeper.handleActionEnvelope(plainAction("a"), playerID: p1, clientID: c1, sessionID: s1)
        _ = try await keeper.handleActionEnvelope(plainAction("b"), playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.currentState().log == ["init", "join:p1", "a", "b"])

        let path = try await savePassRecord(keeper, name: "pass-init")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let initialize = try #require(try await source.getLifecycleEvents(for: 0).first { $0.kind == "initialize" })
        #expect(!(try await source.getPasses(for: 0)).flatMap(\.inputs).contains(initialize.sequence))

        let result = try await replayPassRecord(path, initializeWithResolver: true)
        #expect(result.initialize == .passed)
        #expect(result.recordedPassMismatches.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("Passes from several tick-0 turn records are concatenated in file order, and merged within one", arguments: [true, false])
    func passesConcatenateAcrossTurnRecords(endsTurn: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pass-concat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ReevaluationRecorder(spoolDirectory: directory)
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: passLandID, landType: "pass-order",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
            landDefinitionID: "pass-order", rngSeed: DeterministicSeed.fromLandID(passLandID),
            version: ReevaluationRecordVersion.current
        ))
        let passes = [
            ReevaluationRecordedPass(sequenceBefore: 4, inputs: [3]),
            ReevaluationRecordedPass(sequenceBefore: 6, inputs: [1, 5]),
            ReevaluationRecordedPass(sequenceBefore: 9, inputs: [8]),
        ]
        for pass in passes {
            await recorder.recordTick(ReevaluationTickRecord(tickId: 0, passes: [pass]), endsTurn: endsTurn)
        }
        let path = directory.appendingPathComponent("concat.sstr").path
        try await recorder.save(to: path)
        // Ending each turn writes three turn records (the reader concatenates them); without it
        // the recorder merges the calls into one.
        var turnPasses: [[ReevaluationRecordedPass]] = []
        try rewriteLog(from: path, to: path + ".copy") { record in
            if record.kind == .turn { turnPasses.append(record.passes ?? []) }
        }
        try? FileManager.default.removeItem(atPath: path + ".copy")
        #expect(turnPasses == (endsTurn ? passes.map { [$0] } : [passes]))
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        #expect(try await source.getPasses(for: 0) == passes)
        #expect(try await source.getMetadata().version == "3.1")
    }

    @Test("A 3.0 tickless record without passes still replays, in sequence order, ignoring sequences")
    func recordWithoutPassesReplaysAsBefore() async throws {
        let keeper = try await makePassKeeper(inTurn: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        for tag in ["a", "b", "c"] {
            _ = try await keeper.handleActionEnvelope(plainAction(tag), playerID: p1, clientID: c1, sessionID: s1)
        }
        let path = try await savePassRecord(keeper, name: "pass-old")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let oldPath = path + ".3.0.sstr"
        defer { try? FileManager.default.removeItem(atPath: oldPath) }
        try writeAsThreeZero(from: path, to: oldPath)

        let source = try ReevaluationRecordFile.openSource(filePath: oldPath)
        #expect(try await source.getMetadata().version == "3.0")
        #expect(try await source.getPasses(for: 0).isEmpty)
        let result = try await replayPassRecord(oldPath)
        #expect(result.watermarkedTicks.isEmpty)
        #expect(result.recordedPassMismatches.isEmpty)
        #expect(result.serverEventVerification == .passedIgnoringSequence(ticks: [0]))
    }

    @Test("The JSON view keeps a 3.1 record's passes; a 2.x JSON tickless record replays ignoring sequences")
    func jsonRecordsReplay() async throws {
        let keeper = try await makePassKeeper(inTurn: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        for tag in ["a", "b", "c"] {
            _ = try await keeper.handleActionEnvelope(plainAction(tag), playerID: p1, clientID: c1, sessionID: s1)
        }
        let path = try await savePassRecord(keeper, name: "pass-json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let livePasses = try await ReevaluationRecordFile.openSource(filePath: path).getPasses(for: 0)
        try #require(!livePasses.isEmpty)

        // The JSON view of the 3.1 record keeps its passes and replays exactly.
        let jsonPath = path + ".json"
        defer { try? FileManager.default.removeItem(atPath: jsonPath) }
        try FileManager.default.copyItem(atPath: path, toPath: jsonPath)
        try ReevaluationRecordFile.convertToJSONViewForTesting(atPath: jsonPath)
        let json = try ReevaluationRecordFile.openSource(filePath: jsonPath)
        #expect(json is JSONReevaluationSource)
        #expect(try await json.getPasses(for: 0) == livePasses)
        #expect(try await replayPassRecord(jsonPath).serverEventVerification == .passed)

        // The same frames as a 2.6 writer wrote them: no passes, version 2.6.
        let oldPath = path + ".2.6.json"
        defer { try? FileManager.default.removeItem(atPath: oldPath) }
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jsonPath))) as? [String: Any])
        var metadata = try #require(object["recordMetadata"] as? [String: Any])
        metadata["version"] = "2.6"
        object["recordMetadata"] = metadata
        let frames = try #require(object["tickFrames"] as? [[String: Any]])
        object["tickFrames"] = frames.map { frame in frame.filter { $0.key != "passes" } }
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: oldPath))
        let old = try ReevaluationRecordFile.openSource(filePath: oldPath)
        #expect(try await old.getPasses(for: 0).isEmpty)
        let result = try await replayPassRecord(oldPath)
        #expect(result.watermarkedTicks.isEmpty)
        #expect(result.serverEventVerification == .passedIgnoringSequence(ticks: [0]))
    }

    @Test("Passes that don't match the tick's inputs fail the tick with a reason", arguments: [
        "missing", "unknown", "duplicate", "decreasing", "duplicate-input", "unready",
    ])
    func mismatchedPassesFailTheTick(kind: String) async throws {
        let keeper = try await makePassKeeper(inTurn: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        for tag in ["a", "b"] {
            _ = try await keeper.handleActionEnvelope(plainAction(tag), playerID: p1, clientID: c1, sessionID: s1)
        }
        let path = try await savePassRecord(keeper, name: "pass-bad")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let badPath = path + ".bad.sstr"
        defer { try? FileManager.default.removeItem(atPath: badPath) }
        // Edit one record: since #327 every pass is its own turn record.
        var edited = false
        try rewriteLog(from: path, to: badPath) { record in
            guard !edited, let passes = record.passes, !passes.isEmpty else { return }
            if kind == "duplicate-input" || kind == "unready" {
                // An action's record: two inputs with one sequence, or one resolving after the tick.
                guard var actions = record.actions, let first = actions.first else { return }
                edited = true
                if kind == "duplicate-input" {
                    actions.append(first)
                } else {
                    actions[0] = ReevaluationRecordedAction(
                        kind: first.kind, sequence: first.sequence, typeIdentifier: first.typeIdentifier,
                        payload: first.payload, playerID: first.playerID, clientID: first.clientID,
                        sessionID: first.sessionID, resolverOutputs: first.resolverOutputs, resolvedAtTick: 1
                    )
                }
                record.actions = actions
                return
            }
            edited = true
            var all = passes
            switch kind {
            case "missing":
                all.removeLast()
            case "unknown":
                all.append(ReevaluationRecordedPass(sequenceBefore: 1_000, inputs: [999]))
            case "duplicate":
                all.append(ReevaluationRecordedPass(sequenceBefore: 1_000, inputs: all[0].inputs))
            default:
                all.append(ReevaluationRecordedPass(sequenceBefore: -1, inputs: []))
            }
            record.passes = all
        }
        let result = try await replayPassRecord(badPath)
        #expect(result.recordedPassMismatches.keys.sorted() == [0], "\(result.recordedPassMismatches)")
        #expect(result.serverEventVerification == .failed(ticks: [0]))

        // The check runs before any turn: the frame applies nothing, and nothing is left queued.
        let replay = try await makePassReplayKeeper(badPath, sink: PassReplaySink())
        await replay.stepTickOnce()
        #expect(await replay.currentState().log.isEmpty)
        #expect(await replay.pendingItemSequencesForTesting().isEmpty)
        #expect(await replay.takeRecordedPassMismatch(for: 0) != nil)

        // The hosted replay (admin route) reports it too: not a match, with the reason.
        let runner = try await ConcreteReevaluationRunner(definition: makePassDefinition(), recordFilePath: badPath)
        let step = try #require(try await runner.step())
        #expect(step.tickId == 0)
        #expect(step.recordedPassMismatch != nil)
        #expect(!step.isMatch)
    }

    @Test("Replaying a tickless frame of many one-input passes scans the queue a bounded number of times per input")
    func replayIsLinearInTheFrame() async throws {
        let keeper = try await makePassKeeper(inTurn: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let count = 2_000
        for index in 0..<count {
            _ = try await keeper.handleActionEnvelope(plainAction("a\(index)"), playerID: p1, clientID: c1, sessionID: s1)
        }
        let path = try await savePassRecord(keeper, name: "pass-linear")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #require(try await ReevaluationRecordFile.openSource(filePath: path).getPasses(for: 0).count == count + 1)

        // Work, not time: queue elements visited by whole-queue scans. Removing each pass's
        // input from the queue would visit about count² / 2 (two million); one index and one
        // removal visit about 2 × count.
        let replay = try await makePassReplayKeeper(path, sink: PassReplaySink())
        let before = await replay.pendingItemScansForTesting()
        await replay.stepTickOnce()
        let scans = await replay.pendingItemScansForTesting() - before
        #expect(await replay.currentState().log.count == count + 1)
        #expect(await replay.pendingItemSequencesForTesting().isEmpty)
        #expect(await replay.takeRecordedPassMismatch(for: 0) == nil)
        #expect(scans <= 4 * (count + 1), "\(scans) queue elements visited for \(count + 1) inputs")
    }

    @Test("Replay doesn't apply an input that left the queue across a pass's await")
    func replayRereadsAChangedQueue() async throws {
        let keeper = try await makePassKeeper(inTurn: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        for tag in ["a", "b"] {
            _ = try await keeper.handleActionEnvelope(plainAction(tag), playerID: p1, clientID: c1, sessionID: s1)
        }
        let path = try await savePassRecord(keeper, name: "pass-requeue")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let passes = try await ReevaluationRecordFile.openSource(filePath: path).getPasses(for: 0)
        try #require(passes.count == 3)
        let last = try #require(passes[2].inputs.first)

        // At the first pass's record hold, the last pass's input leaves the queue.
        let replay = try await makePassReplayKeeper(path, sink: PassReplaySink())
        let held = ManagedFlag()
        await replay.installHolds { point in
            if point == .turnRecord, held.setOnce() {
                await replay.removePendingItemForTesting(sequence: last)
            }
        }
        await replay.stepTickOnce()
        #expect(await replay.currentState().log == ["join:p1", "a"])
        #expect(await replay.takeRecordedPassMismatch(for: 0)?.contains("no longer queued") == true)
        #expect(await replay.pendingItemSequencesForTesting().isEmpty)
    }

    @Test("A tick land records no passes")
    func tickLandRecordsNoPasses() async throws {
        let definition = Land("pass-tick", using: PassOrderState.self) {
            ServerEvents { Register(PassLogged.self) }
            Rules {
                HandleAction(PassPlainAction.self) {
                    (state: inout PassOrderState, action: PassPlainAction, ctx: LandContext) in
                    appendEntry(action.tag, to: &state, ctx: ctx)
                    return PassAck(ok: true)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (_: inout PassOrderState, _: LandContext) in }
            }
        }
        let keeper = LandKeeper<PassOrderState>(definition: definition, initialState: PassOrderState(), enableLiveStateHashRecording: true, autoStartLoops: false)
        await keeper.setLandID("pass-tick:\(UUID().uuidString)")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        _ = try await keeper.handleActionEnvelope(plainAction("a"), playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await keeper.waitForRecorderSubmissionsForTesting()
        let frames = await recorder.getAllFrames()
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.passes.isEmpty })
    }
}

/// Log lengths seen at the replay's turn holds.
private actor PassLogLengths {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

/// Counts calls at one hold point (1 for the first).
private actor PassHoldCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// The transport log as one hold saw it.
private actor PassDeliverySnapshot {
    private(set) var value: [String]?
    func set(_ log: [String]) { value = log }
}

/// Sets once, from any thread.
private final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    /// True for the first caller only.
    func setOnce() -> Bool {
        lock.withLock {
            if set { return false }
            set = true
            return true
        }
    }
}

/// Rewrites a 3.x log record by record (`edit` may change each one), keeping the framing.
private func rewriteLog(
    from source: String,
    to destination: String,
    minor: UInt8? = nil,
    _ edit: (inout ReevaluationLogRecord) throws -> Void
) throws {
    let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: source)))
    var output = Array(bytes[0..<ReevaluationRecordLog.preamble.count])
    if let minor { output[5] = minor }
    var offset = ReevaluationRecordLog.preamble.count
    while offset + 4 <= bytes.count {
        let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        let start = offset + 4
        var record = try CanonicalMessagePack.decode(ReevaluationLogRecord.self, from: Array(bytes[start..<(start + length)]))
        try edit(&record)
        output += try ReevaluationRecordLog.framed(record)
        offset = start + length
    }
    try Data(output).write(to: URL(fileURLWithPath: destination))
}

/// The same record as a 3.0 writer would have written it: no passes, format and version 3.0.
private func writeAsThreeZero(from source: String, to destination: String) throws {
    try rewriteLog(from: source, to: destination, minor: 0) { record in
        record.passes = nil
        if record.kind == .header, let metadata = record.metadata {
            record.format = "3.0"
            var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
            object["version"] = "3.0"
            record.metadata = try JSONDecoder().decode(ReevaluationRecordMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
