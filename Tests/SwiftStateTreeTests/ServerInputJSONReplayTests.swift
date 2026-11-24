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

private func tempPath(_ ext: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("si-json-replay-\(UUID().uuidString).\(ext)").path
}

/// Submits the inputs live with recording on, applies them in one tick, and returns the record's
/// path in `form` with the live state.
private func recordInputs(_ inputs: [SIJSONRatio], form: SIJSONReplayForm) async throws -> (path: String, live: SIJSONReplayState) {
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
    let saved = tempPath("sstr")
    try await recorder.save(to: saved)
    guard form == .jsonView else { return (saved, live) }
    let json = tempPath("json")
    try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: saved)))
        .write(to: URL(fileURLWithPath: json))
    return (json, live)
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
        let inputs = [SIJSONRatio(ratio: 2.0, n: 3), SIJSONRatio(ratio: 0.5, n: 4)]
        let (path, live) = try await recordInputs(inputs, form: form)
        #expect(live.seen == ["2.0/3", "0.5/4"])
        let replayed = try await replayState(path: path)
        #expect(replayed.seen == live.seen, "\(form)")
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
