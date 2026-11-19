# TransportAdapter on the turn core: the rewrite (#546)

**Status:** rev 2, plan only, for review. Rev 1 (686c3fc8) was NOT GO with 4 must-fix; rev 2 folds in all of them, the 6 shoulds and the nit (§12 lists where each went). **Issue:** #546. **Inputs:** the turn core (#551, merged as #608; `Notes/plans/2026-11-18-swift-state-turns-core.md`), the differential harness (#555; `Notes/plans/2026-11-19-adapter-differential-harness.md`, rev 10), the stateless extraction (#554; `Notes/plans/2026-11-18-adapter-stateless-extraction.md`). **Prerequisite:** #555 step 2b (#654: the runner, its goldens and the gate) merged on `main`; B0 doesn't start before it. **Base:** `main` at 25dbdbe8. Line pointers are `Sources/SwiftStateTreeTransport/TransportAdapter.swift` ("TA") at that commit unless a file is named; they locate today's code and aren't part of the design.

## 1. Goal and rule

`TransportAdapter` becomes one `TurnActor`. Its machine holds every piece of adapter state. Every change to that state is made in a synchronous step or a synchronous answer. Work that waits (the keeper, the transport, timers) leaves the step as an effect, and its result comes back as an input. The core decides whether a result is still wanted, by the key the request was filed under and that key's generation. Handlers hold no tickets (core rule 4). This is Elm's `Cmd`/`Msg` shape; for timers the closer model is OTP's `erlang:start_timer/4` with `handle_info/2`, where the timer's reference comes back in the message the way rule 18's scheduled instant does.

The rewrite happens on one branch and merges once (harness plan rev 10). The branch is compared with the goldens `main` recorded; any difference fails the comparison unless the branch lists it (`ExpectedDifferences.swift`) or retires the row (`RetiredRows.swift`, with a replacement test).

**What stays outside the machine,** as `let` `Sendable` tools that `perform` and the commit routine use (#546's settled design):
- the encoders (`EncodingPipeline`, `SyncPlanning`, `SyncStreamCanonical`, after #554);
- the transport (`WebSocketTransport`);
- the recorder;
- `outboundWriter` and `outputGate`;
- `perPlayerTables` (`SyncTablePerPlayerDiff`, a `package final class`, `SyncTables.swift:1880`): it can't be `PlainData`. Its only writer is the plan-and-commit routine (§2.4), which runs synchronously on the actor inside a step or an answer, so it is mutated only in turns. A debug check asserts the routine is its only caller (§11).

The router, the manager, the keeper and NIO aren't rewritten. Their hold points stay where they are, so on both sides they are the same seam (the harness's kind (a)).

## 2. The machine: state, inputs, effects, keys

**Keys.**
- `.membership`: the land-wide ordering domain. Today every membership operation, whatever its SessionID, chains onto one `membershipQueueTail` (`enqueueMembership`, TA:3013): S2's registration waits behind S1's join or leave, and the land-stop leaves apply in submission order. The branch keeps that order. Every membership input (register, rebind, join, disconnect, leave) is a normal input with `waitsFor: [.membership]`, and the request it files holds `.membership` until the keeper's worker returns (`Hold.untilWorkerReturns(.membership, deadline:)`, rule 6), not until the request closes. Narrowing this to per-player domains is a later change with its own row, not part of this rewrite.
- `.session(SessionID, binding)`: one generation per connection binding, for checking results. A fresh key per binding avoids the core's known limit (an input for a key that isn't live steps under the next generation).
- `.joinAttempt(SessionID, attempt)`: one per router join attempt, ended by the router's end token or the session's end.
- `.syncCycle`, `.lagTimer`, `.followUp(n)` (one key per failed plan, §2.4), `.freeze` (debug only), `.land`.

**Scopes of queued inputs.** A queued input's scope decides what withdraws it. Membership inputs are scoped to `.land` and withdrawn by the router's `WithdrawToken` for their attempt, never by the end of an earlier binding's key: today a queued rebind survives the old binding's disconnect and the later rebind wins, and that stays true. Inbound frames for a joining session are scoped to their binding (§2.2).

### 2.1 Membership and sessions

