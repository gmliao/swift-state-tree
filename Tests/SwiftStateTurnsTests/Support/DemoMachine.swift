import SwiftStateTurns

enum DemoError: Error, Sendable, Equatable {
    case refused
    case abandoned
}

/// A machine that exercises the core's rules one at a time: jobs (a key each, with work under
/// it), transactions that hold `.membership`, steps queued behind that hold, scoped and
/// token-guarded inputs, `queue`, timers and the clock. It logs what each step did, so a check
/// compares the log with the order the rule requires.
@PlainData
struct DemoMachine: TurnMachine {
    enum Input: Sendable {
        case setup                       // issues .io and .other
        case ping                        // an empty step
        case note(String)                // external, no hold: logs its text
        case mark(String)                // control: logs its text (what `queue` and `run` deliver)
        // Jobs: a key per job, work under it.
        case start(job: Int, gate: String)
        case finished(job: Int)          // logs, emits the job number under its key
        case endJob(Int)
        case emit(Int)
        case reissue(job: Int, first: String, second: String)
        case cancelJob(Int)
        case replyAfter(job: Int, gate: String, deadline: Duration?)
        case echo(Int)
        case holdCaller(Int)             // control: logs, keeps its caller without a reply
        case answerHeld                  // replies to the callers `holdCaller` kept
        case answerNow(Int)              // control: logs, replies to its caller in its own step
        // Transactions that hold .membership, and what queues behind them.
        case txn(Int, gate: String, deadline: Duration?, untilRetire: Bool)
        case txnFinished(Int)
        case abort(Int)
        case step(Int)                   // queues behind .membership; logs, emits under .io
        case scoped(Int, scope: Int)     // queues behind .membership, scoped to .job(scope)
        case guarded(Int, token: WithdrawToken)
        case revoke(WithdrawToken)
        case enqueue(String)             // queues .mark("queued <label>") behind .membership
        case endKey(Key)
        case relay(Int, first: String, second: String)
        case relayed(Int, leg: Int)
        case emitAndWork(Int)            // emits under .io, then runs work that is traced
        // Timers and the clock.
        case arm(job: Int, at: TurnInstant)
        case armIn(job: Int, after: Duration)
        case tick(job: Int, at: TurnInstant)
        case startPeriodic(job: Int, periodSeconds: Int64)
        case periodic(job: Int, at: TurnInstant, periodSeconds: Int64)
        case nowAndDeadline(job: Int, deadline: Duration)
        case runMark(String)
        case issueKey(Int)
        // Follow-ups.
        case gatedFollowUp(job: Int, gate: String, deadline: Duration?) // starts the job, arms `.finished` after a work gate
        // Lifecycle and tests.
        case shutdown
        case teardown
        case hook
        case awaitLog(Int)

        /// A transaction; with no deadline, one that never passes in a check.
        static func transaction(_ name: Int, _ gate: String, deadline: Duration? = nil, untilRetire: Bool = false) -> Input {
            .txn(name, gate: gate, deadline: deadline, untilRetire: untilRetire)
        }
    }

    enum Effect: Sendable {
        case work(job: Int, gate: String)
        case txnWork(Int, gate: String)
        case relayWork(Int, gate: String, leg: Int)
        case traced(Int)
        case echoMark(String)
    }

    @PlainData
    enum Key: Hashable, Sendable {
        case io
        case other
        case job(Int)
        case txn(Int)
        case membership
    }

    enum Query: Sendable {
        case steps
        case bump
    }

    typealias Output = Int
    typealias Reply = Int
    typealias Answer = Int
    /// One follow-up slot per job key.
    typealias FollowUpSlot = Int

    @PlainData
    struct CountWaiter: Sendable {
        var count: Int
        var caller: InputID
    }

    /// A holding request's deadline where a check never lets one pass: its gate is never opened.
    static let unbounded: Duration = .seconds(3600)

    var steps: Int = 0
    var asks: Int = 0
    var log: [String] = []
    var logWaiters: [CountWaiter] = []
    var txnCaller: [Int: InputID] = [:]
    var txnRequest: [RequestID: Int] = [:]
    var jobRequests: [RequestID: Int] = [:]
    var heldCallers: [InputID] = []
    /// The callers `handleCallerCancelled` was stepped for, in order.
    var cancelledCallers: [InputID] = []
    var relaySecond: [Int: String] = [:]

    init() {}

