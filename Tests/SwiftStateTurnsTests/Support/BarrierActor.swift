import SwiftStateTurns

/// Runs `BarrierMachine` on a test clock. The core's diagnostics go to the fixture (a
/// registration opens "barrier wait #n"); the work waits at its gate after opening "at <gate>";
/// each flushed output opens "out <value> #n", and a flush can cancel a task the test hands in.
actor BarrierActor: TurnActor {
    let core: TurnCore<BarrierMachine>
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock
    /// Cancelled, once, by the next flush: a cancellation that lands between two steps of one
    /// segment, before the second one reads it.
    private var cancelOnFlush: Task<Int, any Error>?

    init(fixture: Fixture) {
        let clock = TestClock(fixture: fixture)
        self.fixture = fixture
        self.clock = clock
        core = TurnCore(BarrierMachine(), queueLimit: 64, maxReleasesPerBatch: 16, clock: clock)
        core.onDiagnostic = { event in fixture.observe(event) }
    }

    @concurrent nonisolated func perform(_ effect: BarrierMachine.Effect) async -> BarrierMachine.Input? {
        switch effect {
        case .work(let gate):
            fixture.open("at " + gate)
            await fixture.wait(gate)
            return .finished
        }
    }

    func flush(_ outputs: consuming [Int]) {
        let outputs = Array(outputs)
        for value in outputs { fixture.openCounted("out \(value)") }
        if let task = cancelOnFlush {
            cancelOnFlush = nil
            task.cancel()
        }
    }

    func cancel(onNextFlush task: Task<Int, any Error>) { cancelOnFlush = task }

    var log: [String] { core.read { $0.log } }
    var stats: TurnStats { core.stats }
    /// The entries in the barrier table, and the cancellation flags still set.
    var table: [Int] { [core.barrierWaitersForTesting, core.cancelledCallersForTesting] }
    /// The deadline heap's live entries.
    var liveDeadlines: Int { core.liveDeadlinesForTesting }
    /// The deadline heap's entries, live or stale, and the core's timer's starts and target.
    var heap: (entries: Int, sleeperStarts: Int, target: TurnInstant?) {
        (core.deadlineEntriesForTesting, core.sleeperStartsForTesting, core.sleeperTargetForTesting)
    }
}
