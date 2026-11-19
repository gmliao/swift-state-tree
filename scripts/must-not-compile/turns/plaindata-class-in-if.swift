// expect-error: requires that 'Collaborator' conform to 'PlainData'
import SwiftStateTurns

// A class stored inside an `#if` block is checked under the same condition.
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    #if DEBUG
    var collaborator: Collaborator
    #else
    var collaborator: Collaborator
    #endif
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
