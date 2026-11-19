// expect-error: initializer is inaccessible due to 'internal' protection level
import SwiftStateTurns

// A step makes a Turn of its own, to swap the real one out.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {
        var other = Turn<Mach>(core: snippetCore(Mach()), input: nil)
        swap(&other, &turn)
    }
}
