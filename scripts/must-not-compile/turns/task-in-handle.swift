// expect-error: escaping closure captures mutating 'self' parameter
import SwiftStateTurns

// A task started from a step that reaches the machine.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var n: Int = 0
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {
        Task { self.n += 1 }
    }
}
