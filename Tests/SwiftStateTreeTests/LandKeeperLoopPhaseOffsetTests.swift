// Tests/SwiftStateTreeTests/LandKeeperLoopPhaseOffsetTests.swift
//
// Per-land phase offset of the keeper's tick and sync loops: lands created together must not
// run their loops in phase.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct PhaseOffsetTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
}

/// Tick instants recorded from the tick handler.
private final class TickInstants: @unchecked Sendable {
    private let lock = NSLock()
    private var instants: [ContinuousClock.Instant] = []

    func append(_ instant: ContinuousClock.Instant) {
        lock.lock()
        instants.append(instant)
        lock.unlock()
    }

    var all: [ContinuousClock.Instant] {
        lock.lock()
        defer { lock.unlock() }
        return instants
    }
}

private func phaseOffsetLand(tick interval: Duration, recorder: TickInstants) -> LandDefinition<PhaseOffsetTestState> {
    Land("phase-offset-test", using: PhaseOffsetTestState.self) {
        Rules {}
        Lifetime {
            Tick(every: interval) { (state: inout PhaseOffsetTestState, _) in
                recorder.append(ContinuousClock.now)
                state.ticks += 1
            }
            StateSync(every: interval) { (_: PhaseOffsetTestState, _: LandContext) in }
        }
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@Suite("LandKeeper loop phase offset")
struct LandKeeperLoopPhaseOffsetTests {
    @Test("The offset is FNV-1a of the land ID modulo the interval, the same in every process")
    func offsetIsProcessStable() {
        // Expected values are FNV-1a 64 over the UTF-8 bytes, computed outside Swift, so a
        // per-process seeded hash (`Hasher`) would fail here.
        #expect(LandLoopPhase.offset(landID: "hero-defense:room-1", interval: .milliseconds(100)) == .nanoseconds(34_994_091))
        #expect(LandLoopPhase.offset(landID: "counter:550e8400-e29b-41d4-a716-446655440000", interval: .milliseconds(100)) == .nanoseconds(88_547_430))
        #expect(LandLoopPhase.offset(landID: "counter:550e8400-e29b-41d4-a716-446655440000", interval: .milliseconds(50)) == .nanoseconds(38_547_430))
        #expect(
            LandLoopPhase.offset(landID: "hero-defense:room-1", interval: .milliseconds(100))
                == LandLoopPhase.offset(landID: "hero-defense:room-1", interval: .milliseconds(100))
        )
    }

    @Test("The offset is inside [0, interval) and spreads lands over the interval")
    func offsetIsInRangeAndSpread() {
        let interval = Duration.milliseconds(100)
        var buckets = Set<Int>()
        for index in 0..<500 {
            let offset = LandLoopPhase.offset(landID: "hero-defense:\(UUID().uuidString)-\(index)", interval: interval)
            #expect(offset >= .zero)
            #expect(offset < interval)
            buckets.insert(Int(milliseconds(offset)) / 10)
        }
        // 500 lands over ten 10 ms buckets: every bucket is hit.
        #expect(buckets.count == 10)
    }

    @Test("A zero or negative interval gives no offset")
    func nonPositiveIntervalGivesZero() {
        #expect(LandLoopPhase.offset(landID: "x", interval: .zero) == .zero)
        #expect(LandLoopPhase.offset(landID: "x", interval: .milliseconds(-5)) == .zero)
    }

    @Test("The first tick waits for the land's offset; the period after it is unchanged")
    func firstTickIsDelayedAndPeriodIsKept() async throws {
        let interval = Duration.milliseconds(100)
        let landID = "counter:550e8400-e29b-41d4-a716-446655440000"  // offset 88.5 ms
        let offset = LandLoopPhase.offset(landID: landID, interval: interval)
        let recorder = TickInstants()
        let keeper = LandKeeper<PhaseOffsetTestState>(
            definition: phaseOffsetLand(tick: interval, recorder: recorder),
            initialState: PhaseOffsetTestState(),
            enableLoopPhaseOffset: true
        )
        await keeper.setLandID(landID)

        let start = ContinuousClock.now
        try await keeper.join(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))
        let deadline = ContinuousClock.now + .seconds(5)
        while recorder.all.count < 6, ContinuousClock.now < deadline {
            try await safeTaskSleep(for: .milliseconds(10))
        }
        try await keeper.leave(playerID: PlayerID("p"), clientID: ClientID("c"))

        let ticks = recorder.all
        try #require(ticks.count >= 6, "expected at least 6 ticks, got \(ticks.count)")
        // First tick: the offset, then one interval (5 ms slack for clock granularity).
        #expect(ticks[0] - start >= offset + interval - .milliseconds(5), "first tick after \(ticks[0] - start)")
        // Fixed rate after the first tick: the span of five periods stays close to 5 × interval.
        let span = milliseconds(ticks[5] - ticks[0])
        #expect(span >= 480 && span <= 650, "five periods took \(span) ms")
    }

    @Test("With the offset disabled, the keeper applies none")
    func disabledAppliesNoOffset() async {
        let recorder = TickInstants()
        let keeper = LandKeeper<PhaseOffsetTestState>(
            definition: phaseOffsetLand(tick: .milliseconds(100), recorder: recorder),
            initialState: PhaseOffsetTestState(),
            enableLoopPhaseOffset: false
        )
        await keeper.setLandID("counter:550e8400-e29b-41d4-a716-446655440000")
        #expect(await keeper.loopPhaseOffset(interval: .milliseconds(100)) == .zero)
    }

    @Test("A re-evaluation keeper applies no offset (replay timing is unchanged)")
    func reevaluationAppliesNoOffset() async {
        let keeper = LandKeeper<PhaseOffsetTestState>(
            definition: phaseOffsetLand(tick: .milliseconds(100), recorder: TickInstants()),
            initialState: PhaseOffsetTestState(),
            mode: .reevaluation,
            autoStartLoops: false,
            enableLoopPhaseOffset: true
        )
        await keeper.setLandID("counter:550e8400-e29b-41d4-a716-446655440000")
        #expect(await keeper.loopPhaseOffset(interval: .milliseconds(100)) == .zero)
    }

    @Test("The opt-out env var turns the default off")
    func envOptOut() {
        #expect(LandLoopPhase.isEnabled(environment: [:]) == true)
        #expect(LandLoopPhase.isEnabled(environment: [EnvKeys.Runtime.landLoopPhaseOffset: "false"]) == false)
        #expect(LandLoopPhase.isEnabled(environment: [EnvKeys.Runtime.landLoopPhaseOffset: "0"]) == false)
        #expect(LandLoopPhase.isEnabled(environment: [EnvKeys.Runtime.landLoopPhaseOffset: "true"]) == true)
    }
}
