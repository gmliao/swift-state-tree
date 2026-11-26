// `TurnCore.isStepping` (#700 K2): true inside every step kind, false between steps, inside a
// read and in `flush`. Each step emits its kind, and its behavior records what the core's
// predicate said as the step ran; each check reads that after the event, so a wrong value fails
// at once, naming it. The flush records what the predicate says there.

import Foundation
import SwiftStateTurns
import Testing

@PlainData
struct SteppingMachine: TurnMachine {
    enum Input: Sendable {
        case go
        case followed
        case stop
        case done
        case arm(seconds: Int64)
        case tick
    }
    enum Effect: Sendable { case work }
    enum Key: Hashable, Sendable { case room }
    enum Query: Sendable { case ask }
    enum Mail: Sendable { case ping }
    enum FollowUpSlot: Hashable, Sendable { case next }
    typealias Output = String
    typealias Reply = Int
    typealias Answer = String
    typealias Behavior = SteppingProbe

    var pending: RequestID?

    mutating func handle(_ input: Input, _ turn: inout Turn<SteppingMachine>) {
        switch input {
        case .go:
            turn.start(.room)
            turn.emit(turn.behavior.line("input"), for: .room)
            pending = turn.request(.work, for: .room)
            turn.followUp(.followed, .next, of: .room, .afterBatch)
        case .followed:
            turn.emit(turn.behavior.line("follow-up"), for: .room)
        case .stop:
            if let pending { turn.cancel(pending) }
        case .done:
            turn.emit(turn.behavior.line("completion"), for: .room)
        case .arm(let seconds):
            if !turn.isLive(.room) { turn.start(.room) }
            turn.timer(at: .seconds(seconds), for: .room, .tick)
        case .tick:
            turn.emit(turn.behavior.line("timer"), for: .room)
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<SteppingMachine>) {
        turn.emit(turn.behavior.line("abandoned"), for: .room)
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<SteppingMachine>) {
        turn.emit(turn.behavior.line("late"), for: .room)
    }

    mutating func answer(_ query: Query, _ turn: inout Turn<SteppingMachine>) -> String {
        turn.behavior.line("answer")
    }

    mutating func handleMail(_ mail: Mail, _ turn: inout MailTurn<SteppingMachine>) {
        turn.emit(turn.behavior.line("mail"), for: .room)
    }
}

actor SteppingActor: TurnActor {
    let core: TurnCore<SteppingMachine>
    private let probe: SteppingProbe
    nonisolated let mailbox: TurnMailbox<SteppingMachine.Mail>?
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock
    /// What the predicate said at each flush.
    private(set) var steppingAtFlush: [Bool] = []

    init(fixture: Fixture) {
        self.fixture = fixture
        let clock = TestClock(fixture: fixture)
        self.clock = clock
        let probe = SteppingProbe()
        let core = TurnCore(machine: SteppingMachine(), behavior: probe, queueLimit: 16, maxReleasesPerBatch: 16,
                            clock: clock)
        probe.core = core
        self.probe = probe
        self.core = core
        self.mailbox = core.mailbox
    }

    @concurrent nonisolated func perform(_ effect: SteppingMachine.Effect) async -> SteppingMachine.Input? {
        fixture.open("work started")
        await fixture.wait("work go")
        return .done
    }

    func flush(_ outputs: consuming [String]) {
        steppingAtFlush.append(core.isStepping)
        for line in outputs { fixture.open(line) }
    }

    func go() { send(.go) }
    func stop() { send(.stop) }
    func arm(seconds: Int64) { send(.arm(seconds: seconds)) }
    func ask() -> String { query(.ask) }
    /// What the predicate said in the last step of `kind` (nil: no such step ran).
    func stepping(_ kind: String) -> Bool? { probe.stepping[kind] }
    /// The predicate between steps, and inside a read.
    func outsideSteps() -> (between: Bool, inRead: Bool) {
        (core.isStepping, core.read { _ in core.isStepping })
    }
}

@Suite("TurnCore.isStepping")
struct IsSteppingTests {
    @Test("true inside every step kind; false between steps, inside a read and in flush")
    func trueOnlyInsideSteps() async {
        let fixture = Fixture()
        let actor = SteppingActor(fixture: fixture)
        #expect(await actor.outsideSteps() == (between: false, inRead: false))

        // A sent step, then its follow-up as its own job.
        await actor.go()
        await fixture.reach("input")
        #expect(await actor.stepping("input") == true)
        await fixture.reach("follow-up")
        #expect(await actor.stepping("follow-up") == true)
        await fixture.reach("work started")
        // Cancelling the request steps its abandonment; the worker's return is a late result.
        await actor.stop()
        await fixture.reach("abandoned")
        #expect(await actor.stepping("abandoned") == true)
        fixture.open("work go")
        await fixture.reach("late")
        #expect(await actor.stepping("late") == true)
        // A mail steps through `handleMail`.
        #expect(actor.post(.ping))
        await fixture.reach("mail")
        #expect(await actor.stepping("mail") == true)
        // A query's answer is a step.
        #expect(await actor.ask() == "answer")
        #expect(await actor.stepping("answer") == true)
        // A timer's input steps when the core's timer wakes it.
        await actor.arm(seconds: 5)
        actor.clock.advance(to: 5)
        await fixture.reach("timer")
        #expect(await actor.stepping("timer") == true)

        #expect(await actor.outsideSteps() == (between: false, inRead: false))
        let atFlush = await actor.steppingAtFlush
        #expect(!atFlush.isEmpty)
        #expect(atFlush.allSatisfy { !$0 }, "flush runs after the step gives the machine back")
    }

    @Test("a completion's step reads true")
    func completionStepReadsTrue() async {
        let fixture = Fixture()
        let actor = SteppingActor(fixture: fixture)
        await actor.go()
        await fixture.reach("work started")
        fixture.open("work go")
        await fixture.reach("completion")
        #expect(await actor.stepping("completion") == true)
        #expect(await actor.outsideSteps() == (between: false, inRead: false))
    }
}
