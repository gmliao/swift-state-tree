// expect-error: 'Collaborator' conform to 'PlainData'
import SwiftStateTurns

// A class reached through a collection.
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var byName: [String: Collaborator]
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
