import Foundation
import SwiftStateTurns

/// Named gates and the events of a check. An effect, a sleep or a check waits at a gate until
/// something opens it, and a gate stays open once opened. Every interleaving in these tests is
/// ordered by a gate, a core diagnostic or an awaited reply, never by a sleep or a poll.
final class Fixture: @unchecked Sendable {
    private struct Waiter {
        let name: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var opened: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellable: [UInt64: Waiter] = [:]
    private var cancelledEarly: Set<UInt64> = []
    private var nextWaiter: UInt64 = 0
    private var segmentSizes: [Int] = []
    private var traceLines: [String] = []
    private var diagnosticCounts: [String: Int] = [:]

    init() {}

    /// Returns once `name` is open. An empty name is always open.
    func wait(_ name: String) async {
        if name.isEmpty { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = self.lock.withLock { () -> Bool in
                if self.opened.contains(name) { return true }
                self.waiting[name, default: []].append(continuation)
                return false
            }
            if isOpen { continuation.resume() }
        }
    }

    /// Returns true once `name` is open, or false as soon as the calling task is cancelled.
    func waitUnlessCancelled(_ name: String) async -> Bool {
        let id = lock.withLock { () -> UInt64 in
            nextWaiter += 1
            return nextWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate = self.lock.withLock { () -> Bool? in
                    if self.opened.contains(name) { return true }
                    if self.cancelledEarly.remove(id) != nil { return false }
                    self.cancellable[id] = Waiter(name: name, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiter = self.lock.withLock { () -> Waiter? in
                if let waiter = self.cancellable.removeValue(forKey: id) { return waiter }
                self.cancelledEarly.insert(id)
                return nil
            }
            waiter?.continuation.resume(returning: false)
        }
    }

    func open(_ name: String) {
        let (plain, woken) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], [Waiter]) in
            opened.insert(name)
            let plain = waiting.removeValue(forKey: name) ?? []
            let ids = cancellable.filter { $0.value.name == name }.map(\.key)
            let woken = ids.compactMap { cancellable.removeValue(forKey: $0) }
            return (plain, woken)
        }
        for continuation in plain { continuation.resume() }
        for waiter in woken { waiter.continuation.resume(returning: true) }
    }

    func isOpen(_ name: String) -> Bool {
        lock.withLock { opened.contains(name) }
    }

    // MARK: The core's diagnostics

    /// The core's diagnostics hook. A parked input opens "park #n" (n counts every park so
    /// far), a foreign completion opens "foreign", a stale deadline or timer opens "stale
    /// deadline" or "stale timer"; segment sizes and clock reads are recorded.
    func observe(_ event: TurnDiagnostic) {
        switch event {
        case .parked(let total):
            open("park #\(total)")
        case .segmentEnded(let released):
            lock.withLock { segmentSizes.append(released) }
        case .foreignCompletion:
            bump("foreign")
            open("foreign")
        case .staleDeadline:
            open("stale deadline #\(bump("stale deadline"))")
        case .staleTimer:
            open("stale timer #\(bump("stale timer"))")
        case .clockRead:
            bump("clock read")
        }
    }

    /// Counts `name` and returns its new count.
    @discardableResult
    private func bump(_ name: String) -> Int {
        lock.withLock { () -> Int in
            diagnosticCounts[name, default: 0] += 1
            return diagnosticCounts[name] ?? 0
        }
    }

    /// How many times a diagnostic was seen: "foreign", "stale deadline", "stale timer",
    /// "clock read".
    func count(of name: String) -> Int {
        lock.withLock { diagnosticCounts[name] ?? 0 }
    }

    /// The released count of every segment that released parked inputs, in order.
    var segments: [Int] {
        lock.withLock { segmentSizes }
    }

    // MARK: Trace

    /// Appends a line to the trace that flushes and effects share, in the order they happen.
    func record(_ line: String) {
        lock.withLock { traceLines.append(line) }
    }

    var trace: [String] {
        lock.withLock { traceLines }
    }
}

/// A clock the test drives by hand. `now` starts at zero, is set by the test and counts its
/// reads. A sleep until an instant of N whole seconds waits at the gate "deadline N" (deadlines
/// and timers alike), and returns early when its task is cancelled. When it returns it opens
/// "woke deadline N" or "cancelled deadline N", so a check can wait for either.
final class TestClock: TurnClock, @unchecked Sendable {
    let fixture: Fixture
    private let lock = NSLock()
    private var current = TurnInstant(nanoseconds: 0)
    private var readCount = 0

    init(fixture: Fixture) {
        self.fixture = fixture
    }

    var now: TurnInstant {
        lock.withLock { () -> TurnInstant in
            readCount += 1
            return current
        }
    }

    /// How many times `now` was read.
    var reads: Int {
        lock.withLock { readCount }
    }

    func set(seconds: Int64) {
        lock.withLock { current = .seconds(seconds) }
    }

    static func gate(for instant: TurnInstant) -> String {
        let nanoseconds = instant.nanoseconds
        if nanoseconds % 1_000_000_000 == 0 { return "deadline \(nanoseconds / 1_000_000_000)" }
        return "deadline \(nanoseconds)ns"
    }

    func sleep(until instant: TurnInstant) async {
        let gate = Self.gate(for: instant)
        let woke = await fixture.waitUnlessCancelled(gate)
        fixture.open(woke ? "woke \(gate)" : "cancelled \(gate)")
    }
}

extension TurnInstant {
    static func seconds(_ value: Int64) -> TurnInstant {
        TurnInstant(nanoseconds: value * 1_000_000_000)
    }

    var wholeSeconds: Int64 { nanoseconds / 1_000_000_000 }
}

/// What a step calls in the middle of `handle`: the shape the core's rules forbid (reaching the
/// actor from inside a step). A task-local, so a check sets it only for the entry it makes, and
/// a machine holds no reference to it.
enum StepHooks {
    @TaskLocal static var duringStep: (@Sendable () -> Void)? = nil
}

/// A call's outcome as text: "success n", "cancelled", or the error ("closed", "withdrawn",
/// "overloaded", "refused", "abandoned").
func outcome(_ result: Result<Int, any Error>) -> String {
    switch result {
    case .success(let value):
        return "success \(value)"
    case .failure(let error):
        return error is CancellationError ? "cancelled" : "\(error)"
    }
}
