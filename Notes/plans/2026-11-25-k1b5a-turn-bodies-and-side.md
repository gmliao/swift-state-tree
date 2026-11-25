# K1b-5a: turn bodies on the model, the turn side, and the staging rule (#700)

**Status:** rev 1, plan only, for Review. This is the first half of K1b-5 (plan rev 2.1, `2026-11-25-k1b5-turn-bodies-and-segments.md`), split as that plan's §9 proposed and Main approved. K1b-5b, the segments, follows once this plan is GO, and its PR opens after this one merges.

**Base:** #853's head 5d53571a (K1b-3, on #835's K1a). Its `LandKeeper.swift` has the same line numbers as a87e0278, which K1b-4's rev 2.1 names. K1b-5a needs K1b-4.

**How the tables were checked.** Each table below ends with a line saying what was checked, against 5d53571a, with the LSP (`findReferences`, `incomingCalls`, `goToDefinition`) and grep, and which rows weren't verified.

`LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift` and `TA` is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`, both at 5d53571a.

**From K1b-5 rev 2.1 (Review's NOT GO, 4 must-fix, 5 should, 1 nit), what this half takes:**
- MF1: there is no teardown record step. A failing turn's order is three steps, and teardown records nothing (§3.2).
- MF4: every inline operation has a borrow-safe route through the side (§3.1). The mailbox is read, never cleared. Staged outputs flush on a throw (§2). The alignment check runs after the flush (§3.4).
- S1: the sentinel is on the actor, guards only the adapter-facing entry, and fails fast through the mailbox (§3.6).
- S3: the full list of callers outside a body (§3.3).
- S4: the wording on the mailbox and on the resolver cancellation handler (§3.5, §3.6).
- The nit: a clear is a marker (§3.2).
- MF2 and MF3 are about the join and action tables. Those are K1b-5b's.

## 1. Goal

After K1b-5a:
- **Every turn is a body.** A body is a `mutating` method on `KeeperModel` that takes the behavior, the turn side (§3.1) and the turn's outputs (§2).
- **The drivers call the bodies:** the input drain, the live tick, the sync-only turn, the settle, the requested sync, and the shutdown between ticks. **Replay's driver calls the same bodies** on its own model (§4).
- **K2-1's `handle` calls these same bodies, not copies** (a K2 condition from Review).

The async flows (join, leave, actions, client events, server inputs) are unchanged in K1b-5a. K1b-5b cuts them into segments.

**No behavior change.** Each move is a refactor, pinned by the existing suites.

## 2. The turn bodies

| Body | Today (LK) | What stays in the driver after it |
|---|---|---|
| the tick turn | `runTickTurn` (:5033) | `finishTickTurn`'s record submit (:5140) |
| the input turn | `runInputTurn` (:6032) | `runInputDrain`'s record submit or tickless `endTurn` (:5986–5998), then `resumeInputTurnWaiters` (:6085) |
| the sync-only turn | `runSyncOnlyTurn` (:5412) | none |
| the settle | `settleTurn` (:1842) | none |
| the requested sync | `syncTurnNow` (:5605) | none |
| the shutdown between ticks | `applyShutdownTurnBetweenTicks` (:3047): its synchronous apply, before its one await | the record submit |
| initialization's output segment | in `performInitialization` (:1433) | K5 owns the flow; K1b-5a only makes this segment a body |

*Checked against 5d53571a: each definition line by grep; the drivers' calls into the bodies by LSP `incomingCalls` (`failLand`'s five callers include `settleTurn`, `applyInputs`, `applyInTurnSyncResult` and `applyPendingTransportFailure`). Not verified: none.*

```swift
extension KeeperModel {
    mutating func applyTickTurn(_ input: TickTurnInput, behavior: KeeperBehavior<State>,
                                side: inout KeeperTurnSide, outputs: inout TurnOutputs)
}

