# K1b-5: turn bodies on the model, and the named segments (#700)

**Status:** rev 2, plan only, for Review. Read at #853's head a87e0278 (K1b-3, on #835's K1a), the base K1b-4's rev 2.1 names, without the LSP. The reach-out census of §3 comes from a script over that file's call graph (`func` bodies by brace matching, sync callees only), not from the LSP. K1b-5 re-takes it with `outgoingCalls` on its own base. K1b-5 needs K1b-4.

**Inputs:**
- the parent plan `2026-11-22-keeper-on-turncore.md` rev 5.8: A.6's F6 to F8 and A.8;
- K1b-4's plan rev 2.1 (GO):
  - the 59-field `KeeperModel`;
  - `KeeperBehavior` with `KeeperConfig`;
  - `outputCollector` on the actor (D1);
  - the actor-side `playerServices` table;
  - one `inout` access of the model per step (§3.4);
- K1b-1 and K1b-2 rev 2.1 (GO): `InputResult`, `FailureID`, the failure table, `actionJobTasks`, `actionSlotWaiters`;
- the K2 prep survey (1ebd7ddb), §7's three requests;
- Review's K2 pre-read, relayed by Main (2026-11-25): **a segment ends by returning the request for its await**, not by awaiting inline (§4).

`LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift` at a87e0278.

**Rev 1 → rev 2:**
- K1b-4's settled shapes replace draft 1's guesses.
- §3 is new: what a body reaches outside the model, and where each reach goes.
- §4 makes each segment return its await's request (Review's forced point).
- #852's note is unchanged.

## 1. Goal

After K1b-5:
- **Every turn is a body.** A body is a `mutating` method on `KeeperModel` that takes the behavior and the turn's ports (§3), and returns the turn's staged outputs (survey §1, §2).
- **Every async flow is a chain of synchronous segments.** Each segment returns a value that names the next await and carries what that await needs (§4). The actor's driver performs the await and passes the result to the next segment. K2 turns the same value into an effect, and the result into an input, without rewriting the segment.
- **Replay calls the same bodies** on its own model (A.6, "Replay path"; K2 moves them into `ReplayLandOwner`), and runs a segment's returned request directly.
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

Each body has this shape:

```swift
extension KeeperModel {
    mutating func applyTickTurn(_ input: TickTurnInput, behavior: KeeperBehavior<State>,
                                ports: inout KeeperTurnPorts) -> TurnOutputs
}
```

- **`TurnOutputs`** is a non-plain struct, built by the body and performed by the driver right after the body returns, in the same synchronous segment (§3.2). It holds:
  - the emitted events and the sync request, drained from the collector at the body's end;
  - the record draft, or the record entries to enqueue, in order;
  - the waiters to resume, by key and outcome;
  - the tasks to start, as request values (§3.2).
- **The handler step.** K1b-4's `withHandlerStep(ctx) { m, ctx in … }` becomes a `mutating` method on the model. The body calls it on `self`, so the single access to the model is the body's own.

## 3. What a body reaches outside the model

A body is synchronous, but today its sync callees reach actor-side state. The script found 64 sync functions reachable from `runTickTurn` and 27 from `settleTurn`. Every reach-out found goes one of three ways.

### 3.1 Ports: called during the turn, synchronously

`KeeperTurnPorts` is a non-plain struct, assembled by the actor for each step and passed `inout`. Each of its fields is a reference or a value the body reads or writes during the turn. Its order relative to the rest of the turn matters, so it can't be staged.

