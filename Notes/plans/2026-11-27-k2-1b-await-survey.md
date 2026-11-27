# K2-1b survey: every await in `performInitialization` and `drainAfterIdleCheck`

Read-only, origin/main **aced9ace**; anchors are `LandKeeper.swift` lines at that head (`LK:`). The scope is from the K2 plan's §16 item 18 (on `draft/700-k2-1`): segment both functions, end #522's exception, a `HoldPoints` case per await, no behavior change.

"Hold" is how a test parks the keeper at that await, so that a re-entrant call can check the state its segment left. When the await is on test-controlled code (a resolver, a handler, a source, a transport), a gate in that code is enough and no new `LandKeeperHoldPoint` case is needed. A new case is needed only where the await is on library code.

## Who can re-enter during each

- **During initialization:** `ensureInitialized` waiters (`join`, `forceShutdown` LK:2554, `awaitInitialization`). They park on `initializationTask.value` (LK:1253) and read nothing until it ends. Test hooks: `currentState()` and the `...ForTesting` reads. Transport attach and binding. A turn that fails the land (`failLand`, from the record's submission) sets `isDraining` during the record's await; LK:1596's comment names this.
- **During the drain:** intake is closed by `isDraining` (set in `shutdownIfIdle` LK:4753, or in `failLand`). Re-entrant: `shutdownIfIdle`/`forceShutdown` second callers, which wait on `drainTask` (LK:4747). Reads: `currentState`, `isDraining`, `destructionFinished`. A tick already running finishes (`waitForTickInFlight`).

## `performInitialization` (LK:1415–1631)

The initialization runs in its own Task (LK:1260), started by `ensureInitialized`. `didInitialize = true` and the watcher resumes happen in the **caller's** segment after `task.value` (LK:1265–1268), not in `performInitialization`.

| # | Await | LK | Mode | State the segment after it touches | Hold | Pinned by |
|---|---|---|---|---|---|---|
| I1 | `source.getMetadata()` | 1464 | reevaluation | writes `turnSide.replay!.replayHeaderPayloadEncoding`; then I2 | gated `ReevaluationSource` (test type) | RecordPayloadFormatTests, RecordPayloadBytesTests |
| I2 | `behavior.payloadDecoders.check(source)` | 1465 | reevaluation | failure: `failInitialization` (`model.recordFailure`, `model.initializationFailure`) + teardown Task; success: falls to I3 | the same gated source (`check` reads it) | RecordPayloadFormatTests (`noDecoder`) |
| I3 | `replayInitializeBeforeTickZero()` | 1475 | reevaluation | **inside the callee, across its own awaits:** I3a `source.getInitializeRecord()` (LK:1365), I3b `getLifecycleEvents(for: 0)` (LK:1366); then `model.sequence.next/take`, `withHandlerStep` (OnInitialize writes `model.state`), `turnSide.replay!.replayedInitializeBeforeTickZero = true`; then I3c `flushOutputs(forTick:)` (LK:1392), which awaits the transport, the recorder, the sink and `runSyncRequests` (LK:744–789) and removes `model.syncRequestsByTick[tick]` | I3a/b: gated source; I3c: gated transport (`sendEventToTransport`) or a **new case** `.replayInitializeFlush` before LK:1392 | ReplayJSONAllowanceKeeperTests, SyncOutputGoldenTests, TicklessReplayPassTests |
| I4 | `ResolverExecutor.executeInitializeResolvers(...)` | 1497 | live | **across the await:** `sequence` (taken LK:1481, before it) and `ctx` (built LK:1483 with `tickId: model.lastCommittedTickId`) are carried; after: reads `isDraining`/`Task.isCancelled` (LK:1518), `failInitialization` + teardown Task on timeout or `.failLand`; else `withTurn { initializeTurnBody }` (LK:1538) writes the state, and on failure `failInitialization` + teardown | gated OnInitialize resolver (WatermarkGate pattern); **no new case** | InitializeTwoStageTests (`waitForInitializationWaitersForTesting`), InitializeResolverFailureTests, ResolverDeadlineTests (timeout), ResolverValueTests, ResolverOutputReplayTests, LandManagerFailedInitializationTests |
| I5 | `submitTurnRecord(...)` | 1576 | live, recorder | inside: `withTurnSubmitting` stages (sync), `holds.at(.turnRecord)` (LK:4109), then `submission?.value`. After: LK:1598 `guard autoStartLoops, !isDraining` | **existing** `.turnRecord` (LK:4109) | SyncStreamInitializeRecordTests, LandLifecycleLogTests; `.turnRecord` users: DrainTurnTests, ShutdownTurnTests, TicklessReplayPassTests … |
| I6 | `recorder.record(...)` | 1583 | — | **dead on main:** the block runs only when `mode == .live` (LK:1480), and `routesThroughTurn` is `config.mode == .live` (KeeperModel.swift:241), so the `else` at LK:1582 is never taken | none; delete in K2-1b, with the proof above | — |
| I7 | `recorder.recordTick(...)` | 1590 | — | dead, as I6 | none; delete | — |
| I8 | `configureTickLoop(interval:)` | 1606 | live, autoStartLoops | **not a suspension:** the body has no await outside the Task it creates (LK:2988–). Writes `tickTask`, `appliedTickPhaseOffset`, `tickLoopConfiguredAt` | none needed; K2-1b can make it sync | the tick-loop suites, #910's loop test |
| I9 | `configureSyncLoop(interval:)` | 1629 | live, autoStartLoops | not a suspension, as I8. Writes `syncTask`, `appliedSyncPhaseOffset` | none; can be sync | the sync-loop suites |

The failure exits (LK:1455, 1471, 1512, 1526, 1551) start `tearDownAfterFailedInitialization` in a **new Task** (LK:1336). It is keeper-isolated, so it runs after the initialization's segment ends. Its writes (`players`, `playerServices`, `rejoinReservations`, `dropPendingInputs`) come before its only await, `shutdownIfIdle`. Not part of `performInitialization`'s segments, but K2-1b's init-failure route touches it.

**Segments after I6/I7 are deleted and I8/I9 made sync:** S0 the checks (to I1, or to I4 live); S1 after I1/I2; S2 the replay init (three internal awaits); S3 after I4 (the turn); S4 after I5 (the loops). So there are 3 live awaits (I4, I5, plus I3 on replay) and 5 on replay.

## `drainAfterIdleCheck` (LK:4776–4856)

Entered from `shutdownIfIdle`'s Task (LK:4757) or from `runFailureTeardown` (LK:4773, after `.landFailedTeardown` and `transport.landDidFail`).

| # | Await | LK | State the segment after it touches | Hold | Pinned by |
|---|---|---|---|---|---|
| D0 | `holds.at(.drainStart)` | 4777 | `tickTask`/`syncTask` cancel + nil, `turnSide.cancelDestroy()` | **existing** `.drainStart` | GracefulShutdownTests, LandManagerSingleFlightTests, LandDSLTests, KeeperCensusTests |
| D1 | `waitForTickInFlight()` | 4788 | only suspends when `model.ticksInFlight > 0` (LK:4410). After: `model.dropPendingInputs(..., "drain")`, `model.destroyHandlersStarted = true`, reads `initializationFailure` and `mode` | a tick held in flight (a gated tick handler or `.turnRecord` on the tick); no new case | DrainTurnTests, ShutdownTurnTests |
| D2 | `notifyTransportDestroyedAndRelease()`, early exits | 4797, 4805 | inside (LK:4862): `await (transport ?? boundSyncRequester)?.onLandDestroyed()`, then `boundRequester.object = nil`, `model.destructionFinished = true`, `releasedTransport`, `setTransport(nil)`: **the #522 post-await bookkeeping** | gated test transport (`onLandDestroyed`); a **new case** `.drainNotifyTransport` if the test needs it without a transport (`boundSyncRequester`) | InitializeResolverFailureTests (init failed → skip), ReevaluationDrainTests (#826 skip), LandReleaseTests (#346) |
| D3 | `runDestroyHandler("onDestroyWhenEmpty")` | 4820 | inside: `ctx` and the resolver values built from `model.state` before the await (LK:4884–4892); await `executeResolversWithoutDeadline` (LK:4896); after: `withHandlerStep(..., dropsOutputs: true)` writes `model.state` | gated destroy resolver; no new case | DrainTurnTests, LandDSLTests, LandRandomStepTests (`drainRandom`), StepScopeTests |
| D4 | `runDestroyHandler("OnFinalize")` | 4829 | as D3, the State after D3's write | gated OnFinalize resolver | as D3, plus GracefulShutdownTests |
| D5 | `afterFinalizeHandler(snapshot, scoped)` | 4849 | `snapshot = model.state` before the await; after: `scope.close()` (defer, LK:4848), then D6 | gated AfterFinalize handler (test code) | AfterFinalizeRaceTests (#893), StepScopeTests |
| D6 | `notifyTransportDestroyedAndRelease()` | 4855 | as D2 | as D2 | LandReleaseTests, LandManagerSingleFlightTests |

The no-ticket argument for D3–D5 is in the code (LK:4809–4812, LK:4875–4877): intake is closed, no tick starts, and nothing is pending. K2-1b turns it into checks: each segment after D3/D4/D5 asserts `isDraining`, `ticksInFlight == 0` and `pending.isEmpty` (or reads them in the turn).

## What K2-1b's holds come to

| Await | Hold |
|---|---|
| I4, D3, D4, D5 | gate in test code (a resolver or handler); **no new case** |
| I5 | existing `.turnRecord` |
| D0 | existing `.drainStart` |
| D1 | a held tick |
| I1–I3b, D2/D6 | gated test source or transport |
| I3c (replay flush) | **new case** `.replayInitializeFlush`, or a gated transport |
| D2/D6 with no transport | **new case** `.drainNotifyTransport` |
| I6, I7 | dead; delete |
| I8, I9 | not suspensions; make them sync |

The plan's "a HoldPoints case per await" (§16 item 18) therefore comes to **at most two new `LandKeeperHoldPoint` cases**. The rest are test-side gates or existing holds. `KeeperCensusTests` lists the hold cases (it matches `.drainStart`), so a new case adds a census row.

## Open points for the K2-1b plan

1. **#612's part.** I1–I3 are replay-only. Item 18 asks whether they move. Recommend: leave them on the legacy path and name them in the #612 exception, since replay's tick is already non-turn until #612.
2. **`didInitialize`** is set by the caller after `task.value` (LK:1265). A segmented init sets it in its last turn or keeps the caller's write. That write is outside the init Task, so the order "loops configured → `didInitialize`" holds today. Pin it.
3. **I4's carried `sequence`.** It is taken before the resolvers, so a join during them gets a later sequence than OnInitialize, but those joins are parked on `ensureInitialized`. A ticket isn't needed, but the segment should assert that `model.sequence` moved by nothing but this init.
4. **The CLAUDE.md sentence** "The land-stop drain's post-await bookkeeping is a further exception until #522 moves it into a turn" is D2/D6's writes. K2-1b updates it. #522 itself is broader: join/leave resolvers, freeze settle, legacy tick, monitor land. So it stays open.
