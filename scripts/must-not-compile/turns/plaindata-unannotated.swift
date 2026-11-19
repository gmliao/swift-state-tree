// expect-error: needs a type annotation for @PlainData to check it
import SwiftStateTurns

// A stored property the macro can't see the type of.
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var count = 0
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
