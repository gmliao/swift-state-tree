# Remove the adapter's off mode on live lands (#546 L2)

**Status:** rev 8, GO for L2d-1 (2026-11-21). L1 (#677), L2a, L2b (#712) and L2c (#718, follow-ups #724) are merged. §3.8 holds L2d; L2d-2 waits on the maintainer's decision on a live transport that doesn't opt in (§3.8.6).
- **Decided (the maintainer, 2026-11-20):**
  - §8's Q1 (a), Q2 (a) and Q3 (a); Q4, the settle as a sync-only turn in L2d (decided after #712's review);
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
- What `.reevaluation` keepers reach: `processPendingActions`, `replayRecordedPasses`, the replay broadcast calls (LK:3802, :4516), the sync loop's transport call (LK:5564), and `LandKeeperTransport`'s `syncNowFromTransport`/`syncBroadcastOnlyFromTransport`, kept with do-nothing defaults from L2d (§3.5). `LandKeeperReevaluationOutputModeTests` keeps its `.reevaluation` keepers.
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

*Rule: whenever sync work is due outside a turn on an in-turn land, something asks the keeper for a sync-only turn. No flag waits for an adapter cycle to read it.* One exception: an event queued outside a turn, on a land without periodic sync, waits for the next sync (L2a delta, below). On an off adapter the legacy follow-up and retries stay until L2c.

**Decided (the maintainer, 2026-11-20): a requested sync turn is a keeper input that carries its reason and a ticket, validated in the turn.** This is the shape B2 gives the adapter's other callbacks: one place to inspect, and one thing to hold in tests. Not chosen: a keeper entry point with a pending flag.

