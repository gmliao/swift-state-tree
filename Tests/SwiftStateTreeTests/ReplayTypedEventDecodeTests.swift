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
import SwiftStateTreeTestSupport

// MARK: - Fixtures

@StateNodeBuilder
struct ReplayEventDecodeState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

/// A server event with a field of every kind the domain names: the scalars, and `Data`, which goes
/// through its own `Codable` in the record. (`Date` and `URL` aren't plain data, so a payload
/// can't hold them.)
@Payload
struct ReplayDomainEvent: ServerEventPayload, Equatable {
    let blob: Data
    let ratio: Double
    let whole: Double
    let small: Float
    let count: Int
    let largest: Int
    let flag: Bool
    let name: String
    let negativeZero: Double
}

/// A value nested past the record codec's depth: a round trip through the codec throws.
@Payload
struct ReplayDeepEvent: ServerEventPayload, Equatable {
    let nest: Nest
}

@Payload
struct ReplayUnsignedEvent: ServerEventPayload, Equatable {
    let big: UInt64
}

/// A state whose tick sets a NaN: its hash can't be computed (#180).
@StateNodeBuilder
struct ReplayNaNState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast)
    var ratio: Double = 0

    public init() {}
}

/// A state a replay land can show: built back from its snapshot (A11).
@StateNodeBuilder
struct ReplayShownState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

/// A type that isn't a `ServerEventPayload`: registered through a descriptor built with the
/// public `AnyEventDescriptor` init, which has no decoder.
struct ReplayNotAPayload: Codable, Sendable {
    let value: Int
}

private let replayDecodeLandID = "replay-decode:local"

func replayDomainEvent() -> ReplayDomainEvent {
    ReplayDomainEvent(
        blob: Data([0, 1, 2, 255]),
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
            Tick(every: .seconds(3600)) { state, ctx in
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
            Tick(every: .seconds(3600)) { state, _ in
                state.ticks += 1
            }
        }
    }
    .replacingServerEventRegistry(undecodableServerEvents(ReplayNotAPayload.self))
}

/// A server event registry holding `type` through the public descriptor init: no decoder (EV8).
private func undecodableServerEvents(_ type: Any.Type) -> EventRegistry<AnyServerEvent> {
    EventRegistry(registered: [
        AnyEventDescriptor(type: type, eventName: EventRegistry<AnyServerEvent>.eventName(for: type), direction: .server)
    ])
}

/// Each tick sets `ratio` to NaN.
private func makeNaNLand() -> LandDefinition<ReplayNaNState> {
    Land("replay-decode", using: ReplayNaNState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { state, _ in
                state.ratio = .nan
            }
        }
    }
}

/// Each tick emits `event` to everyone.
private func makeUnsignedLand(emitting event: ReplayUnsignedEvent) -> LandDefinition<ReplayEventDecodeState> {
    Land("replay-decode", using: ReplayEventDecodeState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                ctx.emitEvent(event, to: .all)
            }
        }
        ServerEvents { Register(ReplayUnsignedEvent.self) }
    }
}

