// Tests/SwiftStateTreeTests/VerifierRecordCodecTests.swift
//
// The offline verifier (`ReevaluationEngine.run`) compares each recorded server event with the
// one the replay emitted (#633). The recorded payload is a tree in the record's form, as
// `CanonicalMessagePack` wrote it: a `Date` as an ISO string at whole seconds, `Data` as an array
// of bytes, a `URL` in its keyed `Codable` form. The emitted payload is the typed value. (A
// `Decimal` can't be a server event field: the macros and registration refuse it, #597.) The comparison puts the emitted payload in the record's form first, so an event with such
// fields matches on both record forms (a saved record and its JSON view).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct VerifierCodecState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
}

/// Each field a JSON comparison of the typed value and the recorded tree tells apart.
@Payload
struct VerifierCodecEvent: ServerEventPayload {
    let at: Date
    let blob: Data
    let link: URL
    let ratio: Double
    let count: Int
}

/// A `-0.0`: a saved record keeps its sign, the JSON view writes `-0`, which reads back as `0`.
@Payload
struct VerifierZeroEvent: ServerEventPayload {
    let zero: Double
}

func verifierCodecEvent(at seconds: Double) -> VerifierCodecEvent {
    VerifierCodecEvent(
        at: Date(timeIntervalSince1970: seconds),
        blob: Data([0, 1, 254, 255]),
        link: URL(string: "https://example.com/a?b=c")!,
        ratio: 2.0,
        count: 7
    )
}

/// OnInitialize and each tick emit `event` to everyone.
private func makeVerifierCodecLand(emitting event: VerifierCodecEvent, zero: VerifierZeroEvent? = nil) -> LandDefinition<VerifierCodecState> {
    Land("verifier-codec", using: VerifierCodecState.self) {
        Rules {}
        Lifetime {
            OnInitialize { (_: inout VerifierCodecState, ctx: LandContext) in
                ctx.emitEvent(event, to: .all)
            }
            Tick(every: .seconds(3600)) { (state: inout VerifierCodecState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(event, to: .all)
                if let zero { ctx.emitEvent(zero, to: .all) }
            }
        }
        ServerEvents {
            Register(VerifierCodecEvent.self)
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

private func tempPath(_ ext: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("verifier-codec-\(UUID().uuidString).\(ext)").path
}

/// Runs OnInitialize and one tick of the land live with recording on, and returns the record's
/// path in `form`.
private func recordOneTick(emitting event: VerifierCodecEvent, zero: VerifierZeroEvent?, form: VerifierRecordForm) async throws -> String {
    let keeper = LandKeeper<VerifierCodecState>(
        definition: makeVerifierCodecLand(emitting: event, zero: zero),
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
    let saved = tempPath("sstr")
    try await recorder.save(to: saved)
    guard form == .jsonView else { return saved }
    let json = tempPath("json")
    try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: saved)))
        .write(to: URL(fileURLWithPath: json))
    return json
}

private func verify(emitting event: VerifierCodecEvent, zero: VerifierZeroEvent? = nil, form: VerifierRecordForm) async throws -> ReevaluationEngine.RunResult {
    let path = try await recordOneTick(emitting: event, zero: zero, form: form)
    return try await ReevaluationEngine.run(
        definition: makeVerifierCodecLand(emitting: event, zero: zero),
        initialState: VerifierCodecState(),
        recordFilePath: path
    )
}

@Suite("The offline verifier compares server events in the record's form (#633)")
struct VerifierRecordCodecTests {
    @Test("A replayed event with Date, Data, URL and integral Double fields matches its record, from each record form",
          arguments: VerifierRecordForm.allCases)
    func eventsMatchTheirRecord(form: VerifierRecordForm) async throws {
        let result = try await verify(emitting: verifierCodecEvent(at: 1_800_000_000), form: form)
        #expect(result.serverEventMismatches.isEmpty, "\(form): \(result.serverEventMismatches.map(\.tickId))")
        #expect(result.serverEventVerification == .passed, "\(form)")
        #expect(result.initialize == .passed, "\(form): OnInitialize's events")
    }

    @Test("A Date with a fractional second: the record keeps whole seconds, and the comparison puts the replayed value in the same form, so it matches",
          arguments: VerifierRecordForm.allCases)
    func fractionalDateMatches(form: VerifierRecordForm) async throws {
        let result = try await verify(emitting: verifierCodecEvent(at: 1_800_000_000.75), form: form)
        #expect(result.serverEventMismatches.isEmpty, "\(form)")
        #expect(result.initialize == .passed, "\(form)")
    }

    @Test("A -0.0: a saved record matches; the JSON view, which lost the sign, reports the tick (the stated JSON view limit)",
          arguments: VerifierRecordForm.allCases)
    func negativeZero(form: VerifierRecordForm) async throws {
        let result = try await verify(emitting: verifierCodecEvent(at: 1_800_000_000), zero: VerifierZeroEvent(zero: -0.0), form: form)
        #expect(result.serverEventMismatches.map(\.tickId) == (form == .saved ? [] : [0]), "\(form)")
    }
}
