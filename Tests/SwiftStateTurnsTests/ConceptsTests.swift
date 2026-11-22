// The examples of the documentation's "Core concepts" article (CoreConcepts.md) that the lobby
// of WorkedExampleTests.swift doesn't show: a room with an asked seat count, an untracked log
// line, a save under a worker-returns hold, chat scoped to a player, joins that carry their
// connection's withdraw token, and an idle timer. Compiled and run here; the rot check in
// WorkedExampleTests.swift covers its blocks.

import SwiftStateTree
import SwiftStateTurns
import Testing

/// A room: the lobby's ideas, plus the rest of the core's tools.
@PlainData
struct Room: TurnMachine {
    // docs:room-input
    enum Input: Sendable {
        /// From a connection; withdrawn if that connection closed before the join stepped.
        case join(player: Int, connection: WithdrawToken)
        case chat(player: Int, text: String)
        case saveStats(player: Int)
        case saved(player: Int)
        case idleKick(player: Int)
    }
    // docs:end

    enum Effect: Sendable {
        case writeStats(player: Int)
        case log(String)
    }

    enum Key: Hashable, Sendable {
        case player(Int)
        case database
    }

    enum Query: Sendable {
        case seatCount
    }

    typealias Output = String
    typealias Reply = Int
    typealias Answer = Int

    var seats: Set<Int>
    var saving: [RequestID: Int]

    // docs:room-admission
    func inputPolicy(for input: Input) -> InputPolicy<Key> {
        switch input {
        // Refused at once if the player's connection already closed.
        case .join(_, let connection): .normal(waitsFor: nil, belongsTo: nil, withdrawnBy: connection)
        // Waits while a save holds the database; withdrawn if the player leaves meanwhile.
        case .chat(let player, _): .normal(waitsFor: .database, belongsTo: .player(player))
        case .saveStats: .normal(waitsFor: .database, belongsTo: nil)
        default: .control
        }
    }
    // docs:end

    mutating func handle(_ input: Input, _ turn: inout Turn<Room>) {
        switch input {
        // docs:room-join
        case .join(let player, _):
            turn.start(.player(player))
            seats.insert(player)
            // Untracked work: no key owns it, and nothing waits for it.
            turn.run(.log("joined \(player)"))
            // Kicked after a minute without a word; each chat line re-arms it.
            turn.timer(at: turn.now + .seconds(60), for: .player(player), .idleKick(player: player))
            if let caller = turn.input { turn.reply(to: caller, .success(seats.count)) }
        // docs:end
        case .chat(let player, let text):
            turn.timer(at: turn.now + .seconds(60), for: .player(player), .idleKick(player: player))
            turn.emit("\(player): \(text)", for: .player(player))
        // docs:room-save
        case .saveStats(let player):
            // The write changes the database while it runs: the hold lasts until the worker
            // returns, even if the request is abandoned first.
            let hold = Hold.untilWorkerReturns(Key.database, deadline: .seconds(5))
            if let id = turn.request(.writeStats(player: player), for: .player(player), holding: hold) {
                saving[id] = player
            }
        // docs:end
        case .saved(let player):
            saving = saving.filter { $0.value != player }
        case .idleKick(let player):
            turn.end(.player(player))
            seats.remove(player)
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Room>) {
        saving.removeValue(forKey: request)
    }

    // docs:room-answer
    /// A synchronous question, answered as a step: `query` returns the answer.
    mutating func answer(_ query: Query, _ turn: inout Turn<Room>) -> Int {
        switch query {
        case .seatCount: seats.count
        }
    }
    // docs:end
}

actor RoomActor: TurnActor {
    let core: TurnCore<Room>
    private(set) var sent: [String] = []

    init(clock: some TurnClock) {
        core = TurnCore(Room(seats: [], saving: [:]), queueLimit: 64, maxReleasesPerBatch: 16, clock: clock)
    }

    @concurrent nonisolated func perform(_ effect: Room.Effect) async -> Room.Input? {
        switch effect {
        case .writeStats(let player): .saved(player: player)
        case .log: nil
        }
    }

    func flush(_ outputs: consuming [String]) {
        sent.append(contentsOf: outputs)
    }

    func heldKeys() -> Int { core.stats.heldKeys }
}

@Suite("The documentation's core concepts", .timeLimit(.minutes(1)))
struct ConceptsTests {
    @Test("A room: query, run, a scoped chat, a worker-returns save, a withdraw token and an idle timer")
    func room() async throws {
        try await withinTestHangBound {
            let f = Fixture()
            let clock = TestClock(fixture: f)
            let room = RoomActor(clock: clock)
            // docs:room-use
            let connection = WithdrawToken()
            let seated = try await room.sendAndWait(.join(player: 7, connection: connection), cancellation: .cancelsCall)
            let count = await room.query(.seatCount)
            // docs:end
            #expect(seated == 1)
            #expect(count == 1)

            await room.send(.chat(player: 7, text: "hi"))
            #expect(await room.sent == ["7: hi"])

            await room.send(.saveStats(player: 7))
            for _ in 0 ..< 10_000 where await room.heldKeys() != 0 {
                await Task.yield() // wall-clock: not time: documented code carries no test hooks; yields until the save's result has run
            }
            #expect(await room.heldKeys() == 0)

            // docs:room-token
            // The connection closed before its join stepped: the join is withdrawn.
            let late = WithdrawToken()
            late.withdraw()
            await #expect(throws: TurnError.withdrawn) {
                try await room.sendAndWait(.join(player: 8, connection: late), cancellation: .cancelsCall)
            }
            // docs:end

            // The idle timer: the test clock moves to the deadline, and the timer's sleep returns.
            clock.set(seconds: 60)
            f.open("deadline 60")
            for _ in 0 ..< 10_000 where await room.query(.seatCount) != 0 {
                await Task.yield() // wall-clock: not time: documented code carries no test hooks; yields until the timer has run
            }
            #expect(await room.query(.seatCount) == 0)
        }
    }

