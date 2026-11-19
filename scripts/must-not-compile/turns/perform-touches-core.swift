// expect-error: actor-isolated property 'core' cannot be accessed from outside of the actor
import SwiftStateTurns

@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var n: Int = 0
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) { n += 1 }
}

// An effect reads the core.
actor A: TurnActor {
    let core = snippetCore(Mach())
    @concurrent nonisolated func perform(_ effect: Int) async -> Int? {
        core.read { $0.n }
    }
    func flush(_ outputs: consuming [Int]) {}
}
