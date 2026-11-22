import SwiftStateTurns

/// A reference a timer's input can carry, so a check can see when the core lets go of it.
final class Probe: Sendable {}

/// A machine for the core's one timer (#621 item 2): requests with deadlines under numbered keys,
/// each closed in a way a check picks, and abandonment steps that close or make other requests.
/// Its log names each abandonment and the clock reading its step took.
@PlainData
struct DeadlineMachine: TurnMachine {
    enum Input: Sendable {
        /// Starts key `label` if it isn't live, then makes a request under it with a deadline
        /// of `seconds` (nil: none). The request's work waits at "work <label>".
        case request(Int, seconds: Int64?)
        /// `request` for each label in `labels`, in order, in one step.
        case requests([Int], seconds: Int64)
        /// A request that closes in the step that made it.
        case requestAndCancel(Int, seconds: Int64)
        case cancel(Int)
        /// `cancel` for each label, in order, in one step.
        case cancelEach([Int])
        case end(Int)
        /// `start` over a live key: its requests close.
        case supersede(Int)
        case teardown
        /// When `label`'s request is abandoned, its step cancels `other`'s request.
        case onAbandonCancel(Int, other: Int)
        /// When `label`'s request is abandoned, its step cancels each of `others`' requests.
        case onAbandonCancelEach(Int, others: [Int])
        /// When `label`'s request is abandoned, its step calls `endAll`.
        case onAbandonTeardown(Int)
        /// When key `label`'s timer fires, its step arms each of `labels`' timers at the matching
        /// instant in `seconds` (absolute).
        case onTickArm(Int, labels: [Int], seconds: [Int64])
        /// When `label`'s request is abandoned, its step makes a request for `other` with a
        /// deadline of `nanoseconds`.
        case onAbandonRequest(Int, other: Int, nanoseconds: Int64)
        case note(String)
        /// Arms key `label`'s timer at `seconds` (starting the key if it isn't live).
        case arm(Int, seconds: Int64)
        /// `arm` with an input that carries `probe`.
        case armProbe(Int, seconds: Int64, Probe)
        /// A timer's input: logs.
        case tick(Int)
        /// A timer's input that carries a probe: logs as `tick`.
        case tickProbe(Int, Probe)
        /// A request's result.
        case completed(Int)
    }

    enum Effect: Sendable {
        case work(Int)
    }

    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int

    var log: [String] = []
    var requests: [RequestID: Int] = [:]
    var cancelOnAbandon: [Int: Int] = [:]
    var requestOnAbandon: [Int: Int] = [:]
    var requestOnAbandonNanoseconds: [Int: Int64] = [:]
    var cancelEachOnAbandon: [Int: [Int]] = [:]
    var teardownOnAbandon: Set<Int> = []
    var armOnTick: [Int: [Int]] = [:]
    var armOnTickSeconds: [Int: [Int64]] = [:]

    init() {}

    mutating func handle(_ input: Input, _ turn: inout Turn<DeadlineMachine>) {
        switch input {
        case .request(let label, let seconds):
            makeRequest(label, seconds.map { .seconds($0) }, &turn)
        case .requests(let labels, let seconds):
            for label in labels { makeRequest(label, .seconds(seconds), &turn) }
        case .requestAndCancel(let label, let seconds):
            makeRequest(label, .seconds(seconds), &turn)
            cancelRequest(of: label, &turn)
        case .cancel(let label):
            cancelRequest(of: label, &turn)
        case .cancelEach(let labels):
            for label in labels { cancelRequest(of: label, &turn) }
        case .end(let label):
            turn.end(label)
        case .supersede(let label):
            turn.start(label)
        case .teardown:
            turn.endAll()
        case .onAbandonCancel(let label, let other):
            cancelOnAbandon[label] = other
        case .onAbandonCancelEach(let label, let others):
            cancelEachOnAbandon[label] = others
        case .onAbandonTeardown(let label):
            teardownOnAbandon.insert(label)
        case .onTickArm(let label, let labels, let seconds):
            armOnTick[label] = labels
            armOnTickSeconds[label] = seconds
        case .onAbandonRequest(let label, let other, let nanoseconds):
            requestOnAbandon[label] = other
            requestOnAbandonNanoseconds[label] = nanoseconds
        case .note(let text):
            log.append(text)
        case .arm(let label, let seconds):
            if !turn.isLive(label) { turn.start(label) }
            turn.timer(at: .seconds(seconds), for: label, .tick(label))
        case .armProbe(let label, let seconds, let probe):
            if !turn.isLive(label) { turn.start(label) }
            turn.timer(at: .seconds(seconds), for: label, .tickProbe(label, probe))
        case .tick(let label), .tickProbe(let label, _):
            log.append("tick \(label) at \(turn.now.wholeSeconds)")
            if let labels = armOnTick.removeValue(forKey: label), let seconds = armOnTickSeconds.removeValue(forKey: label) {
                for (other, at) in zip(labels, seconds) {
                    if !turn.isLive(other) { turn.start(other) }
                    turn.timer(at: .seconds(at), for: other, .tick(other))
                }
            }
        case .completed(let label):
            requests = requests.filter { $0.value != label }
            log.append("completed \(label)")
            turn.emit(label, for: label)
        }
    }

    mutating func makeRequest(_ label: Int, _ deadline: Duration?, _ turn: inout Turn<DeadlineMachine>) {
        if !turn.isLive(label) { turn.start(label) }
        if let id = turn.request(.work(label), for: label, deadline: deadline) { requests[id] = label }
    }

    mutating func cancelRequest(of label: Int, _ turn: inout Turn<DeadlineMachine>) {
        for (id, owner) in requests where owner == label { turn.cancel(id) }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<DeadlineMachine>) {
        guard let label = requests.removeValue(forKey: request) else { return }
        log.append("abandoned \(label) \(why) at \(turn.now.wholeSeconds)")
        turn.emit(label, for: label)
        if let other = cancelOnAbandon.removeValue(forKey: label) { cancelRequest(of: other, &turn) }
        if let others = cancelEachOnAbandon.removeValue(forKey: label) {
            for other in others { cancelRequest(of: other, &turn) }
        }
        if teardownOnAbandon.remove(label) != nil { turn.endAll() }
        if let other = requestOnAbandon.removeValue(forKey: label),
           let nanoseconds = requestOnAbandonNanoseconds.removeValue(forKey: label) {
            makeRequest(other, .nanoseconds(nanoseconds), &turn)
        }
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<DeadlineMachine>) {
        if case .completed(let label) = input { log.append("stale \(label)") }
    }
}
