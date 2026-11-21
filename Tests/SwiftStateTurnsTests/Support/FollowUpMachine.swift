import SwiftStateTurns

// MARK: - The machine and its actor

/// What a script step does, in order.
@PlainData
indirect enum Op: Sendable {
    case start(Int)
    case end(Int)
    case endAll
    case close
    case arm(String, Placement = .slot(.a), key: Int = 1, Trigger = .batch, then: [Op] = [])
    case consume(Slot = .a, key: Int = 1)
    case pending(Slot = .a, key: Int = 1)
    case readNow
    /// A request under `key` that holds key 99 until its gate opens.
    case hold(gate: String, key: Int = 1, deadlineSeconds: Int64 = 3600)
    /// A request under `key` that holds nothing; it closes when its gate opens.
    case request(gate: String, key: Int = 1)
    case timer(key: Int = 1, seconds: Int64)
    /// The next `handleAbandoned` for a follow-up runs this script (once).
    case onAbandoned([Op])
    /// The next gate result runs this script (once).
    case onGateResult([Op])
    /// `cancel` with the pending follow-up's id (a notification id: nothing happens).
    case cancelPending(Slot = .a, key: Int = 1)
    /// Replies to the step's caller `after:` the pending follow-up's id (published at once).
    case replyAfterPending(Slot = .a, key: Int = 1)

    /// Shorthands for `arm` with a trigger or a key and the default slot.
    static func arm(_ label: String, _ trigger: Trigger, then: [Op] = []) -> Op {
        .arm(label, .slot(.a), key: 1, trigger, then: then)
    }

    static func arm(_ label: String, key: Int, _ trigger: Trigger = .batch) -> Op {
        .arm(label, .slot(.a), key: key, trigger)
    }

    static func arm(_ label: String, then: [Op]) -> Op {
        .arm(label, .slot(.a), key: 1, .batch, then: then)
    }
}

@PlainData
enum Slot: Hashable, Sendable {
    case a, b
}

/// Wraps a slot so `arm`'s shorthands don't overload on it.
@PlainData
enum Placement: Sendable {
    case slot(Slot)
}

@PlainData
enum Trigger: Sendable {
    case batch
    case work(gate: String, result: Bool = false, deadlineSeconds: Int64? = nil)
}

@PlainData
struct FollowUpMachine: TurnMachine {
    enum Input: Sendable {
        case script([Op])
        /// A script as a control input: it steps after `close` and `endAll`.
        case controlScript([Op])
        /// A follow-up's input: logs, then runs its script.
        case ran(String, then: [Op])
        /// A gate's own result.
        case gateResult(String)
        /// A normal input that waits behind key 99 (held by a `.hold` request).
        case parked(String)
        /// `parked`, which runs a script when it steps.
        case parkedScript(String, [Op])
        case released(String)
    }

    enum Effect: Sendable {
        case gate(String, result: Bool)
        case work(String)
    }

    typealias Key = Int
    typealias Output = Never
    typealias Reply = Int
    typealias FollowUpSlot = Slot

    /// A query whose answer step consumes a follow-up (case 31).
    enum Query: Sendable {
        case consume(Slot, key: Int)
    }

    typealias Answer = Bool

    var log: [String] = []
    var labels: [RequestID: String] = [:]
    /// Every id an arm returned as `.armed`, in order.
    var armedIDs: [RequestID] = []
    var ran: Int = 0
    var abandoned: Int = 0
    var abandonScript: [Op] = []
    var gateResultScript: [Op] = []

    init() {}

    func inputPolicy(for input: Input) -> InputPolicy<Int> {
        switch input {
        // A follow-up's input asks to wait behind key 99: the core steps it as a control input anyway.
        case .ran: return .normal(waitsFor: 99, belongsTo: nil)
        case .script: return .normal(waitsFor: nil, belongsTo: nil)
        case .parked, .parkedScript: return .normal(waitsFor: 99, belongsTo: nil)
        case .gateResult, .released, .controlScript: return .control
        }
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<FollowUpMachine>) {
        switch input {
        case .script(let ops), .controlScript(let ops):
            run(ops, &turn)
        case .ran(let label, let then):
            ran += 1
            log.append("ran \(label)")
            run(then, &turn)
        case .gateResult(let label):
            log.append("gate result \(label)")
            let then = gateResultScript
            gateResultScript = []
            run(then, &turn)
        case .released:
            break
        case .parked(let label):
            log.append("parked \(label)")
        case .parkedScript(let label, let ops):
            log.append("parked \(label)")
            run(ops, &turn)
        }
    }

    mutating func run(_ ops: [Op], _ turn: inout Turn<FollowUpMachine>) {
        for op in ops {
            switch op {
            case .start(let key):
                turn.start(key)
            case .end(let key):
                turn.end(key)
            case .endAll:
                turn.endAll()
            case .close:
                turn.close()
            case .arm(let label, .slot(let slot), let key, let trigger, let then):
                let core: FollowUpTrigger<Effect>
                switch trigger {
                case .batch:
                    core = .afterBatch
                case .work(let gate, let result, let deadline):
                    core = .afterWork(.gate(gate, result: result), deadline: deadline.map { .seconds($0) })
                }
                switch turn.followUp(.ran(label, then: then), slot, of: key, core) {
                case .armed(let id):
                    labels[id] = label
                    armedIDs.append(id)
                    log.append("armed \(label)")
                case .joined(let id):
                    log.append("joined \(labels[id] ?? "?")")
                case .refused:
                    log.append("refused \(label)")
                }
            case .consume(let slot, let key):
                if case .ran(let label, _)? = turn.consumeFollowUp(slot, of: key) {
                    log.append("consumed \(label)")
                } else {
                    log.append("consumed nothing")
                }
            case .pending(let slot, let key):
                log.append("pending \(turn.followUpPending(slot, of: key).flatMap { labels[$0] } ?? "none")")
            case .readNow:
                _ = turn.now
                log.append("now")
            case .hold(let gate, let key, let deadline):
                turn.request(.work(gate), for: key, holding: .untilRequestCloses(99, deadline: .seconds(deadline)))
            case .request(let gate, let key):
                turn.request(.work(gate), for: key)
            case .timer(let key, let seconds):
                turn.timer(at: .seconds(seconds), for: key, .released("timer"))
            case .onAbandoned(let then):
                abandonScript = then
            case .onGateResult(let then):
                gateResultScript = then
            case .cancelPending(let slot, let key):
                if let id = turn.followUpPending(slot, of: key) { turn.cancel(id) }
                log.append("cancel sent")
            case .replyAfterPending(let slot, let key):
                if let caller = turn.input, let id = turn.followUpPending(slot, of: key) {
                    turn.reply(to: caller, .success(1), after: id)
                }
            }
        }
    }

    mutating func answer(_ query: Query, _ turn: inout Turn<FollowUpMachine>) -> Bool {
        switch query {
        case .consume(let slot, let key):
            guard case .ran(let label, _)? = turn.consumeFollowUp(slot, of: key) else { return false }
            log.append("consumed \(label)")
            return true
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<FollowUpMachine>) {
        guard let label = labels[request] else { return }
        abandoned += 1
        log.append("abandoned \(label) \(why)")
        let then = abandonScript
        abandonScript = []
        run(then, &turn)
    }
}
