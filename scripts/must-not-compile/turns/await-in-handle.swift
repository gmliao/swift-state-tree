// expect-error: 'async' call in a function that does not support concurrency
import SwiftStateTurns

// An await inside a step.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var n: Int = 0
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {
        await Task.yield()
        n += 1
    }
}
