// §6.4: seeded, deterministic orders of inputs, completions, cancellations, deadlines and timers
// against `OrderModel`. After every operation the machine's recorded violations and the core's
// counters are checked against the machine's own view. A failing seed is printed; replay it with
// `TURNS_SEED=<seed> swift test --filter GeneratedOrderTests`. CI runs the fixed seed set; a
// longer run is `TURNS_SEEDS=<count>`.
//
// Every operation waits for its consequence before the next one starts: a `send` returns after
// its segment; a completion, a deadline or a timer is waited for by the `notify` its step starts.
// So a seed gives one order, run after run. (The segment budget is set high so that no drain
// continues in a job of its own; the budget has its own ordered check, 13.)

import Foundation
import SwiftStateTurns
import Testing

/// Counts the machine's notifications and lets the harness wait for the n-th of a name.
final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var waiting: [String: [(Int, CheckedContinuation<Void, Never>)]] = [:]

    func post(_ name: String) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let count = (counts[name] ?? 0) + 1
            counts[name] = count
            var ready: [CheckedContinuation<Void, Never>] = []
            waiting[name]?.removeAll { entry in
                if entry.0 <= count { ready.append(entry.1); return true }
                return false
            }
            return ready
        }
        for continuation in ready { continuation.resume() }
    }

    /// Returns once `name` has been posted at least once.
    func wait(_ name: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let posted = lock.withLock { () -> Bool in
                if (counts[name] ?? 0) >= 1 { return true }
                waiting[name, default: []].append((1, continuation))
                return false
            }
            if posted { continuation.resume() }
        }
    }
}

actor OrderActor: TurnActor {
    let core: TurnCore<OrderModel>
    nonisolated let fixture: Fixture
    nonisolated let notes: Notes

    init(fixture: Fixture, notes: Notes, parkedLimit: Int, segmentBudget: Int) {
        self.fixture = fixture
        self.notes = notes
        core = TurnCore(OrderModel(), parkedLimit: parkedLimit, segmentBudget: segmentBudget, clock: TestClock(fixture: fixture))
    }

    @concurrent nonisolated func perform(_ effect: OrderModel.Effect) async -> OrderModel.Input? {
        switch effect {
        case .work(let seq):
            await fixture.wait("work \(seq)")
            return .completed(seq: seq)
        case .notify(let name):
            notes.post(name)
            return nil
        }
    }

    func flush(_ outputs: consuming [Int]) {}

    struct View: Sendable {
        var violations: [String]
        var open: [Int]
        var pending: [Int]
        var timers: [Int: Int]
        var expectedHeld: Int
        var ended: Bool
        var stats: TurnStats
    }

    func view() -> View {
        let stats = core.stats
        return core.read { machine in
            View(
                violations: machine.violations,
                open: machine.open.keys.sorted(),
                pending: machine.open.keys.sorted() + machine.abandoned.sorted(),
                timers: machine.timers,
                expectedHeld: machine.expectedHeldKeys.count,
                ended: machine.ended,
                stats: stats
            )
        }
    }
}

