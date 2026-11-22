// The turn core's cost per operation, against a hand-written direct actor doing the same work
// (Notes/plans/2026-11-18-swift-state-turns-core.md §8). Release builds only.
//
//   TurnsBench [<bench>|all] [turn|direct|both] [iterations]
//
// `park-64` runs `iterations / 64` rounds of 64 holds; give it a multiple of 64.
//
// One bench and one side per run is what a normal counter (`perf stat`) wraps. On Darwin the
// run also prints the process's retired instructions, for development only.

import Foundation
import SwiftStateTurns

/// A clock whose sleep ends only when its task is cancelled: no bench lets a deadline pass.
struct BenchClock: TurnClock {
    var now: TurnInstant { TurnInstant(ContinuousClock.now) }

    func sleep(until instant: TurnInstant) async {
        let gate = CancelGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate.wait($0) }
        } onCancel: {
            gate.cancel()
        }
    }
}

final class CancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelled = false

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

actor BenchActor: TurnActor {
    let core = TurnCore(BenchMachine.make(), queueLimit: 1 << 20, maxReleasesPerBatch: 1 << 20, clock: BenchClock())
    var flushed = 0

    @concurrent nonisolated func perform(_ effect: Int) async -> BenchMachine.Input? {
        effect == 1 ? .done : nil
    }

    func flush(_ outputs: consuming [Int]) {
        flushed &+= outputs.count
    }

    func setUp() { send(.setup) }

    /// The synchronous benches: `n` operations inside one actor job.
    func run(_ bench: String, _ n: Int) -> Int {
        switch bench {
        case "idle": for _ in 0 ..< n { send(.noop) }
        case "emit": for _ in 0 ..< n { send(.emit) }
        case "issue-end": for _ in 0 ..< n { send(.issueEnd) }
        case "now": for _ in 0 ..< n { send(.now) }
        case "held-lookup":
            send(.takeHold)
            for _ in 0 ..< n { send(.lookup) }
            send(.releaseHold)
        case "park":
            for _ in 0 ..< n {
                send(.takeHold)
                send(.held)
                send(.releaseHold)
            }
        case "park-64":
            // Per hold: 64 outstanding at once, then released in one step.
            for _ in 0 ..< n / 64 {
                for _ in 0 ..< 64 { send(.takeKept) }
                send(.releaseKept)
            }
        case "read1":
            var sum = 0
            for i in 0 ..< n { sum &+= core.read { $0.table[i & 63] ?? 0 } }
            return sum
        case "read4":
            var sum = 0
            for i in 0 ..< n {
                sum &+= core.read { machine in
                    (machine.table[i & 63] ?? 0) &+ (machine.table[(i + 1) & 63] ?? 0)
                        &+ (machine.table[(i + 2) & 63] ?? 0) &+ (machine.table[(i + 3) & 63] ?? 0)
                }
            }
            return sum
        default: fatalError("unknown bench \(bench)")
        }
        return core.read { $0.counter } &+ flushed
    }
}

/// The same work by hand: state in the actor, no core.
actor DirectActor {
    var counter = 0
    var ticks: Int64 = 0
    var live: [Int: UInt64] = [0: 1]
    var held: [Int: Int] = [:]
    var parked: [Int: [Int]] = [:]
    var outputs: [Int] = []
    var flushed = 0
    var generation: UInt64 = 1
    let table = Dictionary(uniqueKeysWithValues: (0 ..< 64).map { ($0, $0) })

    nonisolated func perform(_ effect: Int) async -> Int { effect }

    func flushOutputs() {
        flushed &+= outputs.count
        outputs.removeAll(keepingCapacity: true)
    }

    func run(_ bench: String, _ n: Int) -> Int {
        switch bench {
        case "idle": for _ in 0 ..< n { counter &+= 1 }
        case "emit":
            for _ in 0 ..< n {
                if live[0] != nil { outputs.append(counter) }
                flushOutputs()
            }
        case "issue-end":
            for _ in 0 ..< n {
                generation &+= 1
                live[2] = generation
                live.removeValue(forKey: 2)
            }
        case "now": for _ in 0 ..< n { ticks &+= TurnInstant(ContinuousClock.now).nanoseconds }
        case "held-lookup":
            held[1] = 1
            for _ in 0 ..< n where held[2] == nil { counter &+= 1 }
            held.removeValue(forKey: 1)
        case "park-64":
            for _ in 0 ..< n / 64 {
                for _ in 0 ..< 64 { held[1, default: 0] += 1 }
                held.removeValue(forKey: 1)
                counter &+= 1
            }
        case "park":
            for _ in 0 ..< n {
                held[1, default: 0] += 1
                parked[1, default: []].append(counter)
                held.removeValue(forKey: 1)
                if let item = parked[1]?.removeFirst() { counter &+= item & 1 }
                if parked[1]?.isEmpty == true { parked.removeValue(forKey: 1) }
            }
        case "read1":
            var sum = 0
            for i in 0 ..< n { sum &+= table[i & 63] ?? 0 }
            return sum
        case "read4":
            var sum = 0
            for i in 0 ..< n {
                sum &+= (table[i & 63] ?? 0) &+ (table[(i + 1) & 63] ?? 0) &+ (table[(i + 2) & 63] ?? 0) &+ (table[(i + 3) & 63] ?? 0)
            }
            return sum
        default: fatalError("unknown bench \(bench)")
        }
        return counter &+ flushed
    }

    /// A request round trip: the work off the actor, its result back on it.
    func request() async -> Int {
        let result = await perform(1)
        counter &+= result
        return counter
    }

    func callNoop() -> Int { counter }
}

