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

    /// When a flush first carries `value`: a new actor job sends `.note(text)`. That job runs
    /// after the one that flushed, ahead of the core timer's next hop.
    func onOutputSendLater(_ value: Int, _ text: String) {
        flushHook = { (owner: isolated DeadlineActor, outputs: [Int]) in
            guard outputs.contains(value) else { return }
            owner.flushHook = nil
            Task { owner.send(.note(text)) }
        }
    }

    /// Sends each input and returns, after each one, the timer inputs the core holds and the
    /// heap's entry count.
    func sendEachTimers(_ inputs: [DeadlineMachine.Input]) -> [(inputs: Int, entries: Int)] {
        inputs.map { input in
            send(input)
            return (core.liveTimerInputsForTesting, core.deadlineEntriesForTesting)
        }
    }

    /// Sends each input and returns the heap's entry count after each one.
    func sendEach(_ inputs: [DeadlineMachine.Input]) -> [Int] {
        inputs.map { input in
            send(input)
            return core.deadlineEntriesForTesting
        }
    }
}
