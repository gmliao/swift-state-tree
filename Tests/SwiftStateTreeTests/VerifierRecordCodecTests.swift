// Tests/SwiftStateTreeTests/VerifierRecordCodecTests.swift
//
// The offline verifier (`ReevaluationEngine.run`) compares each recorded server event with the
// one the replay emitted (#633). The recorded payload is a tree in the record's form, as
// `CanonicalMessagePack` wrote it: a `Date` as an ISO string at whole seconds, `Data` as an array
// of bytes, a `URL` in its keyed `Codable` form. The emitted payload is the typed value. (A
// `Decimal` can't be a server event field: the macros and registration refuse it, #597.) The
// comparison puts the emitted payload in the record's form first, so an event with such fields
// matches on both record forms (a saved record and its JSON view).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct VerifierCodecState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
}

/// `at`, `blob` and `link` are the fields a JSON comparison of the typed value and the recorded
/// tree tells apart; `ratio` (an integral `Double`) and `count` are controls that compare equal
/// either way.
@Payload
struct VerifierCodecEvent: ServerEventPayload {
    let at: Date
    let blob: Data
    let link: URL
    let ratio: Double
    let count: Int
}

/// A `Date` alone, so a test of its fractional second fails for that field only.
@Payload
struct VerifierDateEvent: ServerEventPayload {
    let at: Date
}

/// A `Double` alone, for the sign of zero: a saved record keeps it, the JSON view writes `-0`,
/// which reads back as `0`.
@Payload
struct VerifierZeroEvent: ServerEventPayload {
    let zero: Double
}

let verifierCodecEvent = VerifierCodecEvent(
    at: Date(timeIntervalSince1970: 1_800_000_000),
    blob: Data([0, 1, 254, 255]),
    link: URL(string: "https://example.com/a?b=c")!,
    ratio: 2.0,
    count: 7
)

/// OnInitialize and each tick emit `events`, in order, to everyone.
private func makeVerifierCodecLand(emitting events: [any ServerEventPayload]) -> LandDefinition<VerifierCodecState> {
    Land("verifier-codec", using: VerifierCodecState.self) {
        Rules {}
        Lifetime {
            OnInitialize { (_: inout VerifierCodecState, ctx: LandContext) in
                for event in events { ctx.emitEvent(event, to: .all) }
            }
            Tick(every: .seconds(3600)) { (state: inout VerifierCodecState, ctx: LandContext) in
                state.ticks += 1
                for event in events { ctx.emitEvent(event, to: .all) }
            }
        }
        ServerEvents {
            Register(VerifierCodecEvent.self)
            Register(VerifierDateEvent.self)
            Register(VerifierZeroEvent.self)
        }
    }
}

private let verifierCodecLandID = "verifier-codec:local"

/// The record formats the verifier reads.
enum VerifierRecordForm: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case saved
    case jsonView
    var testDescription: String { rawValue }
}

/// A directory of its own for one recording, removed by the caller.
private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("verifier-codec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs OnInitialize and one tick of the land live with recording on, and returns the record's
/// path in `form`.
private func recordOneTick(emitting events: [any ServerEventPayload], form: VerifierRecordForm, in directory: URL) async throws -> String {
    let keeper = LandKeeper<VerifierCodecState>(
        definition: makeVerifierCodecLand(emitting: events),
        initialState: VerifierCodecState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.setLandID(verifierCodecLandID)
    await keeper.awaitInitialization()
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: verifierCodecLandID,
        landType: "verifier-codec",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "verifier-codec",
        rngSeed: await keeper.getRngSeed()
    ))
    await keeper.stepTickOnce()
    await keeper.waitForRecorderSubmissionsForTesting()
    let saved = directory.appendingPathComponent("record.sstr").path
    try await recorder.save(to: saved)
    guard form == .jsonView else { return saved }
    let json = directory.appendingPathComponent("record.json").path
    try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: saved)))
        .write(to: URL(fileURLWithPath: json))
    return json
}

/// Records `live`, then verifies a replay whose land emits `replayed` (by default the same events).
private func verify(
    live: [any ServerEventPayload],
    replayed: [any ServerEventPayload]? = nil,
    form: VerifierRecordForm
) async throws -> ReevaluationEngine.RunResult {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = try await recordOneTick(emitting: live, form: form, in: directory)
    return try await ReevaluationEngine.run(
        definition: makeVerifierCodecLand(emitting: replayed ?? live),
        initialState: VerifierCodecState(),
        recordFilePath: path
    )
}

