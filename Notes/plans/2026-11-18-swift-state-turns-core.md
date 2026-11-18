# SwiftStateTurns: the turn core target (#551)

**Status:** open, rev 2 (answers the plan review: model checks ported, the holding deadline in the type, the clock contract, merge conditions). Plan for review before any code. Part of #546; milestone "Turn core (SwiftStateTurns)".

**Scope:** a new library target, `SwiftStateTurns`, with no dependency on the rest of the package, plus its macro, lints, tests, must-fail snippets and benches. No adopter changes. `TransportAdapter` adopts it slice by slice later (#546), after #554 and the machine outline.

## 1. What it is, and where it fits

An execution model for stateful asynchronous components. Asynchrony is pushed to the edges:

```
        asynchronous world (network, keeper, timers)
               │ inputs              ▲ effects
               ▼                     │
       ┌──────────────────────────────────────┐
       │ synchronous step, one input per turn │  no await; state changes only here
       │ input + state → state + effects      │
       └──────────────────────────────────────┘
```

- A **turn** is an actor turn, as in E's event loops: one input handled to completion with no suspension. It isn't a game turn. The DocC overview says so in its first paragraph.
- The core is synchronous and handles one input at a time. Work that waits leaves as an `Effect`; its result comes back as a new input. The core, not each handler, decides whether a result is still wanted (keys and generations).
- **Where it fits:** a component that receives inputs from many sources and must keep its state consistent across them: a session manager, a room, matchmaking. Its typical bug is "the state changed while I was awaiting" (#545, #548, #549, #522 all have that shape: a worker changes state after an await, when the lifetime that owned the work may have ended).
- **Where it doesn't:** stateless request/response, and one-way pipelines. Nothing there can change during an `await`, so a machine only adds cost. An actor is converted only when it has the problem.
- **Lineage:** E's communicating event loops; the Elm architecture (and Redux with an effect layer); Erlang's `gen_server`; "functional core, imperative shell"; the reactor pattern (NIO). What this adds: lifetimes and staleness live in the core (keys, generations, scope, end tokens, holds), and the rules are enforced by the compiler and by runtime stops, not by convention.
- **What it changes is the kind of bug.** Timing-dependent reentrancy, hard to reproduce and invisible to TSan, becomes a deterministic logic bug in a synchronous value-type machine that unit tests can find. It doesn't stop a handler from filing a request under the wrong key, never ending a key, missing compensation in `handleStale`, or calling a global.
- **The core owns the step, not the loop.** Tick loops, folds, recording and replay stay with the adopter.

## 2. Package layout

| Target | Kind | Depends on |
|---|---|---|
| `SwiftStateTurns` | library, product `SwiftStateTurns` | `SwiftStateTurnsMacros` only |
| `SwiftStateTurnsMacros` | macro (`@PlainData`) | swift-syntax (the package's pin) |
| `SwiftStateTurnsTests` | Swift Testing | `SwiftStateTurns` |
| `SwiftStateTurnsMacrosTests` | Swift Testing, macro expansion | the macro target |
| `TurnsBench` | executable, release only | `SwiftStateTurns` |

- `SwiftStateTree` does **not** depend on it in this PR. The adapter takes the dependency in slice 1.
- Tools version stays 6.0; nothing here needs a newer one. The pinned toolchain (6.2.4) is the gate; a local 6.3.x or 6.4.x is fine for development.
- Must-fail snippets go under `scripts/must-not-compile/turns/`, checked by the existing generated-package script (`scripts/check-must-not-compile.sh`), extended to build a second snippet set against the `SwiftStateTurns` product.

## 3. The API

Names are final unless Review objects; every one of them is in the DocC.

### 3.1 Values

```swift
public struct InputID: Hashable, Sendable, PlainData      // one per `call`; names its waiter
public struct RequestID: Hashable, Sendable, PlainData    // one per `request`
public struct Generation: Hashable, Sendable, PlainData   // comparisons and logs only

public final class EndToken: @unchecked Sendable {         // marked upstream, read by the core; not PlainData
  public init()
  public var isEnded: Bool { get }
  public func markEnded()
}

public enum Admission<Key: Hashable & Sendable>: Sendable {
  case external(hold: Key?, scope: Key?, unless: EndToken? = nil)
  case control
}
public enum Hold<Key: Hashable & Sendable>: Sendable {   // every holding request has a deadline
  case untilRequestCloses(Key, deadline: Duration)
  case untilWorkerRetires(Key, deadline: Duration)
}
public enum Abandonment: Sendable, Equatable { case keyEnded, deadline, cancelled }
public enum TurnError: Error, Sendable, Equatable { case closed, overloaded, withdrawn }
public enum CallerCancellation: Sendable { case ignored, honoured }
```

### 3.2 The machine

```swift
public protocol TurnMachine: Sendable {          // a value type; every stored field is PlainData
  associatedtype Input: Sendable                 // external inputs and effect results alike
  associatedtype Effect: Sendable                // asynchronous work, as data
  associatedtype Output                          // synchronous sink items
  associatedtype Key: Hashable & Sendable
  associatedtype Reply: Sendable
  associatedtype Query = Never                   // a synchronous collaborator's questions
  associatedtype Answer = Never

  func admission(of input: Input) -> Admission<Key>                     // default: .external(hold: nil, scope: nil)
  mutating func handle(_ input: Input, _ turn: inout Turn<Self>)        // not async
  mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Self>)  // default: nothing
  mutating func handleStale(_ input: Input, _ turn: inout Turn<Self>)   // default: nothing
  mutating func answer(_ query: Query, _ turn: inout Turn<Self>) -> Answer
}
```

**Only a `PlainData` machine runs.** `TurnCore.init` requires `M: PlainData` and `TurnActor.M` is `TurnMachine & PlainData`, so a machine without `@PlainData` (one that stores a class, a closure or an `EndToken`) doesn't compile where it would be run. `TurnMachine` doesn't refine `PlainData`: that would give every machine the conformance with no check behind it, and `Turn<Self>` in the requirements would need it on every conformer. The constraint sits on the core's initializer instead, which is the only way to make a core. A hand-written conformance is the remaining way around the macro; the lint refuses it (§7), and the runtime stop for a class machine stays behind it.

### 3.3 The turn

```swift
public struct Turn<M: TurnMachine>: ~Copyable {  // no public init: a handler can't make, copy or move one
  public let input: InputID?                     // this step's caller, when it came through `call`
  public var now: TurnInstant { mutating get }   // at most one clock read per segment

  // Lifetimes
  @discardableResult public mutating func issue(_ key: M.Key) -> Bool   // true: superseded a live generation
  public mutating func end(_ key: M.Key)
  public mutating func revoke(_ token: EndToken)
  public mutating func endAll()
  public func isLive(_ key: M.Key) -> Bool
  public func generation(of key: M.Key) -> Generation?

  // Work
  // nil: the key isn't live. Two forms, so a hold and a second deadline can't both be passed:
  @discardableResult
  public mutating func request(_ effect: M.Effect, for key: M.Key, holding: Hold<M.Key>) -> RequestID?
  @discardableResult
  public mutating func request(_ effect: M.Effect, for key: M.Key, deadline: Duration? = nil) -> RequestID?
  public mutating func cancel(_ request: RequestID)
  public mutating func run(_ effect: M.Effect)                           // untracked
  @discardableResult public mutating func queue(_ input: M.Input, behind key: M.Key) -> Bool  // false after endAll
  public mutating func timer(at instant: TurnInstant, for key: M.Key, _ input: M.Input)

  // Output and answers
  public mutating func emit(_ output: M.Output, for key: M.Key)
  public mutating func reply(to: InputID, _ result: Result<M.Reply, any Error>, after: RequestID? = nil)
  public mutating func close()
}
```

**A holding request always has a deadline, and the type says so.** The deadline is part of the `Hold` value, so `request(_, for:, holding:)` without one doesn't compile (a must-fail snippet, §6.3). **The deadline bounds the request,** not always the hold: an `.untilRequestCloses` hold ends with it, while an `.untilWorkerRetires` hold ends when its worker returns (rule 6), so the adopter bounds that worker (in slice 1, the keeper's own join and leave bounds). A request with no deadline would leave its caller and every input parked behind its key waiting for as long as the work hangs; allowing one is a design change, not an option a caller picks. Only an adopter's machine code calls `request(holding:)`: Land, resolver and handler authors never see the core, and replay makes no holding requests, so neither changes. For `.untilWorkerRetires` the deadline abandons the request (its caller is answered, `handleAbandoned` runs) while the hold stays until the worker returns.

**The instant is one concrete type,** `TurnInstant`: a `PlainData` value holding signed `Int64` nanoseconds (so `-` can give a negative `Duration`), `Comparable`, with `+ Duration` and `- TurnInstant -> Duration`. **Its origin is fixed once per process:** a `ContinuousClock.Instant` captured in a static on first use, from which every production `TurnClock` measures. So an instant a machine stored stays meaningful under a replaced core (check 14) or a second clock. A test clock starts at 0 and is never mixed with a production one.
- Rejected: `associatedtype Clock: TurnClock` on `TurnMachine`. It puts a clock type in every machine's signature and generic constraint, and buys nothing once the origin is fixed per process: a machine only compares instants and adds durations.
- **The keeper's `TickLoopClock` maps onto it later** at no cost: its `now` (a `ContinuousClock.Instant`) is the process origin plus an offset, and its `sleepUntil(_:)`, which returns early on cancellation, is the same contract as `TurnClock.sleep(until:)` below. Nothing in the keeper changes in this PR.

### 3.4 The core and the adopter

```swift
public final class TurnCore<M: TurnMachine> {    // not Sendable; stops the process for a class machine
  public init(_ machine: M, parkedLimit: Int, segmentBudget: Int, clock: some TurnClock) where M: PlainData  // no defaults
  public func read<R>(_ body: (borrowing M) -> R) -> R    // between steps only
  public var stats: TurnStats { get }            // parked, openRequests, heldKeys, liveKeys, pendingWaiters,
                                                 // droppedOutputs, ignoredAfterEnd, droppedSends, foreignCompletions,
                                                 // drainContinuations, cancelledCalls
  public var effectsByInput: [String: Int] { get }        // debug builds; empty in release (rule 20)
  package var onDiagnostic: ((TurnDiagnostic) -> Void)?  // tests and in-package adopters only
}

public protocol TurnClock: Sendable {            // injected; no default
  var now: TurnInstant { get }
  func sleep(until instant: TurnInstant) async
}

public protocol TurnActor: Actor {
  associatedtype M: TurnMachine & PlainData
  var core: TurnCore<M> { get }                  // a stored `let` (lint)
  @concurrent nonisolated func perform(_ effect: M.Effect) async -> M.Input?
  func flush(_ outputs: consuming [M.Output])    // synchronous; called between steps
}
extension TurnActor {
  public func send(_ input: M.Input)
  public func call(_ input: M.Input, cancellation: CallerCancellation) async throws -> M.Reply
  public func ask(_ query: M.Query) -> M.Answer  // synchronous; a collaborator's entry
}
```

**The clock's contract:**
- `sleep(until:)` replaces a sleep by duration, so a deadline or timer computed from one clock read doesn't drift.
- **It returns early when its task is cancelled** (the same contract as `TickLoopClock.sleepUntil`). The core cancels a deadline's or timer's task when its request closes or its timer is replaced.
- **A task that wakes re-checks before it submits:** the deadline's request must still be open and the same one, and the timer must still be the key's current one. So an early wake (cancellation), a late one, or one that races a completion can't abandon a request that already closed or fire a replaced timer. The check is in the core, by request ID and timer generation, not in the clock.
- **A `Duration` deadline becomes an instant from the segment's single clock read** (the lazy read of rule 18), so a deadline never takes a second read.
- The adapter's production clock uses `safeTaskSleep(for: until - now)`, the repository's safe sleep. It must not copy `TickLoopClock.continuous`, which calls `Task.sleep(until:clock:)`. This target can't depend on that helper, so the adopter's clock is where it comes in.

### 3.5 `PlainData`

```swift
public protocol PlainData {}
@attached(extension, conformances: PlainData, names: named(_plainDataCheck))
public macro PlainData() = #externalMacro(module: "SwiftStateTurnsMacros", type: "PlainDataMacro")
```

The macro writes the conformance and one check per stored property, which fails to compile unless the property's type is `PlainData`. It is an extension macro only: a generic type's `where T: PlainData` can constrain only an extension, so the checks go in the extension it writes (`_plainDataCheck`), not in a member. Members inside `#if` blocks are read in every clause, and their checks are written under the same conditions, so a member that only one configuration compiles is still checked there.

| Rule | Reason |
|---|---|
| Every stored property has a type annotation | A syntactic macro can't see an inferred type |
| A generic type gets `where T: PlainData` | So `Box<T>` is checked field by field |
| Each associated value of an enum is checked | Same as a stored property |
| On a class, actor or protocol: a diagnostic | Only structs and enums are plain data |
| `any P`, closures, `weak`/`unowned` are rejected | Each can call through or change behind the machine |

The core conforms the standard value types a machine stores (integers, `Bool`, `String`, `Double`, `Duration`, `Optional`, `Array`, `Dictionary`, `Set`, tuples through a wrapper where needed) and its own `InputID`, `RequestID`, `Generation` and `TurnInstant`. `EndToken` doesn't conform.

## 4. The core's rules

Each rule says what holds. A rejected alternative listed here was a real bug found in design review; don't simplify a rule back into one.

1. **A step is synchronous, and nothing enters a running step.** `handle`, `handleAbandoned`, `handleStale` and `answer` aren't `async`. A `send` or `call` made during a step or segment is queued and steps later in that segment. `read`, `ask`, or a step entered from inside a step stops the process with a message (`fatalError`, which prints in release; `precondition` doesn't).
2. **The core is a reference held in a `let`; the `Turn` points at it.** `TurnCore` is a final, non-`Sendable` class, so it can't leave the actor and `perform` can't reach it. `Turn` holds `unowned(unsafe)` to the core and changes its runtime in place; the machine and the runtime are separate stored properties, so a step has no access conflict. That reference is sound only because a handler can't make, copy or move a `Turn`: the must-fail snippets that prove it stay. Rejected: a value core in `var core` (the adopter could replace it, or copy it across an await); moving the runtime into the `Turn` and back per step (too slow).
3. **Admission.** An `external` input is refused `closed` after `close`, refused `withdrawn` if its token has ended, parks behind its hold key if that key is blocked (refused `overloaded` over the parked limit), and otherwise steps. A key is blocked while a request holds it or inputs are still parked behind it, which keeps arrival order while a released queue drains. A `control` input is never gated, parked or refused. A request's completion is neither: it's gated only by its request being open. So a stop's own drain completions survive `close`.
4. **Keys and generations; handlers hold no tickets.** `issue(key)` starts a generation and returns true when it superseded a live one, closing that generation's requests (including ones made earlier in the same step), dropping its timer and withdrawing the external inputs parked under its scope, as `end` does. A parked input carries no generation, so one sent under the old binding would otherwise step under the new one; its caller gets `withdrawn`, which it can retry, instead of a silent misapplication. Inputs parked before the key's first `issue` stay (that isn't a supersede), and so does what a step queued (`queue`). `end(key)` closes the key's requests, releases their `.untilRequestCloses` holds and withdraws parked inputs scoped to it. Work is `request(effect, for: key)`, nil when the key isn't live. Rejected: `Ticket` values handed to handlers.
5. **A request, its worker and its reply are three states.** A request closes by its completion, its key ending or being superseded, its deadline, or `cancel`. Closed without its completion, `handleAbandoned` steps in that segment. The worker's late result goes to `handleStale`, which is the signal that the worker retired. `handleStale` may `issue` (compensation needs a key). Each core has an incarnation; a completion from another core is dropped and counted.
6. **A hold belongs to its request.** It exists only as a property of an open request, or of an abandoned one whose worker hasn't retired (`.untilWorkerRetires`). Owners are counted per key; a handover is a new request taking the same hold in the step that closes the old one. A late completion can't release another owner's hold. Rejected: `hold(key)`/`release(key)`, and a separate hold ID.
7. **Parking is FIFO per hold key, bounded, budgeted and scoped.** `parkedLimit` bounds all parked inputs; a `send` over it has no caller to answer and is dropped and counted. The driver steps released inputs one at a time, never recursively, re-checking the hold before each, at most `segmentBudget` per segment; the rest step in a later segment, as the actor's own job, and the key counts as blocked until then. A parked input carries its scope; `end(scope)`, or a supersede of the scope's key (rule 4), withdraws it with `withdrawn`. An adopter that wants inputs to carry over a rebind scopes them to a longer-lived key, or to none. Withdrawn and closed callers are answered in call order.
8. **End tokens cover the end that arrives first.** The core reads an input's token on arrival and on release from parking; an ended token withdraws it. `turn.revoke(token)` marks it and withdraws the parked inputs that carry it in that step. Scope, the key and the token cover three different orders; all three are needed.
9. **`queue(input, behind:)` can't be refused.** It places the input after those already parked behind the key, or after the current step if the key isn't held. The parked limit, `close`, scope and tokens don't apply; only `endAll` drops it, and after `endAll` it returns false and is counted. The core sets no bound; the adopter does.
10. **The driver's order.** After every step, before any other: flush outputs; publish replies without `after:`; answer withdrawn callers; if `close` ran, answer parked external callers `closed`; launch effects (one task each; a deadline is a second task). Then, one step at a time, repeating the list after each: an abandoned request, a queued `send` or `call`, a released parked input within the budget. `reply(to:_:after: r)` is published when `r`'s completion step ends or `r` is abandoned. An `ask` from inside a segment (a collaborator the driver called between two steps, from `flush`) runs its answer step at once, and what that step produced leaves when the segment drains, after the `ask` returns: a second `ask` in the same collaborator steps before the first one's outputs are flushed. That is the one exception to "flushed before the next step" (invariant 11).
11. **Output is checked by key.** `emit(_, for: key)` is dropped and counted unless the key is live.
12. **Replies.** At most one per `InputID`. `close` answers parked calls only; a call that already stepped gets its real answer. The waiter table is empty when the core is destroyed (a debug assertion).
13. **Entries.** `send` steps in the caller's segment when the core is idle, queued otherwise. `call` registers its waiter and submits in one segment. `ask` runs `answer` as a step; called outside a segment, what it produced has left the core when it returns, and called from inside one, it leaves when that segment drains (rule 10). `read` borrows the machine between steps; an adopter's per-message path does one `read` per segment.
14. **`close`** closes external intake and answers parked external calls; queued inputs, completions, control inputs, `ask` and `run` still step.
15. **`endAll`** abandons every open request (`.keyEnded`; a `.untilWorkerRetires` hold stays until its worker returns), ends every key, withdraws scoped parked inputs, drops queued ones, and closes intake. Afterwards `issue` does nothing and returns false (counted), so `request` returns nil and `emit` drops; `queue` returns false; `run`, `ask`, control inputs and in-flight completions still step. A debug assertion in `request` checks that no key is live after the end.
16. **Caller cancellation is a policy per `call`, with no default.**

    | Policy | Behaviour |
    |---|---|
    | `.ignored` | No handling: the caller waits for the real result |
    | `.honoured`, external, cancelled before entry | Not submitted; `CancellationError` |
    | `.honoured`, external, still parked when the cancellation is handled | Withdrawn, never steps; `CancellationError` |
    | `.honoured`, already stepped | The caller stops waiting (`CancellationError`); the work goes on and its reply finds no waiter |
    | `.honoured`, control | Always submitted and stepped; only the caller stops waiting. Cancelled before entry, it is submitted and the caller gets `CancellationError` at once, even when the step replies at once; the reply finds no waiter |

    The cancellation is handled as its own job on the actor, so the contract is "withdrawn if still parked when the cancellation is handled". No tombstone is needed: the waiter registers in the call's entry segment.
17. **`run` and `perform`.** `perform` is `@concurrent nonisolated`, doesn't throw, and returns an optional input (nil: nothing to report; an error is a case of the input). A `run`'s result comes back as a control input. Completion order across effects isn't guaranteed; only keys and holds order work. A deadline's or a timer's task doesn't keep the actor alive (it holds it weakly), so a periodic timer doesn't outlive the actor's last owner; an effect's task does, until its result has been handled, so launched work is never dropped. A released actor's core cancels its deadline and timer tasks; a `call` still waiting then is a bug (the waiter assertion of rule 12), so an adopter ends its keys and answers its callers before it lets go.
18. **`timer(at:for:_:)`.** One outstanding fire per key; a new one replaces it. The fire arrives as a control input carrying its scheduled instant, so the handler computes the next one with skip-ahead. Ending the key drops a fire already queued. A waking timer task submits only if it is still the key's current timer (§3.4). The clock is read at most once per segment, lazily (`turn.now`, or a `Duration` deadline, reads it on first use). A replay driver arms no timer. Rejected: `every(interval)`, which builds a backlog when a step overruns.
19. **The step path is `@inlinable`,** and what it touches `@usableFromInline`, so the client specializes the driver for its machine with no build flag. A script checks that the specializations exist (§7).
20. **Nothing per message is an effect.** A debug counter of effects per input case lets an adopter's tests assert zero for its hot inputs.

## 5. Invariants

The checks in §6 and the generated-order harness (§6.4) assert these. None may happen:

1. The machine is changed outside a step.
2. A step is entered while another runs.
3. A handler awaits or starts a task.
4. A machine stores something it can call through or that can change behind it: a class, a closure, an actor, an existential, a lock, a token.
5. A result is handled by `handle` after its request closed.
6. A late completion releases another owner's hold.
7. A hold is left with no owner, or released while its owner is open (or, for `.untilWorkerRetires`, its worker unretired).
8. A parked input steps after its scope ended or its token was read as ended.
9. A parked external input steps after `close`.
10. A caller gets two replies, or none.
11. Another step runs between a step and the flush of its outputs (except after an `ask` from inside a segment, rule 10).
12. An output is delivered under a key that wasn't live at its `emit`.
13. After `endAll`: a key is issued, a request made, a keyed output emitted, or a queued input survives.
14. A queued input is refused, withdrawn or dropped by anything but `endAll`.
15. A parked input steps from inside the handler that released its hold.
16. A completion from another core is handled.
17. A timer fires for a key that ended, or two fires for one key are outstanding.

## 6. Tests

Every interleaving is ordered by an event, never by a sleep or a poll: an effect waits at a named gate in the test target (the core has no dependency on `SwiftStateTree`'s `HoldPoints`), and a check waits for the gate's or the core's event. The wall-clock lint covers the new test target.

### 6.1 Ordered checks (Swift Testing, debug and release)

| # | Shows | Rule |
|---|---|---|
| 1 | A completion after its key ended goes to `handleStale` | 5 |
| 2 | An aborted owner's late completion doesn't release the next owner's hold | 6 |
| 3 | A deadline abandons the request and releases its hold | 5, 6 |
| 4 | A `.untilWorkerRetires` hold outlives the deadline, and is released by the stale result | 6 |
| 5 | `close` answers a parked call, refuses a later one; a stepped call still gets its answer | 12, 14 |
| 6 | `emit` under an ended key is dropped and counted | 11 |
| 7 | A `send` from inside a step is queued and steps after it | 1 |
| 8 | A collaborator called between steps may `read`, `ask` and `send` | 13 |
| 9 | `call` and `reply` round-trip; `reply(after:)` waits for the request's completion step, and for its abandonment | 10, 12 |
| 10 | `cancel(request)` abandons with `.cancelled`; the late result is stale | 5 |
| 11 | Scope: a parked input is withdrawn when its scope ends; ending another key leaves it | 7 |
| 12 | The parked limit refuses with `overloaded`; a `send` over it is dropped and counted | 7 |
| 13 | 40 released inputs step in order, at most `segmentBudget` per segment; a late arrival steps after them | 7 |
| 14 | A replaced core doesn't take the old core's completion | 5 |
| 15 | A token marked before arrival withdraws; marked while parked withdraws on release; `revoke` withdraws in its step | 8 |
| 16 | `queue` steps after the inputs already parked, survives `close`, the parked limit and scope ends, and is dropped only by `endAll` | 9 |
| 17 | `endAll`: open requests abandoned, keys ended, scoped inputs withdrawn, queued dropped, intake closed; then `issue`/`queue` return false and are counted, `run` and `ask` still step | 15 |
| 18 | `endAll` with a `.untilWorkerRetires` hold: the hold outlives it, and a late deadline is ignored | 6, 15 |
| 19 | `issue` over a live generation closes requests made earlier in the same step | 4 |
| 19b | A supersede withdraws the inputs parked under the old generation's scope; one parked before the key's first `issue` stays | 4, 7 |
| 20 | Outputs flush before the next step; a step's effects launch after its flush | 10 |
| 21–25 | Cancellation, one check per row of rule 16's table | 16 |
| 25b | `.honoured`, control, cancelled before entry, whose step replies at once: stepped, and the caller gets `CancellationError` | 16 |
| 26 | Timer: fires once at its instant with that instant in the input; a new timer for the key replaces it; ending the key drops a queued fire; the clock is read at most once per segment (a counting test clock) | 18 |
| 27 | Timer skip-ahead: a step that overruns two periods schedules the next fire after now, not three fires | 18 |
| 28 | Hold handover: the step that closes a holding request makes a new one on the same key; an input parked behind the key stays parked throughout (the owner count never reaches zero), and steps when the new request closes | 6 |
| 29 | Wake re-check: a deadline task woken after its request completed abandons nothing; a timer task of a replaced timer fires nothing; a cancelled sleep submits nothing | 18, §3.4 |
| 30 | A `Duration` deadline and `turn.now` in one segment take one clock read (a counting test clock) | 18, §3.4 |
| 31 | A periodic timer doesn't keep a released actor alive; an effect in flight keeps it until its result is handled | 17 |

Check 28 asserts the plan's row: the parked input stays parked through the handover. The momentary zero owner count before the fix couldn't be observed from outside, because the release re-checks the hold before stepping a parked input, so the fix (the completion's hold kept through its step) is defensive.

### 6.1b Model checks: the membership scenarios on a model machine

These are the combinations the design closed on: a hold handed over, `queue(behind:)` on a held key, `revoke` while parked, `reply(after:)` behind a worker, and `ask` inside an admission. A core bug that only shows in them must surface here, before the core is merged, not in slice 1. They run on **models** in `SwiftStateTurnsTests`, named as models: a membership machine with connection, member and land keys; a keeper model (`player → session`, with no entry generation, destroy timer or drain); a transport model with a connection generation. Slice 1 repeats each scenario against the real adapter and keeper.

| # | Scenario on the models | Rules |
|---|---|---|
| M1 | A registration parked behind the hold, then a disconnect: withdrawn by scope | 7 |
| M2 | A refused registration withdraws a second one parked behind it | 7 |
| M3 | A disconnect during the keeper read: the request is abandoned, the hold released, the late read stale | 5, 6 |
| M4 | A refusal leaves the member's first sync running; registering the same binding doesn't move the member key; a rebind does | 4 |
| M5 | Teardown answers a reading registration and a parked one | 12, 15 |
| M6 | The end token is marked first: the registration is withdrawn, and no keeper request is made | 8 |
| M7 | The join budget: a parked admission is ended and withdrawn, with its final frame out at the answer; a started one is left alone | 8, 10 |
| M8 | The transport registration in five orders: the disconnect wins; the registration wins; mapped then disconnected; a guarded nil; a supplied generation | 4, 11 |
| M9 | A started library join, then a disconnect, in six orders: before the insert; during resolvers; after the admission; the keeper doesn't ask; a member's leave behind work in flight; a queued leave then `close` | 9, 13, 14 |
| M10 | A disconnect as a call, in six parts: nothing due; behind work in flight; a stop of three sessions; the session's own join running; teardown drops a queued leave and answers its caller; after the end | 9, 12, 15 |

With §6.1 these are the 24 ordered checks and 2 cancellation checks the design closed on, plus the checks for what it added since (timer, the clock, `reply(after:)`, `cancel(request)`, handover).

**Ordering for adopters.** A holding request can now be abandoned by its deadline, which makes the disconnect's per-worker rule reachable in an adopter. Slice 1's tests for that rule under a deadline, for a join and for a leave, must exist before the adapter relies on it. This PR covers the core side (checks 3, 4, 18 and 28).

### 6.2 Runtime stops (exit tests)

`#expect(processExitsWith: .failure)` with the message checked in the output, in debug and release: `read` from inside a step; `ask` from inside a step; a step entered from inside a step; a class as the machine. Linux runs them too.

### 6.3 Must-fail snippets

Under `scripts/must-not-compile/turns/`, each with its expected diagnostic, plus a control that compiles:
- an `await` in `handle`; a `Task {` reaching the machine from `handle`;
- a `Turn` escaped into a stored property, made with an init, copied, or consumed and used again;
- `perform` touching `core`;
- replacing `core` (`let`), and a `TurnMachine` that isn't `Sendable`;
- a holding request without a deadline (`holding: .untilRequestCloses(key)`);
- `@PlainData` on a struct with a closure, a class, an actor, an `any Error`, a class inside a dictionary, an un-annotated stored property; `@PlainData` on a class; a machine storing an `EndToken`; a closure and a class inside `#if` blocks;
- a machine without `@PlainData` that stores a class, given to `TurnCore`.

### 6.4 Generated orders

A seeded, deterministic harness: a small machine with two keys, holds, scopes, tokens, `queue`, timers and a test clock; a generator of sends, calls (with caller cancellation), completions, cancellations and clock orders; after every operation, the invariants in §5 that the machine can observe (and the core's counters) are asserted:
- 2 and 15 (no step inside a step), 5–9, 12 (the sink receives exactly the outputs emitted under a live key), 11 (a flush carries only the latest step's outputs), 13 and 17;
- 7 as FIFO order per hold key, not just counts;
- at the end, 10 (each call answered once, consistently with whether it stepped) and 14 (each queued input stepped, unless `endAll` dropped it).

Every third seed runs with a segment budget of 2, so drain continuations interleave with later operations; those keep the invariants but not one fixed schedule. Invariant 16 needs a second core, which one harness core can't produce; check 14 covers it. A failing seed is printed and kept as a fixed replay test. CI runs a fixed seed set; a longer run is a manual command.

### 6.5 The macro

Expansion tests (`assertMacroExpansion`) for each rule in §3.5, including the diagnostics.

## 7. Lints and scripts

Run in `scripts/pre-push-checks.sh` and CI, each with a self-test of a passing and a failing fixture:
- **No hand-written `PlainData` conformance** outside `Sources/SwiftStateTurns`: a `: PlainData` or `extension … PlainData` in source that isn't the macro's attribute, a protocol that refines `PlainData`, or a typealias that names it (a class could conform through either). It doesn't flag a constraint (`where T: PlainData`, `<T: PlainData>`) or the core target's own conformances.
- **`let core` in every `TurnActor`:** a type conforming to `TurnActor`, in its declaration or in an extension in any file, declares `let core` as a member of its declaration, and no `var core` member anywhere (the protocol can't require a stored `let`). A local `let core` doesn't count.
- **No task (`Task {`, `Task(…)`, `Task<…>`, `Task.init`, `Task.detached`), `nonisolated(unsafe)` or `@unchecked Sendable` in a file that declares a `TurnMachine`,** outside `Sources/SwiftStateTurns` (whose `EndToken` is `@unchecked Sendable` and whose protocol file declares `TurnMachine`).
- A declaration header that spans several lines is read as one. A deliberate site carries `// lint-allow: turns-<rule>: <reason>`: only under `Tests/`, with a reason of ten characters or more, in a file listed with its marker count (the list may only shrink).
- **No `assumeIsolated` outside named boundary files,** listed in the script with a reason each (the design's "a step doesn't call out"). It applies from this PR: the existing call sites are the initial list, and the list may only shrink.
- **`check-turns-inlinable.sh`:** a release build of `TurnsBench` must have a specialization on the bench's types of each named driver function (`TurnCore.step`, `TurnActor.runSegment`); a failed build fails the check. The negative control builds a copy of the three targets with every `@inlinable` in the core removed (internal ones become `@usableFromInline`) and requires the same check to find none of them. Run in CI on Linux.

## 8. Cost

`TurnsBench` (release) measures, against a hand-written direct baseline of the same work: an idle step, `emit` plus flush, `issue`/`end`, a held-key lookup, `read` with one lookup and with four, a park and release, a request round trip, and a `call` round trip, with `turn.now` and the timer in place.

- On the Mac it prints time and in-process instruction counts, for development only.
- The judged numbers come from the measurement host, on the pinned toolchain, under the repository's instruction gate (`Notes/plans/2026-11-13-off-path-instruction-gate.md`): `instructions:u` from `perf stat` around one bench and one side. The figure slice 1 depends on is `read`'s cost per call, which becomes its per-message budget; the PR reports it, and the A/B of slice 1 confirms it in the adapter.
- There is no base to compare against (a new target), so this PR's host run is a measurement, not an A/B: it records the numbers the later slices are judged by.

**Merge conditions** (#546's order: the core lands after its checks pass on the pinned toolchain, with instruction counts):
1. CI green on 6.2.4, debug and release, Linux;
2. the host's 6.2.4 instruction counts for every bench in this section, reported in the PR;
3. Review's GO on the code.
The host run is briefed when the code is GO, and the PR doesn't merge before it reports.

## 9. Steps and PRs

One PR, as #551 says, built in reviewable commits:
1. Package targets, values, `TurnMachine`, `Turn`, `TurnCore`, the driver; checks 1–20 and 28; the exit tests.
2. Cancellation (checks 21–25).
3. `TurnClock`, `TurnInstant`, `timer` (checks 26–27, 29–30).
4. The model checks (§6.1b).
5. The `PlainData` macro, its expansion tests, the conformances; the lints.
6. The must-fail snippets and the script extension.
7. The generated-order harness.
8. `TurnsBench` and `check-turns-inlinable.sh`; DocC. The catalog has:
   - an overview article: what a turn is (the actor-turn sense, in the first paragraph) and the rule the core enforces (state changes only in steps; effects come back as inputs);
   - a worked example article: a small machine and actor trimmed from `DemoMachine`/`DemoActor`, compiled and run as a test, with a check that the article's code matches the test file. It shows `step`, an effect, `perform`, `flush`, `send` against `call`, and a holding request with its deadline;
   - why `perform` carries both attributes: `nonisolated` keeps it off the actor's state, and `@concurrent` makes it run off the actor under 6.2's `nonisolated(nonsending)` default. One paragraph, with what goes wrong with each one alone.

   - a "How the pieces fit" section near the top, with a diagram (one hand-written SVG, shared by the DocC catalog and `docs/turns/`), naming the pattern (functional core, imperative shell);
   - a core-concepts article: each concept in the order it builds on the others, why it exists, a compiled example, the API it maps to, and a summary table; a timeline picture for a hold and for a supersede;
   - a comparison article: the lobby as a plain actor (the hazard, forced with a hold and asserted), fixed by hand with a `GenerationTable` ticket, and on the core; all three compiled as tests;
   - a "How it's tested" section that introduces representative tests as examples.

   A bilingual pair `docs/turns/README.md` and `docs/turns/README.zh-TW.md` summarizes the DocC (the maintainer asked for a Chinese version), with its excerpts under the same check. A `docs/` architecture page for the adapter comes with #546's first slice, when `TransportAdapter` adopts the core.

If Review finds the PR too large, the split is (1–4, 6's snippets for `Turn`, `perform` and the holding deadline, 7) then (5, the PlainData snippets, the lints), then (8). Each part is green on 6.2.4 in both configurations; the merge conditions (§8) apply to the last.

**#554** (the adapter's stateless encode extraction) is independent of this target and touches only `TransportAdapter`'s hot paths under the instruction gate. It can run in parallel in another session; I'd leave it there and keep this PR to the core.

## 10. The existing reentrancy helpers

`GenerationTable`, `SingleFlight` and `Lifecycle` (`Sources/SwiftStateTree/Support`) are **kept**, not wrapped and not replaced by this PR.
- **Not wrapped:** `SwiftStateTurns` depends on nothing in the package, and the helpers live in `SwiftStateTree`; wrapping would invert that.
- **Replaced inside an adopted actor, one slice at a time:** a machine has no use for them. A `GenerationTable` ticket captured before an await becomes a key's generation that the core checks (rule 4); a `SingleFlight` create-or-destroy-once becomes a request under a key with a hold (rules 4 and 6); a `Lifecycle` start/stop becomes `close` and `endAll` (rules 14 and 15). An adopted slice's legacy code, with its helper calls, is deleted before the next slice starts (#546).
- **Kept where nothing adopts the core:** the router, the host, NIO and the admin routes keep using the helpers, and the coding conventions' reentrancy rule for code outside turns stays as it is. A helper is removed only when its last call site is gone, which is a separate change after the adopters, if ever.
- The keeper keeps its own turn structure (`runInputTurn`, `runTickTurn`); whether it runs on this core is a later question (after #522), not this PR's.

## 11. Public API

All new, in a new product: everything in §3. Nothing existing changes.

## 12. Risks

- **The pinned toolchain.** `~Copyable` structs passed `inout` with generic parameters, `borrowing` closure parameters, `@concurrent`, and exit tests are all Swift 6.2 features; their diagnostics and codegen on 6.2.4 may differ from newer compilers. The must-fail snippets' expected wording is 6.2.4's. The design's ordered checks, runtime stops and compile-time rules were checked on 6.2.4 in a release build before this plan, and held; the debug build wasn't checked there (the compile ran out of memory in a 1 GB container). The PR's CI runs both configurations on 6.2.4, and the debug run is the first evidence for it.
- **Specialization across the module boundary on 6.2.4.** If `@inlinable` doesn't specialize the driver for an external machine on 6.2.4, the per-step cost rises several times. `check-turns-inlinable.sh` is the guard; the fallback is fewer generic layers on the step path, not a build flag.
- **`unowned(unsafe)` in `Turn`.** Sound only while the must-fail snippets for escaping, making and moving a `Turn` hold. If a toolchain accepts one of them, the rule is broken, not just the test.
- **CI's 6.2.4 debug build fails on memory or time.** A blocker, not a follow-up: the debug run is a merge condition. The first response is the CI job's settings (one job's parallelism) and the test target's size; if neither suffices, the fallback split of §9 lands the core first and the model checks next, each green in both configurations.
- **The `TurnInstant` choice** changes a public protocol if reversed later; settled in this review.
- **Macro and swift-syntax.** The macro builds on the package's swift-syntax pin (602.0.0 on CI's 6.2.4); no new dependency.

## 13. Not in this PR

Any adopter change (#546's slices); slice 1's tests of the disconnect's per-worker rule under a holding deadline, which must exist before the adapter relies on it (§6.1b); `PendingSet` (for the keeper, after #522), the public changes listed on #546 for slice 1 (`JoinAdmission.refused`, the required `EndToken` on `registerSession`, the `Transport` defaults), and turning caller cancellation on anywhere.
