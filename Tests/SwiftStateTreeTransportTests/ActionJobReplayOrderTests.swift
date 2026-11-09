// Tests/SwiftStateTreeTransportTests/ActionJobReplayOrderTests.swift
//
// The property the action completion queue relies on: the server's processing order can be
// reconstructed from the record. An action with resolvers is bound to the tick of its
// completion (`resolvedAtTick`), and replay applies inputs by `(resolvedAtTick, sequence)`.
// Here a resolver-free action overtakes an earlier action whose resolver is held (gates, not
// timing), the held one completes a tick later, and the record replays to the live state,
// with in-turn sync on and off. The land's state is an ordered list, so a replay that applied
// the two in sequence order would end in a different state.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct ReplayOrderJobState: StateNodeProtocol {
    /// The applied actions' values, in apply order.
    @Sync(.broadcast)
    var applied: [Int] = []
}

@Payload
struct ReplayOrderAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct ReplayOrderHeldAction: ActionPayload {
    typealias Response = ReplayOrderAck
    /// Also the key of the resolver's gate (`ReplayOrderGates`).
    let key: Int
}

@Payload
struct ReplayOrderPlainAction: ActionPayload {
    typealias Response = ReplayOrderAck
    let value: Int
}

struct ReplayOrderOutput: ResolverOutput {
    let value: Int
}

/// A gate the resolver arrives at and waits on until it's opened; the test awaits the arrival on
/// a continuation, not a poll.
final class ReplayOrderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    private var isOpen = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            arrived = true
            defer { arrivalWaiters = [] }
            return arrivalWaiters
        }
        toResume.forEach { $0.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard !isOpen else { return true }
                openWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func waitUntilArrived() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard !arrived else { return true }
                arrivalWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { openWaiters = [] }
            return openWaiters
        }
        toResume.forEach { $0.resume() }
    }
}

/// One gate per action key: resolvers are static, and parallel tests must not share a gate.
/// Keys come only from `freshKey()`, never a literal.
private enum ReplayOrderGates {
    private static let keys = KeyedGates(firstKey: 4_000) { ReplayOrderGate() }
    static func freshKey() -> Int { keys.freshKey() }
    static func gate(_ key: Int, sourceLocation: SourceLocation = #_sourceLocation) -> ReplayOrderGate { keys.gate(key, sourceLocation: sourceLocation) }
}

/// Live: waits at its gate. Replay never runs resolvers: it reads the recorded output.
struct ReplayOrderHeldResolver: ContextResolver {
    typealias Output = ReplayOrderOutput

    static func resolve(ctx: ResolverContext) async throws -> ReplayOrderOutput {
        let key = (ctx.actionPayload as? ReplayOrderHeldAction)?.key ?? -1
        await ReplayOrderGates.gate(key).arrive()
        return ReplayOrderOutput(value: key)
    }
}

private func makeReplayOrderLand() -> LandDefinition<ReplayOrderJobState> {
    Land("action-job-replay-order", using: ReplayOrderJobState.self) {
        Rules {
            HandleAction(ReplayOrderHeldAction.self, resolvers: ReplayOrderHeldResolver.self) {
                (state: inout ReplayOrderJobState, action: ReplayOrderHeldAction, _: LandContext) in
                state.applied.append(action.key)
                return ReplayOrderAck(ok: true)
            }
            HandleAction(ReplayOrderPlainAction.self) {
                (state: inout ReplayOrderJobState, action: ReplayOrderPlainAction, _: LandContext) in
                state.applied.append(action.value)
                return ReplayOrderAck(ok: true)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout ReplayOrderJobState, _: LandContext) in }
        }
    }
}

/// Runs `work`, recording an issue if it doesn't finish within 10 s: a backstop against a broken
/// build hanging the run. The interleavings themselves are forced by gates.
private func bounded(
    _ step: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ work: @escaping @Sendable () async -> Void
) async -> Bool {
    switch await raceDeadline(.seconds(10), work) {
    case .finished: return true
    case .timedOut:
        Issue.record("Timed out: \(step)", sourceLocation: sourceLocation)
        return false
    }
}

/// Records nothing: the test reads the keeper's record, not the frames.
private actor ReplayOrderTransport: Transport {
    var delegate: TransportDelegate?
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {}
}

