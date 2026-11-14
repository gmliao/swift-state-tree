// Tests/SwiftStateTreeTests/InTurnSyncFoldReportTests.swift
//
// The keeper reports each in-turn sync fold to its transport (`noteInTurnSyncFold`) when the tick
// turn that carries it starts, once per turn (#232): overdue when the tick's deadline had passed
// at the fold, and with the turn's lateness against that deadline. Only when the transport
// records folds (`recordsInTurnSyncFolds`, read when the transport is attached).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct FoldReportState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

/// Ticks and syncs hourly: the loops exist (the fold needs a tick task) but never fire.
private func foldReportLand() -> LandDefinition<FoldReportState> {
    Land("fold-report-test", using: FoldReportState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout FoldReportState, _: LandContext) in
                state.ticks += 1
            }
            StateSync(every: .seconds(3600)) { (_: FoldReportState, _: LandContext) in }
        }
    }
}

/// In-turn transport that records the folds it is told about.
private final class FoldRecordingTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [InTurnSyncFold] = []
    private var deferNextSyncs = 0
    private var syncPhases: [InTurnSyncResult] = []
    let records: Bool

    init(records: Bool) { self.records = records }

    var folds: [InTurnSyncFold] { lock.withLock { notes } }
    /// What each sync phase the keeper ran returned.
    var syncResults: [InTurnSyncResult] { lock.withLock { syncPhases } }

    /// The next `count` sync phases defer on writer back-pressure.
    func deferNext(_ count: Int) { lock.withLock { deferNextSyncs = count } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    var recordsInTurnSyncFolds: Bool { records }
    func noteInTurnSyncFold(_ fold: InTurnSyncFold) { lock.withLock { notes.append(fold) } }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(syncPhaseResult(state: state, events: events, includeSync: includeSync))
    }

    private func syncPhaseResult<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        guard includeSync else { return .notRequested }
        return lock.withLock {
            let result: InTurnSyncResult
            if deferNextSyncs > 0 {
                deferNextSyncs -= 1
                result = .deferredBackPressure
            } else {
                result = .committed(clearDirtyFlags: true)
            }
            syncPhases.append(result)
            return result
        }
    }
}

/// A tick-loop clock on real time that reports the loop's first `sleepUntil`. The loop
/// publishes its first tick deadline (`noteNextTickDeadline`) in its own task, just before that
/// sleep; a test that set the deadline before then could have it overwritten by the loop's
/// (now + 1 h), and the next sync would then not fold. Once the sleep is reported, the loop
/// writes no deadline until the hour has passed. The sleep is real and ends on shutdown.
private final class FirstTickSleepSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var tickLoopClock: TickLoopClock {
        TickLoopClock(
            now: { ContinuousClock.now },
            sleepFor: { try? await safeTaskSleep(for: $0) },
            sleepUntil: { deadline in
                self.markReached()
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
        )
    }

    private func markReached() {
        lock.lock()
        reached = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in resumed { waiter.resume() }
    }

