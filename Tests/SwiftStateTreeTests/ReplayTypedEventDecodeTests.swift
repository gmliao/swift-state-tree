// Tests/SwiftStateTreeTests/ReplayTypedEventDecodeTests.swift
//
// A recorded server event replays typed (#521 PR 1b, #538). The runner resolves each tick: every
// recorded event is looked up by name in the base land's registry and decoded with the record's
// own codec (`CanonicalMessagePack`), strictly for a saved record and with one numeric allowance
// for the JSON view. Inside the byte-identity domain the re-emitted event encodes to the live
// frame's bytes; outside it the differences are the stated ones. A server event type a replay
// can't decode is refused at registration for a land whose records replay (EV8).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor
@testable import SwiftStateTreeTransport

// MARK: - Fixtures

@StateNodeBuilder
struct ReplayEventDecodeState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

/// A server event with a field of every kind the domain names: the scalars, and the types that
/// go through their own `Codable` in the record.
@Payload
struct ReplayDomainEvent: ServerEventPayload, Equatable {
    let at: Date
    let blob: Data
    let link: URL
    let amount: Decimal
    let ratio: Double
    let whole: Double
    let small: Float
    let count: Int
    let largest: Int
    let flag: Bool
    let name: String
    let negativeZero: Double
}

@Payload
struct ReplayUnsignedEvent: ServerEventPayload, Equatable {
    let big: UInt64
}

/// A type that isn't a `ServerEventPayload`: given to the deprecated `ServerEventNode(type:)`.
struct ReplayNotAPayload: Codable, Sendable {
    let value: Int
}

private let replayDecodeLandID = "replay-decode:local"

func replayDomainEvent(at seconds: Double) -> ReplayDomainEvent {
    ReplayDomainEvent(
        at: Date(timeIntervalSince1970: seconds),
        blob: Data([0, 1, 2, 255]),
        link: URL(string: "https://example.com/a?b=c")!,
        amount: Decimal(string: "12.345")!,
        ratio: 2.5,
        whole: 3.0,
        small: 0.1,
        count: -7,
        largest: Int.max,
        flag: true,
        name: "näme",
        negativeZero: -0.0
    )
}

/// Each tick emits `event` to everyone.
private func makeReplayDecodeLand(emitting event: ReplayDomainEvent) -> LandDefinition<ReplayEventDecodeState> {
    Land("replay-decode", using: ReplayEventDecodeState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout ReplayEventDecodeState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(event, to: .all)
            }
        }
        ServerEvents {
            Register(ReplayDomainEvent.self)
        }
    }
}

/// The same land with a server event type a replay can't decode (EV8).
private func makeUndecodableEventLand() -> LandDefinition<ReplayEventDecodeState> {
    Land("replay-decode", using: ReplayEventDecodeState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout ReplayEventDecodeState, _: LandContext) in
                state.ticks += 1
            }
        }
        ServerEventNode(type: ReplayNotAPayload.self)
    }
}

/// Runs one tick of `definition` live with recording on and saves the record to `path`.
private func recordOneTick(_ definition: LandDefinition<ReplayEventDecodeState>, path: String) async throws {
    let keeper = LandKeeper<ReplayEventDecodeState>(
        definition: definition,
        initialState: ReplayEventDecodeState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.setLandID(replayDecodeLandID)
    await keeper.awaitInitialization()
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: replayDecodeLandID,
        landType: "replay-decode",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "replay-decode",
        rngSeed: await keeper.getRngSeed()
    ))
    await keeper.stepTickOnce()
    await keeper.waitForRecorderSubmissionsForTesting()
    try await recorder.save(to: path)
}

private func tempPath(_ ext: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("replay-decode-\(UUID().uuidString).\(ext)").path
}

/// The record formats a replay reads: a saved record, and its JSON view.
enum ReplayRecordForm: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case saved
    case jsonView
    var testDescription: String { rawValue }
}

