// Tests/SwiftStateTreeTransportTests/SyncOutputGoldenTests.swift
//
// Golden replay recordings: short checked-in records of the verifier land, replayed on every
// test run. Each must still reproduce every recorded state hash and sync-output hash
// (`passed`), with the same counts as when it was recorded. An intentional change to the sync
// output (the diff, the canonical form, the hashes, the record format, the verifier land)
// re-baselines them with `Tools/regenerate-sync-output-goldens.sh`, and the PR says why.
// See Fixtures/SyncOutputGoldens/README.md.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// A recorded scenario: its encoding and its script.
enum SyncOutputGolden: String, CaseIterable, Sendable, CustomStringConvertible {
    /// Three players, mid-run join and leave, per-player scores (combined frames).
    case joinLeaveJSON = "join-leave-json"
    /// The same script with opcode 107 (merged broadcast frame, events).
    case joinLeaveMessagePack = "join-leave-messagepack"
    /// A debug freeze and resume between ticks: a legacy cycle in the stream.
    case freezeResume = "freeze-resume-messagepack"
    /// Bursts of targeted and broadcast events in action turns and ticks.
    case eventHeavy = "event-heavy-messagepack"

    var description: String { rawValue }

    var encoding: InTurnEncoding {
        switch self {
        case .joinLeaveJSON: return .json
        case .joinLeaveMessagePack, .freezeResume, .eventHeavy: return .messagepack
        }
    }

    func play(_ f: VerifierFixture) async throws {
        switch self {
        case .joinLeaveJSON, .joinLeaveMessagePack:
            try await playScript(f)
        case .freezeResume:
            try await f.join(1)
            try await f.join(2)
            await f.tick(2)
            try await f.set(1, "score", 5)
            let frozen = try await f.adapter.debugFreeze()
            _ = await f.adapter.debugResume(freezeToken: frozen.freezeToken)
            try await f.set(2, "score", 7)
            await f.tick(2)
        case .eventHeavy:
            try await f.join(1)
            try await f.join(2)
            await f.tick()
            try await f.set(1, "burst", 6)
            try await f.set(2, "burst", 4)
            await f.tick()
            try await f.set(1, "burst", 3)
            await f.tick(2)
        }
    }
}

@Suite("Sync-output golden recordings", .timeLimit(.minutes(1)))
struct SyncOutputGoldenTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/SyncOutputGoldens")

    /// Set by `Tools/regenerate-sync-output-goldens.sh`: record each scenario live and write its
    /// record and expected summary, instead of checking them.
    static let regenerateKey = "SST_REGENERATE_SYNC_OUTPUT_GOLDENS"

    static func recordPath(_ golden: SyncOutputGolden) -> String {
        directory.appendingPathComponent("\(golden.rawValue).reeval.json").path
    }

    static func expectedPath(_ golden: SyncOutputGolden) -> String {
        directory.appendingPathComponent("\(golden.rawValue).expected.txt").path
    }

    @Test("A golden recording replays with every hash reproduced and the recorded counts", arguments: SyncOutputGolden.allCases)
    func replays(golden: SyncOutputGolden) async throws {
        if ProcessInfo.processInfo.environment[Self.regenerateKey] == "1" {
            try await regenerate(golden)
            return
        }
        guard FileManager.default.fileExists(atPath: Self.recordPath(golden)) else {
            Issue.record("missing \(Self.recordPath(golden)): run Tools/regenerate-sync-output-goldens.sh")
            return
        }
        let expected = try String(contentsOfFile: Self.expectedPath(golden), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await VerifierFixture.replay(recordAt: Self.recordPath(golden))
        #expect(result.tickHashes == result.recordedStateHashes, "state hashes")
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.syncOutput.summary == expected)
        #expect(result.initialize == .passed)
    }

    /// Records the scenario live and writes the record and the summary its replay gives. The
    /// replay must pass: a regenerated golden is a baseline, not a known failure.
    private func regenerate(_ golden: SyncOutputGolden) async throws {
        try #require(InTurnSync.isEnabled(), "goldens are recorded with in-turn sync on")
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let f = await VerifierFixture.make(encoding: golden.encoding)
        try await golden.play(f)
        try await f.saveRecord(to: Self.recordPath(golden))
        let result = try await VerifierFixture.replay(recordAt: Self.recordPath(golden))
        try #require(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        try #require(result.tickHashes == result.recordedStateHashes)
        try (result.syncOutput.summary + "\n").write(toFile: Self.expectedPath(golden), atomically: true, encoding: .utf8)
    }
}
