// Sources/SwiftStateTree/Runtime/StepScope.swift
//
// One handler call's scope (#700 K2-E): the call's random service and the gate its outputs
// pass. The keeper opens a scope for each handler call, binds it to the call's `LandContext`,
// and closes it when the handler returns. An output (an emitted event, a sync request) made
// through the context while the scope is open goes where it goes today; one made after the
// close, from a context kept past its call, is dropped and counted. A destroy handler's scope
// drops every output (#893): the land is gone, and nothing would take it.

import Foundation

/// A count of dropped outputs, per land: the ones whose context outlived its handler call
/// (`LandKeeper.lateStepOutputs`), or a destroy handler's (`destroyHandlerOutputsDropped`).
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
/// comes after finds it closed. An open output goes where it goes today, numbered at emit
/// time, which the body around the handler reads (the tick body's watermarks, K2 plan §4.4).
///
/// The lock orders an output against its own scope's close only, so two open scopes' outputs
/// can run at once; the keeper's output collector has no lock of its own. What keeps them
/// apart is that only one scope that passes outputs is open at a time: a scope that passes
/// outputs belongs to a synchronous handler call, which the keeper runs inside one segment of
/// its actor, and a context kept past the call finds its scope closed. The one async handler,
/// AfterFinalize, could hold its scope open across awaits while other calls run, so a destroy
/// handler's scope passes nothing (`dropsOutputs`): its outputs, made after the drain began,
/// would never be taken (#893). A later async handler needs the same drop, or the collector
/// needs its own lock.
///
/// The boundary is the keeper's close: the handler's return.
package final class StepScope: @unchecked Sendable {
    /// The service the call draws from (`LandContext.random`).
    let random: DeterministicRngService

    private let lock = NSLock()
    private var isOpen = true
    private let late: LateStepOutputCounter
    private let assertsOnLateOutput: Bool
    /// A destroy handler's count: set, an output made while the scope is open is dropped and
    /// counted there, with no assert. It is legal land code that has nowhere to go. One made
    /// after the close is a late output as in any scope.
    private let dropsOutputs: LateStepOutputCounter?

    /// - Parameters:
    ///   - assertsOnLateOutput: whether a late output stops a debug build; tests that pin the
    ///     drop turn it off.
    ///   - dropsOutputs: a destroy handler's count; see the property.
    init(
        random: DeterministicRngService,
        late: LateStepOutputCounter,
        assertsOnLateOutput: Bool,
        dropsOutputs: LateStepOutputCounter? = nil
    ) {
        self.random = random
        self.late = late
        self.assertsOnLateOutput = assertsOnLateOutput
        self.dropsOutputs = dropsOutputs
    }

    /// Runs `output` if the scope is open and passes outputs; otherwise drops it and counts the
    /// drop.
    func pass(_ output: () -> Void) {
        let passed = lock.withLock { () -> Bool in
            guard isOpen else { return false }
            if let dropsOutputs {
                dropsOutputs.increment()
            } else {
                output()
            }
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
