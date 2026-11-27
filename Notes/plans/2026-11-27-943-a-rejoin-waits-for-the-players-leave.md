# #943: a rejoin waits for the player's leave in flight

Revision 0 (2026-11-27). Plan only. The fix builds on #940 (the join's arrival token and the kick by generation), so it lands after #940 merges. Line numbers are at #940's head 7b2dda84 (`LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, `KM` is `KeeperMachine.swift`, `TA` is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`).

## 1. The problem

A leave with OnLeave resolvers runs in two segments around an await:
- **L1** (`leaveBegin`, LK:6044) checks the identities, removes the player's entry (LK:6089), cancels its jobs, takes the OnLeave sequence and returns `.runOnLeaveResolvers`.
- **L2** (`leaveAppend`, LK:6164) appends the OnLeave input after the resolvers return.

Between the two, the player has no entry. A join of the same player that runs then finds the slot empty at J2 and J2b: it is not a reconnection, kicks nothing and inserts. Its OnJoin is appended, and applied, before the leave's OnLeave. A handler pair that adds the player's state on OnJoin and removes it on OnLeave then removes the new session's state.

**P1 reproduces it** at the keeper level, in all four rows (tick and tickless lands, both join paths): the log is `[join A, join C, leave A]`, and `playerCount()` is 0 while A's OnLeave resolver is held. The same order shows up through a kick: on #940, R11's log is checked as a set for that reason.

**Replay is not affected (P3).** The record keeps the order the handlers ran in, `join#0, join#2, leave#1`, and the replay matches it: server events pass, with 0 pass mismatches and 0 hash mismatches. The bug is the order itself, live and replayed alike, not a divergence between them.

**The hosted path doesn't reach it today**, by reading the code (§7 P2). The adapter runs the disconnect's leave and every join in its one membership queue:
- `_onDisconnectImpl` → `enqueueMembership { handleDisconnectQueued }`, which awaits `keeper.leave` to the end, through the OnLeave resolvers and, on a tickless land, its input turn (TA:1282, TA:1337);
- `performJoinQueued` (TA:2265), whose `keeper.joinReportingAdmission` (TA:2297) runs in the same queue (`enqueueMembership`, TA:3115).

So a rejoin through one adapter queues behind the leave. Only direct keeper callers reach #943: the public `LandKeeper.join` / `leave` API, server code that calls it, and the tests. The same holds for #940's J2b must-fix. The keeper's rule still applies: the segment that acts re-checks what an await can change, whatever the caller serializes. And K2's cut-over must not rely on the adapter's queue for the keeper's own invariants.

## 2. Lessons consulted

