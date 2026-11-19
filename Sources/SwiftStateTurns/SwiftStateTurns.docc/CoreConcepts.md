# Core concepts

The ideas the core is built from, in the order they build on each other.

## Overview

The core uses a dozen ideas. Each one below builds on the ones before it, and each answers a question a game server runs into. The examples come from the lobby of <doc:WorkedExample> and from a room that adds the rest of the tools; both are compiled and run as tests.

## Input and step

An *input* is a message to the machine, such as "player 7 wants to join". A *step* is the machine handling one input. Steps run one at a time and can't `await`, so nothing changes the state while a step reads it.

An input arrives in one of three ways. `send` delivers an input and returns without waiting for a reply; it returns once the input has stepped or queued (see Input policy). `sendAndWait` delivers it and waits for the machine's reply, which the step gives with `reply`. `query` puts a synchronous question to the machine, answered in a step, and returns the answer.

```swift
let connection = WithdrawToken()
let seated = try await room.sendAndWait(.join(player: 7, connection: connection), cancellation: .cancelsCall)
let count = await room.query(.seatCount)
```

API: ``TurnActor/send(_:)``, ``TurnActor/sendAndWait(_:cancellation:)``, ``Turn/reply(to:_:after:)``, ``TurnActor/query(_:)``, ``TurnMachine/answer(_:_:)``.

## Effect and perform

An *effect* is work the machine needs done outside a step, written as data: "load player 7's profile". A step can't wait for the database, so it asks for the work, and the actor's `perform` does it off the actor. Its result comes back as a new input.

There are two ways to ask. A *request* is work that a key owns and that the core tracks (the next sections explain both). `run` is untracked work: no key owns it, and nothing waits for it, such as a log line.

```swift
// Untracked work: no key owns it, and nothing waits for it.
turn.run(.log("joined \(player)"))
```

API: ``TurnActor/perform(_:)``, ``Turn/request(_:for:holding:)``, ``Turn/run(_:)``.

## Key

A *key* names something whose work can stop being wanted, such as a player's place in the lobby. `start` starts it, and `end` stops it. When a player leaves mid-join, ending their key is how the machine says "the profile load for this player is no longer wanted".

```swift
case .leave(let player):
    // Ends the binding: a load in flight is abandoned, and its late result is stale.
    turn.end(.player(player))
    seats[player] = nil
```

API: ``Turn/start(_:)``, ``Turn/end(_:)``, ``Turn/isLive(_:)``.

## Generation

A *generation* is one lifetime of a key, from one `start` to the next. Calling `start` on a live key *supersedes* it: the old generation ends, and a new one starts. This answers the reconnect case. A player who drops and joins again gets a new generation, so a profile load started for the old connection can't seat the new one.

@Image(source: "supersede-timeline.svg", alt: "Generation 1 of key player 7 owns a load request and has a chat input queued under its scope. A start begins generation 2: the request is abandoned with keyEnded, its late result goes to handleLateResult, and the queued chat is withdrawn.")

When the key is superseded, three things happen to the old generation. Its requests close (`handleAbandoned` runs, with `keyEnded`). A result that comes back later goes to `handleLateResult`. Inputs queued under the key's scope are withdrawn, and their callers get `withdrawn`. That includes an input sent while a batch runs and admitted after the supersede. Limit: an input that arrives while the key isn't live (before its first `start`, or after an `end`) steps under the next generation; use a fresh key per binding, such as a connection or session id, when that matters. Such an input belongs to the generation that `start` begins, so a later supersede of that generation withdraws it too. When several callers are withdrawn at once, the order in which they get their answers is unspecified.

API: ``Turn/start(_:)`` (true when it superseded), ``Turn/generation(of:)``, ``Generation``.

## Request

A *request* is an effect that a key's current generation owns. It has an ID, and it finishes in one of two ways. Its result arrives while it is open: the result steps in `handle`. Or it closes first, and it is *abandoned*: `handleAbandoned` runs with the reason (the deadline passed, the key ended, or it was cancelled). A result that arrives after that goes to `handleLateResult`, so a hung database load that finally returns changes nothing.

```swift
let hold = Hold.untilRequestCloses(Key.store, deadline: .seconds(2))
guard let id = turn.request(.loadProfile(player: player), for: .player(player), holding: hold) else { return }
loading[id] = player
```

API: ``RequestID``, ``Turn/cancel(_:)``, ``Abandonment``, ``TurnMachine/handleAbandoned(_:_:_:)``, ``TurnMachine/handleLateResult(_:_:)``.

## Hold

A *hold* makes later inputs wait behind work in flight. The profile store serves one load at a time; without a hold, a second join would start a second load while the first is still running. A request takes a hold on a key, and inputs that name that key wait until the hold ends.

@Image(source: "hold-timeline.svg", alt: "Join 7 steps and makes a load request that holds the store. Join 8 arrives while the load is in flight and queues. When the load's result steps, the request closes, the hold ends, and join 8 steps.")

A hold has two kinds. `untilRequestCloses` ends when the request closes, for any reason. `untilWorkerReturns` ends only when the work returns, even if the request was abandoned first. Use it for work that changes something else while it runs, such as a database write:

```swift
// The write changes the database while it runs: the hold lasts until the worker
// returns, even if the request is abandoned first.
let hold = Hold.untilWorkerReturns(Key.database, deadline: .seconds(5))
if let id = turn.request(.writeStats(player: player), for: .player(player), holding: hold) {
    saving[id] = player
```

Every hold has a deadline, and the compiler requires it. Without one, a load that hangs would keep every later join waiting for as long as it hangs.

API: ``Hold``, ``Turn/request(_:for:holding:)``.

## Input policy

An *input policy* is the machine's rule for each kind of input: whether it waits behind a hold, and which key it belongs to (its *scope*). An input that has to wait is *queued*. If the player its scope names leaves while it waits, it is withdrawn and never steps.

```swift
// Waits while a save holds the database; withdrawn if the player leaves meanwhile.
case .chat(let player, _): .normal(waitsFor: .database, belongsTo: .player(player))
case .saveStats: .normal(waitsFor: .database, belongsTo: nil)
```

The queue has a limit, set when the core is made. An input over the limit is refused with `queueFull`, so a flood of inputs can't grow memory without bound. A `control` input is never gated: a disconnect or a stop always steps. A step's own follow-up can keep its place behind a hold with `queue`. Such a *pinned* input isn't withdrawn by a scope or refused by the limit.

API: ``InputPolicy``, ``Turn/queue(_:behind:)``, ``TurnError``.

## Withdraw token

A *withdraw token* lets the sender give up an input before it steps. A key can't do this, because the input hasn't started anything yet. A join from a connection that closed before its join stepped shouldn't seat anyone:

```swift
let late = WithdrawToken()
late.withdraw()
await #expect(throws: TurnError.withdrawn) {
    try await room.sendAndWait(.join(player: 8, connection: late), cancellation: .cancelsCall)
```

The core reads the token when the input arrives and again when it leaves the queue. A machine never stores a token.

API: ``WithdrawToken``, ``Turn/revoke(_:)``.

## Timers and the clock

A *timer* is an input that a key schedules for later, such as "kick this player if they say nothing for a minute". Each key has at most one timer, and a new one replaces it. Ending or superseding the key drops it.

```swift
// Kicked after a minute without a word; each chat line re-arms it.
turn.timer(at: turn.now + .seconds(60), for: .player(player), .idleKick(player: player))
```

`turn.now` reads the core's clock, once per batch. The clock is injected, with no default. A test passes a clock it moves by hand, so a one-minute timer fires when the test says so, not after a minute.

API: ``Turn/timer(at:for:_:)``, ``Turn/now``, ``TurnClock``, ``TurnInstant``.

## Batch and `maxReleasesPerBatch`

A *batch* is the steps one entry into the actor causes: a `send`, a `sendAndWait`, or a result coming back. When a load's result releases a hold, the queued joins behind it step in the same batch. There is no run loop between entries. The `maxReleasesPerBatch` caps how many queued inputs a release lets step in one batch; the rest continue in a later one, so a long queue behind one hold can't keep other callers out. Limit: it counts only queued inputs that a hold's release lets step; abandonments and sends that arrive during the batch don't count.

```swift
queueLimit: 64,
maxReleasesPerBatch: 16,
clock: ContinuousTurnClock()
```

API: ``TurnCore/init(_:queueLimit:maxReleasesPerBatch:clock:)``.

## Incarnation

An *incarnation* is a random number each core gets when it is made. Every task the core starts carries it. A result whose incarnation doesn't match the actor's core is dropped and counted, never stepped. It guards the case where a result reaches a core other than the one that asked for it, whose request IDs could otherwise match. There is nothing to write: the core checks it.

API: ``TurnStats`` (`foreignCompletions`).

## Caller cancellation

A `sendAndWait` waits, and the task that waits can be cancelled, for example when the client's connection task ends. Each `sendAndWait` says what that means; there is no default. `.ignoresCancel`: the caller keeps waiting and gets the real result. Pick it when the caller must know the outcome, such as a shutdown waiting for a save. `.cancelsCall`: the caller gets `CancellationError` as soon as the actor handles the cancellation, unless its answer came first, and an input still queued is withdrawn and never steps. An input that already stepped goes on. Pick it when a gone caller means the input is no longer wanted, such as a join from a client that left.

API: ``CallerCancellation``.

## Summary

| Concept | The question it answers | API |
|---|---|---|
| Input and step | How does work reach the state, one change at a time? | `send`, `sendAndWait`, `reply`, `query` |
| Effect and perform | How does a step get async work done without awaiting? | `perform`, `request`, `run` |
| Key | Is this work still wanted? | `start`, `end` |
| Generation | Is this result from the current binding, after a reconnect? | `start`, `Generation` |
| Request | Did the work finish, or was it given up? | `RequestID`, `handleAbandoned`, `handleLateResult` |
| Hold | What must wait behind work in flight? | `Hold` |
| Input policy | Does this input wait, and whose is it? | `InputPolicy`, `queue` |
| Withdraw token | Can the sender give up an input before it steps? | `WithdrawToken`, `revoke` |
| Timer and clock | How does a step act later, and how does a test control time? | `timer`, `now`, `TurnClock` |
| Batch | How much runs per entry? | `maxReleasesPerBatch` |
| Incarnation | Does this result belong to this core? | `foreignCompletions` |
| Caller cancellation | What happens when the caller's task is cancelled? | `CallerCancellation` |
