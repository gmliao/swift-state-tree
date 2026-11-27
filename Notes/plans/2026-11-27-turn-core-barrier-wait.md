# A barrier wait in SwiftStateTurns (#953)

Revision 2 (2026-11-27). Answers Review's early read on revision 1, three points:
1. §2.7 contradicted the code: `endAll()` calls `stopDeadlines()` and then `close()`. Now `endAll` ends every wait through the hook before its deadlines stop, and `close` leaves waits alone.
2. Payloads were dropped on the withdraw, on a caller that couldn't wait, and on an expired budget. Now every non-release exit hands the payload back through `handleWaitEnded(_:_:_:)` with a `WaitEnd` reason, as `handleAbandoned` does for a request. #958's join holds a #852 reservation that the machine must undo on every exit.
3. The flag set leaked when a cancel raced the resume, and §2.3 answered a cancelled `.ignoresCancel` caller `CancellationError` at `wait`, against §2.2. Now the flag lives in an in-flight map that the caller's own task inserts and removes, and a cancelled caller that has a waiter waits.

B-Q5 is settled: `wait`.

Revision 1 (2026-11-27). Answers Review's NOT GO on revision 0, which had 7 must-fixes and 5 shoulds:
1. The withdraw removes the entry and its timer, and a pre-cancelled or waiterless caller never waits (§2.3).
2. Every answer is a `Result` that the core never overrides (§2.2).
3. The timeout is a saturating `Duration` budget on timer generations (§2.4).
4. `release(where:)`, oldest first, replaces `releaseAll` (§2.1).
5. The waits hold payloads that the release hands back, which settles B-Q2 (§2.1, P953-2).
6. A replaying core refuses `wait`, and the recording model is corrected (§2.5).
7. There is no per-key `ever`; a stats counter and a diagnostic replace it (§2.6).

From the shoulds:
- `BarrierPolicy` is dropped, settling B-Q1.
- The flag costs nothing on a core without barriers.
- The edge cases are specified (§2.7).
- The names are distinct from the hold queue's.
- §4's mapping is redone.

Revision 0 was the first draft. Refs #700, #943, #953, #954, #958.

## 1. Problem

Moving the keeper onto the turn core hand-rolls one shape again and again. A caller waits in a table in the model, and the step that meets the condition answers it, or continues its work. The waits today, or planned:

| Wait | Key | Released by | Timeout | What the release does | Where |
|---|---|---|---|---|---|
| The freeze | generation | the work's end (`debugInFlightWork == 0`) | per caller; an expired budget answers at once | answers every generation: `true` for the current one, `false` for stale ones | `coreBarrierWaits.freeze`, #948 |
| The initialization | one key | the step that ends the initialization, done or failed | none | answers `.done` | `coreBarrierWaits.initialized`, #948; commit 1a |
| A tick in flight | one key | the tick's `.recordTaken` | none | continues the drain or the stop | the drain's `.waitForTick`, the stop, the tick-land freeze (commit 1b) |
| A player's OnLeave | `PlayerID` | the leave's end; at the drain, every player | none | continues the join (J2c): an insert, OnJoin's resolvers, maybe another wait | `KeyedBarrierWaits<PlayerID>`, #958 (#943); #950 §3.3 |
| The shutdown's callers | one key | the destroy's end | none | answers | `.shutdown(caller)`, commit 1b |
| Inputs held while frozen | generation | the resume | none | re-runs each input's step, in arrival order | `heldWhileFrozen`, #948 |

Three of the six rows don't just answer at their release. They continue a flow, with `&turn`. So a wait holds a payload, and the release hands the payloads back to the machine in the releasing step (§2.1).

#948's must-fixes across rounds 1–3 sat in these hand-rolled waits:
- a missing wake-up on a failure path;
- deadline arithmetic (an overflow, an expired budget answered through a zero timer);
- tests that read the current waiters instead of counting registrations;
- a cancellation read in the wrong segment.

