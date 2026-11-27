# A barrier wait in SwiftStateTurns (#953)

Revision 0 (2026-11-27). A design for review. This revision adds no code. Refs #700, #943, #953, #954, #958.

## 1. Problem

Moving the keeper onto the turn core hand-rolls one shape again and again. A caller waits in a table in the model, and the step that meets the condition replies to it. The callers today, or planned:

| Wait | Key | Released by | Per-caller deadline | A newer caller | Where |
|---|---|---|---|---|---|
| The freeze | generation | the work's end (`debugInFlightWork == 0`) | yes; an expired budget answers at once | a superseded generation's callers are answered `false` at the work's end, not at their timeout | `coreBarrierWaits.freeze`, #948 |
| The initialization | one key | the step that ends the initialization, done or failed | no | all wait together | `coreBarrierWaits.initialized`, #948; commit 1a |
| A tick in flight | one key | the tick's `.recordTaken` | no | all wait together | the drain's `.waitForTick`, the stop, the tick-land freeze (commit 1b) |
| A player's OnLeave | `PlayerID` | the leave's end, or every key at the drain | no | all wait together | `KeyedBarrierWaits<PlayerID>`, #958 (#943) |
| The shutdown's callers | one key | the destroy's end | no | all wait together | `.shutdown(caller)`, commit 1b |
| Inputs held while frozen | generation | the resume | no | arrival order | `heldWhileFrozen`, #948 |

The last row holds inputs, not replies: a release re-runs each input's step. That's where #948 round 3's MF1 came from. A cancellation delivered through a hop lost to the resume, so a cancelled caller's job started anyway.

#948's must-fixes across rounds 1–3 sat in these hand-rolled waits:
- a missing wake-up on a failure path;
- deadline arithmetic (an overflow, and an expired budget answered through a zero timer);
- tests that read the current waiters instead of counting registrations;
- a cancellation read in the wrong segment.

## 2. Proposal

The waiter table moves into the core, keyed by a type the machine names. The core owns four things: the deadlines, the exactly-once reply, the cancellation flag and the counts.

```swift
public protocol TurnMachine {
    /// The keys callers park on. `Never` for a machine that parks none (the default).
    associatedtype BarrierKey: Hashable & Sendable = Never
}

extension Turn {
    /// Defers `caller`'s reply: it waits on `key` until a step releases the key, its deadline
    /// passes, or its caller cancels. `policy` says what happens when the key has callers already.
    /// Returns the parked caller's handle, or nil when the policy refused it (the refusal was replied).
    public mutating func park(
        _ caller: InputID, on key: M.BarrierKey,
        deadline: TurnInstant? = nil, onTimeout: M.Reply,
        policy: BarrierPolicy<M.Reply> = .queue
    ) -> ParkedCaller?

    /// The key's barrier ends: every caller parked on it, oldest first, leaves the table and is
    /// answered `answer(parked)` exactly once. A caller whose cancellation flag is set is passed
    /// with `cancelled: true`, and gets `CancellationError` instead whatever `answer` returns.
    public mutating func release(_ key: M.BarrierKey, _ answer: (ParkedCaller) -> M.Reply)

    /// Releases every key (a drain or a failure): the same per caller.
    public mutating func releaseAll(_ answer: (M.BarrierKey, ParkedCaller) -> M.Reply)

    /// The parked callers on `key` now, and how many ever parked on it (tests count events).
    public func parked(on key: M.BarrierKey) -> (now: Int, ever: Int)
}

public struct ParkedCaller: Sendable {
    public let id: InputID
    /// Read in the releasing step: set by the caller's `onCancel`, synchronously, inside `cancel()`.
    public let cancelled: Bool
}

public enum BarrierPolicy<Reply: Sendable>: Sendable {
    /// Parks behind the callers already there; all are released together.
    case queue
    /// Answers the callers already there with `reply` now; then parks. Newest wins.
    case supersede(answeringOlder: Reply)
    /// Refuses: answers this caller with `reply` now, and parks nothing.
    case reject(with: Reply)
}
```