| Port | Reached through (LK) | Why it stays synchronous |
|---|---|---|
| `collector` (the output collector, K1b-4 D1) | `makeContext` (:3584), `takeEmittedEvents`, `takeSyncRequest`, `syncReadPosition`, `replaySequenceExhausted` | the handler's context closures write it during the handler. They capture the reference before the step borrows the model (LK:3606), and they must keep doing so: a closure that reads it through the actor's storage during the step would trap |
| `playerServices` (K1b-4 §3.3) | `makeContext` | the context is built during the turn. The port is the actor's table, passed `inout`: a distinct stored property from `model`, so the two accesses don't overlap |
| `transport` (the binding's port) | `applyInTurnSyncResult` (:4971), `runTurnOutputs` (:4939), `applyInputs`, `requestSyncTurnAfterThisTurn` (:5626), `bindSyncRequester`, `failLand`'s `closeOutputs` | the in-turn sync phase sends frames during the turn (§3.7 of the parent). `closeOutputs` must close the gate before any later output of the same turn |
| `drainFlag` | `failLand` (:5847), `completeShutdownTurn` | `setFailed` decides, during the turn, whether a later failure is the first |
| `pendingTransportFailure` | `applyInputs`, `applyPendingTransportFailure` (:5402) | read mid-turn, at the input boundary |
| `pendingSyncTurnAfterTurn` | `requestSyncTurnAfterThisTurn`, `runPendingSyncTurnAfterTurn` | set and run within the turn's end |
| `pendingFold` and the tick clock's `now` | `takePendingFold` (:5124) | F4: the clock is read inside the turn. K1b-5 reads `now` in the driver right before the body, in the same synchronous segment, so no other code runs between the two reads. K2 passes it as the turn's input |
| the replay group's per-turn fields (`replayRejected`) | `applyInputs`, `takeReplayRejected` | replay only. K2 moves it with `ReplayFields` |
| K1b-2's failure table | the input turn's outcome loop | a failure recorded in the turn |
| test probes (`inTurnProbeForTesting`) | `runTickTurn`, `runInputTurn`, `runSyncOnlyTurn`, `settleTurn`, `applyInTurnSyncResult` | synchronous test hooks. They must not call into the keeper (§3.4) |

**The ports become a stored struct.** The actor-side fields above become one stored struct on the actor, `var turnSide: KeeperTurnSide` (non-plain). The body gets `&turnSide` beside `&model`. This changes K1b-4's census paths from `actor.X` to `turnSide.X` for these rows, and K1b-5 updates the census in the same commit. The fields' slices (K2, K4) don't change. **For Review:** the alternative is one `inout` parameter per port. That gives the same access pattern, with a longer signature, and the census stays as K1b-4 left it.

### 3.2 Staged: performed by the driver after the body, in the same segment

Performing these after the body returns can't be observed: the body is synchronous, so nothing runs between its last statement and the driver's next. Each is a value in `TurnOutputs`, performed in the order the body staged it.

| Staged output | Today (LK) | Why staging can't be seen |
|---|---|---|
| waiter resumes: `inputTurnWaiters`, `shutdownTurnWaiters` (:5914), K1b-2's `actionSlotWaiters` | `dropPendingInputs` (:5927), `resumeShutdownTurnWaiters`, `fillActionSlot` | a resumed continuation can't run before the actor is free |
| recorder submissions | `enqueueRecorderSubmission` (:5333), `enqueueTicklessTurnEnd`, `recordSyncMarker`, `recordSyncOutput`, `submitSyncStream` | each starts a `Task` chained on the previous submission. Staged in order, they chain in the same order |
| task starts | `failLand`'s drain task, `runJoinSyncTurn`'s join, `releaseHeldInputsForDrain` | a started task runs only after the actor is free |
| test waiters | `resumeDrainStartedWaitersForTesting`, `failureWaitersForTesting` | as the resumes |

**`failLand` splits.**
- **Its model part runs in the body:** the position, the queue drop, `players.removeAll()`.
- **Its ports run in the body too:** `drainFlag.setFailed` and the transport's `closeOutputs`.
- **Its resumes, its record entry and its drain task are staged.**
- Its order is kept: the terminal record entry is staged before any teardown entry, as #535 D9 requires.

### 3.3 Not reached from a body

`holds.at(…)` appears in `failLand` and `applyPendingItem` in the script's output, but only inside `Task { }` closures, so a body never awaits it. Every other actor field (the loop tasks, the init and destroy tasks, the freeze's continuations, the binding token's other parts) is reached only from async flows (§4) or from the drivers.

### 3.4 Exclusivity

- The body holds `&model` and `&turnSide` together. They are two stored properties of the actor, and dynamic enforcement is per property, so the two accesses don't conflict.
- **What would trap:** anything the body calls that reads `self.model` or `self.turnSide` through the actor, instead of through the binding it was given. That includes a port closure that captured `self`.
- **K1b-5's audit** (K1b-4 §3.4's, extended) lists every closure stored in a port. Each must capture references or values, not `self`. The audit goes in the PR body.

