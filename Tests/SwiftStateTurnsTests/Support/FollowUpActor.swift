import SwiftStateTurns

struct FollowUpSnapshot: Sendable {
    var log: [String]
    var ran: Int
    var abandoned: Int
    var stats: TurnStats
}

actor FollowUpActor: TurnActor {
    let core: TurnCore<FollowUpMachine>
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock

    init(fixture: Fixture = Fixture()) {
        let clock = TestClock(fixture: fixture)
        let core = TurnCore(FollowUpMachine(), queueLimit: 64, maxReleasesPerBatch: 64, clock: clock)
        core.onDiagnostic = { event in fixture.observe(event) }
        self.fixture = fixture
        self.clock = clock
        self.core = core
    }

    @concurrent nonisolated func perform(_ effect: FollowUpMachine.Effect) async -> FollowUpMachine.Input? {
        switch effect {
        case .gate(let label, let result):
            fixture.open("at gate \(label)")
            await fixture.wait("gate \(label)")
            return result ? .gateResult(label) : nil
        case .work(let label):
            await fixture.wait("gate \(label)")
            return .released(label)
        }
    }

    func flush(_ outputs: consuming [Never]) {}

    func snapshot() -> FollowUpSnapshot {
        let (log, ran, abandoned) = core.read { machine in (machine.log, machine.ran, machine.abandoned) }
        return FollowUpSnapshot(log: log, ran: ran, abandoned: abandoned, stats: core.stats)
    }

    /// The quiescence waiters registered now.
    func waiterCount() -> Int {
        core.quiescenceWaitersForTesting
    }

    /// Returns once `count` quiescence waiters are registered: a test starts its waiter in a
    /// task, and the step it then sends must come after the registration.
    func waitForWaiters(_ count: Int) async {
        while core.quiescenceWaitersForTesting < count {
            await Task.yield()
        }
    }
}
