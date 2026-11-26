import SwiftStateTurns

/// `SteppingMachine`'s behavior (IsSteppingTests.swift): when a step asks for a line, it records
/// what the core's predicate says, under the step's kind, and returns the kind alone, so a check
/// reads the value after the event instead of waiting for an event named by it. The core is set
/// once, right after it is made; both are used on the actor's executor only. In its own file: a machine's file holds no `@unchecked Sendable`
/// (scripts/lint-turns.sh, rule machine-file).
final class SteppingProbe: @unchecked Sendable {
    weak var core: TurnCore<SteppingMachine>?

    /// The predicate's reading for each step kind, the last one per kind.
    private(set) var stepping: [String: Bool] = [:]

    func line(_ kind: String) -> String {
        stepping[kind] = core?.isStepping == true
        return kind
    }
}
