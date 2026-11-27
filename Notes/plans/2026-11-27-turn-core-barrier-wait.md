# A barrier wait in SwiftStateTurns (#953)

Revision 2 (2026-11-27), code-first. Review's NOT GO on revision 1 was the plan's second semantics NOT GO, so the barrier is now implemented in SwiftStateTurns with core tests for every exit (`Sources/SwiftStateTurns/Barrier.swift`, `Tests/SwiftStateTurnsTests/BarrierTests.swift`), and this plan describes that code. Revision 1's seven must-fixes shared one theme: a waiter's leftovers (its flag, payload and timer) need an owner on every exit, not just the release. Each is answered here:
1. **The flag's owner** is the cancellation's hop. It removes the flag on every exit, the stale ones included. A reply never touches the flag set (§2.3).
2. **`.ignoresCancel` stays handler-free.** The flag and the `.cancelled` refusal are `.cancelsCall`'s only (§2.3).
3. **No payload is dropped.** A wait that doesn't register hands its payload back to the waiting step (`WaitOutcome`). A registered wait removed without a release steps `handleWaitEnded` with it, before the caller's answer leaves the core (§2.1, §2.2).
4. **`close()` leaves waits alone.** `endAll()` ends every wait, oldest first, through the hook, and a later `wait` is refused `.ended`. A wait is caller-bound: a continuation of internal work with no caller stays model state (§2.6).
5. **Barrier timeouts have a kind** (`DeadlineKind.barrier`), which arm, `deadlineIsLive`, the fire and compaction all read. Each registration gets a fresh generation (§2.4).
6. **The flag stays set for the call's life,** across a release and a re-wait. `cancelled` is sampled once per `release(where:)` call (§2.3).
7. **A published reply claims its caller.** One rule, in `drainProducts`, covers `reply` and `reply(after:)` alike. A `wait` on a caller with a staged reply stops the process, in debug and release builds alike (§2.5).

From the shoulds:
- The reply path's extra lookup sits behind `usesBarriers` and a non-empty table.
- §2.4 states timeout precedence.
- `MailTurn` releases but doesn't wait (§2.1).
- The Public API list names `TurnDiagnostic.barrierWait` and `TurnError.timedOut` (§2.7).

From the nit:
- `BarrierTimeout` is gone: the budget is a `Duration`.
- B-Q3 is two associated types.

Revision 1 answered revision 0's NOT GO (the withdraw's removal, `Result` answers, the saturating budget, `release(where:)`, payloads, replay refusing `wait`, scalar counts). Revision 0 was the first draft. Refs #700, #943, #953, #954, #958.

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

## 2. The barrier, as built

The core owns the table, its removal on every exit, the timeouts, the cancellation flag, the order and the counts. The machine owns what a release does and what each payload holds.

### 2.1 The API

```swift
public protocol TurnMachine {
    /// The keys a caller waits on. Default `Never`: the barrier paths fold away.
    associatedtype BarrierKey: Hashable & Sendable = Never
    /// What a waiting caller holds, handed back however its wait ends.
    associatedtype BarrierPayload: Sendable = Never
    /// A registered wait ended without a release. Default: replies `.failure(why.error)`.
    mutating func handleWaitEnded(_ ended: ReleasedWait<Self>, _ why: WaitEnd, _ turn: inout Turn<Self>)
}

extension Turn {
    public mutating func wait(_ caller: InputID, on key: M.BarrierKey, holding payload: M.BarrierPayload,
                              timeout: Duration? = nil) -> WaitOutcome<M>
    public mutating func release(where matches: (M.BarrierKey) -> Bool) -> [ReleasedWait<M>]
    public func waiterCount(on key: M.BarrierKey) -> Int
}
extension MailTurn {   // a mail can finish a waiter, not make one wait: it has no caller
    public mutating func release(where matches: (M.BarrierKey) -> Bool) -> [ReleasedWait<M>]
    public func waiterCount(on key: M.BarrierKey) -> Int
}

public struct ReleasedWait<M> { caller: InputID; key: M.BarrierKey; payload: M.BarrierPayload; cancelled: Bool }
public enum WaitOutcome<M> { case waiting, refused(M.BarrierPayload, WaitRefusal), expired(M.BarrierPayload) }
public enum WaitRefusal { case noWaiter, cancelled, ended }
public enum WaitEnd { case withdrawn, timedOut, answered, ended }
```

