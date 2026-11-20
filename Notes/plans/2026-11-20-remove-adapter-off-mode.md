# Remove the adapter's off mode on live lands (#546 L2)

**Status:** rev 7, plan only, for review. No code until this plan is GO. L1 (#677) is merged (7a462bd1).
- **Decided (the maintainer, 2026-11-20):**
  - §8's Q1 (a), Q2 (a) and Q3 (a);
  - a requested sync turn is a keeper input that carries its reason and a ticket, validated in the turn (§3.2, §8).
- **Rev 7** answers rev 6's review (#680: 2 must-fix, 5 should, 1 nit). What changed is in §11; the earlier revisions' changes follow it.
- **Order changed in rev 5:** L2c now deletes the off adapter, and L2d moves every live keeper onto turns. So there is no transitional routing rule and no `portless` parameter (§3.5).

**Issue:** #546, step L2 of `2026-11-19-adapter-turn-core-rewrite.md` (rev 13). That plan holds L2's placeholder (§3.2, groups 2a–2e) and the "Inputs to L2's own plan" block; §9 here maps each input to the section that settles it. "Group 2a"–"2e" name #655's groups; "L2a"–"L2d" name this plan's PRs.

**Base:** `main` at 1075c23c, with L1 (#677) and B0 (#666) in. Pointers are at 1075c23c:
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
- Every live keeper runs its inputs through turns, routed by its mode alone. A turn with no port that opts in records its outputs and delivers none.
- The harness has no legacy cells. Its in-turn goldens record what the in-turn path does for every sync a scenario asks for.

**Unchanged by L2:**
- The standalone initial sync (`_syncStateForNewPlayer`, TA:5588) and its re-checks: the ticket, the player binding, the output gate and the commit epoch. It stays until B2 (`.initialSyncCommit`) and B3 (membership). Its recorder tag `.legacyCycle` stays (`ReevaluationSyncStream.swift:20`).
- What `.reevaluation` keepers reach: `processPendingActions`, `replayRecordedPasses`, the replay broadcast calls (LK:3802, :4516), the sync loop's transport call (LK:5564), and `LandKeeperTransport`'s `syncNowFromTransport`/`syncBroadcastOnlyFromTransport`, kept with do-nothing defaults (§3.5). `LandKeeperReevaluationOutputModeTests` keeps its `.reevaluation` keepers.
- Frames on the default production path. A server built from `main` already runs in-turn, and production's periodic sync already runs `runSyncOnlyTurn`.

## 2. Who reaches the off mode after L1

Counting rule: executable call sites, not comments; conformers per declaration and per keeper mode. Each PR's body lists its files.

**The adapter's own syncs on an in-turn land** (group 2a): the kept-event follow-up (TA:3154, :5271, `startFollowUpSync` TA:3162), the backlog and busy retry (`deferSyncForOutboundBacklog`, TA:3198–3217), the lag timer's sync (TA:3605, `runSyncLagTimerSync` TA:3622), and the behind-commit repair (`startDelayedFollowUpSync`, TA:3186, called at TA:5657).

**`syncNow()` and `syncBroadcastOnly()`** (group 2b, `TransportAdapter+Sync.swift:4–10`). They run the adapter's cycle even on an in-turn land.
- `syncNow()`: 127 calls in `SwiftStateTreeTransportTests` (35 files), 3 in `SwiftStateTreeTests`, 3 in `SwiftStateTreeNIOTests` (2 files, `DR` among them), 6 in `SwiftStateTreeBenchmarks`, 30 in EncodingBenchmark (`BenchmarkExecution.swift`, `EncodingBenchmarkMain.swift`, `RouterJoin.swift:271`), one in each Examples `SyncTablesFrameIdentityTests`, and `TransportAdapterBenchmarkHandle.syncNow`.
- `syncBroadcastOnly()`: 17 direct calls in nine `SwiftStateTreeTransportTests` files: `PerPlayerSyncTablesScenarioTests` (3), `TransportAdapterSyncConcurrencyTests` (3), `TransportAdapterOrderedSendTests` (2), `TransportAdapterPendingEventsAcrossCyclesTests` (2), `TransportAdapterSyncBackPressureTests` (2), `TransportAdapterSyncPhaseTests` (2), `TransportAdapterDebugFreezeTests`, `TransportAdapterSyncDirtyWindowTests` and `TransportAdapterSyncLagTests` (1 each).
- The broadcast-only cycle has three internal callers besides the entry point: `syncBroadcastOnlyFromTransport` (`TransportAdapter+LandKeeperTransport.swift:19–21`), which a legacy keeper calls on every leave (LK:645, :3876); `runBacklogDeferredSync` (TA:3245); and the resume (TA:6644).

**The cycle hold on in-turn adapters.** `SyncCycleHold` (`TransportTestHelpers.swift:80–87`) arms `.cycleBeforeEndSync` and spawns `syncNow()`. In-turn callers: `TransportAdapterPendingEventsAcrossCyclesTests` (:297, :646–710, :826–1018), `TransportAdapterTargetedEventOnceTests` (:81, :167), `TransportAdapterSyncBackPressureTests` (:159), `TransportAdapterSyncDirtyWindowTests` (:166, :228) and `TransportAdapterInTurnSyncTests` (:893). The harness row `join-during-sync-cycle-inturn` (DS:386, built by `syncCycleRow`, DS:66–90) does the same, and so does `DiffLeaveTurnTests.heldCycleMovesTheLeaveSync` (#678, which lands before L2a): it holds an in-turn legacy cycle at `.cycleBeforeEndSync` over the leave's turn and asserts the latch path (a sync-only turn after `endSync`).

**The legacy cycle's witnesses.** `join-during-sync-cycle` (`.legacyOnly`, DS:348–375) arms and reaches `.busyRetry`, arms `.followUpSynced` in its MessagePack cell, and asserts `syncDeferredByCycleCountForTesting == 1`, which reads `syncSkips.busy` (TA:3312, :3555). The off case in `TransportAdapterInTurnSyncTests.swift:927–937` asserts the same count.

**The freeze** (group 2c): the settle's `beginSync` loop (TA:6548–6612) and the resume's replay (TA:6641–6645). The in-turn adapter uses it until L2b, the off adapter until L2c.

**Keepers whose transport doesn't opt in** (group 2d). Per declaration, leaving out `TransportAdapter`, there are 28 conformers in 20 files, 11 of which opt in (`LandFailureTests:92` and `TicklessActionJobTests:130` among them). The rest, by keeper mode:
- live, not opting in: the conformers in `LandKeeperDebugFreezeTests`, `ReplaySequenceWatermarkTests`, `SyncRegistrationTests`, `ActionEventSyncTests`, `LandDSLTests`, `ResolverDeadlineTests`, `InitializeResolverFailureTests`, `MockLandKeeperTransport`, `DestroyHoldTransport` (`DrainTurnTests.swift:281`), `BroadcastSpyTransport` (`PerSequenceResultTests.swift:200`), the second conformers in `DrainTurnTests` and `ResolverDeliveryTests`, and `PassSyncCountingTransport` and `PassDeliveryLogTransport` (`TicklessReplayPassTests` :164, :174), the transports of its two live tests (:451, :484);
- `.reevaluation`: `LandKeeperReevaluationOutputModeTests` (:41; its :104 is the `mode: .reevaluation` argument). The replay keeper builder of `TicklessReplayPassTests` (:278–291) passes no transport;
- the library's `ReleasedLandTransport` (LKT:351), the teardown placeholder.

The L2d PR prints the census from a script, as a migration list (§3.5), so the counts are checked, not hand-kept.

**Live keepers with no transport** (group 2e): about 19 `SwiftStateTreeTests` files, `HashCostBenchmark.swift:50`, and `ReevaluationRunner/main.swift:452` (a live keeper that records a game).

**In-turn adapters whose keeper has no port attached.** The adapter shares its keeper's executor whether or not it is attached (TA:112). But `isAttached(to:)` checks only the keeper's identity (TA:116), not the keeper's transport slot:
- `TransportAdapterSyncLagTests.makeFixture` defaults `keeperTransport` to `false` (:189), and `timerRequestsSync` (:378) expects a resync from that fixture;
- EncodingBenchmark's static and dynamic worker pools build a keeper with no transport, never attach the adapter, and call `syncNow()` in their loop (`BenchmarkExecution.swift:491`, :603, :687, :791).

**Explicit off callers** pass `inTurnSync: false`, directly or through a fixture:
- the harness's legacy cells (`DiffRunner`, after the configuration's init since L1);
- the pinned `LandRouterJoinAttemptTests` (L1);
- direct: `AtomicPatternIndexAdapterTests` (1), `InitialSyncBehindCommitTests` (1), `LandReleaseTests` (1), `RowAddressingAdapterTests` (:441–551, :882), `TransportAdapterPendingEventsAcrossCyclesTests` (2), `TransportAdapterSyncLagTests` (4);
- through a fixture or a case list: `SyncStreamProducerTests.swift:286`, `TransportAdapterInTurnSyncTests.swift:928` and :987, `SyncStreamInitializeRecordTests.swift:144`, `TicklessPassOrdinalTests.swift:551`, every arm of `TransportAdapterNewestWinsTests`, `TransportAdapterRegisterSessionTests.swift:58` (its fixture defaults to `false`) with its `[true, false]` cases, `TransportAdapterInitialSyncStaleReadTests` (:99, :302, :326), `ActionJobReplayOrderTests` (:160–173), `RecordTurnBoundaryLiveTests` (:97), `LandKeeperInputTurnTests` (:222, :595, :616), `TransportAdapterJoiningAdmissionTests` (:114, :143, :186, :233, :253, :274, :302, :326), and `WallClockCadenceSmokeTests.swift:25` (`inTurn: [true, false]`).

**Direct `beginSync`/`endSync` callers:** `LandKeeperSyncLockTests` (:74, :115), `TransportAdapterOrderedSendTests.swift:575`, `SyncStreamProducerTests.swift:543`, `TransportAdapterSyncDirtyWindowTests.swift:273`.

**Other readers of the off mode:** `LandManager` reads `inTurnSyncEnabled` for `recordsSyncStream` and the sync configuration (`LandManager.swift:697–698`); EncodingBenchmark reads `TransportAdapterBenchmarkHandle.inTurnSyncEnabled` (`EncodingBenchmarkMain.swift:158–159`).

## 3. Decisions

### 3.1 What `syncNow()` becomes (groups 2a, 2b)

*On an in-turn adapter, `syncNow()` runs one sync-only turn on the keeper now, and returns after it. On an off adapter it runs the cycle, as today, until L2c.*
- The keeper gets a package entry point, `syncTurnNow(via port: any LandKeeperTransport) -> InTurnSyncResult`. The adapter passes itself. It is an outside request (§3.2): one keeper job validates it, with `port.runsSyncPhaseInTurn(of: self)` among the checks, runs `runSyncOnlyTurn(transport: port)` (LK:5039), and returns the phase's result. The adapter shares the keeper's executor when it runs in-turn (TA:112, :974), so no other turn runs between the request and the turn.
- `syncNow()` keeps returning `Void`. The adapter gets a package twin, `syncNowReportingOutcome() -> InTurnSyncResult`, which the harness's `.syncNoWait` step and tests that assert the outcome use.
- The port is the adapter the call names, not the keeper's transport slot. So the adapters whose keeper has no port attached (§2: the SyncLag fixture and EncodingBenchmark's worker pools) keep working, with their routing and outputs as they are; only `syncNow()`'s path moves. The lag timer's and the other outside requests name their adapter the same way.
- What it returns: `.committed` when the phase committed (its frames are with the writer); `.skipped` when nothing was planned (no members, a failed land, frozen, or the keeper's `isSyncing` held by a legacy cycle, when the latch reruns it after `endSync`); `.deferredBackPressure` when the writer held an earlier phase, with the keeper's one retry pending (LK:5068); `.failed` or `.landFailed` when the phase ended the land. A request that fails validation (a failed or draining land, a stale ticket, a port that fails the binding check, §3.2) returns `.skipped`. The caller that needs a retry's frames awaits the test wait (§3.2).
- Between L2a and L2b the in-turn settle still takes `beginSync` (§3.4), so a turn requested during a settle meets `isSyncing`: it sets the latch and returns `.skipped`, and the latch's turn runs after the settle's `endSync`. The test wait counts that rerun (§3.2).
- No fold. The sync loop folds a sync into a tick due within the coincident-sync window (LK:5539–5557). An explicit `syncNow()` is a test's or a benchmark's request for a sync at that point, so it runs at once.
- No busy outcome on the in-turn path. A sync-only turn is synchronous, so a request can't meet one in flight.

What changes for an in-turn caller:
- **A ready join flips.** The in-turn phase completes ready joins (TA:2914–2920); the legacy cycle passed none (TA:3151). A `syncNow()` while a join waits now sends that join's JoinResponse and firstSync in this phase.
- **A tickless land records a turn.** Its sync-only turn is its own turn record (LK:5054–5056, #327).
- **The record's turn kind** is `syncOnly` where it was `legacyCycle`.

§5 accounts for these in the harness. Outside it, the L2a PR lists each converted assertion.

### 3.2 Pending sync work: one rule, one keeper input

*Rule: whenever sync work is due outside a turn on an in-turn land, something asks the keeper for a sync-only turn. No flag waits for an adapter cycle to read it.* On an off adapter the legacy follow-up and retries stay until L2c.

**Decided (the maintainer, 2026-11-20): a requested sync turn is a keeper input that carries its reason and a ticket, validated in the turn.** This is the shape B2 gives the adapter's other callbacks: one place to inspect, and one thing to hold in tests. Not chosen: a keeper entry point with a pending flag.

**The input.** `SyncTurnRequest` has three fields:
- **`reason`**: `.syncNow`, `.keptEvents`, `.outOfTurnEvent`, `.lagTimer`, `.behindCommitRepair` or `.resume`. It is for diagnostics and tests. No handling depends on it.
- **`ticket`**: the keeper's own lifecycle generation. It is bumped when the land fails and when the drain starts. Where it is captured:
  - an inside request captures it in the turn that makes it;
  - a delayed request (the repair, the lag timer's) captures it when its delay starts, before the sleep and the hold;
  - an immediate outside request (`syncNow()`, an out-of-turn event, the resume) captures it at the call. Its job runs right after, so for these the check rarely fails; it matters for the other two.

  Each request captures its ticket and its binding generation (below) in the adapter's segment before its `await`, and the synchronous keeper job validates both. The shared executor makes `assumeIsolated` valid, but the `await` between them is a suspension point, so they are two segments, and the job re-checks. The latch's rerun enters a synchronous handler after its hold (LK:1380–1384), and validates there. The exact segments are checked at L2a's code review.
- **`port`**: the port to sync through. An outside request carries the requesting adapter (§3.1), and an inside request carries the port of the turn that made it.

**A control input.** It isn't queued with the tick's inputs and isn't recorded as an input. The sync-only turn it runs is recorded as that turn is today: a turn record on a tickless land (#327). On a hand-stepped tick land it runs when requested, not at the next step.

**One synchronous keeper job validates it, runs it and retires it.** In one job, in order:
1. **Validate.** The job re-reads the keeper's state. The land hasn't failed. The keeper isn't draining (`isDraining`, LK:532, the guard `runJoinSyncTurn` has at LK:5102). The ticket is current. `port.runsSyncPhaseInTurn(of: self)` holds, which means the port is in-turn and this keeper's own adapter, so it shares the keeper's executor (`TransportAdapter+LandKeeperTransport.swift:23–25`).
2. **Run** `runSyncOnlyTurn(transport: port)` if every check passed.
3. **Retire** the request, whatever the outcome:
   - committed;
   - deferred by the freeze;
   - deferred by back-pressure, in which case the writer-drain retry owns the work (LK:5068);
   - skipped;
   - stale;
   - failed or draining.

   Retiring clears the request's pending entry and wakes the test wait, so the wait never hangs on a failed or draining land.

**Outside requests run now; only inside requests wait.**
- **From outside the keeper:** the adapter's requests (the lag timer, the repair, an out-of-turn event, the resume) and `syncNow()`. The request's job runs the turn at once. It also consumes a pending inside request for the same port: it clears that entry before the phase runs, so the phase can arm a successor. It never returns early because a request is pending, so when the caller's await returns, the turn that covers its request has run. What that turn delivered is a separate question (below). The resume relies on both (§3.4).
- **From inside a turn** (caller 1 below, in `applyInTurnSyncResult`): a turn can't run inside a turn. The keeper adds a pending entry and enqueues the job, which runs right after the current turn. A later inside request made while one is pending joins it. A job whose entry an outside request has consumed retires it without a turn.

So requests coalesce only before a job runs, and only for the same port. No caller's await returns before the turn that covers its request has run.

**Which adapters may request.** A request's port must pass two checks:
- `port.runsSyncPhaseInTurn(of: self)`: an in-turn adapter of this keeper. This proves identity and the shared executor, so `assumeIsolated` is valid.
- **The binding check:** the port's identity (`ObjectIdentifier` of the adapter, package-scoped, since `LandKeeperTransport` has no class constraint, `LandKeeperTransport.swift:42`) equals the keeper's binding. The binding is the attached port, or, on a keeper that has never held a port, its first requester.

"Has held a port" is seeded from the init's `transport:` argument as well as from `setTransport`. The keeper keeps a binding generation, bumped at each `setTransport` and when a first requester is bound. Delayed work captures it, so A → B → A doesn't make an old request from A current again.

So the attached adapter may request, and so may the one adapter bound as the first requester of a keeper that has never been attached: the SyncLag fixture, EncodingBenchmark's worker pools, and `TransportAdapterSyncBackPressureTests`' fixture unless `keeperDrivesSync`. These each have one adapter per keeper. A second adapter on such a keeper is rejected, because the follow-ups' pending state is keeper-wide (`inTurnDrainRetryPending`, the join-sync flag, the latch's one stored port). A formerly attached adapter may not request either. `setTransport` replaced it (LK:467–470), or the teardown installed the released placeholder. The binding check runs at validation and again before every follow-up below.

**The port goes through everything a request's turn arms.** Today the follow-ups read the keeper's slot, which is nil for a never-attached adapter. L2a gives each one the port of the turn that armed it, and each re-checks the binding:
- **The writer-drain retry** (LK:5068) already waits on the given port. Its turn becomes `runSyncOnlyTurn(transport: port)`, not `runRetriedSyncOnlyTurn` → `runSyncOnlyTurnIfInTurn`, which guards on the slot (LK:5061–5079).
- **The latch** stores the port (`syncOnlyTurnAfterLegacyCycle: (any LandKeeperTransport)?` in place of the Boolean). Its rerun after `endSync` (LK:1367–1383) syncs through that port.
- **The join-sync follow-up** a commit arms (`scheduleJoinSyncTurn`, LK:4663–4665) and **the inside request** for kept events (caller 1) carry the port of the turn that armed them.
- **A failure** goes through the bound port. A plan failure reaches `failLand`, which closes and tells `self.transport` (LK:5285–5293). `failLand` and the teardown's `notifyTransportDestroyedAndRelease` (LK:5697–5705) use the binding: the slot's transport, or the bound requester when the slot is nil. So a never-attached adapter that fails is closed and told, and `onLandDestroyed` gives it the rest of the cleanup: the writer finish, the timer stop and the delegate release (TA:3769–3795).
- **An invalidated request with counted work.** The writer-drain retry waits on the writer's drain, which has no cancellation. It returns when the writer drains or when its consumer ends (`OutboundWriter.swift:260–270`), so a teardown ends it. On waking, the retry re-validates: a failed or draining land, a stale ticket or binding generation retires it without a turn. The test wait counts it until then.
- `transportHasJoinsAwaitingSync` still reads the slot (LK:1923–1925). That's harmless: a keeper with no slot doesn't admit in-turn joins (LK:1903), so it has none awaiting.

The periodic sync loop and the handler's sync requests (LK:637) keep reading the slot: they run only on an attached keeper.

**A turn that ran isn't a delivery.** The outcome of the turn that covers a request names who delivers its work:

| Outcome | Who delivers |
|---|---|
| `.committed` | this phase: its frames are with the writer |
| `.skipped`, frozen | the resume: the phase set `deferredSyncNow` (freeze checked first, above) |
| `.skipped`, latched (between L2a and L2b, while the settle holds `beginSync`) | the latch's rerun after `endSync`, through the stored port |
| `.deferredBackPressure`, land without periodic sync | the writer-drain retry, through the same port (LK:5068) |
| `.deferredBackPressure`, periodic land | the next periodic phase; there is no retry (LK:4663) |
| `.skipped`, nothing to plan, or retired (failed, draining, stale, binding) | nobody; there is nothing to deliver, or the land is ending |

`syncTurnNow(via:)` returns the outcome (§3.1). Every test that awaits a request asserts on the phase that delivers, not just on the await.

**The freeze comes before back-pressure.** The in-turn phase checks writer back-pressure (TA:2894–2899) before the freeze (TA:2903). At `.settleBeforePublish` the settle's own frames can still be in the writer, so a request made then would return `.deferredBackPressure` without setting the resume's deferred sync. L2a swaps the two checks, so the phase checks the freeze first, as the legacy cycle does (TA:3132). A frozen phase then always sets `deferredSyncNow` and plans nothing.

During a freeze this changes two things for in-turn phases:
- a frozen phase no longer arms the writer-drain retry;
- it no longer counts a `syncSkips.outboundBacklog` skip.

§5.1 lists this as a cause. Test: a request at `.settleBeforePublish` with the writer held sets the deferred sync, and the resume delivers it once.

**Joins.** A requested turn's phase flips ready joins up to the join budget (TA:1863). What's left progresses through today's paths:
- **On a land without periodic sync:** a commit with joins left schedules a join-sync turn (LK:4663–4665), and a back-pressure deferral leaves the work to the writer-drain retry (LK:5068).
- **On a periodic land:** the next periodic phase does both jobs.

**The latch, between L2a and L2b.** The in-turn settle still takes `beginSync` until L2b. So a requested turn that meets `isSyncing` sets the latch (LK:5043) and returns `.skipped`. `endSync()` clears the latch and spawns its rerun in a Task (LK:1367–1383). The keeper counts the latch's rerun as requested work, from when the latch is set until the rerun's turn has handed its frames to the writer. So the test wait can't report idle between the clear and the rerun. Test: hold `.syncOnlyAfterLegacyCycle` and check that the wait stays busy until the hold is released. L2d deletes the latch.

**Delays and holds stay on the adapter.** The keeper runs only immediate requests. A delayed caller waits on the adapter's side, in a background Task, then requests:
- **The behind-commit repair** (TA:5657): sleep `syncFailedPlanFollowUpDelay`, `await holds.at(.failedPlanFollowUp)`, then request. The hold is an `AdapterHoldPoint` (TA:20) and stays one. Its request is an outside request, so it runs its own turn when it's made, after its delay and hold.
- **The lag timer** (TA:3605): `syncLagTimerPass` checks the epoch in its segment (`syncLagTimerEpoch`, TA:379, private to the adapter), then spawns `runSyncLagTimerSync(epoch:)`. That function holds at `.syncLagTimerSync` (TA:39). After the hold it checks the epoch again, requests, and only then clears the pending mark. The mark becomes the epoch of the pass that set it, replacing today's Boolean (`syncLagTimerSyncRequested`; admission at TA:3605–3610, the callback at :3575–3625; TA:3470–3476 starts the timer and captures its epoch). It is checked against the epoch at both ends:
  - **at admission:** a pass admits a request unless the mark already holds the pass's own epoch, so a pass of a new epoch can request while an old callback is held;
  - **at retirement:** a callback clears the mark only if it still holds the callback's own epoch.

  So a stale callback (the timer restarted and the epoch bumped) neither requests nor clears a newer pass's mark. Test: hold an old callback at `.syncLagTimerSync`, restart the timer, and let the new epoch admit a request. Hold the new callback too, until the old one has retired. Then release the old callback: it doesn't request, and the new mark stays. The new callback then requests and clears its own mark.

**The callers on an in-turn land.** Callers 1–4 are on lands without periodic sync. The resume, caller 5, isn't limited to those, because `debugReleaseFreeze` has no such guard (TA:6641).
1. **Kept events after a commit.** The phase reports whether events are still queued after its commit, whether it kept them or they were queued after it. The signal is a package field on `InTurnSyncOutput`, `keepsEvents`, set by the adapter's package init. `InTurnSyncResult` and the public init don't change. In `applyInTurnSyncResult`'s `.committed` case, `keepsEvents && !hasPeriodicSync` makes an inside request. This is the legacy follow-up's rule (TA:3280–3287). A phase that ends the land requests nothing.
2. **An event queued outside a turn.** `sendEvent` outside a phase, on a land without periodic sync, queues a merged event that only a phase delivers (opcode 107). The adapter makes an outside request when it queues one. An immediate send needs no request.
3. **The lag timer**, as above.
4. **The behind-commit repair**, as above. The standalone firstSync it follows keeps its re-checks (§1).
5. **The settle's kept events** and **the resume's deferred syncs** (§3.4).

The writer-drain retry (LK:5068) and the join-budget follow-ups (`scheduleJoinSyncTurn`, LK:5089) stay as they are.

**Test waits.** The keeper gets `waitForRequestedSyncTurnsForTesting()`. It returns when no request, writer-drain retry, join-sync turn or latch rerun is pending. Each counts from the moment it is made or armed until its turn has run and handed its frames to the writer, or until it is retired without a turn. The adapter's waits cover its side:
- `waitForSyncQuiescenceForTesting()` (`TransportAdapter+Outbound.swift:172–192`) loops until its own background tasks and the keeper's wait are both idle, then waits for the writer. Its background tasks are now the delayed repair and the lag timer's request. Its callers: `InitialSyncBehindCommitTests` (:122, :162), `TransportAdapterSyncLagTests` (:394, :472), `TransportAdapterSyncDirtyWindowTests` and `JoinPendingInboundTests` (:473, :488).
- DR's three waits use both: the sync step (DR:577–580), `.settleSpawned` (DR:352–357) and the barrier's sync quiescence (DR:602–620).

**Where each case is tested.**
- **At once on a hand-stepped tick land:** the harness's `.tick` cells, which DR steps by hand (DR:307). A request made between two steps runs before the next step.
- **The repair:** `InitialSyncBehindCommitTests`. Its adapter is built with `inTurnSync: false` (:97), so L2a adds an in-turn arm, which the repair request needs. The off arm goes in L2c.
- **The timer:** `TransportAdapterSyncLagTests`.

Both of those suites are tickless.

Rejected: keeping `syncNow()` as an adapter cycle that runs inside a keeper job. It would keep a second sync entry, which B2 would then have to model.

### 3.3 `syncBroadcastOnly()` (group 2b): the entry point goes in L2a

Decided (Q2 (a)). L2a deletes the entry point (`TransportAdapter+Sync.swift:8–10`) and converts its 17 calls to `syncNow()`, or deletes the ones that assert the broadcast-only plan itself (kept dirty flags, no per-player patch). The L2a PR lists each with its fate.

The broadcast-only cycle stays inside the off adapter until L2c. With the entry point gone, its internal callers call `_syncBroadcastOnlyImpl()` directly: `syncBroadcastOnlyFromTransport` (`TransportAdapter+LandKeeperTransport.swift:20`) and `runBacklogDeferredSync` (TA:3245), as the resume already does (TA:6644). Its three internal callers (§2) serve the legacy cells: forwarding them to a full cycle would clear dirty flags, add per-player diffs and treat an empty land differently (TA:5240, :5278), and the legacy goldens would change. L2c deletes `_syncBroadcastOnlyImpl` and `planBroadcastOnlySyncPhase` (TA:5234, :5281) with the off adapter.

On an in-turn land a broadcast-only request already runs the full phase (LK:637–640). The keeper's `requestSyncBroadcastOnly` (LK:422) stays as handler API: "a sync in this turn".

### 3.4 The freeze settle (group 2c)

#655 decision 2 keeps the whole freeze on the adapter through B2, the settle included. L2b keeps that, and replaces the settle's keeper-lock protocol with one keeper job on an in-turn adapter. An off adapter keeps today's settle and resume until L2c: it has its own executor (`ownExecutorHost`, TA:104–112), where the in-turn settle's `assumeIsolated` would trap.

**Steps, in-turn:**
1. **Drain**, as today: `keeper.debugFreeze(generation:timeout:)` (LK:1459).
2. **Wait for the writer**, as today: the bounded loop (TA:6558–6563), which checks the deadline and `debugIsCurrent(generation)` on each pass. `waitForSyncCycleDrain` (`OutboundWriter.swift:260–270`) has no deadline or cancellation, so it isn't used.
3. **Commit, in one synchronous segment on the keeper.** The keeper gets `debugSettleTurn(generation:deadline:_:)`, a package entry point that takes a closure from the adapter. The closure runs the adapter's code through `assumeIsolated`, as `runSyncPhaseInTurn` does. `LandKeeperTransport` doesn't change. In that segment, in this order:
   - **The fence.** The keeper checks that the deadline hasn't passed, that `generation` is still active and the keeper still frozen, and that it isn't draining or shutting down. The adapter's closure checks `debugIsCurrent(generation)` and that the output gate is open. Any failure returns "released", "timed out" or "closed", and nothing is planned.
   - **The membership epoch** is read here, in the same segment as the copy.
   - **The phase** is the settle's own. It passes no joiners, as today (TA:6574). It ignores writer back-pressure, as today: step 2 waited, and a frame that entered the writer since doesn't defer the settle. On an empty land it takes the copy without clearing dirty flags and plans nothing (TA:6570–6575). Otherwise it plans and commits the full phase, clearing the flags when dirty tracking is on.
   - **A plan failure** closes the output gate in this segment and returns the failure. The adapter then submits it with `keeper.submitLandFailure`, as today (TA:6587–6589), so the failure reaches the keeper as an input, at today's recorded position and prefix.
   - It returns the state copy, the committed tick, the epoch and `keepsEvents`.
4. **Publish** after the call, with the generation checked again (TA:6594–6606).

**The record.** The settle records its sync output under `.legacyCycle`, as today, with the same position source. So `freeze-resume-messagepack` (`SyncOutputGoldenTests.swift:21–22`, :47, :96) stays byte-identical. A new turn kind would be a record-format change.

**The resume** (TA:6616–6652) runs in this order:
1. **The deferred sync**, as one outside request (§3.2), awaited. An outside request runs its turn before it returns, even when an inside request is pending, so the turn that covers the deferred sync has run when the resume goes on.
2. **The join-sync turn request**, as today (TA:6648–6650; `requestJoinSyncTurn` runs its turn synchronously, LK:1932–1942).

The freeze is off when step 1 runs, and after L2b the settle takes no `beginSync`, so step 1's turn can't be frozen or latched. **Step 2 branches on step 1's outcome.** `requestJoinSyncTurn` has no deferral check on a land without periodic sync (LK:1932–1943); `joinSyncWaitsForCommit` and `periodicJoinSyncAllowed` exist only for periodic lands (LK:1949–1952, :4672). So the resume decides:
- **`.committed`:** step 1's phase delivers the deferred work and flips ready joins up to the join budget (TA:1863). Step 2 runs, and its join-sync turn flips the joins step 1 left.
- **`.deferredBackPressure`:** the resume skips step 2.
  - On a land without periodic sync, the writer-drain retry delivers the deferred work and flips the ready joins.
  - On a periodic land, the next periodic phase does.

  So no second phase defers again or races the owner.
- **`.skipped`, retired:** nothing to deliver; step 2 runs only if joins are waiting.

**A refreeze across the call.** Today the adapter re-checks the freeze after `keeper.debugResume` (TA:6627–6650). The resume re-checks it after step 1's await too. If the land was frozen again, step 2 isn't requested, and what step 1 left stays deferred (`deferredSyncNow`) for the next resume.

Tests, each naming the phase that delivers:
- writer free: deferred output and a ready join, both delivered by the resume's own phases;
- writer held, land without periodic sync: step 2 skipped; both delivered by the writer-drain retry after the release;
- writer held, periodic land: step 2 skipped; both delivered by the next periodic phase;
- more ready joins than the budget: the rest delivered by the join-sync turn;
- a request at `.settleBeforePublish` with the writer held: the deferred sync is set, and the resume's path delivers it once;
- a refreeze between step 1 and step 2: step 2 isn't requested, and the next resume delivers what was left.

**The settle's tests, in L2b:**
- `eventKeptBySettleArrivesAfterResume` and `leaveDuringSettleSendsFlagsMembership` (`TransportAdapterPendingEventsAcrossCyclesTests` :1020–1057) arm the cycle hold and wait for the settle to reach it. They move to a new adapter hold, `.settleBeforePublish`, after `debugSettleTurn` returns and before step 4. The segment itself is synchronous and can't hold, and a hold before it would invert both tests: a leave before the copy gives the settle the epoch after the leave, and an event queued before it would go out in the settle's phase while frozen. After step 3, the leave flags `membershipChanged`, and the event takes §3.2's caller 2 during the freeze: its requested turn defers and sets `deferredSyncNow`, so it is delivered once, after the resume.
- `settleRetriesUntilBeginSyncAccepts` and `releasedBeforeSettleFinished` (`TransportAdapterDebugFreezeTests` :297, :454) build a busy `beginSync`. The first is retired for the in-turn adapter (there is no busy outcome) and kept for the off adapter until L2c. The second moves to a release between step 2 and step 3.
- The gate also runs `TransportAdapterSyncBackPressureTests:275` (the writer-backlog settle) and `SyncOutputVerifierTests:1541` (the failed-plan settle).
- New tests: a release and refreeze, a shutdown, and the deadline's expiry, each between the last writer check and the commit; nothing is planned in any of them.

#655's decision 2 text, §3.4's coalescing "after `endSync`" and `.cycleBeforeEndSync` "before the settle's `endSync`" are then rewritten against this shape (§3.7).

### 3.5 Every live keeper on the turn path (groups 2d, 2e), in L2d

**Why L2d comes after the off adapter's removal.** `usesInTurnSync` (LK:672) answers two questions at once: whether inputs run through turns, and whether the sync phase runs in them. While an off adapter exists, a keeper can't route by "has a port" without the predicate depending on timing:
- A keeper starts its initialization in its init (LK:988–991), with no transport.
- `LandManager` attaches the port later, after several awaits, behind the `.wiring` hold (`setTransport` at LK:467).

So `transport == nil` also means "not attached yet". Rev 4's `portless` parameter told the two apart, but it trapped in teardown, left unattached keepers on code L2d deletes, and changed the public init. Rev 5 drops it.

L2c removes the off adapter first. After L2c every attached adapter is in-turn, so routing no longer needs to know whether a port has come. L2d routes every live keeper by its mode alone.

**The predicate split** (decided, Q3 (a)), with #612's names:
- **`routesThroughTurn`** is `mode == .live`. It is fixed for the keeper's life, so LK:670–671's "fixed once the transport is set" becomes "fixed at init".
- **`syncsInTurn`** is `mode == .live` and a transport is attached that opts in (`transport?.runsSyncPhaseInTurn(of: self) == true`). It is not `transport != nil`:
  - the protocol's default doesn't opt in (LKT:281);
  - the released placeholder uses that default (LKT:351);
  - the adapter checks the keeper's identity before its phase (`TransportAdapter+LandKeeperTransport.swift:23–25`).

  So `isUsingInTurnSync()` and `recordsSyncStream` keep their answers.

No init parameter and no transitional rule. `setTransport` doesn't change, and neither does the teardown's `setTransport(nil)` after it installs `ReleasedLandTransport` (`notifyTransportDestroyedAndRelease`, LK:5700–5705).

**A turn with no port, or one whose port doesn't opt in, delivers nothing.**
- `runTickTurn` (LK:4705–4708) takes `transport: (any LandKeeperTransport)?`. With no port that opts in, it:
  1. applies the inputs;
  2. runs the tick handler;
  3. takes the emitted events and the sync request;
  4. records them in the turn record;
  5. calls no phase.
- `runInputTurn`'s output branch (LK:5442–5446) takes the emitted events and the sync request whenever the batch is non-empty and the land hasn't failed. It calls `runTurnOutputs` only when `syncsInTurn`. So `makeTurnRecord` records the turn's events whatever the delivery.
- **Initialize** (LK:1193–1211) is always a turn on a live keeper. OnInitialize's events and sync request are taken inside the turn, after its record is built. Only the phase waits on `syncsInTurn`, and the initialize marker on `recordsSyncStream`.
- `OnSync` with no port: the sync loop runs it as today (LK:5509–5530), read-only, and nothing follows it.

**What happens to an output made before the attach.** Today an event OnInitialize emits before the attach never reaches a client:
- it stays in the collector at tick `-1`;
- `setTransport` only installs the port (LK:467);
- input passes start at tick 0, and event takes match the tick exactly (LK:3385, :4591);
- the first sync plans from the adapter's own queues.

L2d keeps that outcome: the initialize turn takes the event, records it in its turn record and delivers it nowhere. First-frame delivery of pre-attach outputs is not a goal of L2.

**The pin test** is written first and run on L2d's base, then kept through the change. It runs with a recorder on, on a tick land and a tickless land. It holds `.wiring`, awaits the initialization, runs one tick (or one input on the tickless land) under the hold, releases the hold, and syncs:
- **on the base:** the event stays in the collector, the initialize record holds it, and no client receives it;
- **after the change:** the event is in the initialize turn record, the collector holds none, and no client receives it;
- **both, on the tickless land:** the input under the hold is recorded in its own turn, after initialize;
- **both, on the tick land:** initialize and tick 0 share one record (`submitTurnRecord` ends a record explicitly only on a tickless land, LK:5030–5033), so the test asserts the order and the decoded contents within it.

**A legacy tick across the attach.** The loops start at the end of initialization (LK:1255–1288), possibly before `.wiring` is released. A legacy tick reads the slot when it resumes after an await, so on L2d's base a tick that suspends across the attach can deliver through the newly attached port. After L2d a tick turn reads the slot once, in its synchronous segment. The pin runs the tick land with `autoStartLoops: false` and steps it by hand, so its outcome doesn't depend on that race. The base outcome is recorded in the L2d PR, and checked at its code review.

**Keepers with no port, by the census** (should 1). The L2d PR prints a migration list from a script, covering:
- omitted and conditional `transport:` arguments;
- later `setTransport` calls;
- shared fixture builders.

For each keeper the list gives its builder, whether a port ever comes, and what L2d does to it:
- **Never attached, inputs move onto turns, outputs recorded and not delivered:**
  - the 2e keepers (`SwiftStateTreeTests`);
  - `HashCostBenchmark.swift:50` and `ReevaluationRunner/main.swift:452`;
  - EncodingBenchmark's worker pools (`BenchmarkExecution.swift:491`, :603, :687, :791);
  - `TransportAdapterSyncLagTests.makeFixture` with `keeperTransport: false` (:189);
  - the bare keepers outside the core tests: `MonitorTicketTests:351`, and GameDemo's `HeroDefenseStatsTests:35` and `HeroDefenseFreezeResumeTests:42`.

  Their `syncNow()` keeps working through the adapter it names (§3.1). Today their inputs also deliver nothing: the legacy path has no port to call.
- **Attached later:** hosted `LandManager` (:616), the two SDK benchmark runners (`TransportAdapterSyncBenchmarkRunner.swift:237`, `TransportAdapterConcurrentStabilityBenchmarkRunner.swift:134`), and EncodingBenchmark's builders that attach (`BenchmarkExecution.swift:314`, :910, :1143). Their turns before the attach deliver nothing, as above, and their turns after it do.
- **Legacy builders converted at the builder:** `ShutdownTurnTests` (:189, its `.legacy` arm) and `TicklessReplayPassTests` (:217). That pass builder also serves a live record that is replayed later (:420); the replay half stays on `.reevaluation`.
- **`.reevaluation`:** the mode guard already keeps out the production builders (`ReevaluationEngine:257`, `ReevaluationRunnerImpl:215`, :286).

**The sites**, each with its predicate. Besides the declaration there are 21 executable `usesInTurnSync` reads:

| Site | Predicate |
|---|---|
| handler sync requests LK:637 | `syncsInTurn` (a sync-only turn needs a port) |
| `isUsingInTurnSync()` LK:859 | `syncsInTurn` |
| initialize LK:1193 | `routesThroughTurn` for the turn; the phase on `syncsInTurn`; the marker on `recordsSyncStream` |
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

**Recording.** LK:4881 is the sync-stream gate. The state hash's gate is `enableLiveStateHashRecording && reevaluationRecorder != nil` (LK:4741, :4555; the initialize record at :4844). It has no transport term and doesn't change.
- `ReevaluationRunner/main.swift:452` records with no port. Today it runs the legacy `runTick` (LK:4503, :4555–4581), which writes its record through separate calls (`record`, `setStateHash`, `recordServerEvents`). On `runTickTurn` it writes one turn record per tick, so the raw bytes may differ.

The comparison must hold for a tick land, a tickless land and a hosted land whose initialize runs before the attach, each with initialize and a land-failure prefix:
- decoded equality of the inputs, the state hashes, the events and the watermarks, old record against new;
- the new record replayed through today's verifier, with 0 mismatches.

It runs on a controlled schedule: inputs are submitted between steps, and no input is held across one. The legacy path captures W2 after its suspending input path, and the turn path in the apply segment, so an input held between them can cross the boundary. One case holds an input there on purpose, and the PR records the expected watermark difference for it.

**`isUsingInTurnSync()`** (LK:858, public) answers `syncsInTurn`, which keeps today's answer: `false` with `transport: nil`. The tests that assert it (`PerSequenceResultTests:227`, `ResolverDeliveryTests:271`, `TwoPhaseHandlerTests:200`, `DrainTurnTests:388`, :418, `ShutdownTurnTests:215`) keep their assertions.

**The fakes.** On the turn path, a fake that doesn't opt in receives no sync and no delivery, so each live fake gets its fate in L2d.
- **Fakes whose tests don't depend on the legacy path's order opt in:** `runsSyncPhaseInTurn` returns `true`, and `runSyncPhaseInTurn` records what the test needs (`.notRequested` when it records nothing). These include:
  - `DestroyHoldTransport` (`DrainTurnTests.swift:281`);
  - `MockLandKeeperTransport`'s broadcast-only assertions on OnLeave (`TransportAdapterBroadcastOnlySyncTests.swift:20–116`), whose claim becomes "OnLeave's sync runs in its turn";
  - `BroadcastSpyTransport`'s `leaveBeforeThrowStillBroadcasts` (`PerSequenceResultTests.swift:376`), likewise.
- **Tests that hold the legacy path's order** keep their lasting claim as in-turn tests. Each hold moves to a keeper hold point or a resolver hold at the same position in the turn. The lasting claims: one turn can't take another turn's sync request, outputs are handed off in apply order, and the forced shutdown runs its pass. These tests are:
  - the fakes that hold inside an async call to keep a legacy tick in flight: `DebugFreezeGatedKeeperTransport` (`LandKeeperDebugFreezeTests.swift:134`, :206–230), `BroadcastHoldTransport` (`DrainTurnTests.swift:160`, :333), and `HoldingTransport` and `BroadcastHoldingTransport` (`ResolverDeliveryTests.swift:229`, :249, :420, :491);
  - `TicklessReplayPassTests.legacySyncRequestStaysWithItsPass` (:451) and `legacyDeliveryKeepsApplyOrder` (:484);
  - `ShutdownTurnTests.legacyCallerPassAppliesTheShutdown` (:412), which waits on `.legacyShutdownPass`;
  - `TicklessReplayPassTests.legacyPassesRecordInApplyOrder` (:390). It awaits a second input while the first pass is held, so it deadlocks on the turn path. Its claim moves to two inputs in one batch.

  The assertions about the legacy path's suspension windows are retired.

The PR gives each test its fate and reason.

**Fakes on `.reevaluation` keepers** (`LandKeeperReevaluationOutputModeTests` :41) are reached through the mode. They stay, with the code they reach (§1), until #612 S2 and S6.

**The two transport requirements.** `syncNowFromTransport` and `syncBroadcastOnlyFromTransport` stay in `LandKeeperTransport`, since `.reevaluation` keepers' calls reach them (LK:3802, :4516, :5564). L2c deletes the adapter's implementations, and both requirements get do-nothing defaults with a doc comment: kept as a compatibility surface for keepers that replay, until #612 S6. `ReleasedLandTransport` keeps its drops (LKT:378–379), as the teardown placeholder.

Rejected:
- **A null transport that opts in.** It would run a sync phase that sends nothing, clear dirty flags every turn, and change what the 2e tests observe.
- **A `portless` init parameter** (rev 4). Its precondition trapped in teardown. It needed a transitional routing rule that flips at the attach. It still left unattached keepers on the legacy pass. And it changed the public init.

### 3.6 What L2c and L2d delete

**L2c: the off adapter.**
- the adapter's `inTurnSync` init parameter and `inTurnSyncEnabled` (TA:974), `ownExecutorHost` and `AdapterExecutorHost` (TA:106–112), and the package `inTurnSync` on `LandManager`'s init and `NIOLandServerConfiguration`. `LandManager.swift:697–698` read `true` in its place;
- `withSyncState` (TA:3297), `beginSyncLocatedIfRecording` (TA:3917), `legacyCycleRead` (TA:3903), `beginSyncRequests` (TA:748);
- the off adapter's cycle: `_syncNowImpl`'s cycle branch, `_syncBroadcastOnlyImpl` and `planBroadcastOnlySyncPhase` (TA:5234, :5281), the kept-event follow-up, the backlog and busy retry (`deferSyncForOutboundBacklog`, `runBacklogDeferredSync` and their fields), and `syncSkips.busy` with `SyncSkipCounts.busy`. The background-work tracker (`startBackgroundSync`/`backgroundSyncTasks`, TA:3166–3191) stays: the delayed repair and the lag timer's request use it;
- the off settle and resume (§3.4);
- the adapter's `syncNowFromTransport`/`syncBroadcastOnlyFromTransport` (`TransportAdapter+LandKeeperTransport.swift:15–21`). No live keeper calls them on an in-turn adapter, and no `.reevaluation` keeper has an adapter;
- the adapter's hold points only the off cycle reaches: `.cycleBeforeEndSync`, `.busyRetry` and `.followUpSynced`;
- the off arms of every explicit off caller (§2). `WallClockCadenceSmokeTests` keeps its on leg, and CI keeps the check that it ran;
- the legacy witnesses (`join-during-sync-cycle`, `TransportAdapterInTurnSyncTests.swift:927–937`), the remaining legacy-cycle cases, and the harness's legacy cells (§5.3);
- the readers of what L2c deletes, each converted or deleted:
  - `inTurnSyncEnabled`: `HybridEventsAtInitTests.swift:163`, `SyncStreamInitializeRecordTests.swift:178`, `TransportAdapterInTurnSyncTests.swift:987`;
  - `SyncSkipCounts.busy`: `TransportAdapterInTurnSyncTests.swift:833`, in the in-turn comparison;
- **`LandReleaseTests.lateDeliveryIsCounted`** (:412). It builds its manager with `inTurnSync: false` and holds `.legacyDelivery` through teardown, so it can't outlive L2c. It is retired there. Its lasting claim, that the released placeholder counts late keeper work, is already asserted by `DrainTurnTests.swift:325–328` (0, then 2).

These lists are examples, not the census: more readers exist (for example `DifferentialHarnessHooksTests.swift:172` and :199, `TransportAdapterPendingEventsAcrossCyclesTests.swift:830` and :849, `AtomicPatternIndexAdapterTests.swift:151`), and so do explicit `inTurnSync: true` arguments (`TransportAdapterJoinFlipTests.swift:151`, `TransportAdapterJoinHeldEventsTests.swift:165`). The L2c PR prints the census from a script: every reader of each deleted symbol, and every `inTurnSync:` argument, with its fate. It is checked at L2c's code review.

The keeper's routing doesn't change in L2c. Its callers of `beginSync`/`endSync` are only tests by then: L2b's settle uses `debugSettleTurn`.

**L2d: the keeper's legacy path,** with §3.5:
- on the keeper: `beginSync`, `beginSyncLocated`, `endSync()` and `endSync(clearDirtyFlags:)` (LK:1336–1395), `isSyncing` (LK:663), and the latch `syncOnlyTurnAfterLegacyCycle` (LK:704) with its reads in `runTurnOutputs` (LK:4629) and `runSyncOnlyTurn` (LK:5043);
- **the live legacy pass**: `finishTicklessLegacyPass`, `deliverLegacyPass`, `legacyDeliveries`, `runLegacyPass`, and `runSyncRequests`' `else if mode == .live` branch (LK:641–647). They are entered only from live branches (`runLegacyPass` around LK:1654, :1892, :2588 and :2914; `finishTicklessLegacyPass` at :3758), so `.reevaluation` keepers never reach them;
- `runTicklessJobPass`, its hold `.ticklessJobPass` and the `legacyPass*` fields (LK:3884–3890), unreachable once LK:2202 routes by mode. `TicklessActionJobTests.swift:425` holds `.ticklessJobPass` on its off arm, so that arm is deleted with them;
- `runSync`'s fallback call `transport?.syncNowFromTransport()` (LK:5564) is restricted to `.reevaluation` keepers. A live fake that doesn't opt in no longer receives it;
- the keeper's hold points `.syncOnlyAfterLegacyCycle`, `.legacyDelivery` and `.legacyShutdownPass`;
- `LandKeeperSyncLockTests` and the direct `beginSync`/`endSync` calls (§2).

Each off arm or legacy case is deleted, or converted when the in-turn path has the same claim to check. Each PR lists each test with its fate. No new off arm is added. If L2d's diff is too large to review in one piece, it splits into routing with the fakes, then the deletions, each green.

### 3.7 Hand-offs

**To #655 (B2's text).** B2's rewrite against one sync path takes these from L2:
- `.cycleBeforeEndSync` is gone; the settle's commit is `debugSettleTurn` (§3.4);
- a requested sync turn is a keeper input, `SyncTurnRequest` (reason, ticket, port), validated and retired in one keeper job (§3.2). Delays and their holds are the adapter's (`.failedPlanFollowUp`, `.syncLagTimerSync`), with the lag timer's epoch re-checked after its hold;
- decision 2's keeper-lock protocol and §3.4's coalescing "after `endSync`" are replaced by §3.4 here.

**To #612, when it resumes.** With Q3 (a) decided, #612 takes the predicate split as given:
- S2 adds `.record` keepers to `routesThroughTurn`, and may drop `syncsInTurn`'s mode term;
- S2 moves the `.reevaluation` fakes; S6 deletes the two transport requirements and what `.reevaluation` keepers reach (§1). The live legacy pass is L2d's, not S6's;
- §5.3's `SyncPlanMode` drops broadcast-only, which L2c deletes;
- #612 §3.3's "a recorder sets it under today's gate (LK:4881 …)" is the gate mix-up rev 1 had here (§3.5).

## 4. Steps

Order: **L2a → L2b → L2c → L2d.**
- L2b needs L2a's outside requests for its resume.
- L2c deletes the off settle that L2b leaves in place.
- L2d routes by mode alone, which needs every attached adapter to be in-turn, so it comes after L2c.

Each PR leaves `main` green, with the harness byte-identical except where §5 says.

**L2a: the syncs become turns on in-turn adapters** (groups 2a, 2b).
- **The new entry and requests** (§3.1, §3.2): `syncTurnNow(via:)`, `SyncTurnRequest`, the `keepsEvents` signal, the freeze-before-back-pressure order, the latch's counted rerun and the keeper's test wait.
  - On an in-turn adapter, `syncNow()` calls `syncTurnNow(via: self)`. The follow-up, the lag timer's sync and the behind-commit repair make requests.
  - On an off adapter all of these stay as they are, with the backlog and busy retry, `SyncSkipCounts.busy` and their holds, so the legacy cells and their witnesses don't change.
- **`syncBroadcastOnly()`'s entry point** is deleted, and its 17 calls converted (§3.3).
- **The cycle hold on in-turn adapters** (§2): each `SyncCycleHold` caller that holds a `syncNow()` gets its fate here, and so does the held-cycle half of `DiffLeaveTurnTests.heldCycleMovesTheLeaveSync`. A claim about work that arrives while a cycle is in flight has no in-turn window:
  - where the claim is about deferral, the test holds the writer instead (a deferred phase and its retry);
  - where the claim is the cycle's `endSync` hop, the test is deleted;
  - the settle's users of the hold wait for L2b (§3.4).

  The PR lists each test.
- **The harness:** `join-during-sync-cycle-inturn` is retired, and `join-during-writer-backlog` added (§5.2). The in-turn goldens are regenerated (§5.1).
- **`TransportAdapterBenchmarkHandle.syncNow`** forwards to the new `syncNow()`. The handle's `syncStateForNewPlayer` and its join with `completedInTurn == false` (used by `Rejoin.swift`) stay; they belong to the standalone initial sync.
- **Gate:** §6. Host A/B: yes.

**L2b: the freeze settle on in-turn adapters** (group 2c). §3.4, its tests included. The off settle stays until L2c.

**L2b delta, after L2a (#695).** Pointers are at #695's head 1a826823. Where this delta and §3.4 differ, this delta holds.
- **The kept-event path without caller 2.** L2a drops §3.2's caller 2 (§10a, with #695), so §3.4's sentence "the event takes §3.2's caller 2 during the freeze" no longer holds.
  - The event still reaches the resume. After the settle's commit, the adapter sets `deferredSyncNow` when events are queued and the land has no periodic sync (TA ~:6766, "events kept by this cycle need a follow-up"). That rule is the settle's own and doesn't use caller 2.
  - So `eventKeptBySettleArrivesAfterResume` keeps its claim: an event queued at `.settleBeforePublish` is delivered once, by the resume's `syncTurnNow(.resume)`.
  - **Step order:** the kept-events check stays in step 4, after the `.settleBeforePublish` hold and after the generation check. A check before the hold would miss the event the test queues there.
- **The resume's join-sync request** (step 2) keeps `requestJoinSyncTurn()` as it is. It reads the attached `transport`, not the bound requester. On an attached keeper the two are the same (`setTransport` rebinds, and `acceptsSyncTurn` requires the port to be the transport). A keeper bound only by its first request has no `transport`, so step 2 does nothing there, before L2b and after it. When the keeper's turns run on `TurnCore` (#700), the binding's port replaces `transport`. That isn't an L2b change.
- **The latch after L2b.**
  - Both of the latch's arm sites are in-turn keeper paths that meet `isSyncing`: a turn's sync with a legacy cycle in flight (LK :4694), and `runSyncOnlyTurn` (LK :5118).
  - `isSyncing` comes only from `beginSync`. After L2b its adapter callers are the off adapter's `withSyncState` (`_syncNowImpl`, `_syncBroadcastOnlyImpl` and the backlog retry, deleted in L2c) and the off settle. An off adapter's keeper runs no in-turn turns, so neither can latch.
  - So `syncDuringSettleCycleIsLatched` (`TransportAdapterInTurnSyncTests` :888) is retired in L2b, with no off-adapter arm.
  - The latch stays reachable only through a direct, deprecated `keeper.beginSync` on an in-turn keeper (tests or public API), until L2d deletes both. No test pins that window, since it lives only until L2d. Review may ask for one.
- **Carried from L2a's review:** `freezeIsCheckedBeforeBackPressure` (`TransportAdapterRequestedSyncTurnTests` :209) awaits `waitForOutboundIdleForTesting()` after its bounded wait, with no cancel path. L2b's first commit bounds it.

**L2c: the off adapter deleted.** §3.6's L2c list, and the harness's legacy cells (§5.3).
- Gate: the full `swift test`; the harness, which lists 84 cells and runs every one; the deletion census; and the GameDemo build, since L2c removes API EncodingBenchmark reads.
- The in-turn goldens are unchanged by this PR. The byte-identical check is the pinned-image job's: the Mac harness falls back to a decoded comparison when its toolchain differs from the recorder's.

**L2d: every live keeper on the turn path** (groups 2d, 2e). §3.5, and §3.6's L2d list. Its gate:
- the full `swift test`;
- the pin test under the `.wiring` hold;
- the recording comparison;
- the census script and its migration list;
- the GameDemo build, for the migrated callers;
- a `HashCostBenchmark` smoke run (`HashCostBenchmark.swift:50`);
- the harness, with §5.1's check script over the in-turn goldens as a guard: no change is expected.

**Docs, en and zh-TW, by PR:**
- **L2a:** `docs/core/runtime.md`'s sync deduplication and `syncNow` text (:94–104); `docs/transport/README.md:264`.
- **L2b:** the in-turn settle (`runtime.md` :434, :444–478).
- **L2c:** `runtime.md`'s Snapshot Sync Mode and Sync Flow (:41–62).
- **L2d:**
  - `beginSync`/`endSync` and `isSyncing`;
  - `docs/core/failure-handling.md:58`;
  - AGENTS.md § Reentrancy drops the freeze settle and the legacy tick path from its exceptions, and so does the root guide's copy of that section. The replay tick's exception stays until S6.

## 5. The harness

### 5.1 The in-turn goldens change in L2a

Every harness sync is `DiffRunner.sync()` → `adapter.syncNow()`. At 1075c23c the 84 in-turn goldens hold 308 records with `turnKind: legacyCycle`, 87 with `syncOnly` and 126 with `tick`. The 308 are stream totals: the standalone firstSync and the settle keep the tag; only the records of `syncNow()` change. After L2a each `syncNow()` is a sync-only turn.

The L2a PR carries a check script, run over the old and new goldens. It reports each cell's changes, classified by cause:
1. **The turn kind:** `legacyCycle` → `syncOnly` in those syncs' records.
2. **Tickless positions:** a tickless land's sync-only turn is a turn record (#327), so later turn positions move by one per sync.
3. **Joins that flip earlier:** a `syncNow()` while a join waits now completes it. The joiner's JoinResponse and firstSync move into that phase's frames.
4. **Merged events delivered earlier:** a requested turn (§3.2) can carry events the legacy path held for a later cycle.
5. **A phase deferred and retried:** where the writer held an earlier phase, the in-turn path defers and retries where the legacy cycle skipped.
6. **The freeze before back-pressure** (§3.2): a frozen phase with the writer held now records the freeze's deferral, not a back-pressure deferral.


L2d runs the same script as a guard. No change is expected: the legacy initialize already ends a tickless turn (LK:1233–1250), as `submitTurnRecord` does (LK:5030–5033), and neither harness land defines `OnInitialize` (`DiffLand.swift:108–175`). A change it shows is a bug.

Every other change is reported on its own, and the PR body has the table. A change outside these causes needs its own explanation, or it is a bug. Frames that none of these causes touch are byte-identical: both paths plan with `runFullSyncPhase` from the same state.

#676 (a flake in `disconnect-during-keeper-join`'s tickless in-turn cell, on the turn kind) is in this area. Its fix (#678, 41dc4da6) is on `main`, so L2a regenerates from it.

### 5.2 The retired rows

| Row | Retired in | Replacement |
|---|---|---|
| `join-during-sync-cycle-inturn` (`.inTurnOnly`, DS:386) | L2a | Its claim is the latch, which has no in-turn trigger once `syncNow()` is a turn. The join's side moves to `join-during-writer-backlog`. |
| `DiffLeaveTurnTests.heldCycleMovesTheLeaveSync`'s held-cycle half (#678) | L2a | The same claim, the latch, for a leave's sync. Retired with the row above. Its pinned-row half stays. |
| `join-during-sync-cycle` (`.legacyOnly`, DS:348) | L2c | `join-during-writer-backlog` (below). |
| `disconnect-sending-join-response` (`.legacyOnly`, DS:182) | L2c | Retired as unreachable (below). |
| `disconnect-sending-initial-sync` (`.legacyOnly`, DS:184) | L2c | Retired as unreachable (below). |

**`join-during-writer-backlog`**, on the in-turn cells, added in L2a. Two paths could flip the join besides the retry, and the row closes both:
- **The harness's waits.** `sync()` waits for background syncs (DR:577–580), and the barrier waits for sync quiescence (DR:602–620). Both would wait for the held retry, so neither runs while the writer is held.
- **The join's own request.** Making a join ready arms its `requestJoinSyncTurn` (TA:2304–2305, after `.joinSyncRequested`). That request could arm the retry before the row's sync, or flip the join after the release.

Steps:
1. Arm `.joinSyncRequested`, as `TransportAdapterJoinFlipTests.swift:390–423` does, then make the join ready. The join's own request waits at the hold.
2. Hold the writer.
3. **`.syncNoWait`** calls `syncNowReportingOutcome()` (§3.1) without the quiescence waits.
4. **`.expectSyncDeferred`** asserts, with the writer still held, that:
   - the outcome was `.deferredBackPressure`;
   - the backlog skip count went up by one;
   - the joiner has no JoinResponse yet.
5. Release the writer. Wait for the joiner's JoinResponse and firstSync, with `.joinSyncRequested` still held, so only the writer-drain retry can have flipped the join.
6. Release `.joinSyncRequested`, then run the barrier.
7. Assert exactly one JoinResponse and one firstSync for the joiner. The join's own request then finds nothing waiting.

Mutant: drop the retry after the writer drains (LK:5068). Step 5 then times out for want of the join's frames.

**The two router rows** cover the router's non-flip branch (LR:1123–1156), taken when the admission returns `completedInTurn == false`. After L2c no router join reaches it:
- the router always passes a response builder (LR:1050–1056);
- the adapter installs `expectedAdmissions` before `joinReportingAdmission`, in the membership job (the write at TA:2242);
- an in-turn keeper's admission consumes it synchronously and admits in-turn when it is there (`admitJoiningSessionIsolated`, TA:1969–1977).

So with every adapter in-turn, a router join always completes in-turn. L2c states this proof in its body and retires the rows on that ground. The general adapter API keeps a tested fallback with no port, and B3 deletes the branch with the standalone initial sync.

### 5.3 Counts per head, the self-check and the protected paths

| Head | Listed (in-turn + legacy) |
|---|---|
| today | 174 (84 + 90) |
| L2a | 174 (84 + 90): six cells added (`join-during-writer-backlog`) and six retired (`join-during-sync-cycle-inturn`) |
| L2b | 174 |
| L2c, L2d | 84 (84 + 0) |

`ran > 0 && ran + replaced == listed` holds at each head. L2c deletes the `.legacy` sync axis, its 90 goldens, the expected differences that name it, and the legacy cells embedded in `DiffSelfCheckTests.swift` (:23, :56, :140).

The harness files are protected paths. Every PR that edits the runner, the scenarios or the goldens (L2a and L2c) is a normal PR to `main`, outside `rewrite/546-*`, with no merge queue (`differential-paths.yml:24` runs on `merge_group`). Its goldens are recorded in the pinned image.

## 6. Gates and the A/B

Every step runs, on the Mac with the slot held:
- `swift build --build-tests`;
- the touched suites;
- the harness (`DifferentialHarnessTests`), quoting its "compared / replaced / listed" line;
- the step's mutants.

CI runs the full `swift test` and the E2E.

**L2a: a host A/B.** It measures EncodingBenchmark's driver path: its measured loop calls `syncNow()` (30 calls), which moves from the adapter's cycle to a keeper job. The claim is scoped to that driver. L2a also moves the lag timer's and the out-of-turn events' scheduling, which the benchmark doesn't measure. Production's periodic sync already runs `runSyncOnlyTurn`, so this sets that tool's new baseline. Base against L2a, both built from the pinned image, on the measurement host. The cell list is fixed with Main before the run, as B0's was (#655 §5.1), with MessagePack and JSON included. `MeasuredSync`'s skip check stays meaningful: the in-turn path counts a deferred phase in `syncSkips.outboundBacklog`. Attached and unattached keepers both appear among the measured cells: the worker pools' keepers are unattached (`BenchmarkExecution.swift:491`, :603, :687, :791), and the serial and multi-room builders attach (:314, :910, :1143). In both, `syncNow()` takes the same path, `syncTurnNow(via:)`.

**L2b–L2d: a Mac output check.**
- **L2b:** the freeze frames and records (`freeze-resume-messagepack` byte-identical).
- **L2c:** the harness, with the in-turn goldens unchanged (byte-identical in the pinned-image job).
- **L2d:**
  - the recording comparison (§3.5);
  - a `HashCostBenchmark` smoke run;
  - the GameDemo build.

  Some measured windows include ticks, which move onto turns in L2d: the worker-pool cells with `ticksPerSync > 0` (`BenchmarkExecution.swift:585–610`, :785–807), and the serial runs' `timeMs` (:193–198, :1008–1024). L2d gets a scoped A/B on those cells.

## 7. Public API

The adapter is `package` since E, so `syncNow()`, `syncBroadcastOnly()` and the `inTurnSync` parameter are already outside the public surface. Decided (Q1 (a)): the public breaks go with no deprecation. The full list:
- **L2a:** `TransportAdapterBenchmarkHandle.syncNow()` keeps its signature; on the in-turn adapter it gives, its behavior changes (§3.1). `InTurnSyncOutput` gains a package field (`keepsEvents`) and a package init parameter; its public init and `InTurnSyncResult` don't change.
- **L2b:** none. The settle's entry point is the keeper's package `debugSettleTurn` (§3.4).
- **L2c:**
  - `SyncSkipCounts.busy` (a public field and init parameter, `TransportAdapter+Outbound.swift:237–247`) is removed. Both `MeasuredSync.swift`s stop reading it.
  - The profiler's `syncSkipsBusy` JSONL field (`TransportProfilingActor.swift:595`) stays, always `0`, so the profile format doesn't change: `ws-loadtest/src/server-sync.ts:14` requires it, and old and new profiles parse alike. `METRICS.md:136` says it is always 0 since L2. Dropping it would be a format change for its own PR, with ws-loadtest and its test (`tests/server-sync.test.ts:14`) changed together.
  - `TransportAdapterBenchmarkHandle.inTurnSyncEnabled` (`TransportAdapterBenchmarkHandle.swift:59`) is removed. EncodingBenchmark writes `true` in its place in the record metadata (`EncodingBenchmarkMain.swift:158–159`), so records keep their shape.
  - `LandKeeperTransport.syncNowFromTransport()` and `syncBroadcastOnlyFromTransport()` stay as requirements with documented do-nothing defaults (§3.5). #612 S6 removes them.
- **L2d:**
  - `LandKeeper.beginSync(clearDirtyFlags:)`, `endSync()` and `endSync(clearDirtyFlags:)` are removed.
  - `LandKeeper.isUsingInTurnSync()` keeps its signature and its answers (§3.5). `LandKeeper`'s init doesn't change.
  - A behavior change, stated in L2d's body: a live custom transport that doesn't opt in (`runsSyncPhaseInTurn` → `false`) receives no sync and no delivery from turns after L2d.

Each PR's body restates its items.

## 8. Decisions by the maintainer (2026-11-20)

**Q1. The public removals (§7).** *Decided: (a).*
- (a) Remove them in L2, with no deprecation. Nothing calls them after L2, and there are no external users (2026-11-18).
- (b) Deprecate them in L2 and remove them later. They would stay as no-ops or traps, with a test each, until the removal.

The list is §7's: `LandKeeper.beginSync`/`endSync` (both overloads), `SyncSkipCounts.busy` and `TransportAdapterBenchmarkHandle.inTurnSyncEnabled`, in L2c and L2d. `LandKeeperTransport`'s two sync requirements move to #612 S6 under the same rule. The profiler field stays (§7).

**Q2. `syncBroadcastOnly()` (§3.3).** *Decided: (a).*
- (a) Delete it. Its callers use `syncNow()`, which runs the full phase, as an in-turn broadcast-only request already does (LK:637–640). The broadcast-only plan goes with it.
- (b) Keep it as a broadcast-only sync-only turn: a phase that diffs broadcast fields only and keeps the dirty flags.

The entry point goes in L2a. The plan goes in L2c, with the off adapter that still uses it (§3.3).

**Q3. Where the predicate split lands (§3.5).** *Decided: (a).*
- (a) In L2d, with #612's names (`routesThroughTurn`, `syncsInTurn`). #612 S2 takes the split as given and adds its `.record` keepers to `routesThroughTurn`.
- (b) In #612 S2, with L2d after S2. L2 would wait on S2, which waits on S1, #521's remaining PRs and #606.

**The requested turn's shape (§3.2).** *Decided: a keeper input that carries its reason and a ticket, validated in the turn,* the shape B2 gives the adapter's other callbacks. Not chosen: a keeper entry point with a pending flag.

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
- **The 2e keepers' tests assume the off path's order.** For example, a test that awaits an action's result before its handler's effects are visible: the turn path resumes a waiter after the turn record is submitted (LK:5381–5393). L2d's PR runs these suites with the change before converting anything, and lists the failures.
- **A requested turn lost to coalescing.** Only inside requests coalesce, and only before their job runs. The L2a PR tests:
  - an outside request while a delayed repair sleeps, or is held at `.failedPlanFollowUp`, runs at once;
  - the repair, when its delay and hold end, makes its own outside request, which runs its own turn;
  - an outside request that finds an inside request pending consumes it, and the pending job then retires without a turn;
  - an inside request made during a requested turn arms a new one;
  - a stale lag-timer callback neither requests nor clears a newer pass's mark.

## 11. Rev 7: what changed

| Change (from #680's rev 6 review) | Where |
|---|---|
| The resume's step 2 branches on step 1's outcome: skipped after a back-pressure deferral, which the retry or the next periodic phase owns; a refreeze across the call leaves the work deferred (MF1) | §3.4 |
| `join-during-writer-backlog` holds `.joinSyncRequested` so the join's own request can't flip it, observes the retry's flip before releasing that hold, and uses `syncNowReportingOutcome()` (MF2) | §3.1, §5.2 |
| One requester per never-attached keeper, bound on its first request; invalidated retries retire when the writer's drain wait returns; `transportHasJoinsAwaitingSync` reading the slot is harmless (should 1) | §3.2 |
| The binding by `ObjectIdentifier`, seeded from the init's `transport:`, with a binding generation; `failLand` and `onLandDestroyed` reach the bound port (should 2) | §3.2 |
| Capture before the `await`, validation in the synchronous job; the lag test holds the new callback until the old one retires; exact segments checked at L2a's code review (should 3) | §3.2 |
| L2c's reader lists marked as examples, the census script authoritative, checked at L2c's code review (should 4) | §3.6 |
| The tick-land pin asserts order and contents within the shared tick-0 record; a legacy tick across the attach, with the pin stepped by hand (should 5) | §3.5 |
| Nit: the lag admission at TA:3605–3610; `.syncNow` among the reasons; L2d's body states that a non-opting custom transport gets nothing from turns | §3.2, §7 |

## 12. Rev 6: what changed

| Change (from #680's rev 5 review) | Where |
|---|---|
| Which adapters may request (the attached one, or one whose keeper was never attached) and the binding check; the port carried through the writer-drain retry, the latch's rerun, the join-sync follow-up and the inside request; `failLand` closes the failing port when the slot is nil; coalescing only for the same port, with the entry cleared before the phase (MF1) | §3.1, §3.2 |
| A turn that ran isn't a delivery: each outcome names who delivers; the resume's tests name the delivering phase for a free writer, a held writer without periodic sync and a periodic land; `join-during-writer-backlog` observes the deferral with steps that don't wait, then releases the writer before the barrier (MF2) | §3.2, §3.4, §5.2 |
| L2c's deletion census: the readers of `inTurnSyncEnabled` and `SyncSkipCounts.busy`; `LandReleaseTests.lateDeliveryIsCounted` retired in L2c, its claim already in `DrainTurnTests`; the background-work tracker stays (should 1) | §3.5, §3.6 |
| Where each request's ticket is captured; the lag mark checked against the epoch at admission and at retirement, with its test (should 2) | §3.2 |
| An in-turn arm for `InitialSyncBehindCommitTests` in L2a (should 3) | §3.2 |
| L2d also deletes `runTicklessJobPass`, `.ticklessJobPass` and the `legacyPass*` fields, and restricts `runSync`'s fallback to `.reevaluation` (should 4) | §3.6 |
| Cause 7 dropped, the L2d script kept as a guard; the pin runs with a recorder and a tick under the hold (should 5) | §3.5, §4, §5.1 |
| Nits: `LandManager.swift:697–698`, the admissions write at TA:2242, the SyncLag default at :189, the `runLegacyPass` callers; the L2d A/B names the cells whose windows include ticks; the GameDemo build in L2c's gate | §2, §3.6, §4, §5.2, §6 |

## 13. Rev 5: what changed

Pointers now refer to `main` at 1075c23c (B0 in). Only TA, `TransportAdapter+Outbound.swift`, DS, DR and `ReevaluationSyncStream.swift` moved, by a few lines.

| Change (from #680's rev 4 review, and the maintainer's decision) | Where |
|---|---|
| A requested sync turn is a keeper input with a reason, a ticket and a port, validated, run and retired in one synchronous keeper job; a control input outside the tick queue and the recorder (decision; should 2) | header, §3.2, §3.7, §8 |
| `syncTurnNow(via:)`: the adapter names itself, so unattached keepers (the SyncLag fixture, EncodingBenchmark's worker pools) keep working; the A/B says which cells attach (MF1) | §2, §3.1, §6 |
| When a request is done: the freeze checked before back-pressure; outside requests run before returning and consume pending inside requests; joins over the budget and periodic lands; the latch's rerun counted by the test wait (MF2) | §3.2, §3.4, §5.1, §10 |
| The `.wiring` test pins today's outcome (no client gets a pre-attach event), instead of asking for a first-frame delivery (MF3) | §3.5 |
| L2c and L2d swap: the off adapter goes first, then routing by mode alone; `portless` and the transitional rule are dropped; sync eligibility stays `runsSyncPhaseInTurn(of:)`, not `transport != nil`; teardown unchanged (MF4, should 4) | header, §3.5, §3.6, §4, §5.3, §6, §7 |
| The census as a migration list, by builder (should 1) | §3.5 |
| The lag timer's mark keyed by epoch; the coalescing rule reconciled with §10 (should 2) | §3.2, §10 |
| `LandReleaseTests.lateDeliveryIsCounted`'s lasting claim (should 3) | §3.5 |
| Nits: the tick cell for the at-once check (DR's `.tick` cells), the SyncLag and repair suites kept for their callers; 21 `usesInTurnSync` reads; LK:670–671 | §3.2, §3.5 |
| L2c's byte-identical claim is the pinned-image job's; the GameDemo build is in L2d's gate | §4, §6 |

## 14. Rev 4: what changed

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

## 15. Rev 3: what changed

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

## 16. Rev 2: what changed

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
