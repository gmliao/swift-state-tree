// Tests/SwiftStateTreeTests/ReplayRecordRangeTests.swift
//
// A record with a recorded integer no live run writes is refused when it is opened, and replay
// never reaches the arithmetic that would trap on it (#729, same class as #639 and #640).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

@StateNodeBuilder
struct RangeTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

@Payload
struct RangeTestEvent: ServerEventPayload {
    let value: Int
}

@Payload
struct RangeTestAction: ActionPayload {
    typealias Response = RangeTestAck
}

@Payload
struct RangeTestAck: ResponsePayload {
    let ok: Bool
}

private let rangeLandID = "range-test:local"

/// `quiet`: OnInitialize emits once and nothing else does, so a record near the top of the range replays.
private func makeRangeTestLand(quiet: Bool = false) -> LandDefinition<RangeTestState> {
    Land("range-test", using: RangeTestState.self) {
        ServerEvents {
            Register(RangeTestEvent.self)
        }
        Rules {
            HandleAction(RangeTestAction.self) { (_: inout RangeTestState, _: RangeTestAction, ctx: LandContext) in
                if !quiet { ctx.emitEvent(RangeTestEvent(value: -1), to: .all) }
                return RangeTestAck(ok: true)
            }
        }
        Lifetime {
            OnInitialize { (_: inout RangeTestState, ctx: LandContext) in
                ctx.emitEvent(RangeTestEvent(value: 0), to: .all)
            }
            Tick(every: .seconds(3600)) { (state: inout RangeTestState, ctx: LandContext) in
                state.ticks += 1
                if !quiet {
                    ctx.emitEvent(RangeTestEvent(value: state.ticks), to: .all)
                    ctx.emitEvent(RangeTestEvent(value: state.ticks), to: .all)
                }
            }
        }
    }
}

private struct RangeTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A live run of the land, recorded, as the 2.6 JSON view a record file holds.
private func recordedRun(quiet: Bool = false) async throws -> [String: Any] {
    let definition = makeRangeTestLand(quiet: quiet)
    let keeper = LandKeeper<RangeTestState>(
        definition: definition,
        initialState: RangeTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )
    await keeper.setLandID(rangeLandID)
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: rangeLandID, landType: definition.id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
        landDefinitionID: definition.id, rngSeed: DeterministicSeed.fromLandID(rangeLandID),
        version: ReevaluationRecordVersion.current,
        schemaFingerprint: try ReevaluationSchemaFingerprint.compute(for: definition)
    ))
    // Tick 0 has no input; tick 1 applies an action that emits, before its tick handler emits twice.
    try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
    await keeper.stepTickOnce()
    _ = try await keeper.handleActionEnvelope(
        ActionEnvelope(typeIdentifier: String(describing: RangeTestAction.self), payload: AnyCodable(RangeTestAction())),
        playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
    )
    await keeper.stepTickOnce()
    let data = try await recorder.encodeJSONViewForTesting()
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The recorded run as a JSON record file, after `mutate` changed its frames. The caller removes it.
private func mutatedRecordPath(quiet: Bool = false, mutating mutate: (inout [[String: Any]]) throws -> Void) async throws -> String {
    var record = try await recordedRun(quiet: quiet)
    var frames = try #require(record["tickFrames"] as? [[String: Any]])
    try mutate(&frames)
    record["tickFrames"] = frames
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("range-\(UUID().uuidString).json").path
    try JSONSerialization.data(withJSONObject: record).write(to: URL(fileURLWithPath: path))
    return path
}

/// Replays the recorded run after `mutate` changed its frames; the replay must end with `expected`.
/// A replay that finishes, ends with another error or traps the process is a failure.
private func expectRefusal(
    _ expected: ReevaluationRecordContentError,
    mutating mutate: (inout [[String: Any]]) throws -> Void
) async throws {
    let path = try await mutatedRecordPath(mutating: mutate)
    defer { try? FileManager.default.removeItem(atPath: path) }
    do {
        _ = try await ReevaluationEngine.run(
            definition: makeRangeTestLand(), initialState: RangeTestState(), recordFilePath: path
        )
    } catch let error as ReevaluationRecordContentError {
        guard error == expected else { throw RangeTestFailure("refused with \(error), expected \(expected)") }
        return
    }
    throw RangeTestFailure("the replay ended without refusing the record, expected \(expected)")
}

