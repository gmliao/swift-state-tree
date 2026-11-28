import Foundation
import SwiftStateTurns
import Testing

/// A machine whose requests park their worker until a gate opens or the worker is cancelled:
/// each abandonment path (a cancel, a deadline, its key's end, `endAll`) must cancel the worker
/// once, and its late result must go to `handleLateResult`.
@PlainData
struct CancelMachine: TurnMachine {
    enum Input: Sendable {
        case start(String)
        case make(String, deadlineSeconds: Int64?)
        case makeThenCancel(String)
        case makeThenEnd(String)
        case makeUntracked(String)
        /// A request for `label` under `key` (several per key).
        case makeUnder(String, key: String)
        /// A request whose worker cleans up after a cancel, holding "db" until it returns.
        case makeHolding(String)
        /// Waits behind the "db" hold, then notes "behind `label`".
        case behind(String)
        case cancel(String)
        case end(String)
        case endAll
        case result(String)
    }

    enum Effect: Sendable {
        /// Parks at "release <label>" until opened or cancelled.
        case work(String)
        /// Opens the fixture event (a step's note, seen after the step).
        case note(String)
        /// As `.work`, but a cancelled worker parks at "cleanup `label`" before it returns.
        case cleanup(String)
    }

    enum Query: Sendable { case none }
    typealias Key = String
    typealias Output = String
    typealias Reply = Int
    typealias Answer = Int

    var open: [RequestID: String] = [:]
    var log: [String] = []

    func inputPolicy(for input: Input) -> InputPolicy<Key> {
        if case .behind = input { return .normal(waitsFor: "db", belongsTo: nil) }
        return .control
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<CancelMachine>) {
        switch input {
        case let .start(key):
            _ = turn.start(key)
        case let .make(label, deadline):
            make(label, &turn, deadline: deadline.map { .seconds($0) })
        case let .makeThenCancel(label):
            if let id = make(label, &turn, deadline: nil) { turn.cancel(id) }
        case let .makeThenEnd(label):
            make(label, &turn, deadline: nil)
            turn.end(label)
        case let .makeUntracked(label):
            turn.run(.work(label))
        case let .makeUnder(label, key):
            if let id = turn.request(.work(label), for: key) { open[id] = label }
        case let .makeHolding(label):
            if let id = turn.request(.cleanup(label), for: label, holding: .untilWorkerReturns("db", deadline: .seconds(60))) { open[id] = label }
        case let .behind(label):
            note("behind \(label)", &turn)
        case let .cancel(label):
            for (id, owner) in open where owner == label { turn.cancel(id) }
        case let .end(key):
            turn.end(key)
        case .endAll:
            turn.endAll()
        case let .result(label):
            open = open.filter { $0.value != label }
            note("result \(label)", &turn)
        }
    }

    @discardableResult
    mutating func make(_ label: String, _ turn: inout Turn<CancelMachine>, deadline: Duration?) -> RequestID? {
        guard let id = turn.request(.work(label), for: label, deadline: deadline) else { return nil }
        open[id] = label
        return id
    }

    mutating func note(_ line: String, _ turn: inout Turn<CancelMachine>) {
        log.append(line)
        turn.run(.note(line))
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<CancelMachine>) {
        note("abandoned \(open.removeValue(forKey: request) ?? "?") \(why)", &turn)
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<CancelMachine>) {
        if case let .result(label) = input { note("late \(label)", &turn) }
    }

    mutating func answer(_ query: Query, _ turn: inout Turn<CancelMachine>) -> Int { 0 }
}

actor CancelActor: TurnActor {
    let core: TurnCore<CancelMachine>
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock

    init(fixture: Fixture) {
        self.fixture = fixture
        let clock = TestClock(fixture: fixture)
        self.clock = clock
        core = TurnCore(CancelMachine(), queueLimit: 64, maxReleasesPerBatch: 16, clock: clock)
    }

    deinit { fixture.open("deinit") }

    @concurrent nonisolated func perform(_ effect: CancelMachine.Effect) async -> CancelMachine.Input? {
        switch effect {
        case let .work(label):
            fixture.open("entered \(label)")
            let released = await fixture.waitUnlessCancelled("release \(label)")
            fixture.open("returned \(label) cancelled=\(Task.isCancelled) released=\(released)")
            return .result(label)
        case let .note(line):
            fixture.open(line)
            return nil
        case let .cleanup(label):
            fixture.open("entered \(label)")
            let released = await fixture.waitUnlessCancelled("release \(label)")
            if !released {
                // The outside change settles before the worker returns: the hold lasts until then.
                fixture.open("cleaning \(label)")
                await fixture.wait("cleanup \(label)")
            }
            fixture.open("returned \(label) cancelled=\(Task.isCancelled) released=\(released)")
            return .result(label)
        }
    }

    func flush(_ outputs: consuming [String]) {}

    var log: [String] { core.read { $0.log } }
    var workers: Int { core.workersForTesting }
    var openRequests: Int { pendingWork(.requests) }
}

