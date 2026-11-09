// Tests/SwiftStateTreeTransportTests/AutoDirtySamplingTests.swift
//
// Auto dirty tracking measures the change rate on one sync in AUTO_DIRTY_SAMPLE_EVERY (#391).
// The EMA weight and the required samples are scaled so a switch takes about as many syncs as
// when every sync is measured; the syncs in between skip the metric work; and since dirty
// tracking on and off send the same bytes (DirtyTrackingByteIdentityTests), sampling changes no
// frame.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

private func samplingConfig(
    dirtyTracking: Bool,
    autoDirtyTracking: Bool = true,
    changeObjectMetrics: Bool = false,
    sampleEvery: Int
) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: dirtyTracking,
        useSnapshotForSync: true,
        syncStrategy: .delta,
        enableChangeObjectMetrics: changeObjectMetrics,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: autoDirtyTracking,
        // The calculator counts the extracted snapshot's top-level fields, with a map of scalars,
        // an empty map and a nested node as one object each. This state has six broadcast fields:
        // with dirty tracking off, the busy step changes three (0.5) and the quiet step two
        // (0.33); with it on, only the dirty fields are extracted, all scalar here, so the rate is
        // 1. These thresholds put the quiet step below the on threshold and the busy step above it.
        autoDirtyOffThreshold: 0.9,
        autoDirtyOnThreshold: 0.4,
        autoDirtyRequiredConsecutiveSamples: 30,
        profilingConfig: nil,
        autoDirtySampleEvery: sampleEvery
    )
}

/// High change rate: the round, the title and every player's position.
private func busyStep(_ run: DirtyIdentityRun, _ round: Int) async throws {
    try await run.step(1, move: 1, title: "b\(round)")
}

/// Low change rate: the round and the title.
private func quietStep(_ run: DirtyIdentityRun, _ round: Int) async throws {
    try await run.step(1, title: "q\(round)")
}

/// Syncs, each after `step`, until dirty tracking is `target` (nil after `limit` syncs).
private func syncsUntil(
    _ target: Bool,
    _ run: DirtyIdentityRun,
    limit: Int = 80,
    step: (DirtyIdentityRun, Int) async throws -> Void
) async throws -> Int? {
    for index in 1...limit {
        try await step(run, index)
        await run.sync()
        if await run.adapter.dirtyTrackingEnabledForTesting() == target { return index }
    }
    return nil
}

private func joinedRun(_ config: TransportEnvConfig) async throws -> DirtyIdentityRun {
    let run = await DirtyIdentityRun(envConfig: config, encoding: .messagepack)
    for n in 1...3 { try await run.join(n) }
    await run.sync()
    return run
}

@Suite("Auto dirty tracking samples one sync in N (#391)", .timeLimit(.minutes(1)))
struct AutoDirtySamplingTests {
    @Test("The EMA weight and the required samples are scaled to the interval")
    func scaling() {
        let every8 = DirtyTrackingSampling(every: 8)
        #expect(abs(every8.sampledAlpha(0.2) - (1 - pow(0.8, 8))) < 1e-12)
        #expect(every8.requiredSamples(forSyncs: 30) == 4)
        #expect(every8.requiredSamples(forSyncs: 1) == 1)
        #expect((0..<17).filter { every8.isSample(syncIndex: UInt64($0)) } == [0, 8, 16])

        let every1 = DirtyTrackingSampling(every: 1)
        #expect(every1.sampledAlpha(0.2) == 0.2)
        #expect(every1.requiredSamples(forSyncs: 30) == 30)
        #expect(DirtyTrackingSampling(every: 0).every == 1)
        #expect(TransportEnvConfig.defaultAutoDirtySampleEvery == 1)
        #expect(samplingConfig(dirtyTracking: true, sampleEvery: -3).autoDirtySampleEvery == 1)
    }

    @Test("The interval is clamped to 1...1024")
    func intervalIsClamped() {
        #expect(samplingConfig(dirtyTracking: true, sampleEvery: 1024).autoDirtySampleEvery == 1024)
        #expect(samplingConfig(dirtyTracking: true, sampleEvery: 1025).autoDirtySampleEvery == 1024)
        #expect(samplingConfig(dirtyTracking: true, sampleEvery: .max).autoDirtySampleEvery == 1024)
        #expect(DirtyTrackingSampling(every: .max).every == 1024)
        // `fromEnvironment` reads the process environment and applies the same clamp.
        #expect(TransportEnvConfig.clampedAutoDirtySampleEvery(.max) == 1024)
        #expect(TransportEnvConfig.clampedAutoDirtySampleEvery(.min) == 1)
        // At the bound, the scaling is still finite and the ceiling doesn't overflow.
        let widest = DirtyTrackingSampling(every: 1024)
        #expect(widest.sampledAlpha(0.2) <= 1 && widest.sampledAlpha(0.2) > 0.99)
        #expect(widest.requiredSamples(forSyncs: .max) == Int.max / 1024 + 1)
        #expect(widest.requiredSamples(forSyncs: 30) == 1)
    }

