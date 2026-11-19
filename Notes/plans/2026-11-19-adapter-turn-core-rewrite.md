# TransportAdapter on the turn core: the rewrite (#546)

**Status:** rev 1, plan only, for review. **Issue:** #546. **Inputs:** the turn core (#551, merged as #608; `Notes/plans/2026-11-18-swift-state-turns-core.md`), the differential harness (#555; `Notes/plans/2026-11-19-adapter-differential-harness.md`, rev 10), the stateless extraction (#554; `Notes/plans/2026-11-18-adapter-stateless-extraction.md`). **Base:** `main` at 25dbdbe8 with #555 step 2b. Line numbers are `Sources/SwiftStateTreeTransport/TransportAdapter.swift` ("TA") there unless a file is named. They are pointers into today's code, not part of the design.

## 1. Goal and rule

`TransportAdapter` becomes one `TurnActor`. Its machine holds every piece of adapter state. Every change to that state is made in a synchronous step. Work that waits (the keeper, the transport, timers) leaves the step as an effect, and its result comes back as an input. The core decides whether a result is still wanted, by the key the request was filed under and that key's generation. Handlers hold no tickets (core rule 4).

The rewrite happens on one branch and merges once (the maintainer's decision of 2026-11-19, harness plan rev 10). The branch is compared with the goldens that `main` recorded. Any difference fails the comparison, unless the branch lists it as an expected difference (`ExpectedDifferences.swift`) or retires the row (`RetiredRows.swift`, with a replacement test).

**What stays outside the machine,** as `let` `Sendable` tools that `perform` uses (#546's settled design):
- the encoders (`EncodingPipeline`, `SyncPlanning`, `SyncStreamCanonical`, after #554);
- the transport (`WebSocketTransport`);
- the recorder;
- `outboundWriter` and `outputGate`.

The router, the manager, the keeper and NIO aren't rewritten. Their hold points stay where they are, so on both sides they are the same seam (the harness's kind (a)).

## 2. The machine: state, inputs, effects, keys

**Keys.**
- `.session(SessionID, binding)`: one generation per connection binding. A supersede (`start` over a live key) closes the old binding's requests and withdraws its queued inputs (core rule 4). Using a fresh key per binding avoids the core's known limit, where an input for a key that isn't live steps under the next generation.
- `.joinAttempt(SessionID, attempt)`: one per router join attempt, ended by the router's end token (`WithdrawToken`) or by the session's end.
- `.syncCycle`: the one sync cycle in flight.
- `.lagTimer`: the sync-lag timer.
- `.freeze`: debug freeze. It is a test feature only and isn't mentioned outside the tests.
- `.land`: the whole land, ended by `endAll` at teardown.

A ticket today becomes a key's generation. The tables below say, for each piece of state, which input changes it and which key its async results are checked under.

### 2.1 Membership and sessions

| State today | Changed by (input) | Async result | Checked under |
|---|---|---|---|
| `MembershipCoordinator` maps, slots, membership versions; `connectionGenerations`, `endedSessions`, `supersededSessionCount` | `registerSession` (entry), `disconnect` (entry), `supersede` (from a register over a live player) | `transport.registerSession` returns → `.registered` | `.session` |
| `sessionTickets` (`GenerationTable`), `registrationTicketHolders` | gone: the core's generation of `.session` | | |
| leave's tail (`releasePlayerSlot`, `syncEngine` removal, per-player tables, initial-sync entry): today after `await keeper.leave`, TA:1313–1342, guarded only by re-reading `sessionIDs(for:)` | `.leaveApplied` (the keeper's `leave` result) | `keeper.leave` → `.leaveApplied` | `.land` (the leave of an ended session still applies its tail; the session's key has ended by then) |
| `membershipQueueTail` (the serial queue, TA:3013) | gone: inputs for one session are queued by the core behind that session's held key (`Hold.untilRequestCloses(.session, deadline:)`), FIFO (core rule 7) | | |

### 2.2 The join pipeline and its resolvers

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `memberJoinAttempts`, `staleJoinAttemptsRefused`, `expectedAdmissions` | `admitJoin` (the router's call, `sendAndWait`) | `keeper.joinReportingAdmission` → `.keeperJoinReturned(result)` | `.joinAttempt`, holding `.session` until the request closes |
| `joiningSessions`, `joinWaiters`, `nextInTurnJoinOrder` | `.keeperJoinReturned`, `.joinSyncCommitted`, `disconnect` | `keeper.requestJoinSyncTurn` → `.joinSyncRequested` | `.joinAttempt` |
| the keeper's in-turn admission callback (`admitJoiningSessionIsolated`, TA:1925) | stays a synchronous call from the keeper's turn into the machine: a `query` (core rule 13), not an input | | |
| `initialSyncingPlayers`, the initial sync's drop counters | `syncStateForNewPlayer` (legacy path, the router's call) | `keeper.currentStateLocated` → `.initialSyncRead(state, position)` | `.joinAttempt`, plus the commit epoch (`syncPhaseCommits`) carried in the input |
| `inboundAfterFlip`, `inboundClosedSessions`, the inbound counters | `message` (entry) for a joining session | | gone as a drain: a frame for a joining session is queued behind the session's key and released by the core after the flip (core rules 7 and 9) |
| `heldEventOverflows`, the held-event counters | the sync commit input | | `.session` |

**The validate/apply shape (#588, #593)** is the keeper's. The adapter's join request (`.keeperJoin`) keeps one request and one result, so #588 can change what happens inside the keeper without changing the machine (§7).

### 2.3 Action responses

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `actionResponseTasks`, `actionResponseTickets` | `action` (entry) | `keeper.awaitActionResult` → `.actionAnswered(sequence, outcome)` | `.session`: an answer after the session's binding ended goes to `handleLateResult` and is dropped and counted |
| `actionResponsesFinished`, its waiters | the answer input | | tests' observation (§5) |

### 2.4 Sync scheduling and the cycle

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `syncSkips`, `backlogDeferred…`, `backlogRetryScheduled`, `backgroundSyncTasks` | `syncRequested` (entry: the sync loop, `syncNow`, a join's flip); the retry becomes `.retrySync`, queued behind `.syncCycle` (core rule 9), not a background task with a 1 ms sleep | | `.syncCycle` |
| the legacy cycle (in-turn off): `beginSync` / plan / encode / `endSync` | `syncRequested` → a request `.legacyCycle` holding `.syncCycle` | `keeper.beginSync` → `.cycleRead(state, read)`; `keeper.endSync` → `.cycleEnded` | `.syncCycle` |
| the in-turn phase (`runSyncPhaseInTurn*`) | stays a synchronous call from the keeper's turn: a `query` | | |
| `lastSyncSeq`, `planSyncSeq`, `syncEngine`, `pendingEventManager`, `carriedDirtyFields`, the sync-stream sets | the commit input (one per committed phase, #546: "a sync commit is one input") | | |
| `startDelayedFollowUpSync` (failed plan, 100 ms) | a timer input, `.followUpSync` (`turn.timer(at:for: .syncCycle)`) | | |

**Both sync modes stay on the branch.** Half the goldens' cells are legacy (`IN_TURN_SYNC=false`), and removing the legacy path is its own change (layer 3 PR B, #550), with its own re-recording. The branch keeps both, so every golden cell compares. That is decision D1 (§10).

### 2.5 Sync lag

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `syncLag`, `syncLagFullPlanRequested` | `ack` (entry), the commit input | | `.session` |
| `syncLagTimer`, `syncLagTimerEpoch`, `syncLagTimerSyncRequested` | a timer input, `.lagTick` (`turn.timer(at:for: .lagTimer)`), with skip-ahead (core rule 18) | | `.lagTimer`; the epoch is gone |
| the lag close | an effect `.closeSession(code)` | `transport.closeSession` → `.closed` | `.session` |

### 2.6 Closes, teardown, land failure, debug freeze

| State today | Changed by | Async result | Checked under |
|---|---|---|---|
| `teardownTicketEnds`, `endSessionTicketsForTeardown` | `teardown` (control input) → `endAll` (core rule 15) | | |
| `closeSessionsForLandFailure`, `outboundCeilingDisconnects` | `landFailed` (control) → `close`, then effects `.closeSession(4016)` per session | | `.land` |
| `debugFreezeState` | `debugFreeze` / `debugRelease` (control); the settle and the auto-resume become a request and a timer under `.freeze` | `.settled` | `.freeze` |

**Counters and test hooks** (§2.2–2.6's counters, the `…FaultForTesting` hooks) move into the machine as plain fields, or stay `let` closures on the actor where they are faults read in `perform`. A counter read by a test is a `core.read`, between steps.

## 3. Hold points: what each becomes

Every interleaving a hold forces today is one of three things on the branch:
- **a request whose result comes back as an input:** the hold sits in `perform`, either before the neighbour's call ("request leaves") or after it returns, before its result input is sent ("result arrived, not yet applied");
- **a timer input:** the test drives it with a stepped `TurnClock`, not a hold;
- **gone:** the interleaving can't happen, because it fell between two synchronous steps or inside one. The test is replaced by an invariant test.

**The seams on the branch need no turn-core API.** `perform` is the adapter's own code, outside any step, so `await holds.at(.x)` there is legal and sits at the same semantic boundary as today. The entry holds (b) sit in the adapter's entry methods, before `send`/`sendAndWait`. The core's `onDiagnostic` (package) gives the observation "queued behind a key" (`TurnDiagnostic.queued`). So `SwiftStateTurns` stays free of any dependency on `HoldPoints`.

### 3.1 `TransportAdapterHoldPoint` (17)

| Hold | (a) What it forces today | (b) Becomes | (c) Seam on the branch | (d) Users, and how each keeps its order |
|---|---|---|---|---|
| `keeperJoinReturned` | after `await keeper.joinReportingAdmission` (TA:2202), before the registration; the code after it mutates | the `.keeperJoin` request's result | `perform`, after the keeper returns, before `.keeperJoinReturned` is sent | harness: disconnect-at-registration, join-during-sync-cycle-inturn, and the harness-wide join order (DiffRunner:215); JoinFlip 4, JoinHeldEvents 2, RouterJoinTimeout 1. The same name, at the same point: the keeper has admitted, and the adapter hasn't applied it |
| `joinSyncRequested` | before `await keeper.requestJoinSyncTurn()` (TA:2263) | the `.requestJoinSync` request | `perform`, before the call | harness: disconnect-at-registration; JoinFlip 1. Same |
| `admitJoinEntry` | entry of `admitJoin`, before the membership queue | the `admitJoin` entry | the entry method, before `sendAndWait` | harness: disconnect-before-keeper-admission, join-during-sync-cycle; RouterJoinAttempt 5, RouterJoinTimeout 4. Same |
| `membershipQueued` | in the queue's task, before it awaits the previous operation (TA:3018) | gone as a hold: the core queues a session's input behind its held key | an observation: `disconnectQueuedBehind(session)` from `TurnDiagnostic.queued` for that key | harness: disconnect-during-keeper-join, disconnect-at-registration, land-stop. Their use is an arrival count, which reads the observation instead. DisconnectOwnership 1 and RegisterSession 2 hold it: their order is that a disconnect waits behind a held register, which the replacement asserts by the core's queue, with a register held at `registrationGeneration` (below) |
| `cycleBeforeEndSync` | before `await keeper.endSync()` (TA:3289, and `debugSettle` TA:6533) | the `.endSync` request of the legacy cycle | `perform`, before the call | harness: join-during-sync-cycle and its in-turn variant; InTurnSync 2, TransportTestHelpers 1. Same |
| `actionResponse` | start of `finishActionResponse`, before the ticket check | the `.awaitActionResult` result | `perform`, after the keeper's answer, before `.actionAnswered` is sent | harness: stale-action-reply; ActionJob 1. Same: the answer has arrived and isn't applied. The ticket check becomes the core's, so the race mutant becomes "the core routes a late result to `handle`". The core's own checks (rule 5, invariant 5) kill it, and on the branch the row with a reused SessionID kills it too (§7, #652) |
| `initialSync` | before the initial sync's state read (TA:5545) | the `.readForInitialSync` request | `perform`, before the read | JoiningAdmission 4, NewestWins 1. Same |
| `initialSyncAfterRead` | after the read, before the ticket check and commit (TA:5557) | its result | `perform`, after the read, before `.initialSyncRead` is sent | InitialSyncBehindCommit 1, TicklessPassOrdinal 1, InitialSyncStaleRead 1. Same; the commit-epoch check becomes the handler's comparison of the carried epoch |
| `inboundDrainDispatch` | after a deferred frame is popped, before its ticket check and dispatch (TA:2393) | gone: the core releases queued inputs one step at a time, and an ended key withdraws them first (core rules 7, 8) | none | JoinPendingInbound 4. **Retires.** Replacement invariant: "a frame queued behind a joining session never steps after that session's disconnect, and the frames that do step keep arrival order", tested on the machine with the core's generated orders (§6.4 of the core plan). Witness: a mutant that doesn't scope queued frames to the session key |
| `failedPlanFollowUp` | in the follow-up task, after the 100 ms sleep, before `syncNow` | a timer input `.followUpSync` | none; a stepped `TurnClock` | InitialSyncBehindCommit 1, PerPlayerSyncTablesScenario 1, SyncOutputVerifier 1. The test advances the clock to the timer's instant |
| `debugFreezeAutoResumeFired` | start of the auto-resume, before its generation check | a timer input under `.freeze` | none; a stepped clock | DebugFreeze 2. The clock fires it |
| `debugFreezeAutoResumeStale` | the stale branch of the auto-resume | gone: a replaced timer never fires (core rule 18) | none | DebugFreeze 2. **Retires.** Replacement: "a released freeze's auto-resume never fires", asserted with the stepped clock past the old instant. Witness: the core's timer generation check (core check 27) |
| `syncLagTimerSync` | in the lag timer's sync, before `syncNow` (TA:3564) | the timer input `.lagTick`, which files a sync request | none; a stepped clock | SyncLag 1. The clock fires it |
| `syncLagClose` | in the close task, before `await transport.closeSession` | the `.closeSession` request | `perform`, before the call | SyncLagCloseDecidedLog 3, SyncLag 2. Same |
| `syncLagClosed` | after `closeSession` returned | its result | `perform`, after the call | SyncLagCloseDecidedLog 1, SyncLag 2. Same |
| `registrationAfterKeeperRead` | after `await keeper.entrySession(for:)`, before the ticket resolve (TA:1461) | the `.readEntrySession` result | `perform`, after the read | RegisterSession 7. Same |
| `registrationGeneration` | before `await webSocketTransport.registerSession` (TA:1557) | the `.registerWithTransport` request | `perform`, before the call | RegisterSession 2. Same |

### 3.2 The neighbours' holds

The router's 14, the manager's 6 and the keeper's 15 stay where they are, unchanged. The harness rows that use them are kind (a), and they keep their order on the branch without any work:
- router: `beforeAdmit`, `afterAdmit`, `sendingJoinResponse`, `sendingInitialSync`, `stopLeave`;
- keeper: `.join`, `.leave`, `syncOnlyAfterLegacyCycle`.

Two of the router's holds sit right after an adapter call returns:
- `flipWaitResumed` (LR:1378), after `adapter.awaitJoined`;
- `afterAdmit` (LR:1099), after `admitJoin`.

Their position is the same on the branch, because the adapter's entry methods keep their signatures (`sendAndWait` returns where the method returns today).

### 3.3 The harness's ordering hooks on the branch

| Hook | On the branch |
|---|---|
| `waitForDisconnectForwardsForTesting`, `waitForNoPendingFlipForTesting`, `setJoinTimeoutForTesting` (router) | unchanged |
| `waitForInputDrainIdleForTesting`, `stepTickOnce`, `syncOnlyTurnAfterLegacyCycleForTesting`, `waitForActionJobsForTesting`, `waitForRecorderSubmissionsForTesting` (keeper) | unchanged |
| `onAfterSessionsClosedForTesting` (NIO server) | unchanged |
| `waitForBackgroundSyncsForTesting` | the same name: returns when the core has no open request or queued input under `.syncCycle` and no `perform` task of the sync kind is running. Its meaning is the same ("a skipped cycle's retry has run") |
| `syncNow` | sends `syncRequested` and waits for that cycle's commit or skip (`sendAndWait`) |
| `captureJoinCommitsForTesting`, `joinFlippedForTesting`, `initialSyncCommittedForTesting`, `admittedNotRegisteredForTesting`, `sessionTicketForTesting`, `ticketIsCurrentForTesting`, `pendingActionCountForTesting`, `staleJoinAttemptsRefused`, `teardownTicketEnds`, `syncDeferredByCycleCountForTesting` | package reads from the machine (`core.read`), with the same meaning. `sessionTicket` becomes the session key's generation, and `ticketIsCurrent` asks whether that generation is live |
| `waitForOutboundIdleForTesting`, `waitForSyncQuiescenceForTesting`, `waitForInboundDrainForTesting`, `waitForActionResponsesFinishedForTesting`, `setJoinFlipLimitsForTesting` | the same names. `waitForInboundDrainForTesting` becomes "no input queued behind the session's key" |

**The holds the harness's scenarios need** (`keeperJoinReturned`, `joinSyncRequested`, `admitJoinEntry`, `disconnectForwarded`, `syncOnlyAfterLegacyCycle`):
- `keeperJoinReturned` and `joinSyncRequested` sit in `perform` (§3.1).
- `admitJoinEntry` sits in the entry method.
- `disconnectForwarded` (router) and `syncOnlyAfterLegacyCycle` (keeper) aren't the adapter's, so they don't move.

The `membershipQueued` arrival count the rows read becomes the `disconnectQueuedBehind` observation, which has the same meaning.

## 4. The order of the rewrite inside the branch

The branch is `rewrite/546-adapter-turn-core` (the path check's head prefix). It merges `main` to stay current and never rebases. Each step below is a group of commits Review takes one at a time. **Each step's gate:**
- the harness compares every cell with its golden, green or covered by a listed entry;
- `swift test` passes in both sync modes and with `USE_SYNC_TABLES=false`;
- E2E passes in the three encodings;
- the wall-clock baseline for that step's files is lowered (§6);
- the step's legacy code is deleted before the next step starts (#546).

| Step | Moves into the machine | Notes |
|---|---|---|
| B0 | an empty machine and `TurnCore` in the adapter; the `SwiftStateTurns` dependency; the production `TurnClock` over `safeTaskSleep` (core plan §3.4) | the goldens must still pass unchanged: no behaviour |
| B1 | membership: register, supersede, disconnect and leave, the session keys, the end of the membership queue (§2.1) | #652 decided here (§7) |
| B2 | the join pipeline: admission, the keeper join, registration, the flip, held events, inbound deferral, the initial sync (§2.2) | the #548 entry lands here (§7); `inboundDrainDispatch` retires |
| B3 | action responses (§2.3) | the race witness moves to the core and the reused-SessionID row |
| B4 | sync scheduling, the legacy cycle as requests, the retry and follow-up as queued input and timer, sync lag (§2.4, §2.5) | the heaviest step for performance; the host A/B runs at its end too (§8) |
| B5 | teardown, land failure, closes, debug freeze (§2.6) | `debugFreezeAutoResumeStale` retires |
| B6 | the deletion of what's left: `GenerationTable` and the queue in the adapter, the `…Queued` wrappers; the public changes of slice 1 (#546): `JoinAdmission.refused`, a required `WithdrawToken` on `registerSession`, the `Transport` defaults that ignore the connection generation removed (#240) | the public changes are breaking. There are no external users, so they need no deprecation |

**Stop conditions** (from #546):
- a step needs a coordinator-shaped API: stop and redo the outline;
- the deleted scaffolding is as large as the added machine: revisit;
- a step's host A/B regresses beyond the gate: stop and find the cause before the next step.

## 5. Retired rows and replacement invariants

**Harness rows: none planned.** Every row's holds are kept at the same semantic boundary (§3). `RetiredRows.swift` stays empty unless a step finds otherwise. Any entry then goes through Review, and Main approves it with its witness's failing output, as the harness plan requires.

**Unit-test holds that retire** (they aren't harness rows; each replacement is a machine or core test, with a source mutant it must kill):

| Hold | Tests | Replacement invariant | Witness |
|---|---|---|---|
| `inboundDrainDispatch` | JoinPendingInboundTests (4 uses) | queued frames of a joining session never step after its disconnect, and keep arrival order (generated orders over the machine) | a mutant that queues frames with no scope |
| `debugFreezeAutoResumeStale` | TransportAdapterDebugFreezeTests (2) | a released freeze's auto-resume never fires (stepped clock) | a mutant that arms the auto-resume under a fresh key per freeze without ending the old one |
| `membershipQueued` as a hold | DisconnectOwnership (1), RegisterSession (2) | a disconnect waits behind a held register and applies after it, in arrival order | a mutant whose disconnect input doesn't wait for the session's key |

Main approves each after Review (rev 10's rule).

## 6. The 485 adapter-side wall-clock polls (#458)

#458's split (issuecomment-7007487698) leaves 485 polls in 58 files, the files that mention `TransportAdapter`, `LandRouter`, `MembershipCoordinator` or `WebSocketTransport`, to this rewrite. Most are `waitForOutboundDrain` helper polls (187 were added by it alone).

How the rewritten tests wait:
- **On a turn, not a time.** A test that waited for "the adapter has processed X" sends X with `sendAndWait`, or waits on the observation that X's step produced (`waitForTurnIdleForTesting()`: no open request, no queued input, no running `perform` task, and the outbound writer idle). This replaces `waitForOutboundDrain` and the yield loops.
- **On a stepped clock for timers.** The lag timer, the follow-up sync, the join waiter's timeout and the freeze's auto-resume run on the injected `TurnClock`. A test steps it to the instant and waits for the timer's step.
- **On a hold for a race.** As today (`HoldPoints`), at the seams of §3.

Each step converts the files it touches and lowers `scripts/wall-clock-baseline.txt` in the same commit, so the baseline only goes down. A file outside the adapter's steps isn't touched. Each converted pattern gets one mutant run, which shows the new wait still fails when the awaited work is removed. At B6, every adapter-side entry is gone from the baseline, or listed with its reason (a test of the clock itself).

## 7. #652, #548, #588 in the new model

- **#652 (a SessionID reused after a disconnect is refused as stale).** In the machine, a session key is per binding, and a new binding on the same SessionID is a `start` that supersedes nothing, because the old binding's key ended at the disconnect. So reuse is safe by construction: the old binding's late results go to `handleLateResult`. **Proposed (D2): allow reuse.** The router clears the ended entry when a new connection binds the SessionID, and the adapter's `endedSessions` set goes away. Then the stale-reply row moves to a reused SessionID (A2 on `s-a`) on `main` first, since rows change on `main`. Its cells are re-recorded, and the race mutant must fail it (the note on #652). Production is unaffected: NIO mints a fresh SessionID per connection. The alternative is to forbid reuse explicitly with its own error code; the row then stays on a fresh SessionID, and the race witness is the core's alone.
- **#548 (a teardown during the keeper's join re-creates the session's membership).** Fixed by construction in B2: the teardown is `endAll`, so the keeper's join result arrives for a key that isn't live and goes to `handleLateResult`. There the machine compensates: the keeper admitted a player whose session is gone, so it files the keeper's `leave` under `.land`. The golden records the bug (on `main`, A has a current ticket after the teardown), so the branch lists one expected difference on the teardown-during-keeper-join row (harness plan rev 10, "The #548 row"). It names what the branch does: no current ticket for A, `teardownTicketEnds == 1`, no initial sync for A.
- **#588 (`CanJoin` and `OnJoin` run in different turns).** This is the keeper's change (validate and apply in one turn, #593), not the adapter's. The machine's `.keeperJoin` request keeps one result, a refusal or an admission, so #588 doesn't change the machine. Order: #588 lands on `main` after the rewrite merges, or before the freeze. A #588 that lands during the freeze changes goldens, so it re-records on `main` and reaches the branch by merging `main` (the harness plan's freeze rule).

## 8. The performance A/B

The host runs it before the branch merges, and also at the end of B4 (the sync path), on the instruction gate (#517; `Notes/plans/2026-11-13-off-path-instruction-gate.md`):
- **Base:** `main` at run time. **Head:** the branch merged with that `main`. Release builds, both sides in one container from the pinned image, with `swift --version` and the digest recorded beside each side. ABBA, one warm-up pair discarded, then 5 pairs, with `SWIFT_DETERMINISTIC_HASHING=1`.
- **Cells:** #554's five EncodingBenchmark cells (`rows-mp`, `rows-json`, `router-mp`, `rows-mp-100`, `json-control`) with `ENCODING_BENCHMARK_PERF_WINDOW=iteration`, plus one cell with the window off the sync path (`nonsync`), for the per-message `core.read`.
- **Judged:** mean `instructions:u` per cell; a REGRESSION above base by more than max(0.5 %, 3 × base's spread). The per-message budget is #546's: about +100 instructions per message for the one `core.read`, against the figure `TurnsBench` recorded for `read` on the host. Time is reported, not judged.
- **ServerLoadTest:** the zero-disconnect bar at today's room and player counts, on both sides, reported.
- Encoded bytes and the patch and event counts per cell must equal base's, as in #554's run.

## 9. Public API

- **Changed (B6, from #546):**
  - `JoinAdmission` gets a `refused` case, and `isAdmitted` becomes a `switch`; a new public enum case, so a switch over it breaks;
  - `registerSession` takes a required `WithdrawToken`, replacing `JoinAttemptEnd`;
  - the `Transport` protocol's defaults that ignore the connection generation (`closeSession`, `sendSessionFrames`) are removed (#240).
- **Added (package only):** the test hooks of §3.3 that are new: `waitForTurnIdleForTesting`, and the `disconnectQueuedBehind` observation.

## 10. Decisions for the maintainer

- **D1.** Keep both sync modes on the branch (proposed), or remove the legacy sync path on `main` first (#550 and layer 3 PR B) and re-record before the rewrite starts. Keeping both lets every golden cell compare, and costs B4 the legacy cycle as requests.
- **D2.** #652: allow a reused SessionID (proposed) or forbid it explicitly (§7).
- **D3.** #588's order relative to the freeze (§7).

## 11. Risks

- **The per-message `core.read`.** If it costs more than the budget on 6.2.4 (cross-module specialization, #621), the sync path regresses. The guard is `check-turns-inlinable.sh` and the A/B at the end of B4.
- **A hold whose boundary has no equivalent.** §3 maps every one. If a step finds a row whose order can't be forced at the mapped seam, the row is retired with a replacement only after Review and Main approve it, never quietly.
- **The branch's size.** One merge for the whole rewrite, so each step's gate is the guard, and the steps are reviewable commit groups.
