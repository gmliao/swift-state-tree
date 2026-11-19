// expect-error: missing reinitialization of inout parameter 'turn' after consume
import SwiftStateTurns

func sinkTurn(_ turn: consuming Turn<Mach>) {}

// A step moves its Turn away and doesn't put one back.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {
        sinkTurn(turn)
    }
}