## 2. Proposal

The core owns six things: the table, its removal, the timeouts, the cancellation flag, the order and the counts. The machine owns what a release does.

### 2.1 The API

The names are `wait`, `release(where:)` and `waiterCount(on:)` (B-Q5, settled); inside the core, the table is `barrierWaiters`. They stay distinct from the hold queue's names (`Runtime`'s `Parked`, `parked`, `park(_:behind:)`, `parkedCount`).

```swift
public protocol TurnMachine {
    /// The keys a caller waits on. `Never` (the default): the machine has no barriers.
    associatedtype BarrierKey: Hashable & Sendable = Never
    /// What a waiting caller holds, handed back to the machine however its wait ends.
    associatedtype BarrierPayload: Sendable = Never

    /// A wait that ended without a release: the caller withdrew, couldn't wait, timed out, or
    /// the core ended. The entry is already out of the table, with its timer cancelled. The
    /// machine cleans up what the payload holds and answers the caller (`turn.reply`); a reply
    /// to a withdrawn or waiterless caller finds no waiter and is dropped. Default: answers
    /// `.failure(why.error)`.
    mutating func handleWaitEnded(_ ended: Released<Self>, _ why: WaitEnd, _ turn: inout Turn<Self>)
}

extension Turn {
    /// `caller`'s reply is deferred: it waits on `key`, holding `payload`, until a step
    /// releases the key, `timeout` passes, its caller withdraws, or the core ends.
    public mutating func wait(
        _ caller: InputID, on key: M.BarrierKey, holding payload: M.BarrierPayload,
        timeout: Duration? = nil
    )

    /// Every caller waiting on a key that `matches`, oldest first by `InputID.raw` across the
    /// matching keys, taken out of the table with its timer cancelled. The machine replies to
    /// each one or continues it, with `&turn`, in this step.
    public mutating func release(where matches: (M.BarrierKey) -> Bool) -> [Released<M>]

    /// The callers waiting on `key` now.
    public func waiterCount(on key: M.BarrierKey) -> Int
}

public struct Released<M: TurnMachine>: Sendable {
    public let caller: InputID
    public let key: M.BarrierKey
    public let payload: M.BarrierPayload
    /// Whether the caller's task was cancelled by the time this step read it (§2.3).
    public let cancelled: Bool
}

public enum WaitEnd: Sendable, Equatable {
    /// The caller's `.cancelsCall` cancellation withdrew it; it has resumed with `CancellationError`.
    case withdrawn
    /// The caller has no waiter (a pre-cancelled `.control` input), so it never waited.
    case noWaiter
    /// Its budget passed, or was `<= .zero` when it waited.
    case timedOut
    /// `endAll()` ended the core.
    case ended
    public var error: any Error { … }   // CancellationError, CancellationError, TurnError.timedOut, TurnError.closed
}
```

**The payload always comes back.** It returns through `release` or through `handleWaitEnded`, whichever ends the wait, never dropped. #958's join holds a #852 reservation that the machine must undo on every exit, as `handleAbandoned` gives an abandoned request back. So the five ways a wait ends (release, withdraw, no waiter, timeout, `endAll`) are one release path and one hook with four named reasons. A machine switches over `WaitEnd`, so a new reason is a compile error in each adopter, in the spirit of the maintainer's "every exit handled" rule.

The timeout's answer is no longer a parameter: the hook answers `.timedOut` like the other reasons. `TurnError` gains `.timedOut`, a new public case. The adopter that answers a value instead (the freeze answers `false`) does so in its hook.