- `2026-11-27-after-an-await-recheck-the-slot-by-identity-not-key` (#940): per-attempt fencing tokens, checked in every acting segment. Here, the leave's window is one more await the join doesn't see.
- `2026-11-26-a-barrier-that-looks-up-live-state-skips-what-is-being-torn-down`: J2b decides what to wait for (a kick) by looking at `players`, live state. A leave in flight is exactly what that lookup no longer reports. The fix keys the wait on a record made when the teardown started (the leave's marker), not on the table.
- `2026-11-25-capacity-check-before-an-await-needs-one-reservation-per-attempt` (#852): a join that waits holds a reservation of its own.
- `2026-11-05-callback-outlives-its-instance-clears-by-key`: the marker is ended by the leave that set it, by identity.
- `2026-11-25-an-issue-read-from-the-code-gets-a-failing-test-before-it-shapes-a-plan`: P1 ran before this plan.

## 3. Design

### 3.1 What holds the slot during OnLeave's resolvers

Two candidates:

| | (a) The entry stays until L2 (a `leaving` flag) | (b) L1 removes it as today; a per-player marker records the leave in flight |
|---|---|---|
| Readers of `players` | every one has to skip a leaving entry: `playerCount`, the sync targets, the action and event intakes, `currentPlayerServices`, the capacity check, the destroy check, the snapshot, the admin views | only J2 and J2b read the marker |
| What a leaving player looks like | present until its OnLeave is appended: a behavior change for counts, broadcasts and the empty-land timer | as today |
| Jobs and services | cancelled and removed at L1 as today, but the entry is still there | as today |
| The kick | the kicking join's own leave also leaves the entry in place, so J2c's "slot by generation" check changes | unchanged: the kick's leave is a leave in flight like any other |

**Recommendation: (b).** The window is the leave's, not the entry's: what the next join must not overtake is the leave's OnLeave, not the entry's presence. (b) adds one model table and changes no reader of `players`.

The marker is `leavesInFlight: [PlayerID: Epoch]`, the leaving entry's generation, on `KeeperModel`:
- **Set** by L1, in the segment that removes the entry, only when it returns `.runOnLeaveResolvers`. A leave without resolvers, one whose OnJoin was pending, a re-evaluation keeper's and a land without OnLeave all end in L1's segment, so no window exists.
- **Ended** in the segment that ends the window, by the leave that set it (its generation must match):
  - L2's append;
  - L2's drain drop (`guard !side.isDraining`);
  - `leaveResolversFailed`;
  - and every teardown that clears `players`: `failLand` (LK:6584), the shutdown item, `tearDownAfterFailedInitialization` and the forced shutdown's turnless branch. These clear the table whole and answer its waiters.
- **At most one per player.** While it is set, no join inserts for the player (§3.2), so no second entry can start a second leave. L1 asserts that the key is free.

### 3.2 A rejoin during the window: wait

| Option | Verdict |
|---|---|
| **Wait** for the leave, then go on | **recommended** |
| Refuse (a retryable error) | rejected: the common case is a reconnect right after a disconnect, while the OnLeave resolver saves the player's data. A refusal makes that reconnect fail at random and puts a retry loop in every client. The hosted path never refuses today, since it queues |
| Fence: the later join wins and A's OnLeave is dropped | rejected: A's OnJoin applied, so its OnLeave must apply, or the pair is unbalanced. #860 drops both halves only when the OnJoin never applied |

**The wait is the kick's path, minus the leave it would start.**
- J2b (`joinKickCheck`, LK:6211) gains one branch, after the drain and the token check and before the slot check: if `leavesInFlight[player]` is set, it returns `.awaitLeave(decided, leavingGeneration:)`.
- The driver waits for that leave to end, then runs J2c (`joinAfterKick`, LK:6247) with `kickedGeneration: leavingGeneration`. J2c's checks are all still right:
  - the drain: a leave dropped by a drain ends its marker, and the join answers `landShuttingDown`;
  - the token: when several joins of the player wait, all of them resume, the latest arrival inserts and the rest get `.superseded`, as for overlapping kicks (#940);
  - the slot: still empty, since nobody inserts while the marker is set or while a later token waits.

**The kick's own leave is a leave in flight too.** B kicks A, and C arrives during A's OnLeave. Today C inserts into the empty slot, and B is fenced out when its kick returns (R8, R11). With the marker, C waits for A's leave like B does. Both resume after A's OnLeave is appended. C, the latest arrival, inserts, and B gets `.superseded`. The order is `[join A, leave A, join C]` on every path, so R11's set check becomes an exact one, and #940's R8 keeps its order without depending on C's OnJoin being held.

**The wait's mechanics, on the keeper path.**
- J2b's segment records the waiter's ticket (the player and the leaving generation) in `side.leaveEndWaiters[player]` and returns. The driver registers its continuation there before any other suspension, the same way `awaitInputTurn`'s waiter is registered (no suspension since the segment).
- The segment that ends the marker resumes every waiter of that generation. A waiter whose generation is gone (a teardown) is resumed too, and J2c's drain check answers it.
- Cancellation: a join cancelled while it waits removes its waiter (`withTaskCancellationHandler`, as `waitUntilDrainStartedForTesting` does). Its driver's `defer` already ends its reservation and its token.
- Resuming mutates nothing: J2c is a new segment that re-reads everything.

**Capacity (#852).** A player whose leave is in flight has no entry and no reservation, so J2 counts it as a new player: the cap applies to C, as it does today. A join that will wait must then hold a place while it waits, or a newcomer could take the last place and C would insert over the cap. So J2 takes a reservation when an entry exists (as today) **or when a leave of the player is in flight**. The reservation is a place hold, not a cap bypass: `isReconnection` stays "an entry or a reservation exists", and a waiting join that passed the cap holds the place until it inserts or ends.

**The empty-land timer.** It is unchanged. L2 can schedule the destroy while a join waits (`players` is empty). A join still waiting when the timer fires gets `landShuttingDown`, which a client retries, as a kick's join does today. Counting waiters as "not empty" is a separate change (§6 Q3).

### 3.3 K2-2: the routed join and leave

The core's join (`KM` `joinDrive`, KM:645) and leave (`leaveDrive`) already run the same model segments as the keeper (#938), and #940's merge made the core's kick pass the generation and run J2c. The fix keeps all of its logic in model segments, so K2-2 routes only the wait.
- **On the core, the wait is a barrier wait,** as #948 does for `.awaitResume` and `.awaitInitialized` (`model.coreBarrierWaits`, K2-2 plan §3, commit 2: "barriers, not holds"). J2b's `.awaitLeave` parks the join's `KeeperContinuation` (`.joinAfterKick(decided, kickedGeneration:, caller:, syncsInTurn:)`, the case #940's merge added) in `coreBarrierWaits.leaveEnd[player]`. The step that ends the marker (L2, the failure, the drain drop, the teardowns) takes the waits out and runs `continueAfterLeave` for each, in the same step.
- **On the keeper path,** the waits are continuations on the side (`side.leaveEndWaiters`), like `inputTurnWaiters`.
- **The two tables follow the K2-2 plan's rule for barrier waits:** the core's table is in the model, and the keeper's on the side. The differential compares the core's table as a stated asymmetry, empty on the keeper's path (as #948 states for `coreBarrierWaits`).
- **Order with #948:**
  - If #948 has merged when this PR is written, the core's arm lands in this PR, with a differential row: P1's shape on both paths, exact log, and the R8/R11 interleavings, which also answers #940's Codex follow-up (no differential case suspends the core's kick while another login arrives).
  - If it hasn't, `.awaitLeave` on the core is a refusal case in `KeeperInputRoutes`' reason enum, named for K2-2 commit 2, so commit 4's totality check can't pass without it.

## 4. Tests

All of these use the keeper's own fixtures and holds (`ReplacedJoinGates`' `lgate-` OnLeave gate, `.join` / `.leave` holds), with no timing. They run on tick and tickless lands, and on both join paths where a join is involved.

| # | Case | Expected |
|---|---|---|
| W1 | P1's shape: A leaves, held in its OnLeave resolver; C joins | C waits (bounded check: C hasn't returned while A is held); after the release, the log is exactly `[join A, leave A, join C]`, with one player |
| W2 | W1 with two rejoins, C then D | D inserts, C is `.superseded`, and the log ends `join D` |
| W3 | the kick: B kicks A, held in A's OnLeave; C arrives | C waits; B is `.superseded`; the log is exactly `[join A, leave A, join C]` (R11's set check becomes exact) |
| W4 | W1, but A's OnLeave resolver throws | the marker ends; C inserts; A's OnLeave is dropped as today |
| W5 | W1, and the land drains while C waits (`forceShutdown`, `waitUntilDrainStartedForTesting`) | C gets `landShuttingDown`; the drain ends (bounded through an `EventLog`, not `withinHangBound` on the drain's task) |
| W6 | W1, and C's task is cancelled while it waits | C ends with `CancellationError`; its waiter, reservation and token are gone; A's leave ends normally |
| W7 | capacity: a full land (`maxPlayers` 2), A leaves (held), C rejoins and waits, and a newcomer arrives | the newcomer gets `roomIsFull`; C inserts; the count stays at 2 |
| W8 | a leave without resolvers, or with a pending OnJoin | no marker; a join right after behaves as today |
| W9 | the record of W1 replays | 0 mismatches; the recorded order is `join, leave, join` |
| W10 | the census | rows for `model.leavesInFlight` and the side's `leaveEndWaiters` (and `coreBarrierWaits.leaveEnd` with the core's arm) |

The suites that change their expectations: #940's R11 (the set check becomes exact) and R8 (its order no longer depends on holding C's OnJoin). #852's `RejoinHoldsPlaceTests` is unchanged.

## 5. Mutants

| # | Mutant | Must fail |
|---|---|---|
| 1 | J2b ignores `leavesInFlight` | W1, W3 |
| 2 | L2 doesn't end the marker | W1 (C never resumes; bounded) |
| 3 | `leaveResolversFailed` doesn't end the marker | W4 |
| 4 | the drain's drop doesn't end the marker or answer the waiters | W5 |
| 5 | J2 takes no reservation for a waiting join | W7 |
| 6 | the cancellation handler doesn't remove the waiter | W6's table check |
| 7 | the marker is ended by key alone (no generation check) | a stale end: W3 with a second leave scheduled (written with the code) |

The mutants go to the cloud.

## 6. Questions

- **Q1 (Review): (b) over (a).** The marker keeps every reader of `players` as it is. Does Review agree that the window belongs to the leave, not to the entry?
- **Q2 (maintainer): wait, not refuse or fence.** A rejoin during a slow OnLeave resolver waits for it, as it already does through the adapter's queue. Is a bound needed? A resolver deadline already bounds OnLeave (`ResolverDeadline`), so the wait is bounded by it.
- **Q3 (maintainer, may be out of scope): should a waiting join keep the land from its empty-land destroy?** Today a kick's join can be told `landShuttingDown` in the same window. Proposal: leave it for a follow-up and keep this change to the order.

## 7. Probes

**P1: run** (throwaway test in `JoinReplacedDuringOnJoinTests`, on #940's head, not committed). Shape: join A through the OnLeave gate (`lgate-<n>`), leave A and hold it at OnLeave's resolver, join C, settle, release. Output:

```
PROBE943 P1 tick=true reporting=false: countDuringOnLeave=0 C=returned log=["join:lgate-11034", "join:c-c", "leave:lgate-11034"] players=1
PROBE943 P1 tick=true reporting=true: countDuringOnLeave=0 C=returned log=["join:lgate-11042", "join:c-c", "leave:lgate-11042"] players=1
PROBE943 P1 tick=false reporting=true: countDuringOnLeave=0 C=returned log=["join:lgate-11035", "join:c-c", "leave:lgate-11035"] players=1
PROBE943 P1 tick=false reporting=false: countDuringOnLeave=0 C=returned log=["join:lgate-11041", "join:c-c", "leave:lgate-11041"] players=1
```

**P3: run** (same test file). The P1 shape with a recorder, then an event, save and `ReevaluationEngine.run`:

```
PROBE943 P3 tick=false: live log=["join:lgate-11059", "join:c-c", "leave:lgate-11059", "emit:1"] recorded lifecycle=["join#0", "join#2", "leave#1"] events=passed passMismatches=0 hashMismatches=0
PROBE943 P3 tick=true: live log=["join:lgate-11057", "join:c-c", "leave:lgate-11057", "emit:1"] recorded lifecycle=["join#0", "join#2", "leave#1"] events=passed passMismatches=0 hashMismatches=0
```

So the record keeps the live order with the sequences out of order (the OnLeave took its number at L1, before C's), and replay follows the record.

**P2: settled by reading the code, no run.** The hosted path serializes the two. `_onDisconnectImpl` (TA:1282) runs `handleDisconnectQueued` in `enqueueMembership`, and that awaits `keeper.leave` to its end (TA:1337). `performJoinQueued` (TA:2265) runs in the same queue. `enqueueMembership` (TA:3115) chains every operation on `membershipQueueTail`, one queue per adapter, so a hosted rejoin starts only after the leave returned. The claim shapes the severity, not the design: the fix is in the keeper either way. W1 is the failing test the fix starts from.

**P4: to run with the code.** That the driver registers the waiter's continuation before any suspension after J2b's segment, the way `awaitInputTurn` does. It is pinned by W1 with a `.join`-style hold placed right after the segment, which must not let a leave end unseen. Written as a test, not argued.
