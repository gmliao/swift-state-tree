// Tests/SwiftStateTreeTransportTests/TransportProfilerSyncCountersTests.swift
//
// The profiler's sync counters (cycles, skips, in-turn deferrals, folds, overdue and late folds,
// the largest fold lateness): each window takes and resets them, the packed fold fields stay
// apart, and an adapter that doesn't profile records no folds.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// A fold in a land whose coincident window is 5 ms.
private let window = Duration.milliseconds(5)

private func fold(overdue: Bool, lateness: Duration) -> InTurnSyncFold {
    InTurnSyncFold(overdueAtFold: overdue, tickLateness: lateness, coincidentWindow: window)
}

@Suite("Transport profiler: sync counters")
struct TransportProfilerSyncCountersTests {
    @Test("a window takes the sync counters and resets them")
    func windowTakesAndResets() {
        let counters = TransportProfilerCounters()
        for _ in 0..<5 { counters.incrementSyncCycles() }
        counters.incrementSyncSkipsBacklog()
        counters.incrementSyncSkipsBacklog()
        counters.incrementSyncSkipsBusy()
        counters.incrementSyncDeferredTurns()
        counters.recordSyncFold(fold(overdue: false, lateness: .milliseconds(-1)))
        counters.recordSyncFold(fold(overdue: true, lateness: .microseconds(800)))
        counters.recordSyncFold(fold(overdue: true, lateness: .milliseconds(20)))
        counters.recordSyncFold(fold(overdue: false, lateness: .microseconds(7_250)))
        counters.incrementSyncJoinTicks()

        let window = counters.takeAndResetSync()
        #expect(window.cycles == 5)
        #expect(window.skipsBacklog == 2)
        #expect(window.skipsBusy == 1)
        #expect(window.deferredTurns == 1)
        #expect(window.folds == 4, "every fold, overdue and late ones included")
        #expect(window.overdueFolds == 2)
        #expect(window.lateFolds == 2, "late: lateness above the 5 ms window, overdue or not")
        #expect(window.foldTickLatenessMaxUs == 20_000)
        #expect(window.joinTicks == 1, "join sync ticks are not folds")

        let next = counters.takeAndResetSync()
        #expect(next.cycles == 0 && next.skipsBacklog == 0 && next.skipsBusy == 0)
        #expect(next.deferredTurns == 0 && next.folds == 0 && next.overdueFolds == 0 && next.joinTicks == 0)
        #expect(next.lateFolds == 0 && next.foldTickLatenessMaxUs == 0)
    }

    @Test("a fold at the window's edge isn't late, and a fold that started early keeps the max at 0")
    func lateIsStrictAndMaxIgnoresEarly() {
        let counters = TransportProfilerCounters()
        counters.recordSyncFold(fold(overdue: true, lateness: window))
        counters.recordSyncFold(fold(overdue: false, lateness: .milliseconds(-3)))
        let taken = counters.takeAndResetSync()
        #expect(taken.folds == 2 && taken.overdueFolds == 1 && taken.lateFolds == 0)
        #expect(taken.foldTickLatenessMaxUs == 5_000)

        counters.recordSyncFold(fold(overdue: false, lateness: .milliseconds(-3)))
        #expect(counters.takeAndResetSync().foldTickLatenessMaxUs == 0)
    }

    @Test("the packed fold fields stay apart up to their limit; one more carries into the next field")
    func packedFieldsAtTheirLimit() {
        let limit = (1 << TransportProfilerCounters.foldFieldBits) - 1
        let counters = TransportProfilerCounters()
        let late = fold(overdue: true, lateness: .milliseconds(20))
        for _ in 0..<limit { counters.recordSyncFold(late) }
        let full = counters.takeAndResetSync()
        #expect(full.folds == limit && full.overdueFolds == limit && full.lateFolds == limit)

        // Documented: past the limit a field carries into the next one.
        for _ in 0...limit { counters.recordSyncFold(fold(overdue: false, lateness: .zero)) }
        let over = counters.takeAndResetSync()
        #expect(over.folds == 0 && over.overdueFolds == 1 && over.lateFolds == 0)
    }

    @Test("an adapter without profiling doesn't record folds")
    func adapterWithoutProfilingRecordsNoFolds() async throws {
        let keeper = LandKeeper<SkipConvergenceState>(
            definition: Land("profiler-off-test", using: SkipConvergenceState.self) { Rules {} },
            initialState: SkipConvergenceState()
        )
        let adapter = TransportAdapter<SkipConvergenceState>(
            keeper: keeper,
            transport: BlockingTransport(),
            landID: "profiler-off-test"
        )
        // Profiling is on only with TRANSPORT_PROFILE_JSONL_PATH, which tests don't set.
        #expect(await adapter.profilerCounters == nil)
        #expect(!adapter.recordsInTurnSyncFolds)
    }

    @Test("a window takes the sync-lag counters (#332) and resets them")
    func syncLagWindow() {
        let counters = TransportProfilerCounters()
        counters.addSyncLag(.init(resyncs: 2, resyncsAlongside: 1, pendingMarks: 3, keyScopeResets: 1, keyScopeResetBytes: 400, droppedEvents: 5))
        counters.addSyncLag(.init(resyncs: 1, keyScopeResetBytes: 100))
        counters.addSyncLag(.init(slowConsumerCloses: 1, unresponsiveCloses: 2, droppedAcks: 4))
        let window = counters.takeAndResetSyncLag()
        #expect(window == .init(
            resyncs: 3, resyncsAlongside: 1, pendingMarks: 3, keyScopeResets: 1, keyScopeResetBytes: 500,
            droppedEvents: 5, slowConsumerCloses: 1, unresponsiveCloses: 2, droppedAcks: 4
        ))
        #expect(counters.takeAndResetSyncLag() == .init())
    }
}
