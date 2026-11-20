# Remove the adapter's off mode on live lands (#546 L2)

**Status:** rev 2, plan only, for review. No code until this plan is GO and L1 (#677) has merged.
- **Decided (the maintainer, 2026-11-20):** §8's Q1 (a), Q2 (a) and Q3 (a). They are recorded there.
- **Rev 2** answers rev 1's review (#680: 7 must-fix, 7 should, 4 nit) and Code-2's correction of the recording gate. What changed is in §11.

**Issue:** #546, step L2 of `2026-11-19-adapter-turn-core-rewrite.md` (rev 13). That plan holds L2's placeholder (§3.2, groups 2a–2e) and the "Inputs to L2's own plan" block. This plan lays L2 out; §9 maps each input to the section that settles it. "Group 2a"–"2e" name #655's groups; "L2a"–"L2d" name this plan's PRs.

**Base:** `main` at bf8a2ac2 with L1 (#677) applied. L1 moves no line this plan points at by more than a few lines. Pointers are at bf8a2ac2:
- "TA" is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`;
- "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`;
- "LKT" is `Sources/SwiftStateTree/Runtime/LandKeeperTransport.swift`;
- "LR" is `Sources/SwiftStateTreeTransport/LandRouter.swift`;
- "DS" is `Tests/SwiftStateTreeNIOTests/Differential/DiffScenarios.swift`; "DR" is `DiffRunner.swift` beside it.

**Related:** #612 (`2026-11-20-replay-on-turn-core.md`; rev 4 is in review). It owns the keeper's off path for `.reevaluation` keepers (S2, S6), and lists groups 2d and 2e as a dependency of S6. §3.4 draws the line between the two plans; §3.7 lists what #612 takes over.

## 1. Goal and end state

**Goal.** Every sync on a live land runs in one of the keeper's turns. The adapter no longer runs a sync cycle of its own.

**End state after L2:**
- The adapter has one sync path: the in-turn phase, called by the keeper inside a turn. `withSyncState`, `_syncNowImpl`, `_syncBroadcastOnlyImpl`, the adapter's executor host and the `inTurnSync` init parameter are gone.
- The keeper has no `beginSync`/`endSync`, no `isSyncing` flag, and no latch that reruns a sync-only turn after a legacy cycle.
- Every live keeper runs its inputs through turns, with or without a transport.
- The harness has no legacy cells. Its in-turn goldens record what the in-turn path does for every sync a scenario asks for.

**Unchanged by L2:**
- The standalone initial sync (`_syncStateForNewPlayer`, TA:5586) and its re-checks: the ticket, the player binding, the output gate and the commit epoch. It doesn't use `beginSync`/`endSync`. It stays until B2 (`.initialSyncCommit`) and B3 (membership). Its recorder tag `.legacyCycle` stays (`ReevaluationSyncStream.swift:19`).
- The keeper's off path for `.reevaluation` keepers: `processPendingActions`, `replayRecordedPasses`, `deliverLegacyPass`, the legacy `runSync` loop's transport call, and `LandKeeperTransport`'s `syncNowFromTransport`/`syncBroadcastOnlyFromTransport`, which fakes attached to `.reevaluation` keepers still receive (§3.4). #612 S2 moves those keepers onto `runTurn`; S6 deletes that code.
- Frames on the default production path. A server built from `main` already runs in-turn; production's periodic sync already runs `runSyncOnlyTurn`.

## 2. Who reaches the off mode after L1

Counting rule: executable call sites, not comments. Each PR's body lists its files.

**The adapter's own syncs on an in-turn land** (group 2a): the kept-event follow-up (TA:3153, :5269, `startFollowUpSync` TA:3161), the backlog and busy retry (`deferSyncForOutboundBacklog`, TA:3197–3216), the lag timer's sync (TA:3603, `runSyncLagTimerSync` TA:3620), and the behind-commit repair (`startDelayedFollowUpSync`, TA:3185, called at TA:5655).

**`syncNow()` and `syncBroadcastOnly()`** (group 2b, `TransportAdapter+Sync.swift:4–10`). They run the adapter's cycle even on an in-turn land.
- `syncNow()`: 127 calls in `SwiftStateTreeTransportTests` (35 files), 3 in `SwiftStateTreeTests`, 3 in `SwiftStateTreeNIOTests` (2 files, `DR` among them), 6 in `SwiftStateTreeBenchmarks`, 30 in EncodingBenchmark (`BenchmarkExecution.swift`, `EncodingBenchmarkMain.swift`, `RouterJoin.swift:271`), one in each Examples `SyncTablesFrameIdentityTests`, and `TransportAdapterBenchmarkHandle.syncNow`.
- `syncBroadcastOnly()`: 17 direct calls in nine `SwiftStateTreeTransportTests` files: `PerPlayerSyncTablesScenarioTests` (3), `TransportAdapterSyncConcurrencyTests` (3), `TransportAdapterOrderedSendTests` (2), `TransportAdapterPendingEventsAcrossCyclesTests` (2), `TransportAdapterSyncBackPressureTests` (2), `TransportAdapterSyncPhaseTests` (2), `TransportAdapterDebugFreezeTests`, `TransportAdapterSyncDirtyWindowTests` and `TransportAdapterSyncLagTests` (1 each). Helpers that wrap it are listed by the L2a PR.

**The cycle hold on in-turn adapters.** `SyncCycleHold` (`TransportTestHelpers.swift:80–87`) arms `.cycleBeforeEndSync` and spawns `syncNow()`. In-turn callers: `TransportAdapterPendingEventsAcrossCyclesTests` (:297, :646–710, :826–1018), `TransportAdapterTargetedEventOnceTests` (:81, :167), `TransportAdapterSyncBackPressureTests` (:159), `TransportAdapterSyncDirtyWindowTests` (:166, :228) and `TransportAdapterInTurnSyncTests` (:893). The harness row `join-during-sync-cycle-inturn` (DS:372, built by `syncCycleRow`, DS:66–90) does the same.

**The freeze** (group 2c): the settle's `beginSync` loop (TA:6546–6610) and the resume's replay (TA:6639–6643).

**Keepers whose transport doesn't opt in** (group 2d). These are 23 conformers in 19 files. Nine files already answer `runsSyncPhaseInTurn` with `true`, but four of them have a second conformer that doesn't: `DrainTurnTests`, `PerSequenceResultTests`, `ResolverDeliveryTests` and `TicklessReplayPassTests`. Ten files don't opt in at all: `LandKeeperDebugFreezeTests`, `ReplaySequenceWatermarkTests`, `SyncRegistrationTests`, `ActionEventSyncTests`, `LandDSLTests`, `ResolverDeadlineTests`, `LandKeeperReevaluationOutputModeTests`, `InitializeResolverFailureTests`, `MockLandKeeperTransport` and the library's `ReleasedLandTransport` (LKT:351). Some of them are attached to `.reevaluation` keepers (§3.4).

**Live keepers with no transport** (group 2e): about 19 `SwiftStateTreeTests` files, `HashCostBenchmark.swift:50`, and `ReevaluationRunner/main.swift:452` (a live keeper that records a game).

**Explicit off callers** pass `inTurnSync: false`, directly or through a fixture:
- the harness's legacy cells (`DiffRunner`, after the configuration's init since L1);
- the pinned `LandRouterJoinAttemptTests` (L1);
- direct: `AtomicPatternIndexAdapterTests` (1), `InitialSyncBehindCommitTests` (1), `LandReleaseTests` (1), `RowAddressingAdapterTests` (:441–551, :882), `TransportAdapterPendingEventsAcrossCyclesTests` (2), `TransportAdapterSyncLagTests` (4);
- through a fixture or an `[true, false]` case list: `SyncStreamProducerTests.swift:286`, `TransportAdapterInTurnSyncTests.swift:928` and :987, `SyncStreamInitializeRecordTests.swift:144`, `TicklessPassOrdinalTests.swift:551`, every arm of `TransportAdapterNewestWinsTests`, `TransportAdapterRegisterSessionTests.swift:58` (its fixture defaults to `false`) with its `[true, false]` cases, `TransportAdapterInitialSyncStaleReadTests` (:99, :302, :326), `ActionJobReplayOrderTests` (:160–173), `RecordTurnBoundaryLiveTests` (:97), `LandKeeperInputTurnTests` (:222, :595, :616), `TransportAdapterJoiningAdmissionTests` (:114, :143, :186, :233), and `WallClockCadenceSmokeTests.swift:25` (`inTurn: [true, false]`).

**Direct `beginSync`/`endSync` callers:** `LandKeeperSyncLockTests` (:74, :115), `TransportAdapterOrderedSendTests.swift:575`, `SyncStreamProducerTests.swift:543`. Cycle cases also live in `TransportAdapterDebugFreezeTests`, `TransportAdapterSyncDirtyWindowTests`, `TransportAdapterSyncBackPressureTests` and `TransportAdapterSyncConcurrencyTests`.

## 3. Decisions

### 3.1 What `syncNow()` becomes (groups 2a, 2b)

*`syncNow()` runs one sync-only turn on the keeper now, and returns after it.*
- The keeper gets a package entry point, `syncTurnNow()`. It runs `runSyncOnlyTurn` (LK:5039) in a single keeper job and returns. The adapter shares the keeper's executor when it runs in-turn (TA:111, :973), so no other turn runs between the request and the turn.
- No fold. The sync loop folds a sync into a tick due within the coincident-sync window (LK:5539–5557). An explicit `syncNow()` is a test's or a benchmark's request for a sync at that point, so it runs at once. The sync loop keeps its fold.
- Writer back-pressure is the keeper's. A deferred phase on a land without periodic sync gets one retry after the writer drains (`retrySyncOnlyTurnAfterWriterDrain`, LK:5068), as a skipped legacy cycle did. The adapter's backlog retry and its fields (`backlogRetryRuns`, `backlogDeferredSyncNow`, `backlogDeferredBroadcastOnly`, `backlogRetryScheduled`) go.
- No busy outcome. A sync-only turn is synchronous, so a request can't meet one in flight. `SyncSkipCounts.busy` goes (§7).

What changes for a caller:
- **A ready join flips.** The in-turn phase completes ready joins (TA:2913–2919); the legacy cycle passed none (TA:3150). A `syncNow()` while a join waits now sends that join's JoinResponse and firstSync in this phase.
- **A tickless land records a turn.** Its sync-only turn is its own turn record (LK:5054–5056, #327).
- **The record's turn kind** is `syncOnly` where it was `legacyCycle`.

§5 accounts for these in the harness. In tests outside it, the L2a PR lists each converted assertion.

### 3.2 Pending sync work: one rule, one entry point

*Rule: whenever sync work is due outside a turn, something asks the keeper for a sync-only turn. No flag waits for an adapter cycle to read it.*

The keeper gets one requested-turn path beside the join-sync turn: `requestSyncTurn(after: Duration = .zero)`, with its own pending flag. One request is pending at most; a second one coalesces. Unlike `runJoinSyncTurn` (LK:5102), it doesn't require a ready join. It runs `runSyncOnlyTurn`, which skips a failed land (LK:5042) and a draining one. Callers:
1. **Kept events after a commit.** After a committed phase on a land without periodic sync, if events are still queued (kept by this phase or queued after its commit), the keeper requests one sync-only turn. This is the legacy follow-up's rule (TA:3279–3286), moved to `applyInTurnSyncResult`'s `.committed` case. A phase that ends the land requests nothing.
2. **An event queued outside a turn.** `sendEvent` outside a phase (an out-of-turn `sendEventToTransport`, or a test) on a land without periodic sync queues a merged event that only a phase delivers (opcode 107). The adapter requests a sync-only turn when it queues one. An immediate send needs none.
3. **The lag timer** (TA:3603): it requests a sync-only turn where it spawned `syncNow()`. Its hold point `.syncLagTimerSync` moves to the keeper side of the request, and the request re-checks the timer's epoch after the hold.
4. **The behind-commit repair** (TA:5655): `requestSyncTurn(after: syncFailedPlanFollowUpDelay)`. Its hold point `.failedPlanFollowUp` stays, before the turn. The standalone firstSync it follows keeps its re-checks (§1).
5. **The settle's kept events** and **the resume's deferred syncs** (§3.3): one request each.

The writer-drain retry (LK:5068) and the join-budget follow-ups (`scheduleJoinSyncTurn`, LK:5089) stay as they are.

**Test wait.** The keeper gets `waitForRequestedSyncTurnsForTesting()`. It returns when no requested turn, delayed repair, writer-drain retry or join-sync turn is pending, each counted until its turn has run and handed its frames to the writer. DR's three waits use it after the adapter's own waits: the sync step (DR:573–576), `.settleSpawned` (DR:352–357) and the barrier's sync quiescence (DR:598–616). `waitForBackgroundSyncsForTesting` (TA:3179) goes when its last source goes.

Rejected: keeping `syncNow()` as an adapter cycle that runs inside a keeper job. It would keep a second sync entry, which B2 would then have to model.

### 3.3 `syncBroadcastOnly()` (group 2b): deleted

Decided (Q2 (a)). Its callers use `syncNow()`.
- On an in-turn land a broadcast-only request already runs the full phase (LK:637–640). Production never reaches the broadcast-only plan; its only caller is `_syncBroadcastOnlyImpl` (TA:5232).
- The legacy broadcast-only cycle kept the dirty flags and upgraded to a full plan in several cases (TA:5248–5256). With the full phase those are the default. The cost is per-player diffs where only broadcast fields changed, which the in-turn path already pays.
- `planBroadcastOnlySyncPhase` (TA:5279) goes with it.
- The keeper's `requestSyncBroadcastOnly` (LK:422) stays as handler API: "a sync in this turn".

Each of the 17 calls is converted to `syncNow()` or deleted. A test that asserts the broadcast-only plan itself (kept dirty flags, no per-player patch) is deleted with the plan. The L2a PR lists each one with its fate.

### 3.4 The freeze settle (group 2c)

#655 decision 2 keeps the whole freeze on the adapter through B2, the settle included. L2 keeps that and replaces the settle's keeper-lock protocol with one keeper job.

**Steps:**
1. **Drain**, as today: `keeper.debugFreeze(generation:timeout:)` (LK:1459).
2. **Wait for the writer**, as today: the bounded loop (TA:6556–6561) that checks the deadline and `debugIsCurrent(generation)` on each pass. So a release or the deadline ends it. `waitForSyncCycleDrain` (`OutboundWriter.swift:260–270`) has no deadline or cancellation, so it isn't used here.
3. **Commit, in one synchronous segment on the keeper.** The keeper gets `debugSettleTurn(generation:_:)`, a package entry point that takes a closure from the adapter. Both share the executor, so the closure runs the adapter's code through `assumeIsolated`, as `runSyncPhaseInTurn` does. `LandKeeperTransport` doesn't change. In that one segment, in this order:
   - **The fence:** the keeper checks that `generation` is still active and the keeper still frozen. The adapter's closure checks `debugIsCurrent(generation)` and that the output gate is open. Any failure returns "released" or "closed", and nothing is planned.
   - **The membership epoch** is read here, in the same segment as the copy, so no join or leave slips in between.
   - **The phase** is the settle's own, not the ordinary in-turn phase. It passes no joiners, as today (TA:6572). It ignores writer back-pressure, as today: step 2 waited, and a frame that entered the writer since doesn't defer the settle. On an empty land it takes the copy without clearing dirty flags and plans nothing (TA:6568–6573). Otherwise it plans and commits the full phase, clearing the flags when dirty tracking is on.
   - **A plan failure** closes the output gate and fails the land in this segment, as the in-turn phase does.
   - It returns the state copy, the committed tick, the epoch and whether events are still kept.
4. **Publish** after the call, with the generation checked again (TA:6592–6604).

**The record.** The settle records its sync output under `.legacyCycle`, as today, with the same position source. So `freeze-resume-messagepack` (`SyncOutputGoldenTests.swift:21–22`, :47, :96) stays byte-identical. A new turn kind would be a record-format change; #612's format 4.0 can rename it.

**The resume** (TA:6614–6650): the deferred syncs become one `requestSyncTurn()` (§3.2). The join-sync turn request after it stays (TA:6646–6648).

#655's decision 2 text, §3.4's coalescing "after `endSync`" and `.cycleBeforeEndSync` "before the settle's `endSync`" are then rewritten against this shape (§3.7).

### 3.5 Every live keeper on the turn path (groups 2d, 2e)

`usesInTurnSync` (LK:672) answers two questions at once: whether inputs run through turns, and whether the sync phase runs in them. Decided (Q3 (a)): L2c splits it, with #612's names (§3.3 there).
- **`routesThroughTurn`** is true when inputs go through turns. After L2c it is `mode == .live`. #612 S2 adds its `.record` keepers.
- **`syncsInTurn`** is true when a transport is attached and opts in (`runsSyncPhaseInTurn(of:)`). It has no mode term.

**The turns with no transport.** The turn functions take an optional transport:
- `runTickTurn` (LK:4705–4708) takes `transport: (any LandKeeperTransport)?`. With none, it applies the inputs, runs the tick handler, takes the emitted events and the sync request, and records them in the turn record. It calls no phase.
- `runInputTurn`'s output branch (LK:5442–5446) takes the emitted events and the sync request whenever the batch is non-empty and the land hasn't failed. It calls `runTurnOutputs` only when `syncsInTurn`. So `makeTurnRecord` records the turn's events whatever the delivery.
- Initialize (LK:1193–1210) runs as a turn when `routesThroughTurn`. It emits its initialize marker only when the sync stream is recorded (`recordsSyncStream`), so a keeper with no port writes no marker without a stream.
- `OnSync` with no port: the sync loop runs it as today (LK:5509–5530), read-only. With no port nothing follows it.

**The 22 sites** (#612 §3.3's list), each with its predicate:

| Site | Predicate |
|---|---|
| handler sync requests LK:637 | `syncsInTurn` (a sync-only turn needs a port) |
| `isUsingInTurnSync()` LK:859 | `syncsInTurn` (below) |
| initialize LK:1193 | `routesThroughTurn` for the turn; the marker on `recordsSyncStream` |
| join LK:1651, :1889 | `routesThroughTurn` |
| the join admission helpers LK:1903–1924 | `syncsInTurn` (they call the port) |
| actions LK:2202, :2657 | `routesThroughTurn` |
| leave LK:2585 | `routesThroughTurn` |
| client events LK:2909, :3046 | `routesThroughTurn` |
| server input LK:3153 | `routesThroughTurn` |
| tick LK:4250, :4300 | `routesThroughTurn`; the phase inside on `syncsInTurn` |
| `recordsSyncStream` LK:4881 | `reevaluationRecorder != nil && syncsInTurn` (mode term kept until #612 S2) |
| `runSyncOnlyTurnIfInTurn` LK:5062 | `syncsInTurn` |
| tickless turns LK:5442, :5539 | `routesThroughTurn`; the phase on `syncsInTurn` |

**Recording.** LK:4881 is the sync-stream gate, and stays on `syncsInTurn`. The state hash's gate is `enableLiveStateHashRecording && reevaluationRecorder != nil` (LK:4741, :4555; the initialize record at :4844). It has no transport term and doesn't change. `ReevaluationRunner/main.swift:452` records with no port. Today it runs the legacy `runTick` (LK:4503, :4555–4581), which writes its record through separate calls (`record`, `setStateHash`, `recordServerEvents`). On `runTickTurn` it writes one turn record per tick (`makeTurnRecord`, `submitTurnRecord`). So the raw bytes may differ. The comparison that must hold, for a tick land and a tickless land, each with initialize and a land-failure prefix:
- decoded equality of the inputs, the state hashes, the events and the watermarks, old record against new;
- the new record replayed through today's verifier, with 0 mismatches.

**`isUsingInTurnSync()`** (LK:858, public) answers `syncsInTurn`. A keeper with `transport: nil` answers `false`, as today. The tests that assert it (`PerSequenceResultTests:227`, `ResolverDeliveryTests:271`, `TwoPhaseHandlerTests:200`, `DrainTurnTests:388`, :418, `ShutdownTurnTests:215`) are listed in L2c's PR with what they now assert.

**The fakes.** A fake on a live keeper opts in: `runsSyncPhaseInTurn` → `true`, and a `runSyncPhaseInTurn` that records what the test needs (`.notRequested` when it records nothing). Not all of them can:
- **Fakes that hold inside an async call** to keep a legacy tick in flight: `DebugFreezeGatedKeeperTransport` (`LandKeeperDebugFreezeTests.swift:134`, :206–230), `BroadcastHoldTransport` (`DrainTurnTests.swift:160`, :333), `HoldingTransport` and `BroadcastHoldingTransport` (`ResolverDeliveryTests.swift:229`, :249, :420, :491). The in-turn phase is synchronous, so opting in would erase the order they witness. Each test moves its hold to a keeper hold point (`HoldPoints`) or a resolver hold at the same position in the turn, or is retired because the turn path has no such window. The L2c PR gives each its fate and reason.
- **Fakes on `.reevaluation` keepers** stay as they are until #612 S2: `PassSyncCountingTransport` and `PassDeliveryLogTransport` (`TicklessReplayPassTests.swift:164`, :174, :453, :486), and `LandKeeperReevaluationOutputModeTests.swift:41`, :104. They are reached through the mode, not through a missing port.
- **`ReleasedLandTransport`** keeps its `syncNowFromTransport`/`syncBroadcastOnlyFromTransport` drops (LKT:378–379), which `DrainTurnTests.swift:326` calls directly.

So `syncNowFromTransport` and `syncBroadcastOnlyFromTransport` stay in `LandKeeperTransport` until #612 S6, with their keeper calls (LK:643, :645, :3802, :3876, :4516, :5564). After L2c no live keeper reaches those calls. L2d deletes the adapter's implementations and gives both requirements default implementations that do nothing.

Rejected: a null transport that opts in. It would run a sync phase that sends nothing, clear dirty flags every turn and change what the 2e tests observe.

### 3.6 What L2d deletes

The off executor goes last, when no caller is left:
- the adapter's `inTurnSync` init parameter and `inTurnSyncEnabled` (TA:973), `ownExecutorHost` and `AdapterExecutorHost` (TA:105–111), and the package `inTurnSync` on `LandManager`'s init and `NIOLandServerConfiguration` (added by L1);
- `withSyncState` (TA:3296), `beginSyncLocatedIfRecording` (TA:3915), `legacyCycleRead` (TA:3901), `beginSyncRequests` (TA:747), and `startBackgroundSync`/`backgroundSyncTasks` once their last user goes;
- the adapter's `syncNowFromTransport`/`syncBroadcastOnlyFromTransport` (`TransportAdapter+LandKeeperTransport.swift:15–21`);
- on the keeper: `beginSync`, `beginSyncLocated`, `endSync()` and `endSync(clearDirtyFlags:)` (LK:1336–1395), `isSyncing` (LK:663), and the latch `syncOnlyTurnAfterLegacyCycle` (LK:704) with its reads in `runTurnOutputs` (LK:4629) and `runSyncOnlyTurn` (LK:5043). With no legacy cell left, nothing calls them;
- the hold points only the legacy cycle reaches: `.cycleBeforeEndSync`, `.busyRetry`, `.followUpSynced`, and the keeper's `.syncOnlyAfterLegacyCycle`. The keeper's `.legacyDelivery` stays for `.reevaluation` keepers until S6;
- the off arms of every explicit off caller (§2). `WallClockCadenceSmokeTests` keeps its on leg, and CI keeps the check that it ran;
- `LandKeeperSyncLockTests`, the direct `beginSync`/`endSync` calls (§2), and the remaining legacy-cycle cases.

Each off arm is deleted, or converted when the in-turn path has the same claim to check. The PR lists each test with its fate. No new off arm is added.

### 3.7 Hand-offs

**To #655 (B2's text).** B2's rewrite against one sync path takes these from L2:
- `.cycleBeforeEndSync` is gone; the settle's commit is `debugSettleTurn` (§3.4);
- each delayed follow-up is the keeper's `requestSyncTurn(after:)`, with one pending flag, not a key per follow-up; the lag timer's request and its `.syncLagTimerSync` hold are on the keeper side, with the timer's epoch re-checked after the hold (§3.2);
- decision 2's keeper-lock protocol and §3.4's coalescing "after `endSync`" are replaced by §3.4 here.

**To #612 (Code-2).** With Q3 (a) decided, #612 takes the predicate split as given:
- S2 adds `.record` keepers to `routesThroughTurn`, and moves the `.reevaluation` fakes (§3.5);
- S6's trap list and §8's order ("S2 → L2 → S6") change: L2 no longer deletes the two transport requirements, S6 does;
- §5.3's `SyncPlanMode` drops broadcast-only, which L2a deletes;
- #612 §3.3's "a recorder sets it under today's gate (LK:4881 …)" is the same gate mix-up as rev 1 here (§3.5).

## 4. Steps

Order: **L2a ∥ L2b → L2c → L2d.** L2a and L2b are independent and can be reviewed side by side. L2c needs L2a, because its no-port turns use the keeper's requested-turn path. L2d needs all three. Each PR leaves `main` green, with the harness byte-identical except where §5 says.

**L2a: the syncs become turns** (groups 2a, 2b).
- `syncTurnNow()`, `requestSyncTurn(after:)` and the test wait on the keeper (§3.1, §3.2). On an in-turn adapter, `syncNow()` calls `syncTurnNow()`. On an off-mode adapter it still runs the cycle until L2d, so the legacy cells and their goldens don't change.
- `syncBroadcastOnly()` deleted, and its callers converted (§3.3).
- The follow-up, the backlog retry, the lag timer's sync and the behind-commit repair moved to the keeper (§3.2).
- **The cycle hold on in-turn adapters** (§2): each `SyncCycleHold` caller gets its fate here. A claim about work that arrives while a cycle is in flight has no in-turn window. Where the claim is about deferral, the test holds the writer instead (a deferred phase and its retry). Where the claim is the cycle's `endSync` hop, it is deleted. The PR lists each test.
- **The harness:** `join-during-sync-cycle-inturn` is retired here, and `join-during-writer-backlog` added (§5.2). The in-turn goldens are regenerated (§5.1).
- `TransportAdapterBenchmarkHandle.syncNow` forwards to the new `syncNow()`. The handle's `syncStateForNewPlayer` and its join with `completedInTurn == false` (used by `Rejoin.swift`) stay; they belong to the standalone initial sync.
- `SyncSkipCounts.busy` and the profiler's busy counter (§7).
- Gate: §6. Host A/B: yes.

**L2b: the freeze settle** (group 2c). §3.4. Gate: `TransportAdapterDebugFreezeTests`, `LandKeeperDebugFreezeTests` and `SyncOutputGoldenTests`; the harness. A held-writer test shows a release and the deadline both end step 2. A test releases the generation between step 2 and step 3 and shows nothing is planned.

**L2c: every live keeper on the turn path** (groups 2d, 2e). §3.5. Gate: the full `swift test`; the recording comparison; a `HashCostBenchmark` smoke run (`HashCostBenchmark.swift:50`).

**L2d: the off executor deleted.** §3.6, and the harness's legacy cells (§5.3). Gate: the full `swift test`; the harness lists 84 cells and runs every one; the in-turn goldens unchanged by this PR.

**Docs, en and zh-TW, by PR:**
- L2a: `docs/core/runtime.md`'s sync deduplication and `syncNow` text (:94–104); `docs/transport/README.md:264`;
- L2b: the settle's cycle (`runtime.md` :434, :444–478); AGENTS.md § Reentrancy drops the freeze settle from its exceptions, and so does the root guide's copy of that section;
- L2c: AGENTS.md's "the legacy tick path" exception becomes "the replay tick path (`.reevaluation` keepers)", until S6;
- L2d: `runtime.md`'s Snapshot Sync Mode and Sync Flow (:41–62), `beginSync`/`endSync` and `isSyncing`; `docs/core/failure-handling.md:58`.

## 5. The harness

### 5.1 The in-turn goldens change in L2a

Every harness sync is `DiffRunner.sync()` → `adapter.syncNow()`. At bf8a2ac2 the 84 in-turn goldens hold 308 records with `turnKind: legacyCycle`, 87 with `syncOnly` and 126 with `tick`. After L2a each `syncNow()` is a sync-only turn. The changes come in three kinds:
1. **The turn kind:** `legacyCycle` → `syncOnly` in those syncs' records.
2. **Tickless positions:** a tickless land's sync-only turn is a turn record (#327), so later turn positions move by one per sync.
3. **Joins that flip earlier:** a `syncNow()` while a join waits now completes it (§3.1). The joiner's JoinResponse and firstSync move into that phase's frames.

The L2a PR carries a check script, run over the old and new goldens. It reports each cell's changes in these three kinds, and every other change on its own. The PR body has the table. A change outside the three kinds needs its own explanation, or it is a bug. Other frames are byte-identical: both paths plan with `runFullSyncPhase` from the same state.

#676 (a flake in `disconnect-during-keeper-join`'s tickless in-turn cell, on the turn kind) is in this area. L2a regenerates the goldens only after #676's fix has merged.

### 5.2 The retired rows

| Row | Retired in | Replacement |
|---|---|---|
| `join-during-sync-cycle-inturn` (`.inTurnOnly`, DS:372) | L2a | Its claim is the latch, which has no in-turn trigger once `syncNow()` is a turn. The join's side moves to `join-during-writer-backlog` (below). |
| `join-during-sync-cycle` (`.legacyOnly`, DS:334) | L2d | `join-during-writer-backlog` on the in-turn cells, added in L2a: a join becomes ready while the writer holds a phase's frames; the deferred phase's retry flips it once. Mutant: drop the retry after the writer drains (LK:5068). |
| `disconnect-sending-join-response` (`.legacyOnly`, DS:182) | L2d | See below |
| `disconnect-sending-initial-sync` (`.legacyOnly`, DS:184) | L2d | See below |

**The two router rows** cover the router's non-flip branch (LR:1123–1156). It is taken when the admission returns `completedInTurn == false`. With every adapter in-turn, that needs an admission that isn't in-turn: the router always passes a response builder (LR:1056), and an in-turn keeper admits in-turn when the adapter holds an expected admission for the session (TA:1968–1976). The one gap is an `expectedAdmissions` miss. The L2d PR settles it:
- **If it shows the miss is unreachable from the router**, the rows are retired on that ground. B3 deletes the branch with the standalone initial sync.
- **If the miss is reachable**, the replacement is a `LandRouter` test whose seam withholds the expected admission (a test hook on the adapter's admission, armed through `HoldPoints`). It runs the disconnect at `.sendingJoinResponse` and `.sendingInitialSync`. Mutants: the removed session's JoinResponse is sent; its firstSync is sent.

### 5.3 Counts per head, the self-check and the protected paths

| Head | Listed (in-turn + legacy) |
|---|---|
| today | 174 (84 + 90) |
| L2a | 174 (84 + 90): six cells added (`join-during-writer-backlog`) and six retired (`join-during-sync-cycle-inturn`) |
| L2b, L2c | 174 |
| L2d | 84 (84 + 0) |

`ran > 0 && ran + replaced == listed` holds at each head. L2d deletes the `.legacy` sync axis, its 90 goldens, the expected differences that name it, and the legacy cells embedded in `DiffSelfCheckTests.swift` (:23, :56, :140).

The harness files are protected paths. Every PR that edits the runner, the scenarios or the goldens (L2a and L2d) is a normal PR to `main`, outside `rewrite/546-*`, with no merge queue (`differential-paths.yml:24` runs on `merge_group`). Its goldens are recorded in the pinned image.

## 6. Gates and the A/B

Every step runs, on the Mac with the slot held:
- `swift build --build-tests`;
- the touched suites;
- the harness (`DifferentialHarnessTests`), quoting its "compared / replaced / listed" line;
- the step's mutants.

CI runs the full `swift test` and the E2E.

**L2a: a host A/B.** It measures EncodingBenchmark's driver path: its measured loop calls `syncNow()` (30 calls), which moves from the adapter's cycle to a keeper job. Production's periodic sync already runs `runSyncOnlyTurn`, so this sets that tool's new baseline rather than measuring a production change. Base against L2a, both built from the pinned image, on the measurement host. The cell list is fixed with Main before the run, as B0's was (#655 §5.1), with MessagePack and JSON included.

**L2b–L2d: a Mac output check.**
- L2b: the freeze frames and records (`freeze-resume-messagepack` byte-identical).
- L2c: the recording comparison (§3.5), and a `HashCostBenchmark` smoke run.
- L2d: the harness, with the in-turn goldens unchanged.

## 7. Public API

The adapter is `package` since E, so `syncNow()`, `syncBroadcastOnly()` and the `inTurnSync` parameter are already outside the public surface. Decided (Q1 (a)): the public breaks go with no deprecation. The full list:
- **L2a:**
  - `TransportAdapterBenchmarkHandle.syncNow()` keeps its signature; its behavior changes (§3.1).
  - `SyncSkipCounts.busy` (a public field and init parameter, `TransportAdapter+Outbound.swift:235–245`) is removed. Both `MeasuredSync.swift`s stop reading it.
  - The profiler's `syncSkipsBusy` JSONL field (`TransportProfilingActor.swift:595`) stays, always `0`, so the profile format doesn't change: `ws-loadtest/src/server-sync.ts:14` requires it, and old and new profiles parse alike. `METRICS.md:136` says it is always 0 since L2. Dropping it would be a format change for its own PR, with ws-loadtest and its test (`tests/server-sync.test.ts:14`) changed together.
- **L2b:** none. The settle's entry point is the keeper's package `debugSettleTurn` (§3.4). `LandKeeperTransport.runSyncPhaseInTurn` (LKT:178–183) doesn't change.
- **L2c:** `LandKeeper.isUsingInTurnSync()` keeps its signature and answers `syncsInTurn` (§3.5).
- **L2d:**
  - `LandKeeper.beginSync(clearDirtyFlags:)`, `endSync()` and `endSync(clearDirtyFlags:)` are removed.
  - `TransportAdapterBenchmarkHandle.inTurnSyncEnabled` (`TransportAdapterBenchmarkHandle.swift:59`) is removed. EncodingBenchmark writes `true` in its place in the record metadata (`EncodingBenchmarkMain.swift:158–159`), so records keep their shape.
  - `LandKeeperTransport.syncNowFromTransport()` and `syncBroadcastOnlyFromTransport()` stay as requirements with do-nothing defaults (§3.5). #612 S6 removes them.

Each PR's body restates its items.

## 8. Decisions by the maintainer (2026-11-20)

**Q1. The public removals (§7).** *Decided: (a).*
- (a) Remove them in L2, with no deprecation. Nothing calls them after L2, and there are no external users (2026-11-18).
- (b) Deprecate them in L2 and remove them later. They would stay as no-ops or traps, with a test each, until the removal.

The list is §7's. It covers `LandKeeper.beginSync`/`endSync` (both overloads), `SyncSkipCounts.busy`, and `TransportAdapterBenchmarkHandle.inTurnSyncEnabled`. `LandKeeperTransport`'s two sync requirements move to #612 S6 under the same rule. The profiler field stays (§7).

**Q2. `syncBroadcastOnly()` (§3.3).** *Decided: (a).*
- (a) Delete it. Its callers use `syncNow()`, which runs the full phase, as an in-turn broadcast-only request already does (LK:637–640). The broadcast-only plan goes with it.
- (b) Keep it as a broadcast-only sync-only turn: a phase that diffs broadcast fields only and keeps the dirty flags.

**Q3. Where the predicate split lands (§3.5).** *Decided: (a).*
- (a) In L2c, with #612's names (`routesThroughTurn`, `syncsInTurn`). #612 S2 takes the split as given and adds its `.record` keepers to `routesThroughTurn`.
- (b) In #612 S2, with L2c after S2. L2 would wait on S2, which waits on S1, #521's remaining PRs and #606.

Main settles the rest: the A/B cells (§6), and where L2a–L2d sit among the other open work.

## 9. The inputs from #655, and where each is settled

| Input (#655 rev 13, §3.2) | Here |
|---|---|
| The in-turn goldens change in 2b: account for each cell's record and frame changes | §5.1 |
| Each retired row needs a replacement invariant and a mutant; the remaining legacy cells, `DiffSelfCheckTests`' embedded cells and the protected-path route need a disposition | §5.2, §5.3 |
| The keeper side: `syncNowFromTransport`, `syncBroadcastOnlyFromTransport`, `beginSync`/`endSync` and their overloads, the latch | §3.5, §3.6 |
| Broadcast-only semantics: it keeps the dirty flags and can upgrade to a full plan | §3.3 |
| The freeze settle: it commits while the ordinary phase defers; decision 2's keeper-lock protocol and the coalescing "after `endSync`" | §3.4, §3.7 |
| The fixture-mediated off callers | §2, §3.6 |
| The tickless behind-commit follow-up; its `.legacyCycle` recorder tag | §3.2, §1 |

## 10. Risks

- **A join flips in a different phase in L2a.** A test that counts frames after `syncNow()` while a join waits sees the join's frames sooner. §5.1's script finds them in the harness; elsewhere the full `swift test` does, and the PR lists each converted assertion.
- **The 2e keepers' tests assume the off path's order.** For example, a test that awaits an action's result before its handler's effects are visible: the turn path resumes a waiter after the turn record is submitted (LK:5381–5393). L2c's PR runs these suites with the change before converting anything, and lists the failures.
- **A requested turn lost to coalescing.** One pending flag serves five callers (§3.2). A request made while one is pending must still be served by that turn, which runs after the request. The L2a PR tests a request that arrives while a delayed repair is pending: the earlier turn must not drop it.

## 11. Rev 2: what changed

| Change (from #680's review) | Where |
|---|---|
| The order is L2a ∥ L2b → L2c → L2d, green at each head: the latch row and the in-turn `SyncCycleHold` callers handled in L2a; the transport requirements, `beginSync`/`endSync`, `isSyncing` and the latch kept until L2d (MF1) | §3.5, §3.6, §4, §5.2 |
| The no-port turn path: optional transport in the tick and input turns, outputs recorded whatever the delivery, initialize's marker on `recordsSyncStream`, each of the 22 sites with its predicate; the sync-stream gate (LK:4881) and the state-hash gate kept apart; the recording comparison is decoded equality plus a 0-mismatch replay, and raw bytes may differ (MF2, Code-2's correction) | §3.5 |
| The fakes that hold inside async calls, the fakes on `.reevaluation` keepers and `ReleasedLandTransport`: each with its disposition; the two transport requirements stay until #612 S6 (MF3) | §3.5, §3.7 |
| The settle: a fence in one synchronous segment, the epoch read there, its own phase (no joiners, no back-pressure deferral, the empty-land copy), the bounded writer wait kept, its record tag kept (MF4) | §3.4 |
| One rule for pending sync work, its entry point and pending flag, the kept-event and out-of-turn-event cases, the behind-commit repair's own path, the test wait and DR's three waits (MF5) | §3.2 |
| The API list completed: `inTurnSyncEnabled`, `SyncSkipCounts.busy`, the profiler field kept at 0, the settle's entry point (MF6, should 7) | §7, §8 |
| The router rows' reachability argument or seam, counts per head, `DiffSelfCheckTests`' PR, the protected-path route for L2a and L2d (MF7) | §5.2, §5.3 |
| §2's inventory completed: the off arms, the direct `beginSync`/`endSync` callers, the second conformers, `ReleasedLandTransport` (should 1) | §2 |
| `isUsingInTurnSync()` answers `syncsInTurn` (should 2) | §3.5, §7 |
| Docs assigned to PRs, AGENTS.md's exceptions (should 3) | §4 |
| Hand-offs to B2 and #612; a live keeper's `OnSync` with no port (should 4) | §3.5, §3.7 |
| A/B: L2a sets EncodingBenchmark's baseline; L2b–L2d get a Mac output check (should 5) | §6 |
| The cadence smoke keeps its on leg (should 6) | §3.6 |
| Nits: one counting rule with file lists, pointers (TA:2902, :2913, :3215), group and PR names kept apart, the keeper's test wait named | §2, §3 |
| The maintainer's Q1–Q3 recorded as decided | §8 |
