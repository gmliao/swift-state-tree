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
    let legacy = await recorder.legacyFramesForTesting()
    try await recorder.save(to: path)
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    // Every pass's event is in tick 0 (on the legacy path 2.6 kept only the last pass's).
    #expect(try await source.getServerEvents(for: 0).count == 3)
    // `flushOutputs` records each pass's events with `recordServerEvents` in both sync modes;
    // 2.6 replaced the tick's list on each call, so only the last pass's survived.
    #expect(legacy.first { $0.tickId == 0 }?.serverEvents.map(\.sequence) == [5], "2.6 kept the last pass only")
    #expect(try await source.getServerEvents(for: 0).map(\.sequence) == [1, 3, 5])

    // Replay applies the three passes' actions in tick 0 and emits their events (#268): the
    // same events, targets and order. A tickless frame carries no sequence watermarks, so the
    // replay can't restore the counter before each pass and numbers the events 0, 1, 2; the
    // verdict ignores the sequence on that tick, as for older records without watermarks.
    let result = try await ReevaluationEngine.run(
        definition: definition,
        initialState: RecordLogNumberState(),
        recordFilePath: path
    )
    #expect(result.maxTickId == 0)
    #expect(result.serverEventVerification == .passedIgnoringSequence(ticks: [0]))
    // The verdict already means every other field matched; only the numbering differs.
    #expect(result.serverEventMismatches.map { $0.actual.map(\.sequence) } == [[0, 1, 2]])
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