    @Test("A scoreboard: one coalesced publish per round, consumed by a publish-now")
    func scoreboard() async throws {
        try await withinTestHangBound {
            let board = ScoreboardActor(clock: TestClock(fixture: Fixture()))
            await board.send(.open)
            // docs:scoreboard-use
            await board.send(.round(points: [3, 1, 4]))
            await board.waitForQuiescence()
            // docs:end
            #expect(await board.published == [[3, 1, 4]])

            // A publish-now in the same step as a round: the round's follow-up is consumed, so the
            // scores go out once.
            await board.send(.roundAndPublish(points: [1, 1, 1]))
            #expect(await bounded { await board.waitForQuiescence() })
            #expect(await board.published == [[3, 1, 4], [4, 2, 5]])
        }
    }
}

/// The "Follow-ups" section of CoreConcepts.md: a scoreboard that publishes once per round.
@PlainData
struct Scoreboard: TurnMachine {
    enum Input: Sendable {
        case open
        case round(points: [Int])
        case roundAndPublish(points: [Int])
        case publish
    }

    enum Key: Hashable, Sendable {
        case board
    }

    // docs:scoreboard-slot
    enum FollowUpSlot: Hashable, Sendable {
        case publish
    }
    // docs:end

    typealias Effect = Never
    typealias Output = [Int]
    typealias Reply = Int

    var scores: [Int]

    mutating func handle(_ input: Input, _ turn: inout Turn<Scoreboard>) {
        switch input {
        case .open:
            turn.start(.board)
        // docs:scoreboard-round
        case .round(let points):
            for (player, gained) in points.enumerated() {
                add(gained, to: player)
                // One publish per round, however many scores changed: later arms join the first.
                turn.followUp(.publish, .publish, of: .board, .afterBatch)
            }
        case .publish:
            turn.emit(scores, for: .board)
        // docs:end
        // docs:scoreboard-now
        case .roundAndPublish(let points):
            for (player, gained) in points.enumerated() {
                add(gained, to: player)
                turn.followUp(.publish, .publish, of: .board, .afterBatch)
            }
            // Publishing now does the pending follow-up's work: retire it, so it doesn't run too.
            turn.consumeFollowUp(.publish, of: .board)
            turn.emit(scores, for: .board)
        // docs:end
        }
    }

    mutating func add(_ points: Int, to player: Int) {
        while scores.count <= player { scores.append(0) }
        scores[player] += points
    }
}

actor ScoreboardActor: TurnActor {
    let core: TurnCore<Scoreboard>
    private(set) var published: [[Int]] = []

    init(clock: some TurnClock) {
        core = TurnCore(Scoreboard(scores: []), queueLimit: 16, maxReleasesPerBatch: 16, clock: clock)
    }

    @concurrent nonisolated func perform(_ effect: Never) async -> Scoreboard.Input? {}

    func flush(_ outputs: consuming [[Int]]) {
        published.append(contentsOf: outputs)
    }
}