@Suite("An abandoned request's worker is cancelled (structured cancellation)", .timeLimit(.minutes(1)))
struct AbandonedWorkerCancellationTests {
    /// A worker parked inside its await, then `abandon`: the worker sees the cancellation, its
    /// result goes to `handleLateResult`, and no handle or request is left.
    private func expectCancelled(_ label: String, why: String, abandon: (CancelActor) async -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
        let f = Fixture()
        let a = CancelActor(fixture: f)
        await a.send(.start(label))
        await a.send(.make(label, deadlineSeconds: why == "deadline" ? 5 : nil))
        // Registered first, so the cancel provably wakes a suspended wait ("woken").
        guard await f.reach("registered release \(label)", sourceLocation: sourceLocation) else { return }
        #expect(await a.workers == 1, "the parked worker has its handle", sourceLocation: sourceLocation)
        await abandon(a)
        guard await f.reach("woken release \(label)", sourceLocation: sourceLocation),
              await f.reach("returned \(label) cancelled=true released=false", sourceLocation: sourceLocation),
              await f.reach("late \(label)", sourceLocation: sourceLocation) else { return }
        let log = await a.log
        #expect(log == ["abandoned \(label) \(why)", "late \(label)"], "\(log)", sourceLocation: sourceLocation)
        let workers = await a.workers, requests = await a.openRequests
        #expect(workers == 0 && requests == 0, "handles \(workers), requests \(requests)", sourceLocation: sourceLocation)
    }

    @Test("turn.cancel cancels the request's worker")
    func cancelCancelsTheWorker() async {
        await expectCancelled("c", why: "cancelled") { await $0.send(.cancel("c")) }
    }

    @Test("endAll cancels every open request's worker")
    func endAllCancelsTheWorker() async {
        await expectCancelled("e", why: "keyEnded") { await $0.send(.endAll) }
    }

    @Test("A key's end cancels its request's worker")
    func keyEndCancelsTheWorker() async {
        await expectCancelled("k", why: "keyEnded") { await $0.send(.end("k")) }
    }

    @Test("A request's deadline cancels its worker")
    func deadlineCancelsTheWorker() async {
        await expectCancelled("d", why: "deadline") { a in a.clock.advance(to: 5) }
    }

    @Test("A request abandoned in the step that made it, before its worker started, has its worker cancelled at the launch", arguments: ["cancel", "end"])
    func abandonedBeforeTheLaunch(path: String) async {
        let f = Fixture()
        let a = CancelActor(fixture: f)
        await a.send(.start("b"))
        await a.send(path == "cancel" ? .makeThenCancel("b") : .makeThenEnd("b"))
        guard await f.reach("returned b cancelled=true released=false"), await f.reach("late b") else { return }
        let log = await a.log
        #expect(log == ["abandoned b \(path == "cancel" ? "cancelled" : "keyEnded")", "late b"], "\(log)")
        let workers = await a.workers, requests = await a.openRequests
        #expect(workers == 0 && requests == 0, "handles \(workers), requests \(requests)")
    }

    @Test("A worker that returns is not cancelled, and its handle leaves; a later abandon of its key finds nothing")
    func completedWorkerIsLeftAlone() async {
        let f = Fixture()
        let a = CancelActor(fixture: f)
        await a.send(.start("n"))
        await a.send(.make("n", deadlineSeconds: nil))
        guard await f.reach("entered n") else { return }
        f.open("release n")
        guard await f.reach("returned n cancelled=false released=true"), await f.reach("result n") else { return }
        #expect(await a.workers == 0)
        await a.send(.endAll)
        #expect(await a.log == ["result n"], "the closed request wasn't abandoned again")
    }

    @Test("run's untracked worker is never cancelled, not even by endAll")
    func untrackedWorkerIsNotCancelled() async {
        let f = Fixture()
        let a = CancelActor(fixture: f)
        await a.send(.start("u"))
        await a.send(.makeUntracked("u"))
        guard await f.reach("entered u") else { return }
        #expect(await a.workers == 0, "an untracked worker has no handle")
        await a.send(.endAll)
        f.open("release u")
        guard await f.reach("returned u cancelled=false released=true"), await f.reach("result u") else { return }
    }

