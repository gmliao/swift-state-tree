// expect-error: cannot assign to property: 'core' is a 'let' constant
import SwiftStateTurns

@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}

// The adopter replaces its core.
actor A: TurnActor {
    let core = snippetCore(Mach())
    @concurrent nonisolated func perform(_ effect: Int) async -> Int? { nil }
    func flush(_ outputs: consuming [Int]) {}
    func replace() {
        core = snippetCore(Mach())
    }
}
