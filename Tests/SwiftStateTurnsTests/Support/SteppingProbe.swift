import SwiftStateTurns

/// `SteppingMachine`'s behavior (IsSteppingTests.swift): it reads the core's predicate when a
/// step asks for a line. The core is set once, right after it is made, and read on the actor's
/// executor only. In its own file: a machine's file holds no `@unchecked Sendable`
/// (scripts/lint-turns.sh, rule machine-file).
final class SteppingProbe: @unchecked Sendable {
    weak var core: TurnCore<SteppingMachine>?

    func line(_ kind: String) -> String { "\(kind):\(core?.isStepping == true)" }
}
