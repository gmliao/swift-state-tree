import Foundation
import Testing
@testable import SwiftStateTree

// Record format 3.0 (#245) on a live keeper: typed payloads through the strict MessagePack
// decoder, and the frames against the 2.6 recorder's.

@StateNodeBuilder
struct RecordLogNumberState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Double = 0
    @Sync(.broadcast)
    var fraction: Float = 0
    @Sync(.broadcast)
    var count: Int = 0
    @Sync(.broadcast)
    var ticks: Int = 0
}

@Payload
struct RecordLogNumberAction: ActionPayload {
    typealias Response = RecordLogNumberResponse
    let amount: Double
    let fraction: Float
    let count: Int
}

@Payload
struct RecordLogNumberResponse: ResponsePayload {
    let total: Double
}

func makeRecordLogNumberLand() -> LandDefinition<RecordLogNumberState> {
    Land("record-log-numbers", using: RecordLogNumberState.self) {
        Rules {
            HandleAction(RecordLogNumberAction.self) { (state: inout RecordLogNumberState, action: RecordLogNumberAction, _: LandContext) in
                state.total += action.amount
                state.fraction += action.fraction
                state.count += action.count
                return RecordLogNumberResponse(total: state.total)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout RecordLogNumberState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
}

@Test("Integral Double, Float and Int payloads recorded as 3.0 replay to the live state hashes")
func numericPayloadsReplayFromThreeZero() async throws {
    let definition = makeRecordLogNumberLand()
    let landID = "record-log-numbers:local"
    let keeper = try await ReevaluationRecorder.$recordsLegacyFramesForTesting.withValue(true) {
        LandKeeper<RecordLogNumberState>(
            definition: definition,
            initialState: RecordLogNumberState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
    }
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID, landType: "record-log-numbers",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
        landDefinitionID: definition.id, rngSeed: DeterministicSeed.fromLandID(landID)
    ))
    await keeper.setLandID(landID)
    try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
    for (amount, fraction, count) in [(3.0, Float(0.5), 7), (2.0, Float(0.25), -1), (1.5, Float(1), 0)] {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: RecordLogNumberAction.self),
                payload: AnyCodable(RecordLogNumberAction(amount: amount, fraction: fraction, count: count))
            ),
            playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
        )
        await keeper.stepTickOnce()
    }
    await keeper.waitForRecorderSubmissionsForTesting()
    let live = await keeper.currentState()
    #expect(live.total == 6.5 && live.fraction == 1.75 && live.count == 6)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-log-numbers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("numbers.sstr").path
    let legacy = await recorder.legacyFramesForTesting()
    try await recorder.save(to: path)

    let source = try ReevaluationRecordFile.openSource(filePath: path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let frames = await (source as! ReevaluationRecordLogSource).getAllFrames()
    #expect(try encoder.encode(frames) == encoder.encode(legacy), "frames against the 2.6 recorder")

    let result = try await ReevaluationEngine.run(
        definition: definition,
        initialState: RecordLogNumberState(),
        recordFilePath: path
    )
    #expect(!result.recordedStateHashes.isEmpty)
    #expect(result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil } == result.recordedStateHashes)
    #expect(result.recordCompleteness == .complete)
    #expect(result.serverEventVerification == .passed)
}

@Payload
struct RecordLogNumberEvent: ServerEventPayload {
    let count: Int
}

@Test("A tickless land's record keeps every pass's server events")
func ticklessRecordKeepsEveryPassEvents() async throws {
    let definition = Land("record-log-tickless", using: RecordLogNumberState.self) {
        ServerEvents { Register(RecordLogNumberEvent.self) }
        Rules {
            HandleAction(RecordLogNumberAction.self) { (state: inout RecordLogNumberState, action: RecordLogNumberAction, ctx: LandContext) in
                state.count += action.count
                ctx.emitEvent(RecordLogNumberEvent(count: state.count), to: .all)
                return RecordLogNumberResponse(total: state.total)
            }
        }
    }
    let landID = "record-log-tickless:local"
    let keeper = await ReevaluationRecorder.$recordsLegacyFramesForTesting.withValue(true) {
        LandKeeper<RecordLogNumberState>(
            definition: definition,
            initialState: RecordLogNumberState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
    }
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID, landType: "record-log-tickless",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
        landDefinitionID: definition.id, rngSeed: DeterministicSeed.fromLandID(landID)
    ))
    await keeper.setLandID(landID)
    try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
    for count in 1...3 {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: RecordLogNumberAction.self),
                payload: AnyCodable(RecordLogNumberAction(amount: 0, fraction: 0, count: count))
            ),
            playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
        )
    }
    await keeper.waitForRecorderSubmissionsForTesting()

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-log-tickless-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("tickless.sstr").path
    try await recorder.save(to: path)
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    // Every pass's event is in tick 0.
    #expect(try await source.getServerEvents(for: 0).map(\.sequence) == [1, 3, 5])
    // Each action ran in its own pass (3.1, #321): the counter before it and its input.
    let actionSequences = try await source.getActions(for: 0).map(\.sequence)
    #expect(actionSequences == [0, 2, 4])
    let actionPasses = try await source.getPasses(for: 0).filter { pass in
        pass.inputs.allSatisfy(actionSequences.contains)
    }
    #expect(actionPasses == actionSequences.map { ReevaluationRecordedPass(sequenceBefore: $0 + 1, inputs: [$0]) })

    // Replay applies the passes in order and restores the counter before each, so the events
    // match exactly, sequences included (#268, #321).
    let result = try await ReevaluationEngine.run(
        definition: definition,
        initialState: RecordLogNumberState(),
        recordFilePath: path
    )
    #expect(result.maxTickId == 0)
    #expect(result.watermarkedTicks == [0])
    #expect(result.recordedPassMismatches.isEmpty)
    #expect(result.serverEventVerification == .passed)
}

