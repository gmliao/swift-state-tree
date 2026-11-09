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
    private struct Key: Hashable {
        let landID: LandID
        let epoch: Epoch
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
        lock.lock(); defer { lock.unlock() }
        finished.insert(Key(landID: landID, epoch: epoch))
    }

    /// The IDs of the lands started and not finished.
    package var unfinished: Set<LandID> {
        lock.lock(); defer { lock.unlock() }
        return Set(started.subtracting(finished).map(\.landID))
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
