# Core concepts

The ideas the core is built from, in the order they build on each other.

## Overview

The core uses a dozen ideas. Each one below builds on the ones before it, and each answers a question a game server runs into. The examples come from the lobby of <doc:WorkedExample> and from a room that adds the rest of the tools; both are compiled and run as tests.

## Input and step

An *input* is a message to the machine, such as "player 7 wants to join". A *step* is the machine handling one input. Steps run one at a time and can't `await`, so nothing changes the state while a step reads it.

A step gets two things: the machine's state (`self`) and a ``Turn``. The turn is the step's only way to act on the outside: for example, to make a request, run work, arm a timer, emit an output, reply, or start and end a key. Some of that takes effect at once: `start`, `end` and `request` update the core's bookkeeping, and the same step sees the change (`isLive`, a request's ID). Publishing and launching wait for the step to end. Then the actor flushes the outputs, publishes the replies and launches the effects, and each effect's result arrives in a later step. A step can lend its turn to a synchronous helper as an `inout` parameter. It can't make, copy, store or move away a turn, and a `Task` or an escaping closure can't capture one, so a turn exists only for the step that received it. `Turn<M>` is generic over the machine so that its methods take the machine's own types: `request` takes an `M.Effect`, `emit` an `M.Output`, `reply` an `M.Reply`, and `start` an `M.Key`. The word comes from the actor model. In E, a turn is one message handled to completion; in Orleans, a turn runs until the handler's next `await`. A step has no `await`, so each step is one whole turn.

The machine acts only when an input arrives. It has no run loop and no task of its own. Inputs come from three places:
- The I/O side, such as a connection's reader, calls `send`, `sendAndWait` or `query`.
- The core delivers the results of effects and the fires of timers, and steps `handleAbandoned` when a request's deadline passes.
- A step schedules the machine's own later inputs: with `timer`, with `request` (its result), with `queue(_:behind:)`, and with a request's deadline.

An input arrives in one of three ways. `send` delivers an input and returns without waiting for a reply; it returns once the input has stepped, been queued or deferred, or been refused (see What a send waits for). `sendAndWait` delivers it and waits for the machine's reply, which the step gives with `reply`. `query` puts a synchronous question to the machine, answered in a step, and returns the answer.

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

`perform` and `flush` are the actor's two ways out, and they differ. `perform` is a command: it runs async, off the actor, and its result comes back as an input. `flush` is an event: the actor calls it synchronously between steps, it returns nothing, and it gets the outputs in the order the steps emitted them. A database load is an effect; a server's sends to its clients go in `flush`.

Effects are data so that a step's work can be checked and replaced. A test's fake `perform` can record each effect a step asked for and return made-up results, with no database; `effectsByInput` counts the effects per input case, in debug builds only. The machine stays the same whether `perform` does the real work, a fake, a simulation or a replay of recorded results.

API: ``TurnActor/perform(_:)``, ``TurnActor/flush(_:)``, ``Turn/request(_:for:holding:)``, ``Turn/run(_:)``, ``TurnCore/effectsByInput``.

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

An input is queued only when it waits behind a hold, or when a step queues it with `queue(_:behind:)`, which parks it even when the key is free. Every other accepted input steps in the batch it arrives in; one deferred while a batch runs steps later in that batch (see What a send waits for).

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

A periodic game tick is a timer that re-arms itself, not a `while` loop. The tick's input carries the instant it was scheduled for, and its step does the tick's work and arms the next tick. When the next tick falls after a late fire is the machine's choice. The core's tests re-arm at the first point of the period's grid after `turn.now`: with a 2-second period, a tick due at 2 s that fires at 7 s re-arms at 8 s, so the missed ticks are skipped, not run as a backlog. Each tick is an input like any other, a test moves the clock to fire it, and ending the key stops the ticks.

One timer in each core serves every request deadline and every timer. The core keeps one sleeping task, which sleeps until the earliest instant that is set. Due entries fire in instant order, and entries at the same instant fire in the order they were set. Each one fires as its own input, in its own batch. One wake fires at most 64 entries back to back; the rest fire after the other work already queued on the actor. Cancelling a request or replacing a timer wakes nothing: the old entry stays until its instant, or until the core drops it, and then does nothing.

A clock's sleep must not return before its instant, unless its task is cancelled. The core fires the entries due at the instant it slept until, without reading the clock again, so a clock that woke early would fire them early.

API: ``Turn/timer(at:for:_:)``, ``Turn/now``, ``TurnClock``, ``TurnInstant``.

## Follow-ups