Every payload comes back exactly once, by one of three routes:

| How the wait ends | Where the payload comes back | Who answers the caller |
|---|---|---|
| Doesn't register: no waiter, cancelled, ended | `WaitOutcome.refused`, in the waiting step | the waiting step |
| Expired budget (`<= .zero`) | `WaitOutcome.expired`, in the waiting step | the waiting step |
| `release(where:)` | the returned array, in the releasing step | the releasing step: a reply, or a continuation that may `wait` again |
| `.cancelsCall` withdraw | `handleWaitEnded(.withdrawn)`, stepped in the cancellation's entry | the core answers `CancellationError` after the hook's step; a reply from the hook finds no waiter |
| Timeout | `handleWaitEnded(.timedOut)`, stepped in the deadline's entry | the hook (default `TurnError.timedOut`) |
| A reply published while waiting | `handleWaitEnded(.answered)`, its own step after the drain | the published reply, held by the driver until the hook's step has run |
| `endAll()` | `handleWaitEnded(.ended)`, one step per wait, oldest first, after the ending step and after its replies claimed theirs | the hook (default `TurnError.closed`) |

So a #958 join that holds a #852 reservation undoes it in whichever step gets the payload back. Every hook steps before the caller's answer leaves the core, as #958's keeper ends the reservation before the join returns:
- the withdraw's and the timeout's hooks run inside their entry;
- a claimed reply's continuation is held in the hook's queue entry and resumed right after the hook.

The public type is `ReleasedWait`, not `Released`. The plain name collided with a test helper class in SwiftStateTurnsTests, and an adopter's own `Released` would collide the same way.

Oldest first: `release(where:)` sorts the matching callers by `InputID` across the keys, and `endAll` uses the same order. The prior art is the kernel's keyed wake (`__wake_up` with a key that the wake function matches), Akka's stash and unstash for payloads that run again on release, and Erlang's `gen_server` deferred `reply/2` with monitors, whose cleanup on a waiting caller's exit `handleWaitEnded` plays.

### 2.2 Answers are `Result`s; the core answers only the withdraw

Every answer is the machine's (`turn.reply`, a `Result<M.Reply, any Error>`), except the withdraw's `CancellationError`, which the core gives as it does for every `.cancelsCall` caller today. The hook's default answers `why.error`; a machine replaces it to answer a value instead (the freeze answers `false` on a timeout).

### 2.3 Cancellation: the flag and its owner

On a core with barriers (`TurnCore.usesBarriers`, `BarrierKey != Never`), the core keeps a locked `CancelledCallers` set:
- **Set:** by a `.cancelsCall` caller's `onCancel`, synchronously inside `cancel()`, before it schedules its hop.
- **Removed:** by that hop (`callerCancelled`), in a `defer`, on every exit: stale before the mailbox take, stale after it, or the withdraw.
- **Never touched by replies.** The reply path adds no lock.

`.ignoresCancel` installs no handler, so it never has a flag and a release reads `cancelled: false` for it (`ignoresCancel` test).

Between the cancel and its hop, every step reads the flag:
- `release(where:)` samples it once per call, for the whole array, under one lock (`cancelled(among:)`), so the array never shows a pair of flags that didn't coexist;
- `wait` refuses a flagged caller (`.refused(_, .cancelled)`), so a re-wait in the step that released it doesn't park a cancelled caller (`flagSticksAcrossReleaseAndRewait`);
- the hook's `ReleasedWait.cancelled` reads it in its own step.

A cancel after the reply sets the flag and schedules a hop. The hop finds no waiter and removes the flag (`cancelAfterReplyLeavesNoFlag`).

When the hop finds the caller waiting, it does five things, in this order:
1. removes the waiter;
2. withdraws any parked input;
3. removes the barrier entry and its timer;
4. steps `handleWaitEnded(.withdrawn)`;
5. answers `CancellationError`.

The hop is an existing entry with its ordinal, so the barrier adds none. A pre-cancelled `.control` input has no waiter, so its `wait` is refused `.noWaiter`.

### 2.4 The timeout

