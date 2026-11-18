// expect-error: a function type isn't plain data
import SwiftStateTurns

// A closure inside an `#if` block is checked like one outside it.
@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var n: Int
    #if DEBUG
    var hook: @Sendable () -> Void = {}
    #else
    var hook: @Sendable () -> Void = {}
    #endif
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}