/// Runs one tick of `definition` live with recording on and saves the record to `path`.
private func recordOneTick<S: StateNodeProtocol>(_ definition: LandDefinition<S>, path: String) async throws {
    let keeper = LandKeeper<S>(
        definition: definition,
        initialState: S(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: replayDecodeLandID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
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

/// A service fed by one prebuilt runner.
private struct OneRunnerFactory: ReevaluationTargetFactory {
    let runner: any ReevaluationRunnerProtocol
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol { runner }
}

/// Runs `runner` through a service to its end; `replayLand` makes the service feed a replay land
/// of that state type.
private func runThroughService(
    _ runner: any ReevaluationRunnerProtocol,
    replayLand: (any StateNodeProtocol.Type)? = nil
) async -> ReevaluationRunnerService {
    let service = ReevaluationRunnerService(factory: OneRunnerFactory(runner: runner), projectorResolver: { _ in nil })
    if let replayLand { service.expectReplayLandState(replayLand) }
    service.startVerification(landType: "replay-decode", recordFilePath: "unused")
    await service.verificationTaskForTesting()?.value
    return service
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
        let live = replayDomainEvent()
        let path = try await recordedPath(emitting: live, form: form)
        let frame = try await firstFrame(path: path, definition: makeReplayDecodeLand(emitting: live))
        try #require(frame.recordedEvents.count == 1)
        let replayed = try #require(frame.recordedEvents[0].event as? ReplayDomainEvent)
        // The JSON view's one stated difference: `-0.0` reads back as the integer 0.
        let expected = form == .saved ? live : ReplayDomainEvent(
            blob: live.blob, ratio: live.ratio, whole: live.whole,
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
        // Nested past the record codec's depth, so a round trip would throw.
        let event = ReplayDeepEvent(nest: .nested(CanonicalMessagePack.maxDepth + 1))
        #expect(throws: CanonicalMessagePackError.self) { try CanonicalMessagePack.encode(AnyCodable(event)) }
        #expect(try RecordPayloadSource(AnyCodable(event)).decode(ReplayDeepEvent.self) == event)
    }

    @Test("An unsigned value above Int.max (#628): a saved record holding one can't be read; on the JSON view it fails the run at the runner (EV7)")
    func unsignedAboveIntMax() async throws {
        let big = (UInt64(1) << 63) + 1
        // The saved record: the recorder writes it; reading it back fails, as on main.
        let saved = tempPath("sstr")
        try await recordOneTick(makeUnsignedLand(emitting: ReplayUnsignedEvent(big: big)), path: saved)
        let readError = await #expect(throws: (any Error).self) {
            let runner = try await ConcreteReevaluationRunner(definition: makeUnsignedLand(emitting: ReplayUnsignedEvent(big: big)), recordFilePath: saved)
            _ = try await runner.step()
        }
        #expect("\(String(describing: readError))".contains("AnyCodable value cannot be decoded"), "\(String(describing: readError))")

        // The JSON view: no recorder writes one, so take a record of a small value and put the big
        // one in its place. Its tree holds the value as a Double, which the strict decode refuses.
        let small = UInt64(424_242)
        let smallRecord = tempPath("sstr")
        try await recordOneTick(makeUnsignedLand(emitting: ReplayUnsignedEvent(big: small)), path: smallRecord)
        let view = String(decoding: try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: smallRecord))), as: UTF8.self)
        try #require(view.components(separatedBy: "424242").count == 2, "one occurrence to replace")
        let json = tempPath("json")
        try Data(view.replacingOccurrences(of: "424242", with: String(big)).utf8).write(to: URL(fileURLWithPath: json))
        let runner = try await ConcreteReevaluationRunner(definition: makeUnsignedLand(emitting: ReplayUnsignedEvent(big: small)), recordFilePath: json)
        let error = await #expect(throws: ReevaluationReplayResolutionError.self) { _ = try await runner.step() }
        guard case .eventDecode(0, .recorded, _, "ReplayUnsigned", _)? = error else {
            Issue.record("expected eventDecode of the recorded ReplayUnsigned at tick 0, got \(String(describing: error))")
            return
        }
    }

    @Test("A recorded event whose name isn't registered fails the resolve (EV7)")
    func unregisteredEventFails() throws {
        let recorded = ReevaluationRecordedServerEvent(
            kind: "serverEvent", sequence: 4, tickId: 2, typeIdentifier: "Unknown",
            payload: AnyCodable(["hp": 3] as [String: Int]), target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        // The error names the tick being resolved (3), not the one the event claims (2).
        #expect(throws: ReevaluationReplayResolutionError.unregisteredEvent(tickId: 3, origin: .recorded, sequence: 4, name: "Unknown")) {
            try ReevaluationReplayFrame.resolve(
                tickId: 3, recordedServerEvents: [recorded], emittedServerEvents: [], actualState: nil,
                definition: makeReplayDecodeLand(emitting: replayDomainEvent())
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
        let decodable = makeReplayDecodeLand(emitting: replayDomainEvent())
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
        try await recordOneTick(makeReplayDecodeLand(emitting: replayDomainEvent()), path: other)
        let unlisted = SchemaFingerprintError.unbuildableType(String(describing: ReplayNotAPayload.self))
        await #expect(throws: unlisted) {
            _ = try await ConcreteReevaluationRunner(definition: makeUndecodableEventLand(), recordFilePath: other)
        }
        await #expect(throws: unlisted) {
            _ = try await ReevaluationEngine.run(definition: makeUndecodableEventLand(), initialState: ReplayEventDecodeState(), recordFilePath: other)
        }
        // A missing file is refused before any definition row, with the file's own error.
        let missing = tempPath("sstr")
        let fileError = await #expect(throws: CocoaError.self) {
            _ = try await ConcreteReevaluationRunner(definition: makeUndecodableEventLand(), recordFilePath: missing)
        }
        #expect(fileError?.code == .fileReadNoSuchFile, "\(String(describing: fileError))")
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

    @Test("A record read error at the runner fails the step with the tick and the read (A9); a tick the source has no hash for still passes",
          arguments: ["state hash", "server events"])
    func recordReadErrorFailsTheStep(read: String) async throws {
        let path = tempPath("sstr")
        try await recordOneTick(makeReplayDecodeLand(emitting: replayDomainEvent()), path: path)
        let runner = try await ConcreteReevaluationRunner(definition: makeReplayDecodeLand(emitting: replayDomainEvent()), recordFilePath: path)
        await runner.setFaultsForTesting(ReplayRunnerFaults(stateHashRead: read == "state hash", serverEventsRead: read == "server events"))
        let injected: ReplayRunnerFaults.Injected = read == "state hash" ? .stateHashRead : .serverEventsRead
        await #expect(throws: ReevaluationReplayResolutionError.recordRead(tickId: 0, read: read, error: "\(injected)")) {
            _ = try await runner.step()
        }
        let fresh = try await ConcreteReevaluationRunner(definition: makeReplayDecodeLand(emitting: replayDomainEvent()), recordFilePath: path)
        await fresh.setFaultsForTesting(ReplayRunnerFaults(stateHashRead: read == "state hash", serverEventsRead: read == "server events"))
        let service = await runThroughService(fresh)
        #expect(service.getStatus().phase == .failed)
        #expect(service.consumeNextResult() == nil)

        let missing = try await ConcreteReevaluationRunner(definition: makeReplayDecodeLand(emitting: replayDomainEvent()), recordFilePath: path)
        await missing.setFaultsForTesting(ReplayRunnerFaults(stateHashMissing: true))
        let step = try #require(try await missing.step())
        #expect(step.recordedHash == nil && step.isMatch, "no hash for the tick: unchanged, not a failure")
    }

    @Test("Faults installed on a JSON view keep its decode allowance: the policy comes from the record, not the wrapper (#646)")
    func faultWrapperKeepsTheJSONPolicy() async throws {
        let live = replayDomainEvent()
        let path = try await recordedPath(emitting: live, form: .jsonView)
        let runner = try await ConcreteReevaluationRunner(definition: makeReplayDecodeLand(emitting: live), recordFilePath: path)
        await runner.setFaultsForTesting(ReplayRunnerFaults())
        let step = try #require(try await runner.step())
        let replayed = try #require(step.replayFrame?.recordedEvents.first?.event as? ReplayDomainEvent)
        #expect(replayed.whole == live.whole, "a whole-number float written as an integer reads back")
    }

    @Test("Each setFaultsForTesting replaces the earlier faults: read faults don't stack, and the encode fault clears (#646)",
          arguments: ["state hash", "server events", "snapshot encode", "state hash missing"])
    func faultsAreReplaced(fault: String) async throws {
        let path = tempPath("sstr")
        try await recordOneTick(makeReplayDecodeLand(emitting: replayDomainEvent()), path: path)
        let runner = try await ConcreteReevaluationRunner(definition: makeReplayDecodeLand(emitting: replayDomainEvent()), recordFilePath: path)
        await runner.setFaultsForTesting(ReplayRunnerFaults(
            stateHashRead: fault == "state hash", serverEventsRead: fault == "server events", snapshotEncode: fault == "snapshot encode",
            stateHashMissing: fault == "state hash missing"
        ))
        await runner.setFaultsForTesting(ReplayRunnerFaults())
        let step = try #require(try await runner.step(), "\(fault): the earlier fault is gone")
        #expect(step.recordedHash != nil, "\(fault): the record's hash is read again")
        #expect(step.isMatch, "\(fault)")
    }

    @Test("A snapshot that doesn't encode fails the step (A10), and the run through the service")
    func snapshotEncodeErrorFailsTheStep() async throws {
        let path = tempPath("sstr")
        try await recordOneTick(makeReplayDecodeLand(emitting: replayDomainEvent()), path: path)
        let runner = try await ConcreteReevaluationRunner(definition: makeReplayDecodeLand(emitting: replayDomainEvent()), recordFilePath: path)
        await runner.setFaultsForTesting(ReplayRunnerFaults(snapshotEncode: true))
        await #expect(throws: ReevaluationReplayResolutionError.stateEncode(tickId: 0, error: "\(ReplayRunnerFaults.Injected.snapshotEncode)")) {
            _ = try await runner.step()
        }
        let fresh = try await ConcreteReevaluationRunner(definition: makeReplayDecodeLand(emitting: replayDomainEvent()), recordFilePath: path)
        await fresh.setFaultsForTesting(ReplayRunnerFaults(snapshotEncode: true))
        let service = await runThroughService(fresh)
        #expect(service.getStatus().phase == .failed)
        #expect(service.consumeNextResult() == nil)
    }

    @Test("A snapshot that can't build the state back fails the resolve with the tick and the cause (A11)")
    func stateDecodeErrorFailsTheResolve() throws {
        let definition = Land("replay-shown", using: ReplayShownState.self) { Rules {} }
        // A snapshot whose field has the wrong type.
        let wrongType = try JSONEncoder().encode(StateSnapshot(values: ["ticks": .string("three")]))
        let error = #expect(throws: ReevaluationReplayResolutionError.self) {
            try ReevaluationReplayFrame.resolve(
                tickId: 4, recordedServerEvents: [], emittedServerEvents: [],
                actualState: AnyCodable(String(decoding: wrongType, as: UTF8.self)), definition: definition)
        }
        guard case .stateDecode(4, _)? = error else {
            Issue.record("expected stateDecode at tick 4, got \(String(describing: error))")
            return
        }
        // A payload that isn't a snapshot at all.
        #expect(throws: ReevaluationReplayResolutionError.stateDecode(tickId: 4, error: "the snapshot isn't a StateSnapshot")) {
            try ReevaluationReplayFrame.resolve(
                tickId: 4, recordedServerEvents: [], emittedServerEvents: [], actualState: AnyCodable("not json"), definition: definition)
        }
        // The same snapshot with the right type builds it.
        let right = try JSONEncoder().encode(StateSnapshot(values: ["ticks": .int(3)]))
        let frame = try ReevaluationReplayFrame.resolve(
            tickId: 4, recordedServerEvents: [], emittedServerEvents: [],
            actualState: AnyCodable(String(decoding: right, as: UTF8.self)), definition: definition)
        #expect((frame.state as? ReplayShownState)?.ticks == 3)
    }

    @Test("A tick whose state hash can't be computed is unverifiable: a monitor-only run goes on, a replay land's run fails with the hash error (#180)")
    func unavailableHashTick() async throws {
        let path = tempPath("sstr")
        try await recordOneTick(makeNaNLand(), path: path)
        let runner = try await ConcreteReevaluationRunner(definition: makeNaNLand(), recordFilePath: path)
        let step = try #require(try await runner.step())
        #expect(!step.isMatch, "unverifiable, never a match")
        #expect(ReevaluationEngine.isUnavailableHash(step.stateHash))
        let frame = try #require(step.replayFrame)
        #expect(frame.state == nil)
        let reason = try #require(frame.stateUnavailable)
        #expect(reason.hasPrefix("the state can't be converted for its hash: "), "\(reason)")

        // A monitor-only run: the tick is reported, and the run completes.
        let monitor = await runThroughService(try await ConcreteReevaluationRunner(definition: makeNaNLand(), recordFilePath: path))
        #expect(monitor.getStatus().phase == .completed, "\(monitor.getStatus().errorMessage)")
        #expect(monitor.getStatus().mismatchedTicks == 1)
        #expect(monitor.consumeNextResult()?.tickId == 0)

        // A run feeding a replay land: it has no state to show, so the run fails, naming the cause.
        let replay = await runThroughService(
            try await ConcreteReevaluationRunner(definition: makeNaNLand(), recordFilePath: path), replayLand: ReplayNaNState.self)
        #expect(replay.getStatus().phase == .failed)
        #expect(replay.getStatus().errorMessage == ReevaluationReplayResolutionError.stateUnavailable(tickId: 0, reason: reason).description)
        #expect(replay.consumeNextResult() == nil)
    }

    @Test("A result's projector copy keeps every other field (M2)")
    func projectorCopyKeepsFields() throws {
        let snapshot = try JSONEncoder().encode(StateSnapshot(values: ["ticks": .int(1)]))
        let frame = try ReevaluationReplayFrame.resolve(
            tickId: 1, recordedServerEvents: [], emittedServerEvents: [],
            actualState: AnyCodable(String(decoding: snapshot, as: UTF8.self)),
            definition: makeReplayDecodeLand(emitting: replayDomainEvent())
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

// MARK: - Recorded event targets (#641)

@Suite("ReplayEventTargetTests", .timeLimit(.minutes(1)))
struct ReplayEventTargetTests {
    /// Every target form `ReevaluationEventTargetRecord.from(_:)` doesn't write.
    private static let malformed: [(kind: String, ids: [String])] = [
        ("unknown", ["x"]),
        ("player", []), ("client", []), ("session", []),
        ("player", ["a", "b"]), ("client", ["a", "b"]), ("session", ["a", "b"]),
        ("all", ["a"]),
    ]

    private static let eventName = payloadEventName(for: ReplayUnsignedEvent.self)

    private static func recorded(_ target: ReevaluationEventTargetRecord) -> ReevaluationRecordedServerEvent {
        ReevaluationRecordedServerEvent(
            kind: "serverEvent", sequence: 4, tickId: 2, typeIdentifier: eventName,
            payload: AnyCodable(["big": 7] as [String: Int]), target: target
        )
    }

    @Test("Each malformed recorded target fails the resolve with the tick, the event and the target (#641)")
    func malformedTargetsFailTheResolve() throws {
        let definition = makeUnsignedLand(emitting: ReplayUnsignedEvent(big: 7))
        for (kind, ids) in Self.malformed {
            let target = ReevaluationEventTargetRecord(kind: kind, ids: ids)
            let error = #expect(throws: ReevaluationReplayResolutionError.self, "kind \(kind), ids \(ids)") {
                try ReevaluationReplayFrame.resolve(
                    tickId: 3, recordedServerEvents: [Self.recorded(target)], emittedServerEvents: [],
                    actualState: nil, definition: definition
                )
            }
            let cause = ReevaluationRecordContentError.malformedEventTarget(kind: kind, idCount: ids.count)
            #expect(error == .eventTarget(tickId: 3, origin: .recorded, sequence: 4, name: Self.eventName, error: "\(cause)"))
        }
    }

    @Test("A well-formed recorded target resolves to the target the live run sent")
    func wellFormedTargetResolves() throws {
        let frame = try ReevaluationReplayFrame.resolve(
            tickId: 3,
            recordedServerEvents: [Self.recorded(ReevaluationEventTargetRecord(kind: "player", ids: ["p1"]))],
            emittedServerEvents: [], actualState: nil,
            definition: makeUnsignedLand(emitting: ReplayUnsignedEvent(big: 7))
        )
        guard case .player(let playerID)? = frame.recordedEvents.first?.target else {
            Issue.record("expected .player, got \(String(describing: frame.recordedEvents.first?.target))")
            return
        }
        #expect(playerID.rawValue == "p1")
    }

    @Test("A replay of a record whose event target was edited to a malformed one fails the run at that tick (#641)")
    func malformedTargetFailsTheRun() async throws {
        let path = tempPath("sstr")
        try await recordOneTick(makeUnsignedLand(emitting: ReplayUnsignedEvent(big: 7)), path: path)
        let view = String(decoding: try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: path))), as: UTF8.self)
        // Turn the one recorded `all` target into a `player` target with no ID.
        var edited = 0
        func edit(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if var target = object["target"] as? [String: Any], target["kind"] as? String == "all" {
                    target["kind"] = "player"
                    object["target"] = target
                    edited += 1
                }
                return object.mapValues(edit)
            }
            if let array = value as? [Any] { return array.map(edit) }
            return value
        }
        let tree = edit(try JSONSerialization.jsonObject(with: Data(view.utf8)))
        try #require(edited == 1, "one recorded target to edit")
        let json = tempPath("json")
        try JSONSerialization.data(withJSONObject: tree).write(to: URL(fileURLWithPath: json))
        let runner = try await ConcreteReevaluationRunner(
            definition: makeUnsignedLand(emitting: ReplayUnsignedEvent(big: 7)), recordFilePath: json
        )
        let error = await #expect(throws: ReevaluationReplayResolutionError.self) { _ = try await runner.step() }
        guard case .eventTarget(0, .recorded, _, Self.eventName, _)? = error else {
            Issue.record("expected eventTarget of the recorded event at tick 0, got \(String(describing: error))")
            return
        }
    }
}
