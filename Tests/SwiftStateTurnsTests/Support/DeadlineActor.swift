import SwiftStateTurns

/// Runs `DeadlineMachine` on a test clock. The core's diagnostics go to the fixture, each wake
/// of the core's timer opens "timer wake #n" or "superseded wake #n", and each flushed output
/// opens "out <value> #n".
actor DeadlineActor: TurnActor {
    let core: TurnCore<DeadlineMachine>
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock
    /// Called on the actor with each flush's outputs.
    var flushHook: ((isolated DeadlineActor, [Int]) -> Void)?

    init(fixture: Fixture, maxReleasesPerBatch: Int = 16) {
        let clock = TestClock(fixture: fixture)
        self.fixture = fixture
        self.clock = clock
        core = TurnCore(DeadlineMachine(), queueLimit: 1024, maxReleasesPerBatch: maxReleasesPerBatch, clock: clock)
        core.onDiagnostic = { event in fixture.observe(event) }
        core.onTimerWakeForTesting = { superseded in fixture.openCounted(superseded ? "superseded wake" : "timer wake") }
    }

    @concurrent nonisolated func perform(_ effect: DeadlineMachine.Effect) async -> DeadlineMachine.Input? {
        switch effect {
        case .work(let label):
            await fixture.wait("work \(label)")
            return .completed(label)
        }
    }

    func flush(_ outputs: consuming [Int]) {
        let outputs = Array(outputs)
        for value in outputs { fixture.openCounted("out \(value)") }
        flushHook?(self, outputs)
    }

    var log: [String] { core.read { $0.log } }

    /// The core's timer: sleeper starts, superseded and serviced wakes, and the deadline heap's
    /// live and total entries.
    func timer() -> (starts: Int, superseded: Int, wakes: Int, live: Int, entries: Int) {
        (core.sleeperStartsForTesting, core.supersededWakesForTesting, core.timerWakesForTesting,
         core.liveDeadlinesForTesting, core.deadlineEntriesForTesting)
    }

    /// Records `read()` at each flush, on the task that flushed.
    func recordOnFlush(_ read: @escaping @Sendable () -> Int?) {
        flushHook = { (owner: isolated DeadlineActor, _: [Int]) in owner.flushReadings.append(read()) }
    }

    var flushReadings: [Int?] = []

    /// Sends each input and returns the heap's entry count after each one.
    func sendEach(_ inputs: [DeadlineMachine.Input]) -> [Int] {
        inputs.map { input in
            send(input)
            return core.deadlineEntriesForTesting
        }
    }
}