### 2.1 Cancellation: a flag set in `onCancel`, read by the releasing step

This is Review's note on #948. A cancellation that arrives through a hop can lose to a step that runs first. So the core doesn't deliver it as an event. `sendAndWait` installs a set-once flag per call, and its `onCancel` sets the flag synchronously, inside `cancel()`. The parked entry keeps the flag. The releasing step reads it as `ParkedCaller.cancelled`, and a machine whose release does work for the caller skips that work. This is the shape of `awaitActionResult`'s `box.callerCancelled` and of 1a's `ActionJobCallerCancellation`.

The caller's resume needs one rule. With `.cancelsCall`, the core already resumes a live waiter at once with `CancellationError`, through its withdraw. The parked entry stays until the next release or timeout, which then finds no waiter and drops its reply, as a stale reply is dropped today. So a parked caller resumes once, either through the withdraw or through the release, and never twice. With `.ignoresCancel`, the flag is still set, and the release answers `CancellationError`. That matches the keeper reading `Task.isCancelled` after its wait.

### 2.2 Deadlines

`deadline` arms one timer per parked caller on the core's `DeadlineHeap`, as `MailTurn` timers are armed. When it fires, it answers `onTimeout` and removes the entry. A release cancels the timers of the callers it takes. A deadline already passed when the caller parks is answered `onTimeout` in the parking step, with no timer armed. That is #948's "an expired budget answers at once" rule, and it means no zero-length timer exists. The deadline arithmetic (an instant plus a budget, saturating) is the core's, with the core's tests behind it.

### 2.3 Replay

A park, a release and a timeout are steps the core records like any other: their replies are the steps' outputs.

The cancellation flag is ambient, though: a replay can't re-read it. Two options:
- **(a)** The releasing step records which callers it passed as cancelled, as part of its entry. Replay then feeds the recorded set back. This costs a field on the entry record.
- **(b)** A barrier whose release reads `cancelled` is live-only, as `.cancelsCall` is today (MailReplayTests 13w: a replaying core stops on a `.cancelsCall` call).

The design leans to (b) for revision 0. Every adopter in §1 is a live keeper path, and #612 keeps re-evaluation off the core. (a) can come with the first replayed adopter.

## 3. Questions for Review

