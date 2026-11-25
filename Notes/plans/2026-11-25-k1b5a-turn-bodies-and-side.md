# K1b-5a: turn bodies on the model, the turn side, and the staging rule (#700)

**Status:** rev 2.1, plan only, for Review. Rev 2.1 corrects three §3.1 rows found by the LSP check of rev 2 (listed at the end of §3.1). This is the first half of K1b-5 (plan rev 2.1, `2026-11-25-k1b5-turn-bodies-and-segments.md`), split as that plan's §9 proposed and Main approved. K1b-5b, the segments, follows once this plan is GO, and its PR opens after this one merges.

**Base:** #853's head 5d53571a (K1b-3, on #835's K1a). Its `LandKeeper.swift` has the same line numbers as a87e0278, which K1b-4's rev 2.1 names. K1b-5a needs K1b-4.

**How the tables were checked.** Each table ends with a line saying what was checked against 5d53571a, and which rows weren't verified. Rev 1's rows were checked with the LSP (`findReferences`, `incomingCalls`, `goToDefinition`) and grep. **Rev 2's new rows were checked by grep** on 5d53571a's `LandKeeper.swift` and `TransportAdapter.swift`, each call site with its enclosing function, and **then with the LSP** on a fresh index of 5d53571a (rev 2.1). Each check line says which.

`LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift` and `TA` is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`, both at 5d53571a.

**From rev 1 (Review's NOT GO: 6 must-fix, 4 should, 1 nit):**
- MF1: one synchronous helper, `withModel`, owns each body call. Its `defer`s flush and lower the depth before any suspension (§2).
- MF2: a helper stages only into the outputs it is given, and every caller outside a body goes through `withModel` (§3.3).
- MF3: **a staged effect never crosses a direct call.** In K1b-5a every direct call flushes first, so today's order is kept for everything outside the actor (§3.2). The reorderings move to K2-1, which lists them (§8).
- MF4: the sentinel closes the gate when it fires, and the driver ends the land in the same segment (§3.6).
- MF5: replay calls named primitives, not "the same bodies" (§4).
- MF6: the mutants are restated with observations that tell them apart (§5).
- S1–S4 and the nits are in §3.1, §3.2, §3.6 and §5.

**What rev 1 already took from K1b-5 rev 2.1:**
- MF1: no teardown record step;
- MF4: borrow-safe routes, the mailbox read only, the flush on a throw, the alignment check after the flush;
- S1: the sentinel on the actor;
- S3, S4 and the nit.

## 1. Goal

After K1b-5a:
- **Every turn is a body.** A body is a `mutating` method on `KeeperModel` that takes the behavior, the turn side (§3.1) and the turn's outputs (§2).
- **The live drivers call the bodies:** the input drain, the live tick, the sync-only turn, the settle, the requested sync, and the shutdown between ticks.
- **Replay's drivers call shared synchronous primitives** (§4), not the live bodies.
- **K2-1's `handle` calls the live bodies, not copies** (a K2 condition from Review). That condition is about live turns only.

The async flows (join, leave, actions, client events, server inputs) are unchanged in K1b-5a. K1b-5b cuts them into segments.

**No behavior change,** for a precise reason (§3.2). Every effect that something outside the actor can see happens in today's order, because a staged effect is flushed before the next direct call. Only the body's own model writes move relative to the effects. While the body runs, nothing outside the actor can read the model: a resumed caller that calls back in waits for the actor. Each move is a refactor, pinned by the existing suites.

## 2. The turn bodies and `withModel`

| Body | Today (LK) | What stays in the driver after it |
|---|---|---|
| the tick turn | `runTickTurn` (:5033) | `finishTickTurn`'s record submit (:5140) |
| the input turn | `runInputTurn` (:6032) | `runInputDrain`'s record submit or tickless `endTurn` (:5993–5997), then `resumeInputTurnWaiters` (:5998) |
| the sync-only turn | `runSyncOnlyTurn` (:5412) | none |
| the settle | `settleTurn` (:1842) | none |
| the requested sync | `syncTurnNow` (:5605). It returns `runSyncOnlyTurn` (:5617), so its body calls the model's sync-only body directly, not the actor driver, which would borrow twice | none |
| the shutdown between ticks | `applyShutdownTurnBetweenTicks` (:3047): its synchronous apply, before its one await | the record submit |
| initialization's output segment | in `performInitialization` (:1433) | K5 owns the flow; K1b-5a only makes this segment a body |

*Checked against 5d53571a: each definition line by grep; the drivers' calls into the bodies by LSP `incomingCalls` (rev 1). `syncTurnNow` → `runSyncOnlyTurn` by grep (rev 2). Not verified: none.*

**`withModel` owns exactly one body call.** It is a synchronous method on the actor:

```swift
private func withModel<R>(_ step: (inout KeeperModel<State>, inout KeeperTurnSide, inout TurnOutputs) -> R) -> R {
    var outputs = TurnOutputs()
    let violationsBefore = reentryViolations
    defer {
        turnSide.flush(&outputs)                    // 2nd: consumes the outputs, so they flush once
        checkActionTables()                         // 3rd: K1b-2's alignment check (§3.4)
        if reentryViolations != violationsBefore {  // 4th: the sentinel fired (§3.6)
            withModel { m, side, out in m.applyPendingTransportFailure(side: &side, outputs: &out) }
        }
    }
    bodyDepth += 1
    defer { bodyDepth -= 1 }                        // 1st (LIFO): the depth drops before the flush
    return step(&model, &turnSide, &outputs)
}
```

- **The scope is the helper,** not the driver function. `runInputDrain` and `runTick` await after the body (`submitTurnRecord`, :5996 and :5141). A function-scoped `defer` there would flush after that await, and the ordinary draft would reach the recorder before the staged sync-stream drafts and the terminal entry. The flush and the check happen before `withModel` returns, so before the driver's next statement. (Review's lesson: a staging plan that flushes "in a `defer`" must name the scope.)
- **The depth is lowered in a `defer`,** so a throwing step can't leave it raised. A raised depth would make the sentinel fail every later legitimate adapter entry. The steps of §2 don't throw today. K1b-5b's throwing segments use `withModel`'s throwing overload, which has the same `defer`s.
- **The flush consumes the outputs,** so they flush exactly once, even when a step flushed part of them already (§3.2).
- **`TurnOutputs`** is a non-plain struct: **one ordered list of effects**, in the order the body staged them. Every count, position, index or decision those effects depend on is already in the model when they are staged (§3.2). A turn with nothing staged leaves the list unallocated.
- **The handler step.** K1b-4's `withHandlerStep(ctx) { m, ctx in … }` becomes a `mutating` method on the model. The body calls it on `self`, so the single access to the model is the body's own.

## 3. What a body reaches outside the model

### 3.1 `KeeperTurnSide`: methods, with writes staged

`KeeperTurnSide` is one non-plain struct, passed `inout` beside the model. Its fields are private, and a body reaches them only through its methods.
- **In K1b-5a it is a stored property on the actor,** `var turnSide`. It holds what a body, a shared helper or a flush touches:
  - `playerServices`;
  - the continuation tables: `inputTurnWaiters`, `shutdownTurnWaiters`, `actionSlotWaiters`, `debugHeldInputs` (:1037), `debugDrainWaiters` (:1041) and the test waiters;
  - K1b-2's `actionJobTasks` and K1b-2's failure table (`failures`);
  - `pendingSyncTurnAfterTurn` and `pendingFold`;
  - `drainTask`;
  - the recorder tracker's reference (`recorderSubmissions`, a `let` on the actor, :898);
  - a weak reference to the keeper, for the Tasks a flush starts. Each Task captures the keeper as today: weakly for the follow-up sync turns (:5450, 5478, 5636), strongly for the drain task (:5899).

  So a flush needs nothing but the side, and a body can flush in the middle (§3.2). K1b-5a updates K1b-4's census paths for these rows (`actor.X` → `turnSide.X`).
- **In K2-1** a step builds it locally from snapshots and binding tokens, and its writes become the step's outputs (K2 draft 2 §4.5). The methods keep their signatures; the flush points change (§8).
- **The shared references stay on the actor** as `nonisolated let`, and the side holds copies of the references: `drainFlag`, the `LandFailureMailbox`, the keeper's identity. Nonisolated code reads them today (`isDraining`, `destructionCause` and `failure` read `drainFlag`, :641–650; `notePendingFailure` writes the mailbox, :664), and moving them under an isolated `var` would cut that off.

| Method | Kind | Today (LK) |
|---|---|---|
| `services(for:generation:)` | read | `makeContext`'s player services (:3584) |
| `insertServices(…)`, `removeServices(…)` | staged | the joins' inserts and the leave's removal (K1b-5b) |
| `markFailedFirst(_:) -> Bool` | **direct** (flushes first): `drainFlag.setFailed`. K2 sets a model flag and stages the atomic set | `failLand` (:5847, the `setFailed` at :5870) |
| `setDrainCause(_:)` | **direct** (flushes first), `drainFlag.set(cause:)` | `completeShutdownTurn` (:5768), in a body; `shutdownIfIdle` (:6245), an outside caller in `withModel` (§3.3), where the write precedes the releases and cancellations as today |
| `closeOutputs(for:)` | **direct** (flushes first), on the binding token: the attached port, or else the bound requester, chosen at the call as today (:5896) | `failLand` (:5898) |
| `syncNowInTurn(…)`, `settleNowInTurn(…)` | **direct** (flush first), on the binding token: they return frames mid-turn | `runTurnOutputs` (:4951), `runSyncOnlyTurn` (:5427), `settleTurn` (:1868) |
| the keeper's other port calls | **direct** (flush first) | `refusesResolvedJoin` (:2288, in `refusesResolvedJoinInTurn`), `noteJoinInputsConsumed` (:2295), `hasJoinsAwaitingSync` (:2301, a property read in `transportHasJoinsAwaitingSync`), `runsSyncPhaseInTurn(of:)` (:832 `syncsInTurn`, :1857 the settle, :5574 `acceptsSyncTurn`, :5594 `syncTurnTicket`; :591 is a nonisolated static check outside the keeper's isolation), and the profiler hooks `noteInTurnJoinSyncTick` (:5106) and `noteInTurnSyncFold` (:5135) |
| `takeEmittedEvents(forTick:)`, `takeSyncRequest(…)` | read and drain, on the collector | the context closures keep the collector reference they capture before the step borrows the model (:3606) |
| `readPosition()` | **assembled by the model:** `lastCommittedTickId` and `passOrdinal` from the model, `nextSequence` through a side read of the collector | the position read |
| `takePendingFold()`, `now()` | read | `takePendingFold` (:5124) and the tick clock, at today's point (below) |
| `pendingTransportFailure() -> LandFailure?` | **read only**: the mailbox is set-once and has no clear (LandFailureMailbox.swift:21–25). A clear would change which failure wins | `applyInputs` (:4289), `applyPendingTransportFailure` (:5403) |
| `requestFollowUpSyncTurn(reason:)`, `scheduleJoinSyncTurn(…)`, `retryAfterWriterDrain(…)` | **the comparison, the slot and the count inline; only the Task launch staged.** Each writes its binding mark (`pendingSyncTurnAfterTurn`, `joinSyncTurnBinding`, `inTurnDrainRetryBinding`) and `beginRequestedSyncWork()` at the call, as today | `requestSyncTurnAfterThisTurn` (:5626), `scheduleJoinSyncTurn` (:5473), `retrySyncOnlyTurnAfterWriterDrain` (:5445), all reached from `applyInTurnSyncResult` (:4987, 4993, 5002) |
| `noteReplayRejected(sequence:)` | turn-local, then staged | `applyInputs` writes it and `takeReplayRejected` (:4460) reads it in the same turn. The body keeps it in a local that the turn's record reads, as today, and the side hands the list to `replay` after. Nothing on a live keeper |
| `recordFailure(_:) -> FailureID` | the ID from the model's counter; the error staged into the side's table | K1b-2's table |
| `takeWaiter(…)`, `takeHeldInputs()`, `takeDrainWaiters()` | the removal and the outcome inline; the resume staged | §3.5 |
| `cancelJob(_:)` | the mark, the outcome and the slot fill inline; then `task.cancel()`, a direct call | §3.5. `job.task?.cancel()` (:2736) is the only `cancel()` a K1b-5a body reaches. The joins' `destroyTask?.cancel()` (:1962, :2183) are in K1b-5b's segments, and are direct calls there |
| `probe(_:)` | **direct; flushes first when a hook is installed.** It must not call back into the keeper (§3.6) | `inTurnProbeForTesting` (:924 and the in-turn labels) |

*Checked against 5d53571a: every LK line by grep. With LSP (rev 1): `findReferences` on `pendingTransportFailure` (:654, 666, 670, 4289, 5403); `incomingCalls` on `failLand` and `completeShutdownTurn`. With LSP (rev 2.1): `findReferences` on `DrainFlag.setFailed` (:5870 only), `DrainFlag.set(cause:)` (:5768, 6245), `closeOutputs` (:5898 only), `refusesResolvedJoin`, `noteJoinInputsConsumed`, `hasJoinsAwaitingSync`, `runsSyncPhaseInTurn(of:)`, `noteInTurnSyncFold`, `noteInTurnJoinSyncTick` and `inTurnProbeForTesting` (the sites at :924 and the in-turn labels); `incomingCalls` on `scheduleJoinSyncTurn` (:4987), `requestSyncTurnAfterThisTurn` (:4993) and `retrySyncOnlyTurnAfterWriterDrain` (:5002), all from `applyInTurnSyncResult`, and on `runSyncOnlyTurn` (`syncTurnNow` at :5617 among six). The `cancel()` sites by grep, each with its enclosing function. The three Task launches by grep. The mailbox's lines by reading LandFailureMailbox.swift. Not verified: none.*

**Rev 2.1's corrections, from the LSP check:**
- `setDrainCause` has a second write, in `shutdownIfIdle` (:6245). Rev 2 listed only `completeShutdownTurn`'s.
- The other port calls' row now gives each call's line and enclosing function. Rev 2 said "as listed" with no lines.
- The `cancelJob` row now says :2736 is the only `cancel()` a K1b-5a body reaches.

**The clock read stays where it is.** The tick turn reads the time after it consumes the pending fold and checks `inTurnSyncDue`, the test override included. The body keeps that point through `side.now()`. Reading it earlier, in the driver, could change the reported duration or cross the strict `>` lateness threshold with no interleaving at all. K2's input timestamp is a stated behavior change at the cut-over, not part of K1b-5a.

### 3.2 Staged effects: the rule

**Rule 1: stage the effect, not its bookkeeping.** Every count, position, index or mark that later code in the same body reads is assigned at the original call site. Only the effect goes into `TurnOutputs`: the `Task` that submits, the continuation that resumes, the Task to start, the table write.

**Rule 2: a staged effect never crosses a direct call.** Every direct method of the side (§3.1: the drain-flag writes, `closeOutputs`, the port calls, `task.cancel()`, a probe with a hook) first flushes the staged effects. So everything outside the actor sees today's order:
- the recorder tracker's tail and pending count (ReevaluationRecorderService.swift:24–58);
- the resumed callers, which on the generic executor continue at once;
- the port and the outbound writer;
- the nonisolated readers of `drainFlag` and the mailbox.

What moves is only the body's own model writes, relative to the effects. Nothing outside the actor reads the model while the body runs.

**The flush order is the call order.** `TurnOutputs` is one list, so the flush applies the effects in the order they were staged, which is today's order. Review's S2 order follows from it.

For example, `failLand` (:5847–5907) today and in K1b-5a:

| # | Today | K1b-5a |
|---|---|---|
| 1 | `drainFlag.setFailed` | direct: the earlier staged effects flush first |
| 2 | the terminal entry's submit (:5886) | the count inline; the submit staged |
| 3 | `dropPendingInputs` (:5890): the waiters removed, then resumed with `landClosed` | removal and outcome inline; the resumes staged |
| 4 | `cancelAllActionJobs` (:5891): per job, the mark, the slot fill and its resume, `debugEndWork` and its drain waiters, then `task.cancel()` | per job: inline up to the cancel; `cancel()` is direct, so that job's resumes flush before it, as today (§3.5) |
| 5 | `releaseHeldInputsForDrain`, `resumeShutdownTurnWaiters` (:5892–5893) | staged resumes |
| 6 | `players.removeAll()` | model |
| 7 | `closeOutputs` (:5898) | direct: 2–5 flush first, so the terminal entry is submitted and the dropped callers resumed before the gate closes, as today |
| 8 | `drainTask = Task { … }` (:5899) | staged: the side installs the handle when it starts the Task |
| 9 | the drain-start waiters, then the failure waiters (:5904–5907) | staged after 8, so no waiter wakes before `drainTask` is installed |

**Today's record order for a failing tick or pass,** kept by Rules 1 and 2:
1. the sync-stream entries made earlier in the turn;
2. the terminal failure entry (`failLand`, :5886);
3. the turn's ordinary draft, or the tickless `endTurn`. The driver submits these after `withModel` returns (§3.3), so after the flush.

**Teardown records nothing.** It can attempt clears, but `submitSyncStream` refuses them before numbering or recording (:5278). Its gate checks `failure == nil` and that a recorder is present. The order test asserts that teardown adds no clear and advances no stream index (`TicklessPassOrdinalTests.swift:421–440` pins this for the initial-sync path today).

| Kind | Inline, at the original call site | Staged |
|---|---|---|
| a recorder submission (`enqueueRecorderSubmission`, :5333; `enqueueTicklessTurnEnd`, :5342) | the record materialized; `recorderSubmissionCount += 1` (a model field). The settle, the sync-only turn and the input drain compare it with a mark to decide on the tickless `endTurn` (:1847, 1865, 5416, 5426, 5991). A failure-only tickless batch has an empty ordinary draft, so a staged count would drop its only `endTurn` | `recorderSubmissions.submit { … }` |
| a sync-stream output (`recordSyncOutput`, :5293) | the stream index (`takeSyncStreamIndex`), the output cursor (`syncOutputIndexCursor`), the count | the submit |
| a sync-stream marker, a clear included (`recordSyncMarker`, :5318) | the marker position (`syncReadPosition`), the stream index, the count. A marker doesn't touch the output cursor | the submit |
| the gate on both (`submitSyncStream`, :5277) | `failure == nil` (through `drainFlag`) and a recorder present, before anything is numbered | — |
| the drain task (`failLand`, :5899) | the decision to drain | the `Task`, with its handle installed on the side as it starts |
| `playerServices`, the failure table, the follow-up sync Tasks | the binding marks and counts (§3.1) | the write, the launch |

*Checked against 5d53571a: the definitions by grep. With LSP (rev 1): `findReferences` on `recorderSubmissionCount` (:901, 1847, 1865, 5335, 5343, 5344, 5416, 5426, 5991). The `failLand` rows by reading :5847–5907 (rev 2). Not verified: none.*

### 3.3 Callers outside any body

**Rule: a helper stages only into the `TurnOutputs` it is given.** It takes `outputs: inout TurnOutputs`, so it can't be called without one. Every caller outside a body calls it inside `withModel`, which gives it a local list and flushes the list before returning. That covers each caller of a shared helper:

| Caller (LK) | Helper it calls |
|---|---|
| `failLandForTesting` (:5840) | `failLand` |
| `tearDownAfterFailedInitialization` (:1356) | `dropPendingInputs` |
| `runForceShutdown` (:2994) | `dropPendingInputs` |
| `shutdownIfIdle` (:6246, 6248, 6251) | `releaseHeldInputsForDrain`, `cancelAllActionJobs`, `resumeDrainStartedWaitersForTesting` |
| `drainAfterIdleCheck` (:6275) | `dropPendingInputs` |
| `completeAction` (:2585) | `fillActionSlot` (it reaches `debugEndWork` and its drain waiters) |
| `resumeInputTurnWaiters` (:6089), in the input drain's driver and in tickless replay | `fillActionSlot` |
| `leave` (:2861) | `cancelActionJobs(ofEntryGeneration:)` → `cancelActionJob` → `fillActionSlot` → `debugEndWork` |
| `submit` (:3146), `handleClientEvent` (:3419), `kickServerInputTurn` (:3532), `runTick` (:4548), the existing `debugEndWork` `defer`s included | `debugEndWork` |
| `processPendingActions` (:4175), `replayRecordedPasses` (:4366) | `applyInputs` (replay's W1, §4) |
| `submitTurnRecord` (:5376) | `enqueueRecorderSubmission`. `withModel` returns the submission's handle from the flush, and `submitTurnRecord` awaits it after the hold, as today |
| `runInputDrain` (:5996) | `enqueueTicklessTurnEnd` |
| the adapter-facing `submitSyncStream` (:5277), outside a turn | the sync-stream helpers (§3.6) |

**No driver-level submit bypasses staging.** `submitTurnRecord` and `runInputDrain`'s `endTurn` go through `withModel` like any other caller. They run after the body's `withModel` has returned, so their submissions come after the body's flushed ones.

**`withModel` from an outside caller raises `bodyDepth`** like a body does: it borrows the model, so a re-entry during it would trap the same way. None of these callers makes a port call that calls back (§3.6). `task.cancel()` runs only the two handlers of §3.5.

The shutdown path doesn't call `failLand`: `completeShutdownTurn` (:5761) is reached from the input turn's apply (:4285), inside a body.

*Checked against 5d53571a: rev 1's rows by LSP `incomingCalls` on `failLand`, `dropPendingInputs`, `cancelAllActionJobs`, `releaseHeldInputsForDrain`, `resumeDrainStartedWaitersForTesting` and `completeShutdownTurn`. Rev 2's rows by grep, then by LSP `incomingCalls` (rev 2.1), with the same result: `fillActionSlot` (:2585, 2735, 5941, 6089), `cancelActionJobs` (:2861, from `leave` only), `debugEndWork` (:2657, 3146, 3419, 3532, 4548), `applyInputs` (:3054, 4175, 4366, 5051, 6041), `enqueueRecorderSubmission` (:5306, 5324, 5376, 5886), `enqueueTicklessTurnEnd` (:1849, 1889, 5420, 5432, 5996), `resumeInputTurnWaiters` (:4410 in tickless replay, :5998 in the input drain). Not verified: none.*

### 3.4 The alignment check

K1b-2's `actionTableViolations()` compares the IDs the model holds with the failure table's entries. Between a body's `recordFailure` and the flush, the model has the ID and the table doesn't have the error yet, so the two disagree on purpose.
- The check runs in `withModel`, **after its final flush**, before any suspension. So it runs on every path: each driver, `runTick` included, and every caller of §3.3.
- It doesn't run at a flush in the middle of a body (Rule 2), because the model is still borrowed there.
- K1b-5a moves K1b-2's call sites into `withModel`.

### 3.5 Waiters and job cancellation

- **One rule for every waiter.** The removal and the outcome stay inline, at today's decision point; only the `resume` is staged. Rule 2 flushes the resume before the next direct call. This covers:
  - `inputTurnWaiters` (`dropPendingInputs`, :5937) and `shutdownTurnWaiters` (:5914);
  - `actionSlotWaiters` (`fillActionSlot`, :2655);
  - `debugHeldInputs` (`releaseHeldInputsForDrain`, :5746);
  - `debugDrainWaiters` (`debugEndWork`, :1909), including when they are reached through `fillActionSlot` under a job cancellation;
  - the test waiters.

  The side's `take…` methods return the removed continuations with their outcomes for the flush.
- **Job cancellation** (`cancelActionJob`, :2723):
  1. it reads the job, marks it, and builds the outcome;
  2. it fills the slot inline, which stages the slot waiter's resume and, through `debugEndWork`, the drain waiters' resumes;
  3. it calls `cancel()` (:2736; K1b-2 moves the handle to `actionJobTasks`). That is a direct call, so step 2's resumes flush before it.

  So the order is today's: the slot's caller is resumed, then the task is cancelled. `failLand` reaches it through `cancelAllActionJobs` (:5891), and the leave through `cancelActionJobs(ofEntryGeneration:)` (:2861).
- **The cancellation handlers that `cancel()` can run synchronously:**
  - `awaitActionResult`'s `onCancel` sets the caller's flag and cancels the task. It touches no keeper state.
  - `ResolverExecutor`'s handler (ResolverExecutor.swift:191–205) settles its race, updates the abandonment's bookkeeping and cancels the resolver task. The keeper's cleanup comes later, through an async hop (`releaseCompletedActionJob`).
- **The bound sync requester stays weak**, and the choice between the attached port and the bound port is still made at failure time (:5896).

*Checked against 5d53571a with LSP (rev 1): `incomingCalls` on `fillActionSlot`, `debugEndWork` and `cancelActionJob` (:2710, 2717). By grep (rev 2): `cancelActionJob`'s body (:2723–2737). The handler by reading ResolverExecutor.swift. Not verified: none.*

### 3.6 Synchronous re-entry: the audit and the sentinel

A port call the keeper makes during a body can call back into it synchronously. While the body holds `&model`, a callback that reads or writes the model traps. `assumeIsolated` passes its executor check, because the executor is the same.

**Every `assumeIsolated` in `Sources/`:** six in `TransportAdapter+LandKeeperTransport.swift`, the adapter entering its own isolation (lines 36–102), and three in TA, the adapter entering the keeper's.

| Site | What it does | Reached from a body? |
|---|---|---|
| TA:3822 `keeper.assumeIsolated { $0.recordsSyncStream }` | reads `behavior.config.mode`, `reevaluationRecorder` and `syncsInTurn`. After K1b-4 none of these is in the model | yes, through the admission. No trap: it reads no model field |
| TA:3850 `keeper.assumeIsolated { $0.submitSyncStream(drafts) }`, in `recordSyncStream`'s `defer` | writes the stream index, the cursor and `recorderSubmissionCount`: model fields | **no, by an invariant.** It runs only for `.legacyCycle`, and an in-turn recording's kind is only `.tick` or `.syncOnly` (`inTurnSyncTurnKind`, :535, 1863, 5424). `.legacyCycle` comes only from `_syncStateForNewPlayer`, the adapter's standalone initial sync |
| TA:3977 `keeper.assumeIsolated { $0.submitSyncStream([draft], outsideTurn:) }`, in `recordSyncStreamClear` | writes the same model fields | **yes: the trap,** through the join admission. K1b-5b moves the admission between two halves of the join segment, with the borrows released |

**The path to TA:3977:** `admitJoiningSessionIsolated` → `admitJoining` (TA:1735) → `applySessionPerPlayerPolicy` (TA:1567) → `supersedeSessions` (TA:1957) → `recordSyncStreamClear`. The other callers in that chain are the adapter's own flows, not keeper bodies: `performJoinQueued`, `registerSessionCheckingKeeper`, and `handleDisconnectQueued` (TA:1353, for the clear itself).

**The path to TA:3850:** `recordSyncStream` ← `commitSyncPhase` (TA:4195) ← `runSyncPhase` (TA:3769) ← `runFullSyncPhase` (the in-turn phase and the settle) or `_syncStateForNewPlayer` (TA:5283, `.legacyCycle`).

**The keeper's other synchronous calls into the adapter** don't call back: `refusesResolvedJoin`, `noteJoinInputsConsumed`, `hasJoinsAwaitingSync`, `runsSyncPhaseInTurn(of:)`, `closeOutputs`, and the profiler's three.

**The adapter's synchronous uses of the keeper** don't touch the model. `isDraining`, `destructionCause`, `failure`, `isLive` and `hasPeriodicSync` read `drainFlag` or `behavior`. `notePendingFailure` writes the mailbox (§3.1).

**Closures a body runs:** the handler context's closures capture the collector reference and `serverInputSubmitter`. The submitter hops to the keeper asynchronously. `ResolverContext` takes the state by value. None of them reaches the model.

*Checked against 5d53571a with LSP (rev 1): `findReferences` on `submitSyncStream` (in the keeper :1873, 4957, 5428; outside it TA:3850 and TA:3977 only) and on `recordsSyncStream` (in Sources, outside the keeper, TA:3822 only); `incomingCalls` along both paths. Review confirmed that all three legitimate adapter entries run at depth zero. Not verified: none.*

**The sentinel.** The audit is a list, and a future port call can add a path to it.
- **Where it lives.** `bodyDepth` and `reentryViolations` are stored on the actor, outside the model and the side. A counter in the model would trap inside the guard itself. `withModel` raises `bodyDepth` around each step (§2).
- **What it guards.** Only the adapter-facing entry. Today the bodies call the same package `submitSyncStream`:
  - :1873 in the settle;
  - :4957 in `runTurnOutputs`;
  - :5428 in the sync-only turn.

  K1b-5a splits it. The bodies call a model helper through their binding. The package entry that the adapter calls checks `bodyDepth`, and at depth zero it calls that helper inside `withModel`.
- **On a violation it fails fast,** as the adapter's own failure path does (TA:5666–5685). In the same call, the entry:
  1. posts a `LandFailure` to the set-once mailbox (nonisolated, no model write);
  2. closes the output gate: `(transport ?? boundSyncRequester)?.closeOutputs(for:)`, the same choice as `failLand`'s. These are actor properties, not model fields. `closeOutputs` is nonisolated on a locked gate (`LandOutputGate`), so calling it while the adapter's own call is on the stack is safe;
  3. logs the violation and counts it in `reentryViolations`.

  It doesn't touch the model, so the draft is not recorded.
- **The land ends in the same segment.** After the flush, `withModel` sees that `reentryViolations` grew. It then applies the mailbox's failure (`applyPendingTransportFailure` → `failLand`) in a nested `withModel`, before returning.
  - That doesn't wait for a later step. The mailbox is otherwise read only before a turn's sync and settle phases (:1848, 4947, 5419), not after them. So on an idle tickless land, a violation inside a requested sync-only turn's port call would otherwise return `.committed` and never take another step.
  - If an earlier failure already holds the mailbox, `failLand`'s first-cause rule keeps that one, and the violation is still counted and logged.
- **The failure's kind** is `.keeperReentry` (approved by the maintainer; §7).

## 4. The drivers

| Driver | Sequence |
|---|---|
| **the input drain** (`runInputDrain`, :5986) | the mark; `withModel` { the input-turn body }; then `submitTurnRecord` (its enqueue in `withModel`) or `withModel` { `enqueueTicklessTurnEnd(since: mark)` }; then `withModel` { `resumeInputTurnWaiters` }; then `Task.yield()`. The record draft isn't plain: `ReevaluationRecordedResolverOutput.value` is `AnyCodable` (ActionRecorder.swift:10) |
| **the live tick** (`runTick`'s turn branch, :4598) | `withModel` { the tick-turn body }; then `finishTickTurn`'s submit (:5140) |
| **the sync loop** (`runSync`, :6133) | its fold decision writes the model outside a turn (K1b-4 §4.3's exception), then awaits the transport only on its replay branch. Unchanged until K2's `.syncDue` step |
| **tick replay** (`runTick`'s non-turn branch, :4812–4890) | 1. `withModel` { W1's restore and `applyInputs` (:4175) }; 2. the suspensions: `.turnRecord` (:4179), the recorder's `record` and `flushIfNeeded`, the broadcast-only sync; 3. the rejected-divergence check; 4. the `replayFailureEnd` cutoff (:4839–4848): `withModel` { the commit, the event and sync-request drop }, then return; 5. `withModel` { W2's restore (:4859), then the handler step unless `shutdownTurnApplied` (:4866), then `lastCommittedTickId` }; 6. the state hash; 7. the legacy sink flush (`flushOutputs`, :4890); 8. the frame's record |
| **tickless replay** (`replayRecordedPasses`, :4314) | 1. `withModel` { the initialize items' `applyInputs` (:4366) }; 2. per pass: `withModel` { the restore and the input-turn body with `removingFromQueue: false` (:4390), the rejected comparison, and the failure pass's event suppression (:4399–4401) }; 3. the record submit; 4. `withModel` { `resumeInputTurnWaiters` }; 5. the sink flush after each pass (:4413); 6. the pass observer |

**The shared primitives** that replay calls, all synchronous model methods:
- the input apply, `applyInputs`;
- the handler step, `withHandlerStep`;
- the input-turn body with `removingFromQueue: false`.

Tick replay can't call the live tick body: its W1 apply and its handler step are separated by suspensions, as listed above. K2-1's "handle calls the same bodies" applies to live turns only. Replay keeps its own drivers until #612.

*Checked against 5d53571a: the replay lines by grep and by reading :4172–4215, :4314–4420 and :4805–4895 (rev 2). With LSP (rev 2.1): `incomingCalls` on `applyInputs` (:4175 in `processPendingActions`, :4366 in `replayRecordedPasses`) and on `resumeInputTurnWaiters` (:4410). Not verified: none.*

## 5. Commits, tests, mutants

**Commits:**
1. **`KeeperTurnSide`, `TurnOutputs` and `withModel`.** The side's methods and storage, the flush, the census paths updated, the sentinel. No body changes yet.
2. **The bodies of §2,** each a `mutating` method staging under §3.2's rules. `failLand` splits, and the callers of §3.3 go through `withModel`.
3. **The input drain and the tick driver** call the bodies through `withModel`; the alignment check moves into `withModel` (§3.4).
4. **The replay drivers** call the primitives (§4).

Each commit:
- is a pure move: the same statements, in a named function;
- keeps every HoldPoints test green;
- runs the touched suites, with the full debug `swift test` before the push.

**A test recorder service** records an ordered trace of the keeper's submissions: each `recordTick` with its entry's kind and identity, and each `endTurn`. Several tests below use it.

**Tests:**
1. **The record order.** A tickless land and a stub port. In one sync phase the port returns two distinguishable sync-stream drafts together with a failure. The production adapter's failing plan returns `.landFailed` from its `catch` before it records anything (TA:2933–2948), which is why the stub is needed. The trace must read: draft 1, draft 2, the terminal entry, then `endTurn`. Teardown adds nothing to the trace and advances no stream index. A failure-only tickless batch's trace ends with its `endTurn`.
2. **The waiters at `.turnRecord`.** A consumed caller stays parked at `.turnRecord` while a dropped-suffix caller gets `landClosed`. Each is resumed exactly once.
3. **The sentinel, on an idle land.** An otherwise idle tickless land and a requested sync-only turn whose port calls the adapter-facing `submitSyncStream` during the turn. Without driving another turn, assert:
   - the land has a terminal failure of kind `.keeperReentry`;
   - the gate is closed;
   - `reentryViolations` is 1;
   - the model's stream index didn't move.
4. **The three legitimate entries at depth zero** (S1), each recorded with no violation:
   - the standalone `.legacyCycle` commit (TA:3850);
   - the disconnect clear (`outsideTurn: true`);
   - the supersede clear (`outsideTurn: false`, at K1b-5b's position between the halves).

   The `outsideTurn` flag decides the tickless record closure independently of `bodyDepth`. SyncStreamLeaveReplayTests.swift:191–230 already covers the placement.
5. **A throw.** A test-only step that stages a counted effect and throws, inside `withModel`. Afterwards:
   - the effect ran exactly once;
   - an outer `catch` sees it applied;
   - `bodyDepth` is 0;
   - a following adapter `submitSyncStream` succeeds.
6. **A probe sees today's state.** At the tickless sync-only turn's `turn-end` probe, with a hook installed, the probe reads the recorder tracker's submitted count and the gate. The count includes the turn's sync-stream submissions. After a failure in that turn, the gate is closed and the dropped callers have been resumed.

**Mutants (cloud).** Each names the observation that tells it apart from the correct code:
1. **The flush applies the list in reverse.** Test 1's trace shows draft 2 before draft 1. A merged frame couldn't show this, because stream indices are assigned inline and `stream(of:)` sorts by them; the trace can.
2. **A direct call doesn't flush first** (the probe's flush removed). Test 6's count is short by the turn's sync-stream submissions. A staged `closeOutputs` (rev 1's M2) is an equivalent mutant in K1b-5a: Rule 2 flushes it before any later direct call, a probe included. It is K2-1's mutant (§8).
3. **`recorderSubmissionCount` incremented in the flush instead of inline.** Tickless, a recorder, no probe hook. In the sync-only turn, between `submitSyncStream` (:5428) and `enqueueTicklessTurnEnd(since: mark)` (:5432), there is no direct call on a committed result. So the count compare inside the body sees no change, and the turn's `endTurn` is missing from the trace before save or finalization.
4. **The flush not in `withModel`'s `defer`.** Test 5: the counted effect is lost on the throw.
5. **The depth not lowered in a `defer`.** Test 5's following `submitSyncStream` trips the sentinel.
6. **A callback reads the model during a body.** Expected to trap, so cloud only, one case per process (K1b-4's M-4 pattern). Its positive pair is test 4's supersede clear.
7. **The sentinel's guard kept, but its gate close or its mailbox post removed** (a non-trapping negative control). The sentinel test enters only through the guard. Test 3 fails: the gate stays open, or the land doesn't fail.

## 6. Measurement

The small A/B runs K1b-4's cells (`rows-mp`, `wide-tickless-mp`), with the record mode stated for each cell. The base is K1b-5a's merge base and the head is the PR. It reports allocations per turn, and confirms that a turn with nothing staged leaves `TurnOutputs`' list unallocated. Ordering correctness comes from the tests, not from these cells.

## 7. Public API and open points

**Public API:**
- **Addition: `LandFailure.Kind.keeperReentry`.** Approved by the maintainer (standing rule since 2026-11-11: a new public `LandFailure.Kind` case needs no ask). Two consequences go in the PR's Public API line:
  - **Source:** an exhaustive `switch` over `LandFailure.Kind` outside the package stops compiling until it handles the new case.
  - **Records:** `LandFailure.Kind` is a `String`-backed `Codable` enum. A record whose terminal entry has this kind fails to decode in a reader built before this change. Such a record exists only when the sentinel fired.

**Open:**
1. **The failure-ID counter** (`failureIDs`, an `EpochCounter`) is a model field, because K2 mints IDs in the step. The failure table moves to the side (§3.1). K1b-5a's census commit corrects K1b-4's row, which lists the counter among the actor-side tables.

## 8. The K2 handoff

In K2-1 the step's outputs flush after the step, not before each direct call. K2-1 lists each reordering as a behavior change and keeps or removes it with a test. The ones known now:
- **`failLand`:** the terminal entry's submit and the dropped callers' resumes move after the synchronous `closeOutputs`. Off-executor callers continue as soon as they are resumed, so this is observable.
- **`completeShutdownTurn`:** the dropped callers' resumes move after `drainFlag.set(cause:)`.
- **Job cancellation:** the slot's resume moves after `cancel()`.
- **Mutant 2's staged `closeOutputs`** becomes a live mutant there: K2 draft 2's reason for a direct close.
