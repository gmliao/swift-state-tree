// Tests/SwiftStateTreeTests/ReplayRecordedRngSeedTests.swift
//
// A replay uses the record's RNG seed (#573): a live land whose RNG service was given a seed of
// its own records that seed, and the engine and the hosted runner replay with it, not with the
// seed derived from the land ID.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

@StateNodeBuilder
struct RngSeedReplayState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    @Sync(.broadcast)
    var drawn: Int = 0

    public init() {}
}

private let rngSeedReplayLandID = "rng-seed-replay:local"

/// Each tick draws a number from the land's RNG into the state.
private func makeRngSeedReplayLand() -> LandDefinition<RngSeedReplayState> {
    Land("rng-seed-replay", using: RngSeedReplayState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                state.drawn = ctx.random.nextInt(in: 0...1_000_000)
            }
        }
    }
}

/// Runs three ticks live with state hashes recorded, saves the record to `path`, and returns the
/// seed the live land used. `seed`: the live RNG service's own seed; nil for the default.
/// `recordsSeed`: false writes a record without `rngSeed`, as older records were.
private func recordRngSeedLand(seed: UInt64?, recordsSeed: Bool = true, path: String) async throws -> UInt64? {
    var services = LandServices()
    if let seed {
        services.register(DeterministicRngService(seed: seed), as: DeterministicRngService.self)
    }
    let keeper = LandKeeper<RngSeedReplayState>(
        definition: makeRngSeedReplayLand(),
        initialState: RngSeedReplayState(),
        services: services,
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: rngSeedReplayLandID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.awaitInitialization()
    let liveSeed = await keeper.getRngSeed()
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: rngSeedReplayLandID,
        landType: "rng-seed-replay",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "rng-seed-replay",
        rngSeed: recordsSeed ? liveSeed : nil
    ))
    for _ in 0..<3 {
        await keeper.stepTickOnce()
    }
    await keeper.waitForRecorderSubmissionsForTesting()
    try await recorder.save(to: path)
    return liveSeed
}

/// The seeds a record can hold: the default (the landID-derived one), a configured one, and none
/// (the live land used the default; the replay falls back to the landID-derived seed).
enum RecordedRngSeed: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case landIDDerived
    case configured
    case notRecorded

    var liveSeed: UInt64? { self == .configured ? 42 : nil }
    var recordsSeed: Bool { self != .notRecorded }
    var testDescription: String { rawValue }
}

@Suite("A replay uses the record's RNG seed (#573)")
struct ReplayRecordedRngSeedTests {
    func recordPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("rng-seed-replay-\(UUID().uuidString).sstr").path
    }

    @Test("The engine's replayed state hashes match the live ones", arguments: RecordedRngSeed.allCases)
    func engineReplaysWithTheRecordedSeed(seed: RecordedRngSeed) async throws {
        let path = recordPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let liveSeed = try await recordRngSeedLand(seed: seed.liveSeed, recordsSeed: seed.recordsSeed, path: path)
        #expect(liveSeed == (seed.liveSeed ?? DeterministicSeed.fromLandID(rngSeedReplayLandID)))
        let metadata = try await ReevaluationRecordFile.openSource(filePath: path).getMetadata()
        #expect(metadata.rngSeed == (seed.recordsSeed ? liveSeed : nil))
        #expect(metadata.replayRngSeed == liveSeed)

        let result = try await ReevaluationEngine.run(
            definition: makeRngSeedReplayLand(), initialState: RngSeedReplayState(), recordFilePath: path
        )
        #expect(result.recordedStateHashes.count == 3)
        let diverged = result.recordedStateHashes.filter { result.tickHashes[$0.key] != $0.value }.keys.sorted()
        #expect(diverged.isEmpty, "ticks whose replayed hash differs from the live one: \(diverged)")
    }

    @Test("A caller's RNG service with another seed is replaced by the record's seed")
    func engineReplacesTheCallersSeed() async throws {
        let path = recordPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await recordRngSeedLand(seed: 42, path: path)

        var services = LandServices()
        services.register(DeterministicRngService(seed: 7), as: DeterministicRngService.self)
        let result = try await ReevaluationEngine.run(
            definition: makeRngSeedReplayLand(), initialState: RngSeedReplayState(), recordFilePath: path,
            services: services
        )
        let diverged = result.recordedStateHashes.filter { result.tickHashes[$0.key] != $0.value }.keys.sorted()
        #expect(!result.recordedStateHashes.isEmpty)
        #expect(diverged.isEmpty, "ticks whose replayed hash differs from the live one: \(diverged)")
    }

    @Test("The hosted runner's steps match the live state hashes", arguments: RecordedRngSeed.allCases, [false, true])
    func runnerReplaysWithTheRecordedSeed(seed: RecordedRngSeed, withInitialState: Bool) async throws {
        let path = recordPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await recordRngSeedLand(seed: seed.liveSeed, recordsSeed: seed.recordsSeed, path: path)

        // Both initializers: one builds its own services, the other takes the caller's.
        let runner = withInitialState
            ? try await ConcreteReevaluationRunner(
                definition: makeRngSeedReplayLand(), initialState: RngSeedReplayState(), recordFilePath: path,
                services: {
                    var services = LandServices()
                    services.register(DeterministicRngService(seed: 7), as: DeterministicRngService.self)
                    return services
                }()
            )
            : try await ConcreteReevaluationRunner(definition: makeRngSeedReplayLand(), recordFilePath: path)
        var steps = 0
        while let step = try await runner.step() {
            steps += 1
            #expect(step.recordedHash != nil, "tick \(step.tickId)")
            #expect(step.isMatch, "tick \(step.tickId): replayed \(step.stateHash), recorded \(step.recordedHash ?? "none")")
        }
        #expect(steps == 3)
    }
}