    /// Returns once the tick loop has started its first sleep (at once if it has).
    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if reached {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// The land's coincident-sync window: min(5 ms, tick / 4, sync / 4) with hourly loops.
private let window = Duration.milliseconds(5)

@Suite("In-turn sync: folds reported to the transport", .timeLimit(.minutes(1)))
struct InTurnSyncFoldReportTests {
    private func makeKeeper(_ transport: FoldRecordingTransport) async throws -> LandKeeper<FoldReportState> {
        let signal = FirstTickSleepSignal()
        let keeper = TickLoopClock.$forNewKeepers.withValue(signal.tickLoopClock) {
            LandKeeper<FoldReportState>(
                definition: foldReportLand(),
                initialState: FoldReportState(),
                enableLoopPhaseOffset: false,
                transport: transport
            )
        }
        #expect(await keeper.isUsingInTurnSync())
        try await Self.waitForLoops(keeper, signal)
        return keeper
    }

    /// The keeper initializes, and starts its loops, on the first join; the fold needs the tick
    /// task. Waits for the initialization, then for the tick loop's first sleep, after which the
    /// loop no longer writes the tick deadline the tests set (`FirstTickSleepSignal`).
    private static func waitForLoops(
        _ keeper: LandKeeper<FoldReportState>,
        _ signal: FirstTickSleepSignal
    ) async throws {
        try await keeper.join(
            playerID: PlayerID("fold-player"),
            clientID: ClientID("fold-client"),
            sessionID: SessionID("fold-session")
        )
        await keeper.awaitInitialization()
        try #require(await keeper.appliedTickPhaseOffset != nil, "the keeper's tick loop did not start")
        try #require(await keeper.appliedSyncPhaseOffset != nil, "the keeper's sync loop did not start")
        await signal.waitUntilReached()
    }

    /// One sync loop iteration at `deadline + syncAt`, then the tick turn at `deadline + tickAt`.
    /// Fixed clock readings make the fold, overdue and lateness decisions independent of
    /// scheduling.
    private func syncThenTick(
        _ keeper: LandKeeper<FoldReportState>,
        syncAt: Duration,
        tickAt: Duration
    ) async {
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        await keeper.runSyncLoopIterationForTesting(at: deadline + syncAt)
        await keeper.stepTickOnceForTesting(at: deadline + tickAt)
    }

    @Test("each folded tick turn is reported once, with overdue at the fold and lateness at the turn's start")
    func foldsAreReported() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        // (sync at, tick at) relative to the tick deadline; expected overdue, late, lateness.
        let cases: [(Duration, Duration, Bool, Bool, Duration)] = [
            (.milliseconds(-1), .zero, false, false, .zero),                         // coincident, on time
            (.zero, .zero, false, false, .zero),                                       // exactly at the deadline
            (.milliseconds(1), .milliseconds(1), true, false, .milliseconds(1)),       // overdue by the race only
            (window, window, true, false, window),                                     // at the window: not late
            (.milliseconds(-1), .milliseconds(20), false, true, .milliseconds(20)),    // late, not overdue
            (.milliseconds(20), .milliseconds(20), true, true, .milliseconds(20)),     // overdue and late
        ]
        for (syncAt, tickAt, _, _, _) in cases {
            await syncThenTick(keeper, syncAt: syncAt, tickAt: tickAt)
        }
        let expected = cases.map {
            InTurnSyncFold(overdueAtFold: $0.2, tickLateness: $0.4, coincidentWindow: window)
        }
        #expect(transport.folds == expected)
        #expect(transport.folds.map { $0.isLate } == cases.map { $0.3 })
        let counters = await keeper.cadenceCountersForTesting()
        #expect(counters.foldedSyncs == 6)
        #expect(counters.overdueFoldedSyncs == 3)
        #expect(counters.lateFoldedSyncs == 2)
        await keeper.forceShutdown()
    }

    @Test("a sync-only turn when the tick is far away is not a fold")
    func noFoldWhenTickFarAway() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        await syncThenTick(keeper, syncAt: .seconds(-10), tickAt: .zero)
        #expect(transport.folds.isEmpty)
        #expect(await keeper.foldedSyncs == 0)
        await keeper.forceShutdown()
    }

    @Test("two sync iterations before one tick turn give one report, on the first fold's deadline")
    func lateTickCountsOneFold() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        // Two sync iterations, 100 ms apart, before the late tick runs: one tick turn, one cycle.
        await keeper.runSyncLoopIterationForTesting(at: deadline + .milliseconds(1))
        await keeper.setNextTickDeadlineForTesting(deadline + .milliseconds(50))
        await keeper.runSyncLoopIterationForTesting(at: deadline + .milliseconds(101))
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(120))
        #expect(transport.folds == [
            InTurnSyncFold(overdueAtFold: true, tickLateness: .milliseconds(120), coincidentWindow: window)
        ])
        #expect(await keeper.foldedSyncs == 1)
        #expect(await keeper.overdueFoldedSyncs == 1)
        #expect(await keeper.lateFoldedSyncs == 1)
        // The next tick turn carries no fold.
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(170))
        #expect(transport.folds.count == 1)
        await keeper.forceShutdown()
    }

    @Test("a fold is reported at the first tick turn after it, also when that turn's sync phase defers")
    func reportedAtFirstTurnWhenItsSyncDefers() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        await keeper.runSyncLoopIterationForTesting(at: deadline - .milliseconds(1))
        transport.deferNext(1)
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(1))   // on time; sync defers
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(51))  // the next tick turn
        #expect(transport.folds == [
            InTurnSyncFold(overdueAtFold: false, tickLateness: .milliseconds(1), coincidentWindow: window)
        ], "back-pressure is not tick lateness: one report, from the first turn, not late")
        #expect(await keeper.lateFoldedSyncs == 0)
        #expect(transport.syncResults.first == .deferredBackPressure, "the first turn's sync phase deferred")
        await keeper.forceShutdown()
    }

    @Test("a fold pending when the land freezes isn't reported; a fold after the resume is")
    func freezeDropsPendingFold() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        await keeper.runSyncLoopIterationForTesting(at: deadline - .milliseconds(1))
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(1)))
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(1))   // frozen: no turn
        await keeper.debugResume(generation: 1)
        // After the resume: a new fold, and the tick turn that carries it starts on time.
        let next = deadline + .milliseconds(500)
        await keeper.setNextTickDeadlineForTesting(next)
        await keeper.runSyncLoopIterationForTesting(at: next - .milliseconds(1))
        await keeper.stepTickOnceForTesting(at: next + .milliseconds(1))
        #expect(transport.folds == [
            InTurnSyncFold(overdueAtFold: false, tickLateness: .milliseconds(1), coincidentWindow: window)
        ], "the freeze is not tick lateness")
        #expect(await keeper.lateFoldedSyncs == 0)
        await keeper.forceShutdown()
    }

    @Test("a transport that doesn't record folds is not called")
    func notCalledWhenNotRecording() async throws {
        let transport = FoldRecordingTransport(records: false)
        let keeper = try await makeKeeper(transport)
        await syncThenTick(keeper, syncAt: .milliseconds(-1), tickAt: .zero)
        await syncThenTick(keeper, syncAt: .milliseconds(20), tickAt: .milliseconds(20))
        #expect(transport.folds.isEmpty)
        let counters = await keeper.cadenceCountersForTesting()
        #expect(counters.foldedSyncs == 2, "the keeper's own counters still count")
        #expect(counters.lateFoldedSyncs == 1)
        await keeper.forceShutdown()
    }

    @Test("the recording flag is read when the transport is attached with setTransport")
    func flagReadOnSetTransport() async throws {
        let signal = FirstTickSleepSignal()
        let keeper = TickLoopClock.$forNewKeepers.withValue(signal.tickLoopClock) {
            LandKeeper<FoldReportState>(
                definition: foldReportLand(),
                initialState: FoldReportState(),
                enableLoopPhaseOffset: false
            )
        }
        let transport = FoldRecordingTransport(records: true)
        await keeper.setTransport(transport)
        #expect(await keeper.isUsingInTurnSync())
        try await Self.waitForLoops(keeper, signal)
        await syncThenTick(keeper, syncAt: .milliseconds(20), tickAt: .milliseconds(20))
        #expect(transport.folds.map { $0.overdueAtFold } == [true])
        await keeper.forceShutdown()
    }
}

