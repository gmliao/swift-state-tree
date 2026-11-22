// The machine the generated-order harness drives (GeneratedOrderTests). Two owner keys (0, 1),
// two hold keys (10, 11), scoped and tokened work sent or called, holding requests with
// deadlines, cancellation, `queue(behind:)`, timers, `.afterBatch` follow-ups (two slots per
// owner, armed and consumed), `close` and `endAll`. It keeps its own view
// of what is open, live, held, armed and queued, and records a violation whenever a step
// contradicts an invariant (§5) that it can observe. A step that resolves asynchronous work (a
// completion, an abandonment, a timer) starts a `notify` effect, which is how the harness learns
// that the step happened (a machine can't call out). Everything else the harness sends steps
// inside its own `send`.

import SwiftStateTurns

/// An output: the work it reports, and the step that emitted it (invariant 11).
struct OrderOutput: Sendable {
    var id: Int
    var step: Int
}

/// The order machine's lane report: the harness's post number. `Never` makes the laneless
/// twin, which drives the driver's `!usesLane` branches under the same operations.
protocol OrderReport: Sendable {
    /// The report for post `number`; nil for `Never`, which has none.
    static func numbered(_ number: Int) -> Self?
    var number: Int { get }
}

extension Int: OrderReport {
    static func numbered(_ number: Int) -> Int? { number }
    var number: Int { self }
}

extension Never: OrderReport {
    static func numbered(_ number: Int) -> Never? { nil }
    var number: Int { switch self {} }
}

@PlainData
struct OrderModel<LaneReport: OrderReport & PlainData>: TurnMachine {
    enum Input: Sendable {
        /// External work: queues behind `hold`, scoped to `scope` (sent after the scope's
        /// `scopeEnds`-th end or supersede), withdrawn if `token` ended. `pinned`: queued by a
        /// step, not sent from outside.
        case work(id: Int, hold: Int?, scope: Int?, scopeEnds: Int?, token: WithdrawToken?, tokenID: Int?, pinned: Bool)
        case start(Int)
        case end(Int)
        case startHold(seq: Int, owner: Int, hold: Int, untilRetire: Bool)
        case completed(seq: Int)
        case cancel(seq: Int)
        case queueBehind(id: Int, hold: Int)
        case revoke(WithdrawToken, tokenID: Int)
        case noteMarked(tokenID: Int)
        case arm(owner: Int, seq: Int)
        case fired(owner: Int, seq: Int)
        case close
        case endAll
        /// Follow-ups: arm one in `slot` of `owner`; consume it; the follow-up's own input.
        case armFollowUp(owner: Int, slot: Int, label: Int)
        case consumeFollowUp(owner: Int, slot: Int)
        case followUpRan(label: Int)
    }

    /// The machine's mirror of a pending follow-up: its id, owner, slot, and the owner's end count
    /// when it was armed (its generation).
    @PlainData
    struct FollowUpMirror: Sendable {
        var id: RequestID
        var owner: Int
        var slot: Int
        var ends: Int
    }

    enum Effect: Sendable {
        case work(seq: Int)
        case notify(String)
    }

    typealias Output = OrderOutput
    typealias Key = Int
    typealias Reply = Int
    typealias FollowUpSlot = Int

    var violations: [String] = []
    /// Request seq → id, for the requests this machine believes open.
    var open: [Int: RequestID] = [:]
    var seqOf: [RequestID: Int] = [:]
    var holdOf: [Int: Int] = [:]
    var ownerOf: [Int: Int] = [:]
    var untilRetire: Set<Int> = []
    /// Abandoned `.untilWorkerReturns` requests whose worker hasn't returned: they keep their hold.
    var retiring: [Int: Int] = [:]
    /// Abandoned and not yet seen stale.
    var abandoned: Set<Int> = []
    var timers: [Int: Int] = [:]
    var markedTokens: Set<Int> = []
    var closed: Bool = false
    var ended: Bool = false
    var steppedWork: [Int] = []
    /// How many times each key's scope ended: `end`, a supersede (`start` over a live key), or
    /// `endAll` for every key. Each withdraws the queued inputs scoped to the key (rules 4, 7).
    var ends: [Int: Int] = [:]
    /// Steps so far; an output carries the step that emitted it.
    var stepCount: Int = 0
    /// The IDs of the outputs emitted under a live key, in order: what the sink must receive.
    var expectedOutputs: [Int] = []
    /// Per hold key, the last work ID that stepped behind it (rule 7: FIFO per hold key).
    var lastSteppedBehind: [Int: Int] = [:]
    /// Queued with `queue(behind:)` and accepted; and those `endAll` dropped before they stepped.
    var queued: Set<Int> = []
    var droppedQueued: Set<Int> = []
    /// Handlers running now; more than one is a step entered from inside a step (invariants 2, 15).
    var depth: Int = 0
    /// Pending follow-ups by label, and their labels by id and by `owner * 10 + slot`.
    var followUps: [Int: FollowUpMirror] = [:]
    var followUpLabels: [RequestID: Int] = [:]
    var followUpBySlot: [Int: Int] = [:]
    /// Follow-ups that stepped, and those closed unrun.
    var ranFollowUps: Int = 0
    /// The lane reports stepped, in order.
    var reportsStepped: [Int] = []
    var closedFollowUps: Int = 0

