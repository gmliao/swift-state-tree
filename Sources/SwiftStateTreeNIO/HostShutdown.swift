// Sources/SwiftStateTreeNIO/HostShutdown.swift
//
// The bounded steps of a host shutdown (#351): budgets, the bounded wait, and the summary.

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// The steps of a host shutdown that run against a deadline.
enum ShutdownStep: String, Hashable, Sendable, CaseIterable {
    /// Middleware tasks cancelled and `onShutdown` run (a control plane stops sending players).
    case deregister
    /// Joins, connections and creations refused; the listener closed.
    case stopAccepting
    /// Every session closed with 1001, each joined one after its leave ran.
    case leaves
    /// Every land destroyed: destroy handlers, the save on destroy, `onLandDestroyed`.
    case destroy
}

/// When each bounded step's deadline passes. The default sleeps until it; tests open gates.
protocol ShutdownDeadlines: Sendable {
    /// Returns when `step`'s deadline, `deadline`, has passed.
    func expire(_ step: ShutdownStep, at deadline: ContinuousClock.Instant) async
}

/// The real clock.
struct ClockShutdownDeadlines: ShutdownDeadlines {
    func expire(_ step: ShutdownStep, at deadline: ContinuousClock.Instant) async {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return }
        try? await safeTaskSleep(for: remaining)
    }
}

/// How `shutdownTimeout` is split (maintainer decision C2a, #351). A stuck middleware or OnLeave
/// can cut players' leaves, but every land still gets the floor for its destroy and its save.
///
/// - Steps 1 and 2 (deregister, stop accepting) together: at most a quarter of the total and at
///   most 2 s; step 2 gets at least `stopAcceptingMinimum` of it.
/// - Step 4 (destroy): a floor of half the total. Its deadline is the total's end or the floor
///   from step 4's start, whichever is later.
/// - Step 3 (leaves): the rest, up to the total minus the floor.
///
/// Step 3 ends by the total minus the floor at the latest, so step 4's deadline is the total's
/// end, and nothing runs past the total except scheduler slack.
struct ShutdownBudget: Sendable, Equatable {
    let total: Duration
    let start: ContinuousClock.Instant

    static let stopAcceptingMinimum: Duration = .milliseconds(250)
    static let deregisterCap: Duration = .seconds(2)

    /// Steps 1 and 2 together.
    var earlySteps: Duration { min(total / 4, Self.deregisterCap) }
    /// The destroy floor.
    var destroyFloor: Duration { total / 2 }

    var deregisterDeadline: ContinuousClock.Instant {
        start + max(earlySteps - Self.stopAcceptingMinimum, .zero)
    }

    func stopAcceptingDeadline(startedAt now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        max(start + earlySteps, now + Self.stopAcceptingMinimum)
    }

    var leavesDeadline: ContinuousClock.Instant { start + total - destroyFloor }

    func destroyDeadline(startedAt now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        max(start + total, now + destroyFloor)
    }
}

/// Runs work against a deadline, without cancelling it.
///
/// The work runs in an unstructured task and the deadline in another; the first to finish
/// resumes the caller, once. Work still running at the deadline is abandoned, not cancelled:
/// it may be user code mid-await (a destroy handler, an OnLeave resolver), and the waits it
/// contains (`drainTask.value`, a membership-queue leave) ignore cancellation anyway. Not a task
/// group, which would wait for every child at its end, even a cancelled one.
enum BoundedWait {
    /// - Returns: whether the work finished before the deadline.
    static func run(
        until expire: @escaping @Sendable () async -> Void,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let race = Race()
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            race.install(continuation)
            Task { await work(); race.settle(true) }
            race.setTimer(Task { await expire(); race.settle(false) })
        }
        race.cancelTimer()
        return finished
    }

    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timer: Task<Void, Never>?

        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
        }

        func setTimer(_ task: Task<Void, Never>) {
            lock.lock(); defer { lock.unlock() }
            timer = task
        }

        func settle(_ finished: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: finished)
        }

        func cancelTimer() {
            lock.lock()
            let timer = self.timer
            lock.unlock()
            timer?.cancel()
        }
    }
}

/// Errors collected across the shutdown's steps; every step runs whatever the earlier ones did.
final class ShutdownErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}

/// What a host shutdown did, logged in one line at its end.
struct HostShutdownSummary: Sendable {
    /// Bounded steps whose deadline passed before their work finished.
    var timedOutSteps: [ShutdownStep] = []
    /// Errors from any step (a throwing middleware, a failed stop).
    var errors: [String] = []
    /// The sessions step.
    var leaves = ShutdownLeaveProgress.Snapshot()
    /// Lands whose destroy finished.
    var landsDestroyed = 0
    /// Lands whose destroy was still running at the deadline: no record saved, no `destroyed`
    /// line in the lifecycle log.
    var landsAbandoned: [LandID] = []
    /// Of `landsAbandoned`: those whose session tickets were ended before the transports stopped.
    var abandonedSessionsEnded = 0
    /// Hand-offs to the event loops the stop fence dropped (late work after the stop).
    var fenceDropped = 0
    var elapsed: Duration = .zero
}
