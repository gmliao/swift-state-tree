# A barrier wait in SwiftStateTurns (#953)

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

Names are distinct from the hold queue's (`Runtime`'s `Parked`, `parked`, `park(_:behind:)`, `parkedCount`), as Review asked. Review's shape is `park(caller, on:, holding:, timeout:)`, `release(where:) -> [Released]`, `parkedCount(on:)`; revision 1 spells it `wait`, `release(where:)` and `waiterCount(on:)`. Inside the core, the table is `barrierWaiters`.

```swift
public protocol TurnMachine {
    /// The keys a caller waits on. `Never` (the default): the machine has no barriers.
    associatedtype BarrierKey: Hashable & Sendable = Never
    /// What a waiting caller holds, handed back by the release.
    associatedtype BarrierPayload: Sendable = Never
}

extension Turn {
    /// `caller`'s reply is deferred: it waits on `key`, holding `payload`, until a step
    /// releases the key or `timeout` passes. A caller already cancelled, or with no waiter,
    /// doesn't wait (§2.3).
    public mutating func wait(
        _ caller: InputID, on key: M.BarrierKey, holding payload: M.BarrierPayload,
        timeout: BarrierTimeout<M.Reply>? = nil
    )

    /// Every caller waiting on a key that `matches`, oldest first by `InputID.raw` across the
    /// matching keys, taken out of the table with its timer cancelled. The machine replies to
    /// each one (`turn.reply`) or continues it, in this step.
    public mutating func release(where matches: (M.BarrierKey) -> Bool) -> [Released<M>]

    /// The callers waiting on `key` now.
    public func waiterCount(on key: M.BarrierKey) -> Int
}

public struct Released<M: TurnMachine>: Sendable {
    public let caller: InputID
    public let key: M.BarrierKey
    public let payload: M.BarrierPayload
    /// Set by the caller's `onCancel`, synchronously, inside `cancel()`, and read here.
    public let cancelled: Bool
}

public struct BarrierTimeout<Reply: Sendable>: Sendable {
    /// From the step that waits. `<= .zero`: already expired (§2.4).
    public var budget: Duration
    public var answer: Result<Reply, any Error>
}
```

How the adopters release:
- **The freeze's work end:** `release { if case .freeze = $0 { true } else { false } }`, which answers each caller by its key's generation. The cross-generation rule stays in the machine, which is why the policy is dropped.
- **The drain:** `release { if case .leaveEnd = $0 { true } else { false } }`, which leaves `.tick` (the drain's own wait) and `.shutdown` (answered by the destroy's end) in the table.
- **The leave's end:** `release { $0 == .leaveEnd(player) }`, then J2c for each join it hands back, with `&turn`.

The kernel's keyed wake is the prior art: `__wake_up` with a key that the wake function matches.

### 2.2 Answers are `Result`s; the core never overrides one

The core answers a caller in only two places: at a timeout, with `BarrierTimeout.answer`, and where §2.3 says. Every other answer is the machine's, through `turn.reply`, which already takes a `Result<M.Reply, any Error>`. So the initialization barrier can answer `LandInitializationError`, and the drain can answer a closed land.

The core doesn't turn a released caller's answer into `CancellationError`. It passes `cancelled` in `Released`, and the machine decides:
- An adopter that keeps the keeper's "throw if cancelled after the wait" answers `.failure(CancellationError())` when `cancelled` is set.
- One that skips work for a cancelled caller (the held intakes) reads it before the work.

`.ignoresCancel` keeps its contract (Values.swift: "the caller keeps waiting and gets the real result"): the flag is information, not an answer.

### 2.3 Cancellation and the withdraw

**The flag.** On a core whose `BarrierKey` isn't `Never` (`TurnCore<M>.usesBarriers`), `sendAndWait`'s `onCancel` inserts the call's `InputID` into one core-owned, locked `Set<InputID>`, synchronously, inside `cancel()`. Nothing is allocated per call: a call that never waits costs one insert, and only if it is cancelled. A core without barriers installs nothing. `release` and a timeout read the set and remove the caller's ID. The step that answers a caller that never waited, and the withdraw, remove it too.

**The withdraw removes the entry.** For a `.cancelsCall` caller with a live waiter, `callerCancelled` withdraws it and resumes it with `CancellationError`, as today. In the same step, it removes the caller's barrier entry and cancels the entry's timer, through a reverse index `[InputID: BarrierKey]`. So no entry outlives its caller:
- no count includes a caller that has thrown;
- no timer fires later for a stale reply, so a stale timeout takes no mail ordinal;
- no entry piles up on a key that is released rarely.

The prior art is the kernel wait queue's `finish_wait`: a waiter removes itself on wake-up or interrupt, so a waker never meets an entry whose task has gone.

**A caller that can't wait.** `wait` registers nothing when the caller's flag is already set, or when the caller has no waiter (a pre-cancelled `.control` input submits without one, TurnActor.swift:63–71). Instead it answers at once:
- with `.failure(CancellationError())` if the flag is set;
- with no reply at all if there's no waiter: a reply would find no waiter.

#958's `awaitLeaveEnd` does the same: it checks `Task.isCancelled` before it registers.

The payload of a caller that didn't wait is dropped, so a held join that can't wait doesn't run. That is its keeper's behavior: a cancelled `join` throws before J2c. The adopter that must run a payload whatever happens (none in §1) would call its continuation itself instead of waiting.