How the adopters release:
- **The freeze's work end:** `release { if case .freeze = $0 { true } else { false } }`, which answers each caller by its key's generation.
- **The drain:** `release { if case .leaveEnd = $0 { true } else { false } }`, which leaves `.tick` (the drain's own wait) and `.shutdown` in the table.
- **The leave's end:** `release { $0 == .leaveEnd(player) }`, then J2c for each join it hands back.

The prior art is the kernel's keyed wake (`__wake_up` with a key that the wake function matches), and Akka's stash and unstash for payloads that run again on release.

### 2.2 Answers are `Result`s; the core never overrides one

Every answer is the machine's, through `turn.reply` (a `Result<M.Reply, any Error>`): in its release loop, or in `handleWaitEnded`. The core answers nothing itself. The one exception is the hook's default, which a machine replaces. So the initialization barrier can answer `LandInitializationError`, and the drain can answer a closed land.

`Released.cancelled` is information, not an answer:
- An adopter that keeps the keeper's "throw if cancelled after the wait" answers `.failure(CancellationError())` when it's set.
- One that skips work for a cancelled caller (the held intakes) reads it before the work.

`.ignoresCancel` keeps its contract (Values.swift: "the caller keeps waiting and gets the real result"). A cancelled `.ignoresCancel` caller waits like any other, and its release passes `cancelled: true`. Revision 1 answered it `CancellationError` at `wait`, which contradicted that contract; revision 2 removes that case.

### 2.3 Cancellation: the flag, its lifetime, and the withdraw

**The flag lives as long as the call.** On a core whose `BarrierKey` isn't `Never` (`TurnCore<M>.usesBarriers`), the core keeps one locked `[InputID: Bool]` of the calls in flight. `sendAndWait`'s caller task inserts its ID (`false`) before it submits. Its `onCancel` sets the value to `true`, synchronously, inside `cancel()`, if the ID is still there. The caller task removes the ID itself when it resumes, by reply, withdraw or throw, in `sendAndWait`'s own frame. So:
- every inserted ID is removed by the one task that inserted it, whatever answered it;
- a cancel racing the resume only sets a value its own caller removes next;
- nothing leaks.

Revision 1's set was written only by `onCancel` and cleared by the release, so a cancel after the reply left an ID behind. The cost: one locked insert and one remove per call, on barrier cores only. A core without barriers installs nothing.

`release`, `handleWaitEnded` and the timeout read the value as `Released.cancelled`, in their step.

**The withdraw removes the entry.** For a `.cancelsCall` caller with a live waiter, `callerCancelled` withdraws it and resumes it with `CancellationError`, as today. In the same step, the withdraw removes the barrier entry and cancels its timer, through a reverse index `[InputID: BarrierKey]`, and steps `handleWaitEnded(entry, .withdrawn)`. The machine cleans up the payload; its reply finds no waiter.

This step is the cancellation's existing entry, with an ordinal under a mailbox, so it adds no entry. Revision 0's `handleCallerCancelled` hook (#948's reverted b31feae4) is not reborn: this one runs only for a waiting entry, and it doesn't decide the caller's answer, which the withdraw has already given.

The prior art is the kernel wait queue's `finish_wait`: a waiter removes itself on wake-up or interrupt.

**A caller with no waiter.** A pre-cancelled `.control` input submits without a waiter (TurnActor.swift:63–71) and gets no cancellation hop. `wait` registers nothing for it and steps `handleWaitEnded(entry, .noWaiter)` in the waiting step. A cancelled caller that has a waiter waits like any other. A `.cancelsCall` caller's withdraw hop then removes it, and an `.ignoresCancel` caller is answered at its release with `cancelled: true`.

**A timeout racing a cancel.** The timeout is an entry of its own.
- If the withdraw stepped first, it removed the entry and the timer, and the timeout finds nothing: stale, with no ordinal.
- If the timeout steps first, it removes the entry and steps `handleWaitEnded(entry, .timedOut)` with `cancelled` as read; the withdraw's hop then finds the waiter answered and is stale.

The caller resumes once either way.

### 2.4 The timeout

`timeout` is a `Duration` budget. The core adds it to `turn.now` with saturation (`TurnInstant.+` wraps, Values.swift:172, which was #948 round 1's overflow). `budget <= .zero` is already expired, as `debugFreeze`'s `remaining > .zero` reads. An expired caller steps `handleWaitEnded(entry, .timedOut)` in the waiting step, with no timer armed. Its payload comes back like any other.

A live timer is a `DeadlineEntry` with `isTimer: true` and a timer generation as its ticket, never the caller's `InputID`, whose raw value can equal a `RequestID`'s. The entry maps its generation back to the waiting caller. A release, a withdraw or `endAll` cancels the timers of the entries it removes.

### 2.5 Replay and the recording model

`TurnCore` records mail hand-outs by dispatch ordinal, not steps or replies. `wait`, `release` and the `.noWaiter` and expired-budget hooks run inside their enclosing step and take no ordinal of their own. A live timeout is an entry, and takes one ordinal through `entryBoundary`. A stale one takes none. The withdraw's hook runs in the cancellation's entry, which already takes its ordinal.

The cancellation flag is ambient, so a replay can't re-read it. Revision 2 keeps (b): **a replaying core refuses `wait`** with a `fatalError`, as `sendAndWait(.cancelsCall)` does on a mail replay (MailReplayTests 13w). Every adopter in §1 is a live keeper path (#612). (a), recording the flags as entry data, can come with the first replayed adopter.

### 2.6 Counts for tests

`waiterCount(on:)` is the production read, inside a step. A key leaves the map when it empties. Tests count events: each `wait` that registers emits `TurnDiagnostic.barrierWait`, and `TurnStats.barrierWaits` is a scalar counter of registrations. There is no per-key total that only grows.

### 2.7 `close`, `endAll` and the edge cases

The code fixes the order (Turn.swift): `endAll()` stops the core's deadlines (`stopDeadlines()`), marks it ended, withdraws scoped and pinned inputs, then calls `close()`. `close()` only closes intake: queued normal calls are answered `.closed`, and later ones are refused.

- **`close()` leaves waiting entries alone.** A waiting caller has stepped already, as a call whose reply is deferred has, and `close` answers only the queued ones. Its timer stays armed, and a later release or timeout answers it.
- **`endAll()` ends every wait.** It stops every deadline, so a waiter left in the table would never be answered. Before `stopDeadlines()`, it removes every entry, oldest first, and steps `handleWaitEnded(entry, .ended)` for each, in its own step. Each payload comes back, and the default hook answers `.failure(TurnError.closed)`.
- **A caller that waits twice** traps (`precondition`). One caller has one deferred reply.
- **A `turn.reply` to a waiting caller,** not through a release or the hook, traps in debug builds. In release builds it answers the caller, then removes the entry and its timer without stepping the hook, so the caller resumes once. Debug builds catch the lost payload.
- **On `MailTurn`**, a failure that comes by mail can release: `release(where:)` and `waiterCount(on:)` are on `MailTurn` too. `wait` isn't, because a mail has no caller.

## 3. Questions

- B-Q1: settled by Review. There is no policy, and the freeze's rule is a machine `release(where:)`.
- B-Q2: settled. Held inputs are payloads (§2.1).
- B-Q3: agreed. One associated type, which Review's `swiftc -typecheck` showed is source compatible.
- B-Q4: settled. (b), §2.5.
- B-Q5: settled: `wait` / `release(where:)` / `waiterCount(on:)`.

## 4. The first adopter: #958's leave wait, on the core

On the keeper's path, #958 parks a continuation in `KeyedBarrierWaits<PlayerID>`. On the core path, like #950's §3.3, the join holds a `KeeperContinuation` (`.joinAfterKick`). The leave's end runs `continueAfterLeave`, then J2c, with `&turn`.

| `KeyedBarrierWaits` (keeper) | The barrier (core) |
|---|---|
| `makeID()` before the cancel handler | the call's `InputID`; its flag is in the core's set |
| `Task.isCancelled` checked before `park` | a `.cancelsCall` join's withdraw removes its entry and steps `handleWaitEnded(.withdrawn)`; a waiterless one steps `.noWaiter` at the wait (§2.3) |
| `park(player, id:, continuation)` | `turn.wait(caller, on: .leaveEnd(player), holding: .joinAfterLeave(…))` |
| `count(player)` | `turn.waiterCount(on: .leaveEnd(player))`; tests count `TurnStats.barrierWaits` |
| `release(player)`, which resumes each continuation | `for r in turn.release(where: { $0 == .leaveEnd(player) })`: J2c for each `r`, or `.failure(CancellationError())` if `r.cancelled` |
| `releaseAll()` at the drain | `release { if case .leaveEnd = $0 { true } else { false } }`, which leaves `.tick` and `.shutdown` |
| `cancel(player, id:)` returning false after a release | the withdraw removes the entry and steps the hook (§2.3); a release that came first took it |
| — (the keeper's join undoes its #852 reservation on its own throw) | `handleWaitEnded` for every non-release exit: `.withdrawn`, `.noWaiter`, `.timedOut`, `.ended` undo the reservation with `&turn`, as `handleAbandoned` does for an abandoned request |

This adopter moves after #958 merges and the barrier lands, in one commit that reruns #958's tests unchanged. The keeper's own path keeps `KeyedBarrierWaits` until K2-3 deletes that path.

## 5. Order

1. Review revision 1.
2. Land the barrier in SwiftStateTurns, with core tests:
   - wait, release and timeout, each answering once, including an expired budget answered at the wait and a saturating large budget;
   - the withdraw removing the entry and its timer (`waiterCount` 0, no late timeout, no ordinal);
   - a waiterless caller that never waits, and a cancelled `.ignoresCancel` caller that waits and is released with `cancelled: true`;
   - every payload coming back once: through the release or `handleWaitEnded`, for each `WaitEnd` reason;
   - the flag's lifetime: a cancel racing the resume leaves no ID behind (the in-flight map is empty after every call);
   - `endAll()` ending every wait before its deadlines stop, and `close()` leaving waits alone;
   - a cancel concurrent with a release, and one concurrent with a timeout, each forced in both orders with a hold;
   - `release(where:)` order across keys;
   - a payload continued with `&turn`, which waits again;
   - the edge cases in §2.7;
   - a replaying core refusing `wait`.
3. Adopters, one commit each, each rerunning its differential cases:
   - #958's leave wait;
   - `.awaitInitialized`;
   - the freeze, with its held intakes;
   - then 1b's tick wait and shutdown callers.

Whether this goes ahead of 1b is the maintainer's call.

## Probes

**P953-1, 1a's initialization as a chain (#954's shape) next to the hand-written `InitializationPhase`.** Revision 0's probe, unchanged: one throwaway `swiftc` file on a toy core, not committed.
- Version A is 1a's shape: a phase enum, five result inputs and a drain input, each switching over every phase.
- Version B is a generic `Chain` helper: steps in order, a ticket per seam, and the exits as non-optional closures. Then comes the same flow, written as four steps.

Output (macOS, `swiftc -O`, Apple Swift 6.4.2):

```
[no recorder]
  A out [effect resolvers#1, queue finish#1, startLoops]  log ["OnInitialize", "answered 1 done"]
  B out [effect resolvers#1, queue finish#1, startLoops]  log ["OnInitialize", "answered 1 done"]
[recorder]
  A out [effect resolvers#1, effect record#1, startLoops]  log ["OnInitialize", "answered 2 done"]
  B out [effect resolvers#1, effect record#1, startLoops]  log ["OnInitialize", "answered 2 done"]
[resolver failure]
  A out [effect resolvers#1]  log ["failed: resolvers", "answered 1 failed"]
  B out [effect resolvers#1]  log ["failed: resolvers", "answered 1 failed"]
[drain while resolving]
  A out [effect resolvers#1]  log ["failed: drained mid-flow", "answered 1 failed", "stale: resolved#1"]
  B out [effect resolvers#1]  log ["failed: drained mid-flow", "answered 1 failed", "stale: resolved#1"]
[drain while recording]
  A out [effect resolvers#1, effect record#1]  log ["OnInitialize", "failed: drained mid-flow", "answered 1 failed", "stale: recorded#1"]
  B out [effect resolvers#1, effect record#1]  log ["OnInitialize", "failed: drained mid-flow", "answered 1 failed", "stale: recorded#1"]
[initialize twice]
  A out [queue finish#1, startLoops]  log ["OnInitialize", "refused: initialize twice", "answered 0 done"]
  B out [queue finish#1, startLoops]  log ["OnInitialize", "stale: start twice", "answered 0 done"]
FLOW-A: 70 lines
HELPER: 55 lines
FLOW-B: 37 lines
A phase-switch arms: 12
```

The lines are code lines only: no blanks and no comments.

| | A, hand-written phases | B, chain |
|---|---|---|
| Per-flow code | 70 lines | 37 lines, plus a 55-line helper written once |
| Exits the compiler forces | every phase in every result input: 6 switches, 12 arms naming the other phases | 4 closures per flow: requirement, fail, done, stale |
| Stale or superseded result | written per input (a ticket compared in each `where`) | the helper's: one ticket check for every seam |
| A drain mid-flow | written per phase | one `abandon`, which bumps the ticket; the late result goes to `onStale` |
| What it doesn't force | nothing per phase is left out, but each arm is the author's | a step's own failed seam result: leaving out `guard ok` compiles. Typed `Result` seams would force it |
| Matching outputs | — | all six scenarios; the one difference is the label of the second `.initialize` ("refused" vs "stale") |

What P953-1 shows, as a reference for #954 and not a decision:
- The chain halves the per-flow code and moves the ticket and drain checks into one place.
- It doesn't remove the need to handle a failed seam result; that takes typed seam results.
- The hand-written phase enum forces more arms, each an explicit decision.

The `async`/`await` direction, split by a macro or a check, wasn't probed: it needs a macro that cuts at each `await`, and a check that state read before an `await` isn't used after it. Neither fits a one-file probe. Its cut points would be the chain's seams, so the same forced-exit questions apply. Temporal and Durable Functions share no state across workflows, while here every flow shares the land's state, so that check has no prior art to copy.

**P953-2, does `wait(holding:)` with a payload-returning `release(where:)` express #958's J2c on the core?** Throwaway, not committed: a toy `Turn` with the §2.1 shape, and a toy machine with three operations:
- the leave's end, which continues each held join with `&turn` (and may wait again);
- the freeze's work end, which answers every generation;
- the drain, which releases only `.leaveEnd` keys.

Setup: two joins wait on `.leaveEnd("p1")` (IDs 5 and 3, with 5 cancelled), two freezes (IDs 4 and 6, generations 1 and 2, the current generation is 2), and one `.tick` (ID 7). Output (macOS, `swiftc -swift-version 6`, Apple Swift 6.4.2, no warnings):

```
effect OnJoin resolvers for p1/s3
reply 5 failure(Swift.CancellationError())
reply 4 success("false")
reply 6 success("true")
left: tick 1, leaveEnd 0
```

What it shows:
- The release returns its entries out of the table, so the machine's loop holds `&turn` freely. The continuation inserts, launches an effect, or waits again, in the releasing step. Revision 0's `answer` closure couldn't do any of that, because it borrowed `turn`.
- Order is oldest first across the matching keys: 3 before 5, and 4 before 6.
- `cancelled` reaches the machine, which answers `CancellationError` itself (§2.2).
- The drain's `release(where:)` leaves `.tick` in the table.

Revision 2's `handleWaitEnded` needs no separate probe. It has the shape of `handleAbandoned`, a machine hook with `&turn` stepped by the core, which P953-2's release loop already shows can continue or clean up with `&turn`. The rest of §2 (one reply per caller, the withdraw, timers on the heap) is existing core behavior that §5's tests pin.
