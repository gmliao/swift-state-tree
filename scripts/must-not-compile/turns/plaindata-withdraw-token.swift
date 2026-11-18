// expect-error: 'WithdrawToken' conform to 'PlainData'
import SwiftStateTurns

// A machine that stores an withdraw token (the core reads tokens; a machine never keeps one).
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var token: WithdrawToken?
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