/// Sets the target of the first recorded server event of `frames[index]` (or of its initialize record).
private func setTarget(_ frames: inout [[String: Any]], frame index: Int, initialize: Bool, to target: [String: Any]) throws {
    if initialize {
        var record = try #require(frames[index]["initialize"] as? [String: Any], "no initialize record")
        var events = try #require(record["serverEvents"] as? [[String: Any]], "no initialize events")
        events[0]["target"] = target
        record["serverEvents"] = events
        frames[index]["initialize"] = record
    } else {
        var events = try #require(frames[index]["serverEvents"] as? [[String: Any]], "no server events in frame \(index)")
        events[0]["target"] = target
        frames[index]["serverEvents"] = events
    }
}

/// The land's record in the 3.x format, one `turn` per entry, closed by a complete footer.
private func logBytes(_ metadata: ReevaluationRecordMetadata, turns: [ReevaluationTickRecord]) throws -> [UInt8] {
    var header = ReevaluationLogRecord(kind: .header)
    header.metadata = metadata
    var bytes = ReevaluationRecordLog.preamble
    bytes += try ReevaluationRecordLog.framed(header)
    for turn in turns { bytes += try ReevaluationRecordLog.framed(.turn(turn)) }
    var footer = ReevaluationLogRecord(kind: .footer)
    footer.complete = true
    bytes += try ReevaluationRecordLog.framed(footer)
    return bytes
}

private let syncMetadata = ReevaluationRecordMetadata(
    landID: rangeLandID, landType: "range-test",
    createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
    recordsSyncStream: true,
    syncConfig: ReevaluationSyncConfig(mergedBroadcastFrame: false, fullSnapshot: false)
).stampedWithCurrentVersion()

private func syncOutput(afterPass: Int64?) -> ReevaluationRecordedSyncOutput {
    ReevaluationRecordedSyncOutput(
        index: 0, turnKind: .tick, observedTickId: 0, streamIndex: 0, sequence: 0,
        afterPass: afterPass, broadcastHash: 1
    )
}

/// One frame builder per recorded sequence field, each putting the value in that field alone.
private func sequenceFieldCases() -> [(name: String, frame: (Int64) -> ReevaluationTickFrame)] {
    [
        ("initialize sequence", { frame(initializeSequence: $0) }),
        ("sequenceBeforeInputs", { frame(sequenceBeforeInputs: $0) }),
        ("sequenceBeforeTickHandler", { frame(sequenceBeforeTickHandler: $0) }),
        ("pass sequenceBefore", { frame(passSequenceBefore: $0) }),
    ]
}

/// A 2.6 JSON record of `frames`.
private func jsonRecord(_ frames: [ReevaluationTickFrame]) throws -> Data {
    struct RecordFile: Codable {
        let recordMetadata: ReevaluationRecordMetadata
        let tickFrames: [ReevaluationTickFrame]
    }
    let metadata = ReevaluationRecordMetadata(
        landID: rangeLandID, landType: "range-test",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:], version: "2.6"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(RecordFile(recordMetadata: metadata, tickFrames: frames))
}

private func frame(
    initializeSequence: Int64? = nil,
    sequenceBeforeInputs: Int64? = nil,
    sequenceBeforeTickHandler: Int64? = nil,
    passSequenceBefore: Int64? = nil,
    outputAfterPass: Int64? = nil,
    markerAfterPass: Int64? = nil
) -> ReevaluationTickFrame {
    ReevaluationTickFrame(
        tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [],
        sequenceBeforeInputs: sequenceBeforeInputs,
        sequenceBeforeTickHandler: sequenceBeforeTickHandler,
        syncOutputs: outputAfterPass.map { [syncOutput(afterPass: $0)] } ?? [],
        syncMarkers: markerAfterPass.map {
            [ReevaluationRecordedSyncMarker(kind: .seed, playerID: "p1", observedTickId: 0, streamIndex: 1, sequence: 0, afterPass: $0)]
        } ?? [],
        initialize: initializeSequence.map { ReevaluationRecordedInitialize(sequence: $0, serverEvents: [], stateHash: nil) },
        passes: passSequenceBefore.map { [ReevaluationRecordedPass(sequenceBefore: $0, inputs: [], ordinal: 1)] } ?? []
    )
}

@Suite("ReplayRecordRangeTests", .timeLimit(.minutes(1)))
struct ReplayRecordRangeTests {
    // MARK: Exit tests: the replay of each malformed record ends in the refusal, not a trap (Linux)

