import Foundation
import SwiftStateTree
import SwiftStateTurns
import Testing

/// The bound on a test's own wait for an event that a regression may never bring: the same 60 s
/// as `testHangBound` in SwiftStateTreeTestSupport, which this target doesn't link. A suite's
/// `.timeLimit` reports a slow test but can't end a wait that ignores cancellation
/// (Notes/solutions/2026-11-20-a-time-limit-does-not-end-a-wait-that-never-resumes.md), so every
/// wait the follow-up cases make from the test's own task goes through one of the functions
/// below. It costs nothing when the event comes: each wait ends on the event, not on a poll of
/// the bound.
let turnTestHangBound: Duration = .seconds(60)

/// `body`'s result, or nil when the bound runs out first or the test's task is cancelled (its
/// time limit). `body` runs in a task of its own, cancelled then; it is never awaited after that,
/// so a body that ignores cancellation is abandoned parked and the wait still ends.
func withinTurnHangBound<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T? {
    let task = Task { await body() }
    guard let result = await raceHangBound(task) else {
        task.cancel()
        return nil
    }
    return result.get()
}

extension Fixture {
    /// The test's own wait for `name`: true once it is open; false, with an issue recorded, when
    /// the hang bound runs out or the test is cancelled first. Effects and checks keep `wait` and
    /// `waitUnlessCancelled`: a test may end with one of them parked at a gate on purpose.
    @discardableResult
    func reach(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let opened = await withinTurnHangBound { await self.waitUnlessCancelled(name) } ?? false
        if !opened { Issue.record("\"\(name)\" never opened", sourceLocation: sourceLocation) }
        return opened
    }
}

/// `task`'s value (a quiescence wait's answer), or false with an issue recorded when the hang
/// bound runs out or the test is cancelled first. `task` is cancelled then, and never awaited
/// after that: a wait whose own cancellation path is broken is abandoned parked, and the test
/// fails instead of parking with it.
func settled(_ task: Task<Bool, Never>, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
    guard let result = await raceHangBound(task) else {
        task.cancel()
        Issue.record("a task the test awaits never ended", sourceLocation: sourceLocation)
        return false
    }
    return result.get()
}

/// A wait that answers false when cancelled (a quiescence wait), under the hang bound: false when
/// the bound runs out first.
func bounded(_ wait: @escaping @Sendable () async -> Bool) async -> Bool {
    await withinTurnHangBound(wait) ?? false
}

/// `task`'s result, or nil when the hang bound runs out or the test's task is cancelled first. It
/// neither cancels `task` nor waits for it to end: a reader task and a timer race to resume one
/// continuation, and a task that never ends leaves its reader parked, never awaited. Once any
/// wait in the process has run out its bound, later ones get `HangBoundTrip.tripped`'s short
/// bound (see there).
func raceHangBound<T: Sendable, E: Error>(_ task: Task<T, E>) async -> Result<T, E>? {
    let race = FirstOf<Result<T, E>?>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, E>?, Never>) in
            race.start(continuation)
            race.add(Task { race.finish(await task.result) })
            race.add(Task {
                guard (try? await safeTaskSleep(for: HangBoundTrip.bound)) != nil else { return }
                HangBoundTrip.trip()
                race.finish(nil)
            })
        }
    } onCancel: {
        race.finish(nil)
    }
}

/// The first of several racers resumes a continuation, once; later ones do nothing. A finish that
/// lands before the continuation is set (a cancellation before the wait) is kept for it. The
/// racers' tasks are cancelled once one has finished, so a bound's sleep doesn't outlive the wait.
final class FirstOf<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    /// A finish that landed before `start`, kept for it.
    private var early: [T] = []
    private var done = false
    private var racers: [Task<Void, Never>] = []

    func start(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if let value = early.first {
            done = true
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func add(_ racer: Task<Void, Never>) {
        lock.lock()
        let cancelNow = done
        if !done { racers.append(racer) }
        lock.unlock()
        if cancelNow { racer.cancel() }
    }

    func finish(_ value: T) {
        lock.lock()
        if done || !early.isEmpty {
            lock.unlock()
            return
        }
        guard let continuation else {
            early = [value]
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        let racers = self.racers
        self.racers = []
        lock.unlock()
        for racer in racers { racer.cancel() }
        continuation.resume(returning: value)
    }
}

/// `task`'s result, or nil with an issue recorded when the hang bound runs out or the test is
/// cancelled first. Unlike `settled`, it doesn't cancel `task`: a task that ignores cancellation
/// (an `.ignoresCancel` call whose reply a regression holds back) loses the race, is abandoned
/// parked, and is never awaited, so the test fails instead of parking with it. Keep
/// `.ignoresCancel` where the case checks it; this only bounds the test's own wait.
func firstOrBound<T: Sendable, E: Error>(
    _ task: Task<T, E>,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Result<T, E>? {
    let first = await raceHangBound(task)
    if first == nil { Issue.record("a task the test awaits never ended", sourceLocation: sourceLocation) }
    return first
}

/// A call task's result under `firstOrBound`: a task that never ends reads as a failure
/// (`TurnHangBoundExceeded`), after the issue is recorded, so `outcome(_:)` and its expectation
/// see it.
func boundedResult(
    _ task: Task<Int, any Error>,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Result<Int, any Error> {
    await firstOrBound(task, sourceLocation: sourceLocation) ?? .failure(TurnHangBoundExceeded())
}

/// `call` run in a task of its own, under `firstOrBound`: for a file that makes no tasks itself
/// (a machine's file, by the turns lint's machine-file rule).
func firstOrBound<T: Sendable>(
    sourceLocation: SourceLocation = #_sourceLocation,
    call: @escaping @Sendable () async throws -> T
) async -> Result<T, any Error>? {
    await firstOrBound(Task { try await call() }, sourceLocation: sourceLocation)
}

/// `call` run in a task of its own, under `boundedResult`; see `firstOrBound(call:)`.
func boundedResult(
    sourceLocation: SourceLocation = #_sourceLocation,
    call: @escaping @Sendable () async throws -> Int
) async -> Result<Int, any Error> {
    await boundedResult(Task { try await call() }, sourceLocation: sourceLocation)
}

/// What `boundedResult` answers for a task that never ended within the hang bound.
struct TurnHangBoundExceeded: Error, CustomStringConvertible {
    var description: String { "hang bound exceeded" }
}

/// Once one wait has run out the hang bound, the core under test is known to hang, so later
/// waits in the process get 1 s instead of 60 s: a run whose tests make many waits one after
/// another (orders in a loop, generated seeds) ends in about one bound, not one per wait. The
/// first wait that ran out has recorded its issue; the later ones record theirs too.
enum HangBoundTrip {
    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var wasTripped = false
    static let tripped: Duration = .seconds(1)

    static var bound: Duration {
        lock.withLock { wasTripped } ? tripped : turnTestHangBound
    }

    static func trip() {
        lock.withLock { wasTripped = true }
    }
}

/// Runs a test's whole body in a task of its own under the hang bound: for a test whose waits
/// can't go through the helpers above (lines inside a `// docs:` block stay as documented). A
/// body that never ends records an issue, is cancelled and is abandoned, never awaited.
func withinTestHangBound(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> Void
) async throws {
    let task = Task { try await body() }
    guard let result = await raceHangBound(task) else {
        task.cancel()
        Issue.record("the test's body never ended within the hang bound", sourceLocation: sourceLocation)
        return
    }
    try result.get()
}
