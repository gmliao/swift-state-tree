// expect-error: this field's type isn't PlainData: add @PlainData to your struct or enum
import SwiftStateTurns

// A machine field that is an actor.
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var peer: Peer
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