    func inputPolicy(for input: Input) -> InputPolicy<Int> {
        switch input {
        case .work(_, let hold, let scope, _, let token, _, let pinned):
            // A pinned input reaches the core through `queue`, never through admission.
            pinned ? .control : .normal(waitsFor: hold, belongsTo: scope, withdrawnBy: token)
        default:
            .control
        }
    }

    /// The hold keys the core should count as held: open holding requests, and retiring workers.
    var expectedHeldKeys: Set<Int> {
        Set(open.keys.compactMap { holdOf[$0] }).union(retiring.values)
    }

    mutating func violate(_ text: String) { violations.append(text) }

    mutating func enter() {
        if depth != 0 { violate("a step entered while another ran") }
        depth += 1
        stepCount += 1
    }

    mutating func handleReport(_ report: LaneReport, _ turn: inout ReportTurn<OrderModel>) {
        enter()
        defer { depth -= 1 }
        let number = report.number
        if reportsStepped.contains(number) { violate("report \(number) stepped twice") }
        reportsStepped.append(number)
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<OrderModel>) {
        enter()
        defer { depth -= 1 }
        switch input {
        case .work(let id, let hold, let scope, let scopeEnds, _, let tokenID, let pinned):
            if ended { violate("work \(id) stepped after endAll") }
            if closed, !pinned { violate("external work \(id) stepped after close") }
            if let scope, (ends[scope] ?? 0) != scopeEnds {
                violate("work \(id) stepped after its scope \(scope) ended or was superseded")
            }
            if let tokenID, markedTokens.contains(tokenID) { violate("work \(id) stepped after its token ended") }
            if let hold {
                if let last = lastSteppedBehind[hold], last > id {
                    violate("work \(id) stepped behind \(hold) after work \(last), which came later")
                }
                lastSteppedBehind[hold] = id
            }
            if droppedQueued.contains(id) { violate("queued work \(id) stepped after endAll dropped it") }
            steppedWork.append(id)
            // One output, under its scope (or owner 0); delivered only if that key is live.
            let key = scope ?? 0
            if turn.isLive(key) { expectedOutputs.append(id) }
            turn.emit(OrderOutput(id: id, step: stepCount), for: key)
            if let caller = turn.input { turn.reply(to: caller, .success(id)) }
        case .start(let key):
            if turn.start(key) { ends[key, default: 0] += 1 }
            timers.removeValue(forKey: key)
            closeTracked(owner: key)
        case .end(let key):
            turn.end(key)
            ends[key, default: 0] += 1
            timers.removeValue(forKey: key)
            closeTracked(owner: key)
        case .startHold(let seq, let owner, let hold, let retire):
            let holding: Hold<Int> = retire
                ? .untilWorkerReturns(hold, deadline: .nanoseconds(Int64(seq)))
                : .untilRequestCloses(hold, deadline: .nanoseconds(Int64(seq)))
            if let id = turn.request(.work(seq: seq), for: owner, holding: holding) {
                open[seq] = id
                seqOf[id] = seq
                holdOf[seq] = hold
                if retire { untilRetire.insert(seq) }
                ownerOf[seq] = owner
            }
        case .completed(let seq):
            if open.removeValue(forKey: seq) == nil { violate("completion \(seq) handled after its request closed") }
            if ended { violate("completion \(seq) handled after endAll") }
            turn.run(.notify("done \(seq)"))
        case .cancel(let seq):
            if let id = open[seq] { turn.cancel(id) }
        case .queueBehind(let id, let hold):
            let work = Input.work(id: id, hold: hold, scope: nil, scopeEnds: nil, token: nil, tokenID: nil, pinned: true)
            if turn.queue(work, behind: hold) {
                if ended { violate("queue \(id) accepted after endAll") }
                queued.insert(id)
            } else if !ended {
                violate("queue \(id) refused before endAll")
            }
        case .revoke(let token, let tokenID):
            turn.revoke(token)
            markedTokens.insert(tokenID)
        case .noteMarked(let tokenID):
            markedTokens.insert(tokenID)
        case .arm(let owner, let seq):
            if turn.isLive(owner) {
                turn.timer(at: TurnInstant(nanoseconds: Int64(seq)), for: owner, .fired(owner: owner, seq: seq))
                timers[owner] = seq
            }
        case .fired(let owner, let seq):
            if timers[owner] != seq { violate("timer \(seq) fired, but \(String(describing: timers[owner])) is the current one") }
            if ended { violate("timer \(seq) fired after endAll") }
            timers.removeValue(forKey: owner)
            turn.run(.notify("fired \(seq)"))
        case .close:
            turn.close()
            closed = true
        case .endAll:
            turn.endAll()
            for key in [0, 1] { ends[key, default: 0] += 1 }
            closed = true
            ended = true
            timers.removeAll()
            droppedQueued.formUnion(queued.subtracting(steppedWork))
            for seq in open.keys.sorted() { markAbandoned(seq) }
        case .armFollowUp(let owner, let slot, let label):
            let refusable = ended || !turn.isLive(owner)
            let pending = followUpBySlot[owner * 10 + slot]
            switch turn.followUp(.followUpRan(label: label), slot, of: owner, .afterBatch) {
            case .armed(let id):
                if refusable { violate("follow-up \(label) armed under a key that isn't live") }
                if let pending { violate("follow-up \(label) armed while \(pending) was pending in its slot (invariant 19)") }
                followUps[label] = FollowUpMirror(id: id, owner: owner, slot: slot, ends: ends[owner] ?? 0)
                followUpLabels[id] = label
                followUpBySlot[owner * 10 + slot] = label
            case .joined(let id):
                if pending == nil || followUps[pending ?? -1]?.id != id {
                    violate("follow-up \(label) joined \(id), but the slot's pending one is \(String(describing: pending))")
                }
            case .refused:
                if !refusable { violate("follow-up \(label) refused under a live key") }
            }
        case .consumeFollowUp(let owner, let slot):
            let pending = followUpBySlot.removeValue(forKey: owner * 10 + slot)
            let consumed = turn.consumeFollowUp(slot, of: owner)
            switch (pending, consumed) {
            case (let label?, .followUpRan(let got)?):
                if got != label { violate("consume of \(owner)/\(slot) returned \(got), the mirror has \(label)") }
                if let mirror = followUps.removeValue(forKey: label) { followUpLabels.removeValue(forKey: mirror.id) }
            case (nil, nil):
                break
            default:
                violate("consume of \(owner)/\(slot): the mirror has \(String(describing: pending)), the core returned \(String(describing: consumed))")
            }
        case .followUpRan(let label):
            // Invariant 18: steps once, while pending, under the generation it was armed in.
            guard let mirror = followUps.removeValue(forKey: label) else {
                violate("follow-up \(label) stepped after it was consumed or closed, or twice")
                return
            }
            if (ends[mirror.owner] ?? 0) != mirror.ends || ended {
                violate("follow-up \(label) stepped after its key's generation ended")
            }
            followUpLabels.removeValue(forKey: mirror.id)
            followUpBySlot.removeValue(forKey: mirror.owner * 10 + mirror.slot)
            ranFollowUps += 1
        }
    }

