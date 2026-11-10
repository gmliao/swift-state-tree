// Tests/SwiftStateTreeTests/KeeperProbeSignals.swift
//
// Awaits points a keeper reports through its in-turn probe, instead of polling its state.

import Foundation
import Testing
@testable import SwiftStateTree

/// Counts the keeper's in-turn probe labels, so a test awaits a point instead of polling
/// state. The probe runs synchronously on the keeper at the point it names.
///
/// Each wait is bounded (`withinDeadline`): a point that never comes records an issue naming
/// it and returns `false`, and the caller returns from the test. A cancelled wait returns too.
final class KeeperProbeSignals: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let label: String
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    /// Waits cancelled before they registered.
    private var cancelledIDs: Set<UInt64> = []

    /// Install with `setInTurnProbeForTesting(signals.probe)`.
    var probe: @Sendable (String) -> Void { { [self] label in signal(label) } }

    func count(_ label: String) -> Int { lock.withLock { counts[label, default: 0] } }

    /// Waits still registered for a signal (tests of this helper).
    var pendingWaiterCount: Int { lock.withLock { waiters.count } }

    func signal(_ label: String) {
        let ready = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            counts[label, default: 0] += 1
            let now = counts[label, default: 0]
            let isReady = { (waiter: Waiter) in waiter.label == label && now >= waiter.count }
            let ready = waiters.filter(isReady).map(\.continuation)
            waiters.removeAll(where: isReady)
            return ready
        }
        ready.forEach { $0.resume(returning: true) }
    }

    /// Returns `true` once `label` was signalled at least `count` times; `false` after
    /// `deadline` (with an issue recorded) or when the waiting task is cancelled.
    func wait(
        for label: String,
        count: Int = 1,
        deadline: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let id = lock.withLock { () -> UInt64 in
            nextWaiterID &+= 1
            return nextWaiterID
        }
        // The deadline's race runs the wait in a task of its own, which the caller's
        // cancellation doesn't reach: the handler ends the wait by its ID instead.
        return await withTaskCancellationHandler {
            let reached = try? await withinDeadline(
                "probe \"\(label)\" signalled \(count) time(s)",
                deadline: deadline,
                sourceLocation: sourceLocation
            ) { await self.waitUnbounded(id: id, for: label, count: count) }
            // Timed out: the race left the wait behind, still registered; end it.
            if reached == nil { cancelWait(id: id) }
            return reached == true
        } onCancel: {
            cancelWait(id: id)
        }
    }

    /// Returns `true` once no input drain is scheduled (if one is, after its end), or `false`
    /// after `deadline`.
    func waitForInputDrainIdle<S: StateNodeProtocol>(
        _ keeper: LandKeeper<S>,
        deadline: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let ends = count("input-drain-end")
        guard await keeper.inputDrainScheduledForTesting() else { return true }
        return await wait(for: "input-drain-end", count: ends + 1, deadline: deadline, sourceLocation: sourceLocation)
    }

    /// Returns `true` once `label` reached `count`, or `false` once wait `id` was cancelled.
    private func waitUnbounded(id: UInt64, for label: String, count: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let immediate = lock.withLock { () -> Bool? in
                if cancelledIDs.remove(id) != nil { return false }
                if counts[label, default: 0] >= count { return true }
                waiters.append(Waiter(id: id, label: label, count: count, continuation: continuation))
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    private func cancelWait(id: UInt64) {
        let cancelled = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                cancelledIDs.insert(id)
                return nil
            }
            return waiters.remove(at: index).continuation
        }
        cancelled?.resume(returning: false)
    }
}

@Suite("KeeperProbeSignals", .timeLimit(.minutes(1)))
struct KeeperProbeSignalsTests {
    @Test("A wait returns true once its label reaches the count, before or after the wait starts")
    func reachesCount() async {
        let signals = KeeperProbeSignals()
        signals.signal("a")
        #expect(await signals.wait(for: "a"))
        let second = Task { await signals.wait(for: "a", count: 3) }
        signals.signal("b")
        signals.signal("a")
        signals.signal("a")
        #expect(await second.value)
    }

    @Test("A label that never comes fails the wait at its deadline instead of hanging")
    func deadlineFails() async {
        let signals = KeeperProbeSignals()
        var reached = true
        // Only the timeout the wait records counts as the known issue.
        await withKnownIssue("the wait records its timeout") {
            reached = await signals.wait(for: "never", deadline: .milliseconds(50))
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("Timed out") }
        }
        #expect(!reached)
        #expect(signals.pendingWaiterCount == 0, "the timed-out wait is no longer registered")
    }

    @Test("A cancelled wait returns")
    func cancelledWaitReturns() async {
        let signals = KeeperProbeSignals()
        let waiting = Task { await signals.wait(for: "never", deadline: .seconds(30)) }
        waiting.cancel()
        // Returns long before the deadline (the suite's time limit would catch a hang), with
        // `false` and no issue.
        #expect(await waiting.value == false)
    }
}