// docs/turns/README.md § Plain data and tools: the before/after example, in both languages, each
// block in its own namespace so the two `Room`s compile side by side. `PlayerID` is the
// repository's own (SwiftStateTree), which is plain data. `Connection` sits at file scope: the
// macro's extension is written there and names the field types unqualified. It and the example
// are fileprivate, so they don't leak into the rest of the target.
fileprivate final class Connection {}

fileprivate enum PlainDataDocExample {
    enum Before {
        struct Room {
            var players: [PlayerID: Connection]       // Connection is a class
            var lastChat: ContinuousClock.Instant
        }
    }

    enum After {
        @PlainData
        struct Room {
            var players: Set<PlayerID>                // PlayerID is @PlainData
            var lastChat: TurnInstant
        }
    }

    enum BeforeZH {
        struct Room {
            var players: [PlayerID: Connection]       // Connection 是 class
            var lastChat: ContinuousClock.Instant
        }
    }

    enum AfterZH {
        @PlainData
        struct Room {
            var players: Set<PlayerID>                // PlayerID 是 @PlainData
            var lastChat: TurnInstant
        }
    }
}

@Test("The plain-data example's after form is plain data")
func plainDataDocExampleIsPlain() {
    func isPlain<T: PlainData>(_: T.Type) -> Bool { true }
    #expect(isPlain(PlainDataDocExample.After.Room.self))
    #expect(isPlain(PlainDataDocExample.AfterZH.Room.self))
    #expect(isPlain(PlayerID.self))
    #expect(isPlain(SessionID.self))
}

// MARK: - The lane

/// The lane's documented example: a keeper that a transport tells, from its own thread, that the
/// output gate closed on a failure. The next step takes the failure first, and a step that runs
/// while it lands sees it through `takeReports`.
@PlainData
struct Keeper: TurnMachine {
    enum Input: Sendable {
        case tick
    }

    @PlainData
    enum Failure: Sendable {
        case transportFailed
    }

    enum Key: Hashable, Sendable {
        case land
    }

    enum Output {
        case sync
    }

    typealias Effect = Never
    typealias Reply = Int
    typealias LaneReport = Failure

    var failed: Failure?
    var ticks: Int = 0

    init() {}

    mutating func handle(_ input: Input, _ turn: inout Turn<Keeper>) {
        switch input {
        case .tick:
            turn.start(.land)
            ticks += 1
            StepHooks.duringStep?()
            // docs:lane-take
            // A failure posted while this step ran stops its output.
            if let failure = turn.takeReports().first { failed = failed ?? failure }
            if failed == nil { turn.emit(.sync, for: .land) }
            // docs:end
        }
    }

    // docs:lane-report
    mutating func handleReport(_ report: Failure, _ turn: inout ReportTurn<Keeper>) {
        failed = failed ?? report
    }
    // docs:end
}

actor KeeperActor: TurnActor {
    // docs:lane-actor
    let core: TurnCore<Keeper>
    nonisolated let lane: TurnLane<Keeper.LaneReport>?

    init() {
        let core = TurnCore(Keeper(), queueLimit: 64, maxReleasesPerBatch: 16, clock: ContinuousTurnClock())
        self.core = core
        // The core's own lane: a lint checks it's assigned from `core.lane`.
        self.lane = core.lane
    }
    // docs:end

    private(set) var synced = 0

    @concurrent nonisolated func perform(_ effect: Never) async -> Keeper.Input? {}

    func flush(_ outputs: consuming [Keeper.Output]) {
        synced += outputs.count
    }

    var failed: Keeper.Failure? { core.read { $0.failed } }
}

@Suite("The lane, as documented")
struct LaneConceptTests {
    @Test("A failure posted before a tick steps first; one posted during a tick stops its output")
    func keeperSeesFailures() async {
        let keeper = KeeperActor()
        await keeper.send(.tick)
        #expect(await keeper.synced == 1)
        // docs:lane-post
        // From any thread, with no await: the core's next step takes the report first.
        _ = keeper.post(.transportFailed)
        // docs:end
        await keeper.send(.tick)
        #expect(await keeper.failed == .transportFailed)
        #expect(await keeper.synced == 1)

        let second = KeeperActor()
        await StepHooks.$duringStep.withValue({ _ = second.post(.transportFailed) }) {
            await second.send(.tick)
        }
        #expect(await second.failed == .transportFailed)
        #expect(await second.synced == 0)
    }
}
