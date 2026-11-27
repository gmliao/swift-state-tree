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

    /// The core's diagnostics hook. A queued input opens "park #n" (n counts every queued input so
    /// far), and its release "released #n" once its batch ends. A foreign completion opens
    /// "foreign" and "foreign #n", a stale deadline, timer, follow-up or cancellation "stale
    /// deadline #n", "stale timer #n", "stale follow-up #n" or "stale cancellation #n", an idle
    /// completion "idle completion #n", a barrier wait's registration "barrier wait #n"; batch sizes and clock reads are recorded.
    func observe(_ event: TurnDiagnostic) {
        switch event {
        case .queued(let total):
            open("park #\(total)")
        case .batchEnded(let released):
            // "released #n" for each queued input released so far, opened after its batch.
            let total = lock.withLock { () -> Int in
                segmentSizes.append(released)
                return segmentSizes.reduce(0, +)
            }
            for n in (total - released + 1) ... total { open("released #\(n)") }
        case .foreignCompletion:
            open("foreign #\(bump("foreign"))")
            open("foreign")
        case .staleDeadline:
            open("stale deadline #\(bump("stale deadline"))")
        case .staleTimer:
            open("stale timer #\(bump("stale timer"))")
        case .staleFollowUp:
            open("stale follow-up #\(bump("stale follow-up"))")
        case .staleCancellation:
            open("stale cancellation #\(bump("stale cancellation"))")
        case .idleCompletion:
            open("idle completion #\(bump("idle completion"))")
        case .clockRead:
            bump("clock read")
        case .barrierWait:
            open("barrier wait #\(bump("barrier wait"))")
        }
    }

    /// Counts `name` and opens "`name` #n", n its new count: an event a test reaches by number.
    func openCounted(_ name: String) {
        open("\(name) #\(bump(name))")
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

    /// The released count of every batch that released queued inputs, in order.
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

/// A clock the test drives by hand, with monotonic time (after `swift-clocks`' `TestClock`).
/// `now` starts at zero, is moved forward by the test and counts its reads. Sleeps wait for the
/// release horizon: `release(through:)` moves `now` up to it, raises it, and wakes every sleep
/// until an instant at or before it, in instant order; a later sleep until a released instant
/// returns at once. So an uncancelled sleep never returns before `now` reaches its instant, as
/// `TurnClock` requires. A sleep returns early when its task is cancelled. When it returns it opens "woke deadline N" or
/// "cancelled deadline N" (N whole seconds, else "Nns"), so a check can wait for either.
/// `holdAfterWake` makes a woken sleep wait at "resume deadline N" before it returns. A sleep
/// that starts waiting for a release opens "sleeping deadline N #k" (k counts them).
final class TestClock: TurnClock, @unchecked Sendable {
    private struct Sleep {
        let instant: Int64
        let continuation: CheckedContinuation<Bool, Never>
    }

    let fixture: Fixture
    private let lock = NSLock()
    private var current = TurnInstant(nanoseconds: 0)
    private var readCount = 0
    /// Every sleep until an instant at or before it has returned. Nothing is released at first.
    private var horizon = Int64.min
    private var pending: [UInt64: Sleep] = [:]
    private var cancelledEarly: Set<UInt64> = []
    private var nextSleep: UInt64 = 0
    private var sleepCount = 0
    private var inFlight = 0
    /// Instants whose woken sleeps are held, with how many wakes to let through first.
    private var held: [Int64: Int] = [:]

    init(fixture: Fixture) {
        self.fixture = fixture
    }

    var now: TurnInstant {
        lock.withLock { () -> TurnInstant in
            readCount += 1
            return current
        }
    }

    /// `now`, without counting a read: for a harness that computes instants.
    var peek: TurnInstant {
        lock.withLock { current }
    }

    /// How many times `now` was read.
    var reads: Int {
        lock.withLock { readCount }
    }

    /// How many sleeps started, and how many haven't returned.
    var sleeps: Int { lock.withLock { sleepCount } }
    var sleepsInFlight: Int { lock.withLock { inFlight } }

    /// The instants the sleeps still waiting for a release sleep until, in order.
    var sleepingUntil: [TurnInstant] {
        lock.withLock { pending.values.map { TurnInstant(nanoseconds: $0.instant) }.sorted() }
    }

    /// Moves `now` only (a fire that runs late). Never backwards.
    func set(seconds: Int64) {
        set(.seconds(seconds))
    }

    func set(_ instant: TurnInstant) {
        lock.withLock {
            precondition(instant >= current, "TestClock: now moved back from \(current.nanoseconds) ns to \(instant.nanoseconds) ns")
            current = instant
        }
    }

    /// Moves `now` up to `instant` (never back), then releases every sleep until `instant` or
    /// earlier, in instant order (then start order).
    func release(through instant: TurnInstant) {
        let woken = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            current = max(current, instant)
            horizon = max(horizon, instant.nanoseconds)
            let due = pending.filter { $0.value.instant <= horizon }
                .sorted { ($0.value.instant, $0.key) < ($1.value.instant, $1.key) }
            for (id, _) in due { pending.removeValue(forKey: id) }
            return due.map(\.value.continuation)
        }
        for continuation in woken { continuation.resume(returning: true) }
    }

    func release(through seconds: Int64) {
        release(through: .seconds(seconds))
    }

    /// `set` plus `release(through:)`: `instant` must not be before `now`.
    func advance(to instant: TurnInstant) {
        set(instant)
        release(through: instant)
    }

    func advance(to seconds: Int64) {
        advance(to: .seconds(seconds))
    }

    /// A sleep that wakes for `seconds` waits at "resume deadline N" (cancellable) before it
    /// returns, after opening "woke deadline N". The first `skipping` such wakes aren't held.
    func holdAfterWake(_ seconds: Int64, skipping: Int = 0) {
        lock.withLock { held[TurnInstant.seconds(seconds).nanoseconds] = skipping }
    }

    static func gate(for instant: TurnInstant) -> String {
        let nanoseconds = instant.nanoseconds
        if nanoseconds % 1_000_000_000 == 0 { return "deadline \(nanoseconds / 1_000_000_000)" }
        return "deadline \(nanoseconds)ns"
    }

    func sleep(until instant: TurnInstant) async {
        let gate = Self.gate(for: instant)
        let id = lock.withLock { () -> UInt64 in
            nextSleep += 1
            sleepCount += 1
            inFlight += 1
            return nextSleep
        }
        let woke = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate = lock.withLock { () -> Bool? in
                    if instant.nanoseconds <= horizon { return true }
                    if cancelledEarly.remove(id) != nil { return false }
                    pending[id] = Sleep(instant: instant.nanoseconds, continuation: continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                } else {
                    fixture.openCounted("sleeping \(gate)")
                }
            }
        } onCancel: {
            let sleep = lock.withLock { () -> Sleep? in
                if let sleep = pending.removeValue(forKey: id) { return sleep }
                cancelledEarly.insert(id)
                return nil
            }
            sleep?.continuation.resume(returning: false)
        }
        fixture.open(woke ? "woke \(gate)" : "cancelled \(gate)")
        let hold = woke && lock.withLock { () -> Bool in
            guard let skips = held[instant.nanoseconds] else { return false }
            if skips == 0 { return true }
            held[instant.nanoseconds] = skips - 1
            return false
        }
        if hold {
            _ = await fixture.waitUnlessCancelled("resume \(gate)")
        }
        lock.withLock { inFlight -= 1 }
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
/// "queueFull", "refused", "abandoned").
func outcome(_ result: Result<Int, any Error>) -> String {
    switch result {
    case .success(let value):
        return "success \(value)"
    case .failure(let error):
        return error is CancellationError ? "cancelled" : "\(error)"
    }
}
