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
    case hold(gate: String, key: Int = 1)
    case timer(key: Int = 1, seconds: Int64)
    /// The next `handleAbandoned` for a follow-up runs this script (once).
    case onAbandoned([Op])
    /// The next gate result runs this script (once).
    case onGateResult([Op])

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

    var log: [String] = []
    var labels: [RequestID: String] = [:]
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
            case .hold(let gate, let key):
                turn.request(.work(gate), for: key, holding: .untilRequestCloses(99, deadline: .seconds(3600)))
            case .timer(let key, let seconds):
                turn.timer(at: .seconds(seconds), for: key, .released("timer"))
            case .onAbandoned(let then):
                abandonScript = then
            case .onGateResult(let then):
                gateResultScript = then
            }
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