## 4. The segments: each returns its await's request

**The forced point (Review, via Main).** A segment never awaits. It returns a value of its flow's request enum, one case per await, carrying what the await needs. The driver performs the await and calls the next segment with the result.

```swift
enum JoinRequest {
    case awaitInitialization(JoinCapture)
    case runCanJoinResolvers(JoinCapture, CanJoinResolverRequest)
    case kick(JoinCapture, KickRequest)
    case runOnJoinResolvers(JoinCapture, OnJoinResolverRequest)
    case awaitInputTurn(sequence: Int64)
    case done(JoinOutcome)
}

// The driver, on the actor, in K1b-5:
var request = model.joinStart(…, behavior: behavior, ports: &turnSide)
while true {
    switch request {
    case .runCanJoinResolvers(let capture, let r):
        let resolved = await r.run()
        request = model.joinDecide(capture, resolved, behavior: behavior, ports: &turnSide)
    // …
    case .done(let outcome): return outcome
    }
}
```

- **What K2 does with it:** each case becomes an effect (`.run`), and each `model.joinX(capture, result)` becomes the handler of that effect's completion input. The segments don't change.
- **The capture** is the flow's state that crosses the await. §4.5 lists it, and flags what isn't plain.
- **`holds.at(…)`** stays in the driver, at the start of the case that performs the await, where it is today. It doesn't suspend without a hook (HoldPoints.swift:29–36).

### 4.1 Join (`joinReportingAdmission`, :2079; the public `join` follows the same split)