    func inputPolicy(for input: Input) -> InputPolicy<Key> {
        switch input {
        case .ping, .note, .echo, .start, .emit, .replyAfter, .reissue, .emitAndWork:
            return .normal(waitsFor: nil, belongsTo: nil)
        case .txn, .step:
            return .normal(waitsFor: .membership, belongsTo: nil)
        case .scoped(_, let scope):
            return .normal(waitsFor: .membership, belongsTo: .job(scope))
        case .guarded(_, let token):
            return .normal(waitsFor: .membership, belongsTo: nil, withdrawnBy: token)
        default:
            return .control
        }
    }

    mutating func note(_ line: String) {
        log.append(line)
    }

    mutating func settleLogWaiters(_ turn: inout Turn<DemoMachine>) {
        if logWaiters.isEmpty { return }
        let count = log.count
        for waiter in logWaiters where waiter.count <= count {
            turn.reply(to: waiter.caller, .success(count))
        }
        logWaiters.removeAll { $0.count <= count }
    }

    /// Records the caller and drops it from the held callers. A held caller's cancellation also
    /// emits `-1` under `.io` when that key is live, so a test sees the hook's output flushed,
    /// and replies to it, a reply that must find no waiter.
    mutating func handleCallerCancelled(_ caller: InputID, _ turn: inout MailTurn<DemoMachine>) {
        cancelledCallers.append(caller)
        guard let index = heldCallers.firstIndex(of: caller) else { return }
        heldCallers.remove(at: index)
        if turn.isLive(.io) { turn.emit(-1, for: .io) }
        turn.reply(to: caller, .success(-1))
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<DemoMachine>) {
        steps += 1
        apply(input, &turn)
        settleLogWaiters(&turn)
    }