`timeout` is a `Duration` budget, added to `turn.now` (the batch's clock sample) with saturation:
- `<= .zero` is `.expired`, with no timer;
- the instant is clamped, not the budget first: from a negative `now` a budget past `Int64`'s range can still land below `Int64.max` (`saturatingDeadline`, `saturatingDeadlineArithmetic`);
- a budget past the range from a non-negative `now` waits until `Int64.max`, and the heap's head is that instant (`saturatingBudget`).

Each registration takes a fresh generation from `nextBarrierTimer`. `barrierTimers[generation] = caller` is the liveness that every heap path reads through `DeadlineEntry.kind == .barrier`:
- `deadlineIsLive`, so compaction and the wake's stale pops;
- the fire, which consumes only the matching generation;
- the staged arm in `drainProducts`, which skips a generation its wait already gave up.

So:
- a re-wait's new generation leaves the old heap entry stale (`rewaitFreshGeneration`);
- a timer whose wait ends in the step that armed it is never armed (`replyInTheWaitingStep`);
- an entry already in a wake's due list when an earlier entry's hook released its waiter fails the liveness recheck before `entryBoundary` (`dueEntryReleasedInTheSameWake`).

The heap deletes lazily, so stale barrier entries stay in it until a wake or a compaction drops them, report `.staleTimer`, and take no ordinal. An entry counts toward the stale count (which decides compaction) only once its arm pushed it (`BarrierEntry.armed`). A firing one, already out of the heap, doesn't count.

Precedence:
- The budget makes the timeout eligible at its instant, not exact: the driver serves mail and queued work before a due timer, so a release can win after the instant.
- A caller that is both cancelled and expired at `wait` is `.refused(_, .cancelled)`.
- A timeout and a cancel race as two entries: whichever steps first ends the wait, and the other finds it gone (`timeoutAgainstCancel`, both orders).

### 2.5 How a reply claims a caller

One rule, at the place a reply is published (`drainProducts`): a published reply whose caller still has a barrier entry removes the entry and its timer, and queues `handleWaitEnded(.answered)` with the payload and the held answer. The caller resumes right after the hook's step. `reply(after:)` publishes through the same queue when its request completes or is abandoned, so it claims the caller then, not when it was staged (`replyAfterClaimsCaller`). A completion keeps its staged replies in `repliesAfter` through its own step, so a `wait` there sees them as staged. The check sits behind `usesBarriers` and a non-empty table.

`wait` stops the process (`fatalError`, in debug and release builds alike) for a caller that already waits, or that has a reply staged (in `replies`, or held for a request by `reply(after:)`). One caller has one answer. A reply staged after the wait, in the same step, is legal, and claims it at publication.

### 2.6 `close`, `endAll` and callers that aren't calls

- **`close()`** is intake close and leaves barrier waits alone: those callers have stepped. A release, their timeout or `endAll` ends them (`closeLeavesWaits`). The drain's `.tick` wait and `.shutdown`'s callers survive it.
- **`endAll()`** marks the waits for ending, and `stopDeadlines()` empties the heap. The driver ends them right after it has published the ending step's replies:
  - a waiter whose reply was staged (a `reply(after:)` of a request `endAll` closes, or one staged in that step) is claimed by it, `.answered`, with that reply as its answer (`endAllWithStagedReply`);
  - every other waiter goes to the hook queue as `.ended`, oldest first.

  Each payload comes back in a step of its own after the ending step. A step that must answer some callers otherwise (`.shutdown` with the destroy's result) releases them before `endAll`, in the same step (`releaseThenEndAll`). After it, `wait` is refused `.ended`.
- **A wait is caller-bound** (an `InputID` with a waiter). A continuation of internal work, such as a drain started by the land's own timer, has no caller, so it can't be a barrier wait. It stays model state (a phase), released by the same step that would release the waiters.

### 2.7 Replay, counts and the public API

- **Replay:** `wait` stops the process on a replaying core. The flag is ambient, so a replay can't re-read it. Every adopter in §1 is a live keeper path (#612). The registration, the release, the refusals and the `.answered` and `.ended` hooks take no entry. The `.answered` and `.ended` hooks take a dispatch ordinal each, as an abandonment's step does. A live timeout takes one through `entryBoundary`; the withdraw's hook runs inside the cancellation's entry.
- **Counts:** `waiterCount(on:)` is the production read. Tests count events: `TurnStats.barrierWaits` and `TurnDiagnostic.barrierWait` per registration, plus the `package` reads `barrierWaitersForTesting` and `cancelledCallersForTesting`.
- **Public API (additive):**
  - `TurnMachine.BarrierKey`, `.BarrierPayload` and `.handleWaitEnded` (defaulted);
  - `Turn.wait`, `.release(where:)` and `.waiterCount(on:)`, with `MailTurn.release(where:)` and `.waiterCount(on:)`;
  - `ReleasedWait`, `WaitOutcome`, `WaitRefusal` and `WaitEnd`;
  - `TurnStats.barrierWaits`.

  The new public enum cases break an exhaustive switch over those enums: `TurnDiagnostic.barrierWait` and `TurnError.timedOut`. In this repository only the tests' `Fixture.observe` switches over `TurnDiagnostic`.

  `package`: `DeadlineEntry.kind` and `DeadlineKind`; `init(…, isTimer:)` stays as a convenience.

## 3. Questions

- B-Q1: settled by Review. There is no policy, and the freeze's rule is a machine `release(where:)`.
- B-Q2: settled. Held inputs are payloads.
- B-Q3: agreed. Two associated types, `BarrierKey` and `BarrierPayload`, both defaulted to `Never`, which keeps existing machines source compatible.
- B-Q4: settled. (b), §2.7.
- B-Q5: settled: `wait` / `release(where:)` / `waiterCount(on:)`.

## 4. The first adopter: #958's leave wait, on the core

On the keeper's path, #958 parks a continuation in `KeyedBarrierWaits<PlayerID>`. On the core path, like #950's §3.3, the join holds a `KeeperContinuation` (`.joinAfterKick`). The leave's end runs `continueAfterLeave`, then J2c, with `&turn`.

| `KeyedBarrierWaits` (keeper) | The barrier (core) |
|---|---|
| `makeID()` before the cancel handler | the call's `InputID`; a `.cancelsCall` join's flag is set in `onCancel` |
| `Task.isCancelled` checked before `park` | `wait` returns `.refused(payload, .cancelled)` or `.refused(payload, .noWaiter)`; the waiting step undoes the reservation |
| `park(player, id:, continuation)` | `turn.wait(caller, on: .leaveEnd(player), holding: .joinAfterLeave(…))` |
| `count(player)` | `turn.waiterCount(on: .leaveEnd(player))`; tests count `TurnStats.barrierWaits` |
| `release(player)`, which resumes each continuation | `for r in turn.release(where: { $0 == .leaveEnd(player) })`: J2c for each `r`, or `.failure(CancellationError())` plus the reservation's end if `r.cancelled` |
| `releaseAll()` at the drain | `release { if case .leaveEnd = $0 { true } else { false } }`, which leaves `.tick` and `.shutdown` |
| `cancel(player, id:)` returning false after a release | the hop finds the entry gone (stale); when it finds it, `handleWaitEnded(.withdrawn)` |
| the keeper's `defer`, which ends the reservation and the arrival token on every exit | `handleWaitEnded` for `.withdrawn`, `.timedOut`, `.answered` and `.ended`, and the waiting step for a refusal: each ends the reservation with `&turn` |

This adopter moves after #958 merges and the barrier lands, in one commit that reruns #958's tests unchanged. The keeper's own path keeps `KeyedBarrierWaits` until K2-3 deletes that path.

## 5. Order and tests

1. **This PR (#959):** the barrier in SwiftStateTurns, with `BarrierTests`, one case per exit:
   - release order across keys, and a keyed release;
   - timeout, expired budget and saturating budget;
   - the withdraw, including its timer going stale;
   - no waiter;
   - `.ignoresCancel`;
   - the flag across a release and a re-wait;
   - a cancel after the reply;
   - a reply claiming a caller, and `reply(after:)` claiming it at completion;
   - a reply in the waiting step, before the timer is armed;
   - `endAll`, `endAll` with a staged `reply(after:)`, and a release before `endAll`;
   - the deadline arithmetic at the range's edge;
   - `close`;
   - release vs. cancel and timeout vs. cancel, both orders each;
   - a re-wait's fresh generation;
   - a due entry released earlier in the same wake.

   The two process stops (a wait on a replaying core, and a wait on a caller with a staged reply) are exit tests, for the Linux cloud worker, never the Mac.
2. **Adopters,** one commit each, each rerunning its differential cases:
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

Revision 2 is code-first, so its probe is the code: `BarrierTests` (§5) runs the API in SwiftStateTurns, every exit forced by a gate, a diagnostic or an awaited reply.
