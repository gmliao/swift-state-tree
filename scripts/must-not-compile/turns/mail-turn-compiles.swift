// expect: compiles
import SwiftStateTurns

// The control for mail-arms-after-batch: a mail's handler arms an `afterWork` follow-up,
// runs an effect and emits, through its MailTurn.
enum Slot: Hashable, Sendable { case next }

@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    typealias FollowUpSlot = Slot
    typealias Mail = Int
    var seen: Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
    mutating func handleMail(_ mail: Int, _ turn: inout MailTurn<Mach>) {
        seen = mail
        turn.followUp(mail, .next, of: 1, afterWork: mail, deadline: .seconds(5))
        turn.run(mail)
        turn.emit(mail, for: 1)
    }
}

actor MachActor: TurnActor {
    let core: TurnCore<Mach>
    nonisolated let mailbox: TurnMailbox<Int>?
    init() {
        let core = snippetCore(Mach(seen: 0))
        self.core = core
        self.mailbox = core.mailbox
    }
    @concurrent nonisolated func perform(_ effect: Int) async -> Int? { effect }
    func flush(_ outputs: consuming [Int]) {}
}
