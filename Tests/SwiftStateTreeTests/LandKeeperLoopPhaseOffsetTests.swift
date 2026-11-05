// Tests/SwiftStateTreeTests/LandKeeperLoopPhaseOffsetTests.swift
//
// Per-land phase offset of the keeper's tick and sync loops: lands created together must not
// run their loops in phase. The tick loop's offset and period are checked exactly on a manual
// clock; one wall-clock test is a loose smoke check of the real clock.

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

private func phaseOffsetLand(
    tick interval: Duration,
    recorder: TickInstants,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
) -> LandDefinition<PhaseOffsetTestState> {
    Land("phase-offset-test", using: PhaseOffsetTestState.self) {
        Rules {}
        Lifetime {
            Tick(every: interval) { (state: inout PhaseOffsetTestState, _) in
                recorder.append(now())
                state.ticks += 1
            }
            StateSync(every: interval) { (_: PhaseOffsetTestState, _: LandContext) in }
        }
    }
}

/// A clock that moves only when the test advances it. Each sleep the loop starts is reported in
/// order (`nextSleep()`), so the test waits for the loop to reach its next sleep (no timing)
/// and then advances to that deadline, which resumes it.
private final class ManualTickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ContinuousClock.Instant
    private var sleepers: [UInt64: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextSleeperID: UInt64 = 0
    /// Deadlines of sleeps started and not yet taken by `nextSleep()`.
    private var reported: [ContinuousClock.Instant] = []
    private var reportWaiter: CheckedContinuation<ContinuousClock.Instant, Never>?

    init(start: ContinuousClock.Instant) {
        current = start
    }

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var tickLoopClock: TickLoopClock {
        TickLoopClock(
            now: { self.now },
            sleepFor: { await self.sleep(until: self.now + $0) },
            sleepUntil: { await self.sleep(until: $0) }
        )
    }

    /// Moves the clock to `instant` and resumes the sleeps due by then.
    func advance(to instant: ContinuousClock.Instant) {
        lock.lock()
        current = max(current, instant)
        let due = sleepers.filter { $0.value.deadline <= current }
        for id in due.keys { sleepers[id] = nil }
        lock.unlock()
        for sleeper in due.values { sleeper.continuation.resume() }
    }

    /// The deadline of the next sleep the loop starts (waits for it), or nil after 5 s: a
    /// failure guard, not a timing bound.
    func nextSleep() async -> ContinuousClock.Instant? {
        let outcome = await raceDeadline(.seconds(5)) {
            await withCheckedContinuation { (continuation: CheckedContinuation<ContinuousClock.Instant, Never>) in
                self.lock.lock()
                if !self.reported.isEmpty {
                    let deadline = self.reported.removeFirst()
                    self.lock.unlock()
                    continuation.resume(returning: deadline)
                    return
                }
                self.reportWaiter = continuation
                self.lock.unlock()
            }
        }
        guard case let .finished(.success(deadline)) = outcome else { return nil }
        return deadline
    }

    private func sleep(until deadline: ContinuousClock.Instant) async {
        let id = lock.withLock {
            nextSleeperID += 1
            return nextSleeperID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if deadline <= current || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = (deadline, continuation)
                let waiter = reportWaiter
                reportWaiter = nil
                if waiter == nil { reported.append(deadline) }
                lock.unlock()
                waiter?.resume(returning: deadline)
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            lock.unlock()
            sleeper?.continuation.resume()
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

    @Test("A zero or negative interval gives no offset, and extreme intervals do not trap")
    func nonPositiveIntervalGivesZero() {
        #expect(LandLoopPhase.offset(landID: "x", interval: .zero) == .zero)
        #expect(LandLoopPhase.offset(landID: "x", interval: .milliseconds(-5)) == .zero)
        #expect(LandLoopPhase.offset(landID: "x", interval: .seconds(Int64.min)) == .zero)
        let huge = LandLoopPhase.offset(landID: "x", interval: .seconds(Int64.max))
        #expect(huge >= .zero && huge < LandLoopPhase.maxOffset)
    }

    @Test("A slow loop is delayed by at most maxOffset, not by up to a whole interval")
    func offsetIsBoundedForSlowLoops() {
        // Same as the 100 ms window: FNV-1a("hero-defense:room-1") % 100 ms.
        #expect(LandLoopPhase.offset(landID: "hero-defense:room-1", interval: .seconds(30)) == .nanoseconds(34_994_091))
        for index in 0..<200 {
            let offset = LandLoopPhase.offset(landID: "timer:\(index)", interval: .seconds(30))
            #expect(offset >= .zero && offset < LandLoopPhase.maxOffset)
        }
    }

    @Test("Manual clock: the first tick waits for the offset, then one interval; later ticks are one interval apart")
    func firstTickIsDelayedAndPeriodIsKept() async throws {
        let interval = Duration.milliseconds(100)
        let landID = "counter:550e8400-e29b-41d4-a716-446655440000"  // offset 88.5 ms
        let offset = LandLoopPhase.offset(landID: landID, interval: interval)
        let recorder = TickInstants()
        let clock = ManualTickClock(start: ContinuousClock.now)
        let t0 = clock.now
        // The instance ID goes in through init, so the loops cannot start with the type's offset.
        let keeper = TickLoopClock.$forNewKeepers.withValue(clock.tickLoopClock) {
            LandKeeper<PhaseOffsetTestState>(
                definition: phaseOffsetLand(tick: interval, recorder: recorder, now: { clock.now }),
                initialState: PhaseOffsetTestState(),
                enableLoopPhaseOffset: true,
                landID: landID
            )
        }
        try await keeper.join(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))

        // The loop's first sleep is the offset, from the instant it was configured.
        let offsetEnd = try #require(await clock.nextSleep(), "the loop never slept for its offset")
        #expect(await keeper.appliedTickPhaseOffset == offset)
        #expect(await keeper.tickLoopConfiguredAt == t0)
        #expect(offsetEnd == t0 + offset)
        clock.advance(to: offsetEnd)

        // Then one interval to the first tick, and one interval between ticks.
        var deadline = try #require(await clock.nextSleep(), "no first tick deadline")
        #expect(deadline == t0 + offset + interval)
        for k in 0..<5 {
            clock.advance(to: deadline)
            let next = try #require(await clock.nextSleep(), "no deadline after tick \(k)")
            #expect(next == deadline + interval, "tick \(k)")
            deadline = next
        }
        #expect(recorder.all == (0..<5).map { t0 + offset + interval * ($0 + 1) })

        // A tick that runs late (2.5 intervals past its deadline) is followed by the next
        // deadline on the grid, skipping the ones already past, not by catch-up ticks.
        let late = deadline + interval * 2 + interval / 2
        clock.advance(to: late)
        let afterLate = try #require(await clock.nextSleep(), "no deadline after the late tick")
        #expect(afterLate == deadline + interval * 3)
        #expect(recorder.all.count == 6)
        #expect(recorder.all.last == late)

        try await keeper.leave(playerID: PlayerID("p"), clientID: ClientID("c"))
        await keeper.forceShutdown()
    }

    @Test("Real clock smoke: ticks run, and the first waits at least the offset and one interval")
    func realClockSmoke() async throws {
        let interval = Duration.milliseconds(100)
        let landID = "counter:550e8400-e29b-41d4-a716-446655440000"
        let offset = LandLoopPhase.offset(landID: landID, interval: interval)
        let recorder = TickInstants()
        let start = ContinuousClock.now
        let keeper = LandKeeper<PhaseOffsetTestState>(
            definition: phaseOffsetLand(tick: interval, recorder: recorder),
            initialState: PhaseOffsetTestState(),
            enableLoopPhaseOffset: true,
            landID: landID
        )
        try await keeper.join(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))
        let deadline = ContinuousClock.now + .seconds(5)
        while recorder.all.count < 3, ContinuousClock.now < deadline {
            try await safeTaskSleep(for: .milliseconds(10))
        }
        try await keeper.leave(playerID: PlayerID("p"), clientID: ClientID("c"))

        let ticks = recorder.all
        try #require(ticks.count >= 3, "expected at least 3 ticks in 5 s, got \(ticks.count)")
        #expect(await keeper.appliedTickPhaseOffset == offset)
        // Lower bounds only (a loaded runner makes ticks late, never early); 5 ms slack for
        // clock granularity. The exact schedule is the manual-clock test's.
        let loopStart = try #require(await keeper.tickLoopConfiguredAt)
        #expect(loopStart >= start)
        #expect(ticks[0] - loopStart >= offset + interval - .milliseconds(5), "first tick \(ticks[0] - loopStart) after the loop started (offset \(offset))")
    }

    @Test("A land ID passed to init seeds the default RNG and is the land's ID from the start")
    func initLandIDSeedsRng() async {
        let landID = "counter:550e8400-e29b-41d4-a716-446655440000"
        let keeper = LandKeeper<PhaseOffsetTestState>(
            definition: phaseOffsetLand(tick: .milliseconds(100), recorder: TickInstants()),
            initialState: PhaseOffsetTestState(),
            autoStartLoops: false,
            landID: landID
        )
        #expect(await keeper.getRngSeed() == DeterministicSeed.fromLandID(landID))
        #expect(await keeper.loopPhaseOffset(interval: .milliseconds(100)) == LandLoopPhase.offset(landID: landID, interval: .milliseconds(100)))
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
