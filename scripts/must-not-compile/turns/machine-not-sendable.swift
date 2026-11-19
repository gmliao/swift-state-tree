// expect-error: has non-Sendable type 'Coordinator'
import SwiftStateTurns

final class Coordinator {
    var sessions: [String: String] = [:]
}

// A machine is Sendable, so it can't store a class with mutable state.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var coordinator: Coordinator = Coordinator()
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