**A timeout racing a cancel.** Each timeout runs in its own entry. If `onCancel` set the flag before the timeout's step:
- with `.ignoresCancel`, the timeout answers `answer`;
- with `.cancelsCall`, the timeout finds the flag. If the withdraw's hop is still queued, the timeout answers `.failure(CancellationError())`, the entry leaves, and the hop then finds no waiter: a stale cancellation.

Either way the caller resumes once.

### 2.4 The timeout

`timeout` is a `Duration` budget. The core adds it to `turn.now` with saturation (`TurnInstant.+` wraps, Values.swift:172, which was #948 round 1's overflow). `budget <= .zero` is already expired, as `debugFreeze`'s `remaining > .zero` reads. An expired caller is answered `timeout.answer` in the waiting step, with no timer armed, so no zero-length timer exists.

A live timer is a `DeadlineEntry` with `isTimer: true` and a timer generation as its ticket. The caller's `InputID` is not the ticket: an `InputID`'s raw value can equal a `RequestID`'s. The entry maps its generation back to the waiting caller. A release cancels the timers of the callers it takes.

The timeout and its answer are one optional parameter, since four of the six waits have no timeout.

### 2.5 Replay and the recording model

`TurnCore` records mail hand-outs by dispatch ordinal, not steps or replies. `wait` and `release` run inside their enclosing step and take no ordinal of their own. A live barrier timeout is an entry, and takes one ordinal through `entryBoundary`. A stale one takes none, and with §2.3's removal there are no stale ones.

The cancellation flag is ambient, so a replay can't re-read it. Revision 1 takes (b): **a replaying core refuses `wait`** with a `fatalError`, as `sendAndWait(.cancelsCall)` does on a mail replay (MailReplayTests 13w). Every adopter in §1 is a live keeper path (#612 keeps re-evaluation off the core). Recording the flags as entry data, (a), can come with the first replayed adopter.

### 2.6 Counts for tests

`waiterCount(on:)` is the production read. It can only be read inside a step, and a key leaves the map when it empties, so keys like `.leaveEnd(PlayerID)` and `.freeze(generation)` don't pile up for the land's life.

Tests count events, not state: each `wait` that registers emits `TurnDiagnostic.barrierWait`, and `TurnStats.barrierWaits` is a scalar counter of registrations, observed the way `.queued(total:)` is. There is no per-key `ever`: it would never shrink.

### 2.7 Edge cases

- **A caller that waits twice** traps (`precondition`). One caller has one deferred reply.
- **A `turn.reply` to a waiting caller** (not through a release) traps in debug builds. In release builds it answers the caller and removes the entry and its timer, so the caller still resumes once.
- **`endAll()`** releases nothing. The entries stay for the machine's own `release`, because a key's end isn't a barrier's end. `close()` answers every waiting caller `.failure(TurnError.closed)`, oldest first, and empties the table, as it answers queued calls.
- **On `MailTurn`**, a failure that comes by mail can release. `release(where:)` and `waiterCount(on:)` are on `MailTurn` too; `wait` isn't, since a mail has no caller.

## 3. Questions

- B-Q1: settled by Review. There is no policy, and the freeze's rule is a machine `release(where:)`.
- B-Q2: settled. Held inputs are payloads (§2.1).
- B-Q3: agreed. One associated type, which Review's `swiftc -typecheck` showed is source compatible.
- B-Q4: settled. (b), §2.5.
- **B-Q5, open: the names.** `wait` / `release(where:)` / `waiterCount(on:)`, or Review's `park` / `parkedCount` beside the hold queue's same names? Revision 1 proposes the distinct ones.

## 4. The first adopter: #958's leave wait, on the core

On the keeper's path, #958 parks a continuation in `KeyedBarrierWaits<PlayerID>`. On the core path, like #950's §3.3, the join holds a `KeeperContinuation` (`.joinAfterKick`). The leave's end runs `continueAfterLeave`, then J2c, with `&turn`.

| `KeyedBarrierWaits` (keeper) | The barrier (core) |
|---|---|
| `makeID()` before the cancel handler | the call's `InputID`; its flag is in the core's set |
| `Task.isCancelled` checked before `park` | `wait` registers nothing for a cancelled caller (§2.3) |
| `park(player, id:, continuation)` | `turn.wait(caller, on: .leaveEnd(player), holding: .joinAfterLeave(…))` |
| `count(player)` | `turn.waiterCount(on: .leaveEnd(player))`; tests count `TurnStats.barrierWaits` |
| `release(player)`, which resumes each continuation | `for r in turn.release(where: { $0 == .leaveEnd(player) })`: J2c for each `r`, or `.failure(CancellationError())` if `r.cancelled` |
| `releaseAll()` at the drain | `release { if case .leaveEnd = $0 { true } else { false } }`, which leaves `.tick` and `.shutdown` |
| `cancel(player, id:)` returning false after a release | the withdraw removes the entry (§2.3); a release that came first took it |

This adopter moves after #958 merges and the barrier lands, in one commit that reruns #958's tests unchanged. The keeper's own path keeps `KeyedBarrierWaits` until K2-3 deletes that path.

## 5. Order

1. Review revision 1.
2. Land the barrier in SwiftStateTurns, with core tests:
   - wait, release and timeout, each answering once, including an expired budget answered at the wait and a saturating large budget;
   - the withdraw removing the entry and its timer (`waiterCount` 0, no late timeout, no ordinal);
   - a pre-cancelled and a waiterless caller that don't wait;
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

B-Q5 is a naming choice and needs no probe. The rest of §2 (one reply per caller, the withdraw, timers on the heap) is existing core behavior that §5's tests pin.