    @Test("A cancelled worker no longer keeps its actor: once it returns, the actor is released")
    func cancelledWorkerReleasesTheActor() async {
        let f = Fixture()
        weak var weakActor: CancelActor?
        do {
            let a = CancelActor(fixture: f)
            weakActor = a
            await a.send(.start("w"))
            await a.send(.make("w", deadlineSeconds: nil))
            guard await f.reach("entered w") else { return }
            await a.send(.endAll)
        }
        guard await f.reach("returned w cancelled=true released=false"), await f.reach("deinit") else { return }
        #expect(weakActor == nil)
    }

    @Test("An .untilWorkerReturns hold outlasts its worker's cancel: the worker settles its change first, and the input behind the hold steps only once the worker returns")
    func holdLastsUntilTheCancelledWorkerReturns() async {
        let f = Fixture()
        let a = CancelActor(fixture: f)
        await a.send(.start("h"))
        await a.send(.makeHolding("h"))
        guard await f.reach("registered release h") else { return }
        await a.send(.behind("q"))
        // The key's end, not `endAll`, which would drop the queued input with the intake.
        await a.send(.end("h"))
        guard await f.reach("woken release h"), await f.reach("cleaning h") else { return }
        #expect(await a.log == ["abandoned h keyEnded"], "the input behind the hold waits for the cleanup")
        f.open("cleanup h")
        guard await f.reach("returned h cancelled=true released=false"), await f.reach("behind q") else { return }
        let log = await a.log
        #expect(log == ["abandoned h keyEnded", "late h", "behind q"], "\(log)")
        #expect(await a.workers == 0)
    }

    @Test("Several workers under one key, and a start that supersedes it: every worker is cancelled once, each request abandoned keyEnded, and no handle is left")
    func supersedeCancelsEveryWorker() async {
        let f = Fixture()
        let a = CancelActor(fixture: f)
        await a.send(.start("s"))
        await a.send(.makeUnder("s1", key: "s"))
        await a.send(.makeUnder("s2", key: "s"))
        guard await f.reach("registered release s1"), await f.reach("registered release s2") else { return }
        #expect(await a.workers == 2)
        await a.send(.start("s"))
        guard await f.reach("woken release s1"), await f.reach("woken release s2"),
              await f.reach("late s1"), await f.reach("late s2") else { return }
        let log = await a.log
        #expect(Set(log) == ["abandoned s1 keyEnded", "abandoned s2 keyEnded", "late s1", "late s2"] && log.count == 4, "\(log)")
        let workers = await a.workers, requests = await a.openRequests
        #expect(workers == 0 && requests == 0, "handles \(workers), requests \(requests)")
        // The new generation makes its own request: a new handle, cancelled by its own end.
        await a.send(.makeUnder("s3", key: "s"))
        guard await f.reach("registered release s3") else { return }
        await a.send(.end("s"))
        guard await f.reach("woken release s3"), await f.reach("late s3") else { return }
        #expect(await a.workers == 0)
    }
}

/// The mailbox side of the rule: a cancelled worker that returns nil is an idle completion (no
/// entry, no ordinal), live and replayed alike; a follow-up's gate has no handle and is never
/// cancelled.
@Suite("Cancelled workers on a mailbox core", .timeLimit(.minutes(1)))
struct MailboxWorkerCancellationTests {
    @Test("A cancelled worker's nil completion is idle: no step, no handle left, and the replay matches the live run")
    func cancelledNilCompletionIsIdle() async {
        var workersAtPark = -1, workersAfter = -1
        let run = await MailReplayTests.liveThenReplay { a, on in
            await a.send(.script([.start(1), .request(gate: "cancelz", key: 1)]))
            await a.fixture.reach("registered gate cancelz")
            if on { workersAtPark = await a.workers }
            await a.send(.script([.end(1)]))
            await a.fixture.reach("woken gate cancelz")
            await a.fixture.reach("idle completion #1")
            if on { workersAfter = await a.workers }
        }
        #expect(workersAtPark == 1 && workersAfter == 0, "handles: parked \(workersAtPark), after \(workersAfter)")
        #expect(run.live == ["abandoned cancelz keyEnded"], "\(run.live)")
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("A follow-up's gate worker has no handle: an end of its key closes the follow-up, and its gate runs on, uncancelled")
    func followUpGateIsNotCancelled() async {
        let a = await MailboxActor.started()
        // A cancellation-aware gate: a cancel would wake it ("woken").
        await a.send(.script([.start(1), .arm("f", key: 1, gate: "cancelfg")]))
        await a.fixture.reach("registered gate cancelfg")
        #expect(await a.workers == 0, "a gate has no handle")
        await a.send(.script([.end(1)]))
        #expect(!a.fixture.isOpen("woken gate cancelfg"), "the end's step cancelled the gate")
        a.fixture.open("gate cancelfg")
        #expect(await a.waitForQuiescence(.followUps))
        #expect(await a.workers == 0)
    }
}
