# A worked example

A lobby that loads each player's profile before seating them, one load at a time.

## The machine

The machine's state is three dictionaries and a count, and `@PlainData` checks each field's type. Each player has a binding, the key `.player(id)`. A join is admitted behind a second key, `.store`. While one join's load holds the store, the next join queues until that load closes.

```swift
/// Where profiles come from: a service in production, a held fake in a test.
protocol ProfileStore: Sendable {
    func load(_ player: Int) async -> String
}
```

```swift
/// A lobby that loads a player's profile before seating them, one load at a time.
@PlainData
struct Lobby: TurnMachine {
    enum Input: Sendable {
        case join(player: Int)
        case loaded(player: Int, name: String)
        case leave(player: Int)
    }

    enum Effect: Sendable {
        case loadProfile(player: Int)
    }

    /// A player's binding, and the profile store, which one load holds at a time.
    enum Key: Hashable, Sendable {
        case player(Int)
        case store
    }

    typealias Output = String
    typealias Reply = Int

    var seats: [Int: String]
    var loading: [RequestID: Int]
    var waiting: [Int: InputID]
    /// Loads that came back after their join was given up.
    var late: Int
    /// How long one load may hold the store before its join is given up.
    var loadDeadline: Duration = .seconds(2)

    func inputPolicy(for input: Input) -> InputPolicy<Key> {
        switch input {
        // A join waits while another join's load holds the profile store.
        case .join: .normal(waitsFor: .store, belongsTo: nil)
        default: .normal(waitsFor: nil, belongsTo: nil)
        }
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<Lobby>) {
        switch input {
        case .join(let player):
            // The player's binding. The load is a request it owns, holding the store with a
            // deadline.
            turn.start(.player(player))
            let hold = Hold.untilRequestCloses(Key.store, deadline: loadDeadline)
            guard let id = turn.request(.loadProfile(player: player), for: .player(player), holding: hold) else { return }
            loading[id] = player
            if let caller = turn.input { waiting[player] = caller }
        case .loaded(let player, let name):
            // The load's result, back as an input. It reaches `handle` only while its request
            // is open, so the player is still joining: the state changes here, in a step.
            loading = loading.filter { $0.value != player }
            seats[player] = name
            turn.emit("welcome \(name)", for: .player(player))
            if let caller = waiting.removeValue(forKey: player) {
                turn.reply(to: caller, .success(seats.count))
            }
        case .leave(let player):
            // Ends the binding: a load in flight is abandoned, and its late result is stale.
            turn.end(.player(player))
            seats[player] = nil
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Lobby>) {
        // The deadline passed, or the player left: the joiner is told, and the store is free.
        guard let player = loading.removeValue(forKey: request),
              let caller = waiting.removeValue(forKey: player) else { return }
        let error: LobbyError = why == .deadline ? .profileUnavailable : .left
        turn.reply(to: caller, .failure(error))
    }

    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<Lobby>) {
        // A load that returned after its request closed: nothing to seat.
        late += 1
    }
}

enum LobbyError: Error {
    case profileUnavailable
    case left
}
```

In `handle(.join)`, the step starts the player's key and makes the load a request owned by that key. The request holds the store with ``Hold/untilRequestCloses(_:deadline:)``. The deadline is part of the hold, so a holding request can't be written without one. The step stores the request's ID and the caller, and returns. Nothing waits.

The deadline is the machine's `loadDeadline`, two seconds by default. The example under "Using it" passes a long one, so a slow machine can't run out the deadline before the load returns.

The load's result arrives as `.loaded`, in a later step, and only while its request is open. That step changes the state, emits an output and answers the caller. The other cases:

- The deadline passes first: the request is abandoned. `handleAbandoned` answers the caller with an error, and the store's hold is released.
- The player leaves first: `.leave` ends the player's key, which abandons the request the same way.
- A load returns after either of these: it goes to `handleLateResult`, which only counts it.
- A second `.join` for the same player: `.join` waits for the store, so it queues until the first load's request closes. When it steps, its `start(.player(p))` begins a new binding for the player and a second load. The first load is already done; nothing is abandoned.

## The actor

```swift
/// The actor that owns the lobby's core.
actor LobbyActor: TurnActor {
    let core: TurnCore<Lobby>
    nonisolated let profiles: any ProfileStore
    private(set) var sent: [String] = []

    init(profiles: any ProfileStore, loadDeadline: Duration = .seconds(2)) {
        self.profiles = profiles
        core = TurnCore(
            Lobby(seats: [:], loading: [:], waiting: [:], late: 0, loadDeadline: loadDeadline),
            queueLimit: 64,
            maxReleasesPerBatch: 16,
            clock: SystemTurnClock()
        )
    }

    /// The profile load, off the actor. Its result comes back as an input.
    @concurrent nonisolated func perform(_ effect: Lobby.Effect) async -> Lobby.Input? {
        switch effect {
        case .loadProfile(let player):
            return .loaded(player: player, name: await profiles.load(player))
        }
    }

    /// The step's outputs, between steps: here, a list; in a server, the sends.
    func flush(_ outputs: consuming [String]) {
        sent.append(contentsOf: outputs)
    }
}
```

``TurnActor/perform(_:)`` does the work of an effect and returns the input that reports it. ``TurnActor/flush(_:)`` takes a step's outputs between steps; in a server, this is where the sends go. The core's timer task, which serves every deadline and timer, doesn't keep the actor alive. An effect's task does, until its result has been handled.

### Why `perform` is both `nonisolated` and `@concurrent`

`nonisolated` keeps `perform` away from the actor's state. It can't read `core`, so an effect can't look at or change the machine behind a step's back. A must-not-compile check holds this.

`nonisolated` alone doesn't say where `perform` runs. With the `NonisolatedNonsendingByDefault` feature on, a `nonisolated async` function runs on its caller's actor (Swift 6.2's approachable-concurrency settings turn the feature on). The core calls `perform` from the actor, so a slow load would occupy the actor, and every input would wait behind it. `@concurrent` makes `perform` always run off the actor, whatever the module's settings.

Limit: `@concurrent` can't be used alone here. Without `nonisolated`, the method would be isolated to the actor, which `@concurrent` doesn't allow, and the compiler refuses the pair.

## The clock

The core reads time and sleeps through an injected ``TurnClock``. There is no default clock. ``SystemTurnClock`` is the production one: its instants are measured from ``TurnInstant/processOrigin``, and its sleep returns no earlier than the instant it was given, unless it is cancelled. The core fires what is due at that instant without reading the clock again, so a sleep that returned early would fire entries early. The actor above passes `SystemTurnClock()`. A test passes a clock it moves by hand.

## Using it

```swift
let lobby = LobbyActor(profiles: ImmediateProfiles(), loadDeadline: .seconds(300))
let count = try await lobby.sendAndWait(.join(player: 7), cancellation: .ignoresCancel)
// count == 1, and the lobby flushed "welcome player 7".
```

``TurnActor/send(_:)`` submits an input. It returns once the input's step has run, or once the input queued. ``TurnActor/sendAndWait(_:cancellation:)`` also waits for the step's ``Turn/reply(to:_:after:)``. Here, the reply comes in the `.loaded` step, after the load. Each `sendAndWait` says what its task's cancellation does (``CallerCancellation``); there is no default.

The code on this page is compiled and run by `Tests/SwiftStateTurnsTests/WorkedExampleTests.swift`, which also checks that each block here matches it.
