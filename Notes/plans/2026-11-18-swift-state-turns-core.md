# SwiftStateTurns: the turn core target (#551)

**Status:** open. Plan for review before any code. Part of #546; milestone "Turn core (SwiftStateTurns)".

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
public enum Hold<Key: Hashable & Sendable>: Sendable {
  case untilRequestCloses(Key)
  case untilWorkerRetires(Key)
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
  @discardableResult
  public mutating func request(_ effect: M.Effect, for key: M.Key,
                               holding: Hold<M.Key>? = nil, deadline: Duration? = nil) -> RequestID?  // nil: key not live
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

**The instant is one concrete type,** `TurnInstant` (a `PlainData` value of nanoseconds since the clock's own origin, `Comparable`, with `+ Duration` and `- TurnInstant -> Duration`). The alternative, `associatedtype Clock: TurnClock` on `TurnMachine`, puts a clock type in every machine's signature and every generic constraint for no gain: the machine only compares instants and adds durations, and the injected clock decides the origin. Review: object here if you'd rather have the associated type, since it changes a public protocol.

### 3.4 The core and the adopter

```swift
public final class TurnCore<M: TurnMachine> {    // not Sendable; stops the process for a class machine
  public init(_ machine: M, parkedLimit: Int, segmentBudget: Int, clock: some TurnClock)  // no defaults
  public func read<R>(_ body: (borrowing M) -> R) -> R    // between steps only
  public var stats: TurnStats { get }            // parked, openRequests, heldKeys, liveKeys, pendingWaiters,
                                                 // droppedOutputs, ignoredAfterEnd, droppedSends, foreignCompletions
}

public protocol TurnClock: Sendable {            // injected; no default
  var now: TurnInstant { get }
  func sleep(until instant: TurnInstant) async
}

public protocol TurnActor: Actor {
  associatedtype M: TurnMachine
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

`sleep(until:)` replaces a sleep by duration so a deadline or timer computed from one clock read doesn't drift. The adapter's clock wraps `safeTaskSleep`; this target can't depend on that helper, so the clock is where it comes in.

### 3.5 `PlainData`

```swift
public protocol PlainData {}
@attached(extension, conformances: PlainData, names: arbitrary)
@attached(member, names: named(_plainDataCheck))
public macro PlainData() = #externalMacro(module: "SwiftStateTurnsMacros", type: "PlainDataMacro")
```

The macro writes the conformance and one check per stored property, which fails to compile unless the property's type is `PlainData`.

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
4. **Keys and generations; handlers hold no tickets.** `issue(key)` starts a generation and returns true when it superseded a live one, closing that generation's requests, including ones made earlier in the same step. `end(key)` closes the key's requests, releases their `.untilRequestCloses` holds and withdraws parked inputs scoped to it. Work is `request(effect, for: key)`, nil when the key isn't live. Rejected: `Ticket` values handed to handlers.
5. **A request, its worker and its reply are three states.** A request closes by its completion, its key ending or being superseded, its deadline, or `cancel`. Closed without its completion, `handleAbandoned` steps in that segment. The worker's late result goes to `handleStale`, which is the signal that the worker retired. `handleStale` may `issue` (compensation needs a key). Each core has an incarnation; a completion from another core is dropped and counted.
6. **A hold belongs to its request.** It exists only as a property of an open request, or of an abandoned one whose worker hasn't retired (`.untilWorkerRetires`). Owners are counted per key; a handover is a new request taking the same hold in the step that closes the old one. A late completion can't release another owner's hold. Rejected: `hold(key)`/`release(key)`, and a separate hold ID.
7. **Parking is FIFO per hold key, bounded, budgeted and scoped.** `parkedLimit` bounds all parked inputs; a `send` over it has no caller to answer and is dropped and counted. The driver steps released inputs one at a time, never recursively, re-checking the hold before each, at most `segmentBudget` per segment; the rest step in a later segment, as the actor's own job, and the key counts as blocked until then. A parked input carries its scope; `end(scope)` withdraws it with `withdrawn`.
8. **End tokens cover the end that arrives first.** The core reads an input's token on arrival and on release from parking; an ended token withdraws it. `turn.revoke(token)` marks it and withdraws the parked inputs that carry it in that step. Scope, the key and the token cover three different orders; all three are needed.
9. **`queue(input, behind:)` can't be refused.** It places the input after those already parked behind the key, or after the current step if the key isn't held. The parked limit, `close`, scope and tokens don't apply; only `endAll` drops it, and after `endAll` it returns false and is counted. The core sets no bound; the adopter does.
10. **The driver's order.** After every step, before any other: flush outputs; publish replies without `after:`; answer withdrawn callers; if `close` ran, answer parked external callers `closed`; launch effects (one task each; a deadline is a second task). Then, one step at a time, repeating the list after each: an abandoned request, a queued `send` or `call`, a released parked input within the budget. `reply(to:_:after: r)` is published when `r`'s completion step ends or `r` is abandoned.
11. **Output is checked by key.** `emit(_, for: key)` is dropped and counted unless the key is live.
12. **Replies.** At most one per `InputID`. `close` answers parked calls only; a call that already stepped gets its real answer. The waiter table is empty when the core is destroyed (a debug assertion).
13. **Entries.** `send` steps in the caller's segment when the core is idle, queued otherwise. `call` registers its waiter and submits in one segment. `ask` runs `answer` as a step; called outside a segment, what it produced has left the core when it returns. `read` borrows the machine between steps; an adopter's per-message path does one `read` per segment.
14. **`close`** closes external intake and answers parked external calls; queued inputs, completions, control inputs, `ask` and `run` still step.
15. **`endAll`** abandons every open request (`.keyEnded`; a `.untilWorkerRetires` hold stays until its worker returns), ends every key, withdraws scoped parked inputs, drops queued ones, and closes intake. Afterwards `issue` does nothing and returns false (counted), so `request` returns nil and `emit` drops; `queue` returns false; `run`, `ask`, control inputs and in-flight completions still step. A debug assertion in `request` checks that no key is live after the end.
16. **Caller cancellation is a policy per `call`, with no default.**

    | Policy | Behaviour |
    |---|---|
    | `.ignored` | No handling: the caller waits for the real result |
    | `.honoured`, external, cancelled before entry | Not submitted; `CancellationError` |
    | `.honoured`, external, still parked when the cancellation is handled | Withdrawn, never steps; `CancellationError` |
    | `.honoured`, already stepped | The caller stops waiting (`CancellationError`); the work goes on and its reply finds no waiter |
    | `.honoured`, control | Always submitted and stepped; only the caller stops waiting |

    The cancellation is handled as its own job on the actor, so the contract is "withdrawn if still parked when the cancellation is handled". No tombstone is needed: the waiter registers in the call's entry segment.
17. **`run` and `perform`.** `perform` is `@concurrent nonisolated`, doesn't throw, and returns an optional input (nil: nothing to report; an error is a case of the input). A `run`'s result comes back as a control input. Completion order across effects isn't guaranteed; only keys and holds order work.
18. **`timer(at:for:_:)`.** One outstanding fire per key; a new one replaces it. The fire arrives as a control input carrying its scheduled instant, so the handler computes the next one with skip-ahead. Ending the key drops a fire already queued. The clock is read at most once per segment, lazily (`turn.now` reads it on first use). A replay driver arms no timer. Rejected: `every(interval)`, which builds a backlog when a step overruns.
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
11. Another step runs between a step and the flush of its outputs.
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
| 20 | Outputs flush before the next step; a step's effects launch after its flush | 10 |
| 21–25 | Cancellation, one check per row of rule 16's table | 16 |
| 26 | Timer: fires once at its instant with that instant in the input; a new timer for the key replaces it; ending the key drops a queued fire; the clock is read at most once per segment (a counting test clock) | 18 |
| 27 | Timer skip-ahead: a step that overruns two periods schedules the next fire after now, not three fires | 18 |

The membership scenarios (a registration and a disconnect in each order, the library join, the disconnect answered after its leave, teardown) are the adopter's tests, against the real adapter and keeper, in slice 1.

### 6.2 Runtime stops (exit tests)

`#expect(processExitsWith: .failure)` with the message checked in the output, in debug and release: `read` from inside a step; `ask` from inside a step; a step entered from inside a step; a class as the machine. Linux runs them too.

### 6.3 Must-fail snippets

Under `scripts/must-not-compile/turns/`, each with its expected diagnostic, plus a control that compiles:
- an `await` in `handle`; a `Task {` reaching the machine from `handle`;
- a `Turn` escaped into a stored property, made with an init, copied, or consumed and used again;
- `perform` touching `core`;
- replacing `core` (`let`), and a `TurnMachine` that isn't `Sendable`;
- `@PlainData` on a struct with a closure, a class, an actor, an `any Error`, a class inside a dictionary, an un-annotated stored property; `@PlainData` on a class; a machine storing an `EndToken`.

### 6.4 Generated orders

A seeded, deterministic harness: a small machine with two keys, holds, scopes, tokens, `queue`, timers and a test clock; a generator of input, completion, cancellation and clock orders; after every segment, the invariants in §5 that the machine can observe (and the core's counters) are asserted. A failing seed is printed and replayed by a test with that seed. CI runs a fixed seed set; a longer run is a manual command.

### 6.5 The macro

Expansion tests (`assertMacroExpansion`) for each rule in §3.5, including the diagnostics.

## 7. Lints and scripts

Run in `scripts/pre-push-checks.sh` and CI, each with a self-test of a passing and a failing fixture:
- **No hand-written `PlainData` conformance** outside `Sources/SwiftStateTurns`: a `: PlainData` or `extension … PlainData` in source that isn't the macro's attribute.
- **`let core` in every `TurnActor`:** a type conforming to `TurnActor` declares `let core`, never `var` or a computed property (the protocol can't require a stored `let`).
- **No `Task {`, `nonisolated(unsafe)` or `@unchecked Sendable` in a file that declares a `TurnMachine`.**
- **`check-turns-inlinable.sh`:** two release builds of `TurnsBench`, one with the step path's `@inlinable` attributes stripped by a build define; it fails if the specialized symbols are missing from the normal build. Run in CI on Linux.

## 8. Cost

`TurnsBench` (release) measures, against a hand-written direct baseline of the same work: an idle step, `emit` plus flush, `issue`/`end`, a held-key lookup, `read` with one lookup and with four, a park and release, a request round trip, and a `call` round trip, with `turn.now` and the timer in place.

- On the Mac it prints time and in-process instruction counts, for development only.
- The judged numbers come from the measurement host, on the pinned toolchain, under the repository's instruction gate (`Notes/plans/2026-11-13-off-path-instruction-gate.md`): `instructions:u` from `perf stat` around one bench and one side. The figure slice 1 depends on is `read`'s cost per call, which becomes its per-message budget; the PR reports it, and the A/B of slice 1 confirms it in the adapter.
- There is no base to compare against (a new target), so this PR's host run is a measurement, not an A/B: it records the numbers the later slices are judged by. Main briefs it after Review's GO.

## 9. Steps and PRs

One PR, as #551 says, built in reviewable commits:
1. Package targets, values, `TurnMachine`, `Turn`, `TurnCore`, the driver; checks 1–20; the exit tests.
2. Cancellation (checks 21–25).
3. `TurnClock`, `TurnInstant`, `timer` (checks 26–27).
4. The `PlainData` macro, its expansion tests, the conformances; the lints.
5. The must-fail snippets and the script extension.
6. The generated-order harness.
7. `TurnsBench` and `check-turns-inlinable.sh`; DocC.

If Review finds the PR too large, the split is (1–3, 5's snippets for `Turn` and `perform`, 6) then (4, the PlainData snippets, the lints), then (7).

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
- **The `TurnInstant` choice** changes a public protocol if reversed later; decided in this review.
- **Macro and swift-syntax.** The macro builds on the package's swift-syntax pin (602.0.0 on CI's 6.2.4); no new dependency.

## 13. Not in this PR

Any adopter change (#546's slices), `PendingSet` (for the keeper, after #522), the public changes listed on #546 for slice 1 (`JoinAdmission.refused`, the required `EndToken` on `registerSession`, the `Transport` defaults), and turning caller cancellation on anywhere.