| Request (await) | The segment after it | What the capture carries |
|---|---|---|
| `.awaitInitialization` (:2086) | **J1:** build the CanJoin request | `session`, `clientID`, `sessionID`, `admitThroughTransport`; the services by key, not by value (§4.5) |
| `.runCanJoinResolvers` (:2106) | **J2:** `canJoin`, the stale-join refusal (#234), the cap check. Returns `.kick` on a duplicate login, otherwise goes on to J3 in the same segment | the resolved outputs (`[String: HeldResolverOutput]`) |
| `.kick` (:2153, the old session's leave) | **J3:** the insert into `players` and `playerServices`, the `isDraining` check, the entry generation, then the admission or `.runOnJoinResolvers` | `decision`, `playerID`, `isReconnection` (**stale after the kick: #852**) |
| `.runOnJoinResolvers` (:2218) | **J4:** the `isDraining` and generation re-checks, the append, the admission, then `.awaitInputTurn` or `.done` | `sequence`, `entryGeneration`, `resolvedAtTick`, the outputs |
| `.awaitInputTurn` (:2268) | none: `.done` | — |

**#852.** J2's cap check skips a reconnecting player, and J3 inserts after the kick without checking again.
- **K1b-5 doesn't close #852 by itself:** the check stays in J2 and the insert in J3, as today.
- **Where the fix goes:** J3 is the segment after the await, so the fix is a re-check there against the current model. Which join the cap then refuses is #852's choice (Main keeps #852 as its own fix).
- **In K2,** J3 becomes the kick's completion input, a turn. That's where the re-check runs.

### 4.2 Leave (`leave`, :2827)

| Request | The segment after it | Capture |
|---|---|---|
| `.awaitInitialization` (:2828) | **L1:** find the entry, check the client and the session, read its services from `playerServices`, remove both, cancel its jobs (K1b-2's tables), take the OnLeave sequence, return `.runOnLeaveResolvers` | `playerID`, `clientID`, `sessionID` |
| `.runOnLeaveResolvers` (:2896) | **L2:** on failure, the drop metric and the destroy schedule. Otherwise the `isDraining` check, the append, then `.awaitInputTurn` | the outgoing entry's fields and services snapshot (K1b-4 §3.3), `sequence`, `resolvedAtTick` |
| `.awaitInputTurn` (:2945) | **L3:** `scheduleDestroyIfNeeded()` (:6221), then `.done` | `sequence` |

L3 is a write after an await today. K1b-5 names it, and K2 makes it the completion input's handler.

### 4.3 Actions (`submit`, :3120; `startActionJob`, :2505; `completeAction`, :2544; `awaitActionResult`, :2676)

| Request | The segment after it | Capture |
|---|---|---|
| `.awaitInitialization` (:3127), then `.waitWhileFrozen` (:3140) | **A1, the intake:** the handler lookup (K1b-1's index), the decode, the sender check, the limits, the sequence, the ticket. Then `.startJob`, the delivery, or `.awaitInputTurn` | the envelope (consumed in A1) and the identities |
| `.startJob` (resolvers, then `.actionComplete`'s hold) | **A2, the completion:** re-read the job and its side-table entry, the caller's cancellation, the ticket check, the deliver or the fill | `sequence`, `ticket`, and the resolved outputs or `FailureID` (K1b-2) |
| `.awaitInputTurn` (:3280) | none | — |

- **The job's task** is the driver's: `.startJob` is the request, and the driver starts the `Task` and records it in `actionJobTasks`. K5 replaces the task, and K2's `JobCancellation` replaces the caller's flag.
- **`awaitActionResult`'s continuation** is the waiter K1b-2 keeps in `actionSlotWaiters`. Its closure is one segment, with no request.

### 4.4 Client events and server inputs

- **Client event** (`handleClientEvent`, :3316): `.awaitInitialization` (:3322) and `.waitWhileFrozen` (:3331) come first. Then **C1, the intake**: the descriptor, K1b-1's decode, the bytes, the sender check, the sequence, the append. Then `.awaitInputTurn` (:3420) on a tickless land, or `.done`.
- **Server input** (`submitServerInputErased`, :3446): `.awaitInitialization` (:3448), then **S1, the intake**. Its kick (`kickServerInputTurn`, :3525) is a driver task: the hold, `awaitInputTurn` and `debugEndWork` (:3530–3532). `debugEndWork` is the freeze's bookkeeping after an await, which the CLAUDE.md rule names; it stays until K2.

### 4.5 The drivers

- **The input drain** (`runInputDrain`, :5986): the input turn's body, then the record's submit, then **D1**, the resume.
  - The body's `TurnOutputs` carries `InputTurnOutcome` to the submit: the applied items (plain after K1b-1) and the record draft.
  - The record draft isn't plain: `ReevaluationRecordedResolverOutput.value` is `AnyCodable` (ActionRecorder.swift:10). K2's `.awaitRecordTaken` carries it in the effect, not in the model.
  - Review expects that effect also to carry the turn's failed results. That would retire K1b-2's K2 holder. No change here.
- **The live tick** (`runTick`, :4537): the tick turn's body, then `finishTickTurn`'s submit (:5140). The replay part keeps its source reads between bodies (A.6's replay path).
- **The sync loop** (`runSync`, :6133): its fold decision writes the model outside a turn (K1b-4 §4.3's exception), then awaits the transport. Unchanged until K2's `.syncDue` step.

### 4.6 Out of scope, named for the census

- `performInitialization` (:1433): K5. Only its output segment becomes a body (§2).
- The force shutdown and the drain (`runForceShutdown`, `shutdownIfIdle`, `drainAfterIdleCheck`): K7, and the land-stop drain's exception (#522).
- The destroy handlers (`runDestroyHandler`, `notifyTransportDestroyedAndRelease`): K7.

## 5. What crosses an await and isn't plain (survey §7.3)

| Value | Where | K2's carrier |
|---|---|---|
| `LandServices` | J1 to J4 (the join's services), L1 to L2 (the outgoing services) | the capture holds the `playerServices` key, not the value: the join's caller-supplied services and the leave's snapshot. K1b-5 keeps today's values in the capture, and flags them. K1b-4 keys the table by `(PlayerID, generation: Epoch)`, and K2 uses that `Epoch` as `EntryID` |
| `LandContext` | J1→J2, J3→J4, L1→L2, A1→A2 | the resolver request carries it; only the outputs come back, as `[String: HeldResolverOutput]` |
| `ReevaluationTickRecord` | the record submit, in both drivers | `.awaitRecordTaken`'s effect, until #769 R2 makes the outputs bytes |
| `PlayerSession`, `JoinDecision` | J1→J4 | their fields are plain, but they aren't marked. Each gains `@PlainData`, a public addition, when K2 puts it in an input |
| `isReconnection` | J2→J3 | plain, but stale after the kick: #852 |

The request enums and the captures are non-plain in K1b-5, because they hold the values above. K2 splits each request into a plain input part and an effect part.

## 6. Commits

1. **`KeeperTurnSide` and `TurnOutputs`.** The ports move into the struct, and the census paths are updated. No body changes yet.
2. **The bodies of §2,** each a `mutating` method with its staged outputs. `failLand` splits (§3.2).
3. **The input drain and the tick driver** call the bodies.
4. **The action flow's requests and segments** (§4.3).
5. **The client-event and server-input intakes** (§4.4).
6. **The join** (§4.1).
7. **The leave** (§4.2).
8. **The replay path** calls the bodies.

Each commit:
- is a pure move: the same statements, in a named function, with the awaits moved to the driver;
- keeps every HoldPoints test green, because each hold stays where its await is performed;
- runs the touched suites, with the full debug `swift test` before the push.

**Tests.**
- The existing interleaving suites pin each flow's order.
- A flow whose order no test pins gets one in its commit, shaped like #852's: hold at the await, run the competing input, release. The census in §4 lists the flows. K1b-5 checks each against the suites on its base.
- **One new test per staged kind:** a land failure mid-turn whose waiters, record entry and drain task happen in today's order (the terminal entry before every teardown entry; the waiters resumed with `landClosed`).

**Mutants (cloud):**
1. A segment's driver case runs the next segment before the await (J3 before the kick returns). Expected to fail the join's existing duplicate-login interleaving test.
2. `TurnOutputs`' record entries performed in reverse. Expected to fail the land-failure order test.
3. A port closure that captures `self` and reads `self.model` during the step. Expected to trap: **cloud only, one case per process** (K1b-4's M-4 pattern).
4. `failLand`'s `closeOutputs` staged instead of called. Expected to fail the existing output-gate test, which looks for a frame after the failure.

## 7. Measurement

The bodies become methods on a struct, and the driver gains a `switch` per await. Neither should change the work done per input. But the body now takes two `inout` accesses (model and turn side), and `TurnOutputs` allocates per turn. So the small A/B runs: K1b-4's cells (`rows-mp`, `wide-tickless-mp`), base K1b-5's merge base, head the PR. `TurnOutputs`' arrays are reserved empty and filled only when a turn stages something; the allocation count shows if that holds.

## 8. Open, for Review

1. **`KeeperTurnSide` as one stored struct, or one `inout` per port** (§3.1).
2. **`TurnOutputs` performed by the driver** (§3.2): Review's check of the "can't be seen" column, `failLand`'s split especially.
3. **The request enum's shape** (§4): one enum per flow. The alternative is one shared `KeeperRequest`, which K2's effect enum would mirror.
4. **The clock read moving to the driver** (§3.1, `pendingFold`): the same synchronous segment, so no other code runs between.
5. **`PlayerSession` and `JoinDecision`:** marked in K1b-5 or in K2. Both are public additions.
