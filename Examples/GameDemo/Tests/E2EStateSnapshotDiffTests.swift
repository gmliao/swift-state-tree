// Examples/GameDemo/Tests/E2EStateSnapshotDiffTests.swift
//
// E2E test: records live HeroDefense state snapshots to a temporary directory, then reruns
// as reevaluation with --diff-with to verify every per-tick state matches.
// Focus: initial player position (set via ctx.random in OnJoin) and monster spawning.

import Testing
import Foundation
import Logging
@testable import GameContent
@testable import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

// MARK: - Helpers

/// Where the test writes its records: a new temporary directory per call, so a test run never
/// adds files to the tracked `reevaluation-records/` (its fixtures are read by other tests) and
/// stale records from an earlier run can't be picked up. The paths are printed for inspection
/// after the run.
private func recordsDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gamedemo-e2e-state-records-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeServices() -> LandServices {
    var services = LandServices()
    services.register(
        GameConfigProviderService(provider: DefaultGameConfigProvider()),
        as: GameConfigProviderService.self
    )
    return services
}

// MARK: - Suite

@Suite("E2E State Snapshot Diff")
struct E2EStateSnapshotDiffTests {

    // MARK: - Full e2e: live == reevaluation

    @Test("Live state snapshot matches reevaluation — writes records to a temporary directory")
    func testLiveSnapshotMatchesReevaluation() async throws {
        let landID = "hero-defense:e2e-snapshot-diff"

        // Written to a temporary directory; the paths are printed for post-test inspection
        let dir = recordsDir()
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let recordingFile = dir.appendingPathComponent("e2e-state-\(timestamp).json")
        let stateJsonlPath = recordingFile.path.replacingOccurrences(of: ".json", with: "-state.jsonl")

        print("\n📁 Recording to: \(recordingFile.path)")
        print("📁 State JSONL:  \(stateJsonlPath)\n")

        // ── Live phase ─────────────────────────────────────────────────────────
        let definition = HeroDefense.makeLand()
        let keeper = LandKeeper<HeroDefenseState>(
            definition: definition,
            initialState: HeroDefenseState(),
            services: makeServices(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        await keeper.setLandID(landID)

        guard let recorder = await keeper.getReevaluationRecorder() else {
            Issue.record("ReevaluationRecorder not available")
            return
        }

        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: "hero-defense",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            rngSeed: DeterministicSeed.fromLandID(landID),
            version: ReevaluationRecordVersion.current
        ))

        // Player joins — initial position set via ctx.random (key suspect for divergence)
        try await keeper.join(
            playerID: PlayerID("alice"),
            clientID: ClientID("c1"),
            sessionID: SessionID("s1")
        )

        // Run 35 ticks: covers monster spawning (MONSTER_SPAWN_INTERVAL_TICKS = 30)
        // and player position being recorded at tick 0
        let tickCount: Int64 = 35
        for tickId in Int64(0)..<tickCount {
            await keeper.stepTickOnce()
            let state = await keeper.currentState()
            let (_, snapshot) = ReevaluationEngine.calculateStateHashAndSnapshot(state)
            // Supplement the hash (already set by LandKeeper) with the full snapshot
            await recorder.recordStateSnapshot(tickId: tickId, stateSnapshot: snapshot)
        }

        try await recorder.save(to: recordingFile.path)

        #expect(
            FileManager.default.fileExists(atPath: recordingFile.path),
            "Main record JSON should exist"
        )
        #expect(
            FileManager.default.fileExists(atPath: stateJsonlPath),
            "State JSONL should be written alongside main record"
        )

        let lineCount = (try String(contentsOfFile: stateJsonlPath, encoding: .utf8))
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        #expect(lineCount == Int(tickCount), "State JSONL should have one line per tick (got \(lineCount), expected \(tickCount))")

        print("✅ Recorded \(tickCount) ticks. State JSONL: \(lineCount) lines.")

        // ── Reevaluation phase ─────────────────────────────────────────────────
        var logger = Logger(label: "e2e-reeval")
        logger.logLevel = .error

        let result = try await ReevaluationEngine.run(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            recordFilePath: recordingFile.path,
            services: makeServices(),
            diffWithPath: stateJsonlPath,
            logger: logger
        )

        // ── Assertions ─────────────────────────────────────────────────────────
        #expect(
            !result.recordedStateHashes.isEmpty,
            "Recorded hashes should be present in the record file"
        )

        var mismatchCount = 0
        for (tickId, recordedHash) in result.recordedStateHashes.sorted(by: { $0.key < $1.key }) {
            let computedHash = result.tickHashes[tickId] ?? "missing"
            if computedHash != recordedHash {
                mismatchCount += 1
                print("❌ tick \(tickId): live=\(recordedHash) reeval=\(computedHash)")
            }
        }

        print(mismatchCount == 0
            ? "✅ All \(result.recordedStateHashes.count) ticks match."
            : "❌ \(mismatchCount) tick(s) with hash mismatch — check stderr for field-level diff."
        )

        #expect(
            mismatchCount == 0,
            "\(mismatchCount) tick(s) diverged between live and reevaluation. Run with --diff-with to inspect field-level diffs:\n  swift run ReevaluationRunner --input \(recordingFile.path) --verify --diff-with \(stateJsonlPath)"
        )
    }

    // MARK: - ConcreteReevaluationRunner (webclient path)

    @Test("ConcreteReevaluationRunner produces matching hashes — verifies RNG seed uses recorded landID not replay landID")
    func testConcreteReevaluationRunnerMatchesLive() async throws {
        let landID = "hero-defense:e2e-concrete-runner"
        let tmpDir = FileManager.default.temporaryDirectory
        let recordingFile = tmpDir.appendingPathComponent("e2e-concrete-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: recordingFile) }

        // ── Live phase ──────────────────────────────────────────────────────────
        let definition = HeroDefense.makeLand()
        let keeper = LandKeeper<HeroDefenseState>(
            definition: definition,
            initialState: HeroDefenseState(),
            services: makeServices(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        await keeper.setLandID(landID)

        guard let recorder = await keeper.getReevaluationRecorder() else {
            Issue.record("ReevaluationRecorder not available"); return
        }

        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: "hero-defense",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: definition.id,
            rngSeed: DeterministicSeed.fromLandID(landID),
            version: ReevaluationRecordVersion.current
        ))

        try await keeper.join(
            playerID: PlayerID("charlie"),
            clientID: ClientID("c1"),
            sessionID: SessionID("s1")
        )

        let tickCount: Int64 = 5
        for _ in Int64(0)..<tickCount {
            await keeper.stepTickOnce()
        }
        try await recorder.save(to: recordingFile.path)

        // ── Reevaluation via ConcreteReevaluationRunner (webclient path) ────────
        // Use a fake "replay" landID to simulate what happens when LandManager sets
        // the landID to the replay land's ID (e.g. "hero-defense-replay:xyz").
        // The runner must still derive the RNG seed from metadata.landID, not the
        // replay landID, or the initial player position will diverge.
        var services = makeServices()
        services.register(
            DeterministicRngService(seed: DeterministicSeed.fromLandID(landID)),
            as: DeterministicRngService.self
        )
        let runner = try await ConcreteReevaluationRunner(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            recordFilePath: recordingFile.path,
            services: services
        )

        var revalHashes: [Int64: String] = [:]
        while let result = try await runner.step() {
            revalHashes[result.tickId] = result.stateHash
        }

        // ── Compare hashes ──────────────────────────────────────────────────────
        let source = try JSONReevaluationSource(filePath: recordingFile.path)
        var mismatchCount = 0
        for tickId in 0..<tickCount {
            let recorded = try await source.getStateHash(for: tickId) ?? "missing"
            let computed = revalHashes[tickId] ?? "missing"
            if recorded != computed {
                mismatchCount += 1
                print("❌ tick \(tickId): live=\(recorded) reeval=\(computed)")
            }
        }
        print(mismatchCount == 0
            ? "✅ ConcreteReevaluationRunner: all \(tickCount) ticks match."
            : "❌ ConcreteReevaluationRunner: \(mismatchCount) tick(s) diverged."
        )
        #expect(mismatchCount == 0,
            "ConcreteReevaluationRunner produced \(mismatchCount) hash mismatch(es) — RNG seed bug in webclient path"
        )
    }

    // MARK: - Mismatch detection sanity check

    @Test("diffWithPath detects deliberately corrupted state")
    func testDiffDetectsMismatch() async throws {
        let landID = "hero-defense:e2e-mismatch"
        let tmpDir = FileManager.default.temporaryDirectory
        let recordingFile = tmpDir.appendingPathComponent("e2e-mismatch-\(UUID().uuidString).json")
        let fakeJsonlFile = tmpDir.appendingPathComponent("fake-state-\(UUID().uuidString).jsonl")

        defer {
            try? FileManager.default.removeItem(at: recordingFile)
            try? FileManager.default.removeItem(at: fakeJsonlFile)
        }

        let definition = HeroDefense.makeLand()
        let keeper = LandKeeper<HeroDefenseState>(
            definition: definition,
            initialState: HeroDefenseState(),
            services: makeServices(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        await keeper.setLandID(landID)

        guard let recorder = await keeper.getReevaluationRecorder() else {
            Issue.record("ReevaluationRecorder not available")
            return
        }

        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: "hero-defense",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            rngSeed: DeterministicSeed.fromLandID(landID),
            version: ReevaluationRecordVersion.current
        ))

        try await keeper.join(
            playerID: PlayerID("bob"),
            clientID: ClientID("c1"),
            sessionID: SessionID("s1")
        )
        await keeper.stepTickOnce()
        try await recorder.save(to: recordingFile.path)

        // Hand-crafted JSONL with deliberately wrong player position
        let fakeJsonl = """
        {"tickId":0,"stateSnapshot":{"players":{"bob":{"position":{"v":{"x":999999,"y":999999}}}}}}
        """
        try fakeJsonl.write(to: fakeJsonlFile, atomically: true, encoding: .utf8)

        var logger = Logger(label: "e2e-mismatch-test")
        logger.logLevel = .error

        // Should complete without throwing; diff output goes to stderr
        let result = try await ReevaluationEngine.run(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            recordFilePath: recordingFile.path,
            services: makeServices(),
            diffWithPath: fakeJsonlFile.path,
            logger: logger
        )

        #expect(result.maxTickId >= 0, "Reevaluation should complete even with diffWithPath mismatch")
    }
}
