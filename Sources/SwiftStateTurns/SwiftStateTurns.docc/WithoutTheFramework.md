# Without the framework

The same lobby written three ways, and the one interleaving that tells them apart.

## The scenario

A player joins. While the profile load is in flight, the player leaves. Then the load returns. The tests force this order with a hold inside the profile store's `load`, never with timing (`Tests/SwiftStateTurnsTests/ComparisonTests.swift`). All three versions use the same store:

```swift
/// Where profiles come from: a service in production, a held fake in a test.
protocol ProfileStore: Sendable {
    func load(_ player: Int) async -> String
}
```

## A plain actor

Check the state, await the load, write the result:

```swift
/// A plain actor: check, await, write.
actor NaiveLobby {
    let profiles: any ProfileStore
    private(set) var seats: [Int: String] = [:]

    init(profiles: any ProfileStore) {
        self.profiles = profiles
    }

    func join(_ player: Int) async -> Int {
        guard seats[player] == nil else { return seats.count }
        let name = await profiles.load(player)
        // Other calls ran during the await: the player may have left. This write doesn't know.
        seats[player] = name
        return seats.count
    }

    func leave(_ player: Int) {
        seats[player] = nil
    }
}
```

The `await` lets `leave` run in the middle of `join`. When `join` resumes, the check it made before the `await` is stale, and it seats a player who has already left: a ghost seat. The test asserts that the ghost seat appears; it documents the hazard instead of failing on it. Swift's checker accepts this code, and a thread sanitizer doesn't flag it. There is no data race: every access runs on the actor.

## Fixed by hand

The repository fixes this today with a generation ticket, captured before the `await` and checked after it:

```swift
/// The same actor, fixed by hand: a ticket captured before the await, checked after it.
actor TicketedLobby {
    let profiles: any ProfileStore
    private(set) var seats: [Int: String] = [:]
    private var joins = GenerationTable<Int>()

    init(profiles: any ProfileStore) {
        self.profiles = profiles
    }

    func join(_ player: Int) async throws -> Int {
        guard seats[player] == nil else { return seats.count }
        let ticket = joins.issue(player)
        let name = await profiles.load(player)
        // Still this join's generation? `ifCurrent`'s closure can't await, so the check and the
        // write are one synchronous segment.
        guard joins.ifCurrent(ticket, { _ in seats[player] = name }) != nil else {
            throw LobbyError.left
        }
        return seats.count
    }

    func leave(_ player: Int) {
        joins.end(player)
        seats[player] = nil
    }
}
```

`leave` ends the player's generation. The ticket that `join` took is then no longer current, and `ifCurrent`'s closure doesn't run. The closure isn't `async`, so no `await` can split the check from the write.

Limit: every method with an `await` has to remember this fix. Each one needs its own ticket, its own check, and a test that forces the interleaving.

## On the turn core

The machine of <doc:WorkedExample> behaves the same way, with no ticket in any handler:

```swift
case .leave(let player):
    // Ends the binding: a load in flight is abandoned, and its late result is stale.
    turn.end(.player(player))
    seats[player] = nil
```

`leave` ends the player's key. The load's request belongs to that key, so the request closes, and the joiner gets its answer in the same segment. When the load returns, its result is an input whose request has closed. It goes to `handleStale` and seats nobody. The same scenario passes, and the hazard can't be written:

- A handler can't `await`. The `await-in-handle` snippet under `scripts/must-not-compile/turns/` doesn't compile.
- A handler can't start a task that reaches the machine. That is the `task-in-handle` snippet.
- A result can only come back as an input, and the core checks its request before `handle` sees it.
