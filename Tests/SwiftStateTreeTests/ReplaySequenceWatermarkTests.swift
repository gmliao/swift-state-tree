// Tests/SwiftStateTreeTests/ReplaySequenceWatermarkTests.swift
//
// Re-evaluation must reproduce server-event `sequence` values exactly.
// Live mode records two per-tick watermarks of the shared sequence counter
// (before inputs, before the tick handler); replay restores them.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test State, Payloads, Resolvers

@StateNodeBuilder
struct WatermarkTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    @Sync(.broadcast)
    var total: Int = 0

    /// Tick id at which each action executed, in execution order.
    @Sync(.broadcast)
    var actionTicks: [Int] = []

    public init() {}
}

@Payload
struct WatermarkEmitAction: ActionPayload {
    typealias Response = WatermarkAck
    let amount: Int
}

@Payload
struct WatermarkThrowingAction: ActionPayload {
    typealias Response = WatermarkAck
    let amount: Int
}

@Payload
struct WatermarkGatedAction: ActionPayload {
    typealias Response = WatermarkAck
    let amount: Int
}

@Payload
struct WatermarkAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct WatermarkActionEvent: ServerEventPayload {
    let amount: Int
}

@Payload
struct WatermarkTickEvent: ServerEventPayload {
    let tick: Int
}

@Payload
struct WatermarkJoinEvent: ServerEventPayload {
    let player: String
}

@Payload
struct WatermarkInitEvent: ServerEventPayload {
    let value: Int
}

struct WatermarkResolverFailure: Error {}

struct WatermarkResolverOutput: ResolverOutput {
    let value: Int
}

/// Resolver that always throws: the action has already taken a sequence number and is never recorded.
struct WatermarkThrowingResolver: ContextResolver {
    typealias Output = WatermarkResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> WatermarkResolverOutput {
        throw WatermarkResolverFailure()
    }
}

/// Test-controlled gate: the caller signals entry and then waits until the test releases it.
final class WatermarkGate: @unchecked Sendable {
    /// Gate used by `WatermarkGatedResolver` (resolvers are static, so the gate is shared).
    static let resolver = WatermarkGate()

    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            entered = true
            let waiters = enteredWaiters
            enteredWaiters = []
            return waiters
        }
        toResume.forEach { $0.resume() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                releaseWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if entered { return true }
                enteredWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            let waiters = releaseWaiters
            releaseWaiters = []
            return waiters
        }
        toResume.forEach { $0.resume() }
    }
}

/// Resolver that completes only when the test releases `WatermarkGate.resolver`.
struct WatermarkGatedResolver: ContextResolver {
    typealias Output = WatermarkResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> WatermarkResolverOutput {
        await WatermarkGate.resolver.enterAndWait()
        return WatermarkResolverOutput(value: 7)
    }
}

// MARK: - Land Definitions

private func makeWatermarkTestDefinition(
    emitOnInitialize: Bool = false,
    emitFromTickHandler: Bool = true
) -> LandDefinition<WatermarkTestState> {
    Land("watermark-test", using: WatermarkTestState.self) {
        ServerEvents {
            Register(WatermarkActionEvent.self)
            Register(WatermarkTickEvent.self)
            Register(WatermarkJoinEvent.self)
            Register(WatermarkInitEvent.self)
        }

        Rules {
            OnJoin { (_: inout WatermarkTestState, ctx: LandContext) in
                ctx.emitEvent(WatermarkJoinEvent(player: ctx.playerID.rawValue), to: .all)
            }

            HandleAction(WatermarkEmitAction.self) {
                (state: inout WatermarkTestState, action: WatermarkEmitAction, ctx: LandContext) in
                state.total += action.amount
                state.actionTicks.append(Int(ctx.tickId ?? -1))
                ctx.emitEvent(WatermarkActionEvent(amount: action.amount), to: .all)
                return WatermarkAck(ok: true)
            }

            HandleAction(WatermarkThrowingAction.self, resolvers: WatermarkThrowingResolver.self) {
                (state: inout WatermarkTestState, action: WatermarkThrowingAction, ctx: LandContext) in
                state.total += action.amount
                ctx.emitEvent(WatermarkActionEvent(amount: action.amount), to: .all)
                return WatermarkAck(ok: true)
            }

            HandleAction(WatermarkGatedAction.self, resolvers: WatermarkGatedResolver.self) {
                (state: inout WatermarkTestState, action: WatermarkGatedAction, ctx: LandContext) in
                state.total += action.amount
                state.actionTicks.append(Int(ctx.tickId ?? -1))
                ctx.emitEvent(WatermarkActionEvent(amount: action.amount), to: .all)
                return WatermarkAck(ok: true)
            }
        }

        Lifetime {
            OnInitialize { (_: inout WatermarkTestState, ctx: LandContext) in
                if emitOnInitialize {
                    ctx.emitEvent(WatermarkInitEvent(value: 1), to: .all)
                }
            }
            Tick(every: .seconds(3600)) { (state: inout WatermarkTestState, ctx: LandContext) in
                state.ticks += 1
                if emitFromTickHandler {
                    ctx.emitEvent(WatermarkTickEvent(tick: state.ticks), to: .all)
                }
            }
        }
    }
}

