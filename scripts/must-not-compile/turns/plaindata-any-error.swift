// expect-error: to closure result type 'any PlainData'
import SwiftStateTurns

// A machine field that is an existential: its value can be a class.
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var lastError: (any Error)?
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
