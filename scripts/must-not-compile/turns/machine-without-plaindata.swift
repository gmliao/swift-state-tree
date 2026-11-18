// expect-error: requires that 'Mach' conform to 'PlainData'
import SwiftStateTurns

// A machine without @PlainData that stores a class: the core can't run it.
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var collaborator: Collaborator
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}

func run() {
    _ = TurnCore(Mach(collaborator: Collaborator()), parkedLimit: 8, segmentBudget: 8, clock: SnippetClock())
}