    @Test("Off-sample syncs collect no change metrics", arguments: [(1, 16), (8, 2), (5, 4)])
    func offSampleSyncsCollectNothing(sampleEvery: Int, expectedSamples: UInt64) async throws {
        for (auto, metrics) in [(true, false), (false, true)] {
            let run = await DirtyIdentityRun(
                envConfig: samplingConfig(dirtyTracking: true, autoDirtyTracking: auto, changeObjectMetrics: metrics, sampleEvery: sampleEvery),
                encoding: .messagepack
            )
            try await run.join(1)
            // The join's sync (if any) is counted; measure from here.
            let before = await run.adapter.changeMetricsSamplesForTesting()
            let syncsBefore = before == 0 ? 0 : 1
            for round in 1...(16 - syncsBefore) {
                try await quietStep(run, round)
                await run.sync()
            }
            #expect(await run.adapter.changeMetricsSamplesForTesting() == expectedSamples, "auto=\(auto) metrics=\(metrics)")
        }
        let off = await DirtyIdentityRun(
            envConfig: samplingConfig(dirtyTracking: true, autoDirtyTracking: false, changeObjectMetrics: false, sampleEvery: 1),
            encoding: .messagepack
        )
        try await off.join(1)
        for round in 1...4 { try await quietStep(off, round); await off.sync() }
        #expect(await off.adapter.changeMetricsSamplesForTesting() == 0, "no metrics without auto dirty tracking or change-object metrics")
    }

    @Test("A switch takes about as many syncs sampled as measured every sync, in both directions")
    func flipLatencyInBothDirections() async throws {
        var latencies: [Int: (off: Int, on: Int)] = [:]
        for sampleEvery in [1, 8] {
            let run = try await joinedRun(samplingConfig(dirtyTracking: true, sampleEvery: sampleEvery))
            let off = try #require(try await syncsUntil(false, run, step: busyStep), "every \(sampleEvery): switched off")
            let on = try #require(try await syncsUntil(true, run, step: quietStep), "every \(sampleEvery): switched on")
            latencies[sampleEvery] = (off, on)
        }
        let every1 = try #require(latencies[1]), every8 = try #require(latencies[8])
        // Measured every sync: 30 consecutive syncs past the threshold. Off counts the joins'
        // sync as the first, so it switches after 29 more; on needs a few syncs for the EMA to
        // fall below the on threshold first.
        #expect(every1.off >= 29 && every1.off <= 31, "every sync, off after \(every1.off)")
        #expect(every1.on >= 30 && every1.on <= 40, "every sync, on after \(every1.on)")
        // Sampled: within one interval of each side's syncs (4 samples of 8 syncs).
        #expect(abs(every8.off - every1.off) <= 8, "sampled off after \(every8.off), every sync \(every1.off)")
        #expect(abs(every8.on - every1.on) <= 8, "sampled on after \(every8.on), every sync \(every1.on)")
        #expect(every8.off >= 17, "a switch still takes several samples: off after \(every8.off)")
        #expect(every8.on >= 17, "a switch still takes several samples: on after \(every8.on)")
    }

    @Test("Sampled and every-sync auto dirty tracking send identical frames across switches")
    func sampledAndEverySyncSendIdenticalFrames() async throws {
        var frames: [[(target: String, data: Data)]] = []
        for sampleEvery in [1, 8] {
            let run = try await joinedRun(samplingConfig(dirtyTracking: true, sampleEvery: sampleEvery))
            var switches = 0
            var mode = true
            for round in 1...50 {
                try await busyStep(run, round)
                await run.sync()
                let now = await run.adapter.dirtyTrackingEnabledForTesting()
                if now != mode { switches += 1; mode = now }
            }
            for round in 1...50 {
                try await quietStep(run, round)
                await run.sync()
                let now = await run.adapter.dirtyTrackingEnabledForTesting()
                if now != mode { switches += 1; mode = now }
            }
            #expect(switches == 2, "every \(sampleEvery): switched off and back on")
            frames.append(await run.transport.sent)
        }
        expectSameFrames(frames[0], frames[1], "every 1 vs every 8")
    }
}
