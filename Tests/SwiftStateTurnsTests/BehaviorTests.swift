// A machine's behavior (`TurnMachine.Behavior`, #768): fixed at `TurnCore.init`, read by every
// step kind. Each step emits a line made by the behavior's function, and the flush opens it.

import Foundation
import SwiftStateTurns
import Testing

/// What the machine does: a function and a fixed setting, given once to the core.
struct TagBehavior: Sendable {
    let prefix: String
    let tag: @Sendable (String, String) -> String
}

@PlainData
struct BehaviorMachine: TurnMachine {
    enum Input: Sendable {
        case go
        case followed
        case stop
        case done
    }
    enum Effect: Sendable { case work }
    enum Key: Hashable, Sendable { case room }
    enum Query: Sendable { case ask }
    enum Mail: Sendable { case ping }
    enum FollowUpSlot: Hashable, Sendable { case next }
    typealias Output = String
    typealias Reply = Int
    typealias Answer = String
    typealias Behavior = TagBehavior

    var pending: RequestID?

    mutating func handle(_ input: Input, _ turn: inout Turn<BehaviorMachine>) {
        switch input {
        case .go:
            turn.start(.room)
            turn.emit(turn.behavior.tag(turn.behavior.prefix, "input"), for: .room)
            pending = turn.request(.work, for: .room)
            turn.followUp(.followed, .next, of: .room, .afterBatch)
        case .followed:
            turn.emit(turn.behavior.tag(turn.behavior.prefix, "follow-up"), for: .room)
        case .stop:
            if let pending { turn.cancel(pending) }
        case .done:
            turn.emit(turn.behavior.tag(turn.behavior.prefix, "completion"), for: .room)
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<BehaviorMachine>) {
        turn.emit(turn.behavior.tag(turn.behavior.prefix, "abandoned"), for: .room)
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<BehaviorMachine>) {
        turn.emit(turn.behavior.tag(turn.behavior.prefix, "late"), for: .room)
    }

    mutating func answer(_ query: Query, _ turn: inout Turn<BehaviorMachine>) -> String {
        turn.behavior.tag(turn.behavior.prefix, "answer")
    }

    mutating func handleMail(_ mail: Mail, _ turn: inout MailTurn<BehaviorMachine>) {
        turn.emit(turn.behavior.tag(turn.behavior.prefix, "mail"), for: .room)
    }
}

actor BehaviorActor: TurnActor {
    let core: TurnCore<BehaviorMachine>
    nonisolated let mailbox: TurnMailbox<BehaviorMachine.Mail>?
    nonisolated let fixture: Fixture

    init(fixture: Fixture, behavior: TagBehavior) {
        self.fixture = fixture
        let core = TurnCore(machine: BehaviorMachine(), behavior: behavior, queueLimit: 16, maxReleasesPerBatch: 16,
                            clock: TestClock(fixture: fixture))
        self.core = core
        self.mailbox = core.mailbox
    }

    @concurrent nonisolated func perform(_ effect: BehaviorMachine.Effect) async -> BehaviorMachine.Input? {
        fixture.open("work started")
        await fixture.wait("work go")
        return .done
    }

    func flush(_ outputs: consuming [String]) {
        for line in outputs { fixture.open(line) }
    }

    func go() { send(.go) }
    func stop() { send(.stop) }
    func ask() -> String { query(.ask) }
}

@Suite("Behavior")
struct BehaviorTests {
    @Test("every step kind reads the behavior given at init")
    func everyStepKindReadsTheBehavior() async {
        let fixture = Fixture()
        // The function and the setting both come from the behavior, so a line names both.
        let actor = BehaviorActor(fixture: fixture, behavior: TagBehavior(prefix: "B") { "\($0):\($1)" })
        await actor.go()
        await fixture.reach("B:input")
        // The follow-up steps through `handle` as its own job.
        await fixture.reach("B:follow-up")
        await fixture.reach("work started")
        // Cancelling the request steps its abandonment.
        await actor.stop()
        await fixture.reach("B:abandoned")
        // The worker returns after the request closed: a late result.
        fixture.open("work go")
        await fixture.reach("B:late")
        // A mail steps through `handleMail` with a `MailTurn`.
        #expect(actor.post(.ping))
        await fixture.reach("B:mail")
        // A query's answer reads it too.
        #expect(await actor.ask() == "B:answer")
        #expect(!fixture.isOpen("B:completion"))
    }
}
