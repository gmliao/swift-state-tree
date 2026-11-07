import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// Record format 3.0 (#245) on live runs of the verifier land, with in-turn sync on or off
// (the CI legs): the frames read back against the 2.6 recorder's built from the same calls,
// and the replay verdicts.

@Test("A live run's 3.0 record gives the 2.6 recorder's frames and replays clean", arguments: SyncOutputGolden.allCases)
func liveRunMatchesLegacyFrames(golden: SyncOutputGolden) async throws {
    let f = await ReevaluationRecorder.$recordsLegacyFramesForTesting.withValue(true) {
        await VerifierFixture.make(encoding: golden.encoding)
    }
    try await golden.play(f)
    await f.keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await f.keeper.getReevaluationRecorder())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-log-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("\(golden.rawValue).sstr").path
    try await f.saveRecord(to: path)

    let source = try #require(try ReevaluationRecordFile.openSource(filePath: path) as? ReevaluationRecordLogSource)
    let frames = await source.getAllFrames()
    let legacy = await recorder.legacyFramesForTesting()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // The one intended difference: 2.6 kept only the last server-event list of a tick whose
    // outputs were flushed more than once; 3.0 keeps them all, so 2.6's list is a suffix.
    func withoutServerEvents(_ frames: [ReevaluationTickFrame]) -> [ReevaluationTickFrame] {
        frames.map { $0.replacing(serverEvents: []) }
    }
    #expect(try encoder.encode(withoutServerEvents(frames)) == encoder.encode(withoutServerEvents(legacy)), "frames apart from server events")
    #expect(frames.map(\.tickId) == legacy.map(\.tickId))
    for (current, old) in zip(frames, legacy) {
        #expect(current.serverEvents.map(\.sequence).suffix(old.serverEvents.count) == ArraySlice(old.serverEvents.map(\.sequence)), "tick \(current.tickId)")
    }
    if InTurnSync.isEnabled() {
        #expect(try encoder.encode(frames) == encoder.encode(legacy), "in-turn: identical frames")
    }

    let result = try await VerifierFixture.replay(recordAt: path)
    #expect(result.recordCompleteness == .complete)
    #expect(result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil } == result.recordedStateHashes)
    #expect(result.serverEventVerification == .passed, "\(result.serverEventMismatches.map(\.tickId))")
    if InTurnSync.isEnabled() {
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
    }
}
