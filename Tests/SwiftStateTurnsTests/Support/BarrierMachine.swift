import SwiftStateTurns

/// A machine for the barrier wait (#953): callers wait on string keys holding an `Int` payload,
/// and steps release them, reply to them, end the core or close it. Its log names every way a
/// payload comes back, so a check can see that each one comes back once.
@PlainData
struct BarrierMachine: TurnMachine {
    enum Input: Sendable {
        /// A normal call: waits on `key` holding `payload`, with an optional budget in seconds.
        case wait(String, payload: Int, timeoutSeconds: Int64?)
        /// `wait`, as a control input (submitted even when its caller was cancelled before entry).
        case controlWait(String, payload: Int)
        /// Waits with a budget, then replies to its own caller in the same step: the published
        /// reply ends the wait before its timer is armed.
        case waitThenReply(String, payload: Int, timeoutSeconds: Int64)
        /// Releases every caller waiting on `key`.
        case release(String)
        /// Releases every caller.
        case releaseAll
        /// Logs `waiterCount(on: key)`.
        case count(String)
        /// Replies `value` to the caller that waits holding `payload`.
        case replyTo(payload: Int, value: Int)
        /// Starts work under key "w" whose gate is `gate`, and replies to `payload`'s caller after it.
        case replyAfterWork(payload: Int, gate: String)
        /// Releases `key`, then emits output 0, in one step: the flush comes before the replies.
        case releaseAndEmit(String)
        /// Emits output 0, then queues a `.release(key)` that steps in the same segment.
        case emitThenRelease(String)
        /// When `payload` is released, it waits again on the same key (with this budget, if any).
        case rewaitOnRelease(Int, timeoutSeconds: Int64?)
        /// When `payload` times out, its hook releases every caller.
        case releaseAllOnTimeout(Int)
        /// Releases `key`, then calls `endAll`, in one step.
        case releaseThenTeardown(String)
        /// From now on the hook emits output 0 before it answers: the flush lands between the
        /// hook's step and its reply's publication.
        case emitOnEnd
        /// Replies `value` to `payload`'s caller after work under "w" (gate `gate`), then calls
        /// `endAll` in the same step, which closes that work.
        case replyAfterWorkThenTeardown(payload: Int, gate: String)
        case teardown
        case close
        /// The work's result.
        case finished
    }

    enum Effect: Sendable {
        case work(gate: String)
    }

    typealias Output = Int
    typealias Key = String
    typealias Reply = Int
    typealias BarrierKey = String
    typealias BarrierPayload = Int

    var log: [String] = []
    /// The caller each payload's wait was made by.
    var callers: [Int: InputID] = [:]
    var rewait: [Int: Int64] = [:]
    var rewaitWithoutBudget: [Int] = []
    var releaseAllOnTimeout: [Int] = []
    var emitOnEnd: Bool = false

    init() {}

    func inputPolicy(for input: Input) -> InputPolicy<String> {
        switch input {
        case .wait: .normal(waitsFor: nil, belongsTo: nil)
        default: .control
        }
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<BarrierMachine>) {
        switch input {
        case .wait(let key, let payload, let seconds):
            guard let caller = turn.input else { return }
            callers[payload] = caller
            doWait(caller, key, payload, seconds.map { .seconds($0) }, &turn)
        case .controlWait(let key, let payload):
            guard let caller = turn.input else { return }
            callers[payload] = caller
            doWait(caller, key, payload, nil, &turn)
        case .waitThenReply(let key, let payload, let seconds):
            guard let caller = turn.input else { return }
            callers[payload] = caller
            doWait(caller, key, payload, .seconds(seconds), &turn)
            turn.reply(to: caller, .success(payload))
        case .release(let key):
            releaseEach(turn.release(where: { $0 == key }), &turn)
        case .releaseAll:
            releaseEach(turn.release(where: { _ in true }), &turn)
        case .count(let key):
            log.append("count \(key)=\(turn.waiterCount(on: key))")
        case .replyTo(let payload, let value):
            if let caller = callers[payload] { turn.reply(to: caller, .success(value)) }
        case .replyAfterWork(let payload, let gate):
            turn.start("w")
            let request = turn.request(.work(gate: gate), for: "w")
            if let caller = callers[payload] { turn.reply(to: caller, .success(payload * 10), after: request) }
        case .releaseAndEmit(let key):
            releaseEach(turn.release(where: { $0 == key }), &turn)
            turn.start("out")
            turn.emit(0, for: "out")
        case .emitThenRelease(let key):
            turn.start("out")
            turn.emit(0, for: "out")
            turn.queue(.release(key), behind: "q")
        case .rewaitOnRelease(let payload, let seconds):
            if let seconds { rewait[payload] = seconds } else { rewaitWithoutBudget.append(payload) }
        case .releaseAllOnTimeout(let payload):
            releaseAllOnTimeout.append(payload)
        case .releaseThenTeardown(let key):
            releaseEach(turn.release(where: { $0 == key }), &turn)
            turn.endAll()
        case .emitOnEnd:
            emitOnEnd = true
        case .replyAfterWorkThenTeardown(let payload, let gate):
            turn.start("w")
            let request = turn.request(.work(gate: gate), for: "w")
            if let caller = callers[payload] { turn.reply(to: caller, .success(payload * 10), after: request) }
            turn.endAll()
        case .teardown:
            turn.endAll()
        case .close:
            turn.close()
        case .finished:
            log.append("finished")
        }
    }

    mutating func doWait(_ caller: InputID, _ key: String, _ payload: Int, _ timeout: Duration?, _ turn: inout Turn<BarrierMachine>) {
        switch turn.wait(caller, on: key, holding: payload, timeout: timeout) {
        case .waiting:
            log.append("waiting \(payload) on \(key)")
        case .refused(let held, let why):
            log.append("refused \(held) \(why)")
            let error: any Error = switch why {
            case .cancelled, .noWaiter: CancellationError()
            case .ended: TurnError.closed
            }
            turn.reply(to: caller, .failure(error))
        case .expired(let held):
            log.append("expired \(held)")
            turn.reply(to: caller, .failure(TurnError.timedOut))
        }
    }

    mutating func releaseEach(_ released: [ReleasedWait<BarrierMachine>], _ turn: inout Turn<BarrierMachine>) {
        for r in released {
            log.append("released \(r.payload) from \(r.key) cancelled=\(r.cancelled)")
            if let seconds = rewait.removeValue(forKey: r.payload) {
                doWait(r.caller, r.key, r.payload, .seconds(seconds), &turn)
            } else if let index = rewaitWithoutBudget.firstIndex(of: r.payload) {
                rewaitWithoutBudget.remove(at: index)
                doWait(r.caller, r.key, r.payload, nil, &turn)
            } else if r.cancelled {
                turn.reply(to: r.caller, .failure(CancellationError()))
            } else {
                turn.reply(to: r.caller, .success(r.payload))
            }
        }
    }

    mutating func handleWaitEnded(_ ended: ReleasedWait<BarrierMachine>, _ why: WaitEnd, _ turn: inout Turn<BarrierMachine>) {
        log.append("ended \(ended.payload) \(why) cancelled=\(ended.cancelled)")
        if emitOnEnd {
            turn.start("out")
            turn.emit(0, for: "out")
        }
        if why == .timedOut, let index = releaseAllOnTimeout.firstIndex(of: ended.payload) {
            releaseAllOnTimeout.remove(at: index)
            releaseEach(turn.release(where: { _ in true }), &turn)
        }
        // A reply for a withdrawn or answered caller finds no waiter and is dropped.
        turn.reply(to: ended.caller, .failure(why.error))
    }
}
