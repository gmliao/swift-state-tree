// expect-error: afterBatch
import SwiftStateTurns

// A report's handler arms an `.afterBatch` follow-up: its ReportTurn has no way to (plan §3.9).
enum Slot: Hashable, Sendable { case next }

struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    typealias FollowUpSlot = Slot
    typealias LaneReport = Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
    mutating func handleReport(_ report: Int, _ turn: inout ReportTurn<Mach>) {
        turn.followUp(report, .next, of: 1, .afterBatch)
    }
}
