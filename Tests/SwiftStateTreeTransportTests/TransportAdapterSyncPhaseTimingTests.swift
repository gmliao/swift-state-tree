// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncPhaseTimingTests.swift
//
// Sync phase timing: with transport profiling on, each sync plan times its snapshot
// extraction, its broadcast diff and its per-player diffs, and adds them to the profiler's
// per-window sums (`sync_extract_ms`, `sync_broadcast_ms`, `sync_perplayer_ms`, and
// `sync_combined_plans`). With profiling off the plan carries no timings.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct PhaseTimingState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    init() {}
}

@Payload
struct PhaseTimingBumpAction: ActionPayload {
    typealias Response = PhaseTimingBumpResponse
}

@Payload
struct PhaseTimingBumpResponse: ResponsePayload {
    let ok: Bool
}

private func phaseTimingLand(_ id: String) -> LandDefinition<PhaseTimingState> {
    Land(id, using: PhaseTimingState.self) {
        Rules {
            HandleAction(PhaseTimingBumpAction.self) { (state: inout PhaseTimingState, _: PhaseTimingBumpAction, ctx: LandContext) in
                state.round += 1
                state.scores[ctx.playerID, default: 0] += 1
                return PhaseTimingBumpResponse(ok: true)
            }
        }
    }
}

private func envConfig(profiling: TransportProfilingConfig?) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: true,
        syncStrategy: .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: false,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: 30,
        profilingConfig: profiling
    )
}

/// Joins one player, changes the state, and runs one sync cycle; returns the adapter.
private func runOneCycle(_ id: String, profiling: TransportProfilingConfig?) async throws -> TransportAdapter<PhaseTimingState> {
    let transport = BlockingTransport()
    let keeper = LandKeeper<PhaseTimingState>(definition: phaseTimingLand(id), initialState: PhaseTimingState())
    let adapter = TransportAdapter<PhaseTimingState>(
        keeper: keeper,
        transport: transport,
        landID: id,
        transportEnvConfig: envConfig(profiling: profiling),
        encodingConfig: .messagepack
    )
    await transport.setDelegate(adapter)
    let session = SessionID("\(id)-session")
    let client = ClientID("\(id)-client")
    let player = PlayerID("\(id)-player")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
    try await waitUntilTransportIdle(transport)
    let envelope = ActionEnvelope(
        typeIdentifier: String(describing: PhaseTimingBumpAction.self),
        payload: AnyCodable(PhaseTimingBumpAction())
    )
    _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
    await adapter.syncNow()
    return adapter
}

@Suite("TransportAdapter sync phase timing", .timeLimit(.minutes(1)))
struct TransportAdapterSyncPhaseTimingTests {
    @Test("Profiling off: a committed sync plan carries no phase times")
    func offWritesNoPhaseTimes() async throws {
        let adapter = try await runOneCycle("phase-timing-off", profiling: nil)
        #expect(await adapter.lastSyncPhaseTimesForTesting == nil)
    }

    @Test("Profiling on: a sync plan times extraction, the broadcast diff and the per-player diffs")
    func onTimesPhases() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-timing-\(UUID().uuidString).jsonl").path
        let profiling = TransportProfilingConfig(jsonlPath: path, intervalMs: 60_000, sampleRate: 1, maxSamplesPerInterval: 10)
        let adapter = try await runOneCycle("phase-timing-on", profiling: profiling)
        let times = try #require(await adapter.lastSyncPhaseTimesForTesting)
        #expect(times.extract >= .zero)
        #expect(times.broadcast >= .zero)
        #expect(times.perPlayer >= .zero)
    }

    @Test("The counters sum each window's phase times, count the plans and the combined-path ones, then reset")
    func countersSumPerWindow() {
        let counters = TransportProfilerCounters()
        counters.addSyncPhaseTimes(extract: .microseconds(100), broadcast: .microseconds(300), perPlayer: .microseconds(700), combined: false)
        counters.addSyncPhaseTimes(extract: .microseconds(100), broadcast: .microseconds(100), perPlayer: .microseconds(300), combined: true)
        let window = counters.takeAndResetSyncPhaseTimes()
        #expect(window.plans == 2)
        #expect(window.extractMs == 0.2)
        #expect(window.broadcastMs == 0.4)
        #expect(window.perPlayerMs == 1.0)
        #expect(window.combinedPlans == 1, "only the combined-path plan")
        #expect(counters.takeAndResetSyncPhaseTimes().plans == 0, "reset per window")
    }
}
