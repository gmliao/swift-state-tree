import SwiftStateTurns
import Testing

struct DemoSnapshot: Sendable {
    var steps = 0
    var asks = 0
    var log: [String] = []
    /// Every flushed output, in order.
    var flushed: [Int] = []
    /// Each `flush` call's outputs.
    var batches: [[Int]] = []
    var stats = TurnStats()
    var cancelledCallers: [InputID] = []
}

/// The actor that runs `DemoMachine`. Its effects wait at the fixture's gates: an effect with
/// a non-empty gate opens "at <gate>" when its worker starts, then waits for "<gate>".
actor DemoActor: TurnActor {
    let core: TurnCore<DemoMachine>
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock
    private var flushed: [Int] = []
    private var batches: [[Int]] = []
    /// A collaborator the driver calls between steps, from `flush`.
    private var flushHook: ((isolated DemoActor, [Int]) -> Void)?
    private var collaboratorSaw: [Int] = []

    init(fixture: Fixture = Fixture(), queueLimit: Int = 1024, maxReleasesPerBatch: Int = 64) {
        let clock = TestClock(fixture: fixture)
        let core = TurnCore(DemoMachine(), queueLimit: queueLimit, maxReleasesPerBatch: maxReleasesPerBatch, clock: clock)
        core.onDiagnostic = { event in fixture.observe(event) }
        self.fixture = fixture
        self.clock = clock
        self.core = core
    }

    @concurrent nonisolated func perform(_ effect: DemoMachine.Effect) async -> DemoMachine.Input? {
        switch effect {
        case .work(let job, let gate):
            if !gate.isEmpty { fixture.open("at " + gate) }
            await fixture.wait(gate)
            return .finished(job: job)
        case .txnWork(let name, let gate):
            if !gate.isEmpty { fixture.open("at " + gate) }
            await fixture.wait(gate)
            return .txnFinished(name)
        case .relayWork(let name, let gate, let leg):
            if !gate.isEmpty { fixture.open("at " + gate) }
            await fixture.wait(gate)
            return .relayed(name, leg: leg)
        case .traced(let number):
            fixture.record("perform \(number)")
            fixture.open("performed \(number)")
            return nil
        case .echoMark(let label):
            return .mark("ran \(label)")
        }
    }

    func flush(_ outputs: consuming [Int]) {
        let batch: [Int] = outputs
        flushed.append(contentsOf: batch)
        batches.append(batch)
        fixture.record("flush \(batch)")
        flushHook?(self, batch)
    }

    func snapshot() -> DemoSnapshot {
        var snapshot = core.read { machine in
            DemoSnapshot(steps: machine.steps, asks: machine.asks, log: machine.log)
        }
        snapshot.cancelledCallers = core.read { $0.cancelledCallers }
        snapshot.flushed = flushed
        snapshot.batches = batches
        snapshot.stats = core.stats
        return snapshot
    }

    /// Returns once the machine's log has `count` lines (a control call, so it also works
    /// after `close` and `endAll`).
    /// Under the hang bound: a log that never gets there records an issue instead of parking
    /// the test (the call is `.ignoresCancel`, so it is abandoned, not awaited).
    func waitForLog(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        _ = await firstOrBound(sourceLocation: sourceLocation) {
            try await self.sendAndWait(.awaitLog(count), cancellation: .ignoresCancel)
        }
    }

    // MARK: Reaching the actor from inside a step

    /// A `.hook` step whose hook sends to this actor from inside `handle`: the send is queued.
    func sendFromInsideStep() {
        let me = self
        StepHooks.$duringStep.withValue({ me.assumeIsolated { owner in owner.send(.mark("queued")) } }) { // lint-allow: turns-isolated: reaches the actor from inside a step to show the send is queued
            self.send(.hook)
        }
    }

    /// Installs a mail replay on this core, which has no mailbox: it must stop the process.
    func installReplayForTesting() {
        core.replayMail([])
    }

    /// A `.hook` step whose hook reads this actor's machine from inside `handle`: a stop.
    func readFromInsideStep() {
        let me = self
        StepHooks.$duringStep.withValue({
            me.assumeIsolated { owner in // lint-allow: turns-isolated: reaches the actor from inside a step to show read stops
                let steps = owner.core.read { machine in machine.steps }
                owner.fixture.record("read \(steps)")
            }
        }) {
            self.send(.hook)
        }
    }

    /// A `.hook` step whose hook asks this actor from inside `handle`: a stop.
    func askFromInsideStep() {
        let me = self
        StepHooks.$duringStep.withValue({
            me.assumeIsolated { owner in // lint-allow: turns-isolated: reaches the actor from inside a step to show query stops
                let answer = owner.query(.steps)
                owner.fixture.record("asked \(answer)")
            }
        }) {
            self.send(.hook)
        }
    }

    /// Sends from inside `read`'s body, which steps at once (the core is idle): a stop.
    func sendFromInsideRead() {
        _ = core.read { _ in
            self.send(.ping)
            return 0
        }
    }

    /// Reads inside a read, then sends from the outer body once the inner read has returned: a
    /// stop, since the outer read still holds the machine.
    func sendFromOuterReadAfterNestedRead() {
        _ = core.read { _ in
            _ = self.core.read { _ in 0 }
            self.send(.ping)
            return 0
        }
    }

    /// Asks from inside `read`'s body: the answer is a step, so a stop.
    func queryFromInsideRead() {
        _ = core.read { _ in
            _ = self.query(.steps)
            return 0
        }
    }

    /// Asks from an outer read's body once a nested read has returned: a stop.
    func queryFromOuterReadAfterNestedRead() {
        _ = core.read { _ in
            _ = self.core.read { _ in 0 }
            _ = self.query(.steps)
            return 0
        }
    }

    /// Asks from inside a read that is itself nested in a read: a stop.
    func queryFromNestedRead() {
        _ = core.read { _ in
            self.core.read { _ in
                _ = self.query(.steps)
                return 0
            }
        }
    }

    /// Two reads, one inside the other, and no step: both run.
    func nestedReads() -> Int {
        core.read { _ in 1 + self.core.read { _ in 1 } }
    }

    /// The core's borrow state between calls.
    var borrowState: Int { core.borrowStateForTesting }

    // MARK: Collaborators between steps

    /// A collaborator called by the driver between steps (from `flush`) reads, asks and sends.
    /// Returns what it read and what its ask was answered.
    func collaboratorBetweenSteps() -> [Int] {
        flushHook = { (owner: isolated DemoActor, _: [Int]) in
            let steps = owner.core.read { machine in machine.steps }
            let asked = owner.query(.bump)
            owner.send(.ping)
            owner.collaboratorSaw = [steps, asked]
        }
        send(.start(job: 900, gate: "never"))
        send(.emit(900))
        flushHook = nil
        return collaboratorSaw
    }

    /// `count` steps queue behind a transaction, which is then aborted. While they drain, the
    /// collaborator sends one more when it sees output 3: it must step after every input
    /// already queued.
    func drainWithLateArrival(count: Int) {
        send(.setup)
        send(.transaction(1, "never"))
        for number in 0..<count { send(.step(number)) }
        flushHook = { (owner: isolated DemoActor, outputs: [Int]) in
            if outputs.contains(3) { owner.send(.step(999)) }
        }
        send(.abort(1))
    }

    /// When a flush carries `value`: opens `gate`, then sends `input`, which is queued and
    /// steps in that same batch. Runs once.
    func onOutput(_ value: Int, open gate: String, thenSend input: DemoMachine.Input?) {
        flushHook = { (owner: isolated DemoActor, outputs: [Int]) in
            guard outputs.contains(value) else { return }
            owner.flushHook = nil
            owner.fixture.open(gate)
            if let input { owner.send(input) }
        }
    }

    /// When a flush carries `value`: releases the test clock through `seconds`, then sends
    /// `input`, which is queued and steps in that same batch. Runs once.
    func onOutput(_ value: Int, release seconds: Int64, thenSend input: DemoMachine.Input?) {
        flushHook = { (owner: isolated DemoActor, outputs: [Int]) in
            guard outputs.contains(value) else { return }
            owner.flushHook = nil
            owner.clock.release(through: seconds)
            if let input { owner.send(input) }
        }
    }

    /// The core's timer, for checks: sleeper starts, superseded and serviced wakes, and the
    /// deadline heap's live and total entries.
    func deadlineTimer() -> (starts: Int, superseded: Int, wakes: Int, live: Int, entries: Int) {
        (core.sleeperStartsForTesting, core.supersededWakesForTesting, core.timerWakesForTesting,
         core.liveDeadlinesForTesting, core.deadlineEntriesForTesting)
    }

    /// When a flush carries `value`: sends `inputs`, in order. They are deferred (the batch is
    /// running) and admitted after the flush, one after another. Runs once.
    func onOutput(_ value: Int, send inputs: [DemoMachine.Input]) {
        flushHook = { (owner: isolated DemoActor, outputs: [Int]) in
            guard outputs.contains(value) else { return }
            owner.flushHook = nil
            for input in inputs { owner.send(input) }
        }
    }

    /// For each value in `plan`, when a flush first carries it: sends its inputs, in order (they
    /// are deferred). Each entry runs once.
    func onOutputs(_ plan: [Int: [DemoMachine.Input]]) {
        var remaining = plan
        flushHook = { (owner: isolated DemoActor, outputs: [Int]) in
            for value in outputs {
                guard let inputs = remaining.removeValue(forKey: value) else { continue }
                for input in inputs { owner.send(input) }
            }
            if remaining.isEmpty { owner.flushHook = nil }
        }
    }

    func clearHooks() {
        flushHook = nil
    }
}

