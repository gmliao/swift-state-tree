# K2-1b: the initialization and the destroy drain in segments (#700)

**Status:** draft rev 1 (2026-11-27), not reviewed. Rev 1 quotes the probes P1–P3 (§ Probes). Line anchors are `LandKeeper.swift` (`LK:`) on main 9964d1de: `performInitialization` and `drainAfterIdleCheck` are unchanged since aced9ace, where the await survey was taken. On 7aacf129 (#931) the two functions keep their lines, and the loop configurators moved to LK:2953 and LK:4575.

**Scope:** the K2 plan's §16 item 18 (Review, 2026-11-27). Segment `performInitialization` and `drainAfterIdleCheck` the way K1b-5 segmented the join and the leave:
- each segment is a `KeeperModel` method run in one `withTurn`;
- it returns the await it needs as a request;
- the actor's driver loops over the requests.

The change ends CLAUDE.md's #522 exception for the drain's post-await bookkeeping. It adds no behavior: the init and drain suites stay green unchanged, plus a hold test per await. The PR is keeper-only, based on main, and opens after #860. K2-2's commit 1 routes both flows on the core, with the jobs.

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
  .startLoops(tick, sync)    → configureTickLoop / configureSyncLoop (sync, no await) → return
  .failed                    → return (the teardown Task was staged by the segment)
  .done                      → return
```

| Segment | Does, in one turn | Replaces |
|---|---|---|
| `initializeBegin` | the registration checks (pure reads, LK:1422–1439); on a problem, `fail` (below). Re-evaluation: `.replayHeader`. Live with OnInitialize: takes the sequence and builds `ctx` (LK:1481–1488), and the executors from `model.state` (LK:1493). With executors, `.runResolvers`; without, it applies in this segment, as `initializeResolved` does | LK:1415–1494 |
| `initializeResolved(r, result)` | timeout and `.failLand` handling (LK:1504–1528), reading `side.isDraining` in this segment; then `initializeTurnBody` (LK:1538), unchanged; on `.failure`, `fail`. With a recorder, `.submitRecord`; else `initializeFinish` | LK:1503–1556 |
| `initializeRecorded` | `initializeFinish` | LK:1598's check after the record |
| `initializeFinish` | `guard autoStartLoops, !side.isDraining` → `.startLoops(intervals)` or `.done`; sets `didInitialize = true` (Q2) | LK:1598–1630, LK:1265 |
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

**`setTransport(nil)`** stays a call right after `drainFinished`'s turn, at depth 0 with no await between. The sentinel refuses it from inside a body (LK:556). Q1 asks whether its body should move into a side helper instead.

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
| T8 | `onLandDestroyed` | a gated test transport | `destructionFinished` false. A `setTransport(X)` at the hold attaches X. After release, `destructionFinished` is true and the transport is the released stand-in |

T1–T3 run on tick and tickless lands. T4 needs a tick land. T5–T8 run on a live land, plus one replay row for T8, where a re-evaluation keeper skips the handlers (#826). The gates use `KeyedGates` with a fresh key range (`firstKey: 12_000`).

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
| Q1 | Keep `setTransport(nil)` as a depth-0 call after `drainFinished`, or move its body into a side helper callable in the turn? | keep: it is the public attach path, with its own refusal logic, and K2-2 replaces it with the facade anyway |
| Q2 | Move `didInitialize = true` into the last init segment (and `fail`)? | yes: it is a model write after an await today, and nothing awaits after the last segment. P3: the suite is green with the caller's write removed. The one difference is `initializationWaits` for a caller in the window after the Task's end, a test-only counter |
| Q3 | Gates instead of new `LandKeeperHoldPoint` cases | gates: every await here runs test-controllable code, except `submitTurnRecord`, which already holds at `.turnRecord`, and `waitForTickInFlight`, which a gated tick holds |
| Q4 | The replay header (I1–I3) stays legacy until #612 | yes; only its one write moves into a segment |
| Q5 | CLAUDE.md's sentence "The land-stop drain's post-await bookkeeping is a further exception until #522 moves it into a turn" | delete it in this PR. #522 stays open for its other paths (join and leave resolvers, freeze settle, the legacy tick, the monitor land) |

## Order of work

1. The tests T1–T8 against main: green, since they pin today's behavior.
2. The init segments, then the drain segments: one commit each, each green on T1–T8 and the listed suites.
3. The deletions (the dead branch, `async`), with P1 and P2.
4. CLAUDE.md (Q5), and `Notes/plans/README.md`'s row.
5. Full debug test, pre-push, push. Mutants to the cloud.