@Test("A tick land's replay still matches its server events exactly, sequences included")
func tickLandReplayKeepsExactServerEvents() async throws {
    let definition = Land("record-log-tick-events", using: RecordLogNumberState.self) {
        ServerEvents { Register(RecordLogNumberEvent.self) }
        Rules {
            HandleAction(RecordLogNumberAction.self) { (state: inout RecordLogNumberState, action: RecordLogNumberAction, ctx: LandContext) in
                state.count += action.count
                ctx.emitEvent(RecordLogNumberEvent(count: state.count), to: .all)
                return RecordLogNumberResponse(total: state.total)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout RecordLogNumberState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(RecordLogNumberEvent(count: -state.ticks), to: .all)
            }
        }
    }
    let landID = "record-log-tick-events:local"
    let keeper = LandKeeper<RecordLogNumberState>(
        definition: definition,
        initialState: RecordLogNumberState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID, landType: "record-log-tick-events",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
        landDefinitionID: definition.id, rngSeed: DeterministicSeed.fromLandID(landID)
    ))
    await keeper.setLandID(landID)
    try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
    // Two actions in the first tick, one in the second, none in the third.
    for actions in [[1, 2], [3], []] {
        for count in actions {
            _ = try await keeper.handleActionEnvelope(
                ActionEnvelope(
                    typeIdentifier: String(describing: RecordLogNumberAction.self),
                    payload: AnyCodable(RecordLogNumberAction(amount: 0, fraction: 0, count: count))
                ),
                playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
            )
        }
        await keeper.stepTickOnce()
    }
    await keeper.waitForRecorderSubmissionsForTesting()

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-log-tick-events-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("tick-events.sstr").path
    try await recorder.save(to: path)

    let result = try await ReevaluationEngine.run(
        definition: definition,
        initialState: RecordLogNumberState(),
        recordFilePath: path
    )
    #expect(result.maxTickId == 2)
    #expect(result.recordedStateHashes.count == 3)
    #expect(result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil } == result.recordedStateHashes)
    #expect(result.serverEventVerification == .passed)
}

@Test("A tickless replay that emits an event the record doesn't have fails")
func ticklessReplayExtraEventFails() async throws {
    // Live: the handler emits nothing, so the record holds no server events at all.
    let silent = Land("record-log-tickless-extra", using: RecordLogNumberState.self) {
        ServerEvents { Register(RecordLogNumberEvent.self) }
        Rules {
            HandleAction(RecordLogNumberAction.self) { (state: inout RecordLogNumberState, action: RecordLogNumberAction, _: LandContext) in
                state.count += action.count
                return RecordLogNumberResponse(total: state.total)
            }
        }
    }
    // Replay: the same land, whose handler now emits an event.
    let emitting = Land("record-log-tickless-extra", using: RecordLogNumberState.self) {
        ServerEvents { Register(RecordLogNumberEvent.self) }
        Rules {
            HandleAction(RecordLogNumberAction.self) { (state: inout RecordLogNumberState, action: RecordLogNumberAction, ctx: LandContext) in
                state.count += action.count
                ctx.emitEvent(RecordLogNumberEvent(count: state.count), to: .all)
                return RecordLogNumberResponse(total: state.total)
            }
        }
    }
    let landID = "record-log-tickless-extra:local"
    let keeper = LandKeeper<RecordLogNumberState>(
        definition: silent,
        initialState: RecordLogNumberState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID, landType: "record-log-tickless-extra",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
        landDefinitionID: silent.id, rngSeed: DeterministicSeed.fromLandID(landID)
    ))
    await keeper.setLandID(landID)
    try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
    _ = try await keeper.handleActionEnvelope(
        ActionEnvelope(
            typeIdentifier: String(describing: RecordLogNumberAction.self),
            payload: AnyCodable(RecordLogNumberAction(amount: 0, fraction: 0, count: 1))
        ),
        playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
    )
    await keeper.waitForRecorderSubmissionsForTesting()

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-log-tickless-extra-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("tickless-extra.sstr").path
    try await recorder.save(to: path)
    #expect(try await ReevaluationRecordFile.openSource(filePath: path).getServerEvents(for: 0).isEmpty)

    // The unchanged land replays with nothing to differ: the empty lists are compared and equal.
    let same = try await ReevaluationEngine.run(definition: silent, initialState: RecordLogNumberState(), recordFilePath: path)
    #expect(same.serverEventVerification == .passed)
    #expect(same.serverEventMismatches.isEmpty)
    // The changed land emits an event the record doesn't have: a content mismatch, not a pass.
    let changed = try await ReevaluationEngine.run(definition: emitting, initialState: RecordLogNumberState(), recordFilePath: path)
    #expect(changed.serverEventVerification == .failed(ticks: [0]))
}