| State today | Changed by (input) | Async result | Checked under |
|---|---|---|---|
| `MembershipCoordinator` (a `final class`, `MembershipCoordinator.swift:22`; becomes a `@PlainData` struct in B0), `connectionGenerations`, `endedSessions`, `supersededSessionCount` | `registerSession`, `disconnect`, `supersede` (all wait for `.membership`) | `transport.registerSession` → `.registered` | `.session` |
| `sessionTickets` (`GenerationTable`), `registrationTicketHolders` | gone in B2: the generation of `.session`. `ticketIsCurrentForTesting` compares with the machine's own current-binding field, because `core.read` borrows the machine only and can't see which keys are live (`TurnCore.swift:186`) | | |
| leave's tail (`releasePlayerSlot`, `syncEngine` removal, per-player tables, initial-sync entry; today after `await keeper.leave`, TA:1313–1342) | `.leaveApplied` | `keeper.leave` → `.leaveApplied`, holding `.membership` until the worker returns | `.land` |
| `membershipQueueTail` | gone in B2: the `.membership` domain | | |
| the recoverable teardown (`endSessionTicketsForTeardown`, TA:1577: ends tickets, clears lag, drops the inbound drains, fails join waiters) | `.teardownSessions` (control): `end` on every `.session` and `.joinAttempt` key; `.membership` and `.land` stay live | | |
| the terminal teardown (`onLandDestroyed`) | `.landDestroyed` (control): `endAll` (rule 15) | | |