    /// The core closes an ended or superseded key's requests; mirror it.
    mutating func closeTracked(owner: Int) {
        for (seq, _) in open where ownerOf[seq] == owner { markAbandoned(seq) }
    }

    mutating func markAbandoned(_ seq: Int) {
        guard open.removeValue(forKey: seq) != nil else { return }
        abandoned.insert(seq)
        if untilRetire.contains(seq), let hold = holdOf[seq] { retiring[seq] = hold }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<OrderModel>) {
        enter()
        defer { depth -= 1 }
        if let label = followUpLabels.removeValue(forKey: request) {
            // A follow-up closed unrun: only by its key's end, a supersede or endAll.
            guard let mirror = followUps.removeValue(forKey: label) else { return }
            if why != .keyEnded { violate("follow-up \(label) closed with \(why)") }
            if !ended, (ends[mirror.owner] ?? 0) == mirror.ends {
                violate("follow-up \(label) closed while its key's generation was live")
            }
            followUpBySlot.removeValue(forKey: mirror.owner * 10 + mirror.slot)
            closedFollowUps += 1
            return
        }
        guard let seq = seqOf[request] else {
            violate("an abandonment for a request this machine never made")
            return
        }
        // Closed by the machine's own end/issue/endAll: already mirrored. By deadline or cancel: now.
        if open[seq] != nil {
            if why == .keyEnded { violate("request \(seq) abandoned as keyEnded while its key was live") }
            markAbandoned(seq)
        }
        turn.run(.notify("abandoned \(seq)"))
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<OrderModel>) {
        enter()
        defer { depth -= 1 }
        guard case .completed(let seq) = input else {
            violate("a stale input that isn't a completion")
            return
        }
        if open[seq] != nil { violate("completion \(seq) went stale while its request was open") }
        abandoned.remove(seq)
        retiring.removeValue(forKey: seq)
        turn.run(.notify("done \(seq)"))
    }
}