let syncBenches = ["idle", "emit", "issue-end", "held-lookup", "read1", "read4", "park", "park-64", "now", "follow-up-join"]
let asyncBenches = ["request", "call", "follow-up"]

func instructions() -> UInt64? {
    #if canImport(Darwin)
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return status == 0 ? info.ri_instructions : nil
    #else
    return nil
    #endif
}

func measure(_ bench: String, _ side: String, _ n: Int) async -> (nanoseconds: Double, instructions: Double?, sink: Int) {
    let turn = BenchActor()
    let direct = DirectActor()
    let followUps = FollowUpBenchActor()
    let directFollowUps = DirectFollowUpActor()
    await turn.setUp()
    await followUps.setUp()
    let startInstructions = instructions()
    let start = ContinuousClock.now
    var sink = 0
    switch (side, bench) {
    case ("turn", "request"): for _ in 0 ..< n { sink &+= (try? await turn.sendAndWait(.request, cancellation: .ignoresCancel)) ?? 0 }
    case ("turn", "call"): for _ in 0 ..< n { sink &+= (try? await turn.sendAndWait(.callNoop, cancellation: .ignoresCancel)) ?? 0 }
    case ("direct", "request"): for _ in 0 ..< n { sink &+= await direct.request() }
    case ("direct", "call"): for _ in 0 ..< n { sink &+= await direct.callNoop() }
    case ("turn", "follow-up"): for _ in 0 ..< n { sink &+= await followUps.armAndRun() }
    case ("direct", "follow-up"): for _ in 0 ..< n { sink &+= await directFollowUps.armAndRun() }
    case ("turn", "follow-up-join"): sink = await followUps.armMany(n)
    case ("direct", "follow-up-join"): sink = await directFollowUps.armMany(n)
    case ("turn", _): sink = await turn.run(bench, n)
    case ("direct", _): sink = await direct.run(bench, n)
    default: fatalError("unknown side \(side)")
    }
    let elapsed = ContinuousClock.now - start
    let (seconds, attoseconds) = elapsed.components
    let ns = (Double(seconds) * 1e9 + Double(attoseconds) / 1e9) / Double(n)
    var spent: Double?
    if let before = startInstructions, let after = instructions() { spent = Double(after &- before) / Double(n) }
    return (ns, spent, sink)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let only = arguments.first ?? "all"
let sides = (arguments.count > 1 ? arguments[1] : "both") == "both" ? ["turn", "direct"] : [arguments[1]]
let iterations = arguments.count > 2 ? Int(arguments[2]) : nil
let benches = only == "all" ? syncBenches + asyncBenches : [only]
#if DEBUG
print("TurnsBench: a debug build; its numbers are not comparable")
#endif
print("bench          side    ns/op     instr/op")
var total = 0
for bench in benches {
    let n = iterations ?? (asyncBenches.contains(bench) ? 100_000 : 1_000_000)
    for side in sides {
        let result = await measure(bench, side, n)
        total &+= result.sink
        let instr = result.instructions.map { String(format: "%9.1f", $0) } ?? "        -"
        print("\(bench.padding(toLength: 14, withPad: " ", startingAt: 0)) \(side.padding(toLength: 7, withPad: " ", startingAt: 0)) \(String(format: "%8.1f", result.nanoseconds)) \(instr)")
    }
}
print("sink \(total & 1)")