    @Test("An initialize sequence of Int64.max is refused, not trapped at the next number (#729)")
    func initializeSequenceAtMaxDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            try await expectRefusal(.sequenceOutOfRange(Int64.max)) { frames in
                var initialize = try #require(frames[0]["initialize"] as? [String: Any], "the run recorded no initialize record")
                initialize["sequence"] = Int64.max
                frames[0]["initialize"] = initialize
            }
        }
    }

    @Test("A sequence watermark of Int64.max is refused, not trapped by the next number the replay takes (#729)")
    func watermarkAtMaxDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            try await expectRefusal(.sequenceOutOfRange(Int64.max)) { frames in
                let last = frames.count - 1
                try #require(frames[last]["sequenceBeforeTickHandler"] != nil, "the run recorded no watermark")
                frames[last]["sequenceBeforeTickHandler"] = Int64.max
            }
        }
    }

    @Test("A sync output that read after pass Int64.min is refused at open, not trapped when it is located (#729)")
    func afterPassAtMinDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let bytes = try logBytes(syncMetadata, turns: [
                ReevaluationTickRecord(tickId: 0, syncOutputs: [syncOutput(afterPass: Int64.min)])
            ])
            do {
                let source = try ReevaluationRecordFile.openSource(data: Data(bytes))
                // A source that opened is read as the runner reads it: the driver locates each entry.
                _ = SyncOutputReplayDriver<RangeTestState>(
                    metadata: try await source.getMetadata(), stream: try await source.getSyncStream(), tickless: true
                )
            } catch let error as ReevaluationRecordContentError {
                guard error == .afterPassOutOfRange(Int64.min) else { throw RangeTestFailure("refused with \(error)") }
                return
            }
            throw RangeTestFailure("the record was opened, expected \(ReevaluationRecordContentError.afterPassOutOfRange(Int64.min))")
        }
    }

    // MARK: A value inside the range can still leave too little room (#741 review)

    @Test("An initialize sequence of Int64.max - 1 ends the replay with a typed error at OnInitialize's first event, not a trap")
    func initializeSequenceNearMaxIsExhausted() async {
        await #expect(processExitsWith: .success) {
            try await expectRefusal(.sequenceExhausted) { frames in
                var initialize = try #require(frames[0]["initialize"] as? [String: Any], "the run recorded no initialize record")
                initialize["sequence"] = Int64.max - 1
                frames[0]["initialize"] = initialize
            }
        }
    }

    @Test("A watermark of Int64.max - 1 before a tick handler that emits twice ends the replay with a typed error, not a trap")
    func watermarkNearMaxIsExhaustedByTwoEmits() async {
        await #expect(processExitsWith: .success) {
            try await expectRefusal(.sequenceExhausted) { frames in
                try #require(frames[0]["sequenceBeforeTickHandler"] != nil, "the run recorded no watermark")
                frames[0]["sequenceBeforeTickHandler"] = Int64.max - 1
            }
        }
    }

    @Test("One emission in each of two phases after watermarks of Int64.max - 1 ends the replay with a typed error, not a trap")
    func watermarksNearMaxAreExhaustedByOneEmitPerPhase() async {
        await #expect(processExitsWith: .success) {
            try await expectRefusal(.sequenceExhausted) { frames in
                // The restore never moves the counter back: the action's emission takes the last number
                // below the bound, and the tick handler's watermark of the same value doesn't give it back.
                frames[1]["sequenceBeforeInputs"] = Int64.max - 1
                frames[1]["sequenceBeforeTickHandler"] = Int64.max - 1
            }
        }
    }

    // MARK: The binary source refuses a tick outside 0 ..< Int64.max (#727 left this unpinned)

    @Test("A 3.x record with a tick outside 0 ..< Int64.max is refused at open, naming the tick (#729)")
    func binarySourceRefusesOutOfRangeTick() throws {
        for tickId in [Int64.max, -1] {
            let bytes = try logBytes(syncMetadata, turns: [ReevaluationTickRecord(tickId: 0), ReevaluationTickRecord(tickId: tickId)])
            #expect(throws: ReevaluationRecordContentError.tickIdOutOfRange(tickId)) {
                _ = try ReevaluationRecordLogSource(bytes: bytes)
            }
            #expect(throws: ReevaluationRecordContentError.tickIdOutOfRange(tickId)) {
                _ = try ReevaluationRecordFile.openSource(data: Data(bytes))
            }
        }
    }

    @Test("A 3.x record whose last tick is Int64.max - 1 still opens (#729)")
    func binarySourceOpensTheLastWritableTick() async throws {
        let bytes = try logBytes(syncMetadata, turns: [ReevaluationTickRecord(tickId: 0), ReevaluationTickRecord(tickId: Int64.max - 1)])
        let source = try ReevaluationRecordLogSource(bytes: bytes)
        #expect(try await source.getMaxTickId() == Int64.max - 1)
    }

    // MARK: Every source refuses the values at open

    @Test("Each recorded sequence outside 0 ..< Int64.max is refused at open, in a JSON and a 3.x record (#729)")
    func sequencesOutOfRangeAreRefused() throws {
        let cases = sequenceFieldCases()
        for (name, make) in cases {
            for value in [Int64.max, -1, Int64.min] {
                #expect(throws: ReevaluationRecordContentError.sequenceOutOfRange(value), "\(name) \(value)") {
                    _ = try JSONReevaluationSource(data: jsonRecord([make(value)]))
                }
                let turn = ReevaluationTickRecord(
                    tickId: 0,
                    sequenceBeforeInputs: make(value).sequenceBeforeInputs,
                    sequenceBeforeTickHandler: make(value).sequenceBeforeTickHandler,
                    initialize: make(value).initialize,
                    passes: make(value).passes
                )
                #expect(throws: ReevaluationRecordContentError.sequenceOutOfRange(value), "3.x \(name) \(value)") {
                    _ = try ReevaluationRecordLogSource(bytes: try logBytes(syncMetadata, turns: [turn]))
                }
            }
        }
    }

    @Test("Each recorded afterPass below 0 is refused at open, on an output and on a seed marker (#729)")
    func afterPassBelowZeroIsRefused() throws {
        for value in [Int64.min, -1] {
            for make in [frame(outputAfterPass: value), frame(markerAfterPass: value)] {
                #expect(throws: ReevaluationRecordContentError.afterPassOutOfRange(value)) {
                    _ = try JSONReevaluationSource(data: jsonRecord([make]))
                }
                let turn = ReevaluationTickRecord(tickId: 0, syncOutputs: make.syncOutputs, syncMarkers: make.syncMarkers)
                #expect(throws: ReevaluationRecordContentError.afterPassOutOfRange(value)) {
                    _ = try ReevaluationRecordLogSource(bytes: try logBytes(syncMetadata, turns: [turn]))
                }
            }
        }
    }

    @Test("The lowest and the highest accepted sequence open for each of the four fields, in a JSON and a 3.x record (#729)")
    func acceptedSequenceEdgesOpen() async throws {
        for (name, make) in sequenceFieldCases() {
            for value in [Int64(0), Int64.max - 1] {
                _ = try JSONReevaluationSource(data: jsonRecord([make(value)]))
                let made = make(value)
                let turn = ReevaluationTickRecord(
                    tickId: 0, sequenceBeforeInputs: made.sequenceBeforeInputs,
                    sequenceBeforeTickHandler: made.sequenceBeforeTickHandler,
                    initialize: made.initialize, passes: made.passes
                )
                let log = try ReevaluationRecordLogSource(bytes: try logBytes(syncMetadata, turns: [turn]))
                #expect(try await log.getAllFrames().count == 1, "3.x \(name) \(value)")
            }
        }
    }

    @Test("The lowest and the highest accepted afterPass open on an output and on a seed marker, in a JSON and a 3.x record (#729)")
    func acceptedAfterPassEdgesOpen() async throws {
        for value in [Int64(0), Int64.max] {
            for made in [frame(outputAfterPass: value), frame(markerAfterPass: value)] {
                _ = try JSONReevaluationSource(data: jsonRecord([made]))
                let turn = ReevaluationTickRecord(tickId: 0, syncOutputs: made.syncOutputs, syncMarkers: made.syncMarkers)
                let log = try ReevaluationRecordLogSource(bytes: try logBytes(syncMetadata, turns: [turn]))
                #expect(try await log.getSyncStream().count == 1, "3.x afterPass \(value)")
            }
        }
    }

    @Test("A record at the lowest accepted sequences replays end to end")
    func lowestAcceptedSequencesReplay() async throws {
        let path = try await mutatedRecordPath(quiet: true) { frames in
            var initialize = try #require(frames[0]["initialize"] as? [String: Any], "no initialize record")
            initialize["sequence"] = Int64(0)
            frames[0]["initialize"] = initialize
            for index in frames.indices {
                frames[index]["sequenceBeforeInputs"] = Int64(0)
                frames[index]["sequenceBeforeTickHandler"] = Int64(0)
            }
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeRangeTestLand(quiet: true), initialState: RangeTestState(), recordFilePath: path
        )
        #expect(result.maxTickId == 1)
    }

    @Test("A record at the highest accepted initialize sequence that leaves room for OnInitialize replays end to end")
    func highestAcceptedInitializeSequenceReplays() async throws {
        // OnInitialize takes its own number, then one for its event: Int64.max - 2 leaves the counter at Int64.max.
        let path = try await mutatedRecordPath(quiet: true) { frames in
            var initialize = try #require(frames[0]["initialize"] as? [String: Any], "no initialize record")
            initialize["sequence"] = Int64.max - 2
            frames[0]["initialize"] = initialize
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeRangeTestLand(quiet: true), initialState: RangeTestState(), recordFilePath: path
        )
        #expect(result.maxTickId == 1)
    }

    // MARK: A malformed event target reports the typed error, not a mismatch (#729, from #727's review)

    private static var allWithIDs: [String: Any] { ["kind": "all", "ids": ["a"]] }

    @Test("The standalone engine refuses a malformed target of the initialize record with the typed error")
    func standaloneEngineRefusesMalformedInitializeTarget() async throws {
        try await expectRefusal(.malformedEventTarget(kind: "all", idCount: 1)) { frames in
            try setTarget(&frames, frame: 0, initialize: true, to: Self.allWithIDs)
        }
    }

    @Test("The standalone engine refuses a malformed target of a tick's server event with the typed error")
    func standaloneEngineRefusesMalformedTickTarget() async throws {
        try await expectRefusal(.malformedEventTarget(kind: "all", idCount: 1)) { frames in
            try setTarget(&frames, frame: 1, initialize: false, to: Self.allWithIDs)
        }
    }

    @Test("The hosted runner's OnInitialize check fails with the typed error for a malformed target")
    func hostedVerifyInitializeRefusesMalformedTarget() async throws {
        let path = try await mutatedRecordPath { frames in
            try setTarget(&frames, frame: 0, initialize: true, to: Self.allWithIDs)
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runner = try await ConcreteReevaluationRunner(
            definition: makeRangeTestLand(), initialState: RangeTestState(), recordFilePath: path
        )
        await #expect(throws: ReevaluationRecordContentError.malformedEventTarget(kind: "all", idCount: 1)) {
            try await runner.prepare()
        }
    }

    @Test("A second prepare() after the refusal throws it again, and step() does too (#741 review)")
    func retriedPrepareStillThrows() async throws {
        let path = try await mutatedRecordPath { frames in
            try setTarget(&frames, frame: 0, initialize: true, to: Self.allWithIDs)
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runner = try await ConcreteReevaluationRunner(
            definition: makeRangeTestLand(), initialState: RangeTestState(), recordFilePath: path
        )
        let refusal = ReevaluationRecordContentError.malformedEventTarget(kind: "all", idCount: 1)
        await #expect(throws: refusal) { try await runner.prepare() }
        await #expect(throws: refusal) { try await runner.prepare() }
        await #expect(throws: refusal) { _ = try await runner.step() }
    }

    @Test("The hosted runner ends with the typed error when the replay takes a sequence past Int64.max (#741 review)")
    func hostedRunnerEndsOnSequenceExhaustion() async throws {
        let atInitialize = try await mutatedRecordPath { frames in
            var initialize = try #require(frames[0]["initialize"] as? [String: Any])
            initialize["sequence"] = Int64.max - 1
            frames[0]["initialize"] = initialize
        }
        defer { try? FileManager.default.removeItem(atPath: atInitialize) }
        let initializeRunner = try await ConcreteReevaluationRunner(
            definition: makeRangeTestLand(), initialState: RangeTestState(), recordFilePath: atInitialize
        )
        await #expect(throws: ReevaluationRecordContentError.sequenceExhausted) { try await initializeRunner.prepare() }

        let atTick = try await mutatedRecordPath { frames in frames[0]["sequenceBeforeTickHandler"] = Int64.max - 1 }
        defer { try? FileManager.default.removeItem(atPath: atTick) }
        let tickRunner = try await ConcreteReevaluationRunner(
            definition: makeRangeTestLand(), initialState: RangeTestState(), recordFilePath: atTick
        )
        await #expect(throws: ReevaluationRecordContentError.sequenceExhausted) { _ = try await tickRunner.step() }
    }

    @Test("A well-formed recorded run still verifies its initialize record and tick events")
    func wellFormedRunStillPasses() async throws {
        let path = try await mutatedRecordPath { _ in }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeRangeTestLand(), initialState: RangeTestState(), recordFilePath: path
        )
        #expect(result.initialize == .passed)
        #expect(result.serverEventMismatches.isEmpty)
    }
}
