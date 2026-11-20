# Remove the adapter's off mode on live lands (#546 L2)

**Status:** rev 1, plan only, for review. No code until this plan is GO and L1 (#677) has merged.

**Issue:** #546, step L2 of `2026-11-19-adapter-turn-core-rewrite.md` (rev 13). That plan holds L2's placeholder (§3.2, groups 2a–2e) and the "Inputs to L2's own plan" block. This plan lays L2 out; §9 maps each input to the section that settles it.

**Base:** `main` at bf8a2ac2 with L1 (#677) applied. L1 removes the `IN_TURN_SYNC` switch and the public `inTurnSync` parameters; it moves no line this plan points at by more than a few lines. Pointers are at bf8a2ac2:
- "TA" is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`;
- "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`;
- "LKT" is `Sources/SwiftStateTree/Runtime/LandKeeperTransport.swift`;
- "DS" is `Tests/SwiftStateTreeNIOTests/Differential/DiffScenarios.swift`.

**Related:** #612 (`2026-11-20-replay-on-turn-core.md`, rev 3). It owns the keeper's off path for `.reevaluation` keepers (S2, S6). It lists L2's groups 2d and 2e as a dependency of S6. §3.4 here draws the line between the two plans.

## 1. Goal and end state

**Goal.** Every sync on a live land runs in one of the keeper's turns. The adapter no longer runs a sync cycle of its own.

**End state after L2:**
- The adapter has one sync path: `runSyncPhaseInTurn`, called by the keeper inside a turn. `withSyncState`, `_syncNowImpl`, `_syncBroadcastOnlyImpl`, the adapter's executor host and the `inTurnSync` init parameter are gone.
- The keeper has no `beginSync`/`endSync`, no `isSyncing` flag and no latch that reruns a sync-only turn after a legacy cycle.
- Every live keeper runs its inputs through turns, with or without a transport.
- The harness has no legacy cells. Its in-turn goldens record what the in-turn path does for every sync the scenario asks for.

**Unchanged by L2:**
- The standalone initial sync (`_syncStateForNewPlayer`, TA:5586). It doesn't use `beginSync`/`endSync`. It stays as it is until B2 (`.initialSyncCommit`) and B3 (membership). Its recorder tag `.legacyCycle` stays (`ReevaluationSyncStream.swift:19`), so recorded data keeps its meaning.
- The keeper's off path for `.reevaluation` keepers (`processPendingActions`, `replayRecordedPasses`, `deliverLegacyPass`, the legacy `runSync` loop). Those keepers have no transport. #612 S2 moves them onto `runTurn`, and S6 deletes that code (§3.4).
- Frames on the default production path. A server built from `main` already runs in-turn; L2 removes code it doesn't reach.

## 2. Who reaches the off mode after L1

After L1, nothing in production selects the adapter's off mode. It is still reached in five ways.

| Caller | Sites (at bf8a2ac2, plus L1) | Group |
|---|---|---|
| The adapter's own syncs on an in-turn land: the follow-up (TA:3161), the backlog retry (TA:3197–3216), the lag timer's sync (TA:3603, :3620), the behind-commit follow-up (TA:3185, called at :5655) | 4 functions | 2a |
| `syncNow()` and `syncBroadcastOnly()` (`TransportAdapter+Sync.swift:4–10`), which run the adapter's cycle even on an in-turn land | 137 `syncNow` and 17 `syncBroadcastOnly` test calls (127 + 17 in `SwiftStateTreeTransportTests`, 7 in `SwiftStateTreeTests`, 3 in `SwiftStateTreeNIOTests`); EncodingBenchmark (17 + 12 + 1 calls); `SwiftStateTreeBenchmarks` (7); the two Examples `SyncTablesFrameIdentityTests`; `TransportAdapterBenchmarkHandle.syncNow` | 2b |
| The freeze: the settle's `beginSync` loop (TA:6546–6610) and the resume's replay (TA:6639–6643) | 2 functions | 2c |
| Keepers whose transport isn't the attached adapter: 18 fake `LandKeeperTransport`s in `SwiftStateTreeTests` and `MockLandKeeperTransport` in `SwiftStateTreeTransportTests`. Nine of the 19 already answer `runsSyncPhaseInTurn` with `true`. The other ten don't: `LandKeeperDebugFreezeTests`, `ReplaySequenceWatermarkTests`, `SyncRegistrationTests`, `ActionEventSyncTests`, `LandDSLTests`, `ResolverDeadlineTests`, `LandKeeperReevaluationOutputModeTests`, `InitializeResolverFailureTests`, `MockLandKeeperTransport`, plus each fake's second conformer where a file has two | 19 files | 2d |
| Live keepers with no transport: about 19 `SwiftStateTreeTests` files, `HashCostBenchmark.swift:50`, `ReevaluationRunner/main.swift:452` (a live keeper that records a game) | about 21 sites | 2e |

The explicit off callers also pass `inTurnSync: false`:
- the harness's legacy cells (`DiffRunner`, set after the configuration's init since L1);
- the pinned `LandRouterJoinAttemptTests` (L1);
- `AtomicPatternIndexAdapterTests` (1), `InitialSyncBehindCommitTests` (1), `LandReleaseTests` (1), `RowAddressingAdapterTests` (3), `TransportAdapterPendingEventsAcrossCyclesTests` (2), `TransportAdapterSyncLagTests` (4);
- the fixture-mediated ones: `SyncStreamProducerTests.swift:286`, `TransportAdapterInTurnSyncTests.swift:928` and :987, `SyncStreamInitializeRecordTests.swift:144`, `TicklessPassOrdinalTests.swift:551`, and the live arms of `TransportAdapterNewestWinsTests.swift:348` and :392.

## 3. Decisions

Each decision has a recommendation. §8 lists the ones that need the maintainer.

### 3.1 What `syncNow()` becomes (2a, 2b)

*Recommended: `syncNow()` runs one sync-only turn on the keeper now, and returns after it.*
- The keeper gets one package entry point, for example `syncTurnNow()`. It runs `runSyncOnlyTurn` (LK:5039) in a single keeper job and returns. The adapter shares the keeper's executor when it runs in-turn (TA:111, :973), so the call has no other turn between the request and the turn.
- No fold. The sync loop folds a sync into a tick that is due within the coincident-sync window (LK:5539–5557). An explicit `syncNow()` is a test's or a benchmark's request for a sync at that point, so it runs at once. The sync loop keeps its fold.
- Writer back-pressure is the keeper's. A deferred phase on a land without periodic sync gets one retry after the writer drains (`retrySyncOnlyTurnAfterWriterDrain`, LK:5068), as a skipped legacy cycle did (TA:3197). The adapter's backlog retry and its counters (`backlogRetryRuns`, `backlogDeferredSyncNow`, `backlogDeferredBroadcastOnly`, `backlogRetryScheduled`) go.
- There is no busy outcome. A sync-only turn is synchronous, so a second request can't meet one in flight. `syncSkips.busy` and its profiler counter go.

What changes for a caller:
- **A ready join flips.** The in-turn phase completes the ready joins (TA:2905–2911). The legacy cycle passed no joiners (TA:3150). So a `syncNow()` while a join waits for its sync now sends that join's JoinResponse and firstSync in this phase.
- **A tickless land records a turn.** A tickless land's sync-only turn is its own turn record (LK:5054–5056, #327). The legacy cycle wasn't one.
- **The record's turn kind.** Recorded sync outputs carry `turnKind: syncOnly` where they carried `legacyCycle`.

§5 accounts for these changes in the harness goldens.

**The adapter's own syncs (2a)** become requests for the same turn:
- the follow-up after kept events (TA:3153, :5269): no counterpart. It exists because events queued during the `endSync` hop had no cycle to carry them (TA:3279–3286). A turn has no such hop: an event emitted in a turn goes out in that turn's phase. The L2a PR shows this with a test that queues an event outside a turn on a tickless land and checks it is delivered;
- the lag timer's sync (TA:3620): a request for a sync-only turn;
- the behind-commit follow-up (TA:5655): a sync-only turn after `syncFailedPlanFollowUpDelay`, through the keeper's delayed request (`scheduleJoinSyncTurn(after:)`, LK:5089, generalized to any sync-only turn). Its hold point `.failedPlanFollowUp` stays, on the keeper's side of the request. The standalone commit it follows stays in the adapter (§1).

`waitForBackgroundSyncsForTesting` (TA:3179) loses its sources. The harness's step (`DiffRunner.sync()`, `DiffRunner.swift:573–576`) then awaits the keeper's pending retry instead. The keeper gets the matching test wait.

Rejected: keeping `syncNow()` as an adapter cycle that runs inside a keeper job. It would keep a second sync entry, which B2 would then have to model.

### 3.2 `syncBroadcastOnly()` (2b)

*Recommended: delete it. Its callers use `syncNow()`.*
- On an in-turn land a broadcast-only request already runs the full phase (LK:637–640). Production never reaches the broadcast-only plan: its only caller is `_syncBroadcastOnlyImpl` (TA:5232).
- The legacy broadcast-only cycle kept the dirty flags. It upgraded to a full plan when row addressing, a key-scope reset, carried dirty fields or a resync was due (TA:5248–5256). With the full phase, those cases are the default. The cost is per-player diffs where only broadcast fields changed, which the in-turn path already pays.
- `planBroadcastOnlySyncPhase` (TA:5279) goes with it.
- The keeper's `requestSyncBroadcastOnly` (LK:422) stays as handler API. It keeps meaning "a sync in this turn".

The 17 test calls are in nine files. Each is either converted to `syncNow()` or deleted. A test that asserts the broadcast-only plan itself (kept dirty flags, no per-player patch) is deleted with the plan. The L2a PR lists each one with its fate.

Rejected: a broadcast-only variant of the sync-only turn. Nothing in production would use it.

### 3.3 The freeze settle (2c)

#655 decision 2 keeps the whole freeze on the adapter through B2, the settle included. L2 keeps that and replaces only the settle's keeper-lock protocol.

*Recommended: the settle's commit runs as one keeper job on the frozen keeper.*
1. Drain, as today: `keeper.debugFreeze(generation:timeout:)` (LK:1459).
2. Wait for the writer: `waitForSyncCycleDrain()`, the wait the backlog retry uses (TA:3213), within the same deadline. The 2 ms poll (TA:6556–6561) goes.
3. Run the commit: a keeper entry point, for example `settleTurn(generation:)`, calls the transport synchronously with a settle flag. The phase skips the freeze deferral (`debugDeferSyncIfFrozen`, TA:2903) for this call only. It returns the state copy, the committed tick and whether the commit happened.
4. Check the generation after the call and publish, as today (TA:6592–6604).

It keeps today's details:
- the membership epoch is read before the copy;
- an empty land takes the copy without clearing dirty flags;
- the follow-up flag for kept events on a land without periodic sync. Its resume replay becomes a sync-only turn request (§3.1).

A frozen keeper runs no other turn, and no legacy cycle exists. So the busy retry loop goes, and the settle needs no lock. A plan failure ends the land as today: the output gate closes in the same segment, and the keeper applies the failure.

**The resume** (TA:6614–6650): the deferred `syncNow`/`syncBroadcastOnly` become one sync-only turn request. The join-sync turn request after it stays (TA:6646–6648).

#655's decision 2 text and §3.4's coalescing "after `endSync`" are then rewritten against this shape in B2's rewrite. Both are marked pending L2 there today.

### 3.4 Keepers without the adapter (2d, 2e), and the line with #612

`usesInTurnSync` (LK:672) answers two questions at once: whether inputs run through turns, and whether the sync phase runs in them. A live keeper with no transport, or with a fake that doesn't opt in, gets "no" to both and runs the off path.

*Recommended: L2 splits the predicate, with #612's names (§3.3 there).*
- **`routesThroughTurn`**: inputs go through turns. After L2 it is `mode == .live`. #612 S2 extends it to its `.record` keepers.
- **`syncsInTurn`**: a transport is attached and opts in (`runsSyncPhaseInTurn(of:)`). It has no mode term.

L2's PR lists each of the 22 sites (#612 §3.3 has the list: LK:637, :859, :1193, :1651, :1889, :1903–1924, :2202, :2585, :2657, :2909, :3046, :3153, :4250, :4300, :4881, :5062, :5442, :5539) with the predicate it takes. A live keeper with no transport then runs its turns with no sync phase. The events of such a turn have no transport to go to, as today.

**The fakes (2d)** opt in. Each of the ten that don't (§2) gets `runsSyncPhaseInTurn` → `true` and a `runSyncPhaseInTurn` that records what the test needs (`.notRequested` when it records nothing). `MockLandKeeperTransport` gets the same.

**Recording.** The state hash's gate (LK:4881) keeps its `usesInTurnSync` term as `syncsInTurn`. `ReevaluationRunner/main.swift:452` records with no transport, so its records keep their present shape. Its turns move onto the turn path. The L2c PR compares one recording before and after, byte for byte.

**The line with #612.**
- L2 moves every live keeper onto the turn path. That is #612 S6's dependency.
- L2 deletes what only the adapter's cycle used: `beginSync`/`endSync` and their located and deprecated overloads (LK:1336–1395), `isSyncing` (LK:663), and the latch `syncOnlyTurnAfterLegacyCycle` (LK:704) with its reads in `runTurnOutputs` (LK:4629) and `runSyncOnlyTurn` (LK:5043). No `.reevaluation` keeper calls them, since none has an adapter (S0).
- L2 deletes `syncNowFromTransport` and `syncBroadcastOnlyFromTransport` from `LandKeeperTransport` (LKT:57, :69) and their calls (LK:643, :645, :3802, :3876, :4516, :5564). After 2d and 2e, only `.reevaluation` keepers reach those lines, and they have no transport, so each call is a no-op today.
- The rest of the keeper's off path stays for `.reevaluation` keepers until S6.

#612's §4 row "The keeper's off path" then lists less. The L2c PR comments on #612 with the narrowed list.

Rejected: a null transport that opts in. It would run a sync phase that sends nothing, clear dirty flags each turn and change the behavior of the 2e tests. That isn't a removal.

### 3.5 What is deleted, and when

The off executor goes last, when no caller is left:
- the adapter's `inTurnSync` init parameter and `inTurnSyncEnabled` (TA:973), `ownExecutorHost` and `AdapterExecutorHost` (TA:105–111);
- the package `inTurnSync` on `LandManager`'s init and `NIOLandServerConfiguration`, added by L1;
- `withSyncState` (TA:3296), `beginSyncLocatedIfRecording` (TA:3915), `legacyCycleRead` (TA:3901), `beginSyncRequests` (TA:747), `startBackgroundSync` and `backgroundSyncTasks` once their last user goes;
- the hold points only the legacy cycle reaches: `.cycleBeforeEndSync`, `.busyRetry`, `.followUpSynced`, `.syncLagTimerSync` (if the timer's request has no other hold), and the keeper's `.syncOnlyAfterLegacyCycle`. The keeper's `.legacyDelivery` stays for `.reevaluation` keepers until S6;
- the off arms of every explicit `inTurnSync: false` caller (§2);
- `LandKeeperSyncLockTests` (LK's `beginSync`/`endSync` test) and the legacy-cycle cases of `SyncStreamProducerTests`, `TransportAdapterDebugFreezeTests`, `TransportAdapterSyncDirtyWindowTests` and `TransportAdapterOrderedSendTests`.

Each off arm is deleted, or converted when the in-turn path has the same claim to check. The PR lists each test with its fate. No new off arm is added.

## 4. Steps

Four PRs, in this order. Each one leaves `main` green with the harness byte-identical except where §5 says.

**L2a: the syncs become turns (2a, 2b).**
- `syncTurnNow()` on the keeper; `syncNow()` calls it on a live land; `syncBroadcastOnly()` deleted, and its callers converted (§3.2).
- The follow-up, the backlog retry, the lag timer's sync and the behind-commit follow-up move to the keeper (§3.1).
- `TransportAdapterBenchmarkHandle.syncNow` forwards to the new `syncNow()`. The handle's `syncStateForNewPlayer` and its join with `completedInTurn == false` (used by `Rejoin.swift`) stay: they are the standalone initial sync's, outside L2.
- The harness's in-turn goldens are regenerated (§5). The legacy cells still run until L2d. Their goldens don't change, because `syncNow()` on an off-mode adapter still runs the cycle until L2d removes it.
- Gate: §6. Host A/B: yes (§6).

**L2b: the freeze settle (2c).** §3.3. Gate: `TransportAdapterDebugFreezeTests` and `LandKeeperDebugFreezeTests`, the harness. Host A/B: none; the settle is debug tooling.

**L2c: every live keeper on the turn path (2d, 2e).** The predicate split, the fakes, the keepers with no transport, the transport requirements deleted (§3.4). Gate: the full `swift test`; the recording comparison for `ReevaluationRunner`. Host A/B: none. The production adapter already answers `true` to both predicates, so its path doesn't change.

**L2d: the off executor deleted (§3.5).** The harness's legacy cells, the four rows (§5.2), the 90 legacy goldens and the legacy cells embedded in `DiffSelfCheckTests.swift` go. Gate: the full `swift test`; the harness shows 84 cells compared with every listed cell run. Host A/B: none; it removes code the default path doesn't reach. The Mac output check shows the in-turn goldens unchanged by this PR.

L2a and L2b are independent and can be reviewed side by side. L2c is independent of both. L2d needs all three.

## 5. The harness

### 5.1 The in-turn goldens change in L2a

Every harness sync is `DiffRunner.sync()` → `adapter.syncNow()`. At bf8a2ac2 the 84 in-turn goldens hold 308 records with `turnKind: legacyCycle`, 87 with `syncOnly` and 126 with `tick`. After L2a each `syncNow()` is a sync-only turn. The changes come in three kinds:
1. **The turn kind:** `legacyCycle` → `syncOnly` in the sync-stream records of those syncs.
2. **Tickless positions:** a tickless land's sync-only turn is a turn record (#327), so the turn positions after it move by one per sync.
3. **Joins that flip earlier:** a `syncNow()` while a join waits now completes it (§3.1). The joiner's JoinResponse and firstSync move into that phase's frames.

The L2a PR carries a check script, run over the old and new goldens. It reports each cell's changes in these three kinds, and every other change on its own. The PR body has the table. A change outside the three kinds needs its own explanation, or it is a bug.

Frames that aren't a moved join's are byte-identical. Both paths plan with `runFullSyncPhase` from the same state.

#676 (a flake in `disconnect-during-keeper-join`'s tickless in-turn cell, on the turn kind) is in this area. L2a regenerates the goldens only after #676's fix has merged, so the regeneration doesn't record a flaky order.

### 5.2 The retired rows

Four rows exist only for the legacy cycle (DS:182, :184, :334, :372). Each is retired with a replacement invariant and a mutant that the replacement catches.

| Row | What it checks | Replacement |
|---|---|---|
| `disconnect-sending-join-response` (`.legacyOnly`) | a disconnect while the router's non-flip branch sends the JoinResponse | The in-turn flip carries the JoinResponse in the phase, and `disconnect-after-admit` and `disconnect-during-keeper-join` cover a disconnect around it. The non-flip branch stays until B3, and only direct joins without a response builder reach it. Its case moves to a `LandRouter` unit test that takes that branch. Mutant: the removed session's JoinResponse is sent anyway |
| `disconnect-sending-initial-sync` (`.legacyOnly`) | a disconnect while that branch sends the standalone firstSync | Same unit test, at the firstSync. Mutant: the firstSync is sent to the removed session |
| `join-during-sync-cycle` (`.legacyOnly`) | a join that arrives while a cycle is in flight is synced exactly once, through the busy retry | A new row, `join-during-writer-backlog`, on the in-turn cells: a join becomes ready while the writer holds a phase's frames. The deferred phase's retry flips it once. Mutant: drop the retry after the writer drains (LK:5068) |
| `join-during-sync-cycle-inturn` (`.inTurnOnly`) | the latch that reruns a sync-only turn after a legacy cycle | The latch is deleted (§3.4), so its claim has nothing to check. `join-during-writer-backlog` covers the join's side |

The two unit tests and the new row land in L2a, before the rows go in L2d. So each invariant is checked at every SHA.

### 5.3 The legacy cells

L2d deletes the `.legacy` sync axis from the cell list, its 90 goldens and the expected differences that name it. The gate's count changes from 174 listed to 84 listed. `ran > 0 && ran + replaced == listed` holds as before.

The harness files are protected paths. L2d's PR follows the protected-path rule the way #675 did, and says so in its body.

## 6. Gates and the A/B

Every step runs, on the Mac with the slot held:
- `swift build --build-tests`;
- the touched suites;
- the harness (`DifferentialHarnessTests`), with its "compared / replaced / listed" line quoted;
- the step's mutants.

CI runs the full `swift test` and the E2E.

**Host A/B for L2a.** EncodingBenchmark's measured loop calls `syncNow()` (17 + 12 + 1 calls), so its path moves from the adapter's cycle to a keeper job. The A/B runs on the measurement host, base against L2a, both built from the pinned image. The cells are the EncodingBenchmark cells whose loop calls `syncNow()`. The cell list is fixed with Main before the run, as B0's was (#655 §5.1). The zero-disconnect bar applies where the cell measures connections.

L2b, L2c and L2d get no host A/B: the default production path doesn't change in them. L2c's and L2d's Mac output check is the harness, byte-identical.

## 7. Public API

The adapter is `package` since E. So `syncNow()`, `syncBroadcastOnly()` and the `inTurnSync` parameter are already outside the public surface. Each PR lists its public changes:
- **L2a:** `TransportAdapterBenchmarkHandle.syncNow()` keeps its signature. Its behavior changes (§3.1), and the PR body states it.
- **L2c:** `LandKeeperTransport` loses `syncNowFromTransport()` and `syncBroadcastOnlyFromTransport()`. That's a removal from a public protocol. There are no external users, so it breaks no one (2026-11-18). It is listed for the maintainer (§8).
- **L2d:** `LandKeeper.beginSync(clearDirtyFlags:)`, `endSync()` and `endSync(clearDirtyFlags:)` are public and removed. Listed for the maintainer (§8).

## 8. Questions for the maintainer

**Q1. The public removals (§7).** L2c removes `syncNowFromTransport()` and `syncBroadcastOnlyFromTransport()` from the public `LandKeeperTransport`. L2d removes the public `LandKeeper.beginSync(clearDirtyFlags:)`, `endSync()` and `endSync(clearDirtyFlags:)`.
- (a) Remove them in L2, with no deprecation. Nothing calls them after L2, and there are no external users (2026-11-18).
- (b) Deprecate them in L2 and remove them later. They would stay as no-ops or traps, with a test each, until the removal.
- **Recommended: (a).** (b) keeps API that nothing can call correctly, and B2 would have to step around it.

**Q2. `syncBroadcastOnly()` (§3.2).**
- (a) Delete it. Its callers use `syncNow()`, which runs the full phase, as an in-turn broadcast-only request already does (LK:637–640). The broadcast-only plan goes with it.
- (b) Keep it as a broadcast-only sync-only turn: a phase that diffs broadcast fields only and keeps the dirty flags.
- **Recommended: (a).** No production path reaches the broadcast-only plan today. (b) would add a phase variant only tests use, and B2 would have to model it.

**Q3. Where the predicate split lands (§3.4).**
- (a) In L2c, with #612's names (`routesThroughTurn`, `syncsInTurn`). #612 S2 then takes the split as given and adds its `.record` keepers to `routesThroughTurn`.
- (b) In #612 S2, with L2c after S2. L2 would wait on S2, which waits on S1, #521's remaining PRs and #606.
- **Recommended: (a).** L2 comes before B1, and (b) would hold B1 behind the replay work. The names and the site list are #612's, so S2 changes no predicate twice.

Main settles the rest: the A/B cells (§6), and the order of L2a–L2c among the other open work.

## 9. The inputs from #655, and where each is settled

| Input (#655 rev 13, §3.2) | Here |
|---|---|
| The in-turn goldens change in 2b: account for each cell's record and frame changes | §5.1 |
| Each retired row needs a replacement invariant and a mutant; the remaining legacy cells, `DiffSelfCheckTests`' embedded cells and the protected-path route need a disposition | §5.2, §5.3 |
| The keeper side: `syncNowFromTransport`, `syncBroadcastOnlyFromTransport`, `beginSync`/`endSync` and their overloads, the latch | §3.4, §3.5 |
| Broadcast-only semantics: it keeps the dirty flags and can upgrade to a full plan | §3.2 |
| The freeze settle: it commits while the ordinary phase defers; decision 2's keeper-lock protocol and the coalescing "after `endSync`" | §3.3 |
| The fixture-mediated off callers | §2, §3.5 |
| The tickless behind-commit follow-up; its `.legacyCycle` recorder tag | §3.1, §1 |

## 10. Risks

- **A join flips in a different phase in L2a.** A test that counts frames after `syncNow()` while a join waits will see the join's frames sooner. §5.1's script finds them in the harness. Elsewhere the full `swift test` does, and the PR lists each converted assertion.
- **The 2e keepers' tests assume the off path's order.** For example, a test that awaits an action's result before its handler's effects are visible. The turn path resumes a waiter after the turn record is submitted (LK:5381–5393). L2c's PR runs these suites with the change before converting anything, and lists the failures.
- **The settle's deadline.** Waiting on the writer's drain instead of polling could wait past the deadline if the writer never drains. The wait gets the same deadline as a timeout, and a test holds the writer to show it.
