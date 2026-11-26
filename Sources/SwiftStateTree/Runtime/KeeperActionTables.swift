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
///
/// The task handle's home (#700 K1b-5 rev 2.5 D16): the box is made when the job registers, its
/// start installs the task, and a cancel that comes first is kept, so the start that follows
/// cancels the task it installs. The install and its check, and the cancel, each decide under
/// one lock, and `cancel()` on the task runs after the lock is released: a task's cancellation
/// handlers can run synchronously inside `cancel()`, and one that reads this box must not find
/// the lock held. The shape is a `CancellationTokenSource` with its task.
final class KeeperActionJobTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    /// Its resolvers' abandonment (the caller stopped waiting while they still run). The job
    /// keeps its place in the caps until they end.
    let abandonment: ResolverAbandonment
    /// The caller was cancelled while waiting: the completion fails with `CancellationError`
    /// instead of delivering, unless it ran first.
    let callerCancelled = ActionJobCallerCancellation()

    init(abandonment: ResolverAbandonment) {
        self.abandonment = abandonment
    }

    /// The installed task, if any.
    var installedTask: Task<Void, Never>? {
        lock.withLock { task }
    }

    /// Installs the job's started task; cancels it at once when a cancel came first.
    func install(_ started: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            task = started
            return cancelled
        }
        if cancelNow { started.cancel() }
    }

    /// Cancels the installed task, or, before the install, marks the box so the install cancels.
    func cancel() {
        let installed = lock.withLock { () -> Task<Void, Never>? in
            if let task { return task }
            cancelled = true
            return nil
        }
        installed?.cancel()
    }
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

    /// Registers a job's box, with no task yet; returns it for the start to install into.
    mutating func insertJobTask(_ sequence: Int64, abandonment: ResolverAbandonment) -> KeeperActionJobTask {
        let box = KeeperActionJobTask(abandonment: abandonment)
        jobTasks[sequence] = box
        return box
    }

    /// Removes a job's references and returns its removal waiters, whose resume the caller
    /// stages.
    mutating func removeJobTask(_ sequence: Int64) -> [CheckedContinuation<Void, Never>] {
        jobTasks.removeValue(forKey: sequence)
        return removalWaiters.removeValue(forKey: sequence) ?? []
    }
}
