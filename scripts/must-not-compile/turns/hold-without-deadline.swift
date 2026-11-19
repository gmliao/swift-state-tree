// expect-error: missing argument for parameter 'deadline' in call
import SwiftStateTurns

// A holding request without a deadline: a hold always carries one.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {
        turn.start(1)
        turn.request(input, for: 1, holding: .untilRequestCloses(1))
    }
}
