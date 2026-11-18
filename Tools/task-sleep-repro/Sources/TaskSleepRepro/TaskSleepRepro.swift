// Stresses the concurrency runtime's task allocator with sleeps and cancellation, one arm at a
// time, so a crash ("freed pointer was not the last allocation" in swift_task_dealloc) can be
// tied to one pattern. A run that finishes prints its counts and exits 0; a crash ends the
// process with a signal.
//
//   swift run -c release TaskSleepRepro --arm <arm> [--workers 2000] [--seconds 20]
//
// Arms:
//   sleep-for          Task.sleep(for:) in a child task, cancelled half the time
//   sleep-nanoseconds  Task.sleep(nanoseconds:), the same way
//   async-let          async let with a sleep inside, left unawaited half the time
//   async-let-typed    the same, in a function with typed throws
//   discarding-group   a DiscardingTaskGroup of sleeps, cancelled or thrown out of half the time

import Foundation

enum Arm: String, CaseIterable {
    case sleepFor = "sleep-for"
    case sleepNanoseconds = "sleep-nanoseconds"
    case asyncLet = "async-let"
    case asyncLetTyped = "async-let-typed"
    case discardingGroup = "discarding-group"
}

struct Options {
    var arm: Arm = .sleepFor
    var workers = 2000
    var seconds = 20.0

    init(_ arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch arguments[index] {
            case "--arm":
                guard let arm = Arm(rawValue: value) else {
                    fatalError("unknown arm \(value); one of \(Arm.allCases.map(\.rawValue))")
                }
                self.arm = arm
            case "--workers": workers = Int(value) ?? workers
            case "--seconds": seconds = Double(value) ?? seconds
            default: fatalError("unknown option \(arguments[index])")
            }
            index += 2
        }
    }
}

/// A small, fast, per-worker pseudo-random source: the pattern varies without contention.
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func coin() -> Bool { next() & 1 == 0 }
    /// 1 to 200 microseconds.
    mutating func micros() -> Int { Int(next() % 200) + 1 }
}

struct StopError: Error {}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ n: Int) { lock.lock(); value += n; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A sleep whose result is ignored: cancellation ends it early.
func sleepFor(_ micros: Int) async {
    try? await Task.sleep(for: .microseconds(micros))
}

func sleepNanos(_ micros: Int) async {
    try? await Task.sleep(nanoseconds: UInt64(micros) * 1_000)
}

/// Two `async let` sleeps; half the time one is left unawaited, so leaving the scope cancels
/// and awaits it implicitly (the teardown path of the upstream reports).
func asyncLetRound(_ rng: inout SplitMix) async -> Int {
    let a = rng.micros(), b = rng.micros(), early = rng.coin()
    async let first: Void = sleepFor(a)
    async let second: Void = sleepNanos(b)
    if early {
        await first
        return 1
    }
    await first
    await second
    return 2
}

func typedSleep(_ micros: Int, fail: Bool) async throws(StopError) {
    do {
        try await Task.sleep(for: .microseconds(micros))
    } catch {
        throw StopError()
    }
    if fail { throw StopError() }
}

/// `asyncLetRound` in a typed-throws function: one child throws half the time, and the other is
/// left to the implicit cancel.
func asyncLetTypedRound(_ rng: inout SplitMix) async throws(StopError) -> Int {
    let a = rng.micros(), b = rng.micros(), fail = rng.coin()
    async let first: Void = typedSleep(a, fail: fail)
    async let second: Void = typedSleep(b, fail: false)
    do {
        try await first
    } catch {
        throw error as! StopError
    }
    do {
        try await second
    } catch {
        throw error as! StopError
    }
    return 2
}

/// A discarding group of sleeps: half the time cancelled after the adds, half of the rest
/// thrown out of.
func discardingRound(_ rng: inout SplitMix) async -> Int {
    let count = Int(rng.next() % 6) + 2
    let cancel = rng.coin(), fail = rng.coin()
    let delays = (0..<count).map { _ in rng.micros() }
    do {
        try await withThrowingDiscardingTaskGroup { group in
            for (index, delay) in delays.enumerated() {
                group.addTask {
                    try await Task.sleep(for: .microseconds(delay))
                    if fail, index == 0 { throw StopError() }
                }
            }
            if cancel { group.cancelAll() }
        }
    } catch {}
    return count
}

/// One worker's loop: rounds of its arm until `deadline`.
func work(_ arm: Arm, seed: UInt64, deadline: ContinuousClock.Instant, counter: Counter) async {
    var rng = SplitMix(state: seed)
    var done = 0
    while ContinuousClock.now < deadline {
        switch arm {
        case .sleepFor, .sleepNanoseconds:
            let micros = rng.micros(), cancel = rng.coin()
            let child = Task {
                if arm == .sleepFor { await sleepFor(micros) } else { await sleepNanos(micros) }
            }
            if cancel { child.cancel() }
            await child.value
            done += 1
        case .asyncLet:
            done += await asyncLetRound(&rng)
        case .asyncLetTyped:
            done += (try? await asyncLetTypedRound(&rng)) ?? 1
        case .discardingGroup:
            done += await discardingRound(&rng)
        }
    }
    counter.add(done)
}

@main
struct TaskSleepRepro {
    static func main() async {
        let options = Options(CommandLine.arguments)
        let counter = Counter()
        let start = ContinuousClock.now
        let deadline = start + .milliseconds(Int(options.seconds * 1000))
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<options.workers {
                group.addTask {
                    await work(options.arm, seed: UInt64(worker) &+ 1, deadline: deadline, counter: counter)
                }
            }
        }
        let elapsed = start.duration(to: .now)
        print("arm=\(options.arm.rawValue) workers=\(options.workers) seconds=\(options.seconds) sleeps=\(counter.total) elapsed=\(elapsed) result=completed")
    }
}