private func makeTicklessWatermarkDefinition() -> LandDefinition<WatermarkTestState> {
    Land("watermark-tickless-test", using: WatermarkTestState.self) {
        ServerEvents {
            Register(WatermarkActionEvent.self)
            Register(WatermarkJoinEvent.self)
        }
        Rules {
            HandleAction(WatermarkEmitAction.self) {
                (state: inout WatermarkTestState, action: WatermarkEmitAction, ctx: LandContext) in
                state.total += action.amount
                ctx.emitEvent(WatermarkActionEvent(amount: action.amount), to: .all)
                return WatermarkAck(ok: true)
            }
        }
    }
}

// MARK: - Helpers

private let watermarkLandID = "watermark-test:local"

private func watermarkMetadata(landType: String = "watermark-test") -> ReevaluationRecordMetadata {
    ReevaluationRecordMetadata(
        landID: watermarkLandID,
        landType: landType,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: landType,
        rngSeed: DeterministicSeed.fromLandID(watermarkLandID),
        version: ReevaluationRecordVersion.current
    )
}

private func tempRecordPath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("watermark-\(name)-\(UUID().uuidString).json")
        .path
}

/// Write a record file the same way `ReevaluationRecorder.save` does.
private func writeRecordFile(
    metadata: ReevaluationRecordMetadata,
    frames: [ReevaluationTickFrame],
    to path: String
) throws {
    struct RecordFile: Codable {
        let recordMetadata: ReevaluationRecordMetadata
        let tickFrames: [ReevaluationTickFrame]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(RecordFile(recordMetadata: metadata, tickFrames: frames))
    try data.write(to: URL(fileURLWithPath: path))
}

private func emitActionEnvelope(_ amount: Int) -> ActionEnvelope {
    ActionEnvelope(
        typeIdentifier: String(describing: WatermarkEmitAction.self),
        payload: AnyCodable(WatermarkEmitAction(amount: amount))
    )
}

private func recordedAction(sequence: Int64, amount: Int, resolvedAtTick: Int64) -> ReevaluationRecordedAction {
    ReevaluationRecordedAction(
        kind: "action",
        sequence: sequence,
        typeIdentifier: String(describing: WatermarkEmitAction.self),
        payload: AnyCodable(WatermarkEmitAction(amount: amount)),
        playerID: "p1",
        clientID: "c1",
        sessionID: "s1",
        resolverOutputs: [:],
        resolvedAtTick: resolvedAtTick
    )
}

/// Wire type name the runtime records for a server event (the "Event" suffix is dropped).
private func eventType(_ payload: some ServerEventPayload) -> String {
    AnyServerEvent(payload).type
}

private func recordedEvent(
    sequence: Int64,
    tickId: Int64,
    _ payload: some ServerEventPayload
) -> ReevaluationRecordedServerEvent {
    ReevaluationRecordedServerEvent(
        kind: "serverEvent",
        sequence: sequence,
        tickId: tickId,
        typeIdentifier: eventType(payload),
        payload: AnyCodable(payload),
        target: ReevaluationEventTargetRecord(kind: "all", ids: [])
    )
}

private actor CollectingSink: ReevaluationSink {
    private(set) var events: [ReevaluationRecordedServerEvent] = []

    func onEmittedServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) async {
        self.events.append(contentsOf: events)
    }
}

