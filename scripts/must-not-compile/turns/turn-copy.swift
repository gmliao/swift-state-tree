// expect-error: used after consume
import SwiftStateTurns

// A step copies its Turn, then uses the original.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {
        let copy = turn
        turn.close()
        _ = copy
    }
}