// The driver, on the actor:
var outputs = TurnOutputs()
defer { flush(&outputs) }            // also on a throw: no staged effect is dropped
bodyDepth += 1
model.applyTickTurn(input, behavior: behavior, side: &turnSide, outputs: &outputs)
bodyDepth -= 1
```

- **`TurnOutputs`** is a non-plain struct, owned by the driver and passed `inout`. It holds the staged effects only: the recorder Tasks to submit, in order; the continuations to resume, with their outcomes; the tasks to start; the `playerServices` inserts and removals; the follow-up sync request; the errors to put in the failure table. Every count, position, index or decision those effects depend on is already in the model when the body returns (§3.2).
- **Flushed in a `defer`** in the driver, before the segment's first suspension, so a throwing body or segment still flushes what it staged. The bodies of §2 don't throw today. K1b-5b's throwing segments (the OnJoin and OnLeave error paths, the drain rollbacks) stage a services removal or a destroy schedule and then throw, and the `defer` keeps those.
- **The handler step.** K1b-4's `withHandlerStep(ctx) { m, ctx in … }` becomes a `mutating` method on the model. The body calls it on `self`, so the single access to the model is the body's own.

## 3. What a body reaches outside the model

### 3.1 `KeeperTurnSide`: methods, with writes staged

`KeeperTurnSide` is one non-plain struct, passed `inout` beside the model. Its fields are private, and a body reaches them only through its methods.
- **In K1b-5a** it is a stored property on the actor, `var turnSide`. It holds the actor-side tables that a body or a shared helper touches inline: `playerServices`; the continuation tables `inputTurnWaiters`, `shutdownTurnWaiters`, `actionSlotWaiters`, `debugHeldInputs` (:1037), `debugDrainWaiters` (:1041) and the test waiters; K1b-2's `actionJobTasks`; and `pendingSyncTurnAfterTurn` and `pendingFold`. K1b-5a updates K1b-4's census paths for these rows (`actor.X` → `turnSide.X`).
- **In K2-1** a step builds it locally from snapshots and binding tokens, and its writes become the step's outputs (K2 draft 2 §4.5). The methods keep their signatures.
- **The shared references stay on the actor** as `nonisolated let`, and the side holds copies of the references: `drainFlag`, the `LandFailureMailbox`, the keeper's identity. Nonisolated code reads them today (`isDraining`, `destructionCause` and `failure` read `drainFlag`, :641–650; `notePendingFailure` writes the mailbox, :664), and moving them under an isolated `var` would cut that off.

| Method | Kind | Today (LK) |
|---|---|---|
| `services(for:generation:)` | read | `makeContext`'s player services (:3584) |
| `insertServices(…)`, `removeServices(…)` | staged | the joins' inserts and the leave's removal (K1b-5b) |
| `markFailedFirst(_:) -> Bool` | direct: K1b-5a calls `drainFlag.setFailed`. K2 sets a model flag and stages the atomic set | `failLand` (:5847, the `setFailed` at :5870) |
| `setDrainCause(_:)` | direct, `drainFlag.set(cause:)` | `completeShutdownTurn` (:5761) |
| `closeOutputs(for:)` | **direct, on the binding token** (the attached port, or else the bound requester, chosen at the call as today, :5896) | `failLand` (:5898). In K2 the in-turn sync sends frames during the step and the emits flush after it, so a staged close would let a later direct frame out before the gate closes |
| `syncNowInTurn(…)`, `settleNowInTurn(…)` | **direct, on the binding token** | `applyInTurnSyncResult` (:4971), `runTurnOutputs` (:4939), `settleTurn` (:1868): they return frames mid-turn |
| `takeEmittedEvents(forTick:)`, `takeSyncRequest(…)`, `readPosition()` | read and drain, on the collector | the context closures keep the collector reference they capture before the step borrows the model (:3606) |
| `takePendingFold()`, `now()` | read | `takePendingFold` (:5124) and the tick clock, at today's point (below) |
| `pendingTransportFailure() -> LandFailure?` | **read only**: the mailbox is set-once and has no clear (LandFailureMailbox.swift:21–25). A clear would change which failure wins | `applyInputs` (:4289), `applyPendingTransportFailure` (:5403) |
| `requestFollowUpSyncTurn(reason:)` | staged | `requestSyncTurnAfterThisTurn` (:5626) |
| `noteReplayRejected(sequence:)` | turn-local, then staged | `applyInputs` writes it and `takeReplayRejected` (:4460) reads it in the same turn. The body keeps it in a local that the turn's record reads, as today, and the side hands the list to `replay` after. Nothing on a live keeper |
| `recordFailure(_:) -> FailureID` | the ID from the model's counter; the error staged into the table | K1b-2's table |
| `takeWaiter(…)`, `takeHeldInputs()`, `takeDrainWaiters()` | the removal inline; the resume staged | §3.5 |
| `cancelJob(_:)` | **one ordered inline operation** | §3.5 |
| `probe(_:)` | direct | `inTurnProbeForTesting`. It must not call back into the keeper (§3.6) |

*Checked against 5d53571a: every LK line by grep. With LSP: `findReferences` on `pendingTransportFailure` (:654, 666, 670, 4289, 5403), `incomingCalls` on `failLand` and `completeShutdownTurn`. The mailbox's lines by reading LandFailureMailbox.swift. Not verified: none.*

**The clock read stays where it is.** The tick turn reads the time after it consumes the pending fold and checks `inTurnSyncDue`, the test override included. The body keeps that point through `side.now()`. Reading it earlier, in the driver, could change the reported duration or cross the strict `>` lateness threshold with no interleaving at all. K2's input timestamp is a stated behavior change at the cut-over, not part of K1b-5a.

### 3.2 Staged effects: the rule

**Rule: stage the effect, not its bookkeeping.** Every count, position, index or mark that later code in the same segment reads is assigned at the original call site, inside the body. Only the effect, the `Task` that submits or the continuation that resumes, goes into `TurnOutputs`.

| Kind | Inline, at the original call site | Staged |
|---|---|---|
| a recorder submission (`enqueueRecorderSubmission`, :5333; `enqueueTicklessTurnEnd`, :5342) | the record materialized; `recorderSubmissionCount += 1` (a model field). The settle, the sync-only turn and the input drain compare it with a mark to decide on the tickless `endTurn` (:1847, 1865, 5416, 5426, 5991). A failure-only tickless batch has an empty ordinary draft, so a staged count would drop its only `endTurn` | `recorderSubmissions.submit { … }` |
| a sync-stream output (`recordSyncOutput`, :5293) | the stream index (`takeSyncStreamIndex`), the output cursor (`syncOutputIndexCursor`), the count | the submit |
| a sync-stream marker, a clear included (`recordSyncMarker`, :5318) | the marker position (`syncReadPosition`), the stream index, the count. A marker doesn't touch the output cursor | the submit |
| the gate on both (`submitSyncStream`, :5277) | `failure == nil`, read through `drainFlag`, before anything is numbered | — |
| the drain task (`failLand`, :5899) | the decision to drain | the `Task`. Its handle is installed before any drain-start waiter is signalled |
| `playerServices`, the follow-up sync turn | nothing later in the segment reads them | the write |

*Checked against 5d53571a: the definitions by grep. With LSP: `findReferences` on `recorderSubmissionCount` (:901, 1847, 1865, 5335, 5343, 5344, 5416, 5426, 5991). Not verified: none.*

**Today's record order for a failing tick or pass,** kept by staging in call order:
1. the sync-stream entries made earlier in the turn;
2. the terminal failure entry (`failLand`, :5886);
3. the turn's ordinary draft, or the tickless `endTurn`.

**Teardown records nothing.** It can attempt clears, but `submitSyncStream` refuses them before numbering or recording once the failure gate is set (:5278). The order test asserts that teardown adds no clear and advances no stream index (`TicklessPassOrdinalTests.swift:421–440` pins this for the initial-sync path today).

**What staging guarantees.** A resumed continuation does not always wait for the actor: a caller on the generic executor continues at once. The adapter's waiters share the keeper's executor, so they wait. The guarantee is narrower:
- the body's statements after a staged effect don't depend on it having happened;
- the drain handle is installed before any drain-start waiter is signalled;
- the flush happens before the segment's first suspension, so no keeper code runs between the body and its effects.

**Observers off the keeper,** which see an effect only once it is flushed:
- the recorder tracker's tail and pending count, read by the flush waiters and the tests;
- the outbound writer, which gets the in-turn sync's frames directly, never through a staged effect;
- the nonisolated readers of `drainFlag` and the mailbox, which are written directly.

### 3.3 Callers outside any body

These call a shared helper that stages, so each one builds its own `TurnOutputs`, calls the helper, and flushes:

| Caller (LK) | Helpers it calls |
|---|---|
| `failLandForTesting` (:5839) | `failLand` |
| `tearDownAfterFailedInitialization` (:1354) | `dropPendingInputs` (:1356) |
| `runForceShutdown` (:2988) | `dropPendingInputs` (:2994) |
| `shutdownIfIdle` (:6236) | `releaseHeldInputsForDrain` (:6246), `cancelAllActionJobs` (:6248), `resumeDrainStartedWaitersForTesting` (:6251) |
| `drainAfterIdleCheck` (:6259) | `dropPendingInputs` (:6275) |
| the adapter-facing `submitSyncStream` (:5277), outside a turn | the sync-stream helpers |

The shutdown path doesn't call `failLand`: `completeShutdownTurn` (:5761) is reached from the input turn's apply (:4285), inside a body.

*Checked against 5d53571a with LSP: `incomingCalls` on `failLand`, `dropPendingInputs`, `cancelAllActionJobs`, `releaseHeldInputsForDrain`, `resumeDrainStartedWaitersForTesting` and `completeShutdownTurn`. Not verified: none.*

### 3.4 The alignment check

K1b-2's `actionTableViolations()` compares the IDs the model holds with the failure table's entries. Between a body's `recordFailure` and the flush, the model has the ID and the table doesn't have the error yet, so the two disagree on purpose. So the check runs in the driver **after the flush**, once per body, and not inside the helpers as K1b-2 places it. K1b-5a moves K1b-2's call sites there.

### 3.5 Waiters and job cancellation

- **A waiter's removal and its outcome stay inline**, at today's decision point. Only `resume` is staged. This covers `inputTurnWaiters` (`dropPendingInputs`, :5937), `shutdownTurnWaiters` (:5914), `actionSlotWaiters` (`fillActionSlot`, :2655), `debugHeldInputs` (`releaseHeldInputsForDrain`, :5746), `debugDrainWaiters` (`debugEndWork`, :1909, reached through `fillActionSlot`), and the test waiters. The side's `take…` methods return the removed continuations with their outcomes for the flush.
- **Action cancellation is one ordered operation.** `cancelActionJob` (:2723) reads the job's handle (the `cancel()` is at :2736; K1b-2 moves the handle to `actionJobTasks`), marks the job, fills its slot and calls `cancel()`, in that order, all inline, its slot's resume included. `failLand` reaches it through `cancelAllActionJobs` (:5891) while the model is borrowed, so the side's `cancelJob` does all four.
- **The cancellation handlers that `cancel()` can run synchronously:**
  - `awaitActionResult`'s `onCancel` sets the caller's flag and cancels the task. It touches no keeper state.
  - `ResolverExecutor`'s handler (ResolverExecutor.swift:191–205) settles its race, updates the abandonment's bookkeeping and cancels the resolver task. The keeper's cleanup comes later, through an async hop (`releaseCompletedActionJob`).
- **The bound sync requester stays weak**, and the choice between the attached port and the bound port is still made at failure time (:5896).

*Checked against 5d53571a with LSP: `incomingCalls` on `fillActionSlot` (:2585, 2735, 5941, 6089), `debugEndWork` (:2657, 3146, 3419, 3532, 4548) and `cancelActionJob` (:2710, 2717). The handler by reading ResolverExecutor.swift. Not verified: none.*

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

*Checked against 5d53571a with LSP: `findReferences` on `submitSyncStream` (in the keeper :1873, 4957, 5428; outside it TA:3850 and TA:3977 only) and on `recordsSyncStream` (in Sources, outside the keeper, TA:3822 only); `incomingCalls` along both paths. The TA files are unchanged from 6657fce4, where the same audit gave the same result. Not verified: none.*

**The sentinel.** The audit is a list, and a future port call can add a path to it.
- **Where it lives.** `bodyDepth` and `reentryViolations` are stored on the actor, outside the model and the side. A counter in the model would trap inside the guard itself. The driver raises `bodyDepth` around each body call (§2).
- **What it guards.** Only the adapter-facing entry. Today the bodies call the same package `submitSyncStream` (:1873 in the settle, :4957 in `applyInTurnSyncResult`, :5428 in the sync-only turn). K1b-5a splits it: the bodies call a model helper through their binding, and the package entry the adapter calls checks `bodyDepth` and then calls that helper.
- **On a violation it fails fast.** The entry posts a `LandFailure` to the set-once mailbox (nonisolated, no model write), logs it, and counts it in `reentryViolationsForTesting`. It doesn't touch the model, so the draft is not recorded. The land then ends at its next input boundary or step, where the mailbox is read (:4289, :5403). This follows the rule that a sync error ends the land and is never absorbed. A silent drop would corrupt the live record unseen.
- **The failure's kind is open (§7).**

## 4. The drivers

- **The input drain** (`runInputDrain`, :5986): the mark, the body, the flush, the submit or the tickless `endTurn` (§3.2), the alignment check, then the resume (:6085). The record draft isn't plain: `ReevaluationRecordedResolverOutput.value` is `AnyCodable` (ActionRecorder.swift:10).
- **The live tick** (`runTick`, :4537): the body, the flush, `finishTickTurn`'s submit (:5140).
- **The sync loop** (`runSync`, :6133): its fold decision writes the model outside a turn (K1b-4 §4.3's exception), then awaits the transport. Unchanged until K2's `.syncDue` step.
- **Replay** keeps its own driver: tick replay's separate W1 apply and W2 handler segments, the recorded failure cutoff, and the legacy sink flush (:4812–4888). It calls the same bodies but doesn't go through the live tick's wrapper.

## 5. Commits

1. **`KeeperTurnSide` and `TurnOutputs`.** The side's methods and storage, the census paths updated, the sentinel. No body changes yet.
2. **The bodies of §2,** each a `mutating` method staging under §3.2's rule. `failLand` splits, and the callers of §3.3 get their flushes.
3. **The input drain and the tick driver** call the bodies; the alignment check moves after the flush (§3.4).
4. **The replay driver** calls the bodies.

Each commit:
- is a pure move: the same statements, in a named function;
- keeps every HoldPoints test green;
- runs the touched suites, with the full debug `swift test` before the push.

**Tests:**
- **The record order:** a failing tickless pass with at least two distinct sync-stream entries before the failure. It asserts the three-step order of §3.2, that teardown adds no clear and advances no stream index, and the tickless `endTurn` of a failure-only batch.
- **The waiters:** a consumed caller stays parked at `.turnRecord` while a dropped-suffix caller gets `landClosed`.
- **The sentinel:** a test that calls the adapter-facing entry while `bodyDepth` is raised (through `probe`). It asserts the mailbox holds the failure, the count is 1, and the model's stream index didn't move.
- **A flush on a throw:** a test-only body that stages a services removal and throws. The removal is applied.

**Mutants (cloud).** Each names the observation that tells it apart from the correct code:
1. **The recorder Tasks flushed in reverse.** The record-order test, with two distinct entries: a merged final frame would hide a reversal.
2. **`closeOutputs` staged instead of called.** A keeper-originated failure, on a port whose gate starts open. The gate is observed at a synchronous `probe` after the failure and before the driver's flush. The existing teardown test observes after the segment, and the adapter already closes the gate on several failure paths, so it can't tell.
3. **`recorderSubmissionCount` incremented in the flush instead of inline.** The failure-only tickless batch loses its `endTurn`.
4. **The flush not in a `defer`.** The throw test's removal is lost.
5. **A callback reads the model during a body.** Expected to trap, so cloud only, one case per process (K1b-4's M-4 pattern). Its positive pair is K1b-5b's recording-enabled supersede.

## 6. Measurement

The small A/B runs K1b-4's cells (`rows-mp`, `wide-tickless-mp`), with the record mode stated for each cell. The base is K1b-5a's merge base and the head is the PR. It reports allocations per turn, and confirms that a turn with nothing staged leaves `TurnOutputs`' arrays unallocated. Ordering correctness comes from the tests, not from these cells.

## 7. Open

1. **The sentinel's failure kind.** `LandFailure.Kind` is public, so a new case such as `.keeperReentry` is a public addition, and a source break for an exhaustive `switch` outside the package. That needs the maintainer's approval. The alternative is an existing kind with a `detail` that names the re-entry. This plan proposes the new case.
2. **The failure-ID counter** (`failureIDs`, an `EpochCounter`) is a model field, because K2 mints IDs in the step. The table itself stays on the actor. K1b-5a's census commit corrects K1b-4's row, which lists the counter among the actor-side tables.