/// Records one tick that emits `event`, and returns the path of the record in `form`.
private func recordedPath(emitting event: ReplayDomainEvent, form: ReplayRecordForm) async throws -> String {
    let saved = tempPath("sstr")
    try await recordOneTick(makeReplayDecodeLand(emitting: event), path: saved)
    guard form == .jsonView else { return saved }
    let json = tempPath("json")
    try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: saved)))
        .write(to: URL(fileURLWithPath: json))
    return json
}

/// The first tick's resolved frame from the stock runner.
private func firstFrame(path: String, definition: LandDefinition<ReplayEventDecodeState>) async throws -> ReevaluationReplayFrame {
    let runner = try await ConcreteReevaluationRunner(definition: definition, recordFilePath: path)
    let step = try #require(try await runner.step())
    return try #require(step.replayFrame)
}

/// The event's frame bytes in `config`, as the adapter's encoder writes them.
private func frameBytes(_ event: any ServerEventPayload, _ config: TransportEncodingConfig) throws -> Data {
    try config.makeMessageEncoder().encode(.event(event: .fromServer(event: AnyServerEvent(event))))
}

private let frameEncodings: [(String, TransportEncodingConfig)] = [
    ("json", .json), ("opcode", .opcode), ("messagepack", .messagepack),
]

// MARK: - Tests

@Suite("A recorded server event replays typed, decoded with the record's codec (#521 PR 1b)")
struct ReplayTypedEventDecodeTests {
    @Test("Inside the domain the replayed event equals the live one and encodes to the same frame bytes", arguments: ReplayRecordForm.allCases)
    func domainIsByteIdentical(form: ReplayRecordForm) async throws {
        let live = replayDomainEvent(at: 1_800_000_000)
        let path = try await recordedPath(emitting: live, form: form)
        let frame = try await firstFrame(path: path, definition: makeReplayDecodeLand(emitting: live))
        try #require(frame.recordedEvents.count == 1)
        let replayed = try #require(frame.recordedEvents[0].event as? ReplayDomainEvent)
        // The JSON view's one stated difference: `-0.0` reads back as the integer 0.
        let expected = form == .saved ? live : ReplayDomainEvent(
            at: live.at, blob: live.blob, link: live.link, amount: live.amount, ratio: live.ratio, whole: live.whole,
            small: live.small, count: live.count, largest: live.largest, flag: live.flag, name: live.name, negativeZero: 0.0
        )
        #expect(replayed == expected, "\(form)")
        #expect(replayed.negativeZero.sign == (form == .saved ? .minus : .plus), "\(form): -0.0 kept only by a saved record")
        for (name, config) in frameEncodings {
            #expect(try frameBytes(replayed, config) == frameBytes(expected, config), "\(form) \(name)")
        }
        // The projected event (the runner's own emit) holds the typed value.
        let projected = try #require(frame.projectedEvents.first?.event as? ReplayDomainEvent)
        #expect(projected == live, "\(form): projected")
    }

    @Test("A Date with a fractional second replays truncated to the second (the stated difference)", arguments: ReplayRecordForm.allCases)
    func fractionalDateIsTruncated(form: ReplayRecordForm) async throws {
        let live = replayDomainEvent(at: 1_800_000_000.5)
        let path = try await recordedPath(emitting: live, form: form)
        let frame = try await firstFrame(path: path, definition: makeReplayDecodeLand(emitting: live))
        let replayed = try #require(frame.recordedEvents.first?.event as? ReplayDomainEvent)
        #expect(replayed.at == Date(timeIntervalSince1970: 1_800_000_000), "\(form)")
    }

