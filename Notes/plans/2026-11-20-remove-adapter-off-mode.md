# Remove the adapter's off mode on live lands (#546 L2)

**Status:** rev 4, plan only, for review. No code until this plan is GO. L1 (#677) is merged (7a462bd1).
- **Decided (the maintainer, 2026-11-20):** §8's Q1 (a), Q2 (a) and Q3 (a).
- **Pending the maintainer:** the shape of a requested sync turn (§3.2): an entry point with a pending flag, or a keeper input that carries its reason and a ticket, validated in the turn (B2's shape for the adapter's other callbacks). The behaviors §3.2 requires hold either way.
- **Rev 4** answers rev 3's review (#680: 3 must-fix, 5 should, 3 nit). What changed is in §11; rev 3's and rev 2's changes follow it.

**Issue:** #546, step L2 of `2026-11-19-adapter-turn-core-rewrite.md` (rev 13). That plan holds L2's placeholder (§3.2, groups 2a–2e) and the "Inputs to L2's own plan" block; §9 here maps each input to the section that settles it. "Group 2a"–"2e" name #655's groups; "L2a"–"L2d" name this plan's PRs.

**Base:** `main` at bf8a2ac2 with L1 applied. Pointers are at bf8a2ac2:
- "TA" is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`;
- "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`;
- "LKT" is `Sources/SwiftStateTree/Runtime/LandKeeperTransport.swift`;
- "LR" is `Sources/SwiftStateTreeTransport/LandRouter.swift`;
- "DS" is `Tests/SwiftStateTreeNIOTests/Differential/DiffScenarios.swift`; "DR" is `DiffRunner.swift` beside it.

**Related:** #612 (`2026-11-20-replay-on-turn-core.md`) is parked. It owns what `.reevaluation` keepers reach (S2, S6). §3.5 draws the line, and §3.7 lists what #612 takes over when it resumes. L2 doesn't wait on it.

## 1. Goal and end state

**Goal.** Every sync on a live land runs in one of the keeper's turns. The adapter no longer runs a sync cycle of its own.

**End state after L2:**
- The adapter has one sync path: the in-turn phase, called by the keeper inside a turn. `withSyncState`, `_syncNowImpl`, `_syncBroadcastOnlyImpl`, the backlog and busy retry, the adapter's executor host and the `inTurnSync` init parameter are gone.
- The keeper has no `beginSync`/`endSync`, no `isSyncing` flag, no latch that reruns a sync-only turn after a legacy cycle, and no live legacy pass (§3.6).
- Every live keeper runs its inputs through turns, with or without a transport.
- The harness has no legacy cells. Its in-turn goldens record what the in-turn path does for every sync a scenario asks for.

**Unchanged by L2:**
- The standalone initial sync (`_syncStateForNewPlayer`, TA:5586) and its re-checks: the ticket, the player binding, the output gate and the commit epoch. It stays until B2 (`.initialSyncCommit`) and B3 (membership). Its recorder tag `.legacyCycle` stays (`ReevaluationSyncStream.swift:19`).
- What `.reevaluation` keepers reach: `processPendingActions`, `replayRecordedPasses`, the replay broadcast calls (LK:3802, :4516), the sync loop's transport call (LK:5564), and `LandKeeperTransport`'s `syncNowFromTransport`/`syncBroadcastOnlyFromTransport`, kept with do-nothing defaults (§3.5). `LandKeeperReevaluationOutputModeTests` keeps its `.reevaluation` keepers.
- Frames on the default production path. A server built from `main` already runs in-turn, and production's periodic sync already runs `runSyncOnlyTurn`.

## 2. Who reaches the off mode after L1

Counting rule: executable call sites, not comments; conformers per declaration and per keeper mode. Each PR's body lists its files.

**The adapter's own syncs on an in-turn land** (group 2a): the kept-event follow-up (TA:3153, :5269, `startFollowUpSync` TA:3161), the backlog and busy retry (`deferSyncForOutboundBacklog`, TA:3197–3216), the lag timer's sync (TA:3603, `runSyncLagTimerSync` TA:3620), and the behind-commit repair (`startDelayedFollowUpSync`, TA:3185, called at TA:5655).

**`syncNow()` and `syncBroadcastOnly()`** (group 2b, `TransportAdapter+Sync.swift:4–10`). They run the adapter's cycle even on an in-turn land.
- `syncNow()`: 127 calls in `SwiftStateTreeTransportTests` (35 files), 3 in `SwiftStateTreeTests`, 3 in `SwiftStateTreeNIOTests` (2 files, `DR` among them), 6 in `SwiftStateTreeBenchmarks`, 30 in EncodingBenchmark (`BenchmarkExecution.swift`, `EncodingBenchmarkMain.swift`, `RouterJoin.swift:271`), one in each Examples `SyncTablesFrameIdentityTests`, and `TransportAdapterBenchmarkHandle.syncNow`.
- `syncBroadcastOnly()`: 17 direct calls in nine `SwiftStateTreeTransportTests` files: `PerPlayerSyncTablesScenarioTests` (3), `TransportAdapterSyncConcurrencyTests` (3), `TransportAdapterOrderedSendTests` (2), `TransportAdapterPendingEventsAcrossCyclesTests` (2), `TransportAdapterSyncBackPressureTests` (2), `TransportAdapterSyncPhaseTests` (2), `TransportAdapterDebugFreezeTests`, `TransportAdapterSyncDirtyWindowTests` and `TransportAdapterSyncLagTests` (1 each).
- The broadcast-only cycle has three internal callers besides the entry point: `syncBroadcastOnlyFromTransport` (`TransportAdapter+LandKeeperTransport.swift:19–21`), which a legacy keeper calls on every leave (LK:645, :3876); `runBacklogDeferredSync` (TA:3244); and the resume (TA:6642).

**The cycle hold on in-turn adapters.** `SyncCycleHold` (`TransportTestHelpers.swift:80–87`) arms `.cycleBeforeEndSync` and spawns `syncNow()`. In-turn callers: `TransportAdapterPendingEventsAcrossCyclesTests` (:297, :646–710, :826–1018), `TransportAdapterTargetedEventOnceTests` (:81, :167), `TransportAdapterSyncBackPressureTests` (:159), `TransportAdapterSyncDirtyWindowTests` (:166, :228) and `TransportAdapterInTurnSyncTests` (:893). The harness row `join-during-sync-cycle-inturn` (DS:372, built by `syncCycleRow`, DS:66–90) does the same, and so does `DiffLeaveTurnTests.heldCycleMovesTheLeaveSync` (#678, which lands before L2a): it holds an in-turn legacy cycle at `.cycleBeforeEndSync` over the leave's turn and asserts the latch path (a sync-only turn after `endSync`).

**The legacy cycle's witnesses.** `join-during-sync-cycle` (`.legacyOnly`, DS:334–361) arms and reaches `.busyRetry`, arms `.followUpSynced` in its MessagePack cell, and asserts `syncDeferredByCycleCountForTesting == 1`, which reads `syncSkips.busy` (TA:3311, :3553). The off case in `TransportAdapterInTurnSyncTests.swift:927–937` asserts the same count.

**The freeze** (group 2c): the settle's `beginSync` loop (TA:6546–6610) and the resume's replay (TA:6639–6643). Both modes use it until L2d.

**Keepers whose transport doesn't opt in** (group 2d). Per declaration, leaving out `TransportAdapter`, there are 28 conformers in 20 files, 11 of which opt in (`LandFailureTests:92` and `TicklessActionJobTests:130` among them). The rest, by keeper mode:
- live, not opting in: the conformers in `LandKeeperDebugFreezeTests`, `ReplaySequenceWatermarkTests`, `SyncRegistrationTests`, `ActionEventSyncTests`, `LandDSLTests`, `ResolverDeadlineTests`, `InitializeResolverFailureTests`, `MockLandKeeperTransport`, `DestroyHoldTransport` (`DrainTurnTests.swift:281`), `BroadcastSpyTransport` (`PerSequenceResultTests.swift:200`), the second conformers in `DrainTurnTests` and `ResolverDeliveryTests`, and `PassSyncCountingTransport` and `PassDeliveryLogTransport` (`TicklessReplayPassTests` :164, :174), the transports of its two live tests (:451, :484);
- `.reevaluation`: `LandKeeperReevaluationOutputModeTests` (:41; its :104 is the `mode: .reevaluation` argument). The replay keeper builder of `TicklessReplayPassTests` (:278–291) passes no transport;
- the library's `ReleasedLandTransport` (LKT:351), the teardown placeholder.

The L2c PR prints the census from a script, so the counts are checked, not hand-kept.

**Live keepers with no transport** (group 2e): about 19 `SwiftStateTreeTests` files, `HashCostBenchmark.swift:50`, and `ReevaluationRunner/main.swift:452` (a live keeper that records a game).

**Explicit off callers** pass `inTurnSync: false`, directly or through a fixture:
- the harness's legacy cells (`DiffRunner`, after the configuration's init since L1);
- the pinned `LandRouterJoinAttemptTests` (L1);
- direct: `AtomicPatternIndexAdapterTests` (1), `InitialSyncBehindCommitTests` (1), `LandReleaseTests` (1), `RowAddressingAdapterTests` (:441–551, :882), `TransportAdapterPendingEventsAcrossCyclesTests` (2), `TransportAdapterSyncLagTests` (4);
- through a fixture or a case list: `SyncStreamProducerTests.swift:286`, `TransportAdapterInTurnSyncTests.swift:928` and :987, `SyncStreamInitializeRecordTests.swift:144`, `TicklessPassOrdinalTests.swift:551`, every arm of `TransportAdapterNewestWinsTests`, `TransportAdapterRegisterSessionTests.swift:58` (its fixture defaults to `false`) with its `[true, false]` cases, `TransportAdapterInitialSyncStaleReadTests` (:99, :302, :326), `ActionJobReplayOrderTests` (:160–173), `RecordTurnBoundaryLiveTests` (:97), `LandKeeperInputTurnTests` (:222, :595, :616), `TransportAdapterJoiningAdmissionTests` (:114, :143, :186, :233, :253, :274, :302, :326), and `WallClockCadenceSmokeTests.swift:25` (`inTurn: [true, false]`).

**Direct `beginSync`/`endSync` callers:** `LandKeeperSyncLockTests` (:74, :115), `TransportAdapterOrderedSendTests.swift:575`, `SyncStreamProducerTests.swift:543`, `TransportAdapterSyncDirtyWindowTests.swift:273`.

**Other readers of the off mode:** `LandManager` reads `inTurnSyncEnabled` for `recordsSyncStream` and the sync configuration (`LandManager.swift:700–701`); EncodingBenchmark reads `TransportAdapterBenchmarkHandle.inTurnSyncEnabled` (`EncodingBenchmarkMain.swift:158–159`).

## 3. Decisions

### 3.1 What `syncNow()` becomes (groups 2a, 2b)

*On an in-turn adapter, `syncNow()` runs one sync-only turn on the keeper now, and returns after it. On an off adapter it runs the cycle, as today, until L2d.*
- The keeper gets a package entry point, `syncTurnNow() -> InTurnSyncResult`. It runs `runSyncOnlyTurn` (LK:5039) in a single keeper job and returns the phase's result. The adapter shares the keeper's executor when it runs in-turn (TA:111, :973), so no other turn runs between the request and the turn.
- What it returns: `.committed` when the phase committed (its frames are with the writer); `.skipped` when nothing was planned (no members, a failed land, frozen, or the keeper's `isSyncing` held by a legacy cycle, when the latch reruns it after `endSync`); `.deferredBackPressure` when the writer held an earlier phase, with the keeper's one retry pending (LK:5068); `.failed` or `.landFailed` when the phase ended the land. The caller that needs a retry's frames awaits the test wait (§3.2).
- Between L2a and L2b the in-turn settle still takes `beginSync` (§3.4), so a turn requested during a settle meets `isSyncing`: it sets the latch and returns `.skipped`, and the latch's turn runs after the settle's `endSync`.
- No fold. The sync loop folds a sync into a tick due within the coincident-sync window (LK:5539–5557). An explicit `syncNow()` is a test's or a benchmark's request for a sync at that point, so it runs at once.
- No busy outcome on the in-turn path. A sync-only turn is synchronous, so a request can't meet one in flight.

What changes for an in-turn caller:
- **A ready join flips.** The in-turn phase completes ready joins (TA:2913–2919); the legacy cycle passed none (TA:3150). A `syncNow()` while a join waits now sends that join's JoinResponse and firstSync in this phase.
- **A tickless land records a turn.** Its sync-only turn is its own turn record (LK:5054–5056, #327).
- **The record's turn kind** is `syncOnly` where it was `legacyCycle`.

§5 accounts for these in the harness. Outside it, the L2a PR lists each converted assertion.

### 3.2 Pending sync work: one rule

*Rule: whenever sync work is due outside a turn on an in-turn land without periodic sync, something asks the keeper for a sync-only turn. No flag waits for an adapter cycle to read it.* On an off adapter the legacy follow-up and retries stay until L2d.

**Shape: pending the maintainer.** Two shapes meet the rule:
- (a) a keeper entry point, `requestSyncTurn()`, with one pending flag;
- (b) a keeper input, `.syncTurnRequest(reason, ticket)`, whose handler validates the ticket in the turn and runs the sync-only turn. This is the shape B2 gives the adapter's other callbacks: one place to inspect, and one thing to hold in tests.

Main has taken the choice to the maintainer. Rev 4 records the answer. Everything below holds for both.

**When a requested turn runs.**
- It runs at once, not at the next tick. On a hand-stepped tick land (`autoStartLoops: false`, so `hasPeriodicSync` is false, LK:1399), which the harness, `InitialSyncBehindCommitTests` and `TransportAdapterSyncLagTests` use, it still runs when requested. In shape (b) the `.syncTurnRequest` input is handled at once, is never a tick input and is never recorded as one. Its ticket is the keeper's own; the lag timer's epoch stays private to the adapter (TA:378).
- **From outside the keeper** (the adapter: the lag timer, the repair, an out-of-turn event, the resume), the request is one keeper job that runs the sync-only turn before it returns, unless one is already pending. So the resume awaits its requested turn before it asks for the join-sync turn (§3.4).
- **From inside a turn** (caller 1 below, in `applyInTurnSyncResult`), a turn can't run inside a turn. The request marks itself pending, and a keeper job runs it after the current turn.
- A request made while one is pending coalesces: the pending turn hasn't run yet, so it covers the later request's work. A request made during a requested turn arms a new one.
- It is skipped on a failed land (LK:5042) and while the keeper drains. `runSyncOnlyTurn` checks only the failure and the latch (LK:5039–5046), so the requested-turn runner adds `guard !isDraining` (LK:532), as `runJoinSyncTurn` has (LK:5102). The other callers of `runSyncOnlyTurn` are unchanged. A skipped request clears its pending state and wakes `waitForRequestedSyncTurnsForTesting()`, so the wait never hangs on a failed or draining land.
- **While the land is frozen**, a requested turn runs, and its phase defers as any phase does then (`debugDeferSyncIfFrozen`, TA:2902): it sets the resume's deferred sync and plans nothing. So a request made during a freeze is served by the resume, never dropped.

**Delays and holds stay on the adapter.** The keeper's request is immediate only. A delayed caller waits on the adapter's side, in a background Task, then requests:
- **The behind-commit repair** (TA:5655): sleep `syncFailedPlanFollowUpDelay`, `await holds.at(.failedPlanFollowUp)`, then request. The hold is an `AdapterHoldPoint` (TA:19) and stays one.
- **The lag timer** (TA:3603): in `syncLagTimerPass`'s segment, check the epoch (`syncLagTimerEpoch`, TA:378, private to the adapter), then spawn the request. `runSyncLagTimerSync`'s hold `.syncLagTimerSync` (TA:38) stays before the request, with the epoch re-checked after it.

So an immediate request never waits behind a delayed one, and a delayed one never loses its delay or its hold by coalescing into an immediate one. A delayed repair that finds its work done (an immediate turn ran meanwhile) still requests its turn: one extra sync-only turn, which sends nothing when nothing is dirty.

**The callers on an in-turn land** (callers 1–4 are on lands without periodic sync; the resume, caller 5, isn't limited to them: `debugReleaseFreeze` has no such guard, TA:6639):
1. **Kept events after a commit.** The phase reports whether events are still queued after its commit (kept by it, or queued after it). The signal is a package field on `InTurnSyncOutput`, `keepsEvents`, set by the adapter's package init. `InTurnSyncResult` and the public init don't change. In `applyInTurnSyncResult`'s `.committed` case, `keepsEvents && !hasPeriodicSync` requests one sync-only turn. This is the legacy follow-up's rule (TA:3279–3286). A phase that ends the land requests nothing.
2. **An event queued outside a turn.** `sendEvent` outside a phase on a land without periodic sync queues a merged event that only a phase delivers (opcode 107). The adapter requests a sync-only turn when it queues one. An immediate send needs none.
3. **The lag timer**, as above.
4. **The behind-commit repair**, as above. The standalone firstSync it follows keeps its re-checks (§1).
5. **The settle's kept events** and **the resume's deferred syncs** (§3.4).

The writer-drain retry (LK:5068) and the join-budget follow-ups (`scheduleJoinSyncTurn`, LK:5089) stay as they are.

**Test waits.** The keeper gets `waitForRequestedSyncTurnsForTesting()`. It returns when no requested turn, writer-drain retry or join-sync turn is pending, each counted until its turn has run and handed its frames to the writer. The adapter's waits cover its side:
- `waitForSyncQuiescenceForTesting()` (`TransportAdapter+Outbound.swift:171–191`) loops until both its own background tasks (now the delayed repair and the lag timer's request) and the keeper's wait are idle, then waits for the writer. Its callers: `InitialSyncBehindCommitTests` (:122, :162), `TransportAdapterSyncLagTests` (:394, :472), `TransportAdapterSyncDirtyWindowTests` and `JoinPendingInboundTests` (:473, :488);
- DR's three waits use both: the sync step (DR:573–576), `.settleSpawned` (DR:352–357) and the barrier's sync quiescence (DR:598–616).

Rejected: keeping `syncNow()` as an adapter cycle that runs inside a keeper job. It would keep a second sync entry, which B2 would then have to model.

### 3.3 `syncBroadcastOnly()` (group 2b): the entry point goes in L2a

Decided (Q2 (a)). L2a deletes the entry point (`TransportAdapter+Sync.swift:8–10`) and converts its 17 calls to `syncNow()`, or deletes the ones that assert the broadcast-only plan itself (kept dirty flags, no per-player patch). The L2a PR lists each with its fate.

The broadcast-only cycle stays inside the off adapter until L2d. With the entry point gone, its internal callers call `_syncBroadcastOnlyImpl()` directly: `syncBroadcastOnlyFromTransport` (`TransportAdapter+LandKeeperTransport.swift:20`) and `runBacklogDeferredSync` (TA:3244), as the resume already does (TA:6642). Its three internal callers (§2) serve the legacy cells: forwarding them to a full cycle would clear dirty flags, add per-player diffs and treat an empty land differently (TA:5238, :5276), and the legacy goldens would change. L2d deletes `_syncBroadcastOnlyImpl` and `planBroadcastOnlySyncPhase` (TA:5232, :5279) with the off adapter.

On an in-turn land a broadcast-only request already runs the full phase (LK:637–640). The keeper's `requestSyncBroadcastOnly` (LK:422) stays as handler API: "a sync in this turn".

### 3.4 The freeze settle (group 2c)

#655 decision 2 keeps the whole freeze on the adapter through B2, the settle included. L2b keeps that, and replaces the settle's keeper-lock protocol with one keeper job on an in-turn adapter. An off adapter keeps today's settle and resume until L2d: it has its own executor (`ownExecutorHost`, TA:103–111), where the in-turn settle's `assumeIsolated` would trap.

**Steps, in-turn:**
1. **Drain**, as today: `keeper.debugFreeze(generation:timeout:)` (LK:1459).
2. **Wait for the writer**, as today: the bounded loop (TA:6556–6561), which checks the deadline and `debugIsCurrent(generation)` on each pass. `waitForSyncCycleDrain` (`OutboundWriter.swift:260–270`) has no deadline or cancellation, so it isn't used.
3. **Commit, in one synchronous segment on the keeper.** The keeper gets `debugSettleTurn(generation:deadline:_:)`, a package entry point that takes a closure from the adapter. The closure runs the adapter's code through `assumeIsolated`, as `runSyncPhaseInTurn` does. `LandKeeperTransport` doesn't change. In that segment, in this order:
   - **The fence.** The keeper checks that the deadline hasn't passed, that `generation` is still active and the keeper still frozen, and that it isn't draining or shutting down. The adapter's closure checks `debugIsCurrent(generation)` and that the output gate is open. Any failure returns "released", "timed out" or "closed", and nothing is planned.
   - **The membership epoch** is read here, in the same segment as the copy.
   - **The phase** is the settle's own. It passes no joiners, as today (TA:6572). It ignores writer back-pressure, as today: step 2 waited, and a frame that entered the writer since doesn't defer the settle. On an empty land it takes the copy without clearing dirty flags and plans nothing (TA:6568–6573). Otherwise it plans and commits the full phase, clearing the flags when dirty tracking is on.
   - **A plan failure** closes the output gate in this segment and returns the failure. The adapter then submits it with `keeper.submitLandFailure`, as today (TA:6585–6587), so the failure reaches the keeper as an input, at today's recorded position and prefix.
   - It returns the state copy, the committed tick, the epoch and `keepsEvents`.
4. **Publish** after the call, with the generation checked again (TA:6592–6604).

**The record.** The settle records its sync output under `.legacyCycle`, as today, with the same position source. So `freeze-resume-messagepack` (`SyncOutputGoldenTests.swift:21–22`, :47, :96) stays byte-identical. A new turn kind would be a record-format change.

**The resume** (TA:6614–6650), in this order: first the deferred sync, as one requested sync-only turn (§3.2); then the join-sync turn request, as today (TA:6646–6648). The requested turn's phase flips ready joins itself, so the join-sync request then finds none waiting and does nothing. If the requested turn is deferred by back-pressure, the writer-drain retry flips them. A test covers deferred output and a ready join across one resume.

**The settle's tests, in L2b:**
- `eventKeptBySettleArrivesAfterResume` and `leaveDuringSettleSendsFlagsMembership` (`TransportAdapterPendingEventsAcrossCyclesTests` :1020–1057) arm the cycle hold and wait for the settle to reach it. They move to a new adapter hold, `.settleBeforePublish`, after `debugSettleTurn` returns and before step 4. The segment itself is synchronous and can't hold, and a hold before it would invert both tests: a leave before the copy gives the settle the epoch after the leave, and an event queued before it would go out in the settle's phase while frozen. After step 3, the leave flags `membershipChanged`, and the event takes §3.2's caller 2 during the freeze: its requested turn defers and sets `deferredSyncNow`, so it is delivered once, after the resume.
- `settleRetriesUntilBeginSyncAccepts` and `releasedBeforeSettleFinished` (`TransportAdapterDebugFreezeTests` :297, :454) build a busy `beginSync`. The first is retired for the in-turn adapter (there is no busy outcome) and kept for the off adapter until L2d. The second moves to a release between step 2 and step 3.
- The gate also runs `TransportAdapterSyncBackPressureTests:275` (the writer-backlog settle) and `SyncOutputVerifierTests:1541` (the failed-plan settle).
- New tests: a release and refreeze, a shutdown, and the deadline's expiry, each between the last writer check and the commit; nothing is planned in any of them.

#655's decision 2 text, §3.4's coalescing "after `endSync`" and `.cycleBeforeEndSync` "before the settle's `endSync`" are then rewritten against this shape (§3.7).

### 3.5 Every live keeper on the turn path (groups 2d, 2e)

`usesInTurnSync` (LK:672) answers two questions at once: whether inputs run through turns, and whether the sync phase runs in them. Decided (Q3 (a)): L2c splits it, with #612's names.
- **`syncsInTurn`**: `mode == .live` and a transport is attached and opts in (`runsSyncPhaseInTurn(of:)`). It keeps the mode term, so `isUsingInTurnSync()` and `recordsSyncStream` keep their behavior.
- **`routesThroughTurn`**: inputs go through turns.

**"No port, ever" is told by how the keeper is built, not by timing.** A keeper starts its initialization in its init (LK:988–991), with no transport. `LandManager` attaches the port only after several awaits, behind the `.wiring` hold (`LandManager.swift:703–716`, `setTransport` at LK:467). So `transport == nil` also means "not attached yet", and a rule on it would make OnInitialize a turn with no port, whose events are taken and never delivered. It would also flip the predicate at the attach, against LK:668's "fixed once the transport is set".

So L2c adds a keeper init parameter, `portless: Bool = false` (#612 rev 4 proposes the same parameter for its builder):
- `portless: true` means the keeper never gets a port. The 2e sites pass it: the `SwiftStateTreeTests` keepers that run with no transport, `HashCostBenchmark.swift:50` and `ReevaluationRunner/main.swift:452`. `setTransport` on a portless keeper is a precondition failure.
- `portless: false`, the default, means a port may come. Until it is attached the keeper behaves as today: initialization isn't a turn (`initializeIsTurn` is false, LK:1193), and its outputs stay in the collector for the first delivery.

The rule:
- **L2c:** `routesThroughTurn` is `mode == .live && (portless || syncsInTurn)`. A portless keeper moves onto turns. A keeper behind a transport that doesn't opt in (an off adapter above all) keeps the legacy path, and so does a keeper whose port isn't attached yet. So the 90 legacy cells, the holding fakes and the non-portless keepers with `transport: nil` don't change.
- **L2d:** `routesThroughTurn` is `mode == .live && (portless || transport != nil)`. Every attached port then opts in. Before the attach, a keeper's initialization stays as today, which isn't the off mode: it holds outputs for the first delivery.

**L2c's gate gets the attach test:** with the `.wiring` hold held, an event OnInitialize emits before the attach must reach the first frame, on an in-turn cell and on a legacy cell.

**The turns with no transport** (L2c):
- `runTickTurn` (LK:4705–4708) takes `transport: (any LandKeeperTransport)?`. With none, it applies the inputs, runs the tick handler, takes the emitted events and the sync request, and records them in the turn record. It calls no phase.
- `runInputTurn`'s output branch (LK:5442–5446) takes the emitted events and the sync request whenever the batch is non-empty and the land hasn't failed. It calls `runTurnOutputs` only when `syncsInTurn`. So `makeTurnRecord` records the turn's events whatever the delivery.
- **Initialize** (LK:1193–1211) runs as a turn when `routesThroughTurn`. OnInitialize's events and sync request are taken inside the turn, after its record is built, with or without a port; only the phase waits on `syncsInTurn`. The initialize marker is emitted only when `recordsSyncStream`, so a keeper with no port writes no marker without a stream.
- `OnSync` with no port: the sync loop runs it as today (LK:5509–5530), read-only, and nothing follows it.

**The 22 sites**, each with its predicate:

| Site | Predicate |
|---|---|
| handler sync requests LK:637 | `syncsInTurn` (a sync-only turn needs a port) |
| `isUsingInTurnSync()` LK:859 | `syncsInTurn` |
| initialize LK:1193 | `routesThroughTurn` for the turn; the drain inside it whatever the port; the phase on `syncsInTurn`; the marker on `recordsSyncStream` |
| join LK:1651, :1889 | `routesThroughTurn` |
| the join admission helpers LK:1903–1924 | `syncsInTurn` (they call the port) |
| actions LK:2202, :2909 | `routesThroughTurn` |
| leave LK:2585 | `routesThroughTurn` |
| the forced tickless shutdown LK:2657 | `routesThroughTurn` |
| client events LK:3046 | `routesThroughTurn` |
| server input LK:3153 | `routesThroughTurn` |
| tick LK:4250, :4300 | `routesThroughTurn`; the phase inside on `syncsInTurn` |
| `recordsSyncStream` LK:4881 | `mode == .live && reevaluationRecorder != nil && syncsInTurn` |
| `runSyncOnlyTurnIfInTurn` LK:5062 | `syncsInTurn` |
| tickless turns LK:5442 | `routesThroughTurn`; the phase on `syncsInTurn` |
| the periodic sync loop LK:5539 (`runSync`) | `syncsInTurn` |

**Recording.** LK:4881 is the sync-stream gate. The state hash's gate is `enableLiveStateHashRecording && reevaluationRecorder != nil` (LK:4741, :4555; the initialize record at :4844); it has no transport term and doesn't change. `ReevaluationRunner/main.swift:452` records with no port. Today it runs the legacy `runTick` (LK:4503, :4555–4581), which writes its record through separate calls (`record`, `setStateHash`, `recordServerEvents`). On `runTickTurn` it writes one turn record per tick. So the raw bytes may differ.

The comparison that must hold, for a tick land and a tickless land, each with initialize and a land-failure prefix:
- decoded equality of the inputs, the state hashes, the events and the watermarks, old record against new;
- the new record replayed through today's verifier, with 0 mismatches.

It runs on a controlled schedule: inputs submitted between steps, and no input held across one. The legacy path captures W2 after its suspending input path, and the turn path in the apply segment, so an input held between them can cross the boundary. One case holds an input there on purpose, and the PR records the expected watermark difference for it.

**`isUsingInTurnSync()`** (LK:858, public) answers `syncsInTurn`, which keeps today's answer: `false` with `transport: nil`. The tests that assert it (`PerSequenceResultTests:227`, `ResolverDeliveryTests:271`, `TwoPhaseHandlerTests:200`, `DrainTurnTests:388`, :418, `ShutdownTurnTests:215`) keep their assertions.

**The fakes in L2c.** A live fake whose test doesn't depend on the legacy path's order opts in: `runsSyncPhaseInTurn` → `true`, and a `runSyncPhaseInTurn` that records what the test needs (`.notRequested` when it records nothing). The L2c PR lists each with its fate, including `DestroyHoldTransport` (`DrainTurnTests.swift:281`) and `MockLandKeeperTransport`'s broadcast-only assertions on OnLeave (`TransportAdapterBroadcastOnlySyncTests.swift:20–116`), whose claim becomes "OnLeave's sync runs in its turn".

**Fakes that need the legacy path's order stay on it until L2d,** under the transitional rule:
- fakes that hold inside an async call to keep a legacy tick in flight: `DebugFreezeGatedKeeperTransport` (`LandKeeperDebugFreezeTests.swift:134`, :206–230), `BroadcastHoldTransport` (`DrainTurnTests.swift:160`, :333), `HoldingTransport` and `BroadcastHoldingTransport` (`ResolverDeliveryTests.swift:229`, :249, :420, :491);
- the two live keepers of `TicklessReplayPassTests`: `legacySyncRequestStaysWithItsPass` (:451, holds at `.turnRecord` and expects an async `syncNowFromTransport`) and `legacyDeliveryKeepsApplyOrder` (:484, waits on `.legacyDelivery`);
- `ShutdownTurnTests.legacyCallerPassAppliesTheShutdown` (:412), which waits on `.legacyShutdownPass` (`makeKeeper(.legacy)` passes `transport: nil`, :197);
- `TicklessReplayPassTests.legacyPassesRecordInApplyOrder` (:390), which holds the first pass at `.turnRecord` and awaits a second input before releasing it (`makePassKeeper(inTurn: false)` passes `transport: nil`, :224). On the turn path the second input would wait behind the held turn and deadlock;
- `BroadcastSpyTransport`'s `leaveBeforeThrowStillBroadcasts` (`PerSequenceResultTests.swift:376`), which asserts the leave's `syncBroadcastOnlyFromTransport` call.

The two `transport: nil` tests are not portless, so the rule keeps them on the legacy path until L2d. The census script lists every `transport: nil` keeper with whether it is marked portless and whether its test asserts the legacy order.

In L2d each keeps its lasting claim as an in-turn test, with its hold moved to a keeper hold point or a resolver hold at the same position in the turn: one turn can't take another turn's sync request, outputs are handed off in apply order, and the forced shutdown runs its pass. The assertions about the legacy path's suspension windows are retired. The PR gives each its fate and reason.

**Fakes on `.reevaluation` keepers** (`LandKeeperReevaluationOutputModeTests` :41) are reached through the mode. They stay, with the code they reach (§1), until #612 S2 and S6.

**The two transport requirements.** `syncNowFromTransport` and `syncBroadcastOnlyFromTransport` stay in `LandKeeperTransport`, since `.reevaluation` keepers' calls reach them (LK:3802, :4516, :5564). L2d deletes the adapter's implementations and gives both requirements do-nothing defaults with a doc comment: kept as a compatibility surface for keepers that replay, until #612 S6. `ReleasedLandTransport` keeps its drops (LKT:378–379), as the teardown placeholder. Its direct test (`DrainTurnTests.swift:326`) proves the drop.

Rejected: a null transport that opts in. It would run a sync phase that sends nothing, clear dirty flags every turn and change what the 2e tests observe.

### 3.6 What L2d deletes

The off executor goes last, when no caller is left:
- the adapter's `inTurnSync` init parameter and `inTurnSyncEnabled` (TA:973), `ownExecutorHost` and `AdapterExecutorHost` (TA:105–111), and the package `inTurnSync` on `LandManager`'s init and `NIOLandServerConfiguration`. `LandManager.swift:700–701` read `true` in its place;
- `withSyncState` (TA:3296), `beginSyncLocatedIfRecording` (TA:3915), `legacyCycleRead` (TA:3901), `beginSyncRequests` (TA:747);
- the off adapter's cycle: `_syncNowImpl`'s cycle branch, `_syncBroadcastOnlyImpl` and `planBroadcastOnlySyncPhase` (TA:5232, :5279), the kept-event follow-up, the backlog and busy retry (`deferSyncForOutboundBacklog`, `runBacklogDeferredSync` and their fields), `syncSkips.busy` with `SyncSkipCounts.busy`, and `startBackgroundSync`/`backgroundSyncTasks` once their last user goes;
- the off settle and resume (§3.4);
- the adapter's `syncNowFromTransport`/`syncBroadcastOnlyFromTransport` (`TransportAdapter+LandKeeperTransport.swift:15–21`);
- on the keeper: `beginSync`, `beginSyncLocated`, `endSync()` and `endSync(clearDirtyFlags:)` (LK:1336–1395), `isSyncing` (LK:663), and the latch `syncOnlyTurnAfterLegacyCycle` (LK:704) with its reads in `runTurnOutputs` (LK:4629) and `runSyncOnlyTurn` (LK:5043);
- **the live legacy pass**: `finishTicklessLegacyPass`, `deliverLegacyPass`, `legacyDeliveries`, `runLegacyPass`, and `runSyncRequests`' `else if mode == .live` branch (LK:641–647). They are entered only from live branches (LK:3758), so `.reevaluation` keepers never reach them;
- the hold points only those reach: `.cycleBeforeEndSync`, `.busyRetry`, `.followUpSynced`, and the keeper's `.syncOnlyAfterLegacyCycle`, `.legacyDelivery` and `.legacyShutdownPass`;
- `routesThroughTurn`'s transitional term: `syncsInTurn` becomes `transport != nil` (§3.5);
- the off arms of every explicit off caller (§2). `WallClockCadenceSmokeTests` keeps its on leg, and CI keeps the check that it ran;
- `LandKeeperSyncLockTests`, the direct `beginSync`/`endSync` calls (§2), the legacy witnesses (`join-during-sync-cycle`, `TransportAdapterInTurnSyncTests.swift:927–937`), and the remaining legacy-cycle cases.

Each off arm is deleted, or converted when the in-turn path has the same claim to check. The PR lists each test with its fate. No new off arm is added.

### 3.7 Hand-offs

**To #655 (B2's text).** B2's rewrite against one sync path takes these from L2:
- `.cycleBeforeEndSync` is gone; the settle's commit is `debugSettleTurn` (§3.4);
- a requested sync turn is §3.2's shape (the maintainer's answer). Delays and their holds are the adapter's (`.failedPlanFollowUp`, `.syncLagTimerSync`), with the lag timer's epoch re-checked after its hold;
- decision 2's keeper-lock protocol and §3.4's coalescing "after `endSync`" are replaced by §3.4 here.

**To #612, when it resumes.** With Q3 (a) decided, #612 takes the predicate split as given:
- S2 adds `.record` keepers to `routesThroughTurn`, and may drop `syncsInTurn`'s mode term;
- S2 moves the `.reevaluation` fakes; S6 deletes the two transport requirements and what `.reevaluation` keepers reach (§1). The live legacy pass is L2d's, not S6's;
- §5.3's `SyncPlanMode` drops broadcast-only, which L2d deletes;
- #612 §3.3's "a recorder sets it under today's gate (LK:4881 …)" is the gate mix-up rev 1 had here (§3.5).

## 4. Steps

Order: **L2a → L2b; L2c; then L2d.** L2b needs L2a's requested-turn path for its resume. L2c depends on neither: its no-port keepers run no requested turn, and the transitional rule leaves every off adapter as it is. It can be reviewed beside L2a or L2b. L2d needs all three. Each PR leaves `main` green, with the harness byte-identical except where §5 says.

**L2a: the syncs become turns on in-turn adapters** (groups 2a, 2b).
- `syncTurnNow()`, the requested-turn path, the `keepsEvents` signal and the keeper's test wait (§3.1, §3.2). On an in-turn adapter, `syncNow()` calls `syncTurnNow()`, and the follow-up, the lag timer's sync and the behind-commit repair request turns. On an off adapter all of these stay as they are, with the backlog and busy retry, `SyncSkipCounts.busy` and their holds, so the legacy cells and their witnesses don't change.
- `syncBroadcastOnly()`'s entry point deleted, and its 17 calls converted (§3.3).
- **The cycle hold on in-turn adapters** (§2): each `SyncCycleHold` caller that holds a `syncNow()` gets its fate here. A claim about work that arrives while a cycle is in flight has no in-turn window. Where the claim is about deferral, the test holds the writer instead (a deferred phase and its retry). Where the claim is the cycle's `endSync` hop, it is deleted. The settle's users of the hold wait for L2b (§3.4). The PR lists each test.
- **The harness:** `join-during-sync-cycle-inturn` is retired, and `join-during-writer-backlog` added (§5.2). The in-turn goldens are regenerated (§5.1).
- `TransportAdapterBenchmarkHandle.syncNow` forwards to the new `syncNow()`. The handle's `syncStateForNewPlayer` and its join with `completedInTurn == false` (used by `Rejoin.swift`) stay; they belong to the standalone initial sync.
- Gate: §6. Host A/B: yes.

**L2b: the freeze settle on in-turn adapters** (group 2c). §3.4, its tests included. The off settle stays until L2d.

**L2c: every live keeper on the turn path** (groups 2d, 2e). §3.5: `portless` and the transitional rule. Gate: the full `swift test`; the attach test under the `.wiring` hold; the recording comparison; a `HashCostBenchmark` smoke run (`HashCostBenchmark.swift:50`); the census script and its `transport: nil` listing.

**L2d: the off executor deleted.** §3.6, and the harness's legacy cells (§5.3). Gate: the full `swift test`; the harness lists 84 cells and runs every one; the in-turn goldens unchanged by this PR.

**Docs, en and zh-TW, by PR:**
- L2a: `docs/core/runtime.md`'s sync deduplication and `syncNow` text (:94–104); `docs/transport/README.md:264`;
- L2b: the in-turn settle (`runtime.md` :434, :444–478);
- L2d: `runtime.md`'s Snapshot Sync Mode and Sync Flow (:41–62), `beginSync`/`endSync` and `isSyncing`; `docs/core/failure-handling.md:58`; AGENTS.md § Reentrancy drops the freeze settle and the legacy tick path from its exceptions, and so does the root guide's copy of that section. The replay tick's exception stays until S6.

## 5. The harness

### 5.1 The in-turn goldens change in L2a

Every harness sync is `DiffRunner.sync()` → `adapter.syncNow()`. At bf8a2ac2 the 84 in-turn goldens hold 308 records with `turnKind: legacyCycle`, 87 with `syncOnly` and 126 with `tick`. The 308 are stream totals: the standalone firstSync and the settle keep the tag; only the records of `syncNow()` change. After L2a each `syncNow()` is a sync-only turn.

The L2a PR carries a check script, run over the old and new goldens. It reports each cell's changes, classified by cause:
1. **The turn kind:** `legacyCycle` → `syncOnly` in those syncs' records.
2. **Tickless positions:** a tickless land's sync-only turn is a turn record (#327), so later turn positions move by one per sync.
3. **Joins that flip earlier:** a `syncNow()` while a join waits now completes it. The joiner's JoinResponse and firstSync move into that phase's frames.
4. **Merged events delivered earlier:** a requested turn (§3.2) can carry events the legacy path held for a later cycle.
5. **A phase deferred and retried:** where the writer held an earlier phase, the in-turn path defers and retries where the legacy cycle skipped.

Every other change is reported on its own, and the PR body has the table. A change outside these causes needs its own explanation, or it is a bug. Frames that none of these causes touch are byte-identical: both paths plan with `runFullSyncPhase` from the same state.

#676 (a flake in `disconnect-during-keeper-join`'s tickless in-turn cell, on the turn kind) is in this area. L2a regenerates the goldens only after #676's fix has merged.

### 5.2 The retired rows

| Row | Retired in | Replacement |
|---|---|---|
| `join-during-sync-cycle-inturn` (`.inTurnOnly`, DS:372) | L2a | Its claim is the latch, which has no in-turn trigger once `syncNow()` is a turn. The join's side moves to `join-during-writer-backlog`. |
| `DiffLeaveTurnTests.heldCycleMovesTheLeaveSync`'s held-cycle half (#678) | L2a | The same claim, the latch, for a leave's sync. Retired with the row above. Its pinned-row half stays. |
| `join-during-sync-cycle` (`.legacyOnly`, DS:334) | L2d | `join-during-writer-backlog` (below). |
| `disconnect-sending-join-response` (`.legacyOnly`, DS:182) | L2d | Retired as unreachable (below). |
| `disconnect-sending-initial-sync` (`.legacyOnly`, DS:184) | L2d | Retired as unreachable (below). |

**`join-during-writer-backlog`**, on the in-turn cells, added in L2a. A join becomes ready while the writer holds a phase's frames. A barrier checks that the phase was deferred while the writer is held. After the writer is released, the row asserts exactly one JoinResponse and one firstSync for the joiner, with no explicit or periodic phase run after the release. So the deferred phase's retry is the only thing that can flip it. Mutant: drop the retry after the writer drains (LK:5068); the row then fails for want of the join's frames.

**The two router rows** cover the router's non-flip branch (LR:1123–1156), taken when the admission returns `completedInTurn == false`. After L2d no router join reaches it:
- the router always passes a response builder (LR:1050–1056);
- the adapter installs `expectedAdmissions` before `joinReportingAdmission`, in the membership job (TA:1967–1976);
- an in-turn keeper's admission consumes it synchronously and admits in-turn when it is there (`admitJoiningSessionIsolated`, TA:1968–1976).

So with every adapter in-turn, a router join always completes in-turn. L2d states this proof in its body and retires the rows on that ground. The general adapter API keeps a tested fallback with no port, and B3 deletes the branch with the standalone initial sync.

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

**L2a: a host A/B.** It measures EncodingBenchmark's driver path: its measured loop calls `syncNow()` (30 calls), which moves from the adapter's cycle to a keeper job. The claim is scoped to that driver. L2a also moves the lag timer's and the out-of-turn events' scheduling, which the benchmark doesn't measure. Production's periodic sync already runs `runSyncOnlyTurn`, so this sets that tool's new baseline. Base against L2a, both built from the pinned image, on the measurement host. The cell list is fixed with Main before the run, as B0's was (#655 §5.1), with MessagePack and JSON included. `MeasuredSync`'s skip check stays meaningful: the in-turn path counts a deferred phase in `syncSkips.outboundBacklog`.

**L2b–L2d: a Mac output check.**
- L2b: the freeze frames and records (`freeze-resume-messagepack` byte-identical).
- L2c: the recording comparison (§3.5), and a `HashCostBenchmark` smoke run.
- L2d: the harness, with the in-turn goldens unchanged.

## 7. Public API

The adapter is `package` since E, so `syncNow()`, `syncBroadcastOnly()` and the `inTurnSync` parameter are already outside the public surface. Decided (Q1 (a)): the public breaks go with no deprecation. The full list:
- **L2a:** `TransportAdapterBenchmarkHandle.syncNow()` keeps its signature; on the in-turn adapter it gives, its behavior changes (§3.1). `InTurnSyncOutput` gains a package field (`keepsEvents`) and a package init parameter; its public init and `InTurnSyncResult` don't change.
- **L2b:** none. The settle's entry point is the keeper's package `debugSettleTurn` (§3.4).
- **L2c:** `LandKeeper.isUsingInTurnSync()` keeps its signature and its answers (§3.5). `LandKeeper`'s init gains `portless: Bool = false`, an additive, source-compatible parameter.
- **L2d:**
  - `LandKeeper.beginSync(clearDirtyFlags:)`, `endSync()` and `endSync(clearDirtyFlags:)` are removed.
  - `SyncSkipCounts.busy` (a public field and init parameter, `TransportAdapter+Outbound.swift:235–245`) is removed. Both `MeasuredSync.swift`s stop reading it.
  - The profiler's `syncSkipsBusy` JSONL field (`TransportProfilingActor.swift:595`) stays, always `0`, so the profile format doesn't change: `ws-loadtest/src/server-sync.ts:14` requires it, and old and new profiles parse alike. `METRICS.md:136` says it is always 0 since L2. Dropping it would be a format change for its own PR, with ws-loadtest and its test (`tests/server-sync.test.ts:14`) changed together.
  - `TransportAdapterBenchmarkHandle.inTurnSyncEnabled` (`TransportAdapterBenchmarkHandle.swift:59`) is removed. EncodingBenchmark writes `true` in its place in the record metadata (`EncodingBenchmarkMain.swift:158–159`), so records keep their shape.
  - `LandKeeperTransport.syncNowFromTransport()` and `syncBroadcastOnlyFromTransport()` stay as requirements with documented do-nothing defaults (§3.5). #612 S6 removes them.

Each PR's body restates its items.

## 8. Decisions by the maintainer (2026-11-20)

**Q1. The public removals (§7).** *Decided: (a).*
- (a) Remove them in L2, with no deprecation. Nothing calls them after L2, and there are no external users (2026-11-18).
- (b) Deprecate them in L2 and remove them later. They would stay as no-ops or traps, with a test each, until the removal.

The list is §7's: `LandKeeper.beginSync`/`endSync` (both overloads), `SyncSkipCounts.busy` and `TransportAdapterBenchmarkHandle.inTurnSyncEnabled`, all in L2d. `LandKeeperTransport`'s two sync requirements move to #612 S6 under the same rule. The profiler field stays (§7).

**Q2. `syncBroadcastOnly()` (§3.3).** *Decided: (a).*
- (a) Delete it. Its callers use `syncNow()`, which runs the full phase, as an in-turn broadcast-only request already does (LK:637–640). The broadcast-only plan goes with it.
- (b) Keep it as a broadcast-only sync-only turn: a phase that diffs broadcast fields only and keeps the dirty flags.

The entry point goes in L2a. The plan goes in L2d, with the off adapter that still uses it (§3.3).

**Q3. Where the predicate split lands (§3.5).** *Decided: (a).*
- (a) In L2c, with #612's names (`routesThroughTurn`, `syncsInTurn`). #612 S2 takes the split as given and adds its `.record` keepers to `routesThroughTurn`.
- (b) In #612 S2, with L2c after S2. L2 would wait on S2, which waits on S1, #521's remaining PRs and #606.

**Pending: the requested turn's shape (§3.2).** (a) an entry point with a pending flag, or (b) a keeper input with a reason and a ticket, validated in the turn. Main has taken it to the maintainer.

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
- **A requested turn lost to coalescing.** The L2a PR tests both directions: an immediate request while a delayed repair sleeps or is held at `.failedPlanFollowUp` runs at once; a delayed repair that comes due while an immediate turn is pending still runs its own turn after its delay and hold. A request made during a requested turn arms a new one.

## 11. Rev 4: what changed

| Change (from #680's rev 3 review) | Where |
|---|---|
| "No port, ever" told by a `portless` init parameter, not by `transport == nil`; the rule per head; the attach test under `.wiring` in L2c's gate (MF1, should 5) | §3.5, §4, §7 |
| `ShutdownTurnTests:412` and `TicklessReplayPassTests:390` stay on the legacy path under the rule, with their L2d fates; the census lists `transport: nil` keepers (MF2) | §3.5 |
| The settle tests' hold after `debugSettleTurn` returns, before the publish; a requested turn during a freeze sets the resume's deferred sync (MF3) | §3.4, §3.2 |
| The requested turn's contract: at once on hand-stepped tick lands, never a tick input; a skipped request wakes the test wait; from outside the keeper it runs before returning, so the resume's order holds; the resume isn't on the no-periodic-sync premise; all of `syncTurnNow()`'s results, and the latch between L2a and L2b (should 1) | §3.1, §3.2 |
| Two conformers reclassified as live; `LandKeeperReevaluationOutputModeTests:104` is a mode argument (should 2) | §2, §3.5 |
| LK:5539 is the periodic sync loop, on `syncsInTurn` (should 3) | §3.5 |
| `BroadcastSpyTransport` and its L2d fate (should 4) | §2, §3.5 |
| Nits: the internal callers of `_syncBroadcastOnlyImpl()`; the admission cases :274, :302, :326; `LandManager.swift:700–701` | §3.3, §2, §3.6 |

## 12. Rev 3: what changed

| Change (from #680's rev 2 review) | Where |
|---|---|
| L2a keeps the off adapter's cycle, broadcast-only plan, backlog and busy retry, holds and busy count; only `syncBroadcastOnly()`'s entry point goes; `SyncSkipCounts.busy` moves to L2d (MF1) | §3.1, §3.3, §3.6, §4, §7 |
| L2a → L2b; the off settle and resume kept until L2d; the settle's tests get their fates in L2b, with the writer-backlog and failed-plan settle tests in its gate (MF2) | §3.4, §4 |
| L2c's transitional routing rule, narrowed in L2d; initialize's drain with no port; LK:2657 is the forced tickless shutdown, with `ShutdownTurnTests:412`'s fate; `syncsInTurn` keeps the mode term (MF3, nit 1) | §3.5 |
| The two live `TicklessReplayPassTests` keepers, `DestroyHoldTransport`, `MockLandKeeperTransport`'s OnLeave assertions; the live legacy pass deleted in L2d, not #612 S6; what `.reevaluation` keepers reach kept, with documented defaults (MF4) | §1, §3.5, §3.6, §3.7 |
| The settle's fence: deadline, drain and shutdown in the commit segment; the failure kept as a queued input at today's position; the resume's order (MF5) | §3.4 |
| The requested turn: the drain guard, immediate-only on the keeper with delays and holds on the adapter, the lag timer's epoch on the adapter, the `keepsEvents` signal, `syncTurnNow()`'s results, `waitForSyncQuiescenceForTesting` and its callers; its shape pending the maintainer (MF6) | §3.2, §3.1 |
| The router rows retired on the stated proof; the backlog row's assertions and barrier (should 1) | §5.2 |
| §5.1's causes: merged events delivered earlier, deferred and retried phases; the 308 are stream totals (should 2) | §5.1 |
| `LandManager`'s reads of `inTurnSyncEnabled` (should 3) | §2, §3.6 |
| The census per declaration and mode, with a script; the later admission cases and the direct lock call (should 4) | §2 |
| AGENTS.md's exceptions leave in L2d (should 5) | §4 |
| The recording comparison on a controlled schedule, with the interleaving case's expected watermark (should 6) | §3.5 |
| L2c's dependency: none (should 7) | §4 |
| `DiffLeaveTurnTests.heldCycleMovesTheLeaveSync` (#678), one more in-turn cycle-hold user (Review's addendum) | §2, §5.2 |
| Cross-references; whether requested turns fold (nits 2, 3) | header, §3.2 |

## 13. Rev 2: what changed

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
