// Tests/SwiftStateTreeTests/ServerInputJSONReplayTests.swift
//
// #818: a server input with a whole-valued `Double` (`ratio: 2.0`) replays from the record's JSON
// view. JSON doesn't keep the float/integer split, so the view holds `2`; the record codec's
// strict decode refuses an integer where the type declares `Double`. The JSON view gets the same
// integer-to-float allowance its resolver outputs and server events have (#707), and a saved
// record stays strict.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct SIJSONReplayState: StateNodeProtocol {
    /// What the handler read, per applied input.
    @Sync(.broadcast)
    var seen: [String] = []

    public init() {}
}

@Payload
struct SIJSONRatio: ServerInputPayload {
    let ratio: Double
    let n: Int
}

private func makeSIJSONReplayLand() -> LandDefinition<SIJSONReplayState> {
    Land("si-json-replay", using: SIJSONReplayState.self) {
        Rules {
            HandleServerInput(SIJSONRatio.self) { (state: inout SIJSONReplayState, input: SIJSONRatio, _: LandContext) in
                state.seen.append("\(input.ratio)/\(input.n)")
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout SIJSONReplayState, _: LandContext) in }
        }
    }
}

/// The record formats a replay reads.
enum SIJSONReplayForm: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case saved
    case jsonView
    var testDescription: String { rawValue }
}

private let siJSONReplayLandID = "si-json-replay:local"

/// Runs `body` with a fresh temporary directory, removed afterwards.
private func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-json-replay-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Submits the inputs live with recording on, applies them in one tick, and returns the record's
/// path in `form`, written in `directory`, with the live state.
private func recordInputs(
    _ inputs: [SIJSONRatio], form: SIJSONReplayForm, in directory: URL
) async throws -> (path: String, live: SIJSONReplayState) {
    let keeper = LandKeeper<SIJSONReplayState>(
        definition: makeSIJSONReplayLand(),
        initialState: SIJSONReplayState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: siJSONReplayLandID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.awaitInitialization()
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: siJSONReplayLandID,
        landType: "si-json-replay",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "si-json-replay",
        rngSeed: await keeper.getRngSeed()
    ))
    for input in inputs {
        guard case .accepted = await keeper.submitServerInput(input) else {
            Issue.record("the input \(input) wasn't accepted")
            continue
        }
    }
    await keeper.stepTickOnce()
    await keeper.waitForRecorderSubmissionsForTesting()
    let live = await keeper.currentState()
    let saved = directory.appendingPathComponent("record.sstr").path
    try await recorder.save(to: saved)
    guard form == .jsonView else { return (saved, live) }
    let json = directory.appendingPathComponent("record.json").path
    try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: saved)))
        .write(to: URL(fileURLWithPath: json))
    return (json, live)
}

/// Rewrites the saved record at `path` in place: every recorded server input's `ratio` becomes
/// the integer 2, as an edited or older saved record could hold it. Each record of the log is
/// decoded and framed again, so the header and footer stay as written.
private func rewriteRatioAsInteger(atPath path: String) throws {
    let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
    let preambleCount = ReevaluationRecordLog.preamble.count
    var out = Array(bytes.prefix(preambleCount))
    var offset = preambleCount
    var rewritten = 0
    while offset < bytes.count {
        let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        var record = try CanonicalMessagePack.decode(
            ReevaluationLogRecord.self, from: Array(bytes[offset + 4..<offset + 4 + length]))
        if let inputs = record.serverInputs {
            record.serverInputs = inputs.map { input in
                rewritten += 1
                return ReevaluationRecordedServerInput(
                    sequence: input.sequence,
                    typeIdentifier: input.typeIdentifier,
                    payload: AnyCodable(["ratio": AnyCodable(2), "n": AnyCodable(3)] as [String: AnyCodable]),
                    resolvedAtTick: input.resolvedAtTick
                )
            }
        }
        out += try ReevaluationRecordLog.framed(record)
        offset += 4 + length
    }
    #expect(rewritten == 1, "the record holds the one server input")
    try Data(out).write(to: URL(fileURLWithPath: path))
}

/// Replays the record at `path` through its one tick and returns the replayed state.
private func replayState(path: String) async throws -> SIJSONReplayState {
    let keeper = LandKeeper<SIJSONReplayState>(
        definition: makeSIJSONReplayLand(),
        initialState: SIJSONReplayState(),
        mode: .reevaluation,
        reevaluationSource: try ReevaluationRecordFile.openSource(filePath: path),
        autoStartLoops: false
    )
    await keeper.stepTickOnce()
    return await keeper.currentState()
}

@Suite("A server input with a whole-valued Double replays from the JSON view (#818)")
struct ServerInputJSONReplayTests {
    @Test("Replayed from each record form, the handler reads what the live one read: an integral Double and a fractional one",
          arguments: SIJSONReplayForm.allCases)
    func replaySeesTheLiveInput(form: SIJSONReplayForm) async throws {
        try await withTempDirectory { directory in
            let inputs = [SIJSONRatio(ratio: 2.0, n: 3), SIJSONRatio(ratio: 0.5, n: 4)]
            let (path, live) = try await recordInputs(inputs, form: form, in: directory)
            #expect(live.seen == ["2.0/3", "0.5/4"])
            let replayed = try await replayState(path: path)
            #expect(replayed.seen == live.seen, "\(form)")
        }
    }

    @Test("Replay from a saved record stays strict: a server input whose ratio the record holds as an integer is refused")
    func savedRecordIntegerIsRefused() async throws {
        try await withTempDirectory { directory in
            let (path, live) = try await recordInputs([SIJSONRatio(ratio: 2.5, n: 3)], form: .saved, in: directory)
            #expect(live.seen == ["2.5/3"])
            try rewriteRatioAsInteger(atPath: path)
            // Control: the rewritten record is still a saved record, not the JSON view.
            #expect(try ReevaluationRecordFile.openSource(filePath: path) is ReevaluationRecordLogSource)
            let replayed = try await replayState(path: path)
            #expect(replayed.seen == [], "the integer is refused where the type declares Double")
        }
    }

    @Test("The decode allowance is the JSON view's only: a saved record's integer stays refused where a Double is declared")
    func savedRecordStaysStrict() throws {
        let handler = try #require(makeSIJSONReplayLand().serverInputHandlers[String(describing: SIJSONRatio.self)])
        let tree = AnyCodable(["ratio": AnyCodable(2), "n": AnyCodable(3)] as [String: AnyCodable])
        #expect(throws: (any Error).self, "strict") { _ = try handler.decode(tree) }
        let allowed = try handler.decode(tree, integralFloats: true)
        #expect((allowed as? SIJSONRatio)?.ratio == 2.0)
    }
}
