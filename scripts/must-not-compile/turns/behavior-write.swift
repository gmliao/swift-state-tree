// expect-error: cannot assign to property: 'behavior' is a get-only property
import SwiftStateTurns

struct Limits: Sendable { var maxPlayers: Int }

@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    typealias Behavior = Limits
    var n: Int = 0
    // A step can read its behavior, never write it: a change goes to the model.
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {
        turn.behavior = Limits(maxPlayers: input)
    }
}
