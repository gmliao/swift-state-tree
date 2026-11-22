// expect-error: afterBatch
import SwiftStateTurns

// A mail's handler arms an `.afterBatch` follow-up: its MailTurn has no way to (plan §3.9).
enum Slot: Hashable, Sendable { case next }

struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    typealias FollowUpSlot = Slot
    typealias Mail = Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
    mutating func handleMail(_ mail: Int, _ turn: inout MailTurn<Mach>) {
        turn.followUp(mail, .next, of: 1, .afterBatch)
    }
}
