// Tests/SwiftStateTreeTransportTests/TransportProfilerSyncCountersTests.swift
//
// The profiler's sync counters (cycles, skips, in-turn deferrals, folds and overdue folds):
// each window takes and resets them, and an adapter that doesn't profile records no folds.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

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
        counters.incrementSyncFolds(overdue: false)
        counters.incrementSyncFolds(overdue: true)
        counters.incrementSyncFolds(overdue: true)

        let window = counters.takeAndResetSync()
        #expect(window.cycles == 5)
        #expect(window.skipsBacklog == 2)
        #expect(window.skipsBusy == 1)
        #expect(window.deferredTurns == 1)
        #expect(window.folds == 3, "every fold, overdue ones included")
        #expect(window.overdueFolds == 2)

        let next = counters.takeAndResetSync()
        #expect(next.cycles == 0 && next.skipsBacklog == 0 && next.skipsBusy == 0)
        #expect(next.deferredTurns == 0 && next.folds == 0 && next.overdueFolds == 0)
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
}
