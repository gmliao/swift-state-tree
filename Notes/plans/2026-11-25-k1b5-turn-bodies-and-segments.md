# K1b-5: turn bodies on the model, and the named segments (#700)

**Status:** rev 2.6, Review GO on rev 2.3 (2026-11-26, 3 shoulds and a nit folded in); rev 2.6 moves the sequence counter into the model in the move commit (D15.3, with K2 plan §4.4); rev 2.4 adds D15, four rows the joins and the leave need; rev 2.5 adds D16, the cancel token a staged start checks (Review checks the diffs). Rev 2.3 adds §3.1's missing rows (D11–D14, below) and the move commit (§6, 2b). Rev 2.2: the K1b-5b half (§4, §6 commits 4–7) brought up to date with K1b-1 to K1b-4, #862 and #865. Rev 2.1 was read at #853's head a87e0278 (K1b-3, on #835's K1a), the base K1b-4's rev 2.1 names. The reach-out census of §3 and the re-entry audit of §3.5 come from a script over the call graph (`func` bodies by brace matching, sync callees only) and from grep over `Sources/`. They are **not LSP-verified**: the language server's index on the working clone was stale (its `workspaceSymbol` placed `submitSyncStream` 137 lines off, and `findReferences` there returned another symbol's uses). K1b-5 re-takes both with `findReferences` and `outgoingCalls` on its own base, after a build. K1b-5 needs K1b-4.

**Inputs:**
- the parent plan `2026-11-22-keeper-on-turncore.md` rev 5.8: A.6's F6 to F8 and A.8;
- K1b-4's plan rev 2.1 (GO): the 59-field `KeeperModel`, `KeeperBehavior` with `KeeperConfig`, `outputCollector` on the actor (D1), the `playerServices` table, one `inout` access of the model per step (§3.4);
- K1b-1 and K1b-2 rev 2.1 (GO): `InputResult`, `FailureID`, the failure table, `actionJobTasks`, `actionSlotWaiters`;
- the K2 prep survey (1ebd7ddb), §7's three requests; K2 draft 2 (20290e69), §4.5's turn-side routes and the admission path;
- Review's K2 pre-read (2026-11-25): **a segment ends by returning the request for its await**, not by awaiting inline (§4).

`LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift` at a87e0278; `TA` is `Sources/SwiftStateTreeTransport/TransportAdapter.swift` at the same commit.

**Rev 2.1 → rev 2.2** (the segments' half, K1b-5b; the bodies' half is K1b-5a's own plan, `2026-11-25-k1b5a-turn-bodies-and-side.md`). Read at two bases:
- **K4** = K1b-4's branch at 4873abb7 (`KeeperModel`, `KeeperBehavior`, `ReplayFields`);
- **865** = #865 (K1b-5a step 1: the turn wrapper, `callOut` and the re-entry sentinel) at 1fedeed2, Review GO, merging.

**Line numbers added in rev 2.2 come from grep and reading, not from the LSP: "grep, unverified".** K1b-5b re-takes them with `findReferences` and `outgoingCalls` on its own base, after a build. The rows that still cite a87e0278 keep those numbers.

| # | Where | Change |
|---|---|---|
| D1 | §4.1, §5 | #852 is closed by #862. J2 now refuses a draining land before the cap, counts rejoin reservations in the cap, and reserves after it. The reservation ends at J3's insert and, through a `defer`, on every other exit, across the kick's and the OnJoin resolvers' awaits. A segment can't hold that `defer`: the driver keeps it and calls a one-line model segment. K2 makes it an explicit step on each error continuation and on the flow's abandonment. |
| D2 | §3.5, §6, §8 | #865 ships the sentinel as **refuse and end the land**: a guarded entry called while a body runs changes nothing and the land ends in that turn (`LandFailure.Kind.keeperReentry`). §8's open item is settled. The admission split becomes required for correctness: an admission inside a body would end the land on every recorded supersede. Mutant 3 gets a form the Mac suite observes. |
| D3 | §3.5 | Every synchronous port call a segment makes goes through #865's `callOut`. The admission is the one call made between two segments, outside any body. |
| D4 | §4 | `.awaitInitialization` is returned only before initialization ends. Joins wait through `ensureInitializedForJoin`, which reports any failure as `landShuttingDown`. |
| D5 | §4.4 | The caller's cancellation check is in A1, after the sequence and the ticket are taken, not in the intake before them. |
| D6 | §3.5 | A1 runs the land's `resolvers.build` closure (#825, #769), and J2 runs the CanJoin handler. Today, and in K1b-4, both get the state by value and nothing holds the model during the call. Once A1 and J2 are `mutating` model methods (K1b-5b), they run inside the segment's model access. So K1b-5b, not K1b-4, extends §3.4's contract to them. |
| D7 | §4.4, §4.5 | `.waitWhileFrozen` is a driver loop. The work counts' `defer`s that span the input-turn wait stay in the driver, as D1's does. |
| D8 | §4.5 | S1's frozen branch holds the input outside the queue and returns `.accepted` with no kick. |
| D9 | §4.1, §4.2 | **J4 has no generation re-check before its append** (nor G4). Rev 2.1's J4 row named one. The missing check is #860's fix, out of K1b-5b's pure move. |
| D10 | §3.1 | K1b-4 keeps `playerServices` on the actor. It moves into `KeeperTurnSide` in K1b-5a step 2, or in K1b-5b's first commit if step 2 doesn't move it. |

**Rev 2.2 → rev 2.3** (the move onto the model; Review, 2026-11-26). #884 (K1b-5a step 2) landed the bodies as actor methods that take `_ m: inout KeeperModel<State>`, reviewed as a stand-in for commit 2's `mutating` methods. K2-1's `handle` is a nonisolated method on the model, so it can't call them (K2 plan §6, condition 1). The move is now its own commit (§6, 2b), and §3.1 gets the rows the stand-in still reads from the actor. Anchors: `LK` at 5be6faab (#884's head 3e33ab18 plus this slice's flows 1 and 2), grep, unverified.

| # | Where | Change |
|---|---|---|
| D11 | §3.1, §3.3 | **`actionJobTasks` and `actionJobRemovalWaiters`** (LK:2556, :2737) move into the side. `startActionJob` (:2761, :2781), `completeActionBody` (:2809) and `removeActionJob` (:2855–2856) reach them through side methods. `cancelActionJob` (:3042) still reads the job's handle inline, through a side read, before its slot fill and its `cancel()` (§3.3's ordered cancel). `actionSlotWaiters` was already a §3.3 table. |
| D12 | §3.1 | **`reevaluationRecorder`** (LK:502), read by the six recording helpers (`recordSyncStream` :6082, `recordSyncOutput` :6102, `recordSyncMarker` :6128, `enqueueRecorderSubmission` :6140, `enqueueTicklessTurnEnd` :6151, `stageRecorderSubmission` :6198). It is written once, in `init` (:1212), so it becomes a `let` in `KeeperBehavior`, and `recordsSyncStream` (:5813) and `recordsInputs` (:506) read it there. The submissions themselves stay staged (§3.2). |
| D13 | §3.1, §3.5 | **The re-entry sentinel and `callOut`.** Its census rows move from `actor.*` to one row, `behavior.reentrySentinel`, with a census exception naming it as the behavior's one reference (#773). The class is `final class KeeperReentrySentinel: @unchecked Sendable` in `KeeperModel.swift`, beside `KeeperBehavior`, not in a machine file, so lint-turns' machine-file rule doesn't apply to it. `bodyDepth`, `reentryViolations`, `reentryFailure`, `closingGateForReentry`, `reentryGateClosed`, `reentryClosedGate` and `lateReentriesApplied` (LK:896–913) move into one final class, `KeeperReentrySentinel`, held as a `let` in `KeeperBehavior`, the shape K2 draft 7 §4.2 takes. So K2-1 doesn't move them again. The bodies that read the count (`settleBody` :1929–1931, `runTurnOutputs` :5474–5476, `applyReentryFailure` :5980–5988, `failLand` :6774) read it through `behavior`. `callOut` becomes a side method, `side.callOut(&m, &outputs, call)`, with today's flush → check → call → check order. The refusing entries (`noteReentry`) and `withTurn`'s depth count write the sentinel from the actor, as today. |
| D14 | §3.2, §4 | **Hold points.** A body awaits no hold: holds are driver steps (§4). Three bodies start a `Task` whose first await is a hold: `startActionJob` (:2766, `.actionJobStart`), `kickServerInputTurn` (:3980, `.serverInputKick`) and `failLand` (:6778, `.landFailedTeardown`). Each `Task` start becomes a staged effect, and the hold stays the task's first await. On the model, a body can't capture the actor, so the flush starts the task, and for the job it installs the handle (`actionJobTasks[seq].task`).
  - **Cancel before start** (Review's should 1). The flush runs before the segment's first suspension, so no other segment's cancel can read the handle in between. A cancel in the same body can: `failLand`'s `cancelAllActionJobs` (LK:6763), or, in K2 where a step takes several inputs, a leave's `cancelActionJobs(ofEntryGeneration:)` (:3015) after an action's start. It sees `task == nil`, marks `cancelledByKeeper` and fills the slot, but cancels nothing. So the start effect installs the handle, then calls `cancel()` when `cancelledByKeeper` is already set, the path a job started and then cancelled takes today. K1b-5 can't reach it (A1 ends at `startActionJob`), so the move commit pins it with a test: a cancel staged after a start, in one body; the job's resolvers see the cancellation and the drain doesn't wait for them in full. Prior art: cancel before start, as a `FutureTask` cancelled before `run`, or a Swift `Task` cancelled before its first job: the work starts and sees the flag at once.
  - **What the start captures** (should 2). `startActionJob` (:2755–2780) also builds, from actor state: the job's abandonment (`resolverAbandonment(.action)`, whose `onEnded` captures the actor weakly for `releaseCompletedActionJob`; `nonisolated`, over the actor's `abandonmentCounter`), the holds copy (`let holds = self.holds`), and the resolver context (`makeResolverContext(m, ctx)`, which reads `m.state` and `behavior.resolverServices`, so no actor state). The body builds the context, which the effect carries; the flush builds the abandonment and the holds copy, since both read the actor.
  - **The teardown's drain** (should 3). Today `drainTask = Task {…}` (:6777) is inline, and §3.2 promises that the drain handle is installed before any drain-start waiter is signalled. Staged, `failLand` stages the drain's start before the drain-start waiters' resume, so the flush installs the handle first, in staging order. Between the stage and the flush, `drainTask` reads nil. The readers are `waitUntilDrained` (:699), `waitUntilDrainStartedForTesting` (:714), `runForceShutdown` (:3355, :3371) and `shutdownIfIdle` (:7158). All of them are async actor entries, never reached from a body, so they run after the flush. A second `failLand` in the same body is stopped earlier, by `markFailedFirst`. This replaces flows 1 and 2's inline start, which was right only while the bodies were actor methods. No body calls `holds.at` synchronously; the grep's one other hit (`actionTableViolations` :2649) is the word in a string. |
| D15 | §3.1, §3.2, §4.1–§4.3 | **Rev 2.4: the joins' and the leave's actor reads** (found mapping flows 3+4 onto rev 2.3). Flows 3+4 are written in the actor-method shape, every segment and helper taking `(&m, &side, &outputs, …)`, and the move converts these the way it converts the action flow's:<br>1. **`destroyTask`** (LK:637). J3 cancels it inline, and L1's no-OnLeave branch schedules it (`scheduleDestroyIfNeeded`, whose task sleeps, then checks). The cancel stays inline at its place; the schedule's decision and its model writes stay inline, and its `Task` start is staged, a fourth D14 start. In the move the handle moves into the side beside the job handles (`side.cancelDestroy()`, direct; the start installs it at the flush). Cancel before start: a staged schedule followed by J3's cancel in one body would find no handle, so the start effect checks the cancel, as D14's job start does. K1b-5 can't reach it (L1 and J3 are different segments); K2 can.<br>2. **`scheduleInputDrain`'s task** (J4b's in-turn completion, and the action and server-input paths). The flag (`m.inputDrainScheduled`) is set inline and the `Task` start is staged (`scheduleInputDrain(&m, &outputs)`), a fifth D14 start. It has no handle and nothing cancels it, so D14's cancel-before-start rule holds trivially: the drain it starts re-reads the queue in its own turn.<br>3. **`outputCollector.takeNextSequence()`** (A1, C1, S1, J4, L1). **Rev 2.6:** the move commit moves the counter (`nextSequence`, `checksOverflow`, `sequenceExhausted`) and `syncRequestsByTick` from `OutputCollector` into the model, and the read becomes `m.takeNextSequence()`. This ends K1b-4's D1. K2-E (K2 plan §4.4) no longer moves them: its takes sit on the very intake, join and leave lines that flows 3+4 and the move rewrite. The scope's emits (`emitEvent`) take their numbers from the model too: the scope stages each event without a number, and the step numbers the staged events when it takes them, in staging order. The numbering stays the same, because a handler can't take a number any other way while it runs: it is synchronous, calls don't nest, and `ServerInputSubmitter.submit` is async.<br>4. **`resolverAbandonment(kind)`** (A1, J1, J3, L1): `nonisolated`, over the actor's `abandonmentCounter`. A segment that needs no `onEnded` builds it where it does today; an `onEnded` that captures the actor is built at the flush (D14's should 2). A driver that builds it before the segment is equivalent. |
| D16 | §3.2, D14, D15 | **Rev 2.5: what a staged start checks for a cancel.** A staged action can read neither the model nor the side: a `callOut`'s flush runs it while the body holds `&m` and `&side` (`TurnOutputs.stage`'s contract). It can't read actor state either, since the closure is nonisolated, and after the move a model body doesn't reach the actor at all. So D14's job start can't check `cancelledByKeeper`, and D15's destroy start can't check a model generation. **The rule:** the token is the handle's home. One reference box per job and per destroy holds both the task handle and the cancelled flag, under one lock: for the job, `KeeperActionJobTask` becomes that box; for the destroy, a `DestroyTicket`. The box is made in the body and captured by the staged start; the side's job table (or the actor's destroy slot) stores the box, never the bare handle, so the start writes nothing the staged action can't reach. **The start** installs the task into the box and checks the flag in one critical section, and cancels the task if the flag is set. **The cancel** (`cancelActionJob`, `cancelDestroy`), under the same lock, cancels the handle if it is installed, else sets the flag. Install-and-check against cancel is then one critical section; two separate objects (a handle in a table and a flag elsewhere) would reopen the gap. The shape is a `CancellationTokenSource` with its task, and the lock is `ActionJobCallerCancellation`'s. The model mark (`cancelledByKeeper`) stays, for the model's own logic (the completion's early return, the slot fill). Prior art: a cancellation token captured at stage time and checked by the work when it starts, as .NET's `CancellationToken` passed to a task that hasn't run, and Swift's own cancellation flag on a `Task` cancelled before its first job. Tests (the move commit): a cancel staged after a start in one body, for the job and for the destroy; each asserts that the task observes the cancellation and that the drain doesn't wait for a full run. |

Anything the move finds that can be neither a side method nor a behavior field stops the commit, and goes to the maintainer.

Anchors at K4 | 865 (grep, unverified): `join(playerID:…)` 1874 | 1996; `joinReportingAdmission` 2021 | 2142; `admitJoiningInTurn` 2233 | 2354; `leave(…sessionID:)` 2969 | 3111; `startActionJob` 2576 | 2720; `completeAction` 2617 | 2761; `fillActionSlot` 2737 | 2881; `awaitActionResult` 2763 | 2905; `cancelActionJob` 2815 | 2957; `submit` 3264 | 3405; `handleClientEvent` 3461 | 3602; `submitServerInputErased` 3597 | 3738; `kickServerInputTurn` 3673 | 3817; `awaitInputTurn` 6086 | 6599; `endRejoinReservation` 1283 | 1406; `debugWaitWhileFrozen` 1837 | 1959. TA (the same at both): the clear's `submitSyncStream` 3986, `recordsSyncStream` 3831, the `.legacyCycle` submit 3859, `supersedeSessions` 1935, `admitJoiningSessionIsolated` 1984.

**Rev 2 → rev 2.1** (Review's NOT GO on rev 2: 5 must-fix, 5 should, 1 nit; the K2 mapping in K2 draft 2):
- §3.1: `KeeperTurnSide` is an interface of methods. Reads are methods, writes are staged, and two calls are direct on the binding token (K2 draft 2 §4.5). The shared references stay `nonisolated let` on the actor and are passed in (MF3).
- §3.2: the staging rule. Stage the effect, never the bookkeeping later code in the same segment reads (MF1), with today's record order pinned. The guarantee is restated, and the observers are named (S1).
- §3.3 is new: waiters and job cancellation (MF3).
- §3.5 is new: the synchronous re-entry audit, every adapter → keeper callback, and the join admission's split (MF2).
- §4: every join flow, hold and completion as a row (MF4), and the action lanes, the freeze accounting and the waiter registration (MF5).
- §3.1, F4: the clock read stays where it is (S2).
- §4.5: the K2 and replay handoff (S3). §6: the mutants tell themselves apart (S4). §7: the A/B's terms (S5).
- One name, `KeeperTurnSide`. The failure-ID counter lives in the model. Section references are fixed (nit).
- §9 is new: the slice's size, and a proposed split.

## 1. Goal

After K1b-5:
- **Every turn is a body.** A body is a `mutating` method on `KeeperModel` that takes the behavior and the turn side (§3.1), and returns the turn's staged outputs.
- **Every async flow is a chain of synchronous segments.** Each segment returns a value that names the next await and carries what that await needs (§4). The actor's driver performs the await and passes the result to the next segment. K2 turns the same value into an effect, and the result into an input, without rewriting the segment.
- **Replay calls the same bodies** on its own model (A.6, "Replay path"), through its own driver (§4.5).
- **K2-1's `handle` calls these same bodies and segments, not copies** (a K2 condition from Review).

**No behavior change.** Each move is a refactor, pinned by the existing suites. A re-check that today's code does by hand moves into the segment after its await, unchanged. A flow that lacks a re-check keeps lacking it (#852, §4.1), and a new check is its own change.

## 2. The turn bodies

| Body | Today (LK) | Its awaits after it, which stay in the driver |
|---|---|---|
| the tick turn | `runTickTurn` (:5033) | `finishTickTurn`'s record submit (:5140) |
| the input turn | `runInputTurn` (:6032) | `runInputDrain`'s record submit (:5986), then `resumeInputTurnWaiters` |
| the sync-only turn | `runSyncOnlyTurn` (:5412) | none |
| the settle | `settleTurn` (:1842) | none |
| the requested sync | `syncTurnNow` (:5605) | none |
| the shutdown between ticks | `applyShutdownTurnBetweenTicks` (:3047): its synchronous apply, before its one await | the record submit |
| initialization's output segment | in `performInitialization` (:1433) | K5 owns the flow; K1b-5 only makes this segment a body |

```swift
extension KeeperModel {
    mutating func applyTickTurn(_ input: TickTurnInput, behavior: KeeperBehavior<State>,
                                side: inout KeeperTurnSide) -> TurnOutputs
}
```

- **`TurnOutputs`** is a non-plain struct, built by the body and flushed by the driver right after the body returns, before any suspension (§3.2). It holds the staged effects only: the Tasks to submit to the recorder, in order; the continuations to resume, with their outcomes; the tasks to start; the `playerServices` inserts and removals; the follow-up sync request. Every number, position, count or decision those effects depend on is already in the model when the body returns (§3.2's rule).
- **The handler step.** K1b-4's `withHandlerStep(ctx) { m, ctx in … }` becomes a `mutating` method on the model. The body calls it on `self`, so the single access to the model is the body's own.

## 3. What a body reaches outside the model

A body is synchronous, but today its sync callees reach actor-side state. The script found 64 sync functions reachable from `runTickTurn` and 27 from `settleTurn`. Each reach-out is a side method (§3.1), a staged effect (§3.2), or a waiter step (§3.3).

### 3.1 `KeeperTurnSide`: methods, with writes staged

`KeeperTurnSide` is one non-plain struct, passed `inout` beside the model. Its fields are private, and a body reaches them only through its methods.
- **In K1b-5** it is a stored property on the actor, `var turnSide`, holding the tables a body touches: `playerServices`, the continuation tables (§3.3), `pendingSyncTurnAfterTurn` and `pendingFold`. K1b-5 updates K1b-4's census paths for these rows (`actor.X` → `turnSide.X`).
- **Rev 2.2 (D10):** K1b-4 keeps `playerServices` on the actor (`actor.playerServices`), and #865's `KeeperTurnSide` holds only the recorder tracker. K1b-5a step 2 moves the tables above into the side. If it doesn't, K1b-5b's first commit does, before J3's insert and L1's removal use `insertServices` and `removeServices`.
- **In K2-1** a step builds it locally from snapshots and binding tokens, and its writes become the step's outputs (K2 draft 2 §4.5). The methods keep their signatures.
- **The shared references stay on the actor** as `nonisolated let`, and the side holds copies of the references: `drainFlag`, the `LandFailureMailbox`, the keeper's identity. Nonisolated code reads them today (`isDraining`, `destructionCause`, `failure` and `notePendingFailure`, LK:633–664), and moving them under an isolated `var` would cut that off.

| Method | Kind | Today (LK) |
|---|---|---|
| `services(for:generation:)` | read | `makeContext`'s player services (:3584) |
| `insertServices(…)`, `removeServices(…)` | staged | the join's insert (J3), the leave's removal (L1) |
| `markFailedFirst(_:) -> Bool` | direct: K1b-5 calls `drainFlag.setFailed`; K2 sets a model flag and stages the atomic set | `failLand` (:5847), `completeShutdownTurn` |
| `closeOutputs(for:)` | **direct, on the binding token** | `failLand`. In K2 the in-turn sync sends frames during the step and the emits flush after it, so a staged close would let a later direct frame out before the gate closes |
| `syncNowInTurn(…)`, `settleNowInTurn(…)` | **direct, on the binding token** | `applyInTurnSyncResult` (:4971), `runTurnOutputs` (:4939), `settleTurn` (:1868): they return frames mid-turn |
| `takeEmittedEvents(forTick:)`, `takeSyncRequest(…)`, `readPosition()` | read and drain, on the collector | `takeEmittedEvents`, `takeSyncRequest`, `syncReadPosition`. The context closures keep the collector reference they capture before the step borrows the model (LK:3606) |
| `takePendingFold()`, `now()` | read | `takePendingFold` (:5124) and the tick clock, at today's point (below) |
| `takePendingTransportFailure()` | read and clear, on the mailbox | `applyInputs`, `applyPendingTransportFailure` (:5402) |
| `requestFollowUpSyncTurn(reason:)` | staged | `requestSyncTurnAfterThisTurn` (:5626) |
| `noteReplayRejected(sequence:)` | turn-local, then staged | `applyInputs` writes, `takeReplayRejected` reads in the same turn. The body accumulates in a local that the turn's record reads, as today, and the side hands the list to `replay` after. Nothing on a live keeper |
| `recordFailure(_:) -> FailureID` | the ID from the model's counter, the error staged into the table | K1b-2's table |
| `probe(_:)` | direct | `inTurnProbeForTesting`. It must not call back into the keeper (§3.5) |
| `jobTask(_:)`, `insertJobTask(…)`, `removeJobTask(_:) -> [removal waiters]` (D11) | read; inline write; the waiters' resume staged | `actionJobTasks`, `actionJobRemovalWaiters` (LK:2556, :2737) |
| `callOut(&m, &outputs, call)` (D13) | direct: flush → check → call → check | `callOut` (LK:5922); the counters in `behavior.reentrySentinel` |
| `startTask(…)` (D14) | staged | the three `Task` starts whose first await is a hold (LK:2766, :3980, :6778) |

**The clock read stays where it is** (S2). The tick turn reads the time after it consumes the pending fold and checks `inTurnSyncDue`, the test override included, and the body keeps that point through `side.now()`. Reading it earlier, in the driver, can change the reported duration or cross the strict `>` lateness threshold with no interleaving at all. K2's input timestamp is a stated behavior change at the cut-over, not part of K1b-5.

### 3.2 Staged effects: the rule

**Rule (MF1): stage the effect, not its bookkeeping.** Every count, position, index or mark that later code in the same segment reads is assigned at the original call site, inside the body. Only the effect, the `Task` that submits or the continuation that resumes, goes into `TurnOutputs`. The driver flushes `TurnOutputs` in staged order before the segment's first suspension.

| Kind | Inline, at the original call site | Staged |
|---|---|---|
| recorder submissions (`enqueueRecorderSubmission`, :5333; `enqueueTicklessTurnEnd`, :5343) | the entry materialized; `recorderSubmissionCount += 1` (a model field). The settle, the sync-only turn and the input drain compare it with a mark to decide on the tickless `endTurn` (LK:1847, 1865, 5416, 5426, 5991). A failure-only tickless batch has an empty ordinary draft, so a staged count would drop its only `endTurn` | `recorderSubmissions.submit { … }` |
| sync-stream entries (`submitSyncStream`, :5277; `recordSyncMarker`, `recordSyncOutput`) | the failure gate (`failure == nil`, read through `drainFlag`), the stream index (`syncStreamCounter`), the cursor (`syncOutputIndexCursor`), the marker position | the submit |
| the drain task (`failLand`) | the decision to drain, the drain's state in the model | the `Task`; its handle is installed before the drain-start waiters are signalled |
| `playerServices`, the follow-up sync turn | none needed: nothing later in the segment reads them | the write |

**Today's record order, pinned** for a failing tick or pass, and kept by staging in call order:
1. the sync-stream entries made earlier in the turn;
2. the terminal failure entry;
3. the turn's ordinary draft, or the tickless `endTurn`;
4. the teardown entries (the clears of the sessions the failure closes).

Rev 2's "terminal before teardown" left out that the terminal entry also comes before the same turn's ordinary draft.

**What staging guarantees** (S1, which corrects rev 2's reasoning). A resumed continuation does not always wait for the actor: a caller on the generic executor continues at once. The adapter's waiters share the keeper's executor, so they wait. The guarantee is narrower:
- the body's statements after a staged effect don't depend on it having happened;
- the drain handle is installed before any drain-start waiter is signalled;
- the flush happens before the segment's first suspension, so no keeper code runs between the body and its effects.

**Observers off the keeper**, which see an effect only once it is flushed:
- the recorder tracker's tail and pending count, read by the flush waiters and the tests;
- the outbound writer, which gets the in-turn sync's frames directly, never through a staged effect;
- the nonisolated readers of `drainFlag` and the mailbox, which are written directly (`markFailedFirst`).

**Callers of the shared helpers from outside any body** flush their own outputs: `failLandForTesting` (LK:5839) and the shutdown path call `failLand` directly. Each such caller gets a wrapper that runs the helper and then flushes its outputs, so no effect is dropped.

### 3.3 Waiters and job cancellation (MF3)

- **A waiter's removal and its outcome stay inline**, at today's decision point. Only `resume` is staged. This covers `inputTurnWaiters`, `shutdownTurnWaiters` (:5914), `actionSlotWaiters`, and the test waiters (`drainStartedWaitersForTesting`, `failureWaitersForTesting`). The side holds these tables, and its methods return the removed continuation with its outcome for the flush.
- **Action cancellation is one ordered operation**, not split. `cancelActionJob` (LK:2723) reads the job's handle, marks the job, fills its slot and calls `cancel()`, in that order, all inline. Its slot fill resumes inline too, so the resume stays before the `cancel()`, as today. Cancellation handlers can run synchronously in `cancel()`, so the audit in §3.5 lists them: `awaitActionResult`'s `onCancel` sets the caller's flag and cancels the task, and touches no keeper state. Any handler inside `ResolverExecutor` is checked on K1b-5's base.
- **The bound sync requester stays weak**, and the choice between the attached port and the bound port is still made at failure time (LK:5895).

### 3.4 Exclusivity

- The body holds `&model` and `&turnSide` together. They are two stored properties of the actor, and dynamic enforcement is per property, so the two accesses don't conflict.
- **What traps:** anything a body calls that reaches `self.model` or `self.turnSide` through the actor instead of through the binding it was given. A closure that captured `self` does that. So does a synchronous callback through `assumeIsolated`, which passes its executor check because the executor is the same (§3.5).

### 3.5 Synchronous re-entry: the audit (MF2, as a class)

A port call that the keeper makes during a body can call back into the keeper synchronously. While the body holds `&model`, a callback that reads or writes the model traps. The audit lists every such path at a87e0278, from two directions.

**Every `assumeIsolated` in `Sources/`:** six in `TransportAdapter+LandKeeperTransport.swift`, the adapter entering its own isolation (lines 36–102), and three in TA, the adapter entering the keeper's:

| Site | What it does | Reached from a body? |
|---|---|---|
| TA:3822 `keeper.assumeIsolated { $0.recordsSyncStream }` | reads `behavior.config.mode`, `reevaluationRecorder` and `syncsInTurn` (the transport). After K1b-4 none of these is in the model | yes, through the admission (below). It doesn't trap, because it reads no model field |
| TA:3850 `keeper.assumeIsolated { $0.submitSyncStream(drafts) }`, in `recordSyncStream`'s `defer` | writes the sync-stream index, the cursor and `recorderSubmissionCount`: model fields | **no, by an invariant.** It runs only for `read.turnKind == .legacyCycle`. An in-turn recording's kind is `inTurnSyncTurnKind`, which is only ever `.tick` or `.syncOnly` (LK:535, 1863, 5424). `.legacyCycle` comes only from the adapter's standalone initial sync, in its own segment |
| TA:3977 `keeper.assumeIsolated { $0.submitSyncStream([draft], outsideTurn:) }`, in `recordSyncStreamClear` | writes the same model fields | **yes: the trap.** Path below |

Review's message cited :3850 for the admission path. The admission reaches :3977, the clear's submit, and :3850 is the standalone `.legacyCycle` branch. The two are swapped there.

**Every synchronous keeper → adapter call** (`LandKeeperTransport`'s non-async requirements, plus the settle port), with what the script found each one reaches:

| Keeper call (LK) | Adapter path | Reaches |
|---|---|---|
| `admitJoiningSession`, from `admitJoiningInTurn` (:2278): J3's no-OnJoin branch (:2190) and J4's append (:2256) | `admitJoiningSessionIsolated` → session replacement → `supersedeSessions` → `recordSyncStreamClear` | TA:3822 (a read, safe) and **TA:3977 (a write: the trap)** |
| `runSyncPhaseInTurn` (:4951, :5427) and `runSettlePhaseInTurn` (:1868) | → `commitSyncPhase` → `recordSyncStream` | TA:3850, unreachable by the invariant above. The in-turn drafts come back in the phase's output |
| `refusesResolvedJoin`, `noteJoinInputsConsumed` (:4284), `hasJoinsAwaitingSync` | 110, 1 and 2 sync functions | no keeper callback |
| `runsSyncPhaseInTurn(of:)`, `closeOutputs`, `recordsInTurnSyncFolds`, `noteInTurnSyncFold`, `noteInTurnJoinSyncTick` | nonisolated; the output gate and the profiler counters | no keeper callback |

**The adapter's synchronous reads of the keeper** (`isDraining`, `destructionCause`, `failure`, `notePendingFailure`, `isLive`, `hasPeriodicSync`) are all nonisolated, and they read `drainFlag`, the mailbox or `behavior`, never the model. §3.1 keeps them that way.

**Closures a body runs:** the handler context's closures capture the collector reference and `serverInputSubmitter`. The submitter hops to the keeper asynchronously. `ResolverContext` takes the state by value. None reaches the model.

**User code a segment runs (rev 2.2, D6).** A1 runs the land's `resolvers.build` closure: `resolvers.build((model.state, decodedAction), ValidateContext(ctx))` (K4:3360, grep, unverified; #825, #769). J2 runs the CanJoin handler (K4:2060). Both are user code, like a handler.
- **Today and in K1b-4,** both get the state by value. The model is read through its getter, and that access ends before the call (K1b-4's SILGen probe, in §Probes), so a callback into the keeper doesn't trap. K1b-4's contract covers only the `inout` sites: `withHandlerStep`'s 11, and `clearDirty()`.
- **In K1b-5b,** A1 and J2 are `mutating` methods on the model, so the segment's access to the model lasts across the call. A synchronous call back into the keeper from either one then traps, or ends the land if it reaches a guarded entry.

So K1b-5b extends the contract (a handler must not call back into its keeper synchronously) to `resolvers.build` and CanJoin, in the same places in the docs, in the commit that makes A1 and J2 model methods.

**The fix in K1b-5: admission runs between two halves of the segment, with the borrows released.** The admission must stay in the same actor segment as the insert (the no-OnJoin branch) or the append (J4), before any waiter registration or await. So each of the two segments splits at the admission into two synchronous halves:

```swift
// J4, in the driver; no suspension between the three calls:
let prepared = model.joinAppend(capture, outputs, behavior: behavior, side: &turnSide)   // borrows end here
let admission = admitJoiningInTurn(prepared.admissionRequest)   // may call back: TA:3822, TA:3977
request = model.joinAfterAdmission(prepared, admission, behavior: behavior, side: &turnSide)
```

The callback then finds the model free, as it does today. The draft-returning path, `admitJoiningSessionInStep(…, recordsSyncStream:) -> (JoinAdmission, [SyncStreamDraft])`, stays in K2-1, where K2 draft 2 §4.5 puts it. Inside `turn.run` the step holds the model for its whole length, so the split above isn't possible there. See §9 for the slice size.

**The guard.** The audit is a list, and a future port call can add a path to it. So K1b-5 adds a re-entry sentinel. The actor keeps `bodyDepth` (a stored `Int`, outside the model), raised by the driver around each body call. Each `assumeIsolated` entry that writes the keeper (`submitSyncStream`, and any later one) checks it first.

**Rev 2.2 (D2): the sentinel as #865 ships it.** A guarded entry called while a body runs is refused: it changes nothing in the model, notes the failure in the keeper's mailbox, closes the output gate, and the land ends in that same turn with `LandFailure.Kind.keeperReentry`. Nothing traps. `callOut` refuses a port call whose flush or call tripped the sentinel, so the body never reads that call's answer. A trip the body didn't see is ended by a backstop after the turn. Rev 2.1's counted log, where a test failed on a non-zero count, is replaced. Two consequences for K1b-5b:
- **Every segment runs inside the turn wrapper,** with the depth raised, or the sentinel doesn't cover it.
- **The admission split above is required for correctness,** not only for exclusivity. An admission made inside a body would reach the clear's `submitSyncStream` (TA:3986, grep, unverified) while the depth is raised, and end the land on every recorded supersede.

**Rev 2.2 (D3): port calls from segments.** Every synchronous port call a segment makes goes through `callOut`: J2's stale-join refusal (`refusesResolvedJoinInTurn`, K4:2070 → :2241, grep, unverified) and C1's probe (`client-event-queued`, K4:3569). The admission is the one call made between two segments, at depth zero.

## 4. The segments: each returns its await's request

**The forced point.** A segment never awaits. It returns a value of its flow's request enum, one case per await, carrying what the await needs. The driver performs the await and calls the next segment with the result.

- **Two continuations.** Each request case names the segment for its success and the segment for its error. A thrown await is not a missing value. A flow whose await can't fail says so in its row.
- **Direct paths stay direct.** A flow that today returns without suspending (a refused join, an action that needs no job, a server input refused at intake) returns `.done` from its first segment, and the driver performs no await.
- **Rev 2.2 (D4): initialization.** `ensureInitialized` (K4:1201, grep, unverified) returns without suspending once `didInitialize` is set, so `.awaitInitialization` is returned only before that. The joins wait through `ensureInitializedForJoin` (K4:1274), which reports any initialization failure as `landShuttingDown`: that mapping stays in the join's error continuation.
- **`holds.at(…)`** is an explicit driver step at the position in each row below, not part of an await. Without a hook it doesn't suspend (HoldPoints.swift:29–36), and that fast path stays.

```swift
enum JoinRequest {
    case awaitInitialization(JoinCapture)
    case runCanJoinResolvers(JoinCapture, CanJoinResolverRequest)
    case kick(JoinCapture, KickRequest)
    case admit(JoinPrepared)                     // synchronous; §3.5
    case runOnJoinResolvers(JoinCapture, OnJoinResolverRequest)
    case awaitInputTurn(JoinCapture, sequence: Int64)
    case done(JoinOutcome)
}
```

- **One enum per flow** (§8.3). The action worker is a flow of its own (§4.4). K2 maps the cases at its boundary: the I/O cases to `turn.run`, `.awaitInitialization` and `.waitWhileFrozen` to entry barriers, `.awaitInputTurn` to the reply in `.recordTaken`, and `.done` to the reply (K2 draft 2).
- **The capture** is the flow's state that crosses the await. §5 lists what isn't plain.

### 4.1 The reporting join (`joinReportingAdmission`, :2079)

| Step | Today (LK) | Segment, and what it carries |
|---|---|---|
| `.awaitInitialization` | :2086 | error: throw. Success: **J1** builds the CanJoin request. The CanJoin context carries its outputs, and its detached RNG is drawn at the decision point, as today |
| `.runCanJoinResolvers` | :2106 | error: throw. Success: **J2**, `canJoin`, the stale-join refusal (#234), the draining refusal, the cap check counting rejoin reservations, and the reservation (rev 2.2, D1; K4:2059–2098, grep, unverified) |
| hold `.join` | :2147, after the stale refusal and the cap check, before the old client and session are looked up | a driver step. It also runs in the branch that never kicks. Rev 2.2 (D1): just before it, the driver installs the `defer` that ends this attempt's reservation on every exit (K4:2099, grep, unverified) |
| `.kick` (the old session's leave) | :2153 | **J2b**, after the hold: read the kick target. The kick is the old entry's leave, §4.3's flow. Success: **J3** re-reads the entry after the kick, then the insert into `players`, the staged `playerServices` insert, the `isDraining` check, and the entry generation. Rev 2.2 (D1): J3 also ends the reservation at the insert (K4:2135, grep, unverified) |
| `.admit` (no-OnJoin branch) | :2190 | **J3a/J3b** around the admission (§3.5), then `.done` |
| `.runOnJoinResolvers` | :2218 | error (OnJoin failed): roll back the entry if it is still this generation, with the paired `playerServices` removal, schedule destroy, throw. Success: refresh `resolvedAtTick` (the no-resolver path keeps its original value), then **J4** |
| **J4**, the append | :2228–2260 | the `isDraining` check: when draining, roll back the matching generation with the paired removal, and throw `landShuttingDown`. Then the append, `.admit`, and **J4b**. Rev 2.2 (D9): there is no generation re-check before the append (K4:2186–2208, grep, unverified). The missing check is #860's fix, out of this pure move |
| **J4b** | :2259–2270 | `.admittedCompletesInTurn`: schedule the drain with no waiter, then `.done`. Tickless otherwise: register the waiter in this segment (MF5), then `.awaitInputTurn`. Tick land: `.done` |
| `.awaitInputTurn` | :2268 | carries the `JoinOutcome`. Error: throw. Success: `.done(outcome)` |

**#852** (rev 2.2, D1). #862 closed it, so K1b-5b moves its fix, unchanged:
- J2 checks the cap counting reservations;
- J2 reserves after the cap;
- J3 ends the reservation at the insert;
- the driver's `defer` ends it on every other exit.

`RejoinHoldsPlaceTests` and #862's three mutants pin it: dropping the `defer`, ending the reservation by player key, and one reservation per player. K1b-5b re-runs all three. Under K2 the `defer` becomes an explicit step on each error continuation and on the flow's abandonment.

**#860** (rev 2.2, D9). A join whose entry is replaced while its OnJoin resolvers run still appends its OnJoin. J4 and G4 have no generation re-check before the append, and K1b-5b doesn't add one. K6-Q2 decides the fix (rebind, or refusal).

### 4.2 The legacy join (`join(playerID:clientID:sessionID:services:)`, :1933)

A separate flow, with no CanJoin and no cap, and no admission:

| Step | Today (LK) | Segment |
|---|---|---|
| `.awaitInitialization` | :1939 | error: throw |
| hold `.join` | :1940 | a driver step |
| `.kick` | :1946 | **G1** reads the existing entry; the kick is §4.3's flow. **G2** after it |
| `.runOnJoinResolvers` | :1990 | the same rollback and `resolvedAtTick` rules as J4 |
| `.awaitInputTurn` | :2030 | the waiter registered in the append's segment. Rev 2.2 (D9): G4, like J4, has no generation re-check before its append (K4:1946–1968, grep, unverified): #860 |

### 4.3 Leave (`leave`, :2827)

| Step | Today (LK) | Segment |
|---|---|---|
| `.awaitInitialization` | :2828 | error: throw |
| hold `.leave` | :2829, after initialization, before the identity checks | a driver step |
| **L1** | | find the entry, check the client and the session, snapshot its services **by value**, stage both removals, cancel its jobs (one ordered operation each, §3.3), take the OnLeave sequence. Then `.runOnLeaveResolvers` |
| `.runOnLeaveResolvers` | :2896 | error (OnLeave failed): count the drop, schedule destroy, throw. Success: refresh `resolvedAtTick`, then **L2**: overtaken by the drain, log and return; otherwise the append and the waiter in this segment, then `.awaitInputTurn` |
| `.awaitInputTurn` | :2945 | error: throw, and **L3 is skipped**. Success: **L3**, `scheduleDestroyIfNeeded()` (:6221), then `.done` |

L3 is a write after an await today. K1b-5 names it, and K2 makes it the completion input's handler.

### 4.4 Actions (`submit`, :3120; `startActionJob`, :2505; `completeAction`, :2544; `awaitActionResult`, :2676)

**The intake** keeps its order (LK:3120–3229): `enforcingLimits`; the caller task's cancellation, checked before a job launches; the close check before the freeze; `.awaitInitialization`; `.waitWhileFrozen`; and the checks after waking. Then **A1**: the handler lookup (K1b-1's index), the decode, the sender check, the limits, the sequence, the ticket.

**Rev 2.2.**
- **D5:** the caller's cancellation check (`Task.checkCancellation()`) is in A1, after the sequence and the ticket are taken and before `startActionJob` (K4:3379, grep, unverified), not in the intake before them. It stays there. In K2 the segment doesn't run on the caller's task, so the check moves to the boundary. Moving it before the sequence would also remove a sequence gap, a behavior change that belongs to K2.
- **D7:** `debugWaitWhileFrozen` is a loop (`while frozen, !isDraining`, K4:1837), so `.waitWhileFrozen` is a driver loop, and the segment after it re-checks. The tickless intake's `endsWorkOnReturn` `defer` spans the input-turn wait (K4:3288–3291), and the client event's `defer { debugEndWork() }` does too (K4:3570). Both stay in the driver, as the reservation's does (D1).

| Lane | After A1 |
|---|---|
| **job** (resolvers) | `.startJob`: the driver registers the job, starts its task, and hands `.pending(sequence)` back to the caller at once |
| **direct, tick land** | the append; `.done(.none)` |
| **direct, tickless** | `debugBeginWork`, the append, and the waiter in this segment; then `.awaitInputTurn`. On success **and** on a throw after the wait, `debugEndWork`, so the freeze count balances on both |

**The worker** is its own flow. The task awaits the resolvers, then the hold `.actionComplete`, then calls **A2** on the actor:
- A2 re-reads the job and its side-table entry;
- it keeps the job while its abandoned resolvers run (the abandonment and the cap retention);
- it returns at once for a job the keeper cancelled;
- a resolver failure is checked before the caller's cancellation, as today;
- then the delivery check, the deliver, and the fill.

A job's slot fill ends its freeze work (`ticklessJobWork`), on every path.

**`awaitActionResult`'s continuation** is the waiter K1b-2 keeps in `actionSlotWaiters`. Its closure is one segment, with no request.

### 4.5 Client events, server inputs, the drivers, and the handoff

- **Client event** (`handleClientEvent`, :3316): `.awaitInitialization` (:3322) and `.waitWhileFrozen` (:3331), then **C1**: the descriptor, K1b-1's decode, the bytes, the sender check, the sequence, the append. On a tickless land, `debugBeginWork` and the waiter are in C1's segment, then `.awaitInputTurn` (:3420), with `debugEndWork` on success and on a throw.
- **Server input** (`submitServerInputErased`, :3446): `.awaitInitialization` (:3448), then **S1**. It is exempt from the freeze. Rev 2.2 (D8): S1 has two `.done` paths. While frozen it holds the input outside the queue (`serverInputsHeldWhileFrozen`, K4:3660–3663, grep, unverified) and returns `.accepted` with no kick; the resume queues and kicks it. Otherwise it appends and kicks. Its kick (`kickServerInputTurn`, :3525) is a driver task: the hold, `awaitInputTurn`, `debugEndWork` (:3530–3532). Its waiter registers late, on purpose: an applied input then gets the empty outcome (`?? .success(.none)`, LK:5965).
- **Every other flow registers its waiter in the same actor segment as its append**: join, leave, direct actions and client events. A hop in between turns a real result into the empty one.
- **The input drain** (`runInputDrain`, :5986): the mark, the body, the flush, the submit or the tickless `endTurn` (§3.2), then **D1**, the resume. The record draft isn't plain: `ReevaluationRecordedResolverOutput.value` is `AnyCodable` (ActionRecorder.swift:10).
- **The live tick** (`runTick`, :4537): the body, the flush, `finishTickTurn`'s submit (:5140).
- **The sync loop** (`runSync`, :6133): its fold decision writes the model outside a turn (K1b-4 §4.3's exception), then awaits the transport. Unchanged until K2's `.syncDue` step.
- **Replay** keeps its own driver: tick replay's separate W1 apply and W2 handler segments, the recorded failure cutoff, and the legacy sink flush (LK:4812–4888). It calls the same bodies but doesn't go through the live tick's wrapper.

**The K2 handoff** (S3):
- K2-1 builds a step-local `KeeperTurnSide` from snapshots and binding tokens, with writes as outputs (§3.1).
- **The duplicate-login kick under K2:** J2 returns `.kick`. K2 runs L1 to L3 as the kicked entry's leave flow, a tickless leave waiting on its record through `.awaitRecordTaken`. The kick's completion comes back to J3 as an input.
- **`.awaitRecordTaken`** needs a tracked request, or an equivalent lifecycle with abandonment. `turn.run` gives no `RequestID`, and K1b-2's holder is keyed by one.

### 4.6 Out of scope, named for the census

- `performInitialization` (:1433): K5. Only its output segment becomes a body (§2).
- The force shutdown and the drain (`runForceShutdown`, `shutdownIfIdle`, `drainAfterIdleCheck`): K7, and the land-stop drain's exception (#522).
- The destroy handlers (`runDestroyHandler`, `notifyTransportDestroyedAndRelease`): K7.

## 5. What crosses an await and isn't plain (survey §7.3)

| Value | Where | Carrier |
|---|---|---|
| `LandServices` | J1 to J4: the join's caller-supplied services. L1 to L2: the outgoing entry's snapshot | **values in the capture**, and in K2's effect. A key looked up after the removal would find nothing, or a newer entry's services (rev 2 was wrong here) |
| `LandContext` | J1→J2, J3→J4, L1→L2, A1→A2 | the resolver request carries it; only the outputs come back, as `[String: HeldResolverOutput]` |
| `ReevaluationTickRecord` | the record submit, in both drivers | `.awaitRecordTaken`'s effect, until #769 R2 makes the outputs bytes |
| `PlayerSession`, `JoinDecision` | J1→J4 | `Sendable` is enough for K2's inputs and effects. Each is marked `@PlainData` only when a stored model field needs it, which may be never |
| `JoinOutcome` | J4b → `.awaitInputTurn` → `.done` | the capture |
| `isReconnection` | J2→J3 | plain. Rev 2.2 (D1): it also counts a pending reservation, and the reservation, not a re-check, keeps the place across the kick (#862) |
| the rejoin reservation (`Epoch?`) | J2 → J3, and the driver's `defer` | plain; the capture carries it |

## 6. Commits

1. **`KeeperTurnSide` and `TurnOutputs`.** The side's methods and storage, the census paths updated, the re-entry sentinel (§3.5). No body changes yet.
2. **The bodies of §2,** each a `mutating` method with its staged outputs under §3.2's rule. `failLand` splits; its outside callers get their flush wrappers. Rev 2.3: #884 landed this half as actor methods over `inout KeeperModel`; 2b finishes it.
2b. **The move** (rev 2.3): every body and segment, part 2's (initialization, tick) and flows 1 and 2's included, becomes a `mutating` method on `KeeperModel` that takes the behavior and `inout KeeperTurnSide`, with D11–D14's rows. Stacked after #884, part 2 and flows 1+2; flows 3+4 (joins, leave) are written in this shape. A pure move: the same statements, the same staging order, every HoldPoints test green.
3. **The input drain and the tick driver** call the bodies.
4. **The action flow's requests and segments** (§4.4), and the worker.
5. **The client-event and server-input intakes** (§4.5).
6. **The joins** (§4.1, §4.2), with the admission split (§3.5).
7. **The leave** (§4.3).
8. **The replay driver** calls the bodies (§4.5).

Each commit:
- is a pure move: the same statements, in a named function, with the awaits moved to the driver;
- keeps every HoldPoints test green, because each hold stays at its position;
- runs the touched suites, with the full debug `swift test` before the push.

**Tests.**
- The existing interleaving suites pin each flow's order. A flow whose order no test pins gets one in its commit: hold at the await, run the competing input, release.
- **The record order:** a failing tickless pass with at least two distinct entries before the failure. The test asserts the four-step order of §3.2 and the tickless `endTurn` of a failure-only batch.
- **The re-entry path:** a recording-enabled supersede that reaches the admission's clear (TA:3977). It asserts the clear is recorded and `reentryViolationsForTesting` is zero.
- **The waiters:** a consumed caller stays parked at `.turnRecord` while a dropped-suffix caller gets `landClosed`.

**Mutants (cloud).** Each one names the observation that tells it apart from the correct code:
1. **J3 runs before the kick returns.** Hold the kicked entry's OnLeave resolver (or its tickless record completion), and assert that the replacement hasn't been inserted. The max-player test with empty holds covers another boundary.
2. **`TurnOutputs`' recorder Tasks flushed in reverse.** The record-order test above, with two distinct entries: a merged final frame hides a reversal.
3. **A callback reads `self.model` during a body.** Expected to trap, so cloud only, one case per process (K1b-4's M-4 pattern). The re-entry test above is its positive pair. **Rev 2.2 (D2): a Mac-observable form.** Move the admission back into the segment's body. The supersede's clear then hits the sentinel, and the land ends with `keeperReentry`. The re-entry test observes that (the land failed, `reentryViolationsForTesting == 1`) without a trap.
4. **`closeOutputs` staged instead of called.** A keeper-originated failure, on a port whose gate starts open. Observe the gate at a synchronous marker after the failure and before the driver's flush (`probe`). The existing teardown test observes after the segment, and the adapter already closes the gate on several failure paths, so it can't tell.
5. **`recorderSubmissionCount` incremented in the flush instead of inline.** The failure-only tickless batch loses its `endTurn`.

## 7. Measurement

The small A/B runs: K1b-4's cells (`rows-mp`, `wide-tickless-mp`), with the record mode stated for each cell. Base: K1b-5's merge base; head: the PR. It reports allocations per turn, and it confirms that a turn with nothing staged leaves `TurnOutputs`' arrays unallocated. Ordering correctness comes from the tests and the harness, not from these cells.

## 8. Decisions (Review on rev 2), and what's left open

1. **One `KeeperTurnSide` of methods, with writes staged**, as settled; the shared references are passed in and stay `nonisolated let` (§3.1).
2. **`TurnOutputs`** under §3.2's rule and guarantee. The emits and the in-turn sync stay synchronous through the side, at today's point.
3. **One enum per flow**, the action worker its own flow (§4.4); success and error continuations per request; direct paths stay direct (§4).
4. **The clock read stays where it is** (§3.1).
5. **`PlayerSession` and `JoinDecision`:** not marked (§5).
6. **The failure-ID counter** (`failureIDs`, an `EpochCounter`) is a model field, because K2 mints IDs in the step. The failure table itself stays on the actor. K1b-4's census row, which lists the counter among the actor-side tables, is corrected by K1b-5's census commit.

**Settled (rev 2.2, D2):** the re-entry sentinel's form. #865 ships neither rev 2.1's counted log nor a `precondition`. A refused re-entry ends the land in that turn, with `keeperReentry`. Nothing traps, and the refused call changes nothing.

## 9. The slice's size, and a proposed split

Rev 2.1 grows K1b-5 by the admission split (§3.5), the sentinel, the flush wrappers, and the per-row completions of §4. The draft-returning admission isn't brought forward: it stays in K2-1, so K1b-5 changes no `LandKeeperTransport` requirement and doesn't touch the Transport module. The slice is still large. **Proposal:** two PRs, each a pure move pinned by the same suites:
- **K1b-5a, the bodies:** commits 1–3 and 8. The side, `TurnOutputs`, the staging rule, the sentinel, the drivers, and replay.
- **K1b-5b, the segments:** commits 4–7. The request enums, the joins with the admission split, the leave, actions, events and inputs.

5b needs 5a. Each gets its own review round and its own mutants.

## Probes

Rev 2.2's points are about what the code contains, so the probes are the code at the two bases, quoted (grep and reading, unverified by the LSP). No Swift behavior is in question: the `defer` move (D1, D7) keeps the same statement on the same exits in the same async function, and the existing suites pin that.

- **D9, J4 has no generation re-check before the append** (K4, `joinReportingAdmission`; the same at 865:2308–2329):
  ```
  2186:        guard !isDraining else {
  2187:            if model.players[playerID]?.generation == entryGeneration {
  ...
  2191:            throw JoinError.landShuttingDown
  2192:        }
  2194:        let pendingItem = PendingItem.lifecycle(
  2208:        model.pendingItems.append(pendingItem)
  ```
- **D1, the reservation and its `defer`** (K4):
  ```
  2097:        let reservation = isReconnection ? model.rejoinReservationEpochs.next() : nil
  2098:        if let reservation { model.rejoinReservations[playerID, default: []].insert(reservation) }
  2099:        defer { if let reservation { endRejoinReservation(reservation, of: playerID) } }
  2101:        await holds.at(.join)
  2107:            try await leave(playerID: playerID, clientID: oldClientID, sessionID: existingSession.lastSessionID)
  2135:        if let reservation { endRejoinReservation(reservation, of: playerID) }
  ```
- **D2, the admission reaches a guarded entry:** `admitJoiningSessionIsolated` (TA:1984) → `admitJoining` → `applySessionPerPlayerPolicy` → `supersedeSessions` (TA:1935) → `recordSyncStreamClear` (TA:3981) → `keeper.assumeIsolated { $0.submitSyncStream([draft], outsideTurn: outsideTurn) }` (TA:3986). At 865, `submitSyncStream` begins with `guard bodyDepth == 0 else { noteReentry(through: "submitSyncStream") … }`.
- **D5:** `try Task.checkCancellation()` at K4:3379, after `let sequence = outputCollector.takeNextSequence()` (3369) and `let ticket = actionTicket(…)` (3370).
- **D6:** `let executors = resolvers.build((model.state, decodedAction), ValidateContext(ctx))` at K4:3360, and `decision = try canJoinHandler(model.state, session, ctx)` at K4:2060. K1b-4's SILGen probe of the same shape (an actor `var model: M`, then `build((model.state, 1), { })`) shows the model read through its getter (`apply … -> @owned M`). That access ends before `apply build`, and no `begin_access` spans the call. So nothing holds the model today. In K1b-5b the call sits inside a `mutating` method, whose `self` access spans it.
- **D8:** `if model.debugFrozen { model.serverInputsHeldWhileFrozen.append(item); return .accepted(sequence: sequence) }` at K4:3660–3663, before the append and `kickServerInputTurn` (3664–3665).
