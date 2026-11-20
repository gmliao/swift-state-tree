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

    let maxReleases: Int

    init(fixture: Fixture = Fixture(), maxReleasesPerBatch: Int = 64) {
        let clock = TestClock(fixture: fixture)
        self.fixture = fixture
        self.clock = clock
        self.maxReleases = maxReleasesPerBatch
        self.core = Self.makeCore(fixture, clock, maxReleasesPerBatch)
    }

    static func makeCore(_ fixture: Fixture, _ clock: TestClock, _ maxReleases: Int) -> TurnCore<FollowUpMachine> {
        let core = TurnCore(FollowUpMachine(), queueLimit: 64, maxReleasesPerBatch: maxReleases, clock: clock)
        core.onDiagnostic = { event in fixture.observe(event) }
        return core
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

    /// Debug builds: the core's effect counts by input case.
    func effectsByInput() -> [String: Int] {
        core.effectsByInput
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
