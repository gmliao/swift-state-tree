// expect-error: does not conform to expected type 'Copyable'
import SwiftStateTurns

nonisolated(unsafe) var stolen: [Any] = []

// A step stores its Turn somewhere that outlives it.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {
        stolen.append(turn)
    }
}
