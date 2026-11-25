// Sources/SwiftStateTree/Runtime/KeeperTurnSide.swift
//
// The turn side and the turn's staged outputs (#700 K1b-5a). A turn body changes keeper state
// inline and stages its effects: a recorder submission, a continuation to resume, a task to
// start. The keeper flushes them in the order they were staged, before the body's first
// suspension, and before every call out of the keeper during the body (`LandKeeper.callOut`),
// so code outside the keeper sees the effects in today's order.

import Foundation

/// One effect a turn staged.
package enum TurnEffect {
    /// A recorder submission: `apply` runs after every earlier submission. `label` names the
    /// entry for the submission trace in tests.
    case submission(label: String, apply: @Sendable () async -> Void)
    /// Anything else that must wait for the flush: a continuation's resume, a task's start.
    case action(() -> Void)
}

/// The effects a turn staged, in staging order. Owned by the keeper's `withTurn` for one body
/// call, passed to the body `inout`, and flushed exactly once.
package struct TurnOutputs {
    private var effects: [TurnEffect] = []
    /// The task of the last submission any flush of this turn made, across every flush (one
    /// before each call out, and the final one): what `withTurnSubmitting` returns.
    package fileprivate(set) var lastSubmission: Task<Void, Never>?

    package init() {}

    /// Nothing staged.
    package var isEmpty: Bool { effects.isEmpty }

    /// Stages a recorder submission. Its bookkeeping (the submission count, a stream index)
    /// is the caller's, done inline before this call.
    package mutating func stageSubmission(_ label: String, _ apply: @escaping @Sendable () async -> Void) {
        effects.append(.submission(label: label, apply: apply))
    }

    /// Stages an effect that must not run before the flush. The action must not enter the keeper
    /// synchronously: it runs after the depth has dropped, so the guarded entries wouldn't
    /// refuse it.
    package mutating func stage(_ action: @escaping () -> Void) {
        effects.append(.action(action))
    }

    /// Removes and returns every staged effect, in staging order.
    fileprivate mutating func takeAll() -> [TurnEffect] {
        defer { effects.removeAll(keepingCapacity: false) }
        return effects
    }
}

/// What a turn body reaches outside its state: the keeper's tables it changes inline and the
/// references its flush needs. A stored property of the keeper, borrowed `inout` by one body
/// call at a time (`LandKeeper.withTurn`), so a callback that re-enters the keeper during the
/// body can't reach it.
///
/// K1b-5a's first step holds only the recorder submission tracker. The continuation tables,
/// the services, the job handles and `drainTask` move in with the bodies that change them.
package struct KeeperTurnSide {
    private let submissions: ReevaluationSubmissionTracker

    package init(submissions: ReevaluationSubmissionTracker) {
        self.submissions = submissions
    }

    /// Applies the staged effects in staging order and empties `outputs`, keeping the task of
    /// the last submission it made in `outputs.lastSubmission`. Not `mutating`: the keeper calls
    /// it on a copy of the side, so no access to its stored side is held while the actions run.
    package func flush(_ outputs: inout TurnOutputs) {
        for effect in outputs.takeAll() {
            switch effect {
            case let .submission(label, apply):
                outputs.lastSubmission = submissions.submit(label: label, apply)
            case let .action(action):
                action()
            }
        }
    }
}
