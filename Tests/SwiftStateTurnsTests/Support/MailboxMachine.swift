import SwiftStateTurns
import Testing

// MARK: - A machine that takes mail

/// What a mailbox machine's script step does, in order.
@PlainData
indirect enum MailOp: Sendable {
    case log(String)
    /// An output whose flush records `text` and opens "flushed `text`".
    case note(String)
    /// Calls the task-local `StepHooks.duringStep` (a collaborator the step calls).
    case hook
    /// `Turn.takeMail()`: logs "took" and the mail's labels.
    case take
    case start(Int)
    case end(Int)
    case endAll
    case close
    /// A request under `key` that holds key 99 until its gate opens.
    case hold(gate: String, key: Int = 1)
    /// A request under `key` that holds key 99 until its worker returns, after it closed too.
    case holdUntilReturn(gate: String, key: Int = 1)
    /// A request under `key`, with a deadline in whole seconds when given.
    case request(gate: String, key: Int = 1, deadlineSeconds: Int64? = nil)
    /// A `run` of the effect at `gate`: no request; a "nil" gate mails nothing back.
    case run(gate: String)
    /// A timer under `key` at `seconds`, whose input logs "timer `label`".
    case timer(String, key: Int = 1, seconds: Int64)
    /// A timer under `key` at `seconds`, whose input logs "ran `label`", then runs `then`.
    case timerRunning(String, key: Int = 1, seconds: Int64, then: [MailOp])
    /// `arm` with a gate deadline of `deadlineSeconds`.
    case armWithDeadline(String, key: Int = 1, gate: String, deadlineSeconds: Int64)
    /// An `.afterWork` follow-up under `key`, whose gate is "gate `gate`"; its step logs "ran
    /// `label`", then runs `then`.
    case arm(String, key: Int = 1, gate: String, then: [MailOp] = [])
    /// An `.afterBatch` follow-up under `key` (slot `b`), whose step logs "ran `label`".
    case armAfterBatch(String, key: Int = 1)
    case consume(key: Int = 1)
    /// An output whose flush sends `.script(ops)`.
    case send([MailOp])
    /// An output whose flush asks `query(.ask(label))`.
    case ask(String)
    /// An output whose flush asks `query(.take(label))`, whose answer takes the mailbox.
    case askTake(String)
    /// An output whose flush posts a mail.
    case post(String, then: [MailOp] = [])
    case readNow
}

/// A mail: logs "mail `label`", then runs its script.
@PlainData
struct MailNote: Sendable {
    var label: String
    var then: [MailOp]

    init(_ label: String, then: [MailOp] = []) {
        self.label = label
        self.then = then
    }
}

@PlainData
struct MailboxMachine: TurnMachine {
    enum Input: Sendable {
        case script([MailOp])
        /// A script as a control input: it steps after `close` and `endAll`.
        case control([MailOp])
        /// A normal input that waits behind key 99 (held by a `.hold` request); logs, then runs.
        case parked(String, [MailOp] = [])
        /// A parked input that `token` withdraws: logs "parked `label`" if it steps.
        case tokened(String, WithdrawToken)
        /// A follow-up's input: logs, then runs its script.
        case ran(String, [MailOp])
        /// A request's result.
        case result(String)
        /// A timer's input.
        case fired(String)
    }

    enum Effect: Sendable {
        case work(String)
    }

    enum Output {
        case note(String)
        case send([MailOp])
        case ask(String)
        case askTake(String)
        case post(MailNote)
    }

    enum Query: Sendable {
        case ask(String)
        /// Logs "answer `label` took" and the labels of `Turn.takeMail()`.
        case take(String)
    }

    typealias Key = Int
    typealias Reply = Int
    typealias Answer = Bool
    typealias FollowUpSlot = Slot
    typealias Mail = MailNote

    var log: [String] = []
    var labels: [RequestID: String] = [:]

    init() {}

    func inputPolicy(for input: Input) -> InputPolicy<Int> {
        switch input {
        case .script: return .normal(waitsFor: nil, belongsTo: nil)
        case .parked: return .normal(waitsFor: 99, belongsTo: nil)
        case .tokened(_, let token): return .normal(waitsFor: 99, belongsTo: nil, withdrawnBy: token)
        case .control, .ran, .result, .fired: return .control
        }
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<MailboxMachine>) {
        switch input {
        case .script(let ops), .control(let ops):
            run(ops, &turn)
        case .parked(let label, let ops):
            log.append("parked \(label)")
            run(ops, &turn)
        case .tokened(let label, _):
            log.append("parked \(label)")
        case .ran(let label, let ops):
            log.append("ran \(label)")
            run(ops, &turn)
        case .result(let label):
            log.append("result \(label)")
        case .fired(let label):
            log.append("timer \(label)")
        }
    }