**The stale-disconnect stamp (D2).** The router forwards a disconnect in a later task carrying only the SessionID and ClientID (LR:344–363). With reuse allowed, that disconnect could end a newer binding of the same SessionID. The router stamps the binding (the connection generation it registered) on the disconnect before the hop, and the adapter's step refuses a disconnect whose binding isn't the current one, counting it. Generation-aware output (#240: the `Transport` defaults that ignore the connection generation removed) is a prerequisite of reuse, so it moves to B2 (§4), not B7.

### 2.2 The join pipeline and its resolvers

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `memberJoinAttempts`, `staleJoinAttemptsRefused`, `expectedAdmissions` | `admitJoin` (the router's call: `sendAndWait`, waits for `.membership`) | `keeper.joinReportingAdmission` → `.keeperJoinReturned(result)`, holding `.membership` until the worker returns | `.joinAttempt` |
| `joiningSessions`, `joinWaiters` (`JoinWaiter` is a `final class`, TA:575; the waiter becomes a pending `reply(to:)` of the core), `nextInTurnJoinOrder` | `.keeperJoinReturned`, the flip in the commit routine (§2.4), `disconnect` | `keeper.requestJoinSyncTurn` → `.joinSyncRequested` | `.joinAttempt` |
| `initialSyncingPlayers`, the initial sync's drop counters | `syncStateForNewPlayer` (legacy path) | `.readForInitialSync` (§3.1 `initialSync`) | `.joinAttempt`; the commit epoch is captured in `perform` at the read, as today |
| `inboundAfterFlip`, `inboundClosedSessions`, the inbound and overflow counters | `message` for a joining session: the frame goes into the machine's bounded buffer for that binding (a `@PlainData` array, today's bound and overflow rules) | each buffered frame after the flip: a `.inboundNext(binding)` request whose `perform` holds `inboundDrainDispatch` and returns at once; its result step re-reads the buffer and the session and dispatches the next frame or drops the rest | `.session` |
| `heldEventOverflows`, the held-event counters | the commit routine | | `.session` |

**Keeper callbacks are answers.** The keeper's turn calls the adapter synchronously through `assumeIsolated` (`TransportAdapter+LandKeeperTransport.swift:29`, :43, :51, :59, :93). Each becomes a `query` whose `answer` is mutating (rule 13): `.admitJoining` (installs membership, or refuses an attempt whose `.joinAttempt` key has ended, before installing anything), `.refusesResolvedJoin`, `.joinInputsConsumed`, `.hasJoinsAwaitingSync` (read only) and `.syncPhase` (§2.4). **A query nested in an adapter step traps (rule 1); it can't happen,** because no adapter step calls the keeper synchronously: every keeper call is an effect in `perform`, which runs outside any step. The keeper and the adapter share the land's executor, so the keeper's synchronous call can't land in the middle of an adapter step either.

**The validate/apply shape (#588, #593)** is the keeper's. The adapter's `.keeperJoin` request keeps one request and one result (§7).

### 2.3 Action responses

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `actionResponseTasks`, `actionResponseTickets` | `action` (entry) | `keeper.awaitActionResult` → `.actionAnswered(sequence, outcome)` | `.session`: an answer after its binding ended goes to `handleLateResult`, dropped and counted |
| `actionResponsesFinished`, its waiters | the answer input | | the causal barrier (§6) |

### 2.4 Sync scheduling and the commit

**One plan-and-commit routine,** `planAndCommit(_ read: SyncRead) -> Commit`, synchronous, a method of the machine. Both modes call it:
- **in-turn:** inside the `.syncPhase` answer. The keeper's sync turn calls it synchronously and then applies `.committed` and clears dirty flags at once (`LandKeeper.swift:4618`, :4638), so the commit can't be a later input: it would step after the keeper moved on.
- **legacy:** inside the `.cycleRead` step (the result of `keeper.beginSync`).

The routine plans, encodes (with the `let` encoders and `perPlayerTables`), updates `lastSyncSeq`, `planSyncSeq`, `syncEngine`, `pendingEventManager`, `carriedDirtyFields`, the sync-stream sets and `syncPhaseCommits` (the commit epoch), flips the joins that this commit carries, and hands the frames to `outboundWriter`. There is no separate "commit input".

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `syncSkips`, `backlogDeferred…`, `backlogRetryScheduled`, `backgroundSyncTasks` | `syncRequested` (entry); the backlog retry is an input queued behind `.syncCycle`, not a task with a 1 ms sleep | | `.syncCycle` |
| the legacy cycle | `syncRequested` → `.legacyCycle` request holding `.syncCycle` | `keeper.beginSync` → `.cycleRead`; then `.endSync` request → `.cycleEnded` | `.syncCycle` |
| the keeper's sync flag that `beginSync` sets | released by `keeper.endSync` in every path: a `.cycleRead` that arrives stale (`handleLateResult`, e.g. after a teardown) skips the plan and files `.endSync` with `run`, which still steps after `endAll` | | |
| `startDelayedFollowUpSync` (failed plan, 100 ms) | a timer input per failure, each on its own key `.followUp(n)`: today each follow-up runs its own task, and rule 18 allows one timer per key, so they don't coalesce | | `.followUp(n)` |

**Both sync modes stay on the branch** (D1, §10): half the golden cells are legacy, and removing the legacy path is its own change (#550 and layer 3 PR B).

### 2.5 Sync lag

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `syncLag`, `syncLagFullPlanRequested` | `ack` (entry), the commit routine | | `.session` |
| `syncLagTimer`, `syncLagTimerEpoch`, `syncLagTimerSyncRequested` | a timer input `.lagTick` (`turn.timer(at:for: .lagTimer)`, skip-ahead per rule 18). Its step decides: closes go out as `.closeSession` requests, and the sync it asks for is a `.lagSync` request whose `perform` holds `syncLagTimerSync` and then sends `syncRequested` | | `.lagTimer`; the epoch is gone |
| the lag close | `.closeSession(code)` | `transport.closeSession` → `.closed` | `.session` |

### 2.6 Land failure, debug freeze

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `closeSessionsForLandFailure`, `outboundCeilingDisconnects` | `landFailed` (control) → `.closeSession(4016)` per session, then `close` | | `.land` |
| `debugFreezeState` (holds `Task` values and the land's `State`; the tasks become requests and timers, so the machine part is plain) | `debugFreeze` / `debugRelease` (control); the settle is a request, the auto-resume a timer under `.freeze` | `.settled` | `.freeze` |

**Counters and test hooks** move into the machine as plain fields, or stay `let` closures on the actor where they are faults read in `perform`.

## 3. Hold points: what each becomes

Every interleaving a hold forces today is one of:
- **a request whose result comes back as an input:** the hold sits in `perform`, before the neighbour's call ("request leaves") or after it returns, before its result input is sent ("result arrived, not yet applied");
- **a timer input:** a stepped test clock makes the sleep eligible to resume; the clock alone doesn't prove the step ran, so each timer test also waits for an apply milestone (an observation the step writes), and where today's test holds between the decision and its effect, the effect keeps a `perform` seam;
- **gone:** the interleaving can't happen; the test is replaced by an invariant test.

**No turn-core API is needed.** `perform` is the adapter's code, outside any step, so `await holds.at(.x)` there is legal. Entry holds sit in the adapter's entry methods. `SwiftStateTurns` stays free of `HoldPoints`. The one observation the core can't give (§3.1 `membershipQueued`) is built adapter-side: `TurnDiagnostic.queued(total:)` carries no key and fires only when an input parks (`TurnCore.swift:30`).

### 3.1 `TransportAdapterHoldPoint` (17)

User files are from `grep -rlw` over `Tests/`; counts are Review's (#655), helpers included.

| Hold | (a) What it forces today | (b) Becomes | (c) Seam on the branch | (d) Users (all), and how each keeps its order |
|---|---|---|---|---|
| `keeperJoinReturned` | after `await keeper.joinReportingAdmission`, before registration | the `.keeperJoin` result | `perform`, after the keeper returns, before `.keeperJoinReturned` is sent | 8: JoinFlip 4, JoinHeldEvents 2, RouterJoinTimeout 1, Hooks 1 (:368); harness rows disconnect-at-registration, join-during-sync-cycle-inturn, and the runner-wide join order. Same name, same point |
| `joinSyncRequested` | before `await keeper.requestJoinSyncTurn()` | the `.requestJoinSync` request | `perform`, before the call | JoinFlip 1; harness disconnect-at-registration. Same |
| `admitJoinEntry` | entry of `admitJoin`, before the membership queue | the `admitJoin` entry | entry method, before `sendAndWait` | RouterJoinAttempt 5, RouterJoinTimeout 4; harness disconnect-before-keeper-admission, join-during-sync-cycle. Same: a held entry hasn't taken its place in `.membership` yet, as today it hasn't enqueued |
| `membershipQueued` | in the queue's task, after the operation took its place, before it awaits the previous one | the membership input, sent and parked behind `.membership` | entry method, right after `send` returns (the input has its place), plus the adapter-side observation `membershipInputsWaiting` (incremented at `send`, decremented when the input steps) | 7: RegisterSession 5, DisconnectOwnership 1, Hooks 1; harness rows disconnect-during-keeper-join, disconnect-at-registration, land-stop (arrival counts, read from the observation). A test that holds it reaches the same point: the operation is queued and hasn't run. Holding it no longer delays the operation's start; each of the 7 tests is checked in B2 for that, and one that needs the delay holds the previous operation's `perform` seam instead |
| `cycleBeforeEndSync` (TA:3289, and `debugSettle` TA:6524) | before `await keeper.endSync()` | the `.endSync` request (legacy cycle and the freeze settle) | `perform`, before the call, in both requests | about 20: InTurnSync 2, and `TransportTestHelpers`' helper in 18 tests (TargetedEventOnce, SyncDirtyWindow, SyncBackPressure, PendingEventsAcrossCycles); harness join-during-sync-cycle and its in-turn variant. Same. The settle's site moves in B6 with the freeze; until then B5's request and the legacy settle share the hold name |
| `actionResponse` | start of `finishActionResponse`, before the ticket check | the `.awaitActionResult` result | `perform`, after the answer, before `.actionAnswered` is sent | ActionJob 1, Hooks 1; harness stale-action-reply. Same. The race mutant becomes "the core routes a late result to `handle`": killed by the core's checks and, after D2, by the row on a reused SessionID |
| `initialSync` | before the commit-epoch capture and the state read (TA:5536) | the `.readForInitialSync` request | `perform`: hold, then capture the epoch (`core.read`), then the read | JoiningAdmission 4, NewestWins 1. Same order: the epoch is captured after the hold, as today, so a commit during the hold doesn't drop the initial sync |
| `initialSyncAfterRead` | after the read, before the epoch check and commit | its result | `perform`, after the read, before `.initialSyncRead(state, epoch)` is sent | InitialSyncBehindCommit 1, TicklessPassOrdinal 1, InitialSyncStaleRead 1. Same; the handler compares the carried epoch |
| `inboundDrainDispatch` | after a deferred frame is popped, before its ticket check and dispatch | the `.inboundNext` request (§2.2) | `perform`, which only holds; the step for its result decides the frame | JoinPendingInbound 4. **Kept, not retired**: a disconnect during the hold ends the binding's key, the result goes to `handleLateResult`, and the frame and the rest are dropped and counted, as today |
| `failedPlanFollowUp` | after the 100 ms sleep, before `syncNow` | the `.followUp(n)` timer | the timer's step files a `.followUpSync` request whose `perform` holds it, then sends `syncRequested` | one install serves 7 PerPlayerSyncTablesScenario tests, plus InitialSyncBehindCommit 1, SyncOutputVerifier 1. The clock wakes it; the hold keeps the window |
| `debugFreezeAutoResumeFired` | start of the auto-resume, before its generation check | the `.freeze` timer | none: the test gates the wake | DebugFreeze 2. The test clock resumes sleepers one at a time; the test advances to the instant, resumes the sleeper, and waits for the apply milestone `autoResumesApplied` |
| `debugFreezeAutoResumeStale` | the stale branch of the auto-resume | gone: a replaced timer never fires (rule 18) | none | DebugFreeze 2. **Retires** (§5) |
| `syncLagTimerSync` | in the lag sync, before `syncNow` | the `.lagSync` request (§2.5) | `perform`, before `syncRequested` is sent | SyncLag 1. The test runs decision → disconnect → sync as today: the decision is the `.lagTick` step, the disconnect happens while the hold has the sync |
| `syncLagClose` | before `await transport.closeSession` | `.closeSession` | `perform`, before the call | 6: SyncLagCloseDecidedLog 3, SyncLag 3. Same |
| `syncLagClosed` | after `closeSession` returned | its result | `perform`, after the call | 5: SyncLagCloseDecidedLog 2, SyncLag 3. Same |
| `registrationAfterKeeperRead` | after `await keeper.entrySession(for:)`, before the ticket resolve | the `.readEntrySession` result | `perform`, after the read | RegisterSession 7. Same |
| `registrationGeneration` | before `await webSocketTransport.registerSession` | `.registerWithTransport` | `perform`, before the call | RegisterSession 2. Same |

### 3.2 The neighbours' holds

The router's 14, the manager's 6 and the keeper's 15 stay unchanged, and the harness rows that use them keep their order (router `beforeAdmit`, `afterAdmit`, `sendingJoinResponse`, `sendingInitialSync`, `stopLeave`, `disconnectForwarded`; keeper `.join`, `.leave`, `syncOnlyAfterLegacyCycle`). `flipWaitResumed` (LR:1378) and `afterAdmit` (LR:1099) sit right after an adapter call returns; the entry methods keep their signatures, so `sendAndWait` returns where the method returns today.

### 3.3 The harness's ordering hooks on the branch

| Hook | On the branch |
|---|---|
| router, keeper and NIO hooks (`waitForDisconnectForwardsForTesting`, `waitForNoPendingFlipForTesting`, `waitForInputDrainIdleForTesting`, `stepTickOnce`, `syncOnlyTurnAfterLegacyCycleForTesting`, `onAfterSessionsClosedForTesting`, …) | unchanged |
| `waitForBackgroundSyncsForTesting` | the causal barrier (§6) restricted to `.syncCycle` work |
| `syncNow` | `sendAndWait(syncRequested)`, returning at that cycle's commit or skip |
| `captureJoinCommitsForTesting`, `joinFlippedForTesting`, `initialSyncCommittedForTesting`, `admittedNotRegisteredForTesting`, `pendingActionCountForTesting`, `staleJoinAttemptsRefused`, `teardownTicketEnds`, `syncDeferredByCycleCountForTesting` | `core.read` of machine fields, same meaning |
| `sessionTicketForTesting`, `ticketIsCurrentForTesting` | the machine's current-binding field per session (a `core.read`); not the core's key table, which `read` can't see |
| writer and transport state in `waitForOutboundIdleForTesting` | read from `outboundWriter` and the transport directly, not `core.read` |

**The holds the harness's scenarios need:** `keeperJoinReturned` and `joinSyncRequested` sit in `perform`, `admitJoinEntry` at the entry (§3.1); `disconnectForwarded` (router) and `syncOnlyAfterLegacyCycle` (keeper) don't move. The `membershipQueued` arrival count reads `membershipInputsWaiting`.

## 4. The order of the rewrite inside the branch

The branch is `rewrite/546-adapter-turn-core`. It merges `main` and never rebases. Each step is a group of commits Review takes one at a time, and ends at a named SHA recorded in a branch comment.

**Each step's gate, run at that SHA:**
- the harness: every golden cell compared, green or covered by a listed entry;
- `swift test` with in-turn sync on and off, and with `USE_SYNC_TABLES=false`;
- E2E in all six cells: `json`, `opcodeJsonArray`, `messagepack` × `IN_TURN_SYNC` on and off;
- the wall-clock baseline lowered for the files the step touched (§6);
- `scripts/pre-push-checks.sh origin/main`.

**Owners and bridges.** "Machine" means the machine is the only writer; "actor" means the old actor field still is. A bridge is synchronous: the machine emits an output (`turn.emit`) that the actor applies to its own fields right after the step, before the next input, or the actor's code calls `core.query` outside a step. No bridge awaits.

| Step | Moves to the machine (owner from here on) | Still on the actor | Bridges | Deletes |
|---|---|---|---|---|
| B0 | nothing; `MembershipCoordinator`, `EndedSessionSet` and the other class-free state become `@PlainData` value types under the old adapter | all | none | the class |
| B1 | an empty machine, `TurnCore`, the production `TurnClock` over `safeTaskSleep` | all | none | nothing |
| B2 | membership and sessions (§2.1): the `.membership` domain, register, rebind, supersede, disconnect, leave, the recoverable teardown; the router's binding stamp; generation-aware output (#240); `registerSession`'s required `WithdrawToken` | join, inbound, sync, lag, actions | leave's tail and the teardown emit `.clearPlayer` / `.droppedInbound` / `.failJoinWaiters` outputs that the actor applies to its join, inbound and sync caches | `membershipQueueTail`, `GenerationTable` and the tickets for sessions, `registrationTicketHolders` |
| B3 | the join pipeline (§2.2): admission, keeper join, registration, held events, the inbound buffer, the initial sync, the keeper's admission answers; `JoinAdmission.refused` | sync, lag, actions | the legacy commit code (still the actor's) calls `core.query(.flipCommitted(joins))` to flip | the join waiters, the inbound drains, the join tickets |
| B4 | action responses (§2.3) | sync, lag | none | the action tickets and tasks |
| B5 | sync and lag (§2.4, §2.5): `planAndCommit` in the `.syncPhase` answer and the `.cycleRead` step, the legacy cycle as requests, the retry, the follow-ups, the lag timer | land failure, freeze | the freeze settle's `.endSync` shares the B5 request; the actor's freeze code files it with `core.send` | B3's flip bridge, `backgroundSyncTasks`, the lag timer task |
| B6 | land failure, the terminal teardown, the debug freeze (§2.6) | nothing | none | the freeze tasks, `teardownTicketEnds`' old path |
| B7 | nothing new | | | what's left: the `…Queued` wrappers, unused helpers, the adapter's last `GenerationTable` / `SingleFlight` / `Lifecycle` use |

The public changes land in the step that needs them (B2, B3), so every step builds and runs on its own. They are breaking; there are no external users, so they need no deprecation.

**Stop conditions** (from #546): a step needs a coordinator-shaped API: stop and redo the outline; the deleted scaffolding is as large as the added machine: revisit; a step's host A/B regresses beyond the gate: stop and find the cause.

## 5. Retired rows and replacement invariants

**Harness rows: none planned.** Every row's holds keep their semantic boundary (§3). `RetiredRows.swift` stays empty unless a step finds otherwise; any entry goes through Review, and Main approves it with its witness's failing output.

**Unit-test holds that retire:**

| Hold | Tests | Replacement invariant | Witness |
|---|---|---|---|
| `debugFreezeAutoResumeStale` | DebugFreeze (2) | The test gates the old wake (doesn't resume its sleeper), re-arms the freeze, then resumes the old sleeper: the core reports `.staleTimer` and nothing thaws. Then it resumes the new sleeper: both actors thaw, seen at the apply milestone. Core checks 26 and 29 | a mutant that arms each auto-resume on a fresh key without ending the old one |

`inboundDrainDispatch` and `membershipQueued` don't retire (§3.1). JoinPendingInbound's four tests stay as they are, each its own witness: FIFO across the flip; overflow after the flip while membership is live, including the final frame, the close and the later drops; a disconnect with no late reply; the teardown's drop accounting.

Main approves each retirement after Review (rev 10's rule).

## 6. The 485 adapter-side wall-clock polls (#458)

#458's split (issuecomment-7007487698) leaves 485 polls in 58 files to this rewrite; most are `waitForOutboundDrain` helper polls.

**The causal barrier, not an idle sample.** An idle sample is a proxy: an abandoned worker, a `run` or a timer can finish after it (`Notes/solutions/2026-11-10-a-returned-send-is-not-a-delivered-frame.md`). `waitForQuiescenceForTesting()` counts work from its launch (each `send`, `request`, `run` and timer arm) through its completion step and the writer's flush, abandoned workers included, and returns when the count is zero, rechecking after the writer hands off to the transport. A test that asserts a delivered frame waits for the test transport to receive it, not for the barrier.

How the rewritten tests wait:
- on the barrier, or `sendAndWait`, for "the adapter has processed X";
- on the stepped clock plus the timer step's apply milestone for timers;
- on a hold (§3) for a race.

Each step converts the files it touches and lowers `scripts/wall-clock-baseline.txt` in the same commit, so the baseline only goes down. Each converted pattern gets one mutant run showing the new wait still fails when the awaited work is removed. At B7, every adapter-side entry is gone, or listed with its reason (a test of the clock itself).

## 7. #652, #548, #588 in the new model

- **#652 (a SessionID reused after a disconnect is refused as stale).** Proposed (D2): allow reuse. It is safe only with two things in place, both in B2: the router's binding stamp on forwarded disconnects (§2.1), and generation-aware output (#240). With them, the old binding's late results go to `handleLateResult` and a stale disconnect is refused. The router clears the ended entry when a new connection binds the SessionID, and `endedSessions` goes away. The stale-reply row then moves to a reused SessionID on `main` first (rows change on `main`), its cells are re-recorded, and the race mutant must fail it. NIO mints a fresh SessionID per connection, so production is unaffected. The alternative: forbid reuse with its own error code; the row stays on a fresh SessionID and the race witness is the core's alone.
- **#548 (a teardown during the keeper's join re-creates the session's membership).** The golden row's teardown is the recoverable one (`endSessionTicketsForTeardown`; the row joins A2 afterwards), so on the branch it is `.teardownSessions`, not `endAll` (§2.1). Then:
  1. the keeper's join result arrives for an ended `.joinAttempt` key and goes to `handleLateResult`;
  2. there the machine compensates under `.land`, which is still live: it files the keeper's `leave` for the player that attempt admitted (the keeper's join sequence travels in the result, so the leave targets that admission and not a later one), holding `.membership` until the worker returns;
  3. A2's register and join wait for `.membership`, so they step only after that leave's worker has returned and its `.leaveApplied` tail has run;
  4. in the in-turn path, the keeper's `.admitJoining` answer refuses an attempt whose key has ended before membership is installed; the keeper's hold `.join` sits after its refusal check (`LandKeeper.swift:1734`, :1753), so in this row the admission is late and step 2 applies.

  The golden records the bug, so the branch lists one expected difference on the row (harness plan rev 10, "The #548 row"): no current binding for A, `teardownTicketEnds == 1`, no initial sync for A, A's join refused. If the compensation changes the lifecycle the oracle checks, the entry says so per cell.
- **#588 (`CanJoin` and `OnJoin` run in different turns).** The keeper's change (#593), not the adapter's. It moves `CanJoin` from the resolve milestone (before the keeper's join turn) into the apply turn, with the stale-join refusal, `maxPlayers`, the duplicate-login kick and the draining guard. The `.keeperJoin` request keeps one result, so the machine doesn't change. Proposed (D3): land #588 before the goldens are recorded, or after the rewrite merges. If it has to land during the freeze, it lands on `main` with its re-recorded goldens in the same PR (the recorder in the pinned image), and the branch merges `main`.

## 8. The performance A/B

The host runs it at the end of B5 (the sync path) and before the merge, on the instruction gate (#517; `Notes/plans/2026-11-13-off-path-instruction-gate.md`):
- **Base:** `main` at run time. **Head:** the branch merged with that `main`. Release builds, both sides in one container from the pinned image, with `swift --version` and the digest recorded. ABBA, one warm-up pair discarded, then 5 pairs, with `SWIFT_DETERMINISTIC_HASHING=1`.
- **Cells:** #554's five EncodingBenchmark cells (`rows-mp`, `rows-json`, `router-mp`, `rows-mp-100`, `json-control`) with `ENCODING_BENCHMARK_PERF_WINDOW=iteration`, plus `nonsync` for the per-message `core.read`.
- **Judged:** mean `instructions:u` per cell; a REGRESSION above base by more than max(0.5 %, 3 × base's spread). The per-message budget is #546's: about +100 instructions for the one `core.read`, against `TurnsBench`'s `read` figure on the host. Time is reported, not judged.
- **ServerLoadTest:** the zero-disconnect bar at today's room and player counts, both sides, reported.
- Encoded bytes and the patch and event counts per cell must equal base's.

## 9. Public API

- **Changed:**
  - B2: `registerSession` takes a required `WithdrawToken`, replacing `JoinAttemptEnd`; the `Transport` defaults that ignore the connection generation (`closeSession`, `sendSessionFrames`) are removed (#240).
  - B3: `JoinAdmission` gets a `refused` case and `isAdmitted` becomes a `switch`; a switch over it breaks.
- **Added (package only):** `waitForQuiescenceForTesting`, `membershipInputsWaiting`, `autoResumesApplied`, the test clock's one-at-a-time resume.

## 10. Decisions for the maintainer

- **D1.** Keep both sync modes on the branch (proposed), or remove the legacy path on `main` first (#550, layer 3 PR B) and re-record. Keeping both lets every golden cell compare, and keeps the production rollback switch (`IN_TURN_SYNC=false`) working through the rewrite; it costs B5 the legacy cycle as requests.
- **D2.** #652: allow a reused SessionID (proposed, with the binding stamp and generation-aware output in B2), or forbid it explicitly (§7).
- **D3.** #588: before the recording or after the merge (proposed); during the freeze only with its goldens re-recorded in the same PR on `main` (§7).

## 11. Risks

- **The per-message `core.read`.** If it costs more than the budget on 6.2.4 (cross-module specialization, #621), the sync path regresses. Guards: `check-turns-inlinable.sh` and the A/B at the end of B5.
- **`perPlayerTables` outside the machine.** A class mutated only by the commit routine; if a later change calls it from `perform`, the rule breaks silently. Guard: a debug-build assertion that it runs on the actor inside a step or an answer (the core's `stepping` flag, read through the package diagnostic).
- **The land-wide `.membership` domain** serialises membership across sessions exactly as today; it is not a throughput change, and per-player domains are out of scope.
- **A hold whose boundary has no equivalent.** §3 maps every one. If a step finds a row whose order can't be forced at the mapped seam, the row is retired only after Review and Main approve it.
- **The branch's size.** One merge for the whole rewrite; each step's gate at its SHA is the guard.

## 12. Rev 2: where each review point went

- Must-fix 1 (land-wide queue, observation, rebind scope): §2 keys and scopes, §2.1, §3.1 `membershipQueued`.
- Must-fix 2 (#548 after `endAll`): §2.1 teardown rows, §7 #548, `.untilWorkerReturns` in §2.
- Must-fix 3 (in-turn commit): §2.4 `planAndCommit`, §2.2 keeper callbacks, rule 1, the `beginSync` flag.
- Must-fix 4 (bisectability): §4 owners, bridges, B0 value conversion, per-step gate and E2E matrix, the #654 prerequisite.
- Shoulds: counts (§3.1), `initialSync` epoch (§3.1), timer milestones and `.followUp(n)` (§2.4, §2.5, §3.1), inbound (§2.2, §3.1, §5; kept instead of retired), causal barrier (§6), D1–D3 (§10, §7), OTP (§1).
- Nit: `core.read`'s reach (§2.1, §3.3).