/// An adopter whose `core` is a stored `var` that it replaces: the protocol can't require a
/// `let`. The core's incarnation keeps the old core's completions out of the new one.
actor ReplaceableCoreActor: TurnActor {
    var core: TurnCore<DemoMachine> // lint-allow: turns-let-core: check 14 replaces the core on purpose
    nonisolated let fixture: Fixture

    static func makeCore(_ fixture: Fixture) -> TurnCore<DemoMachine> {
        let core = TurnCore(DemoMachine(), queueLimit: 16, maxReleasesPerBatch: 16, clock: TestClock(fixture: fixture))
        core.onDiagnostic = { event in fixture.observe(event) }
        return core
    }

    init(fixture: Fixture) {
        self.fixture = fixture
        core = Self.makeCore(fixture)
    }

    @concurrent nonisolated func perform(_ effect: DemoMachine.Effect) async -> DemoMachine.Input? {
        if case .work(let job, let gate) = effect {
            await fixture.wait(gate)
            return .finished(job: job)
        }
        return nil
    }

    func flush(_ outputs: consuming [Int]) {}

    func replaceCore() {
        core = Self.makeCore(fixture)
    }

    func state() -> (log: [String], foreign: Int, steps: Int) {
        (core.read { machine in machine.log }, core.stats.foreignCompletions, core.read { machine in machine.steps })
    }
}

/// A machine that is a class: the core stops the process when it is created with one. The
/// compiler only lets a PlainData machine reach the core, and `@PlainData` refuses a class, so
/// this one declares the conformance by hand: the runtime stop is the backstop behind it.
final class ClassMachine: TurnMachine, PlainData { // lint-allow: turns-plain-data: the class-machine stop needs a class that reaches the core
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int

    static func _plainDataCheck() {} // lint-allow: turns-plain-data: the requirement only @PlainData writes, here by hand

    init() {}

    func handle(_ input: Int, _ turn: inout Turn<ClassMachine>) {}
}