    @Test("The record source: strict for a saved record, one integer-to-float allowance for the JSON view")
    func recordSourceAllowance() throws {
        let tree = try JSONDecoder().decode(AnyCodable.self, from: Data(#"{"whole":3}"#.utf8))
        struct Whole: Codable { let whole: Double }
        #expect(throws: CanonicalMessagePackError.self) { try RecordPayloadSource(tree).decode(Whole.self) }
        #expect(try RecordPayloadSource(tree, integralFloats: true).decode(Whole.self).whole == 3.0)
        struct Small: Codable { let whole: Float }
        #expect(try RecordPayloadSource(tree, integralFloats: true).decode(Small.self).whole == 3.0)
        // An integer that doesn't convert exactly isn't allowed.
        let inexact = try JSONDecoder().decode(AnyCodable.self, from: Data(#"{"whole":9007199254740993}"#.utf8))
        #expect(throws: CanonicalMessagePackError.self) { try RecordPayloadSource(inexact, integralFloats: true).decode(Whole.self) }
    }

    @Test("A payload whose base is already the type is taken as is, without the record codec")
    func typedPayloadSkipsTheCodec() throws {
        // Year 10000 is outside the record codec's dates, so a round trip would throw.
        let event = ReplayDomainEvent(
            at: Date(timeIntervalSince1970: 253_402_300_800), blob: Data(), link: URL(string: "https://example.com")!,
            amount: 1, ratio: 1, whole: 1, small: 1, count: 1, largest: 1, flag: false, name: "", negativeZero: 0
        )
        #expect(throws: CanonicalMessagePackError.self) { try CanonicalMessagePack.encode(AnyCodable(event)) }
        #expect(try RecordPayloadSource(AnyCodable(event)).decode(ReplayDomainEvent.self) == event)
    }

    @Test("An unsigned value above Int.max: a saved record already can't be read; on the JSON view it fails the resolve (#628)")
    func unsignedAboveIntMax() throws {
        let big = ReplayUnsignedEvent(big: (1 << 63) + 1)
        #expect(throws: (any Error).self) {
            try CanonicalMessagePack.decode(AnyCodable.self, from: CanonicalMessagePack.encode(AnyCodable(big)))
        }
        // The JSON view's tree holds it as a Double, which the strict integer decode refuses.
        let tree = try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(big))
        let recorded = ReevaluationRecordedServerEvent(
            kind: "serverEvent", sequence: 1, tickId: 0, typeIdentifier: ReplayUnsignedEvent._payloadWireName,
            payload: tree, target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        let definition = Land("replay-unsigned", using: ReplayEventDecodeState.self) {
            Rules {}
            ServerEvents { Register(ReplayUnsignedEvent.self) }
        }
        let error = #expect(throws: ReevaluationReplayResolutionError.self) {
            try ReevaluationReplayFrame.resolve(
                tickId: 0, recordedServerEvents: [recorded], emittedServerEvents: [], actualState: nil,
                definition: definition, integralFloats: true
            )
        }
        guard case .eventDecode(0, 1, "ReplayUnsigned", _)? = error else {
            Issue.record("expected eventDecode, got \(String(describing: error))")
            return
        }
    }

    @Test("A recorded event whose name isn't registered fails the resolve (EV7)")
    func unregisteredEventFails() throws {
        let recorded = ReevaluationRecordedServerEvent(
            kind: "serverEvent", sequence: 4, tickId: 2, typeIdentifier: "Unknown",
            payload: AnyCodable(["hp": 3] as [String: Int]), target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        #expect(throws: ReevaluationReplayResolutionError.unregisteredEvent(tickId: 2, sequence: 4, name: "Unknown")) {
            try ReevaluationReplayFrame.resolve(
                tickId: 2, recordedServerEvents: [recorded], emittedServerEvents: [], actualState: nil,
                definition: makeReplayDecodeLand(emitting: replayDomainEvent(at: 0))
            )
        }
    }

    @Test("EV8: a server event type a replay can't decode is refused only for a land whose records replay")
    func ev8RefusesAtRegistration() throws {
        let definition = makeUndecodableEventLand()
        #expect(throws: Never.self) { try definition.validateForRegistration(context: .encodingIndependent) }
        let error = #expect(throws: LandRegistrationError.self) {
            try definition.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(error?.serverEventsWithoutDecoder.count == 1)
        #expect(error?.description.contains("ReplayNotAPayload") == true, "\(String(describing: error))")
        let decodable = makeReplayDecodeLand(emitting: replayDomainEvent(at: 0))
        #expect(throws: Never.self) {
            try decodable.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
    }

    @Test("At the runner and the engine the record's checks come first: a type EV8 would refuse already fails the fingerprint")
    func recordChecksComeFirst() async throws {
        // A record of another definition, replayed with one whose server event type isn't a
        // payload type: the record's checks refuse it before EV8. The fingerprint can't list a
        // type without @Payload (D15), so EV8 is a backstop past them.
        let other = tempPath("sstr")
        try await recordOneTick(makeReplayDecodeLand(emitting: replayDomainEvent(at: 0)), path: other)
        let runnerError = await #expect(throws: (any Error).self) {
            _ = try await ConcreteReevaluationRunner(definition: makeUndecodableEventLand(), recordFilePath: other)
        }
        #expect(!(runnerError is LandRegistrationError), "\(String(describing: runnerError))")
        #expect("\(String(describing: runnerError))".contains("ReplayNotAPayload"), "\(String(describing: runnerError))")
        let engineError = await #expect(throws: (any Error).self) {
            _ = try await ReevaluationEngine.run(definition: makeUndecodableEventLand(), initialState: ReplayEventDecodeState(), recordFilePath: other)
        }
        #expect(!(engineError is LandRegistrationError), "\(String(describing: engineError))")
        // A bad file is refused before any definition row.
        let missing = tempPath("sstr")
        let fileError = await #expect(throws: (any Error).self) {
            _ = try await ConcreteReevaluationRunner(definition: makeUndecodableEventLand(), recordFilePath: missing)
        }
        #expect(!(fileError is LandRegistrationError), "\(String(describing: fileError))")
    }

    @Test("A server event payload that doesn't encode is a mismatch in the replay comparison, not equal to another (A6)")
    func unencodablePayloadIsAMismatch() {
        // JSONEncoder refuses NaN: before A6 both sides compared as empty data, so equal.
        let event = ReevaluationRecordedServerEvent(
            kind: "serverEvent", sequence: 1, tickId: -1, typeIdentifier: "Unencodable",
            payload: AnyCodable(Double.nan), target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        let verification = ReevaluationEngine.verifyInitialize(
            record: ReevaluationRecordedInitialize(sequence: 0, serverEvents: [event], stateHash: nil),
            emitted: [event],
            state: ReplayEventDecodeState()
        )
        guard case .failed = verification else {
            Issue.record("expected a failed verification, got \(verification)")
            return
        }
    }

    @Test("A result's projector copy keeps every other field (M2)")
    func projectorCopyKeepsFields() throws {
        let snapshot = try JSONEncoder().encode(StateSnapshot(values: ["ticks": .int(1)]))
        let frame = try ReevaluationReplayFrame.resolve(
            tickId: 1, recordedServerEvents: [], emittedServerEvents: [],
            actualState: AnyCodable(String(decoding: snapshot, as: UTF8.self)),
            definition: makeReplayDecodeLand(emitting: replayDomainEvent(at: 0))
        )
        #expect(frame.state == nil, "a state that isn't StateFromSnapshotDecodable has no replay land, so no frame state")
        let result = ReevaluationStepResult(
            tickId: 1, stateHash: "a", recordedHash: "b", isMatch: false,
            recordedPassMismatch: "passes differ", replayFrame: frame
        )
        let copy = result.with(projectedFrame: ProjectedReplayFrame(tickID: 1, stateObject: [:]))
        #expect(copy.recordedPassMismatch == "passes differ")
        #expect(copy.replayFrame?.tickId == 1)
        #expect(copy.projectedFrame?.tickID == 1)
    }
}
