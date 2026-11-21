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
/// continuation, and a task that never ends leaves its reader parked, never awaited.
func raceHangBound<T: Sendable, E: Error>(_ task: Task<T, E>) async -> Result<T, E>? {
    let race = FirstOf<Result<T, E>?>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, E>?, Never>) in
            race.start(continuation)
            race.add(Task { race.finish(await task.result) })
            race.add(Task {
                guard (try? await safeTaskSleep(for: turnTestHangBound)) != nil else { return }
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
