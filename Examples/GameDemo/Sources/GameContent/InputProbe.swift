// Examples/GameDemo/Sources/GameContent/InputProbe.swift
//
// A benchmark's count of the inputs a land's handlers applied (#521, PR 0). EncodingBenchmark
// registers one per room in the keeper's `LandServices`; GameServer and the load tests don't, so
// the handlers' lookup finds nothing there.

import Foundation
import SwiftStateTree

/// Counts the inputs whose handler ran: Hero Defense's `MoveToEvent` and the visibility test's
/// `SetMotionAction`. Not synced and not in the schema.
///
/// The keeper calls `noteApplied()` from its handlers; the benchmark reads `applied` after a run.
/// A lock, not an atomic, because the package targets macOS 14.
public final class InputProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public init() {}

    /// One input's handler ran.
    public func noteApplied() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// The inputs applied so far.
    public var applied: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