/// Whether OnInitialize's verification failed.
private func initializeFailed(_ result: ReevaluationEngine.RunResult) -> Bool {
    if case .failed = result.initialize { return true }
    return false
}

@Suite("The offline verifier compares server events in the record's form (#633)")
struct VerifierRecordCodecTests {
    @Test("A replayed event with Date, Data, URL and integral Double fields matches its record, from each record form",
          arguments: VerifierRecordForm.allCases)
    func eventsMatchTheirRecord(form: VerifierRecordForm) async throws {
        let result = try await verify(live: [verifierCodecEvent], form: form)
        #expect(result.serverEventMismatches.isEmpty, "\(form): \(result.serverEventMismatches.map(\.tickId))")
        #expect(result.serverEventVerification == .passed, "\(form)")
        #expect(result.initialize == .passed, "\(form): OnInitialize's events")
    }

    @Test("A Date with a fractional second: the record keeps whole seconds, and the comparison puts the replayed value in the same form, so it matches",
          arguments: VerifierRecordForm.allCases)
    func fractionalDateMatches(form: VerifierRecordForm) async throws {
        let result = try await verify(live: [VerifierDateEvent(at: Date(timeIntervalSince1970: 1_800_000_000.75))], form: form)
        #expect(result.serverEventMismatches.isEmpty, "\(form)")
        #expect(result.initialize == .passed, "\(form)")
    }

    @Test("A -0.0: a saved record matches; the JSON view, which lost the sign, reports the tick (the stated JSON view limit)",
          arguments: VerifierRecordForm.allCases)
    func negativeZero(form: VerifierRecordForm) async throws {
        let result = try await verify(live: [VerifierZeroEvent(zero: -0.0)], form: form)
        #expect(result.serverEventMismatches.map(\.tickId) == (form == .saved ? [] : [0]), "\(form)")
        #expect(initializeFailed(result) == (form == .jsonView), "\(form): \(result.initialize)")
    }

    @Test("On a saved record, a replay that differs from the live run only in the sign of zero is reported",
          arguments: [(-0.0, 0.0), (0.0, -0.0)])
    func signOfZeroDivergenceIsReported(live: Double, replayed: Double) async throws {
        let result = try await verify(
            live: [VerifierZeroEvent(zero: live)],
            replayed: [VerifierZeroEvent(zero: replayed)],
            form: .saved
        )
        #expect(result.serverEventMismatches.map(\.tickId) == [0])
        #expect(initializeFailed(result), "\(result.initialize)")
    }

    @Test("The public classifier: a recorded tree against a typed replayed payload that differs only in sequence passes ignoring sequence; a payload difference fails")
    func classifierTakesARecordTreeAndTypedValues() throws {
        let typed = AnyCodable(VerifierDateEvent(at: Date(timeIntervalSince1970: 1_800_000_000)))
        // The record reader's form: `CanonicalMessagePack` written and read back as a tree.
        let tree = try CanonicalMessagePack.decode(AnyCodable.self, from: CanonicalMessagePack.encode(typed))
        let other = AnyCodable(VerifierDateEvent(at: Date(timeIntervalSince1970: 1_800_000_001)))
        func event(_ payload: AnyCodable, sequence: Int64) -> ReevaluationRecordedServerEvent {
            ReevaluationRecordedServerEvent(
                kind: "serverEvent", sequence: sequence, tickId: 0, typeIdentifier: "VerifierDate",
                payload: payload, target: ReevaluationEventTargetRecord(kind: "all", ids: [])
            )
        }
        let sequenceOnly = ReevaluationEngine.classifyServerEventMismatches(
            [(tickId: 0, expected: [event(tree, sequence: 1)], actual: [event(typed, sequence: 2)])],
            watermarkedTicks: []
        )
        #expect(sequenceOnly == .passedIgnoringSequence(ticks: [0]))
        let payloadDiffers = ReevaluationEngine.classifyServerEventMismatches(
            [(tickId: 0, expected: [event(tree, sequence: 1)], actual: [event(other, sequence: 2)])],
            watermarkedTicks: []
        )
        #expect(payloadDiffers == .failed(ticks: [0]))
    }
}
