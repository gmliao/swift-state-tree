// The examples of the documentation's "Core concepts" article (CoreConcepts.md) that the lobby
// of WorkedExampleTests.swift doesn't show: a room with an asked seat count, an untracked log
// line, a save under a worker-returns hold, chat scoped to a player, joins that carry their
// connection's withdraw token, and an idle timer. Compiled and run here; the rot check in
// WorkedExampleTests.swift covers its blocks.

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

// docs/turns/README.md § Plain data and tools: the before/after example, in both languages, each
// block in its own namespace so the two `Room`s compile side by side. `PlayerID` and `Connection`
// sit at file scope: the macro's extension is written there and names the field types unqualified.
// All three are fileprivate, so this PlayerID doesn't shadow SwiftStateTree.PlayerID elsewhere in
// the target.
@PlainData
fileprivate struct PlayerID: Hashable, Sendable {
    var raw: Int
}

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
}
