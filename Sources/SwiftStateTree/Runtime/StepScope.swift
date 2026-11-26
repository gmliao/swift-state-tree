// Sources/SwiftStateTree/Runtime/StepScope.swift
//
// One handler call's scope (#700 K2-E): the call's random service and the gate its outputs
// pass. The keeper opens a scope for each handler call, binds it to the call's `LandContext`,
// and closes it when the handler returns. An output (an emitted event, a sync request) made
// through the context while the scope is open goes where it goes today; one made after the
// close, from a context kept past its call, is dropped and counted.

import Foundation

/// The outputs dropped because their context outlived its handler call, counted per land.
package final class LateStepOutputCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var dropped = 0

    package init() {}

    /// The outputs dropped so far.
    package var count: Int {
        lock.withLock { dropped }
    }

    fileprivate func increment() {
        lock.withLock { dropped += 1 }
    }
}

/// One handler call's random service and output gate.
///
/// The gate's lock is held while an output runs, so an output and the close never overlap:
/// an output that finds the scope open completes before the close returns, and one that
/// comes after finds it closed. While the scope is open the keeper is inside the handler call
/// (synchronous, never nested), so an output under the lock is the only access to the keeper's
/// output collector; this keeps an event's number at emit time, which the body around the
/// handler reads (the tick body's watermarks, K2 plan §4.4).
package final class StepScope: @unchecked Sendable {
    /// The service the call draws from (`LandContext.random`).
    let random: DeterministicRngService

    private let lock = NSLock()
    private var isOpen = true
    private let late: LateStepOutputCounter
    private let assertsOnLateOutput: Bool

    /// - Parameter assertsOnLateOutput: whether a late output stops a debug build; tests that
    ///   pin the drop turn it off.
    init(random: DeterministicRngService, late: LateStepOutputCounter, assertsOnLateOutput: Bool) {
        self.random = random
        self.late = late
        self.assertsOnLateOutput = assertsOnLateOutput
    }

    /// Runs `output` if the scope is open; otherwise drops it and counts the drop.
    func pass(_ output: () -> Void) {
        let passed = lock.withLock { () -> Bool in
            guard isOpen else { return false }
            output()
            return true
        }
        guard !passed else { return }
        late.increment()
        assert(!assertsOnLateOutput, "A LandContext output was made after its handler call returned; it was dropped")
    }

    /// Closes the scope: every later output is dropped.
    func close() {
        lock.withLock { isOpen = false }
    }
}
