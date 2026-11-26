// Sources/SwiftStateTree/Runtime/KeeperActionTables.swift
//
// The action flow's tables outside the model (#700 K1b-5 rev 2.3 D11): a job's task handle and
// abandonment, the callers waiting on slots, and the test waiters and watchers. Not plain (tasks,
// continuations), so they can't be model fields. They live in `KeeperTurnSide`, so a turn body
// reaches them through the side it was given, never through the actor.

import Foundation

/// Set by an action job's caller when it is cancelled, from its cancellation handler, which
/// can't wait for the keeper; read by the job's completion segment.
final class ActionJobCallerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

/// A job's references, beside the model until K5 (the task, the abandonment) and K2's
/// `JobCancellation` (the caller's flag). Keyed as `actionJobs`; the two are inserted and
/// removed together.
struct KeeperActionJobTask {
    var task: Task<Void, Never>?
    /// Its resolvers' abandonment (the caller stopped waiting while they still run). The job
    /// keeps its place in the caps until they end.
    let abandonment: ResolverAbandonment
    /// The caller was cancelled while waiting: the completion fails with `CancellationError`
    /// instead of delivering, unless it ran first.
    let callerCancelled = ActionJobCallerCancellation()
}

/// Tests: what a slot watcher waits for, a fill or a waiter, and on which slot.
struct KeeperSlotWatchKey: Hashable {
    let waiter: Bool
    let sequence: Int64
}

/// The action tables a turn body changes (§3.1's D11 rows, §3.3's waiter tables).
struct KeeperActionTables {
    /// Each job's task handle and abandonment, keyed as `model.actionJobs`.
    private(set) var jobTasks: [Int64: KeeperActionJobTask] = [:]
    /// Tests only: waiters for a job to leave the job table (`waitForActionJobsForTesting`).
    var removalWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]
    /// The caller waiting on a slot, until K2's `InputID`. A slot holds at most one of a result
    /// and a waiter.
    var slotWaiters: [Int64: CheckedContinuation<InputOutcome, any Error>] = [:]
    /// Tests: the watchers `watchActionSlotForTesting` registered, each the continuation of the
    /// stream it returned.
    var slotWatchers: [KeeperSlotWatchKey: [(id: UUID, continuation: AsyncStream<Void>.Continuation)]] = [:]
    /// Tests: whether the call sites run the alignment check (`setActionTableAuditForTesting`).
    /// Off in production: the check walks every slot, input-turn result and failure, so running
    /// it at each completed pair would cost O(tables) per job event and per tickless input turn
    /// (#870 review). Tests that pin the tables' alignment turn it on.
    var auditOn = false

    /// The job's handle and abandonment, if it is registered.
    func jobTask(_ sequence: Int64) -> KeeperActionJobTask? { jobTasks[sequence] }

    /// Registers a job's references, with no task yet (its start installs it, `setJobTask`).
    mutating func insertJobTask(_ sequence: Int64, abandonment: ResolverAbandonment) {
        jobTasks[sequence] = KeeperActionJobTask(task: nil, abandonment: abandonment)
    }

    /// Installs the started task of a registered job.
    mutating func setJobTask(_ sequence: Int64, _ task: Task<Void, Never>) {
        jobTasks[sequence]?.task = task
    }

    /// Removes a job's references and returns its removal waiters, whose resume the caller
    /// stages.
    mutating func removeJobTask(_ sequence: Int64) -> [CheckedContinuation<Void, Never>] {
        jobTasks.removeValue(forKey: sequence)
        return removalWaiters.removeValue(forKey: sequence) ?? []
    }
}
