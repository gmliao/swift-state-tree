import Foundation
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
        // A quiescence wait opens "registered #n" when it stores its waiter, in the segment that
        // stores it, so a later call into the actor sees the waiter registered.
        core.onQuiescenceRegistrationForTesting = { fixture.openCounted("registered") }
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

    /// `n` times: arm a follow-up, then wait for it, from inside this actor; true when every
    /// wait returned after its run.
    func armAndWait(_ n: Int) async -> Bool {
        for i in 0 ..< n {
            send(.script([.arm("A\(i)")]))
            guard await waitForQuiescence() else { return false }
            if core.read({ $0.ran }) != i + 1 { return false }
        }
        return true
    }

    /// The quiescence waiters registered now.
    func waiterCount() -> Int {
        core.quiescenceWaitersForTesting
    }
}

/// A serial executor whose jobs run on one dispatch queue, which a test can ask, without
/// trapping, whether the current code runs on it (that is, isolated to the actor it backs).
final class QueueExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "turns-test-queue-executor")
    private let key = DispatchSpecificKey<Bool>()

    init() {
        queue.setSpecific(key: key, value: true)
    }

    /// The calling code runs on this executor's queue.
    var isCurrent: Bool {
        DispatchQueue.getSpecific(key: key) == true
    }

    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

/// `FollowUpMachine` on an actor backed by a `QueueExecutor`, so a test sees where the core's
/// registration of a quiescence wait runs (case 39).
actor QueueFollowUpActor: TurnActor {
    let core: TurnCore<FollowUpMachine>
    nonisolated let fixture: Fixture
    nonisolated let executor = QueueExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(fixture: Fixture) {
        self.fixture = fixture
        self.core = FollowUpActor.makeCore(fixture, TestClock(fixture: fixture), 64)
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

    /// Records, at each registration, whether it ran on this actor's executor, then opens
    /// "registering".
    func watchRegistrations(_ onActor: RegistrationLog) {
        let executor = self.executor
        let fixture = self.fixture
        core.onQuiescenceRegistrationForTesting = {
            onActor.append(executor.isCurrent)
            fixture.open("registering")
        }
    }
}

/// Where each registration ran (true: on the actor's executor).
final class RegistrationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Bool] = []

    func append(_ onActor: Bool) {
        lock.lock()
        entries.append(onActor)
        lock.unlock()
    }

    var all: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
