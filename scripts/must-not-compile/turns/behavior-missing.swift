// expect-error: and '()' be equivalent
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
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
}

// A machine with a behavior can't be made without one.
let core = TurnCore(Mach(), queueLimit: 8, maxReleasesPerBatch: 8, clock: SnippetClock())