/// A small deterministic generator (SplitMix64), so a seed replays on every platform.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Runs one seed and returns its failures (empty: it passed).
func runOrder(seed: UInt64, operations: Int) async -> [String] {
    var random = SeededGenerator(seed: seed)
    let fixture = Fixture()
    let notes = Notes()
    let actor = OrderActor(fixture: fixture, notes: notes, parkedLimit: 6, segmentBudget: 1_000)
    var failures: [String] = []
    var nextSeq = 1
    var nextWork = 1
    var nextToken = 1
    var tokens: [(Int, EndToken)] = []
    var log: [String] = []
    var ends: [Int: Int] = [:]

    await actor.send(.issue(0))
    await actor.send(.issue(1))

    for step in 0 ..< operations {
        let view = await actor.view()
        let choice = Int.random(in: 0 ..< 100, using: &random)
        let owner = Int.random(in: 0 ... 1, using: &random)
        let hold = Int.random(in: 10 ... 11, using: &random)
        var op = ""
        switch choice {
        case 0 ..< 22:
            // External work, maybe parked, scoped, tokened.
            let id = nextWork
            nextWork += 1
            let scoped = Bool.random(using: &random)
            let scopeEnds: Int? = scoped ? ends[owner] ?? 0 : nil
            var token: EndToken?
            var tokenID: Int?
            if Int.random(in: 0 ..< 4, using: &random) == 0 {
                let t = EndToken()
                token = t
                tokenID = nextToken
                tokens.append((nextToken, t))
                nextToken += 1
            }
            op = "work \(id) hold \(hold) scope \(scoped ? String(owner) : "-") token \(tokenID.map(String.init) ?? "-")"
            await actor.send(.work(id: id, hold: Bool.random(using: &random) ? hold : nil, scope: scoped ? owner : nil,
                                   scopeEnds: scopeEnds, token: token, tokenID: tokenID, pinned: false))
        case 22 ..< 36:
            let seq = nextSeq
            nextSeq += 1
            let retire = Int.random(in: 0 ..< 3, using: &random) == 0
            op = "startHold \(seq) owner \(owner) hold \(hold) retire \(retire)"
            await actor.send(.startHold(seq: seq, owner: owner, hold: hold, untilRetire: retire))
        case 36 ..< 56:
            guard let seq = view.pending.randomElement(using: &random) else { continue }
            op = "complete \(seq)"
            fixture.open("work \(seq)")
            await notes.wait("done \(seq)")
        case 56 ..< 63:
            guard let seq = view.open.randomElement(using: &random) else { continue }
            op = "deadline \(seq)"
            fixture.open(TestClock.gate(for: TurnInstant(nanoseconds: Int64(seq))))
            await notes.wait("abandoned \(seq)")
        case 63 ..< 69:
            guard let seq = view.open.randomElement(using: &random) else { continue }
            op = "cancel \(seq)"
            await actor.send(.cancel(seq: seq))
        case 69 ..< 74:
            op = "end \(owner)"
            ends[owner, default: 0] += 1
            await actor.send(.end(owner))
        case 74 ..< 79:
            op = "issue \(owner)"
            await actor.send(.issue(owner))
        case 79 ..< 83:
            let id = nextWork
            nextWork += 1
            op = "queue \(id) behind \(hold)"
            await actor.send(.queueBehind(id: id, hold: hold))
        case 83 ..< 87:
            guard let (tokenID, token) = tokens.randomElement(using: &random) else { continue }
            if Bool.random(using: &random) {
                op = "revoke \(tokenID)"
                await actor.send(.revoke(token, tokenID: tokenID))
            } else {
                op = "mark \(tokenID)"
                token.markEnded()
                await actor.send(.noteMarked(tokenID: tokenID))
            }
        case 87 ..< 93:
            // Timer instants are far from request deadlines, so their gates never meet.
            let seq = 1_000_000 + nextSeq
            nextSeq += 1
            op = "arm \(seq) on \(owner)"
            await actor.send(.arm(owner: owner, seq: seq))
        case 93 ..< 98:
            guard let (timerOwner, seq) = view.timers.randomElement(using: &random) else { continue }
            op = "fire \(seq) on \(timerOwner)"
            fixture.open(TestClock.gate(for: TurnInstant(nanoseconds: Int64(seq))))
            await notes.wait("fired \(seq)")
        case 98:
            op = "close"
            await actor.send(.close)
        default:
            // endAll is terminal: rarely, and only late in the run.
            guard step > operations * 3 / 4, !view.ended else { continue }
            op = "endAll"
            for key in [0, 1] { ends[key, default: 0] += 1 }
            await actor.send(.endAll)
        }
        log.append(op)

        let after = await actor.view()
        if !after.violations.isEmpty {
            failures.append("after `\(op)`: \(after.violations)")
        }
        if after.stats.openRequests != after.open.count {
            failures.append("after `\(op)`: the core has \(after.stats.openRequests) open requests, the machine \(after.open.count)")
        }
        if after.stats.heldKeys != after.expectedHeld {
            failures.append("after `\(op)`: the core holds \(after.stats.heldKeys) keys, the machine expects \(after.expectedHeld)")
        }
        if after.stats.parked > 6 + nextWork {
            failures.append("after `\(op)`: \(after.stats.parked) parked")
        }
        if after.ended, after.stats.liveKeys != 0 {
            failures.append("after `\(op)`: \(after.stats.liveKeys) live keys after endAll")
        }
        if !failures.isEmpty {
            failures.append("seed \(seed), operation \(step); the last operations: \(log.suffix(12))")
            break
        }
    }
    // End everything (cancelling the deadline and timer tasks) and let every worker return, so
    // no task outlives the run.
    if !(await actor.view()).ended { await actor.send(.endAll) }
    let rest = await actor.view()
    for seq in rest.pending {
        fixture.open("work \(seq)")
        await notes.wait("done \(seq)")
    }
    let final = await actor.view()
    if failures.isEmpty, !final.violations.isEmpty {
        failures.append("seed \(seed), at the end: \(final.violations)")
    }
    return failures
}


@Suite("Generated orders (§6.4)", .timeLimit(.minutes(2)))
struct GeneratedOrderTests {
    static var seeds: [UInt64] {
        let environment = ProcessInfo.processInfo.environment
        if let seed = environment["TURNS_SEED"].flatMap(UInt64.init) { return [seed] }
        let count = environment["TURNS_SEEDS"].flatMap(Int.init) ?? 32
        return (1 ... UInt64(count)).map { $0 }
    }

    @Test("Seeded orders keep the core's invariants and its counters match the machine's view", arguments: seeds)
    func seededOrder(seed: UInt64) async {
        let failures = await runOrder(seed: seed, operations: 300)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
