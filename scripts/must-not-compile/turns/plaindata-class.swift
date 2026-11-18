// expect-error: 'Collaborator' conform to 'PlainData'
import SwiftStateTurns

// A machine field that is a class (Sendable, so the protocol alone lets it through).
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var collaborator: Collaborator
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