    mutating func handleMail(_ mail: MailNote, _ turn: inout MailTurn<MailboxMachine>) {
        log.append("mail \(mail.label)")
        for op in mail.then {
            switch op {
            case .log(let text):
                log.append(text)
            case .note(let text):
                turn.emit(.note(text), for: 0)
            case .hook:
                StepHooks.duringStep?()
            case .end(let key):
                turn.end(key)
            case .close:
                turn.close()
            case .consume(let key):
                if case .ran(let label, _)? = turn.consumeFollowUp(.a, of: key) {
                    log.append("consumed \(label)")
                } else {
                    log.append("consumed nothing")
                }
            case .send(let ops):
                turn.emit(.send(ops), for: 0)
            case .ask(let label):
                turn.emit(.ask(label), for: 0)
            case .askTake(let label):
                turn.emit(.askTake(label), for: 0)
            case .post(let label, let then):
                turn.emit(.post(MailNote(label, then: then)), for: 0)
            case .readNow:
                log.append("now \(turn.now.wholeSeconds)")
            default:
                // A mail's turn can't take or arm `.afterBatch` work (MailTurn). A failed test,
                // not a crash: a crash ends every test in the process with no summary line.
                Issue.record("MailboxMachine: op \(op) in a mail")
            }
        }
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<MailboxMachine>) {
        if case .result(let label) = input { log.append("late \(label)") }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<MailboxMachine>) {
        log.append("abandoned \(labels[request] ?? "?") \(why)")
    }

    mutating func answer(_ query: Query, _ turn: inout Turn<MailboxMachine>) -> Bool {
        switch query {
        case .ask(let label):
            log.append("answer \(label)")
            return true
        case .take(let label):
            let taken = turn.takeMail().map(\.label)
            log.append((["answer \(label) took"] + taken).joined(separator: " "))
            return true
        }
    }

    mutating func run(_ ops: [MailOp], _ turn: inout Turn<MailboxMachine>) {
        for op in ops {
            switch op {
            case .log(let text):
                log.append(text)
            case .note(let text):
                turn.emit(.note(text), for: 0)
            case .hook:
                StepHooks.duringStep?()
            case .take:
                let taken = turn.takeMail().map(\.label)
                log.append((["took"] + taken).joined(separator: " "))
            case .start(let key):
                turn.start(key)
            case .end(let key):
                turn.end(key)
            case .endAll:
                turn.endAll()
            case .close:
                turn.close()
            case .hold(let gate, let key):
                if let id = turn.request(.work(gate), for: key, holding: .untilRequestCloses(99, deadline: .seconds(3600))) { labels[id] = gate }
            case .holdUntilReturn(let gate, let key):
                if let id = turn.request(.work(gate), for: key, holding: .untilWorkerReturns(99, deadline: .seconds(3600))) { labels[id] = gate }
            case .request(let gate, let key, let deadline):
                if let id = turn.request(.work(gate), for: key, deadline: deadline.map { .seconds($0) }) { labels[id] = gate }
            case .run(let gate):
                turn.run(.work(gate))
            case .timer(let label, let key, let seconds):
                turn.timer(at: .seconds(seconds), for: key, .fired(label))
            case .timerRunning(let label, let key, let seconds, let then):
                turn.timer(at: .seconds(seconds), for: key, .ran(label, then))
            case .armWithDeadline(let label, let key, let gate, let deadline):
                switch turn.followUp(.ran(label, []), .a, of: key, .afterWork(.work(gate), deadline: .seconds(deadline))) {
                case .armed(let id):
                    labels[id] = label
                    log.append("armed \(label)")
                case .joined, .refused:
                    log.append("not armed \(label)")
                }
            case .arm(let label, let key, let gate, let then):
                switch turn.followUp(.ran(label, then), .a, of: key, .afterWork(.work(gate), deadline: nil)) {
                case .armed(let id):
                    labels[id] = label
                    log.append("armed \(label)")
                case .joined, .refused:
                    log.append("not armed \(label)")
                }
            case .armAfterBatch(let label, let key):
                if case .armed = turn.followUp(.ran(label, []), .b, of: key, .afterBatch) {
                    log.append("armed \(label)")
                }
            case .consume(let key):
                if case .ran(let label, _)? = turn.consumeFollowUp(.a, of: key) {
                    log.append("consumed \(label)")
                } else {
                    log.append("consumed nothing")
                }
            case .send(let ops):
                turn.emit(.send(ops), for: 0)
            case .ask(let label):
                turn.emit(.ask(label), for: 0)
            case .askTake(let label):
                turn.emit(.askTake(label), for: 0)
            case .post(let label, let then):
                turn.emit(.post(MailNote(label, then: then)), for: 0)
            case .readNow:
                log.append("now \(turn.now.wholeSeconds)")
            }
        }
    }
}
