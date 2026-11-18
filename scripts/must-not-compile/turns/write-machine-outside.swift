// expect-error: 'machine' is inaccessible due to 'internal' protection level
import SwiftStateTurns

struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var n: Int = 0
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}

// The adopter writes the machine outside a step.
actor A: TurnActor {
    let core = snippetCore(Mach())
    @concurrent nonisolated func perform(_ effect: Int) async -> Int? { nil }
    func flush(_ outputs: consuming [Int]) {}
    func writeOutside() {
        core.machine.n = 1
    }
}