private actor RecordingTransport: LandKeeperTransport {
    private(set) var sent: [String] = []
    private let gate: WatermarkGate?
    private var gateArmed = false

    init(gate: WatermarkGate? = nil) {
        self.gate = gate
    }

    /// The next send suspends on `gate` until the test releases it.
    func armGate() {
        gateArmed = true
    }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        if gateArmed, let gate {
            gateArmed = false
            await gate.enterAndWait()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(event.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        sent.append("\(event.type):\(payload)")
    }

    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
}

private func makeLiveKeeper(
    definition: LandDefinition<WatermarkTestState>,
    recording: Bool = true,
    transport: LandKeeperTransport? = nil
) async -> LandKeeper<WatermarkTestState> {
    let keeper = LandKeeper<WatermarkTestState>(
        definition: definition,
        initialState: WatermarkTestState(),
        enableLiveStateHashRecording: recording,
        autoStartLoops: false,
        transport: transport
    )
    await keeper.setLandID(watermarkLandID)
    if let recorder = await keeper.getReevaluationRecorder() {
        await recorder.setMetadata(watermarkMetadata(landType: definition.id))
    }
    return keeper
}

private func serverEvents(in frames: [ReevaluationTickFrame]) -> [ReevaluationRecordedServerEvent] {
    frames.flatMap { $0.serverEvents }.sorted { $0.sequence < $1.sequence }
}

// MARK: - Tests

@Suite("Replay sequence watermark")
struct ReplaySequenceWatermarkTests {

    // Test 1
    @Test("Replay restores both watermarks: item-phase and tick-handler events get recorded sequences")
    func craftedWatermarksAreRestored() async throws {
        let frame = ReevaluationTickFrame(
            tickId: 0,
            actions: [recordedAction(sequence: 3, amount: 2, resolvedAtTick: -1)],
            clientEvents: [],
            lifecycleEvents: [],
            serverEvents: [],
            sequenceBeforeInputs: 10,
            sequenceBeforeTickHandler: 15
        )
        let source = JSONReevaluationSource(metadata: watermarkMetadata(), frames: [frame])
        let sink = CollectingSink()
        let keeper = LandKeeper<WatermarkTestState>(
            definition: makeWatermarkTestDefinition(),
            initialState: WatermarkTestState(),
            mode: .reevaluation,
            reevaluationSource: source,
            reevaluationSink: sink,
            autoStartLoops: false
        )
        await keeper.setLandID(watermarkLandID)

        await keeper.stepTickOnce()

        let events = await sink.events
        #expect(events.map(\.sequence) == [10, 15])
        #expect(events.map(\.typeIdentifier) == [
            eventType(WatermarkActionEvent(amount: 2)),
            eventType(WatermarkTickEvent(tick: 1)),
        ])
    }

    // Test 2
    @Test("Record and replay: action, join and tick-handler events match including sequence")
    func recordAndReplayMatchesSequences() async throws {
        let definition = makeWatermarkTestDefinition()
        let keeper = await makeLiveKeeper(definition: definition)
        let path = tempRecordPath("roundtrip")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        await keeper.stepTickOnce()
        for tick in 0..<6 {
            for n in 0..<(tick % 3) {
                _ = try await keeper.handleActionEnvelope(
                    emitActionEnvelope(tick * 10 + n),
                    playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
                )
            }
            if tick == 2 {
                try await keeper.join(playerID: PlayerID("p2"), clientID: ClientID("c2"), sessionID: SessionID("s2"))
            }
            await keeper.stepTickOnce()
        }

        let recorder = try #require(await keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        #expect(frames.allSatisfy { $0.sequenceBeforeInputs != nil && $0.sequenceBeforeTickHandler != nil })
        try await recorder.save(to: path)

        let sink = CollectingSink()
        let result = try await ReevaluationEngine.run(
            definition: definition,
            initialState: WatermarkTestState(),
            recordFilePath: path,
            sink: sink
        )

        #expect(result.serverEventMismatches.isEmpty)
        let replayed = await sink.events.sorted { $0.sequence < $1.sequence }
        let recorded = serverEvents(in: frames)
        #expect(!recorded.isEmpty)
        #expect(replayed.map(\.sequence) == recorded.map(\.sequence))
        #expect(replayed.map(\.tickId) == recorded.map(\.tickId))
        #expect(replayed.map(\.typeIdentifier) == recorded.map(\.typeIdentifier))
    }

    // Test 3
    @Test("A throwing resolver consumes a sequence number without being recorded; replay still matches")
    func throwingResolverStillMatches() async throws {
        let definition = makeWatermarkTestDefinition()
        let keeper = await makeLiveKeeper(definition: definition)
        let path = tempRecordPath("throwing")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        _ = try await keeper.handleActionEnvelope(
            emitActionEnvelope(1),
            playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
        )
        await keeper.stepTickOnce()

        let throwing = ActionEnvelope(
            typeIdentifier: String(describing: WatermarkThrowingAction.self),
            payload: AnyCodable(WatermarkThrowingAction(amount: 100))
        )
        do {
            _ = try await keeper.handleActionEnvelope(
                throwing,
                playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
            )
            Issue.record("Expected the resolver to throw")
        } catch let ResolverExecutionError.resolverFailed(_, underlyingError) {
            #expect(underlyingError is WatermarkResolverFailure)
        }

        _ = try await keeper.handleActionEnvelope(
            emitActionEnvelope(2),
            playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
        )
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()

        let recorder = try #require(await keeper.getReevaluationRecorder())
        try await recorder.save(to: path)

        // The failed action took exactly one number that appears nowhere in the record.
        let frames = await recorder.getAllFrames()
        let recordedSequences = Set(
            frames.flatMap { frame in
                frame.actions.map(\.sequence)
                    + frame.clientEvents.map(\.sequence)
                    + frame.lifecycleEvents.map(\.sequence)
                    + frame.serverEvents.map(\.sequence)
            }
        )
        let highest = try #require(recordedSequences.max())
        let gaps = (0...highest).filter { !recordedSequences.contains($0) }
        #expect(gaps.count == 1)

        let result = try await ReevaluationEngine.run(
            definition: definition,
            initialState: WatermarkTestState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes)
    }

    // Test 4
    @Test("A resolver that completes ticks after arrival: replay still matches")
    func lateResolverStillMatches() async throws {
        let definition = makeWatermarkTestDefinition()
        let keeper = await makeLiveKeeper(definition: definition)
        let path = tempRecordPath("late-resolver")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        await keeper.stepTickOnce()

        let gated = ActionEnvelope(
            typeIdentifier: String(describing: WatermarkGatedAction.self),
            payload: AnyCodable(WatermarkGatedAction(amount: 50))
        )
        let gatedTask = Task {
            try await keeper.handleActionEnvelope(
                gated,
                playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
            )
        }
        // The gated action has taken its sequence number once the resolver is entered.
        await WatermarkGate.resolver.waitUntilEntered()

        // Inputs arriving while the gated resolver is pending take later sequence numbers.
        _ = try await keeper.handleActionEnvelope(
            emitActionEnvelope(3),
            playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
        )
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()

        WatermarkGate.resolver.release()
        _ = try await gatedTask.value
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()

        let liveState = await keeper.currentState()
        #expect(liveState.total == 53)
        // The action that arrived after the gated one ran first; the gated one ran ticks later.
        #expect(liveState.actionTicks.count == 2)
        if liveState.actionTicks.count == 2 {
            #expect(liveState.actionTicks[1] > liveState.actionTicks[0])
        }

        let recorder = try #require(await keeper.getReevaluationRecorder())
        let actions = await recorder.getAllFrames().flatMap(\.actions)
        let gatedRecord = try #require(actions.first { $0.typeIdentifier == String(describing: WatermarkGatedAction.self) })
        let laterRecord = try #require(actions.first { $0.typeIdentifier == String(describing: WatermarkEmitAction.self) })
        // Numbered first, resolved later.
        #expect(gatedRecord.sequence < laterRecord.sequence)
        #expect(gatedRecord.resolvedAtTick > laterRecord.resolvedAtTick)
        try await recorder.save(to: path)

        let result = try await ReevaluationEngine.run(
            definition: definition,
            initialState: WatermarkTestState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes)
    }

    // Test 5
    @Test("Watermarks survive every recorder rebuild and the JSON round trip")
    func watermarksSurviveRecorderAndRoundTrip() async throws {
        let recorder = ReevaluationRecorder()
        await recorder.setMetadata(watermarkMetadata())
        let lifecycle = ReevaluationRecordedLifecycleEvent(
            kind: "join", sequence: 0, tickId: 4, playerID: "p1", clientID: "c1", sessionID: "s1",
            deviceID: nil, isGuest: nil, metadata: [:], resolverOutputs: [:], resolvedAtTick: 3
        )

        // Live order within one tick: inputs, state hash, server events, end-of-tick record.
        await recorder.record(tickId: 4, actions: [recordedAction(sequence: 1, amount: 1, resolvedAtTick: 3)], clientEvents: [], lifecycleEvents: [])
        await recorder.setStateHash(tickId: 4, stateHash: "abc")
        await recorder.recordServerEvents(tickId: 4, events: [recordedEvent(sequence: 2, tickId: 4, WatermarkTickEvent(tick: 1))])
        await recorder.record(
            tickId: 4, actions: [], clientEvents: [], lifecycleEvents: [],
            sequenceBeforeInputs: 1, sequenceBeforeTickHandler: 2
        )
        // Rebuilds after the watermarks were written must keep them.
        await recorder.recordLifecycleEvent(lifecycle)
        await recorder.setStateHash(tickId: 4, stateHash: "def")
        await recorder.recordServerEvents(tickId: 4, events: [recordedEvent(sequence: 2, tickId: 4, WatermarkTickEvent(tick: 1))])
        await recorder.record(tickId: 4, actions: [], clientEvents: [], lifecycleEvents: [])

        let frame = try #require(await recorder.getAllFrames().first)
        #expect(frame.sequenceBeforeInputs == 1)
        #expect(frame.sequenceBeforeTickHandler == 2)
        #expect(frame.stateHash == "def")
        #expect(frame.actions.count == 1)
        #expect(frame.lifecycleEvents.count == 1)

        let path = tempRecordPath("codable")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        #expect(raw.contains("\"sequenceBeforeInputs\""))
        #expect(raw.contains("\"sequenceBeforeTickHandler\""))

        let source = try JSONReevaluationSource(filePath: path)
        let watermarks = try await source.getSequenceWatermarks(for: 4)
        #expect(watermarks == ReevaluationSequenceWatermarks(beforeInputs: 1, beforeTickHandler: 2))
        #expect(try await source.getSequenceWatermarks(for: 5) == nil)
    }

    // Test 6
    @Test("Legacy recording without watermark fields decodes and replays with the old sequence drift")
    func legacyRecordingDecodesAndReplays() async throws {
        let definition = makeWatermarkTestDefinition()
        let keeper = await makeLiveKeeper(definition: definition)
        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        let recorder = try #require(await keeper.getReevaluationRecorder())

        // Strip the watermark keys to simulate a recording made before this change.
        let data = try await recorder.encode()
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var frames = try #require(json["tickFrames"] as? [[String: Any]])
        for i in frames.indices {
            frames[i].removeValue(forKey: "sequenceBeforeInputs")
            frames[i].removeValue(forKey: "sequenceBeforeTickHandler")
        }
        json["tickFrames"] = frames
        let path = tempRecordPath("legacy")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: path))

        let source = try JSONReevaluationSource(filePath: path)
        #expect(try await source.getSequenceWatermarks(for: 0) == nil)

        let result = try await ReevaluationEngine.run(
            definition: definition,
            initialState: WatermarkTestState(),
            recordFilePath: path
        )
        #expect(result.tickHashes == result.recordedStateHashes)
        // Without watermarks the counter is left alone: events differ in sequence only.
        #expect(!result.serverEventMismatches.isEmpty)
        for mismatch in result.serverEventMismatches {
            #expect(mismatch.expected.count == mismatch.actual.count)
            #expect(mismatch.expected.map(\.typeIdentifier) == mismatch.actual.map(\.typeIdentifier))
            #expect(mismatch.expected.map(\.sequence) != mismatch.actual.map(\.sequence))
        }
    }

    // Test 7
    @Test("A too-low watermark never moves the counter back; the extra event is reported")
    func tooLowWatermarkIsNotRewound() async throws {
        // Live (as recorded): the action emitted nothing and the tick handler emitted at 5.
        // Replay: the action emits, taking 5, so the counter (6) is above W2 (5).
        let frame = ReevaluationTickFrame(
            tickId: 0,
            stateHash: nil,
            actions: [recordedAction(sequence: 4, amount: 1, resolvedAtTick: -1)],
            clientEvents: [],
            lifecycleEvents: [],
            serverEvents: [recordedEvent(sequence: 5, tickId: 0, WatermarkTickEvent(tick: 1))],
            sequenceBeforeInputs: 5,
            sequenceBeforeTickHandler: 5
        )
        let path = tempRecordPath("too-low")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try writeRecordFile(metadata: watermarkMetadata(), frames: [frame], to: path)

        let result = try await ReevaluationEngine.run(
            definition: makeWatermarkTestDefinition(),
            initialState: WatermarkTestState(),
            recordFilePath: path
        )
        let mismatch = try #require(result.serverEventMismatches.first)
        #expect(result.serverEventMismatches.count == 1)
        #expect(mismatch.tickId == 0)
        #expect(mismatch.actual.map(\.sequence) == [5, 6])
        #expect(mismatch.actual.map(\.typeIdentifier) == [
            eventType(WatermarkActionEvent(amount: 1)),
            eventType(WatermarkTickEvent(tick: 1)),
        ])
    }

    // Test 8
    @Test("Extra replay event in a tick where live emitted nothing: reported for watermarked frames only")
    func extraEventInEmptyTick() async throws {
        let definition = makeWatermarkTestDefinition(emitFromTickHandler: false)
        func frame(watermarked: Bool) -> ReevaluationTickFrame {
            ReevaluationTickFrame(
                tickId: 0,
                stateHash: nil,
                actions: [recordedAction(sequence: 0, amount: 1, resolvedAtTick: -1)],
                clientEvents: [],
                lifecycleEvents: [],
                serverEvents: [],
                sequenceBeforeInputs: watermarked ? 1 : nil,
                sequenceBeforeTickHandler: watermarked ? 1 : nil
            )
        }

        let watermarkedPath = tempRecordPath("extra-watermarked")
        let legacyPath = tempRecordPath("extra-legacy")
        defer {
            try? FileManager.default.removeItem(atPath: watermarkedPath)
            try? FileManager.default.removeItem(atPath: legacyPath)
        }
        try writeRecordFile(metadata: watermarkMetadata(), frames: [frame(watermarked: true)], to: watermarkedPath)
        try writeRecordFile(metadata: watermarkMetadata(), frames: [frame(watermarked: false)], to: legacyPath)

        let watermarked = try await ReevaluationEngine.run(
            definition: definition, initialState: WatermarkTestState(), recordFilePath: watermarkedPath
        )
        #expect(watermarked.serverEventMismatches.count == 1)
        #expect(watermarked.serverEventMismatches.first?.expected.isEmpty == true)
        #expect(watermarked.serverEventMismatches.first?.actual.map(\.sequence) == [1])

        // Legacy frames keep the previous rule: an empty recorded list is not compared.
        let legacy = try await ReevaluationEngine.run(
            definition: definition, initialState: WatermarkTestState(), recordFilePath: legacyPath
        )
        #expect(legacy.serverEventMismatches.isEmpty)
    }

    // Test 9
    @Test("Recording on vs off: same sent event content and order, same action execution ticks")
    func liveBehaviourUnchangedByRecording() async throws {
        func run(recording: Bool) async throws -> (sent: [String], state: WatermarkTestState) {
            let transport = RecordingTransport()
            let keeper = await makeLiveKeeper(
                definition: makeWatermarkTestDefinition(),
                recording: recording,
                transport: transport
            )
            try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
            for tick in 0..<5 {
                for n in 0..<(tick % 2 + 1) {
                    _ = try await keeper.handleActionEnvelope(
                        emitActionEnvelope(tick * 10 + n),
                        playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
                    )
                }
                await keeper.stepTickOnce()
            }
            return (await transport.sent, await keeper.currentState())
        }

        let withRecording = try await run(recording: true)
        let withoutRecording = try await run(recording: false)
        #expect(!withRecording.sent.isEmpty)
        #expect(withRecording.sent == withoutRecording.sent)
        #expect(withRecording.state.actionTicks == withoutRecording.state.actionTicks)
        #expect(withRecording.state.total == withoutRecording.state.total)
    }

    // Test 9b
    @Test("An input that arrives while a live tick is suspended after its watermarks: replay still matches")
    func inputDuringTickSuspensionStillMatches() async throws {
        let definition = makeWatermarkTestDefinition()
        let gate = WatermarkGate()
        let transport = RecordingTransport(gate: gate)
        let keeper = await makeLiveKeeper(definition: definition, transport: transport)
        let path = tempRecordPath("mid-tick-input")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        await keeper.stepTickOnce()

        // Tick 1 suspends in its output flush (after the tick handler); an action arrives then.
        _ = try await keeper.handleActionEnvelope(
            emitActionEnvelope(1),
            playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
        )
        await transport.armGate()
        let suspendedTick = Task { await keeper.stepTickOnce() }
        await gate.waitUntilEntered()
        _ = try await keeper.handleActionEnvelope(
            emitActionEnvelope(2),
            playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
        )
        gate.release()
        await suspendedTick.value
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()

        let recorder = try #require(await keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        // The mid-tick action took its number after tick 1's W2, so its number lies between
        // tick 1's watermarks and tick 2's first watermark.
        let tick1 = try #require(frames.first { $0.tickId == 1 })
        let tick2 = try #require(frames.first { $0.tickId == 2 })
        let actionAmount: (ReevaluationRecordedAction) -> Int? = { record in
            guard let data = try? JSONEncoder().encode(record.payload) else { return nil }
            return (try? JSONDecoder().decode(WatermarkEmitAction.self, from: data))?.amount
        }
        let midTick = try #require(frames.flatMap(\.actions).first { actionAmount($0) == 2 })
        let tick1W2 = try #require(tick1.sequenceBeforeTickHandler)
        let tick2W1 = try #require(tick2.sequenceBeforeInputs)
        #expect(midTick.sequence > tick1W2)
        #expect(midTick.sequence < tick2W1)
        try await recorder.save(to: path)

        let sink = CollectingSink()
        let result = try await ReevaluationEngine.run(
            definition: definition,
            initialState: WatermarkTestState(),
            recordFilePath: path,
            sink: sink
        )
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes)
        let replayed = await sink.events.sorted { $0.sequence < $1.sequence }
        #expect(replayed.map(\.sequence) == serverEvents(in: frames).map(\.sequence))
    }

    // Test 10
    @Test("Tickless land: no watermarks are written")
    func ticklessLandWritesNoWatermarks() async throws {
        let keeper = await makeLiveKeeper(definition: makeTicklessWatermarkDefinition())
        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        _ = try await keeper.handleActionEnvelope(
            emitActionEnvelope(5),
            playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
        )
        await keeper.stepTickOnce()

        let state = await keeper.currentState()
        #expect(state.total == 5)
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.sequenceBeforeInputs == nil && $0.sequenceBeforeTickHandler == nil })
    }

    // Test 11 (pins current behaviour; the live-side OnInitialize gap is tracked in #66)
    @Test("OnInitialize emitting an event: replay runs it before tick 0 and checks it against the initialize record")
    func onInitializeEmitIsVerifiedBeforeTickZero() async throws {
        let definition = makeWatermarkTestDefinition(emitOnInitialize: true, emitFromTickHandler: false)
        let keeper = await makeLiveKeeper(definition: definition)
        let path = tempRecordPath("on-initialize")
        defer { try? FileManager.default.removeItem(atPath: path) }

        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        try await recorder.save(to: path)

        let result = try await ReevaluationEngine.run(
            definition: definition,
            initialState: WatermarkTestState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty, "the event belongs to tick -1, not tick 0")
        #expect(result.initialize == .passed)
        #expect(result.tickHashes == result.recordedStateHashes)
    }

    // MARK: Per-tick verification rule (shared by the engine and the GameDemo runner)

    private static let tickEvent = recordedEvent(sequence: 5, tickId: 0, WatermarkTickEvent(tick: 1))
    private static let renumbered = recordedEvent(sequence: 9, tickId: 0, WatermarkTickEvent(tick: 1))
    private static let otherPayload = recordedEvent(sequence: 5, tickId: 0, WatermarkTickEvent(tick: 2))

    @Test("Verdict: no mismatches passes")
    func verdictEmpty() {
        #expect(ReevaluationEngine.classifyServerEventMismatches([], watermarkedTicks: []) == .passed)
        #expect(ReevaluationEngine.classifyServerEventMismatches([], watermarkedTicks: [0, 1]) == .passed)
    }

    @Test("Verdict: every tick watermarked fails on a sequence-only mismatch")
    func verdictAllWatermarked() {
        let mismatches = [(tickId: Int64(0), expected: [Self.tickEvent], actual: [Self.renumbered])]
        #expect(ReevaluationEngine.classifyServerEventMismatches(mismatches, watermarkedTicks: [0]) == .failed(ticks: [0]))
    }

    @Test("Verdict: no tick watermarked passes sequence-only and fails content mismatches")
    func verdictNoneWatermarked() {
        let sequenceOnly = [(tickId: Int64(0), expected: [Self.tickEvent], actual: [Self.renumbered])]
        #expect(ReevaluationEngine.classifyServerEventMismatches(sequenceOnly, watermarkedTicks: []) == .passedIgnoringSequence(ticks: [0]))

        let content = [(tickId: Int64(0), expected: [Self.tickEvent], actual: [Self.otherPayload])]
        #expect(ReevaluationEngine.classifyServerEventMismatches(content, watermarkedTicks: []) == .failed(ticks: [0]))

        let count = [(tickId: Int64(0), expected: [Self.tickEvent], actual: [ReevaluationRecordedServerEvent]())]
        #expect(ReevaluationEngine.classifyServerEventMismatches(count, watermarkedTicks: []) == .failed(ticks: [0]))
    }

    @Test("Verdict: mixed record decides per tick, so one legacy frame does not disable strict ticks")
    func verdictMixed() {
        let mismatches = [
            (tickId: Int64(3), expected: [Self.tickEvent], actual: [Self.renumbered]),
            (tickId: Int64(7), expected: [Self.tickEvent], actual: [Self.renumbered]),
        ]
        // Tick 3 is legacy (sequence-only is tolerated), tick 7 is watermarked (must match exactly).
        #expect(ReevaluationEngine.classifyServerEventMismatches(mismatches, watermarkedTicks: [7]) == .failed(ticks: [7]))
        #expect(ReevaluationEngine.classifyServerEventMismatches(Array(mismatches.prefix(1)), watermarkedTicks: [7]) == .passedIgnoringSequence(ticks: [3]))
    }

    @Test("Empty record: nothing to compare, verification passes")
    func emptyRecordPasses() async throws {
        let path = tempRecordPath("empty")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try writeRecordFile(metadata: watermarkMetadata(), frames: [], to: path)

        let result = try await ReevaluationEngine.run(
            definition: makeWatermarkTestDefinition(),
            initialState: WatermarkTestState(),
            recordFilePath: path
        )
        #expect(result.maxTickId == -1)
        #expect(result.watermarkedTicks.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("A frame with only one watermark field counts as watermarked; the missing point is not restored")
    func singleWatermarkField() async throws {
        // Only W1 recorded: replay restores 10 before inputs, the tick handler then takes 11.
        let frame = ReevaluationTickFrame(
            tickId: 0,
            actions: [recordedAction(sequence: 3, amount: 2, resolvedAtTick: -1)],
            clientEvents: [],
            lifecycleEvents: [],
            serverEvents: [
                recordedEvent(sequence: 10, tickId: 0, WatermarkActionEvent(amount: 2)),
                recordedEvent(sequence: 11, tickId: 0, WatermarkTickEvent(tick: 1)),
            ],
            sequenceBeforeInputs: 10,
            sequenceBeforeTickHandler: nil
        )
        #expect(frame.sequenceWatermarks == ReevaluationSequenceWatermarks(beforeInputs: 10, beforeTickHandler: nil))
        let path = tempRecordPath("one-field")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try writeRecordFile(metadata: watermarkMetadata(), frames: [frame], to: path)

        let result = try await ReevaluationEngine.run(
            definition: makeWatermarkTestDefinition(),
            initialState: WatermarkTestState(),
            recordFilePath: path
        )
        #expect(result.watermarkedTicks == [0])
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }
}