/// A tick-loop clock whose phase-offset sleep (`sleepFor`) waits until `release()`: the test
/// decides when the loop's task goes on to write its first tick deadline. Like
/// `FirstTickSleepSignal`, it reports the loop's first `sleepUntil`.
private final class HeldLoopStartClock: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    let firstSleep = FirstTickSleepSignal()

    var tickLoopClock: TickLoopClock {
        let sleeping = firstSleep.tickLoopClock
        return TickLoopClock(
            now: sleeping.now,
            sleepFor: { _ in await self.waitForRelease() },
            sleepUntil: sleeping.sleepUntil
        )
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

extension InTurnSyncFoldReportTests {
    /// The order `waitForLoops` relies on. A deadline the test sets before the loop's task has
    /// written its first one is overwritten (now + 1 h), so the sync doesn't fold; one set after
    /// the loop's first sleep is kept, and the sync folds. If the keeper comes to write the first
    /// deadline synchronously when it configures the loop, the first expectation fails: the race
    /// is gone, and `waitForLoops` no longer needs to wait for the first sleep.
    @Test("a tick deadline set before the loop's first write is overwritten; one set after its first sleep is kept")
    func loopStartDeadlineOrder() async throws {
        let transport = FoldRecordingTransport(records: false)
        let clock = HeldLoopStartClock()
        // A phase offset, so the loop's task sleeps (held) before it writes the deadline.
        let keeper = TickLoopClock.$forNewKeepers.withValue(clock.tickLoopClock) {
            LandKeeper<FoldReportState>(
                definition: foldReportLand(),
                initialState: FoldReportState(),
                enableLoopPhaseOffset: true,
                landID: "fold-report-test:550e8400-e29b-41d4-a716-446655440000",
                transport: transport
            )
        }
        try await keeper.join(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))
        await keeper.awaitInitialization()
        try #require(await keeper.appliedTickPhaseOffset ?? .zero > .zero, "the loop must have an offset to hold")

        // Set before the loop's write: overwritten, no fold.
        let early = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(early)
        clock.release()
        await clock.firstSleep.waitUntilReached()
        await keeper.runSyncLoopIterationForTesting(at: early - .milliseconds(1))
        await keeper.stepTickOnceForTesting(at: early)
        #expect(await keeper.foldedSyncs == 0, "the loop's own deadline replaced the test's")

        // Set after the loop's first sleep: kept, one fold.
        let late = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(late)
        await keeper.runSyncLoopIterationForTesting(at: late - .milliseconds(1))
        await keeper.stepTickOnceForTesting(at: late)
        #expect(await keeper.foldedSyncs == 1)
        await keeper.forceShutdown()
    }
}
