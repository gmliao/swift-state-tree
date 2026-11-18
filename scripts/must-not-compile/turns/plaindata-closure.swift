// expect-error: a function type isn't plain data
import SwiftStateTurns

// A machine field that can call out: a closure.
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var onEvent: @Sendable () -> Void
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
