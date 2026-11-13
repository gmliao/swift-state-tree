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
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

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
    /// Map keys that need escaping in a JSON pointer ("a/b", "t~1") or look like an index
    /// ("x[1]"), added, changed and seen by a joiner.
    case escapedKeys = "escaped-keys-json"

    var description: String { rawValue }

    var encoding: InTurnEncoding {
        switch self {
        case .joinLeaveJSON, .escapedKeys: return .json
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
        case .escapedKeys:
            try await f.join(1)
            await f.tick()
            try await f.set(1, "keys", 1)
            await f.tick()
            try await f.set(1, "keys", 2)
            try await f.join(2)
            await f.tick()
        }
    }
}

/// Environment keys of the golden recordings.
enum SyncOutputGoldenEnvKeys {
    /// Set by `Tools/regenerate-sync-output-goldens.sh`: record each scenario live and write its
    /// record and expected files, instead of checking them.
    static let regenerate = "SST_REGENERATE_SYNC_OUTPUT_GOLDENS"
}

@Suite("Sync-output golden recordings", .timeLimit(.minutes(1)))
struct SyncOutputGoldenTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/SyncOutputGoldens")

    static var regenerating: Bool {
        EnvHelpers.getEnvBool(key: SyncOutputGoldenEnvKeys.regenerate, defaultValue: false)
    }

    static let regenerateHint = "if the change is intended, run Tools/regenerate-sync-output-goldens.sh and say why in the PR"

    /// The current 3.x record (binary log, #245; 3.1 since #325).
    static func recordPath(_ golden: SyncOutputGolden) -> String {
        directory.appendingPathComponent("\(golden.rawValue).reeval.sstr").path
    }

    /// The same scenario recorded as 2.6 before 3.0, kept as a reader fixture: it must still
    /// read, and give the source the 3.x record gives.
    static func legacyRecordPath(_ golden: SyncOutputGolden) -> String {
        directory.appendingPathComponent("\(golden.rawValue).reeval.json").path
    }

    static func expectedPath(_ golden: SyncOutputGolden) -> String {
        directory.appendingPathComponent("\(golden.rawValue).expected.txt").path
    }

    /// The apply oracle's cases for the recording, which `sdk/ts` replays through `view.ts`.
    static func applyCasesPath(_ golden: SyncOutputGolden) -> String {
        directory.appendingPathComponent("\(golden.rawValue).apply-cases.json").path
    }

    /// The verifier land's protocol schema, which the TypeScript check builds its view with.
    static var schemaPath: String {
        directory.appendingPathComponent("verifier-land.schema.json").path
    }

    static func encodeSchema() throws -> Data {
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(makeVerifierLand())])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(schema)
    }

    @Test("The checked-in verifier-land schema is current")
    func schemaIsCurrent() throws {
        guard !Self.regenerating else {
            try Self.encodeSchema().write(to: URL(fileURLWithPath: Self.schemaPath))
            return
        }
        let checkedIn = try Data(contentsOf: URL(fileURLWithPath: Self.schemaPath))
        #expect(try Self.encodeSchema() == checkedIn, "\(Self.regenerateHint)")
    }

    static func encodeApplyCases(_ cases: [SyncOutputApplyCaseRecorder.Case]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(cases)
    }

    @Test("A golden recording replays with every hash reproduced and the recorded counts", arguments: SyncOutputGolden.allCases)
    func replays(golden: SyncOutputGolden) async throws {
        if Self.regenerating {
            try await regenerate(golden)
            return
        }
        guard FileManager.default.fileExists(atPath: Self.recordPath(golden)) else {
            Issue.record("missing \(Self.recordPath(golden)): run Tools/regenerate-sync-output-goldens.sh")
            return
        }
        let expected = try String(contentsOfFile: Self.expectedPath(golden), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recorder = SyncOutputApplyCaseRecorder()
        let result = try await SyncOutputApplyCaseRecorder.$current.withValue(recorder) {
            try await VerifierFixture.replay(recordAt: Self.recordPath(golden))
        }
        #expect(result.tickHashes == result.recordedStateHashes, "state hashes")
        // The TypeScript-side fixture must be the cases this build's oracle checks.
        let applyCases = try Data(contentsOf: URL(fileURLWithPath: Self.applyCasesPath(golden)))
        #expect(try Self.encodeApplyCases(recorder.cases) == applyCases, "apply cases: \(Self.regenerateHint)")
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.syncOutput.summary == expected)
        #expect(result.initialize == .passed)
    }

    /// The replay test only reads the goldens, so a change on the recording side (the scenario,
    /// the verifier land, the adapter's digests or stream writer) would go unnoticed: re-record
    /// each scenario into a temporary file and require the committed bytes.
    @Test("Re-recording a golden scenario gives the committed bytes", arguments: SyncOutputGolden.allCases)
    func rerecordMatchesCommitted(golden: SyncOutputGolden) async throws {
        // Goldens are recorded with in-turn sync on; with it off there is no sync stream.
        guard !Self.regenerating, InTurnSync.isEnabled() else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-output-goldens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("\(golden.rawValue).reeval.sstr").path
        try await Self.record(golden, to: path)
        let rerecorded = try Data(contentsOf: URL(fileURLWithPath: path))
        let committed = try Data(contentsOf: URL(fileURLWithPath: Self.recordPath(golden)))
        #expect(rerecorded == committed, "re-recording \(golden) differs from \(Self.recordPath(golden)): the scenario, the verifier land or the recording side changed; \(Self.regenerateHint)")
    }

    /// A bytes check alone would let a regression in through a re-recording: each 3.x golden
    /// and its kept 2.6 copy must give an equal source (frames, initialize record, sync stream,
    /// max tick).
    @Test("A 3.x golden and its kept 2.6 copy give the same source", arguments: SyncOutputGolden.allCases)
    func legacyCopyGivesTheSameSource(golden: SyncOutputGolden) async throws {
        guard !Self.regenerating else { return }
        let current = try ReevaluationRecordFile.openSource(filePath: Self.recordPath(golden))
        let legacy = try ReevaluationRecordFile.openSource(filePath: Self.legacyRecordPath(golden))
        #expect(current is ReevaluationRecordLogSource)
        #expect(legacy is JSONReevaluationSource)
        #expect(try await current.getMetadata().version == ReevaluationRecordVersion.current)
        #expect(try await legacy.getMetadata().version == "2.6")
        #expect(try await current.getRecordCompleteness() == .complete)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let currentFrames = await (current as! ReevaluationRecordLogSource).getAllFrames()
        let legacyFrames = await (legacy as! JSONReevaluationSource).getAllFrames()
        #expect(try encoder.encode(currentFrames) == encoder.encode(legacyFrames), "frames")
        let maxTicks = (try await current.getMaxTickId(), try await legacy.getMaxTickId())
        #expect(maxTicks.0 == maxTicks.1)
        let streams = (try await current.getSyncStream(), try await legacy.getSyncStream())
        #expect(streams.0 == streams.1, "sync stream")
        let initializes = (try await current.getInitializeRecord(), try await legacy.getInitializeRecord())
        #expect(try encoder.encode(initializes.0) == encoder.encode(initializes.1), "initialize")
    }

    /// The path index changes only the opcode encoders' path ids, after the sync plan: the record
    /// (logical patches, sync-stream hashes) is the committed one with it on, and its replay
    /// gives the committed summary.
    @Test("With the path index on, a golden scenario records the committed bytes and replays to the committed summary", arguments: SyncOutputGolden.allCases)
    func pathIndexKeepsTheRecord(golden: SyncOutputGolden) async throws {
        guard !Self.regenerating, InTurnSync.isEnabled() else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-output-goldens-path-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("\(golden.rawValue).reeval.sstr").path
        // The JSON goldens use the JSON state-update encoding, which has no path ids: record them
        // with the opcode encoding and the index instead.
        let encoding: InTurnEncoding = golden.encoding == .json ? .opcodeJsonArray : golden.encoding
        let f = await VerifierFixture.make(encoding: encoding, pathIndex: true)
        #expect(await f.adapter.stateUpdateFeatures == ["pathIndex"])
        try await golden.play(f)
        try await f.saveRecord(to: path)
        if golden.encoding != .json {
            let committed = try Data(contentsOf: URL(fileURLWithPath: Self.recordPath(golden)))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == committed, "\(golden) with the path index")
        }
        let result = try await VerifierFixture.replay(recordAt: path)
        let expected = try String(contentsOfFile: Self.expectedPath(golden), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.syncOutput.summary == expected, "\(golden) with the path index")
        #expect(await f.adapter.unmappedPathPatches == 0)
    }

    /// Field merge changes only how the opcode encoders group a frame's patches: the record is
    /// the committed one with it on (and the path index on or off), and its replay gives the
    /// committed summary.
    @Test("With field merge on, a golden scenario records the committed bytes and replays to the committed summary", arguments: SyncOutputGolden.allCases, [false, true])
    func fieldMergeKeepsTheRecord(golden: SyncOutputGolden, pathIndex: Bool) async throws {
        guard !Self.regenerating, InTurnSync.isEnabled() else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-output-goldens-field-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("\(golden.rawValue).reeval.sstr").path
        let encoding: InTurnEncoding = golden.encoding == .json ? .opcodeJsonArray : golden.encoding
        let f = await VerifierFixture.make(encoding: encoding, pathIndex: pathIndex, fieldMerge: true)
        #expect(await f.adapter.stateUpdateFeatures == (pathIndex ? ["pathIndex", "fieldMerge"] : ["fieldMerge"]))
        try await golden.play(f)
        try await f.saveRecord(to: path)
        if golden.encoding != .json {
            let committed = try Data(contentsOf: URL(fileURLWithPath: Self.recordPath(golden)))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == committed, "\(golden) with field merge")
        }
        let result = try await VerifierFixture.replay(recordAt: path)
        let expected = try String(contentsOfFile: Self.expectedPath(golden), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.syncOutput.summary == expected, "\(golden) with field merge")
    }

    /// Row addressing changes only how the opcode encoders address a root node map's rows,
    /// after the plan (parent plan section 6, option 1): two router-joined runs of a scenario,
    /// identical but for the feature, record the same frames and sync stream and replay to the
    /// same summary. They are compared with each other, not with the committed goldens: a router
    /// join is scheduled differently from the direct join the goldens were recorded with.
    /// The verifier land has no root node map, so no row entries are sent here: what this covers
    /// is the scheduling rows in effect turn on (the forced full plan, resync-first ordering).
    /// With row entries sent, RowAddressingAdapterTests' `recordStaysLogical` checks the record
    /// and its replay.
    @Test("With row addressing in effect (no row entries: no root node map), a golden scenario through the router records what it records with it off", arguments: SyncOutputGolden.allCases)
    func rowAddressingKeepsTheRecord(golden: SyncOutputGolden) async throws {
        guard !Self.regenerating, InTurnSync.isEnabled() else { return }
        let encoding: InTurnEncoding = golden.encoding == .json ? .opcodeJsonArray : golden.encoding
        var frames: [Data] = [], streams: [[ReevaluationSyncStreamEntry]] = [], summaries: [String] = []
        for on in [false, true] {
            let f = await VerifierFixture.makeThroughRouter(encoding: encoding, rowAddressing: on)
            // Each arm runs what it says.
            #expect(f.adapter.rowAddressing == on, "\(golden): rows \(on ? "in effect" : "off")")
            #expect(f.adapter.stateUpdateFeatures.contains(StateUpdateFeature.rowAddressing) == on)
            try await golden.play(f)
            streams.append(try await f.stream())
            let recorder = try #require(await f.keeper.getReevaluationRecorder())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            frames.append(try encoder.encode(await recorder.getAllFrames()))
            let result = try await f.replay()
            #expect(result.syncOutput.verdict == .passed, "\(golden), rows \(on): \(result.syncOutput.summary)")
            summaries.append(result.syncOutput.summary)
        }
        #expect(streams[0].count > 0, "\(golden): the scenario syncs")
        #expect(frames[0] == frames[1], "\(golden): frames")
        #expect(streams[0] == streams[1], "\(golden): sync stream")
        #expect(summaries[0] == summaries[1], "\(golden): replay summary")
    }

    /// The per-player tables (#514) against the shadow (plan §5): a golden scenario through the
    /// router with them on replays with 0 mismatches, and records what it records with them off.
    /// The shadow runs today's engine, so this holds under D5's condition: the check asserts the
    /// run counted no drop and no encode failure. The verifier land stands in for the visibility
    /// land: its per-player slices (an `Int`, a `Double`, a node) take the typed slots.
    @Test("With the per-player tables on, a golden scenario through the router verifies against the shadow and records what it records with them off", arguments: SyncOutputGolden.allCases)
    func perPlayerTablesKeepTheRecord(golden: SyncOutputGolden) async throws {
        guard !Self.regenerating, InTurnSync.isEnabled() else { return }
        let encoding: InTurnEncoding = golden.encoding == .json ? .opcodeJsonArray : golden.encoding
        var frames: [Data] = [], streams: [[ReevaluationSyncStreamEntry]] = [], summaries: [String] = []
        for on in [true, false] {
            let f = await VerifierFixture.makeThroughRouter(encoding: encoding, rowAddressing: false, perPlayerTables: on)
            #expect(await f.adapter.perPlayerSyncTablesInEffect() == on, "\(golden): per-player tables \(on)")
            if on {
                let kinds = try #require(await f.adapter.perPlayerSyncTableFieldKinds())
                #expect(kinds.values.allSatisfy { $0 != .fallback }, "\(golden): \(kinds)")
            }
            try await golden.play(f)
            #expect(await f.adapter.syncDroppedUpdates == 0, "\(golden), per-player tables \(on): no drop or encode failure")
            streams.append(try await f.stream())
            let recorder = try #require(await f.keeper.getReevaluationRecorder())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            frames.append(try encoder.encode(await recorder.getAllFrames()))
            let result = try await f.replay()
            #expect(result.syncOutput.verdict == .passed, "\(golden), per-player tables \(on): \(result.syncOutput.summary)")
            #expect(result.syncOutput.perPlayer.compared > 0)
            summaries.append(result.syncOutput.summary)
        }
        #expect(frames[0] == frames[1], "\(golden): frames")
        #expect(streams[0] == streams[1], "\(golden): sync stream")
        #expect(summaries[0] == summaries[1], "\(golden): replay summary")
    }

    /// Records the scenario live into `path`.
    static func record(_ golden: SyncOutputGolden, to path: String) async throws {
        let f = await VerifierFixture.make(encoding: golden.encoding)
        try await golden.play(f)
        try await f.saveRecord(to: path)
    }

    /// Records the scenario live and writes the record and the summary its replay gives. The
    /// replay must pass: a regenerated golden is a baseline, not a known failure.
    private func regenerate(_ golden: SyncOutputGolden) async throws {
        try #require(InTurnSync.isEnabled(), "goldens are recorded with in-turn sync on")
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try await Self.record(golden, to: Self.recordPath(golden))
        let recorder = SyncOutputApplyCaseRecorder()
        let result = try await SyncOutputApplyCaseRecorder.$current.withValue(recorder) {
            try await VerifierFixture.replay(recordAt: Self.recordPath(golden))
        }
        try #require(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        try #require(result.tickHashes == result.recordedStateHashes)
        try (result.syncOutput.summary + "\n").write(toFile: Self.expectedPath(golden), atomically: true, encoding: .utf8)
        try Self.encodeApplyCases(recorder.cases).write(to: URL(fileURLWithPath: Self.applyCasesPath(golden)))
    }
}