A *follow-up* is an input a key arms for itself, to step once later: "publish the scores after this round", however many scores the round changed. It is named by its key and a *slot* (the machine's `FollowUpSlot` type), and one is pending per key and slot. An arm while one is pending *joins* it and changes nothing: the first arm's input and trigger stand. The id an arm returns names the follow-up in `handleAbandoned` only. It isn't a request id: `cancel(id)` does nothing for it, and `reply(after: id)` publishes at once.

```swift
case .round(let points):
    for (player, gained) in points.enumerated() {
        add(gained, to: player)
        // One publish per round, however many scores changed: later arms join the first.
        turn.followUp(.publish, .publish, of: .board, .afterBatch)
    }
case .publish:
    turn.emit(scores, for: .board)
```

`.afterBatch` steps it in a new batch, as the actor's own job after the current one. That job is the core's one continuation: it also releases the parked inputs a batch left past its release cap, and it steps the follow-ups that were due when it started, after the releases its loop finds first. Other entries already queued on the actor can run before it. `.afterWork(effect, deadline:)` steps it when `perform(effect)` returns, such as "sync again once the writer has drained"; a deadline that passes first closes it, and `handleAbandoned(id, .deadline)` steps. Either way it steps as a control input, and its slot is freed before it steps, so its step may arm the next one.

A follow-up belongs to its key's generation. Ending or superseding the key closes it unrun, with `handleAbandoned(id, .keyEnded)`, so one armed under an old binding never runs under the new one. A step that does the work itself retires the pending one:

```swift
// Publishing now does the pending follow-up's work: retire it, so it doesn't run too.
turn.consumeFollowUp(.publish, of: .board)
turn.emit(scores, for: .board)
```

A test waits for every follow-up to step or close, instead of sleeping:

```swift
await board.send(.round(points: [3, 1, 4]))
await board.waitForQuiescence()
```

API: ``Turn/followUp(_:_:of:_:)``, ``Turn/consumeFollowUp(_:of:)``, ``Turn/followUpPending(_:of:)``, ``FollowUpTrigger``, ``FollowUpArming``, ``TurnActor/waitForQuiescence(_:of:atMost:)``, ``TurnWork``.

## Batch and `maxReleasesPerBatch`

A *batch* is the steps one entry into the actor causes: a `send`, a `sendAndWait`, or a result coming back. When a load's result releases a hold, the queued joins behind it step in the same batch. There is no run loop between entries. The `maxReleasesPerBatch` caps how many queued inputs a release lets step in one batch; the rest continue in a later one, so a long queue behind one hold can't keep other callers out. Limit: it counts only queued inputs that a hold's release lets step; abandonments and sends that arrive during the batch don't count.

```swift
queueLimit: 64,
maxReleasesPerBatch: 16,
clock: ContinuousTurnClock()
```

API: ``TurnCore/init(_:queueLimit:maxReleasesPerBatch:clock:)``.

## What a send waits for

`send` itself is synchronous. The `await` in `await room.send(...)` is Swift's actor hop: the caller waits until the actor is free, that is, until the batches ahead of it end. Once inside, the input does one of four things before `send` returns:
- It steps now, and its batch runs before `send` returns.
- It is queued behind a hold.
- It is deferred, when `send` is called while a batch runs (from `flush`, say). It is admitted later in that batch, by the same rules.
- It is refused (closed, withdrawn, or over the queue limit): dropped, and counted in `droppedSends`.

`send` waits for none of the input's results or replies. `sendAndWait` waits for the step's `reply`, and throws ``TurnError`` when the input is refused or withdrawn.

So there are three queues. The actor's own queue, kept by the Swift runtime, holds callers waiting to enter. The core's deferred list holds inputs sent while a batch runs; that batch drains it. The core's hold queue holds inputs waiting behind a hold. The wait happens in the caller, before it enters, so no step is ever suspended. A caller that checked its own state before the `await` re-checks it after, as any actor code does.

Swift guarantees no order between calls from different tasks: which one reaches the actor first depends on scheduling and priority. Inputs from one connection keep their order only when one task sends them one after another, so give each connection one loop that awaits each `send` in turn, not a task per message.

API: ``TurnActor/send(_:)``, ``TurnActor/sendAndWait(_:cancellation:)``, ``TurnStats`` (`droppedSends`).

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
| Follow-up | How does a key ask for one step later, however often it asks? | `followUp`, `consumeFollowUp`, `waitForQuiescence` |
| Batch | How much runs per entry? | `maxReleasesPerBatch` |
| What a send waits for | What does `await send` wait for, and in what order? | `send`, `sendAndWait` |
| Incarnation | Does this result belong to this core? | `foreignCompletions` |
| Caller cancellation | What happens when the caller's task is cancelled? | `CallerCancellation` |
