// Sources/SwiftStateTree/Runtime/LandFailureMailbox.swift
//
// A failure found outside a keeper turn, noted for the keeper's next step boundary (#704).

import Foundation

/// A set-once box for a land failure that a transport found outside a keeper turn: an answer
/// or an event that didn't encode, or a joiner's first sync that failed (#704).
///
/// The transport notes the failure in the same segment as it closes the land's output gate.
/// Any isolation can read the box without an await, so the keeper reads it at each step
/// boundary: right after an apply segment, and at the start of a sync-only turn or an output
/// step. The transport's awaited submit then only wakes the keeper when no turn is due.
package final class LandFailureMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var noted: LandFailure?

    package init() {}

    /// The first failure noted, if any.
    package var failure: LandFailure? { lock.withLock { noted } }

    /// Notes `failure`; a later call keeps the first one.
    package func note(_ failure: LandFailure) {
        lock.withLock { if noted == nil { noted = failure } }
    }
}