**The input.** `SyncTurnRequest` has three fields:
- **`reason`**: `.syncNow`, `.keptEvents`, `.lagTimer`, `.behindCommitRepair` or `.resume`. It is for diagnostics and tests. No handling depends on it.
- **`ticket`**: the keeper's own lifecycle generation. It is bumped when the land fails and when the drain starts. Where it is captured:
  - an inside request captures it in the turn that makes it;
  - a delayed request (the repair, the lag timer's) captures it when its delay starts, before the sleep and the hold;
  - an immediate outside request (`syncNow()`, the resume) captures it at the call. Its job runs right after, so for these the check rarely fails; it matters for the other two.

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
- **From outside the keeper:** the adapter's requests (the lag timer, the repair, the resume) and `syncNow()`. The request's job runs the turn at once. It also consumes a pending inside request for the same port: it clears that entry before the phase runs, so the phase can arm a successor. It never returns early because a request is pending, so when the caller's await returns, the turn that covers its request has run. What that turn delivered is a separate question (below). The resume relies on both (§3.4).
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

**The callers on an in-turn land.** Callers 1–3 are on lands without periodic sync. The resume, caller 4, isn't limited to those, because `debugReleaseFreeze` has no such guard (TA:6641).
1. **Kept events after a commit.** The phase reports whether events are still queued after its commit, whether it kept them or they were queued after it. The signal is a package field on `InTurnSyncOutput`, `keepsEvents`, set by the adapter's package init. `InTurnSyncResult` and the public init don't change. In `applyInTurnSyncResult`'s `.committed` case, `keepsEvents && !hasPeriodicSync` makes an inside request. This is the legacy follow-up's rule (TA:3280–3287). A phase that ends the land requests nothing.
2. **The lag timer**, as above.
3. **The behind-commit repair**, as above. The standalone firstSync it follows keeps its re-checks (§1).
4. **The settle's kept events** and **the resume's deferred syncs** (§3.4).

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
4. **Publish** after the call, with the generation checked again (TA:6594–6606). Then, after that check and after the `.settleBeforePublish` hold (tests below), the kept-events check: events still queued on a land without periodic sync set `deferredSyncNow`, so the resume delivers them (today's rule, TA ~:6766 at 1a826823). It stays after the hold, so an event queued at the hold is seen.

**The record.** The settle records its sync output under `.legacyCycle`, as today, with the same position source. So `freeze-resume-messagepack` (`SyncOutputGoldenTests.swift:21–22`, :47, :96) stays byte-identical. A new turn kind would be a record-format change.

**The resume** (TA:6616–6652) runs in this order:
1. **The deferred sync**, as one outside request (§3.2), awaited. An outside request runs its turn before it returns, even when an inside request is pending, so the turn that covers the deferred sync has run when the resume goes on.
2. **The join-sync turn request**, as today (TA:6648–6650; `requestJoinSyncTurn` runs its turn synchronously, LK:1932–1942).

The freeze is off when step 1 runs. After L2b nothing on an in-turn adapter takes `beginSync`: the settle doesn't, and the broadcast-only bridge becomes a requested turn (L2b delta in §4). So step 1's turn can't be frozen, and it can be latched only by a direct `keeper.beginSync` call. **Step 2 branches on step 1's outcome.** `requestJoinSyncTurn` has no deferral check on a land without periodic sync (LK:1932–1943); `joinSyncWaitsForCommit` and `periodicJoinSyncAllowed` exist only for periodic lands (LK:1949–1952, :4672). So the resume decides:
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
- `eventKeptBySettleArrivesAfterResume` and `leaveDuringSettleSendsFlagsMembership` (`TransportAdapterPendingEventsAcrossCyclesTests` :1020–1057) arm the cycle hold and wait for the settle to reach it. They move to a new adapter hold, `.settleBeforePublish`, after `debugSettleTurn` returns and before step 4. The segment itself is synchronous and can't hold, and a hold before it would invert both tests: a leave before the copy gives the settle the epoch after the leave, and an event queued before it would go out in the settle's phase while frozen. After step 3, the leave flags `membershipChanged`, and the event is kept: step 4's kept-events check sets `deferredSyncNow`, so it is delivered once, after the resume.
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

**The two transport requirements.** `syncNowFromTransport` and `syncBroadcastOnlyFromTransport` stay in `LandKeeperTransport`, since `.reevaluation` keepers' calls reach them (LK:3802, :4516, :5564). The adapter keeps its implementations until L2d, as forwards to one requested sync-only turn (§3.6), since a live keeper's legacy paths still reach them. L2d deletes the forwards, and both requirements then get do-nothing defaults with a doc comment: kept as a compatibility surface for keepers that replay, until #612 S6. `ReleasedLandTransport` keeps its drops (LKT:378–379), as the teardown placeholder.

Rejected:
- **A null transport that opts in.** It would run a sync phase that sends nothing, clear dirty flags every turn, and change what the 2e tests observe.
- **A `portless` init parameter** (rev 4). Its precondition trapped in teardown. It needed a transitional routing rule that flips at the attach. It still left unattached keepers on the legacy pass. And it changed the public init.

### 3.6 What L2c and L2d delete

**L2c: the off adapter.**
- the adapter's `inTurnSync` init parameter and `inTurnSyncEnabled` (TA:974), `ownExecutorHost` and `AdapterExecutorHost` (TA:106–112), and the package `inTurnSync` on `LandManager`'s init and `NIOLandServerConfiguration`. `LandManager.swift:697–698` read `true` in its place;
- `withSyncState` (TA:3297), `beginSyncLocatedIfRecording` (TA:3917), `legacyCycleRead` (TA:3903), `beginSyncRequests` (TA:748);
- the off adapter's cycle: `_syncNowImpl`'s cycle branch, `_syncBroadcastOnlyImpl` and `planBroadcastOnlySyncPhase` (TA:5234, :5281), the kept-event follow-up, the backlog and busy retry (`deferSyncForOutboundBacklog`, `runBacklogDeferredSync` and their fields), and `syncSkips.busy` with `SyncSkipCounts.busy`. The background-work tracker (`startBackgroundSync`/`backgroundSyncTasks`, TA:3166–3191) stays: the delayed repair and the lag timer's request use it;
- the off settle and resume (§3.4);
- not the adapter's `syncNowFromTransport`/`syncBroadcastOnlyFromTransport` (`TransportAdapter+LandKeeperTransport.swift:15–21`): they stay until L2d. A live keeper still reaches them on an in-turn adapter through its legacy paths until then (for example, a legacy pass queued before an attach reads the transport after its awaits, LK :3938 at 1a826823). From L2b both forward to `syncTurnNow` on an in-turn adapter (L2b delta in §4), so deleting the off cycle under them changes nothing they do. No `.reevaluation` keeper has an adapter;
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
- the adapter's forwards `syncNowFromTransport`/`syncBroadcastOnlyFromTransport`, kept through L2c; the two requirements get their do-nothing defaults (§3.5);
- `runSync`'s fallback call `transport?.syncNowFromTransport()` (LK:5564) is restricted to `.reevaluation` keepers. A live fake that doesn't opt in no longer receives it;
- the keeper's hold points `.syncOnlyAfterLegacyCycle`, `.legacyDelivery` and `.legacyShutdownPass`;
- `LandKeeperSyncLockTests` and the direct `beginSync`/`endSync` calls (§2);
- **the settle's keeper job** (§8, Q4). The in-turn freeze settle becomes a requested sync-only turn, `SyncTurnReason.settle`, through `runSyncPhaseInTurn`. Its fence (the deadline, the same frozen generation, and no failure or drain) is checked in the turn, and the frozen land's skip exempts that reason. `LandKeeper.debugSettleTurn`, `DebugSettleTurnOutcome` and the adapter's two isolated callbacks (`debugSettleAdmitIsolated`, `debugSettleCommitIsolated`) go. `scripts/lint-turns.sh` lowers `TransportAdapter.swift`'s allowance from 5 back to 3. The settle's output is then recorded as a sync-only turn, not `.legacyCycle`. That changes one record and golden: `freeze-resume-messagepack`, plus any harness cell that freezes. They are regenerated in the pinned image, with the change classified (`classify-golden-changes.py`).

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

### 3.8 L2d (rev 8)

Rev 8 adds this section; §10b lists what changed. Where this section and §3.5, §3.6 or §7 differ, this section holds.

**Base:** `main` at a72b007c. Since 63f3db18 only plan documents changed (#716), so the code pointers are the same as at 63f3db18.
- "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift` (6219 lines).
- "LKT" is `Sources/SwiftStateTree/Runtime/LandKeeperTransport.swift`.
- "TA" is `Sources/SwiftStateTreeTransport/TransportAdapter.swift` (6381 lines).
- "OW" is `Sources/SwiftStateTreeTransport/OutboundWriter.swift`.

#### 3.8.0 What #719 changes for L2d

#719 changed only `SwiftStateTurns`, so no L2d step changes. It does add two constraints:
- **L2d lands before #700.** #719 dropped `.held` and `releaseFollowUp`, on the assumption that L2d deletes their only user, the latch `syncOnlyTurnAfterLegacyCycle` (turn-core plan §3.3, §5.4).
- **`waitForQuiescence` isn't usable here.** The keeper isn't on `TurnCore` until #700, so `waitForRequestedSyncTurnsForTesting` stays. L2d-3 drops the latch from `requestedSyncWork` (its doc comment at LK:5428).

#### 3.8.1 Staleness of §3.5, §3.6 and §7

The pointers are refreshed; no item became stale in substance. One correction: **no differential cell freezes.** `git grep -i freeze` under `Tests/SwiftStateTreeNIOTests/Differential/` finds nothing.
- The settle's golden change is the sync-output set `freeze-resume-messagepack`, four files under `Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens/`. It is regenerated with `Tools/regenerate-sync-output-goldens.sh`.
- `classify-golden-changes.py` runs over the 84 harness goldens as a guard and must report no change.

Pointer map (plan pointer → a72b007c):

| Item | Plan pointer | Now |
|---|---|---|
| `usesInTurnSync` | LK:672 | LK:719 (21 reads, see the table in §3.8.4) |
| `setTransport` | LK:467 | LK:475 |
| `runTickTurn` | LK:4705 | LK:4827, called at LK:4426 |
| `runInputTurn` output branch | LK:5442 | LK:5799 |
| initialize | LK:1193 | LK:1262 |
| `runSync` and its fallback | LK:5509–5564 | LK:5866–5921 |
| `beginSync` … deprecated `endSync(clearDirtyFlags:)` | LK:1336–1395 | LK:1380–1464 |
| `isSyncing` | LK:663 | LK:710; reads at LK:1406, :1409, :1437, :4740, :5166 |
| the latch | LK:704 | LK:762, :765; its rerun :1452; set at :5194–5197 |
| `runSyncRequests`' live branch | LK:641–647 | LK:687–694 |
| `runLegacyPass` callers | LK:1654, :1892, :2588, :2914 | LK:1774, :2012, :2714, :3040 |
| `finishTicklessLegacyPass` | LK:3758 | called LK:3888, declared :3955; `deliverLegacyPass` :3998; `legacyDeliveries` :796 |
| `runTicklessJobPass` | — | LK:2349, called :2335; `legacyPass*` fields :4010–4016, also used at :3871–3882, :4025–4037, :5688–5690 |
| reevaluation broadcast calls | LK:3802, :4516 | LK:3928, :4627 |
| hold points | — | LK:59, :73, :82, :87 |
| settle | — | `DebugSettleTurnOutcome` LK:1588, `debugSettleTurn` LK:1615; TA:6179–6268 |
| default opt-out; released placeholder | LKT:281; LKT:351 | LKT:304; `ReleasedLandTransport` LKT:374 |
| lint allowance | — | `scripts/lint-turns.sh:48` (`TransportAdapter.swift 5`) |

#### 3.8.2 Order: three PRs

**Size:** about −700/+250 in Sources, −1100/+700 in Tests and ±150 in docs. That is over one review, so the change is split. Review agreed on this order. Each PR leaves `main` green, carries its own docs, and has a **revert check**: revert that PR's Sources commit locally, then show that its new tests fail by name.

1. **L2d-1, the settle as a sync-only turn** (§3.8.3). It has the only golden change and doesn't depend on the routing.
2. **L2d-2, routing every live keeper by mode, with the fakes and the transport refusal** (§3.8.4, §3.8.6).
3. **L2d-3, the deletions; the forwards become defaults** (§3.8.5).

#### 3.8.3 L2d-1: the settle as a sync-only turn (Q4)

**The types.** All are package; L2d-1 adds no public API (Review's should 1 on rev 8). The settle phase is a package refinement of `LandKeeperTransport` that only `TransportAdapter` conforms to, in the same package.

```swift
// SwiftStateTree, LandKeeperTransport.swift
package struct InTurnSettle: Sendable, Equatable {
    package let generation: UInt64
    package init(generation: UInt64)
}
package enum InTurnSettleCommit: Sendable, Equatable {      // what the adapter's settle phase did
    case committed(membershipEpoch: UInt64, clearDirtyFlags: Bool)
    case empty(membershipEpoch: UInt64)                      // no members: copy taken, nothing planned
    case refused(InTurnSettleRefusal)
    case failed(LandFailure)
}
package enum InTurnSettleRefusal: Sendable, Equatable { case notCurrent, outputClosed, writerBusy, syncInFlight }
// InTurnSyncOutput gains `package let settle: InTurnSettleCommit?` (package init param, default nil)

// SwiftStateTree: a package refinement, so no public requirement is added
package protocol LandKeeperSettlePort: LandKeeperTransport {
    func runSettlePhaseInTurn<S: StateNodeProtocol>(state: S, settle: InTurnSettle, recording: InTurnSyncRecording?) -> InTurnSyncOutput
}
// TransportAdapter: LandKeeperSettlePort (same package)

// LandKeeper
package struct SettleFence: Sendable { package let generation: UInt64; package let deadline: ContinuousClock.Instant }
package enum SettleTurnOutcome<State: Sendable>: Sendable {
    case settled(state: State, tickId: Int64, membershipEpoch: UInt64, planned: Bool)
    case timedOut, released, closed
    case refused(InTurnSettleRefusal)     // the adapter's admission refused
    case failed(LandFailure)              // the plan threw; the land ended in this turn
}
package func settleTurn(via port: any LandKeeperTransport, fence: SettleFence) -> SettleTurnOutcome<State>
//   guard let port = port as? any LandKeeperSettlePort else { return .refused(.notCurrent) }
```

**MF1: the settle context rides in the one phase call.** There is no adapter-wide `settling` flag. The keeper passes `InTurnSettle` only to `runSettlePhaseInTurn`, inside its synchronous turn. The adapter's ordinary `runSyncPhaseInTurnResult` is unchanged, so every other phase keeps the frozen defer, back-pressure and joiners.
- The adapter's `runSettlePhaseInTurn` is a separate function. It skips the frozen defer and back-pressure, passes no joiners, and takes the membership epoch in the same segment as the plan. It returns `InTurnSyncOutput(result, syncStream:, settle:)`.
- **The ticket.** `debugSettle` captures the freeze generation as a `GenerationTable` ticket (`debugFreezeTickets`) before the drain. Every check after an await uses `ifCurrent(ticket)`: after the drain, after the writer wait, after the turn, and at publish, where the closure writes `debugFreezeState.settled`. So an older continuation can't publish over, or clear, a newer settle's state after a release and refreeze. `debugReleaseFreeze` advances the table.
- **Test** (`TransportAdapterDebugFreezeTests`, new):
  - hold at `.settleBeforeCommit`, run an ordinary `syncNow()` and a tick while frozen, and assert both return `.skipped`, set `deferredSyncNow` and plan no joiner;
  - release and refreeze during the hold, then release the hold: the old settle throws `.released`, the new generation's settle publishes, and the old continuation writes nothing.
  - Mutant: an adapter flag read by the ordinary phase. The first assertion fails.

**MF2: a typed outcome from the turn.** The copy, `lastCommittedTickId` and the epoch are captured in the turn's one synchronous segment and returned together in `.settled`. There is no `debugLastCommittedTickId()` call after the await, and no re-reading of adapter state to name an error.
- The adapter maps the outcome:

  | Outcome | Adapter |
  |---|---|
  | `.timedOut` | `settleTimedOut` |
  | `.released` | `released` |
  | `.closed` | the cause: the land's `LandFailure` when it failed, a closed error when it is draining (not `released`) |
  | `.refused(.notCurrent)` | `released` |
  | `.refused(.outputClosed)` | the cause, as for `.closed` (not `released`) |
  | `.refused(.syncInFlight)` | back to the writer wait while the deadline allows, as for `.writerBusy`; then `settleTimedOut` |
  | `.refused(.writerBusy)` | back to the writer wait while the deadline allows; then `settleTimedOut` |
  | `.failed(f)` | throw `f` |
  | `.settled` | publish, in `ifCurrent` |

- **An empty land succeeds:** `.settled(…, planned: false)`. The copy is taken, the dirty flags aren't cleared, and nothing is recorded, as today (TA:6264).

**MF3: the settle's own bookkeeping, not `runSyncOnlyTurn`'s** (LK:5162). `settleTurn` is its own function. In order:
1. **Fence, in this order.** Each failing check returns without running a phase or changing state:
   - `mode == .live, failure == nil, !isDraining` → else `.closed`;
   - `ContinuousClock.now < fence.deadline` → else `.timedOut`;
   - `debugFrozen && debugActiveGeneration == fence.generation` → else `.released`;
   - the port is the attached `transport` (identity) and `port.runsSyncPhaseInTurn(of: self)` → else `.refused(.notCurrent)`. There is no `bindSyncRequester` and no binding ticket: the settle never binds a requester, and the fence is checked before any binding is read.
   - **While L2d-1 coexists with `isSyncing`:** `isSyncing` true (only a direct public `beginSync` can set it) → `.refused(.syncInFlight)`, its own refusal, retried like `.writerBusy`. It never latches.
2. **Not consumed or reset:**
   - `pendingSyncTurnAfterTurn`. Its turn runs later, skips as frozen and sets `deferredSyncNow`, so the resume delivers it.
   - `inTurnSyncDue`, `joinSyncWaitsForCommit` and the drain-retry binding.
   - No `scheduleJoinSyncTurn` and no `.keptEvents` request. The resume's step 2 and the adapter's kept-events check after publish own those (§3.4).
3. **The phase:** `inTurnSyncTurnKind = .syncOnly`, then the `runSettlePhaseInTurn` call. `submitSyncStream(output.syncStream)`.
   - `.committed(_, clear)`: `state.clearDirty()` when `clear`.
   - `.empty`: nothing.
   - `.failed(f)`: `failLand(f)` in this turn. It is terminal (MF4).
   - `.refused`: no record.
4. **The record:** on a tickless land, `enqueueTicklessTurnEnd(since:)`, as for any sync-only turn (#327). `requestedSyncTurnsForTesting[.settle] += 1` (a new `SyncTurnReason.settle`). The `turn-begin` and `turn-end` probes.

**MF4: the failure ends the land in the settle's turn (Q2 decided), with a compatibility contract.**
- **New records:**
  - **Tick land:** the failure is recorded in the last committed tick's frame. That frame has no `endsInputs`, because the failure ends no input batch.
  - **Tickless land:** the failure shares the last pass, at the keeper's position (`LandFailurePosition(stage: .syncPhase)` with no tick or pass takes the keeper's).
  - **Both:** the committed-output prefix is every output before the settle, and the failed settle has no output.
- **Old records stay replayable.** Pins, as new tests in `SyncOutputVerifierTests`, each verdict `.passed` with 0 mismatches:
  1. **an old successful settle:** a copy of today's `freeze-resume-messagepack.reeval.sstr`, kept as the fixture `freeze-resume-legacy-cycle-messagepack.reeval.sstr`, replays after L2d-1;
  2. **an old queued failure:** a record made on the base by `settleFailureEndsTheLand`'s scenario, with the failure applied by the next tick and `endsInputs` on that frame, kept as `settle-failure-queued-tick.reeval.sstr`, replays after L2d-1;
  3. **a new failure on a tick land:** the frame, position and prefix as above;
  4. **a new failure on a tickless land:** the same, on the last pass.
- **`DebugFreezeSettleFailureTests.settleFailureEndsTheLand`** (`SyncOutputVerifierTests:1502`) drops `stepTickOnce`, and the land has failed when `debugFreeze()` throws. Its negative assertion stays scoped: no output has the settle's stream index or later. It isn't broadened to `!contains(.syncOnly)`, because earlier sync-only outputs exist.

**The writer wait (should).** The 2 ms poll (TA:6186–6190) becomes `outboundWriter.waitForSyncCycleDrain()` (OW:264), made cancellation-aware with #724's waiter-table rule: register under the lock with a `Task.isCancelled` check, and a handler that only removes a registered waiter. It is bounded by the fence's deadline with a timer task that cancels the wait.
- After it returns, `ifCurrent(ticket)` and the deadline are re-checked.
- The backlog is re-checked at admission: `runSettlePhaseInTurn` returns `.refused(.writerBusy)` when a sync-cycle element entered since, and `debugSettle` loops back to the wait.
- **Test:** a writer that never drains gives `settleTimedOut` at the deadline, with no task left behind (`withinHangBound`). Mutant: the old uncancellable wait hangs the bound.

**Deleted in L2d-1:**
- `DebugSettleTurnOutcome` and `debugSettleTurn` (LK:1588–1635);
- `debugSettleAdmitIsolated`, `debugSettleCommitIsolated` and `DebugSettleCommit` (TA:6168–6268), with their two `assumeIsolated` closures;
- `lint-turns.sh:48` goes from 5 to 3.

**Tests:**
- The three `.legacyCycle` assertions become the settle's sync-only output, matched by the settle's stream index:
  - `SyncOutputVerifierTests.legacyCycleIsVerified` (:951), renamed `settleSyncTurnIsVerified`;
  - `SyncStreamProducerTests.legacyCycleAndStreamOrder` (:470), with kinds `seed, tick, tick, syncOnly, clear`;
  - `TicklessPassOrdinalTests.legacyCycleCommitsVerify` (:261): its own turn record, and the later turns' positions move by one.
- The fence cases each run between the last writer check and the turn, with nothing planned: release, refreeze, shutdown, deadline expiry, and a direct `beginSync`.

**Docs:** `runtime.md` In-Turn Sync's settle text (:434, :444–478 region) and `failure-handling.md`'s settle row, in en and zh-TW.

**Gate:**
- the touched suites;
- the harness 84/84, with `classify-golden-changes.py` reporting no change;
- `freeze-resume-messagepack` regenerated in the pinned image, classified as cause 1 only (`legacyCycle → syncOnly`, frames byte-identical);
- the 4 replay pins;
- the revert check.

**A/B:** none (debug tooling).

#### 3.8.4 L2d-2: routing every live keeper by mode

**Order:**
1. The pin test (§3.5, under the `.wiring` hold, tick and tickless) on the base.
2. The predicates: `routesThroughTurn` is `mode == .live`; `syncsInTurn` is today's `usesInTurnSync`.
3. The transport refusal (§3.8.6).
4. The fakes.
5. The census and the recording comparison.

**The predicates, per read (should):**

| Site | Read | Predicate |
|---|---|---|
| handler sync requests | LK:684 | `syncsInTurn`. Otherwise, live: dropped. `.reevaluation`: today's call |
| `isUsingInTurnSync()` | LK:917 | `syncsInTurn` (answers unchanged) |
| initialize | LK:1262 | turn: `routesThroughTurn`; phase: `syncsInTurn`; marker: `recordsSyncStream` |
| join (tickless) | LK:1771, :2009 | `routesThroughTurn` |
| admission helpers | LK:2023, :2031, :2038, :2044 | `syncsInTurn` (they call the port) |
| action (tickless) | LK:2328, :3035 | `routesThroughTurn` |
| leave (tickless) | LK:2711 | `routesThroughTurn` |
| forced tickless shutdown | LK:2783 | `routesThroughTurn` |
| client events | LK:3172 | `routesThroughTurn` |
| server input kick | LK:3279 | `routesThroughTurn` |
| tickless step in `runTick` | LK:4376 | `routesThroughTurn` |
| tick turn | LK:4426 | `routesThroughTurn` (the phase inside on `syncsInTurn`) |
| `recordsSyncStream` | LK:5003 | `mode == .live && reevaluationRecorder != nil && syncsInTurn` |
| `runSyncOnlyTurnIfInTurn` | LK:5186 | `syncsInTurn` |
| tickless turn outputs | LK:5799 | below |
| `runSync` | LK:5896 | `syncsInTurn`. The fallback (LK:5921) only on `mode == .reevaluation` |

**With no port opting in:**
- **The input turn (LK:5799).** When the batch is non-empty and the land hasn't failed, the turn takes the events and the sync request (`takeEmittedEvents`, `takeSyncRequest`). They are recorded by `makeTurnRecord` and then dropped, so the collector is drained. `runTurnOutputs` runs only when `syncsInTurn`.
- **The tick turn.** `runTickTurn(transport: (any LandKeeperTransport)?)` takes the tick's events and sync request on the same rule.

**Census (should).** `scripts/l2d-census.sh`, in the L2c shape.
- **Counting rule:** non-comment lines (lines whose first non-space characters are `//` are skipped) in `Sources Tests Examples Tools`, per symbol, at the base and at HEAD.
- **Allowlist:** `scripts/l2d-census.allow` lists `path symbol count reason`. Examples:
  - `.legacyCycle` in `ReevaluationSyncStream.swift`, TA:3819 and TA:5205 (the standalone firstSync, until B3);
  - `syncNowFromTransport` and `syncBroadcastOnlyFromTransport` in the LKT requirement, its default and `ReleasedLandTransport`;
  - the test fakes' conformances;
  - the `.reevaluation` replay path (`processPendingActions`, `replayRecordedPasses`).
- A count above the allowlist fails. The script also prints the migration list of keepers with no port (§3.5).

**Fakes:** §3.8.8.

**Docs:**
- `runtime.md`: live keepers without an in-turn transport run turns, and their outputs are recorded, not delivered. "Re-evaluation keepers always use the legacy path" (:436) stays.
- transport README: the refusal (§3.8.6).

Both in en and zh-TW.

**Gate:**
- full `swift test`;
- the pin;
- the recording comparison (§3.5);
- the census;
- the GameDemo build;
- the `HashCostBenchmark` smoke;
- the harness (no change expected);
- the A/B (§3.8.9);
- the revert check.

**Between L2d-2 and L2d-3 (Q4 decided).** The live-only legacy entries stay in the code but are unreachable, each guarded with `precondition(mode == .reevaluation)` or `preconditionFailure` (not `assert`, which release builds drop): `runLegacyPass`, `finishTicklessLegacyPass` and `runTicklessJobPass`.

#### 3.8.5 L2d-3: the deletions

**Deleted from the keeper:**
- `beginSync`, `beginSyncLocated`, `endSync()` and `endSync(clearDirtyFlags:)` (LK:1380–1464);
- `isSyncing` and its reads (LK:4740, :5166);
- the latch (LK:762, :765, :1452, :5194–5197) and its share of `requestedSyncWork`;
- the legacy pass: `runLegacyPass`, `finishTicklessLegacyPass`, `deliverLegacyPass`, `legacyDeliveries`, the `legacyPass*` fields with their drain uses (LK:5688–5690), `runTicklessJobPass`, and the action site's else branch (LK:2328–2336);
- `runSyncRequests`' live branch (LK:687–694; it keeps a `.reevaluation` branch);
- the hold points `.legacyShutdownPass`, `.syncOnlyAfterLegacyCycle`, `.legacyDelivery` and `.ticklessJobPass`.

**The forwards become defaults:**
- `LandKeeperTransport`'s extension (LKT:302) gets do-nothing defaults for `syncNowFromTransport` and `syncBroadcastOnlyFromTransport`, documented as the replay surface until #612 S6.
- The adapter's forwards are deleted (`TransportAdapter+LandKeeperTransport.swift:15–23`), with `_syncBroadcastOnlyImpl` (TA:5089) and `SyncTurnReason.broadcastOnly`.
- `_syncNowImpl` (TA:3118) stays, because `syncNow()` uses it.
- `TransportAdapterRequestedSyncTurnTests.broadcastOnlyBridgeIsARequestedTurn` (:98) is retired with the bridge. Its leave claim is kept by the converted `TransportAdapterBroadcastOnlySyncTests`: OnLeave's sync runs in its turn.
- The census lists `_syncBroadcastOnlyImpl` and `.broadcastOnly` as gone.

**Docs:**
- `runtime.md` drops `beginSync`/`endSync`/`isSyncing` (:41–62, :94–104, :444–478);
- the comments at `LandError.swift:21` and TA:405 go;
- `Examples/GameDemo/docs/benchmarks/WORKER_POOL_ANALYSIS.md:230`.

All in en and zh-TW where the file has both. CLAUDE.md and AGENTS.md change separately (§3.8.10).

**Gate:**
- full `swift test`;
- the census, with every deleted symbol at its allowlist count;
- the GameDemo build;
- the harness;
- the revert check: the census fails on the revert.

#### 3.8.6 MF5: a live custom transport that doesn't opt in

After L2d-2 a live keeper whose transport doesn't opt in would silently receive nothing. The maintainer asked why a transport would not opt in at all (order `l2d-transport`).

**Who conforms outside the tests** (Sources and Examples):
- `TransportAdapter` (`Sources/SwiftStateTreeTransport/TransportAdapter+LandKeeperTransport.swift:8`): the only real one.
- `ReleasedLandTransport` (LKT:374), internal: the teardown placeholder, set by the keeper itself (LK:475 through `releasedTransport`).
- No replay transport exists: production replay keepers have none (`ReevaluationEngine.swift:263`, `ReevaluationRunnerImpl.swift:215`, :286 build `.reevaluation` keepers without `transport:`).
- Every attach outside the tests passes an adapter:
  - `LandManager.swift:708`;
  - the two SDK benchmark runners (`TransportAdapterSyncBenchmarkRunner.swift:254`, `TransportAdapterConcurrentStabilityBenchmarkRunner.swift:150`);
  - EncodingBenchmark (`BenchmarkExecution.swift:314`, :910, :1143; `EncodingBenchmarkMain.swift:145`, :477, :888, through the public `TransportAdapterBenchmarkHandle.keeperTransport`, `TransportAdapterBenchmarkHandle.swift:54`);
  - the Demo/GameDemo `SyncTablesFrameIdentityTests` (:64, :79).

**Why "it implements the method" isn't "it can run in turn".** The adapter answers `runsSyncPhaseInTurn(of:)` with `isAttached(to:)` (identity, TA:109), and it shares that keeper's executor through `unownedExecutor` (TA:104–106). Its `assumeIsolated` is valid only then. Any of these makes it a runtime condition, which no type can express:
- an adapter built for keeper A and attached to keeper B;
- a second keeper;
- a class transport on its own executor.

**Test fakes** (28 conformers in `Tests/`, 12 of which opt in):

| Option | What it is | Fakes touched | Public API | What it closes |
|---|---|---|---|---|
| **(c1)** remove the defaults of `runsSyncPhaseInTurn` (LKT:304) and `runSyncPhaseInTurn` (LKT:336) | every conformer must write both | 16 (the 28 minus the 12 that already do), plus `ReleasedLandTransport` | a source break for any outside conformer; none exist | nothing: a conformer can still return `false` / `.unsupported`, and the attach-to-another-keeper case stays runtime |
| **(c2)** make `LandKeeperTransport` package | only the package can conform | 0 (the tests are in the package) | `LandKeeper.setTransport` (LK:475) and `init(transport:)` (LK:973) become package, and `TransportAdapterBenchmarkHandle.keeperTransport` goes. A public attach replaces them (for example `TransportAdapterBenchmarkHandle.attach()`), and the 8 Examples call sites above change. The public types used by the protocol (`InTurnSyncResult`, `InTurnSyncOutput`, `JoinAdmission`, …) can stay public | outside conformers. The wrong-keeper attach stays runtime |
| **(r)** refuse at attach (Review + Main recommendation) | `setTransport` and `init(transport:)` on a live keeper: a non-nil transport with `runsSyncPhaseInTurn(of: self) == false` stops with `preconditionFailure("…a live keeper's transport must run its sync phase in turn (#546 L2d)")`, in release too. It applies only while `!destructionFinished`: after destruction, `setTransport` swaps in the released placeholder | the fakes attached to live keepers that don't opt in: 15 (16 minus the `.reevaluation` fake, which the mode exempts). They opt in, or move to `.reevaluation` where that is their subject | none in signatures; a behavior change (a trap instead of silence) | every live mis-attach, including the wrong keeper and the wrong executor |

**How the three special transports fare:**
- **`nil`:** allowed under every option. The keeper runs turns and records; its outputs are delivered nowhere (§3.8.4).
- **`ReleasedLandTransport`:** the keeper installs it itself, bypassing `setTransport`'s check. Under (r) it is exempt by construction; under (c1) it needs the two methods; under (c2) nothing changes.
- **Replay transports:** none in production. The test fake on `.reevaluation` keepers (`LandKeeperReevaluationOutputModeTests:41`) is exempt by mode under (r), untouched under (c2), and needs the two methods under (c1).

**Decided (the maintainer, 2026-11-21): (r) in L2d-2 and (c1) in L2d-3.** (r): `preconditionFailure` at `init(transport:)` and `setTransport` on a live keeper when `runsSyncPhaseInTurn(of: self)` is false, in release too, with a message that says why; `nil`, `ReleasedLandTransport` and `.reevaluation` keepers are exempt, and the check applies only while `!destructionFinished`. (c1): with the legacy deletions, L2d-3 removes the defaults of `runsSyncPhaseInTurn(of:)` and `runSyncPhaseInTurn(…)`, so a conformer without the in-turn path doesn't compile; the fakes are fixed from the compile errors. Both go under "Public API" and "Behavior" in their PR bodies.

**Recommendation (rev 8): (r) in L2d-2.** It is the only option that closes the case that can't be typed: the attach to a wrong keeper or executor. It costs no signature, and it fails fast at the attach rather than at the first silent turn.
- (c1) adds boilerplate and closes nothing.
- (c2) is sound hardening but closes the extension point. It is a separate maintainer decision, outside L2.

#### 3.8.7 Public API (L2d)

- **L2d-1:**
  - Public: none. The settle phase is the package protocol `LandKeeperSettlePort` (`runSettlePhaseInTurn`), which `TransportAdapter` conforms to.
  - Package: `InTurnSettle`, `LandKeeperSettlePort`, `SettleFence`, `SettleTurnOutcome`, `InTurnSettleCommit`, `InTurnSettleRefusal`, `InTurnSyncOutput.settle`, `SyncTurnReason.settle`.
  - Removed, package: `debugSettleTurn`, `DebugSettleTurnOutcome`.
  - Behavior: a settle whose plan throws ends the land in its own turn.
- **L2d-2:** no signature change. Behavior:
  - (r) a live keeper refuses, with a trap, a transport that doesn't run its phase in turn;
  - live keepers with no transport run turns, and their outputs are recorded, not delivered.
- **L2d-3:**
  - Removed: `LandKeeper.beginSync(clearDirtyFlags:)`, `endSync()`, `endSync(clearDirtyFlags:)`.
  - Added: do-nothing defaults for `syncNowFromTransport` and `syncBroadcastOnlyFromTransport`.
  - Internal or package: the four hold points (`LandKeeperHoldPoint` is internal, LK:55), `beginSyncLocated`, `syncOnlyTurnAfterLegacyCycleForTesting`, `SyncTurnReason.broadcastOnly`.
  - Unchanged: `isUsingInTurnSync()` and `LandKeeper`'s init.

#### 3.8.8 Test fates

| File | PR | Fate |
|---|---|---|
| `LandKeeperSyncLockTests` (9 tests) | L2d-3 | Delete 4 (:47, :142, :175, :202: snapshot, serialization, lock release, consistency; the lock is gone). Convert 5 (:339, :385, :403, :465, :524: the dirty-flag clearing claims) to sync-only turns through an opted-in fake |
| `TicklessActionJobTests` | L2d-3 | Delete the off arm (:271, :286, the `.ticklessJobPass` at :425); drop the `inTurn:` parameter |
| `ShutdownTurnTests.legacyCallerPassAppliesTheShutdown` (:413) | L2d-2 | Becomes a forced-shutdown turn held at `.inputDrain`; the `.legacy` builder arm goes |
| `TicklessReplayPassTests` :390 / :452 / :485 | L2d-2 | :390 becomes two inputs in one batch. :452 and :485 hold at `.inputDrain` and assert the turn's order. The `.reevaluation` half (:420) stays |
| `DrainTurnTests` | L2d-2 | `DestroyHoldTransport` (:281) opts in. `BroadcastHoldTransport` (:160; uses :333, :527) is replaced by a hold at `.inputDrain` |
| `ResolverDeliveryTests` | L2d-2 | `HoldingTransport`/`BroadcastHoldingTransport` (:229, :249; uses :420, :491) are replaced by resolver holds at the same position in the turn |
| `LandKeeperDebugFreezeTests` | L2d-2 | `DebugFreezeGatedKeeperTransport` (:134, :206–230) is replaced by a hold inside the tick turn |
| `PerSequenceResultTests` | L2d-2 | `BroadcastSpyTransport` (:200, :376) opts in; the claim becomes "OnLeave's sync runs in its turn" |
| `MockLandKeeperTransport`, `TransportAdapterBroadcastOnlySyncTests` (:20, :76) | L2d-2 | Opt in; assert the OnLeave sync turn |
| `TransportAdapterRequestedSyncTurnTests.broadcastOnlyBridgeIsARequestedTurn` (:98) | L2d-3 | Retired with the bridge |
| Non-opting live fakes: `ActionEventSyncTests`, `InitializeResolverFailureTests`, `LandDSLTests`, `ReplaySequenceWatermarkTests`, `ResolverDeadlineTests`, `SyncRegistrationTests`, and the second and third fakes in `DrainTurnTests`, `PerSequenceResultTests`, `ResolverDeliveryTests`, `TicklessReplayPassTests` | L2d-2 | (r) traps them at attach. Each opts in, or switches to `transport: nil` where it only observes state. The PR runs the suites first and lists each one (§10 risk 2; lesson `2026-11-09-a-tickless-keeper-without-a-transport-tests-only-the-legacy-path`) |
| `LandKeeperReevaluationOutputModeTests` (:41) | — | Keep (`.reevaluation`, exempt) |
| The `.legacyCycle` asserts (`SyncOutputVerifierTests` :951 and :1502; `SyncStreamProducerTests:470`; `TicklessPassOrdinalTests:261`) | L2d-1 | §3.8.3 |
| `RecordFieldListTests:29` | — | Keep: `.legacyCycle` stays for the standalone firstSync |
| Direct `beginSync`/`beginSyncLocated` (`TransportAdapterOrderedSendTests:575`, `TransportAdapterSyncDirtyWindowTests:250`, `SyncStreamProducerTests:519`) | L2d-3 | Convert to a hold inside a sync-only turn (`.inputDrain` or an adapter hold), or delete with the reason |
| `TransportAdapterSyncConcurrencyTests` | L2d-3 | Keep; fix the comment (:4) |

#### 3.8.9 A/B (Q6 decided)

- **L2d-1:** none.
- **L2d-3:** a Mac output check.
- **L2d-2:** a scoped host A/B. Unattached worker-pool keepers' ticks move from the legacy `runTick` to `runTickTurn`.
  - **Cells:** hero-defense, `messagepack-pathhash`, `--compare-worker-pool` (the static pool `runMultiRoomBenchmarkWithWorkerPool`, `BenchmarkExecution.swift:458`, and the dynamic pool `…WithDynamicWorkerPool`, :654, reported separately); `ticksPerSync` 1 and 2; 10×5 and 100×5. JSON only if cheap.
  - **Null control:** the serial (attached) arm. Its keepers already run turns, so it should not move.
  - **Pass bar:** zero skips and identical bytes on every cell, and `timeMs` within noise on every cell (or the cost stated and accepted by the maintainer). The serial null control must be within noise too.
  - **Setup:** the 7600X with the pinned image; base = L2d-1's head, against L2d-2.
- **Expected golden classification:**
  - `freeze-resume-messagepack`: cause 1 only.
  - The harness: no change in any PR.
  - `ReevaluationRunner/main.swift:452` (L2d-2): a turn record per tick. The bar is decoded equality and the verifier's 0 mismatches.

#### 3.8.10 CLAUDE.md and AGENTS.md (with L2d-3, on the maintainer's OK)

They are changed once, after L2d-3 merges, as a direct change to `main`. There is no interim edit.

**CLAUDE.md, current:**
> Not yet true for the join/leave resolvers, the freeze settle (#129) and the legacy (off in-turn sync) tick path; those paths still re-check by hand until they move.

The same section also says: "…the freeze accounting in `debugEndWork` and, tickless with in-turn sync, the turn waiter registration (`awaitInputTurn`)."

**CLAUDE.md, after L2d:**
> Not yet true for the join/leave resolvers and the freeze drain (#129: `debugFreeze` re-checks its generation and registers its waiter after each await); those paths still re-check by hand until they move. Re-evaluation keepers keep their non-turn replay path until #612.

The bookkeeping sentence becomes "…the freeze accounting in `debugEndWork` and, on a tickless land, the turn waiter registration (`awaitInputTurn`)."

**AGENTS.md:154, current:**
> Not yet true for the join and leave resolvers, the freeze settle (#129) and the legacy tick path (in-turn sync off); until they move, those paths re-check by hand in the segment after the `await`.

**AGENTS.md:154, after L2d:**
> Not yet true for the join and leave resolvers and the freeze drain (#129); until they move, those paths re-check by hand in the segment after the `await`. Re-evaluation keepers keep their non-turn replay path until #612.

AGENTS.md:156's "on a tickless land with in-turn sync" becomes "on a tickless land".

The freeze drain was checked: LK:1531–1559 loops on `debugInFlightWork > 0, debugActiveGeneration == generation`, and writes `debugDrainWaiters` and re-tests after each await. L2d doesn't touch it.

#### 3.8.11 Lessons consulted

- `2026-11-09-a-tickless-keeper-without-a-transport-tests-only-the-legacy-path`: the non-opting fakes (§3.8.8).
- `2026-11-09-an-ordering-check-must-fail-under-its-mutant`: the legacy pass's ordering assert (LK:4036) goes, so its claim is kept as in-turn tests.
- `2026-11-19-a-harness-with-its-loops-off-must-order-the-work-it-starts`: the pin test uses `autoStartLoops: false`.
- `2026-11-21-a-closure-that-captures-only-actor-state-runs-off-the-actor`: L2d-1 removes the settle's closures, and adds none.
- `2026-11-20-a-time-limit-does-not-end-a-wait-that-never-resumes`: the fence and writer-wait tests use `withinHangBound`.

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
- **The kept-event path without caller 2.** L2a drops §3.2's caller 2 (§10a, with #695). The event still reaches the resume through the settle's own kept-events check, now written into §3.4's step 4: it sets `deferredSyncNow`, and the resume's `syncTurnNow(.resume)` delivers the event once. So `eventKeptBySettleArrivesAfterResume` keeps its claim. §3.4's test list still says the event "takes §3.2's caller 2". #695 edits that line, so the L2b PR deletes the sentence, after #695 is merged, rather than this commit, to keep #695's head where it is.
- **The resume's join-sync request** (step 2) keeps `requestJoinSyncTurn()` as it is. It reads the attached `transport`, not the bound requester. On an attached keeper the two are the same (`setTransport` rebinds, and `acceptsSyncTurn` requires the port to be the transport). A keeper bound only by its first request has no `transport`, so step 2 does nothing there, before L2b and after it. When the keeper's turns run on `TurnCore` (#700), the binding's port replaces `transport`. That isn't an L2b change.
- **The broadcast-only bridge becomes a requested turn.** `syncBroadcastOnlyFromTransport()` (a public `LandKeeperTransport` requirement) reaches `_syncBroadcastOnlyImpl`, which has no `inTurnSyncEnabled` branch, unlike `_syncNowImpl` (TA:3150). So on an in-turn adapter it still runs a legacy cycle: `withSyncState`, then `beginSync`, then `isSyncing`. A requested turn inside that cycle latches (LK :5118).
  - **Who reaches it on an in-turn adapter:** the keeper's legacy paths, until L2d (LK :692, :3864, :3938, :4578). One example is a legacy pass queued before an attach, which reads the transport after its awaits. The backlog retry's broadcast branch (TA ~:3316) is a second route.
  - **L2b:** `_syncBroadcastOnlyImpl` on an in-turn adapter becomes `syncTurnNow(via: self, reason: .broadcastOnly)`, as `_syncNowImpl` does. `.broadcastOnly` is a new case of the package `SyncTurnReason`. A full sync-only phase covers broadcast-only changes, as the resume already assumes ("a full cycle also covers broadcast-only changes"). The off adapter keeps its broadcast-only cycle until L2c (§3.3).
  - **Goldens:** no in-turn harness cell is expected to reach the bridge. `classify-golden-changes.py` against #695's merge must report no change. A change would name a cell that reaches a legacy path on an in-turn adapter, and it gets listed in the PR.
  - **Test:** the bridge on an in-turn adapter runs one requested turn (`requestedSyncTurnsForTesting[.broadcastOnly]` + 1) and never makes `isSyncing` true. Mutant: the old body; the test fails.
- **The latch after L2b.**
  - Both of the latch's arm sites are in-turn keeper paths that meet `isSyncing`: a turn's sync with a legacy cycle in flight (LK :4694), and `runSyncOnlyTurn` (LK :5118).
  - With the settle and the bridge on turns, `beginSync`'s adapter callers after L2b are the off adapter's: `withSyncState` (`_syncNowImpl`'s and `_syncBroadcastOnlyImpl`'s cycle branches, and the backlog retry, deleted in L2c) and the off settle. An off adapter's keeper runs no in-turn turns, so none of them can latch.
  - So `syncDuringSettleCycleIsLatched` (`TransportAdapterInTurnSyncTests` :888) is retired in L2b, with no off-adapter arm.
  - The latch stays reachable only through a direct `keeper.beginSync` call on an in-turn keeper, until L2d deletes both. `beginSync` is public, and it isn't marked deprecated: only its `endSync(clearDirtyFlags:)` overload is. No test pins that window, since it lives only until L2d.
- **Carried from L2a's review:** after its bounded wait, `freezeIsCheckedBeforeBackPressure` (`TransportAdapterRequestedSyncTurnTests` :209) awaits `waitForOutboundIdleForTesting()`. That wait has no cancel path, so `withinHangBound` around it would still hang. The test checks no frame after the resume, so L2b's first commit drops the wait.

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
- the harness, with §5.1's check script over the in-turn goldens as a guard: no change is expected, except for the settle's record (§3.6, Q4), which is the only change classified.

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

**L2a: a host A/B.** It measures EncodingBenchmark's driver path: its measured loop calls `syncNow()` (30 calls), which moves from the adapter's cycle to a keeper job. The claim is scoped to that driver. L2a also moves the lag timer's scheduling, which the benchmark doesn't measure. Production's periodic sync already runs `runSyncOnlyTurn`, so this sets that tool's new baseline. Base against L2a, both built from the pinned image, on the measurement host. The cell list is fixed with Main before the run, as B0's was (#655 §5.1), with MessagePack and JSON included. `MeasuredSync`'s skip check stays meaningful: the in-turn path counts a deferred phase in `syncSkips.outboundBacklog`. Attached and unattached keepers both appear among the measured cells: the worker pools' keepers are unattached (`BenchmarkExecution.swift:491`, :603, :687, :791), and the serial and multi-room builders attach (:314, :910, :1143). In both, `syncNow()` takes the same path, `syncTurnNow(via:)`.

**L2b–L2d: a Mac output check.**
- **L2b:** the freeze frames and records (`freeze-resume-messagepack` byte-identical).
- **L2c:** the harness, with the in-turn goldens unchanged (byte-identical in the pinned-image job).
- **L2d:**
  - the recording comparison (§3.5);
  - a `HashCostBenchmark` smoke run;
  - the GameDemo build;
  - the settle's record change (Q4): `freeze-resume-messagepack` changes from `.legacyCycle` to a sync-only turn, with the same frames.

  Some measured windows include ticks, which move onto turns in L2d: the worker-pool cells with `ticksPerSync > 0` (`BenchmarkExecution.swift:585–610`, :785–807), and the serial runs' `timeMs` (:193–198, :1008–1024). L2d gets a scoped A/B on those cells.

## 7. Public API

The adapter is `package` since E, so `syncNow()`, `syncBroadcastOnly()` and the `inTurnSync` parameter are already outside the public surface. Decided (Q1 (a)): the public breaks go with no deprecation. The full list:
- **L2a:** `TransportAdapterBenchmarkHandle.syncNow()` keeps its signature; on the in-turn adapter it gives, its behavior changes (§3.1). `InTurnSyncOutput` gains a package field (`keepsEvents`) and a package init parameter; its public init and `InTurnSyncResult` don't change.
- **L2b:** none. The settle's entry point is the keeper's package `debugSettleTurn` (§3.4).
- **L2c:**
  - `SyncSkipCounts.busy` (a public field and init parameter, `TransportAdapter+Outbound.swift:237–247`) is removed. Both `MeasuredSync.swift`s stop reading it.
  - The profiler's `syncSkipsBusy` JSONL field (`TransportProfilingActor.swift:595`) stays, always `0`, so the profile format doesn't change: `ws-loadtest/src/server-sync.ts:14` requires it, and old and new profiles parse alike. `METRICS.md:136` says it is always 0 since L2. Dropping it would be a format change for its own PR, with ws-loadtest and its test (`tests/server-sync.test.ts:14`) changed together.
  - `TransportAdapterBenchmarkHandle.inTurnSyncEnabled` (`TransportAdapterBenchmarkHandle.swift:59`) is removed. EncodingBenchmark writes `true` in its place in the record metadata (`EncodingBenchmarkMain.swift:158–159`), so records keep their shape.
  - `LandKeeperTransport.syncNowFromTransport()` and `syncBroadcastOnlyFromTransport()` stay as requirements, and the adapter keeps its forwards (§3.5, §3.6). L2d deletes the forwards and adds the documented do-nothing defaults; #612 S6 removes the requirements.
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

**Q4. The in-turn freeze settle's shape.** *Decided (2026-11-20, after #712's review): a requested sync-only turn, in L2d.*
- Chosen: a sync-only turn with its own fence (`SyncTurnReason.settle`) through `runSyncPhaseInTurn`, exempt from the frozen skip. It takes the one sync entry point every other phase uses, and drops `DebugSettleTurnOutcome`, the two isolated callbacks and L2b's lint raise. Its cost is one record and golden change: the settle is recorded as a sync-only turn instead of `.legacyCycle`.
- L2b (#712) keeps the keeper job (§3.4) as reviewed. L2d converts it (§3.6).

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

## 10a. L2a delta

- **§3.2's caller 2 is dropped** (agreed in L2a's review). An event queued outside a turn on a land without periodic sync doesn't request a sync-only turn: it waits for the next sync, and requesting one would be new behavior. One window narrows. Before L2a, on the in-turn adapter, an event queued while `syncNow()`'s legacy cycle was in flight was delivered by the follow-up after `endSync` (the retired test 7e). The requested turn is synchronous, so that window is gone, not just unreachable: such an event now waits for the next sync, like any event queued outside a turn. This is the intended direction. Four tests pin today's semantics: `TransportAdapterMembershipTests` (:130, :214), `SyncStreamProducerTests:479` and `TransportAdapterOrderedSendTests` test 5. The reason `.outOfTurnEvent` goes with it, and the callers are renumbered 1–4. Auto-delivery, if wanted, is a separate behavior change.
- **L2b** restates the path of `eventKeptBySettleArrivesAfterResume`'s event (§3.4), which relied on caller 2.

## 10b. Rev 8: what changed

| Finding | Fix |
|---|---|
| MF1: an adapter `settling` flag spans the await | The settle context rides only in `runSettlePhaseInTurn`, within the turn. A `GenerationTable` ticket is captured before the drain and checked with `ifCurrent` at publish. The hold-point test checks that an ordinary phase still defers (§3.8.3) |
| MF2: re-reading state after the await; the tick read after the call | A typed `SettleTurnOutcome` returns the copy, tick and epoch from one segment. Every error is distinguished. An empty land is `.settled(planned: false)` |
| MF3: inheriting `runSyncOnlyTurn`'s bookkeeping | `settleTurn` is its own function. The fence comes first, in a fixed order. Each piece of bookkeeping is named as done or not done: the `isSyncing` interim, the pending request, the cadence and join resets, the follow-ups, the binding. The dirty-flag clear and the terminal failure are kept |
| MF4: the failure's compatibility | The new record shapes are given for tick and tickless lands. Four replay pins cover the old successful `.legacyCycle` record, the old queued failure, and the new tick and tickless failures. The negative assertion stays scoped to the settle's stream index |
| MF5: a live transport that doesn't opt in | The conformer census; (c1), (c2) and (r) compared; (r) recommended, for the maintainer (§3.8.6) |
| should: the bridge test and the census | `broadcastOnlyBridgeIsARequestedTurn` is retired in L2d-3. `_syncBroadcastOnlyImpl` and `.broadcastOnly` are in the census. `_syncNowImpl` stays |
| should: the writer poll | `waitForSyncCycleDrain`, cancellable and bounded by the deadline, with the backlog and fences re-checked at admission |
| should: Q4 | `precondition`/`preconditionFailure`, not `assert` |
| should: the predicates and the census | A predicate per read; the no-port drain at LK:5799; the census's counting rule and allowlist |
| should: revert checks and docs | A revert check and docs for each PR. CLAUDE.md and AGENTS.md take the end state after L2d-3, on the maintainer's OK |
| Q6 | The cells as given (§3.8.9) |
| rev 8 review, should 1: no public API | `LandKeeperSettlePort`, a package refinement of `LandKeeperTransport`; `InTurnSettle` is package; the keeper casts the port and refuses `.notCurrent` otherwise. The lint allowance still goes 5→3 |
| rev 8 review, should 2: `.closed` read as `released` | `.closed` and `.refused(.outputClosed)` surface the cause (the failure, or a closed error) |
| rev 8 review, should 3: the A/B's performance bar | `timeMs` within noise per cell, or the cost accepted; the serial null control within noise |
| rev 8 review, nits | the interim `isSyncing` gets its own refusal, `.syncInFlight`, retried like `.writerBusy`; (r) applies only while `!destructionFinished` |
| Also | The pointers restated at a72b007c. The golden tool corrected (`regenerate-sync-output-goldens.sh` for the settle; `classify-golden-changes.py` as the harness guard). Q1 (`SettleFence`), Q2 (same-turn failure), Q3 (three PRs), Q4 and Q5 (one CLAUDE/AGENTS edit) are folded in as decided |

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
