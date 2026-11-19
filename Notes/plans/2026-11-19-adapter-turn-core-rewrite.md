# TransportAdapter on the turn core: the rewrite (#546)

**Status:** rev 3, plan only, for review.
- Rev 2 (55a4a93b) was NOT GO with 4 must-fix, 6 should and 1 nit; rev 3 folds them in (§12).
- **One decision is open for the maintainer, D4 (module layering, §10). B0 can't start until it is answered.**

**Issue:** #546.

**Inputs:**
- the turn core (#551, merged as #608; `Notes/plans/2026-11-18-swift-state-turns-core.md`);
- the differential harness (#555; `Notes/plans/2026-11-19-adapter-differential-harness.md`, rev 10);
- the stateless extraction (#554; `Notes/plans/2026-11-18-adapter-stateless-extraction.md`).

**Prerequisite:** #555 step 2b (#654: the runner, its goldens and the gate) merged on `main`.

**Base:** `main` at 25dbdbe8. Line pointers are `Sources/SwiftStateTreeTransport/TransportAdapter.swift` ("TA") at that commit unless a file is named.

## 1. Goal and rule

`TransportAdapter` becomes one `TurnActor`. Its machine holds the adapter's state, and every change to that state is made in a synchronous step or a synchronous answer. Work that waits (the keeper, the transport, timers) leaves the step as an effect, and its result comes back as an input. The core decides whether a result is still wanted, by the key the request was filed under and that key's generation. Handlers hold no tickets (core rule 4).

This is Elm's `Cmd`/`Msg` shape. For timers the closer model is OTP's `erlang:start_timer/4` with `handle_info/2`: the timer's reference comes back in the message, as the instant does in the core's timer input (`timer(at:for:_:)` builds the input from the scheduled instant).

The rewrite happens on one branch and merges once (harness plan rev 10). The branch is compared with the goldens `main` recorded. Any difference fails the comparison, unless the branch lists it (`ExpectedDifferences.swift`) or retires the row (`RetiredRows.swift`, with a replacement test).

**What stays outside the machine,** as `let` tools that `perform` and the commit routine use (#546's settled design):
- the encoders (`EncodingPipeline`, `SyncPlanning`, `SyncStreamCanonical`, after #554);
- the transport (`WebSocketTransport`);
- the recorder;
- `outboundWriter` and `outputGate`;
- `perPlayerTables` (`SyncTablePerPlayerDiff`, a `package final class`, `SyncTables.swift:1880`).

Besides these, D4 decides whether more state stays outside: the fields of other modules' types (§10).

**The "mutated only in turns" guard.** Every tool with mutable state is changed only from inside a step or an answer. A debug assertion checks this at each writer: `core.borrowStateForTesting < 0` holds only while a step or an answer runs (`TurnCore.swift:84`).

The router, the manager, the keeper and NIO aren't rewritten; the one keeper change (§7, #548) is named where it lands. Their hold points stay where they are, so on both sides they are the same seam.

## 2. The machine: keys, the membership chain, scopes

**Keys.**
- `.membership`: the land-wide ordering domain (§2.1).
- `.membershipEpoch(n)`: the scope of queued membership inputs. The recoverable teardown ends epoch `n` and starts `n + 1`.
- `.session(SessionID, binding)`: one generation per connection binding, for checking results. A fresh key per binding avoids the core's known limit: an input for a key that isn't live steps under the next generation.
- `.joinAttempt(SessionID, attempt)`: one per router join attempt.
- `.syncCycle`, `.lagTimer`, `.followUp(n)` (one key per failed plan), `.freeze` (debug only), `.land`.

### 2.1 The membership chain

Today one FIFO slot (`enqueueMembership`, TA:3013) runs a whole membership operation before the next starts, whatever its SessionID:
- a join: `performJoinQueued` (TA:2155) runs `keeper.joinReportingAdmission` (:2202), then registration through `_registerSessionImpl` (:2246, which awaits `keeper.entrySession` and `transport.registerSession`), then `keeper.requestJoinSyncTurn()` (:2264);
- a disconnect: `keeper.leave` (:1314) and its tail.

The branch keeps that whole operation inside `.membership`:
- every membership input (register, rebind, join, disconnect, the queued flip timeout) has the policy `.normal(waitsFor: .membership, belongsTo: .membershipEpoch(n), withdrawnBy: token)`;
- the operation is a chain of requests, each holding `.membership` with `Hold.untilWorkerReturns(.membership, deadline:)` (rule 6).

**How the hold passes from one link to the next.** Each link's completion step files the next link, holding `.membership`. The core keeps the finished link's hold owned through its completion step, and releases parked inputs only after the step (`TurnActor.swift:170–176`: "a handover ... never leaves the key free in between"). So no queued input can step between two links of one operation.

The chains:

| Operation | Links, in order (each holds `.membership`) | Chain ends |
|---|---|---|
| join | `.keeperJoin` → `.readEntrySession` → `.registerWithTransport` → `.requestJoinSync` | at the `.requestJoinSync` completion step |
| register without a join (a host registration, a rebind) | `.readEntrySession` → `.registerWithTransport` | at the `.registerWithTransport` completion step |
| disconnect, leave, supersede's leave | `.keeperLeave`; its completion step runs the leave's tail (`.leaveApplied`: slot release, sync engine, per-player tables, initial-sync entry) | at that step |
| #548's compensation (§7) | `.keeperLeave` filed from the late join's step | at its tail |

**When a link fails.**
- **Abandoned (deadline):** `handleAbandoned` runs. Because the hold is `untilWorkerReturns`, `.membership` stays held until the worker actually returns. The worker's result then arrives as a late result (`handleLateResult`), with the hold handed over the same way (`retire`, then `stepStale`, then the release drain). That step finishes the operation:
  - a late `.keeperJoin` that admitted files the compensating `.keeperLeave` (§7);
  - a late `.keeperLeave` still runs the leave's tail, which is idempotent.

  So a leave is never lost.
- **Refused, by the keeper or the transport:** the completion step ends the chain, answers the router, and runs the cleanup that today's code runs on that path.
- **`queueFull` at `send`:**
  - A register or join is answered with the refusal, and the connection is closed, as an overflow is today.
  - A disconnect can't be refused, because a lost disconnect would leak a slot. On `queueFull`, the entry method sends the control input `.disconnectOverflow(session, binding)`. Its step ends the binding's key, which withdraws its queued inputs. It also appends the leave to the machine's `pendingLeaves` list, and every chain-end step files the first pending leave as the next chain.
  - The queue limit is set above the land's player limit times the membership inputs one session can have queued, so `queueFull` is a fault path, not a normal one.

**Inputs that bypass `.membership`:** the control inputs `.teardownSessions`, `.landDestroyed`, `.landFailed`, `.disconnectOverflow`, `debugFreeze` and `debugRelease`.

**Timer inputs don't wait by default.** The join's flip timeout goes through the membership queue today (`startJoinWaiter`, TA:1731–1735), so its timer step queues `.timeOutJoin(session, attempt)` behind `.membership` (`turn.queue(_:behind:)`). That handler checks `isLive(.joinAttempt)` before it acts.

**Scopes and withdrawal.**
- A queued membership input belongs to the epoch that was current when it was sent. The entry method reads the epoch with `core.read` and sends in the same synchronous segment.
- `.teardownSessions` ends that epoch. That withdraws every queued registration, join and rebind, as today's teardown ends their tickets.
- A disconnect of one binding doesn't end the epoch. So a queued rebind survives the old binding's disconnect, and the later rebind wins, as today.
- `withdrawnBy` is the router's `WithdrawToken` for the attempt. A host registration (no join attempt) passes a fresh token the host never fires; `registerSession`'s token parameter is required (§9).

**The stale-disconnect stamp (D2).** With a reused SessionID allowed, a disconnect carrying only the SessionID could end a newer binding. The binding is stamped wherever a close or leave is decided by ID:
- the router's forwarded disconnect (LR:344–363);
- the router's stop and shutdown leaves, which close by ID after `leave` (LR:578–596): the stamp is taken in the stop snapshot;
- the transport's own ID lookup in `registerSession`: the call passes the binding.

The adapter's step refuses a disconnect whose binding isn't current, and counts it. Generation-aware output (#240) is a prerequisite, so it lands with membership (§4).

### 2.2 State groups

| Group | State today | Owner on the branch | Results checked under |
|---|---|---|---|
| membership | `MembershipCoordinator` (a `final class`), `connectionGenerations`, `endedSessions`, `supersededSessionCount`, `sessionTickets`, `registrationTicketHolders`, `membershipQueueTail` | machine (representation per D4); the ticket table and the queue tail are replaced by the keys and the chain | `.session`, `.membership` |
| join | `memberJoinAttempts`, `staleJoinAttemptsRefused`, `expectedAdmissions` (stores a join response), `joiningSessions`, `joinWaiters` (`JoinWaiter` is a class; it becomes a pending `reply(to:)`), `nextInTurnJoinOrder`, `initialSyncingPlayers`, the initial sync's counters, held events | machine | `.joinAttempt` |
| inbound | `inboundAfterFlip`, `inboundClosedSessions`, the inbound and overflow counters | machine: a bounded buffer per binding with today's bound and overflow rules | `.session` |
| actions | `actionResponseTasks`, `actionResponseTickets`, `actionResponsesFinished` | machine | `.session` |
| sync | `syncSkips`, the backlog flags, `backgroundSyncTasks`, `lastSyncSeq`, `planSyncSeq`, `syncEngine`, `pendingEventManager`, `carriedDirtyFields`, the sync-stream sets, `syncPhaseCommits` | machine (representation per D4) | `.syncCycle` |
| lag | `syncLag`, `syncLagFullPlanRequested`, the lag timer and its epoch | machine; the timer is `.lagTimer` | `.lagTimer`, `.session` |
| failure, teardown | `teardownTicketEnds`, `closeSessionsForLandFailure`, `outboundCeilingDisconnects` | machine | `.land` |
| freeze | `debugFreezeState` (stores `Task` values and the land's `State`) | machine; the tasks become a request and a timer; `State` per D4 | `.freeze` |

**The two teardowns.**
- `.teardownSessions` is the recoverable one, today's `endSessionTicketsForTeardown` (TA:1577). It ends every `.session` and `.joinAttempt` key and the current `.membershipEpoch`. It clears lag, drops the inbound buffers with their accounting, and fails the join waiters. `.membership` and `.land` stay live.
- `.landDestroyed` is the terminal one (`onLandDestroyed`): `endAll` (rule 15).

### 2.3 The join pipeline and inbound

- **The keeper's callbacks are answers.** The keeper's turn calls the adapter synchronously through `assumeIsolated` (`TransportAdapter+LandKeeperTransport.swift:29`, :43, :51, :59, :93). Each becomes a `query` whose `answer` is mutating (rule 13):
  - `.admitJoining`: installs membership, or refuses an attempt whose `.joinAttempt` key has ended before installing anything;
  - `.refusesResolvedJoin`;
  - `.joinInputsConsumed`;
  - `.hasJoinsAwaitingSync` (read only);
  - `.syncPhase` (§2.4).
- **Inbound frames for a joining session, two milestones per frame,** as today's drain has:
  1. after the flip, a step pops the next frame from the binding's buffer, takes it out of the buffered-byte accounting and keeps the active-drain marker. It files `.inboundHold(frame)`, whose `perform` holds `inboundDrainDispatch` and returns the frame;
  2. that request's completion step checks that the binding is live. If it is, it files `.inboundDispatch(frame)`, which hands the frame to the keeper. If not, it drops the frame and the rest, and counts them. Only `.inboundDispatch`'s completion step pops the next frame, so a frame's dispatch finishes before the next pop.

  A disconnect during the hold ends the binding's key, so the first request's result is late and the frame is dropped, as today.

### 2.4 The commit and its synchronous calls

**One plan-and-commit routine,** `planAndCommit(_ read: SyncRead) -> Commit`, synchronous, a method of the machine:
- **in-turn:** inside the `.syncPhase` answer. The keeper's sync turn calls it, then applies `.committed` and clears dirty flags at once (`LandKeeper.swift:4618`, :4638), so the commit can't be a later input;
- **legacy:** inside the `.cycleRead` step, the result of `keeper.beginSync`.

The routine plans and encodes, updates the sync state of §2.2 and the commit epoch, flips the joins this commit carries, and hands the frames to the writer.

**Synchronous calls inside the routine, allowed and kept there.** Each is a synchronous call out of the machine that doesn't re-enter the adapter. Each stays inside the routine, so its order relative to the commit is today's:
- `keeper.assumeIsolated { $0.recordsSyncStream }` (TA:3844);
- `submitSyncStream(drafts)` (:3882) and the single-draft `submitSyncStream` (:4009). The single-draft form is also called from the leave's tail and from supersede, both steps;
- the writer's synchronous enqueue (`outboundWriter`).

Moving any of these to `perform` would put the record after later commits. **Rule 1 (a query from inside a step traps)** is not at risk: none of these calls the adapter back. A test with the trap armed covers it: a mutant that makes the recorder call an adapter query must trap.

**The legacy flag.** Only a successful `beginSync` owns the keeper's sync flag:
- the `.legacyCycle` request holds `.syncCycle` until `endSync` has returned;
- `endSync` runs exactly once after a successful `beginSync`, also when its `.cycleRead` result is late. Then `handleLateResult` skips the plan and files `.endSync` with `run`, which still steps after `endAll`;
- a `beginSync` that failed or returned no read files no `endSync`.

**Retries and follow-ups.**
- The backlog retry is an input queued behind `.syncCycle`, not a task with a 1 ms sleep.
- A failed plan's follow-up is a timer on its own key `.followUp(n)`. Today each follow-up runs its own task, and rule 18 allows one timer per key, so the follow-ups don't coalesce.

**Lag.** `.lagTick` is a timer on `.lagTimer`, with skip-ahead (rule 18). Its step decides the closes and the sync:
- closes go out as `.closeSession` requests;
- the sync is a `.lagSync` request, whose `perform` holds `syncLagTimerSync` and then sends `syncRequested`.

**Both sync modes stay on the branch** (D1).

## 3. Hold points: what each becomes

Every interleaving a hold forces today becomes one of three things:
- **a request whose result comes back as an input.** The hold sits in `perform`, either before the neighbour's call ("request leaves"), or after it returns and before its result input is sent ("result arrived, not yet applied");
- **a timer input.** A stepped test clock makes the sleep eligible to resume. Each timer test also waits for an apply milestone, an observation that the step writes. Where today's test holds between the decision and its effect, the effect keeps a `perform` seam;
- **gone.** The test is replaced by an invariant test.

`perform` and the entry methods are the adapter's code, outside any step, so their holds need no turn-core API, and `SwiftStateTurns` stays free of `HoldPoints`.

### 3.1 `TransportAdapterHoldPoint` (17)

Users are from `grep -rlw` over `Tests/`; the counts are Review's, helpers included.

| Hold | (a) What it forces today | (b) Becomes | (c) Seam on the branch | (d) Users, and how each keeps its order |
|---|---|---|---|---|
| `keeperJoinReturned` | after `keeper.joinReportingAdmission`, before registration | `.keeperJoin`'s result | `perform`, after the keeper returns, before the result is sent; `.membership` is still held | 8: JoinFlip 4, JoinHeldEvents 2, RouterJoinTimeout 1, Hooks 1; harness disconnect-at-registration, join-during-sync-cycle-inturn, the runner-wide join order. Same |
| `joinSyncRequested` | before `keeper.requestJoinSyncTurn()` | `.requestJoinSync` | `perform`, before the call | JoinFlip 1; harness disconnect-at-registration. Same |
| `admitJoinEntry` | entry of `admitJoin`, before the queue | the entry | entry method, before `sendAndWait` | RouterJoinAttempt 5, RouterJoinTimeout 4; harness disconnect-before-keeper-admission, join-during-sync-cycle. Same |
| `membershipQueued` | after the operation took its place, before it awaits the previous one | the membership input, parked behind `.membership` | entry method, right after `send` returns, only when the input parked; and the observation `membershipInputsWaiting` (§6) | 7: RegisterSession 5, DisconnectOwnership 1, Hooks 1; harness disconnect-during-keeper-join, disconnect-at-registration, land-stop (arrival counts). Holding the seam no longer delays the operation's start; B3 checks each of the 7 tests for that, and one that needs the delay holds the previous chain's `perform` seam |
| `cycleBeforeEndSync` (TA:3289; `debugSettle` TA:6524) | before `keeper.endSync()` | `.endSync`, in the legacy cycle and the freeze settle | `perform`, before the call | about 20: InTurnSync 2, and the `TransportTestHelpers` helper in 18 tests (TargetedEventOnce, SyncDirtyWindow, SyncBackPressure, PendingEventsAcrossCycles); harness join-during-sync-cycle and its in-turn variant. Same; the settle moves with sync in B2 (§4) |
| `actionResponse` | before the ticket check | `.awaitActionResult`'s result | `perform`, after the answer | ActionJob 1, Hooks 1; harness stale-action-reply. Same |
| `initialSync` | before the epoch capture and the read (TA:5536) | `.readForInitialSync` | `perform`: hold, then capture the epoch with `core.read`, then the read | JoiningAdmission 4, NewestWins 1. Same order |
| `initialSyncAfterRead` | after the read, before the epoch check | its result | `perform`, after the read | InitialSyncBehindCommit 1, TicklessPassOrdinal 1, InitialSyncStaleRead 1. Same |
| `inboundDrainDispatch` | after a frame is popped, before its check and dispatch | `.inboundHold` (§2.3) | `perform` of `.inboundHold` | JoinPendingInbound 4. Kept: both milestones, the accounting and the marker as today |
| `failedPlanFollowUp` | after the 100 ms sleep, before `syncNow` | the `.followUp(n)` timer | its step files `.followUpSync`, whose `perform` holds | 7 PerPlayerSyncTablesScenario tests through one install, InitialSyncBehindCommit 1, SyncOutputVerifier 1. Same window |
| `debugFreezeAutoResumeFired` | start of the auto-resume | the `.freeze` timer | none: the test gates the wake | DebugFreeze. The test clock resumes sleepers one at a time; the apply milestone is `autoResumesApplied`, written after the keeper has resumed |
| `debugFreezeAutoResumeStale` | the stale branch | gone (rule 18) | none | 1 test, 2 references. **Retires** (§5) |
| `syncLagTimerSync` | before the lag sync's `syncNow` | `.lagSync` | `perform`, before `syncRequested` | SyncLag 1: decision (the `.lagTick` step) → disconnect → sync, as today |
| `syncLagClose` | before `transport.closeSession` | `.closeSession` | `perform`, before the call | 6: SyncLagCloseDecidedLog 3, SyncLag 3. Same |
| `syncLagClosed` | after `closeSession` | its result | `perform`, after the call | 5: SyncLagCloseDecidedLog 2, SyncLag 3. Same |
| `registrationAfterKeeperRead` | after `keeper.entrySession`, before the resolve | `.readEntrySession`'s result | `perform`, after the read | RegisterSession 7. Same |
| `registrationGeneration` | before `transport.registerSession` | `.registerWithTransport` | `perform`, before the call | RegisterSession 2. Same |

### 3.2 The neighbours' holds and the harness's hooks

**The neighbours' holds.** The router's 14, the manager's 6 and the keeper's 15 stay unchanged. The harness rows keep their order:
- router: `beforeAdmit`, `afterAdmit`, `sendingJoinResponse`, `sendingInitialSync`, `stopLeave`, `disconnectForwarded`;
- keeper: `.join`, `.leave`, `syncOnlyAfterLegacyCycle`.

The entry methods keep their signatures, so `flipWaitResumed` (LR:1378) and `afterAdmit` (LR:1099) still sit where the adapter call returns.

| Hook | On the branch |
|---|---|
| router, keeper and NIO hooks | unchanged |
| `waitForBackgroundSyncsForTesting` | the barrier (§6), scoped to `.syncCycle` work |
| `syncNow` | returns where it does today, after `endSync`: legacy at the `.endSync` completion step, in-turn when the keeper's sync turn has returned |
| the named observations (`joinFlipped`, `initialSyncCommitted`, `admittedNotRegistered`, `pendingActionCount`, `staleJoinAttemptsRefused`, `teardownTicketEnds`, `syncDeferredByCycleCount`, `captureJoinCommits`) | `core.read` of machine fields |
| `sessionTicketForTesting`, `ticketIsCurrentForTesting` | the machine's own current-binding field, because `read` borrows the machine only and can't see which keys are live (`TurnCore.swift:186`) |
| writer and transport state | read from `outboundWriter` and the transport directly |

**The harness's five holds.**
- `keeperJoinReturned` and `joinSyncRequested` sit in `perform`;
- `admitJoinEntry` sits at the entry;
- `disconnectForwarded` (router) and `syncOnlyAfterLegacyCycle` (keeper) don't move.

## 4. The order of the rewrite inside the branch

The branch is `rewrite/546-adapter-turn-core`. It merges `main` and never rebases. Each step is a group of commits Review takes one at a time, and ends at a named SHA recorded in a branch comment.

**Each step's gate, run at that SHA (CI parity):**
- the harness: every golden cell compared, green or listed;
- `swift test` with in-turn sync on and off, and with `USE_SYNC_TABLES=false`;
- the wall-clock cadence suite as CI runs it (`WALL_CLOCK_TESTS=1`, `WallClockCadenceSmokeTests`, no parallel);
- E2E in six cells: `json`, `opcodeJsonArray`, `messagepack`, each with `IN_TURN_SYNC` on and off;
- the wall-clock baseline lowered for the files the step touched (§6);
- `scripts/pre-push-checks.sh origin/main`.

**Order: sync first, then everything that shares the membership slot, together.** The commit's state is read by the join, the initial sync and the freeze, so it moves first. The membership queue and the session tickets are used by the join, inbound and the initial sync, so all four move in one step. Each step leaves one writer for every piece of state.

**Bridges are synchronous.** A bridge is either:
- an output the machine emits (`turn.emit`), which the actor applies to its own fields right after the step, before the next input; or
- a `core.query` or `core.read` called from actor code outside a step.

No bridge awaits.

| Step | Moves to the machine | Still on the actor | Bridges | Deletes |
|---|---|---|---|---|
| B0 | nothing; carries out D4 (the representation of the other modules' types, `DebugFreezeState`, `ExpectedAdmission`); `MembershipCoordinator` becomes a value type | all | none | the class |
| B1 | an empty machine, `TurnCore`, the production `TurnClock` over `safeTaskSleep` | all | none | nothing |
| B2 | sync, lag and the freeze settle (§2.4): `planAndCommit`, the legacy cycle as requests, the retry, follow-ups, the lag timer, the settle's commit and its gating of cycles | membership, join, inbound, actions, failure, the freeze's control | the commit reads membership through a snapshot the actor passes in (`.syncPhase` and `.cycleRead` carry it). The flips it decides are emitted as `.flipped(joins)` outputs, which the actor applies to its join state. The legacy initial sync reads the commit epoch with `core.read` | `backgroundSyncTasks`, the lag timer task, the epoch fields on the actor |
| B3 | membership, join, inbound and the initial sync together (§2.1–2.3): the chain, the epochs, both teardowns' session part, the D2 stamp, generation-aware output (#240), `WithdrawToken`, `JoinAdmission.refused`, the keeper's recheck (§7); B2's membership snapshot and flip bridges removed | actions, failure, the freeze's control | actions validate their session through `core.read` of the current-binding field | `membershipQueueTail`, the session tickets, `registrationTicketHolders`, the join waiters, the inbound drains |
| B4 | actions (§2.2) | failure, the freeze's control | none | the action tickets and tasks; B3's action bridge |
| B5 | land failure, the terminal teardown, the freeze's control and auto-resume | nothing | none | the freeze tasks |
| B6 | nothing new | | | what's left: the `…Queued` wrappers, unused helpers, the adapter's last `GenerationTable` / `SingleFlight` / `Lifecycle` use |

The public changes land in B3, where they are needed. They break source compatibility; there are no external users, so they need no deprecation.

**Stop conditions** (from #546):
- a step needs a coordinator-shaped API: stop and redo the outline;
- the deleted scaffolding is as large as the added machine: revisit;
- a step's host A/B regresses beyond the gate: stop and find the cause.

## 5. Retired rows and replacement invariants

**Harness rows: none planned.** `RetiredRows.swift` stays empty unless a step finds otherwise. Any entry goes through Review, and Main approves it with its witness's failing output.

**Unit-test holds that retire:**

| Hold | Users | Replacement invariant | Witness |
|---|---|---|---|
| `debugFreezeAutoResumeStale` | 1 test, 2 references (DebugFreeze) | The test gates the old wake (doesn't resume its sleeper) and re-arms the freeze. It then resumes the old sleeper: the core reports `.staleTimer`, and nothing thaws. Then it resumes the new sleeper and waits for `autoResumesApplied`, which is written after the keeper has resumed, so both actors are seen to thaw. Core checks 26 and 29 | a mutant that arms each auto-resume on a fresh key without ending the old one |

Main approves this after the plan is GO.

## 6. The 485 adapter-side wall-clock polls (#458)

#458's split (issuecomment-7007487698) leaves 485 polls in 58 files to this rewrite; most are `waitForOutboundDrain` helper polls.

**The causal barrier, `waitForQuiescenceForTesting()`.**
- It counts work from its launch through its completion step and the writer's flush, abandoned workers included. Work means each `send`, `request` and `run`.
- An armed timer isn't work in flight. A timer counts from its wake to the end of its step. So a lag timer that re-arms itself doesn't keep the barrier from reaching zero.
- It returns when the count is zero, rechecking after the writer has handed off to the transport.
- A test that asserts a delivered frame waits for the test transport to receive it (`Notes/solutions/2026-11-10-a-returned-send-is-not-a-delivered-frame.md`).

**`membershipInputsWaiting`** counts inputs that are parked behind `.membership`:
- an input that steps as soon as it is sent never counts;
- the count goes down when a parked input steps, is withdrawn (from the core's `stats.droppedSends`, read together with the observation), or the entry method's `send` returns `queueFull`.

**How the rewritten tests wait:**
- for "the adapter has processed X": on the barrier, or on `sendAndWait`;
- for timers: on the stepped clock, plus the timer step's apply milestone;
- for a race: on a hold (§3).

Each step converts the files it touches and lowers `scripts/wall-clock-baseline.txt` in the same commit. Each converted pattern gets one mutant run, which shows the new wait still fails when the awaited work is removed.

## 7. #652, #548, #588 in the new model

### #652: a reused SessionID

**Proposed (D2): allow reuse,** with the stamp of §2.1 in all three places and generation-aware output, both in B3.
- The router clears the ended entry when a new connection binds the SessionID, and `endedSessions` goes away.
- The stale-reply row moves to a reused SessionID on `main` first, its cells are re-recorded, and the race mutant must fail it.
- The alternative is to forbid reuse with its own error code.

### #548: a teardown during the keeper's join

The golden row's teardown is the recoverable one, so on the branch it is `.teardownSessions`.

**The keeper's recheck (in-turn).** Today the only refusal sits before the keeper's `.join` hold, and only when the transport admits inside the join (`admitThroughTransport`, `LandKeeper.swift:1734`). After the hold there is no recheck: the keeper inserts the player (:1787) and, on the handler path, queues OnJoin. The branch adds one keeper change in B3. After the hold, under the same `admitThroughTransport` condition, the keeper asks `refusesResolvedJoin` again, before it inserts the player. The adapter's answer refuses the ended attempt, so the keeper changes nothing: no OnJoin, and no compensation needed.

**The compensation (legacy, and any late admission).** On the legacy path (`admitThroughTransport: false`, :1666) the keeper doesn't ask the adapter. It inserts the player and runs OnJoin, and the adapter learns about it only from the result. That result is late, because the attempt's key has ended. Its `handleLateResult` step files `.keeperLeave` under `.land`, holding `.membership`.

The leave targets the ended attempt's session and client: `keeper.leave(playerID:clientID:sessionID:)` (`LandKeeper.swift:2451`). `JoinOutcome` (:1671) carries no join sequence, and no keeper field is added. A2's admission can't match that leave: it has its own SessionID (`s-a2`) and client, and it steps only after the leave's chain ends.

The same compensation covers an in-turn admission that completed before the teardown and whose result arrives after it.

**What the oracle sees in the #548 row.**
- In both modes: A's join is refused; A has no current binding, `teardownTicketEnds == 1`, and no initial sync.
- `pa`'s lifecycle:
  - **in-turn:** `[join, leave]`, from A2 alone, against the golden's `[join, leave, join, leave]`. The recheck stops A's OnJoin;
  - **legacy:** `[join, leave, join, leave]`, as the golden. A's OnJoin ran, and the compensating leave runs its OnLeave.

The branch lists one expected difference per cell (harness plan rev 10, "The #548 row"). If the expected-difference entry can't express the in-turn cells' lifecycle change, its shape is extended on `main` before the recording, because the file is protected.

### #588: `CanJoin` and `OnJoin` in different turns

This is the keeper's change (#593). It moves `CanJoin` from the resolve milestone into the apply turn, together with:
- the stale-join refusal;
- `maxPlayers`;
- the duplicate-login kick;
- the draining guard.

The `.keeperJoin` result keeps one shape, so the machine doesn't change.

**Proposed (D3):** land #588 before the recording, or after the rewrite merges. During the freeze it lands only with its goldens re-recorded in the same PR on `main`.

## 8. The performance A/B

The host runs the A/B at the end of B2 (the sync path) and again before the merge, on the instruction gate (#517).

**Builds:**
- base is `main` at run time; head is the branch merged with that `main`;
- release builds, both sides in one container from the pinned image, with `swift --version` and the image digest recorded;
- ABBA order, one warm-up pair discarded, then 5 pairs, with `SWIFT_DETERMINISTIC_HASHING=1`.

**Cells:**
- #554's five EncodingBenchmark cells (`rows-mp`, `rows-json`, `router-mp`, `rows-mp-100`, `json-control`), with `ENCODING_BENCHMARK_PERF_WINDOW=iteration`;
- plus `nonsync`.

**Judgement:**
- the measure is mean `instructions:u` per cell. A cell regresses if it is above base by more than max(0.5 %, 3 × base's spread). Time is reported, not judged;
- the per-message budget is about +100 instructions for the one `core.read`;
- ServerLoadTest's zero-disconnect bar is reported for both sides;
- encoded bytes and the patch and event counts per cell must equal base's.

## 9. Public API

**Changed, in B3:**
- `registerSession` takes a required `WithdrawToken`, which replaces `JoinAttemptEnd`; a host passes a fresh token;
- the `Transport` defaults that ignore the connection generation are removed (#240);
- `JoinAdmission` gets a `refused` case, and `isAdmitted` becomes a `switch`;
- the stop snapshot and `registerSession` carry the binding (the D2 stamp), if they are public.

**Added, package only:**
- `waitForQuiescenceForTesting`;
- `membershipInputsWaiting`;
- `autoResumesApplied`;
- the test clock's one-at-a-time resume.

## 10. Decisions for the maintainer

- **D1.** Keep both sync modes on the branch (proposed), or remove the legacy path on `main` first (#550) and re-record. Keeping both lets every golden cell compare, and keeps the production rollback switch (`IN_TURN_SYNC=false`) working through the rewrite.
- **D2.** #652: allow a reused SessionID (proposed, with the stamp and generation-aware output in B3), or forbid it (§7).
- **D3.** #588: before the recording or after the merge (proposed).
- **D4 (open; B0 waits for it). Module layering.**

  **The problem:**
  - `@PlainData` lives in `SwiftStateTurns`, which `SwiftStateTreeTransport` doesn't depend on (`Package.swift:85–95`);
  - the fields the machine would store are other modules' types:
    - `SessionID`, `PlayerID` and `ClientID` (SwiftStateTree);
    - `StateSnapshot` and `SnapshotValue` (inside `SyncEngine`);
    - `MessagePackValue` (inside `PendingEventManager`);
    - the land's generic `State` (in `DebugFreezeState<State>`);
    - a join response (in `ExpectedAdmission`);
  - the lint refuses a hand-written conformance, and `@PlainData` can't be attached to another module's type.

  **The options:**
  - **(a)** `SwiftStateTree` and the MessagePack target depend on `SwiftStateTurns` and annotate their types. Transport then depends on Turns too. This gives one representation and the full compile-time check, but it puts the turn core under the core DSL module.
  - **(b)** The machine stores adapter-side mirror types (IDs as wrapped strings, snapshots as their encoded bytes), converted at the boundary. The layering is unchanged, but each read and write pays a conversion, and that cost is on the sync path, measured by the A/B.
  - **(c)** These fields stay outside the machine as `let` tools, like `perPlayerTables`, under the "mutated only in turns" guard (§1). The machine holds only the adapter's own value types. The layering and the hot path are unchanged, but less of the state is checked at compile time.

  I don't propose one; the choice is the maintainer's. Whichever is chosen, B0 carries it out, and §2.2's "representation per D4" entries follow it.

## 11. Risks

- **The per-message `core.read`.** If it costs more than the budget on 6.2.4 (#621), the sync path regresses. The guards are `check-turns-inlinable.sh` and the A/B at the end of B2.
- **State outside the machine.** `perPlayerTables`, and under D4 (c) more fields, are mutated only from steps and answers. A later change that calls a writer from `perform` breaks the rule. The guard is the debug assertion `core.borrowStateForTesting < 0` at each writer (§1).
- **The land-wide `.membership` chain** serialises membership exactly as today. Per-player domains are out of scope.
- **A hold whose boundary has no equivalent.** If a step finds a row whose order can't be forced at the mapped seam, the row is retired only after Review and Main approve it.
- **The branch's size.** One merge for the whole rewrite; each step's gate at its SHA is the guard.

## 12. Rev 3: where each review point went

| Point | Section |
|---|---|
| MF1: the chain, the handover, abandon, refusal, `queueFull`, what bypasses `.membership` | §2.1 |
| MF2: `JoinOutcome` has no sequence (target by session and client), the keeper's recheck, the oracle per mode | §7 |
| MF3: the allowed synchronous calls in `planAndCommit`, rule 1, the legacy flag | §2.4 |
| MF4: the reorder (sync first, the membership-slot users together), the bridges | §4 |
| MF4: module layering | D4 (§10) |
| Should: teardown withdrawal and host tokens | §2.1, scopes |
| Should: the stamp at stop, shutdown and `registerSession` | §2.1 |
| Should: the inbound milestones | §2.3 |
| Should: causal observations, the barrier under the lag timer | §6 |
| Should: the freeze witness | §5 |
| Should: `syncNow`'s boundary | §3.2 |
| Should: the cadence suite in the gate | §4 |
| Nit: `waitsFor:` takes one key; the timer API; the probe | §2.1, §1 |
