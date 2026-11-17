import Foundation
import SwiftStateTree

/// A set-once, lock-protected gate an adapter closes when its land fails (#535): readable from
/// any isolation without an await, like the keeper's drain flag. The first failure stays.
package final class LandOutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closedBy: LandFailure?

    package init() {}

    /// Whether the land's output is closed.
    package var isClosed: Bool { lock.withLock { closedBy != nil } }

    /// The failure that closed it, if any.
    package var failure: LandFailure? { lock.withLock { closedBy } }

    /// Closes the gate; a later call keeps the first failure.
    package func close(_ failure: LandFailure) {
        lock.withLock { if closedBy == nil { closedBy = failure } }
    }
}
