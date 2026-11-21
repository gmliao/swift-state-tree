// The follow-up benches (#702): arming and joining, and one `.afterBatch` follow-up armed and
// run. On a machine of their own, so `BenchMachine` keeps the default of no follow-ups and the
// existing benches measure what a machine without follow-ups pays.

import SwiftStateTurns

@PlainData
struct FollowUpBenchMachine: TurnMachine {
    enum Input: Sendable {
        case setup
        case arm
        case ran
    }

    enum FollowUpSlot: Hashable, Sendable {
        case only
    }

    typealias Effect = Never
    typealias Output = Never
    typealias Key = Int
    typealias Reply = Int

    var ran: Int

    mutating func handle(_ input: Input, _ turn: inout Turn<FollowUpBenchMachine>) {
        switch input {
        case .setup:
            turn.start(0)
        case .arm:
            turn.followUp(.ran, .only, of: 0, .afterBatch)
        case .ran:
            ran &+= 1
        }
    }
}
