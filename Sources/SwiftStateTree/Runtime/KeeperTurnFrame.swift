// Sources/SwiftStateTree/Runtime/KeeperTurnFrame.swift
//
// One turn body's frame (#865; #700 K2-1): the re-entry sentinel's depth count around the body,
// then the flush of what the body staged, then the backstop for a refused re-entry the body
// didn't apply. The keeper's `withTurn` and a core step (`KeeperModel.handle`) run the same
// frame, so the two paths can't drift (K2's condition 1).
//
// The flush runs after the body's borrow of the model and the side has ended: a staged action
// may reach the keeper, and it must find neither borrowed. The frame is isolated to its caller,
// so the flush runs on the owner's executor.

import Foundation

enum KeeperTurnFrame {
    /// Runs `body` as one turn body: depth 1 while it runs (a synchronous re-entry is refused),
    /// then `flush` with the outputs it staged, then `lateReentry` with the refusal count from
    /// before the body. Both run on every exit, a throw included.
    ///
    /// Isolated to its caller (`isolation`, the caller's own by default): the flush runs staged
    /// starts, and on the owner's executor they run in both callers, the keeper's `withTurn`
    /// and a core step, never on a generic executor (#914's lesson, SE-0420).
    static func run<R>(
        isolation: isolated (any Actor)? = #isolation,
        _ sentinel: KeeperReentrySentinel,
        flush: (inout TurnOutputs) -> Void,
        lateReentry: (_ violationsBefore: Int) -> Void,
        _ body: (inout TurnOutputs) throws -> R
    ) rethrows -> R {
        assert(sentinel.bodyDepth == 0, "turn bodies don't nest")
        var outputs = TurnOutputs()
        let violationsBefore = sentinel.reentryViolations
        defer {
            flush(&outputs)
            lateReentry(violationsBefore)
        }
        sentinel.bodyDepth += 1
        defer { sentinel.bodyDepth -= 1 }
        return try body(&outputs)
    }
}

extension KeeperModel {
    /// The frame's backstop: a re-entry refused during a body that didn't apply it (a call not
    /// made through `callOut`). Applies the failure and returns it with the outputs to flush, or
    /// nil when there is nothing to apply. The caller flushes after the borrow ends, then calls
    /// `noteLateReentry`.
    mutating func applyLateReentry(
        _ behavior: KeeperBehavior<State>,
        _ side: inout KeeperTurnSide,
        since violationsBefore: Int
    ) -> (outputs: TurnOutputs, applied: LandFailure)? {
        guard behavior.reentrySentinel.reentryViolations != violationsBefore, side.failure == nil, !side.isDraining else { return nil }
        var outputs = TurnOutputs()
        let applied = applyReentryFailure(behavior, &side, &outputs)
        return (outputs, applied)
    }

    /// After the late re-entry's flush: counted, and logged as late (the body's result was
    /// already fixed).
    static func noteLateReentry(_ behavior: KeeperBehavior<State>, _ applied: LandFailure) {
        behavior.reentrySentinel.lateReentriesApplied += 1
        behavior.logger.error("A refused re-entry was applied after its turn body returned", metadata: [
            "landID": .string(behavior.config.actualLandID ?? "-"),
            "failure": .string(applied.description),
        ])
    }
}