@Suite("Action jobs: the processing order is reconstructable from the record (tick lands)", .timeLimit(.minutes(1)))
struct ActionJobReplayOrderTests {
    @Test(
        "An action that a resolver-free action overtakes replays in its recorded (resolvedAtTick, sequence) order",
        arguments: [true, false]
    )
    func overtakenActionReplaysInRecordedOrder(inTurn: Bool) async throws {
        let landID = "action-job-replay-order:local"
        let keeper = LandKeeper<ReplayOrderJobState>(
            definition: makeReplayOrderLand(),
            initialState: ReplayOrderJobState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        await keeper.setLandID(landID)
        let transport = ReplayOrderTransport()
        let adapter = TransportAdapter<ReplayOrderJobState>(
            keeper: keeper, transport: transport, landID: landID, inTurnSync: inTurn
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        #expect(await keeper.isUsingInTurnSync() == (inTurn && InTurnSync.isEnabled()))
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: "action-job-replay-order",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            metadata: [:],
            landDefinitionID: "action-job-replay-order",
            rngSeed: DeterministicSeed.fromLandID(landID),
            recordsSyncStream: await keeper.recordsSyncStream,
            syncConfig: adapter.syncConfigForRecord
        ))

        let session = SessionID("s1"), client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"))
        await keeper.stepTickOnce()

        func send(_ requestID: String, _ action: some ActionPayload) async throws {
            let envelope = ActionEnvelope(typeIdentifier: String(describing: type(of: action)), payload: AnyCodable(action))
            let message = TransportMessage.action(requestID: requestID, action: envelope)
            await adapter.onMessage(try JSONEncoder().encode(message), from: session)
        }

        // A (resolvers, held) is taken first, so it has the lower sequence; B (no resolvers)
        // overtakes it and applies in the next tick.
        let a = ReplayOrderGates.freshKey(), b = 7
        try await send("A", ReplayOrderHeldAction(key: a))
        guard await bounded("A's resolver is held", { await ReplayOrderGates.gate(a).waitUntilArrived() }) else { return }
        try await send("B", ReplayOrderPlainAction(value: b))
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().applied == [b], "B applied while A's resolver is held")

        // A completes now, so it is bound to the tick after B's and applies in the next one.
        ReplayOrderGates.gate(a).open()
        guard await bounded("A's answer", { await adapter.waitForActionResponsesFinishedForTesting(1) }) else { return }
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().applied == [b, a], "live apply order: B, then A")
        _ = await adapter.waitForOutboundDrain()
        await keeper.waitForRecorderSubmissionsForTesting()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("action-job-replay-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("record.sstr").path
        try await recorder.save(to: path)

        // The record: A has the lower sequence but the later resolvedAtTick, and sorting the
        // recorded actions by (resolvedAtTick, sequence) gives the live apply order.
        let source = try #require(try ReevaluationRecordFile.openSource(filePath: path) as? ReevaluationRecordLogSource)
        let actions = await source.getAllFrames().flatMap(\.actions)
        let recordedA = try #require(actions.first { $0.typeIdentifier == String(describing: ReplayOrderHeldAction.self) })
        let recordedB = try #require(actions.first { $0.typeIdentifier == String(describing: ReplayOrderPlainAction.self) })
        #expect(recordedA.sequence < recordedB.sequence, "A was taken first")
        #expect(recordedA.resolvedAtTick > recordedB.resolvedAtTick, "A is bound to its completion tick, after B's")
        let replayOrder = actions.sorted { ($0.resolvedAtTick, $0.sequence) < ($1.resolvedAtTick, $1.sequence) }
        #expect(replayOrder.map(\.sequence) == [recordedB.sequence, recordedA.sequence])

        let result = try await ReevaluationEngine.run(
            definition: makeReplayOrderLand(),
            initialState: ReplayOrderJobState(),
            recordFilePath: path
        )
        #expect(result.recordCompleteness == .complete)
        #expect(!result.recordedStateHashes.isEmpty)
        #expect(result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil } == result.recordedStateHashes)
        #expect(result.serverEventVerification == .passed, "\(result.serverEventVerification)")
        await keeper.forceShutdown()
    }
}
