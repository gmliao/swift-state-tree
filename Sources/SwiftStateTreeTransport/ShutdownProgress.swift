// Sources/SwiftStateTreeTransport/ShutdownProgress.swift
//
// How far a bounded shutdown step got (#351), read by the host when the step's deadline passes.

import Foundation
import SwiftStateTree

/// The sessions step of a server shutdown: sessions closed, and leaves that ran through their
/// land's membership queue. Written by the step's tasks, read by the host at any time (a step
/// abandoned at its deadline keeps writing; the host reads what it reached by then).
package final class ShutdownLeaveProgress: @unchecked Sendable {
    package struct Snapshot: Sendable, Equatable {
        /// Joined sessions whose leave was started.
        package var leaves = 0
        /// Of `leaves`: those whose leave ran to its result (applied or rejected).
        package var leavesFinished = 0
        /// Sessions to close, joined or not.
        package var sessions = 0
        package var sessionsClosed = 0

        /// Leaves not finished: cut by the land's destruction when the step's deadline passed.
        package var leavesCut: Int { leaves - leavesFinished }

        package init() {}
    }

    private let lock = NSLock()
    private var value = Snapshot()

    package init() {}

    package func expect(leaves: Int, sessions: Int) {
        lock.lock(); defer { lock.unlock() }
        value.leaves += leaves
        value.sessions += sessions
    }

    package func leaveFinished() {
        lock.lock(); defer { lock.unlock() }
        value.leavesFinished += 1
    }

    package func sessionClosed() {
        lock.lock(); defer { lock.unlock() }
        value.sessionsClosed += 1
    }

    package var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// The lands step of a server shutdown: lands whose destruction was started, and those that
/// finished it (destroy handlers, the save on destroy, `onLandDestroyed`).
package final class ShutdownLandProgress: @unchecked Sendable {
    /// One land instance: a detached instance can share its ID with a stored one.
    package struct Key: Hashable, Sendable {
        package let landID: LandID
        package let epoch: Epoch

        package init(landID: LandID, epoch: Epoch) {
            self.landID = landID
            self.epoch = epoch
        }
    }

    private let lock = NSLock()
    private var started: Set<Key> = []
    private var finished: Set<Key> = []

    package init() {}

    package func started(_ landID: LandID, epoch: Epoch) {
        lock.lock(); defer { lock.unlock() }
        started.insert(Key(landID: landID, epoch: epoch))
    }

    package func finished(_ landID: LandID, epoch: Epoch) {
        lock.lock()
        finished.insert(Key(landID: landID, epoch: epoch))
        let count = finished.count
        var ready: [CheckedContinuation<Void, Never>] = []
        finishedWaiters = finishedWaiters.filter { _, waiter in
            guard waiter.count <= count else { return true }
            ready.append(waiter.continuation)
            return false
        }
        lock.unlock()
        for continuation in ready { continuation.resume() }
    }

    private var finishedWaiters: [UInt64: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextWaiterID: UInt64 = 0

    /// Returns once `count` lands have finished, or when the calling task is cancelled (tests).
    package func waitForFinished(_ count: Int) async {
        let id = nextID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished.count >= count || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                finishedWaiters[id] = (count, continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = finishedWaiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.continuation.resume()
        }
    }

    private func nextID() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextWaiterID += 1
        return nextWaiterID
    }

    /// Lands finished, and those started and not finished, read under one lock.
    package var summary: (finished: Int, unfinished: [LandID]) {
        lock.lock(); defer { lock.unlock() }
        return (finished.count, started.subtracting(finished).map(\.landID).sorted { $0.stringValue < $1.stringValue })
    }

    /// The lands started and not finished, one entry per instance (an ID appears once for
    /// each of its unfinished instances), sorted by ID.
    package var unfinished: [LandID] {
        lock.lock(); defer { lock.unlock() }
        return started.subtracting(finished).map(\.landID).sorted { $0.stringValue < $1.stringValue }
    }

    /// The instances started and not finished, by epoch: a detached instance and a stored one
    /// with the same ID are told apart (#390).
    package var unfinishedInstances: Set<Key> {
        lock.lock(); defer { lock.unlock() }
        return started.subtracting(finished)
    }

    /// Instances started and not finished.
    package var unfinishedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return started.subtracting(finished).count
    }

    package var finishedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return finished.count
    }

    package var startedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return started.count
    }
}