    mutating func apply(_ input: Input, _ turn: inout Turn<DemoMachine>) {
        switch input {
        case .setup:
            turn.start(.io)
            turn.start(.other)
        case .ping:
            break
        case .note(let text), .mark(let text):
            note(text)

        case .start(let job, let gate):
            turn.start(.job(job))
            if let request = turn.request(.work(job: job, gate: gate), for: .job(job)) {
                jobRequests[request] = job
            }
        case .gatedFollowUp(let job, let gate, let deadline):
            turn.start(.job(job))
            turn.followUp(.finished(job: job), 0, of: .job(job), .afterWork(.work(job: job, gate: gate), deadline: deadline))
        case .finished(let job):
            jobRequests = jobRequests.filter { $0.value != job }
            note("finished \(job)")
            turn.emit(job, for: .job(job))
        case .endJob(let job):
            turn.end(.job(job))
        case .emit(let job):
            turn.emit(job, for: .job(job))
        case .reissue(let job, let first, let second):
            turn.start(.job(job))
            if let request = turn.request(.work(job: job, gate: first), for: .job(job)) {
                jobRequests[request] = job
            }
            let superseded = turn.start(.job(job))
            note("reissue \(job) superseded \(superseded)")
            if let request = turn.request(.work(job: job, gate: second), for: .job(job)) {
                jobRequests[request] = job
            }
        case .cancelJob(let job):
            for (request, owner) in jobRequests where owner == job {
                turn.cancel(request)
            }
        case .replyAfter(let job, let gate, let deadline):
            turn.start(.job(job))
            guard let request = turn.request(.work(job: job, gate: gate), for: .job(job), deadline: deadline) else { return }
            jobRequests[request] = job
            if let caller = turn.input { turn.reply(to: caller, .success(job), after: request) }
        case .echo(let value):
            if let caller = turn.input { turn.reply(to: caller, .success(value)) }
        case .holdCaller(let value):
            note("control \(value)")
            if let caller = turn.input { heldCallers.append(caller) }
        case .answerHeld:
            for caller in heldCallers { turn.reply(to: caller, .success(0)) }
            heldCallers.removeAll()

        case .txn(let name, let gate, let deadline, let untilRetire):
            note("begin \(name)")
            if let caller = turn.input { txnCaller[name] = caller }
            turn.start(.txn(name))
            let bound = deadline ?? Self.unbounded
            let hold: Hold<Key> = untilRetire
                ? .untilWorkerReturns(.membership, deadline: bound)
                : .untilRequestCloses(.membership, deadline: bound)
            if let request = turn.request(.txnWork(name, gate: gate), for: .txn(name), holding: hold) {
                txnRequest[request] = name
            }
        case .txnFinished(let name):
            note("end \(name)")
            txnRequest = txnRequest.filter { $0.value != name }
            turn.end(.txn(name))
            if let caller = txnCaller.removeValue(forKey: name) { turn.reply(to: caller, .success(name)) }
        case .abort(let name):
            note("abort \(name)")
            turn.end(.txn(name))
        case .step(let number):
            note("step \(number)")
            turn.emit(number, for: .io)
        case .scoped(let number, _):
            note("scoped \(number)")
        case .guarded(let number, _):
            note("guarded \(number)")
        case .revoke(let token):
            note("revoke")
            turn.revoke(token)
        case .enqueue(let label):
            let queued = turn.queue(.mark("queued \(label)"), behind: .membership)
            note("enqueue \(label) \(queued)")
        case .endKey(let key):
            note("end key \(key)")
            turn.end(key)
        case .relay(let name, let first, let second):
            note("relay \(name)")
            turn.start(.txn(name))
            relaySecond[name] = second
            turn.request(
                .relayWork(name, gate: first, leg: 1),
                for: .txn(name),
                holding: .untilRequestCloses(.membership, deadline: Self.unbounded)
            )
        case .relayed(let name, let leg):
            if leg == 1, let second = relaySecond.removeValue(forKey: name) {
                // The handover: the step that closed the first request makes the next one on
                // the same hold key.
                note("relay \(name) leg 1")
                turn.request(
                    .relayWork(name, gate: second, leg: 2),
                    for: .txn(name),
                    holding: .untilRequestCloses(.membership, deadline: Self.unbounded)
                )
            } else {
                note("relay \(name) done")
                turn.end(.txn(name))
            }
        case .emitAndWork(let number):
            turn.emit(number, for: .io)
            turn.run(.traced(number))

        case .arm(let job, let instant):
            if !turn.isLive(.job(job)) { turn.start(.job(job)) }
            turn.timer(at: instant, for: .job(job), .tick(job: job, at: instant))
        case .armIn(let job, let after):
            if !turn.isLive(.job(job)) { turn.start(.job(job)) }
            let first = turn.now
            let second = turn.now
            note("arm \(job) now \(first.wholeSeconds) \(second.wholeSeconds)")
            turn.timer(at: first + after, for: .job(job), .tick(job: job, at: first + after))
        case .tick(let job, let instant):
            note("tick \(job) at \(instant.wholeSeconds)")
        case .startPeriodic(let job, let period):
            turn.start(.job(job))
            let at = turn.now + .seconds(period)
            turn.timer(at: at, for: .job(job), .periodic(job: job, at: at, periodSeconds: period))
        case .periodic(let job, let at, let period):
            // Skip ahead on the period's grid: the next fire is the first one after now, so a
            // late fire never leaves a backlog of missed ones.
            let now = turn.now
            let length = period * 1_000_000_000
            var next = at.nanoseconds + length
            if next <= now.nanoseconds {
                next += ((now.nanoseconds - next) / length + 1) * length
            }
            let instant = TurnInstant(nanoseconds: next)
            note("periodic \(job) at \(at.wholeSeconds) next \(instant.wholeSeconds)")
            turn.timer(at: instant, for: .job(job), .periodic(job: job, at: instant, periodSeconds: period))
        case .nowAndDeadline(let job, let deadline):
            turn.start(.job(job))
            let now = turn.now
            note("now \(now.wholeSeconds)")
            if let request = turn.request(.work(job: job, gate: "never"), for: .job(job), deadline: deadline) {
                jobRequests[request] = job
            }
            _ = turn.now
        case .runMark(let label):
            turn.run(.echoMark(label))
        case .issueKey(let job):
            let issued = turn.start(.job(job))
            note("issue \(job) \(issued)")

        case .shutdown:
            note("shutdown")
            turn.close()
        case .teardown:
            note("teardown")
            turn.endAll()
        case .hook:
            note("hook start")
            StepHooks.duringStep?()
            note("hook end")
        case .awaitLog(let count):
            if let caller = turn.input { logWaiters.append(CountWaiter(count: count, caller: caller)) }
        case .answerNow(let value):
            note("answered \(value)")
            if let caller = turn.input { turn.reply(to: caller, .success(value)) }
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<DemoMachine>) {
        if let name = txnRequest.removeValue(forKey: request) {
            note("abandoned \(name) \(why)")
            if let caller = txnCaller.removeValue(forKey: name) { turn.reply(to: caller, .failure(DemoError.abandoned)) }
        } else if let job = jobRequests.removeValue(forKey: request) {
            note("abandoned job \(job) \(why)")
        }
        settleLogWaiters(&turn)
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<DemoMachine>) {
        switch input {
        case .finished(let job): note("stale \(job)")
        case .txnFinished(let name): note("stale \(name)")
        case .relayed(let name, let leg): note("stale relay \(name) leg \(leg)")
        default: break
        }
        settleLogWaiters(&turn)
    }

    mutating func answer(_ query: Query, _ turn: inout Turn<DemoMachine>) -> Int {
        switch query {
        case .steps:
            return steps
        case .bump:
            asks += 1
            return asks
        }
    }
}