- **B-Q1, the per-key policy.** Is it chosen per park (as above) or declared per key type? The freeze needs `.supersede` across keys, not within one: a newer generation answers the older generation's callers at the work's end, not at park time. Is that a release of the older key from the freeze step, with no policy needed, or a `supersede` that defers its answer? The design leans to the release: the policy covers the same key only. That keeps `.queue`, `.supersede` and `.reject` simple, and the freeze's cross-generation rule stays in the machine.
- **B-Q2, held inputs.** The last row of §1 parks inputs, not replies. Should `park` take an input to re-run (`park(input:on:)`, released by stepping it again) or stay replies-only, with the held intakes kept in the machine? The design leans to replies-only for revision 0. The held-input row moves later, once #954's flows decide how a step is resumed.
- **B-Q3, the key type.** One `BarrierKey` per machine (an enum of the keeper's waits) or one table per wait? The design leans to one associated type. The keeper's would be an enum: `.freeze(generation)`, `.initialized`, `.tick`, `.leaveEnd(PlayerID)`, `.shutdown`.
- **B-Q4, replay.** (a) or (b) in §2.3.

## 4. The first adopter: `KeyedBarrierWaits` in #958

#958 adds `KeyedBarrierWaits<PlayerID>` on the keeper's side, for a rejoin that waits for its player's leave in flight (#943). Its doc names #953 as its replacement. The mapping:

| `KeyedBarrierWaits` | The barrier |
|---|---|
| `makeID()` before the cancel handler | the core's call ID (`InputID`) and its flag |
| `park(key, id:, continuation)` | `turn.park(caller, on: .leaveEnd(player), onTimeout: …)`, policy `.queue` |
| `count(key)` | `turn.parked(on:).now`, plus `.ever` for tests |
| `release(key)` | `turn.release(.leaveEnd(player)) { _ in .done }` |
| `releaseAll()` | `turn.releaseAll` at the drain |
| `cancel(key, id:)` returning false after a release | the core's withdraw, plus a reply dropped as stale |

It moves after #958 merges and the barrier lands: one commit that swaps the table and reruns #958's tests unchanged. The keeper's own path keeps `KeyedBarrierWaits` until K2-3 deletes that path.

## 5. Order

1. Review this design.
2. Land the barrier in SwiftStateTurns, with core tests:
   - park, release and timeout, each answering exactly once;
   - an expired deadline answered at park;
   - a cancel concurrent with a release, forced in both orders with a hold;
   - `.supersede` and `.reject`;
   - the `ever` count;
   - a replaying core refusing a barrier that reads `cancelled` (option (b)).
3. Its adopters, one commit each, each rerunning its differential cases:
   - #958's leave wait;
   - `.awaitInitialized` (1a's `coreBarrierWaits.initialized`);
   - the freeze;
   - then 1b's tick wait and shutdown callers.

Whether this goes ahead of 1b is the maintainer's call (Main asked).

## Probes

**P953-1, 1a's initialization as a chain (#954's shape) next to the hand-written `InitializationPhase`.** Throwaway, not committed: one `swiftc` file on a toy core. Both versions run the same six scenarios and the outputs are compared.
- **Version A** is 1a's shape: a phase enum, five result inputs and a drain input, each switching over every phase.
- **Version B** is a generic `Chain` helper. It holds the steps in order, a ticket per seam, and the exits as non-optional closures: `onRequirementFailed`, `onFail`, `onDone`, `onStale`. Then comes the same flow, written as four steps.

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
| A drain mid-flow | written per phase (`.resolving, .recording` fail; the rest named) | one `abandon`, which bumps the ticket; the late result goes to `onStale` |
| What it doesn't force | nothing per phase is left out, but each arm is the author's to get right | a step's own `ok == false` (the failed seam result): step 1's `guard ok` is the author's choice, and leaving it out compiles. Seam results typed as `Result` would force it |
| Matching outputs | — | all six scenarios match A; the one difference is the label of the second `.initialize` ("refused" vs "stale") |

What P953-1 shows, as a reference for #954 and not a decision:
- The chain halves the per-flow code and moves the ticket and drain checks into one place, so the #952-class bugs (one exit of three checked, a teardown keyed on a still-racing outcome) can't be written per flow.
- It doesn't remove the need to handle a seam's failure. That takes typed seam results (`Result<Value, Failure>` per step), or a second required closure per step.
- The hand-written phase enum, 1a's shape, forces more arms. Each arm is an explicit decision, which is what the maintainer's rule asks for while the flows are few.

**The other direction, `async`/`await` split by a macro or a check, was not probed.** It would need a macro that cuts a function at its `await`s into steps, and a check that a value read from state before an `await` isn't used after it. Neither can be written as a one-file probe. What the chain probe says about it: the cut points would be the chain's seams, so the same two forced-exit questions apply: what a drain does at each `await`, and what a failed result does. The check would replace the chain's rule that a step receives the current state, never a snapshot. Temporal and Durable Functions split at awaits by replaying a history of results, and share no state across workflows; here every flow shares the land's state. So the check is the part with no prior art to copy, and it would want its own probe once #954 is scheduled.

The barrier API in §2 needs no probe of its own in this revision. Its behavior (one reply per caller, timers on the core's heap, withdraw then a stale reply) is existing core behavior that the §5 tests will pin. B-Q1 and B-Q2 are API choices, not questions about how Swift behaves.
