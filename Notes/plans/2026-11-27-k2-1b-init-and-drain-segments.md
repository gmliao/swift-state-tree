# K2-1b: the initialization and the destroy drain in segments (#700)

**Status:** rev 2 (2026-11-27). Review's GO on rev 1 came with four conditions, met here: the loops before `didInitialize`, with T9; the sequence assert; the bound requester's hold, T8b; the K2-2 boundary table. Q1–Q5 are decided (§ Questions). Rev 1 quoted the probes P1–P3 (§ Probes). Line anchors are `LandKeeper.swift` (`LK:`) on main 9964d1de: `performInitialization` and `drainAfterIdleCheck` are unchanged since aced9ace, where the await survey was taken. On 7aacf129 (#931) the two functions keep their lines, and the loop configurators moved to LK:2953 and LK:4575.

**Scope:** the K2 plan's §16 item 18 (Review, 2026-11-27). Segment `performInitialization` and `drainAfterIdleCheck` the way K1b-5 segmented the join and the leave:
- each segment is a `KeeperModel` method run in one `withTurn`;
- it returns the await it needs as a request;
- the actor's driver loops over the requests.

The change ends CLAUDE.md's #522 exception for the drain's post-await bookkeeping. It adds no behavior: the init and drain suites stay green unchanged, plus a hold test per await. The PR is keeper-only, based on main, and opens after #860. K2-2's commit 0 moves the action jobs, and its later commits route both flows on the core.

## Problem

Both functions are actor code that writes keeper state across their awaits. The await survey ([2026-11-27-k2-1b-await-survey.md](2026-11-27-k2-1b-await-survey.md), at aced9ace) has the full table; it is summarized here.

**`performInitialization` (LK:1415–1631):**
- reads `isDraining` after the OnInitialize resolvers (LK:1518);
- writes the failure (`failInitialization`) and the state (the `withTurn` at LK:1538) in the segment after them;
- reads `isDraining` after the record's await (LK:1598).

`didInitialize` is written by the caller after `await task.value` (LK:1265), outside any turn.

**`drainAfterIdleCheck` (LK:4776–4856):**
- writes `dropPendingInputs` and `destroyHandlersStarted` after `waitForTickInFlight` (LK:4791–4792);
- writes the state after each destroy resolver group (`runDestroyHandler`, LK:4911);
- writes `destructionFinished`, the bound requester, `releasedTransport` and the transport after `onLandDestroyed` (`notifyTransportDestroyedAndRelease`, LK:4862–4868). These last writes are #522's exception.

None of these is a bug today. The no-ticket argument (LK:4809–4812, :4875–4877) holds: intake is closed, no tick starts, and nothing is pending. Initialization's waiters are parked on `initializationTask`. But each of them is a write that only prose protects, and K2-2 can't route a flow that isn't in segments.

## Design

### Initialization

The driver becomes `performInitialization()`:

```text
var request = withTurn { m, side, outputs in m.initializeBegin(behavior, &side, &outputs, checks) }
loop:
  .replayHeader(source)      → legacy replay part, unchanged (see "Replay" below) → withTurn initializeAfterReplay
  .runResolvers(r)           → await executeInitializeResolvers → withTurn initializeResolved(r, result)
  .submitRecord(record)      → await submitTurnRecord(record) → withTurn initializeRecorded
  .startLoops(tick, sync)    → configureTickLoop / configureSyncLoop (sync, no await) → withTurn initializeDone → return
  .failed                    → return (the teardown Task was staged by the segment)
  .done                      → return
```

| Segment | Does, in one turn | Replaces |
|---|---|---|
| `initializeBegin` | the registration checks (pure reads, LK:1422–1439); on a problem, `fail` (below). Re-evaluation: `.replayHeader`. Live with OnInitialize: takes the sequence, builds `ctx` (LK:1481–1488) and the executors from `model.state` (LK:1493), and records `sequence.next` after the take in the request (`sequenceAfterTake`). With executors, `.runResolvers`; without, it applies in this segment, as `initializeResolved` does | LK:1415–1494 |
| `initializeResolved(r, result)` | first, `assert(sequence.next == r.sequenceAfterTake)`: nothing but this initialization took a number during the resolvers (the survey's open point 3). It holds by the code: every intake entry awaits `ensureInitialized` before it takes one (`join`, `leave`, `submit`, `handleClientEvent`, `submitServerInput`), and the loops aren't configured yet. Then the timeout and `.failLand` handling (LK:1504–1528), reading `side.isDraining` in this segment; then `initializeTurnBody` (LK:1538), unchanged; on `.failure`, `fail`. With a recorder, `.submitRecord`; else `initializeFinish` | LK:1503–1556 |
| `initializeRecorded` | `initializeFinish` | LK:1598's check after the record |
| `initializeFinish` | `guard autoStartLoops, !side.isDraining` → `.startLoops(intervals)`; else `initializeDone` in this segment, then `.done` | LK:1598–1630 |
| `initializeDone(loopsConfigured:)` | first, on a tick land, `assert(!autoStartLoops \|\| side.isDraining \|\| loopsConfigured)`; the driver passes `tickLoopConfiguredAt != nil`, an actor field the model can't read. Then `didInitialize = true` and the watchers' resume (`resumeInitializationWaitWatchers`). It runs after the driver configured the loops, so "loops configured, then `didInitialize`" holds as today (Q2; T9) | LK:1265–1266 |
| `fail(error)` (helper) | `failInitialization` (`recordFailure`, `initializationFailure`), `didInitialize = true`, and stages the teardown task in `outputs`, as `scheduleDestroyIfNeeded` stages its timer (LK:6062) | the five `failInitialization` + `Task { … }` exits |

Deletions:
- **The dead record branch (LK:1582–1591)**, the legacy `recorder.record` / `recordTick`. The block runs only when `mode == .live` (LK:1480), and `routesThroughTurn` is `config.mode == .live` (KeeperModel.swift:241), so the `else` is never taken. Probe P2.
- **`async` on `configureTickLoop` and `configureSyncLoop`** (LK:2988, :4610). Their bodies have no await outside the Task each creates, so they are not suspensions; P1. They stay actor methods: `tickTask` and `syncTask` are actor fields until K2-2's core timers.

**Replay (I1–I3).** `getMetadata`, `payloadDecoders.check` and `replayInitializeBeforeTickZero` stay on the legacy replay path, named in #612's exception. Replay's tick is non-turn until #612 anyway. One change: the write of `replayHeaderPayloadEncoding` (LK:1464) and the failure exit (LK:1470) move into `initializeAfterReplay`'s segment, which costs nothing. The getters stay awaited in the driver.

### Destroy drain

The driver becomes `drainAfterIdleCheck()`:

```text
await holds.at(.drainStart)
cancel the loops (actor fields, as today)
var request = withTurn { m, side, outputs in m.drainBegin(behavior, &side, &outputs) }
loop:
  .waitForTick               → await waitForTickInFlight → withTurn drainAfterTicks
  .runDestroyResolvers(d)    → await executeResolversWithoutDeadline → withTurn destroyHandlerResolved(d, result)
  .runAfterFinalize(a)       → open scope; await afterFinalize(snapshot, scoped); scope.close() → withTurn drainAfterFinalize
  .notifyTransport(port)     → await port?.onLandDestroyed() → withTurn drainFinished; setTransport(nil)
```

| Segment | Does, in one turn | Replaces |
|---|---|---|
| `drainBegin` | `side.cancelDestroy()`; with `ticksInFlight > 0`, `.waitForTick`; else `drainAfterTicks` | LK:4785–4788 |
| `drainAfterTicks` | `dropPendingInputs(…, "drain")`, `destroyHandlersStarted = true`; with an initialization failure, or not live, `.notifyTransport`; else `nextDestroyStep(after: nil)` | LK:4791–4807 |
| `nextDestroyStep(after:)` (helper) | the next of OnDestroyWhenEmpty, OnFinalize, AfterFinalize that the land declares. A handler with resolvers gives `.runDestroyResolvers`, built from `state` (LK:4892). One without them applies in this segment and moves on. AfterFinalize gives `.runAfterFinalize(snapshot)`. Then `.notifyTransport` | LK:4817–4849 |
| `destroyHandlerResolved(d, result)` | on failure, the log and skip (LK:4901–4906); else the handler (`withHandlerStep(…, dropsOutputs: true)`, LK:4911); then `nextDestroyStep(after: d)` | `runDestroyHandler`'s tail |
| `drainAfterFinalize` | `.notifyTransport` | LK:4855 |
| `drainFinished` | `destructionFinished = true`, `releasedTransport`, and the bound requester's `object = nil` | LK:4865–4867: **#522's exception** |

Each segment after `drainAfterTicks` asserts the no-ticket argument instead of stating it in prose: `side.isDraining`, `ticksInFlight == 0`, `pendingItems.isEmpty` (`assert`, debug only).

**`setTransport(nil)`** stays a call right after `drainFinished`'s turn, at depth 0 with no await between. The sentinel refuses it from inside a body (LK:556). Until K2-2's commit 3 (the binding as a step), a core-driven drain's driver makes that call too (Q1).

**Re-entry during `onLandDestroyed`.** A `setTransport(X)` that lands in the await attaches X, since `destructionFinished` is still false. `drainFinished` and `setTransport(nil)` then replace it with `releasedTransport`, as today: destruction wins, unconditionally. That is the current behavior, kept, and T8 pins it.

**The drain's `drainRandom`** (LK:4817) is created in `drainAfterTicks` and carried in the requests, so the three handlers continue one sequence as today.

## Holds and tests

Every new test parks the keeper at one await. While it is parked, a re-entrant call (a read, or an intake that must be refused) checks the state its segment left. It then releases, and the end state equals today's. Most holds are gates in test code, so the plan adds **no `LandKeeperHoldPoint` case** (the survey allowed two; Q3).

| # | Await | Hold | At the hold, the re-entrant call sees |
|---|---|---|---|
| T1 | OnInitialize resolvers | gated resolver | `currentState()` is the initial state; `didInitialize` is false; a join waits (`waitForInitializationWaitersForTesting(1)`). After release, OnInitialize is applied and the join completes |
| T2 | the record (`submitTurnRecord`) | existing `.turnRecord` | OnInitialize applied; `didInitialize` false; no tick loop yet (`tickLoopConfiguredAt == nil`). After release, the loop is configured |
| T2b | the record, with a drain begun at the hold (a `failLandForTesting` at `.turnRecord`) | existing `.turnRecord` | after release, no loop is configured (`tickLoopConfiguredAt == nil`). No suite covers this today (grep: no drain-during-initialization test) |
| T3 | OnInitialize resolvers, `.failLand`, a throwing gate | gated resolver | before release, nothing failed. After it, `initializationFailure` is set and the waiting join gets `landShuttingDown`, as in `InitializeResolverFailureTests` |
| T4 | `waitForTickInFlight` | a gated tick handler | `isDraining`; loops cancelled; a submitted action is refused `landClosed`; pending inputs not yet dropped. After release they are dropped, then the handlers run |
| T5 | OnDestroyWhenEmpty resolvers | gated resolver | `destroyHandlersStarted`; `pendingItems` empty; the state before the handler |
| T6 | OnFinalize resolvers | gated resolver | OnDestroyWhenEmpty's write applied, OnFinalize's not |
| T7 | AfterFinalize | gated handler | OnFinalize's write applied; `destructionFinished` false; the transport still attached |
| T8 | `onLandDestroyed` | a gated test transport | `destructionFinished` false. A `setTransport(X)` at the hold attaches X. After release, `destructionFinished` is true and the transport is the released stand-in: X is never told the land was destroyed (#698's second window) |
| T8b | `onLandDestroyed` of a bound requester, on a keeper with no transport (`boundSyncRequester`, D2/D6) | a gated test port, bound by its sync request and never attached (KeeperTurnSkeletonTests' bound-port pattern, its :380) | `destructionFinished` false; the bound requester still set. After release, `destructionFinished` is true and the requester is cleared (`boundRequester.object == nil`) |
| T9 | the order of the loops and `didInitialize` | an initialization waiter (`waitForInitializationWaitersForTesting`) on an `autoStartLoops` tick land with a recorder | the waiter, resumed by `initializeDone`, sees `tickLoopConfiguredAt != nil`; and a join that calls `ensureInitialized` right after it takes the `didInitialize` fast path on a land whose loop is configured |

T1–T3 run on tick and tickless lands. T4 and T9 need a tick land. T5–T8b run on a live land, plus one replay row for T8, where a re-evaluation keeper skips the handlers (#826). The gates use `KeyedGates` with a fresh key range (`firstKey: 12_000`).

**Suites that must stay green unchanged** (from the survey):
- InitializeTwoStageTests, InitializeResolverFailureTests, ResolverDeadlineTests, ResolverValueTests, ResolverOutputReplayTests;
- LandManagerFailedInitializationTests, SyncStreamInitializeRecordTests, LandLifecycleLogTests;
- DrainTurnTests, ShutdownTurnTests, GracefulShutdownTests, LandManagerSingleFlightTests;
- AfterFinalizeRaceTests, ReevaluationDrainTests, LandReleaseTests, LandRandomStepTests, StepScopeTests;
- KeeperCensusTests;
- the replay suites (RecordPayloadFormatTests, ReplayJSONAllowanceKeeperTests, SyncOutputGoldenTests, TicklessReplayPassTests).

**Failing first:** T1–T8 pin today's behavior, so they pass before and after. That's the point of a no-behavior-change PR. What proves they bite are the mutants.

## Mutants (cloud, after the push)

| # | Mutant | Must fail |
|---|---|---|
| 1 | `didInitialize = true` moved into `initializeResolved` (before the record) | T2 |
| 2 | `dropPendingInputs` moved into `drainBegin` (before the tick wait) | T4 |
| 3 | `destructionFinished = true` moved before the `onLandDestroyed` await | T7, T8 |
| 4 | OnFinalize's resolvers built in `drainAfterTicks` (before OnDestroyWhenEmpty's write) | T6 (its resolver sees the state before OnDestroyWhenEmpty: assert on a value it reads) |
| 5 | `fail` doesn't stage the teardown task | T3, LandManagerFailedInitializationTests |
| 6 | the `!isDraining` check in `initializeFinish` removed | T2b |
| 7 | the driver runs `initializeDone` before the loop configuration (the two swapped), so `didInitialize` is true with no loop | `initializeDone`'s assert, deterministically, on every run. T9 sees the order only through timing. Rev 2's form of this mutant (the write in `initializeFinish`, a `Task.yield()` before the loops) still reaches `initializeDone` after the configuration, so the assert can't catch it; the swap is the shape the assert pins |
| 8 | `boundRequester.object = nil` moved before the `onLandDestroyed` await | T8b |

## Probes

| # | Question | Probe | Result |
|---|---|---|---|
| P1 | `configureTickLoop`/`configureSyncLoop` don't suspend | drop `async` from both and build: it compiles only if no await is left outside their Tasks | builds |
| P2 | the legacy record branch is dead | a stderr marker in the `else` (LK:1582), then the full suite. It must not fire (a marker, not `assertionFailure`, so a hit doesn't stop the run) | 0 hits |
| P3 | Q2: setting `didInitialize` in the last segment instead of after `task.value` changes nothing a caller can see | set it in `performInitialization` (a `defer`, every exit), remove `ensureInitialized`'s write after `await task.value`, with a stderr marker there if the flag isn't set; then the full suite | 0 hits, suite green |
| P4 | `setTransport` can't run inside a body | none: the guard is at LK:556 (`sentinel.bodyDepth == 0`, else `noteReentry`) | — |
| P5 | a `TurnOutputs`-staged `Task` starts after the segment, as the inline `Task {}` did | none: `scheduleDestroyIfNeeded` already stages a Task the same way (LK:6062–6075), and the teardown is keeper-isolated either way (LK:1336) | — |

### Results (2026-11-27, macOS, debug, Swift 6.4.2, on main 7aacf129 plus the probe diff)

All three probes ran in one build. Each marks its point with a line to stderr. Then the full `swift test`, debug, ran:

```text
build=0
✔ Test run with 233 tests in 20 suites passed after 0.471 seconds.
✔ Test run with 53 tests in 3 suites passed after 35.025 seconds.
✔ Test run with 1050 tests in 148 suites passed after 10.373 seconds.
━ Test run with 1334 tests in 160 suites passed after 10.203 seconds with 6 known issues.
✔ Test run with 393 tests in 61 suites passed after 2.889 seconds.
✔ Test run with 84 tests in 12 suites passed after 3.869 seconds.
✔ Test run with 146 tests in 2 suites passed after 0.005 seconds.
P2 hits: 0
P3 hits: 0
```

- **P1:** `async` was removed from `configureTickLoop` and `configureSyncLoop`, and the `await` from their only two call sites (LK:1606, :1629). It builds (`build=0`) with no new diagnostic, so neither has a suspension outside the Task it creates.
- **P2:** a stderr marker (`PROBE-K21B-P2`) sat as the first statement of the legacy record branch (LK:1582). In the full suite it fired 0 times, the init and record suites included. The branch is dead in the tests, as the static argument says (LK:1480 runs the block only when `mode == .live`, and `routesThroughTurn` is `config.mode == .live`). The deletion rests on the static argument; P2 only confirms that no test reaches the branch.
- **P3:** `didInitialize = true` moved into `performInitialization` as a `defer`, set at the end of its last segment on every exit, the five failure exits included. `ensureInitialized`'s own write after `await task.value` was removed, with a marker if the flag wasn't set by then. The suite passed with the marker firing 0 times, InitializeTwoStageTests (`waitForInitializationWaitersForTesting`), InitializeResolverFailureTests and LandManagerFailedInitializationTests included. One difference a test could see remains, and no suite pins it: a caller that runs between the init Task's end and the first caller's resume now returns at the `didInitialize` check, where today it goes through `noteInitializationWait()` (`initializationWaits` + 1). That is a test-only counter, and Q2 accepts it.

The probe diff is [2026-11-27-k2-1b-probes.diff](2026-11-27-k2-1b-probes.diff); the code PR implements each point properly.

## Questions

| # | Question | Recommended |
|---|---|---|
All five were decided by Review on rev 1 (2026-11-27).

| # | Question | Decided |
|---|---|---|
| Q1 | Keep `setTransport(nil)` as a depth-0 call after `drainFinished`, or move its body into a side helper callable in the turn? | keep. Until K2-2's commit 3 (the binding as a step), a core-driven drain's driver makes that call |
| Q2 | Move `didInitialize = true` into the last init segment (and `fail`)? | yes, in `initializeDone`, after the loops are configured (condition 1; T9). P3: the suite is green with the caller's write removed. The one difference is `initializationWaits` for a caller in the window after the Task's end, a test-only counter |
| Q3 | Gates instead of new `LandKeeperHoldPoint` cases | gates: every await here runs test-controllable code, except `submitTurnRecord`, which already holds at `.turnRecord`, and `waitForTickInFlight`, which a gated tick holds. The bound requester's `onLandDestroyed` is held by a gated test port (T8b) |
| Q4 | The replay header (I1–I3) stays legacy until #612 | yes; only its one write moves into a segment. The K2-1b code PR names I1–I3 under CLAUDE.md's "re-evaluation keepers keep their non-turn replay path until #612" sentence |
| Q5 | CLAUDE.md's sentence "The land-stop drain's post-await bookkeeping is a further exception until #522 moves it into a turn" | the K2-1b code PR deletes it. #522 stays open for its other paths (join and leave resolvers, freeze settle, the legacy tick, the monitor land) |

## The boundary with K2-2

What each request this plan creates becomes when K2-2 (#700, the K2 plan's PR K2-2) drives these flows on the turn core. On the core, a step can't await: each await is an effect, and its result comes back as an input whose step runs the next segment. A call staged through the keeper (`outputs.stage { … }` reaching an actor method or field) is an owner call. On a core whose `keeperReference` is empty, an owner call is a no-op (#938 r1 MF4, r2). So each one needs a named home.

| Request or staged call | Today's await or call | On the core | Result input |
|---|---|---|---|
| `.replayHeader(source)` (re-evaluation) | `getMetadata`, `payloadDecoders.check`, `replayInitializeBeforeTickZero` | none: re-evaluation keepers keep the non-turn path until #612, and K2-2 doesn't route it | `initializeAfterReplay` (legacy driver only; outside the routed subset) |
| `.runResolvers(r)` | `executeInitializeResolvers` | the resolver effect | `initializeResolved` (already in `KeeperInputRoutes.deferred`) |
| `.submitRecord(record)` | `submitTurnRecord` | the record effect | **`initializeRecorded`** (new) |
| `.startLoops(tick, sync)` | `configureTickLoop`, `configureSyncLoop` (sync after P1) | an **owner call**: it writes the actor fields `tickTask` and `syncTask`. K2-2 keeps it as the owner's call after the step, until the core's timers (#762) replace the loops | **`initializeDone`** (new; no await before it) |
| `fail(error)`'s staged teardown | `Task { tearDownAfterFailedInitialization() }` (LK:1336) | an **owner call** (a Task through the keeper). K2-2 makes it an effect, or keeps it as the owner's call after the step; either way it must not be dropped (mutant 5 and LandManagerFailedInitializationTests pin it) | none: the teardown starts its own leave and drain flows |
| `.waitForTick` | `waitForTickInFlight` | a barrier. On a land with a recorder, K2-2 keeps `ticksInFlight` and the work count until the record's `.recordTaken` (the K2 plan's note "For K2-2", #938). So the drain can't take its pending inputs when the tick's step ends, only once `.recordTaken` has run. Without a recorder, the tick's step ends the hold | **`drainAfterTicks`** (new): a barrier the `.recordTaken` step answers, or a drain start deferred until it |
| `.runDestroyResolvers(d)` | `executeResolversWithoutDeadline` | the resolver effect | `destroyHandlerResolved` (already in `deferred`) |
| `.runAfterFinalize(snapshot)` | the land's AfterFinalize handler | an effect: the handler runs off the core with the snapshot, in its scope | **`drainAfterFinalize`** (new) |
| `.notifyTransport(port)` | `port?.onLandDestroyed()` (transport, or the bound requester) | the port effect | `drainFinished` (already in `deferred`); then `setTransport(nil)`, the driver's owner call until K2-2's commit 3 (Q1) |

So K2-2's "routed subset total" check gains four result inputs, beside the three already in `deferred`:
- `initializeRecorded`;
- `initializeDone`;
- `drainAfterTicks`;
- `drainAfterFinalize`.

It also gains two owner calls that need a home: `.startLoops` and `fail`'s teardown. `initializeAfterReplay` stays outside the routed subset until #612.

## Order of work

1. The deletions first: `async` off `configureTickLoop` and `configureSyncLoop`, and the dead record branch (P1, P2). With them in, no later commit can suspend between `didInitialize` and the loops (condition 1).
2. The tests T1–T9 (T8b included) against that commit: green, since they pin today's behavior.
3. The init segments, then the drain segments: one commit each, each green on T1–T9 and the listed suites.
4. CLAUDE.md: Q5's sentence deleted, and I1–I3 named under the #612 sentence (Q4). `Notes/plans/README.md`'s row.
5. Full debug test, pre-push, push. Mutants to the cloud.

The nit on T8 (a `setTransport(X)` during `onLandDestroyed` is replaced, and X never hears that the land was destroyed) is a second window of #698 (a rebind during teardown), added there. K2-1b keeps today's behavior; #698's fix changes T8's expectation.
