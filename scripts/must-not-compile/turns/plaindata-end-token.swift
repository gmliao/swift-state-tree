// expect-error: 'EndToken' conform to 'PlainData'
import SwiftStateTurns

// A machine that stores an end token (the core reads tokens; a machine never keeps one).
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var token: EndToken?
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
