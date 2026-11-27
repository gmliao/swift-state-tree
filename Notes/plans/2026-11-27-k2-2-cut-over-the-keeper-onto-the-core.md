# K2-2: cut the keeper over onto the turn core (#700)

Revision 5 (2026-11-27): Review's GO on rev 4 with four shoulds. The services table's home while unwired (commit 3). K22-Q5's in-flight table moves to the model. The loop epoch's bump step and the stale `.tickDue`'s fold (Q3 note). §3.2's follow-up row follows #938's round-3 contract. K22-Q5 and K22-Q6 are answered (§6). Revision 4 (2026-11-27): item 15's two design points (K22-Q5, K22-Q6), found while drafting commit 0; §4 item 15's row. Revision 3 (2026-11-27): Review's NOT GO on rev 2. Commit 1 maps every K2-1b request to its core effect, result input or owner call (§3.1, with #942's boundary table as Review corrected it). Every #938 refusal is mapped to the commit that lifts it, and commit 4's precondition includes "no refusal reachable" (§3.2). Commit 0's box table lives on the harness until commit 4. Item 16 lists its tests. Item 15 goes in commit 0. The parent's §6 is amended (§8). The [#938] points are refreshed at #938's round-3 head fbc27f72. Revision 2: P-K22-3's Linux output quoted (§7). Revision 1: P-K22-1 run, P-K22-2 settled by reading the code; two PRs (K22-Q4); commits 0, 2 and 3 independent of commit 1. Revision 0 was the prep draft. It is based on K2-1's shape in #938 (head 25ec1efb), which is still in review. Each point that depends on Review's verdict on #938 is marked **[#938]**. The parent plan is `Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md` (here "K2 §n"), whose §6 defines K2-2 and K2-3 as one PR, and whose §16 items 14–18 are left open for K2-2.

## 1. Goal

After K2-2, a live `LandKeeper` runs every input through a `TurnCore<KeeperModel<State>>`. The keeper's own drivers (`withTurn` frames entered from actor methods, the tick and sync loop bodies, the input drain) are gone from the live path. The public API stays unchanged and so does behavior (K2 §6: "a pure cut-over"), except for what K2-Q3 (a) already keeps: a re-entry during a step is refused and ends the land, as #865 does today.

K2-3, in the same PR, deletes the paths K2-2 made unreachable on live keepers and in the replay owner (K2 §6, condition 4).

## 2. What K2-2 starts from

- **K2-1 (#938, round-3 head fbc27f72) [#938].** The machine routes a closed subset: 11 inputs routed and 10 deferred (`KeeperInputRoutes`), and 2 queries routed and 4 deferred (`KeeperQueryRoutes`). Both are `CaseIterable` route enums, and the census checks routed ∪ deferred = all. The test harness `KeeperCoreHarness` is its only adopter, and the differential (23 tests) compares it with the keeper's path. Shapes that need the binding token are refused on the core by name (§3.2). The keeper builds its core twin with `coreTwinForTesting`. `KeeperSideStore` holds the step's side, bound to its owner, and `withSide` checks the owner's isolation per borrow.
- **K2-1b (§16 item 18, its own PR, not yet written).** It splits `performInitialization` and `drainAfterIdleCheck` into K1b-5 segments on today's keeper and ends CLAUDE.md's #522 exception. K2-2 routes both only after K2-1b merges. If K2-1b is still open when K2-2 is ready, K2-2 waits; it doesn't route those two flows on unsegmented bodies.
- **Deferred inputs and queries at #938:**

  | Input / query | Destination in K2-1 | K2-2 commit (§3) |
  |---|---|---|
  | `.actionResolved` | the action jobs (§16 item 17) | 0 |
  | `.initializeResolved`, `.destroyHandlerResolved`, `.drainFinished` | K2-1b, then K2-2 (item 18) | 1 |
  | `.freeze`, `.resume`, `.awaitResume` | the freeze barrier | 2 |
  | `.awaitInitialized` | the initialization barrier | 2 |
  | `.shutdown` | K2-2 | 1 (it ends in the drain) |
  | `.syncStreamDraft` | K2-2 | 3 |
  | queries `.admitClientEvent`, `.syncTurnNow`, `.syncTurnTicket`, `.settle` | `preconditionFailure("… is not routed yet")` | 2 (the first), 3 (the sync three) |

  Commit 4 then checks that `KeeperInputRoutes.deferred` is empty and the query `answer` has no unrouted arm. That check is the wiring step's precondition: the routed subset must be total.

## 3. Commits

Two PRs (K22-Q4, Main's lean, 2026-11-27): **K2-2a**, commits 0–3, still unwired, so the differential grows with them and the PR builds green on its own, as K2-1 did; **K2-2b**, commits 4–6, the cut-over, reviewable on its own. One commit per step, each building green.

**Commit 1 is blocked on K2-1b**, which waits on the maintainer (#117). Commits 0, 2 and 3 don't depend on it: none of them routes the initialization, the destroy drain or anything that ends in them. Where a commit-2 flow ends in one of those (the stop's drain, an initialization barrier still closed), that part is commit 1's, named below. K2-2a can merge without commit 1; K2-2b needs it, since the wiring needs the routed subset total.

**0. The action jobs on the core** (K2 §16 item 17). The job lane's four keeper-only parts move together:
- the job's task, staged through `side.keeperReference` and installed in `jobTasks`, becomes one `turn.run(.actionJob(…))` per job, and `.actionResolved(seq, token, result)` comes back. Its step checks the job, the entry generation and the sealed token (K2 §4.3);
- the abandonment's `onEnded` release becomes a result input that `perform` returns when the job's task is cancelled; `handleAbandoned` covers a run the core abandons (which one the core calls on a cancelled `run` is read from TurnActor.swift's `run` handling in rev 1, with a test citation, not a probe: the core's own tests pin it);
- **the caller's cancel. `.cancelsCall` alone doesn't match today** (found reading the code for P-K22-2). Today `awaitActionResult`'s cancel handler (LK:2370 at #938's head) sets `callerCancelled` and cancels the job's task synchronously, and `.actionResolved`'s segment then turns a success into `CancellationError` (LK:5963): **the action is not applied**. The core's `.cancelsCall` on a stepped input lets the work go on and only the caller stops waiting (CancellationTests.swift:78, test 24: "the work goes on and its reply finds no waiter"), so the action would be applied. **Proposal:** keep the box. The job's box (the `callerCancelled` flag and the task, Sendable, not plain) rides the `.actionJob` effect and comes back on `.actionResolved`; the model never stores it. The caller's wait is `sendAndWait(.awaitActionResult(seq), cancellation: .cancelsCall)` inside a `withTaskCancellationHandler` whose `onCancel` sets the box's flag and cancels its task, synchronously as today, so a completion that hasn't run yet fails with `CancellationError`. The wait finds its box through a table keyed by the sequence. `flush` writes it from the intake's output, and `.actionResolved`'s output removes it. While K2-2a is unwired, the table lives on the core's adopter, `KeeperCoreHarness` (test target; its `jobBox`). Commit 4 moves it to `LiveLandTurns`' storage, beside the services table, with a `live.` census row. The differential pins it: a job whose caller cancels before the resolver returns is not applied on either path, and its caller gets `CancellationError`;
- `awaitActionResult`'s `slotWaiters` become `coreSlotReplies`, checked like `coreInputReplies`: empty on the keeper's path (a violation entry, not an assert).
- §4 item 15 lands here, because this commit is the first to touch the action replies. `.awaitRecordTaken` and `.recordTaken` carry the tickless results.
- The job's completion kicks the input drain (`completeActionBody` → `scheduleInputDrain`, staged through the keeper reference today). On the core, the kick becomes a core queue entry (`.inputDrainDue` sent from the flush). That route also lifts the tickless `.admitServerInput` precondition, whose kick is the same call (§3.2).

Tests: the differential gets a job case per lane shape (a resolver job that succeeds, throws, and is cancelled by its caller), plus §16 item 10's job example: a step that starts a job and cancels it, so the task observes the cancel and the drain doesn't wait for a full run. K2-1's "core side: a job intake" violation entry goes; the job intake is now routed.

**1. The initialization and the destroy drain** (after K2-1b). Every request K2-1b's segments create becomes a core effect with a result input, an owner call, or stays outside the routed subset, as §3.1's table says. The result inputs are routed onto K2-1b's segments. The differential reruns K2-1b's hold cases (one per await) on the core path. K2 §16 item 13's remaining part goes here: `teardownWaitsForTheFailingTurn`'s scenario, from the failure through the teardown and the drain, on the core path, with every staged start beginning with a call into the owner (SE-0420). Also here, because they end in these flows: the stop's `.shutdown` (queued leaves first, then the destroy, on tick lands too, #511's follow-up, then the drain), and the initialization barrier's closed case (the waiters recorded by commit 2 are answered by the step that ends the initialization).

**2. The barriers and the freeze.**
- `.awaitInitialized` and `.awaitResume` are `sendAndWait` inputs whose step replies at once when the barrier is open, and otherwise records the caller in a model table answered by the step that opens it (K2 §4.2, "barriers, not holds"). No intake is parked by a hold, so a query can't overtake a parked call. Commit 2 routes `.awaitResume` whole, and `.awaitInitialized`'s open case and its waiter table; the closed case's answer is commit 1's.
- `.freeze` / `.resume` route `debugFreeze` / `debugResume`. This ends #129's hand re-check: the freeze's generation is the step's own read, so the post-await re-check goes.
- `.admitClientEvent`'s answer is decided here (§16 item 17's last sentence): **the proposal** is no value, as today (`Void` in `KeeperAnswer`), since no caller reads a sequence. The plan's `Result<Int64>` is dropped unless Review names a caller.

**3. The sync entries, the admission path and the services table.**
- The queries `.syncTurnNow`, `.syncTurnTicket` and `.settle` are routed; `syncTurnNow` keeps its nested `.skipped` answer through `isStepping` (K2 §4.2 matrix).
- `.syncStreamDraft` (the `submitSyncStream` entry) is routed for its awaited callers (the `.legacyCycle` branch, the disconnect's clear).
- The package admission path `admitJoiningSessionInStep(…, recordsSyncStream:) -> (JoinAdmission, [SyncStreamDraft])` (K2 §4.5) replaces the port's `admitJoiningSession` call in the join step. It must land with the join's step on the core, not after it: otherwise every recorded supersede is refused and ends the land. `SyncStreamLeaveReplayTests.supersedingJoinWithOnJoinRecordsItsClear` (tick and tickless) compares the stream with P-K2-2b's golden, with the refusal count at 0.
- The per-player services table's writes become outputs that `flush` applies: the 10 write sites emit `KeeperOutput.services`. While K2-2a is unwired, the table stays where K2-1 keeps it, on the side (`side.playerServices`, in the side store's census row). The adopter's `flush` applies the outputs there: the keeper on its own path, `KeeperCoreHarness` on the core. Commit 4 moves the table to `LiveLandTurns`' storage (K2 §4.5) with a `live.` census row, as commit 0's box table moves. `KeeperPlayerServicesTests` runs unchanged.
- The binding token: the attached transport rides the inputs that need a port (K2 §4.2), and `setTransport` becomes a step that writes it.

**4. The cut-over: the facade, `KeeperOwner` and the drivers.**
- `LandKeeper` becomes the facade over `enum KeeperOwner { case live(LiveLandTurns), replay(ReplayLandOwner) }` (K2 §3). `LiveLandTurns` is the `TurnActor` that owns the core; the facade and the adapter share its executor. K2-0's `facade` lint rule becomes live with the file that declares `KeeperOwner`.
- Every public and package entry forwards (`live.assumeIsolated { … }`, `await live.…`, or a `switch owner` whose arms forward). The guarded entries of K2 §4.2's matrix read `live.core.isStepping` and refuse with their name.
- The sentinel moves into `KeeperBehavior` as its one reference field (K2 §4.2 (a)), with #773's behavior lint listing it.
- The drivers: the tick and sync loops `send(.tickDue(…))` and `.syncDue(…)`. K2 §4.6 names a loop epoch for a stale `.tickDue`; no such field exists at #938 (`loopEpoch` has no hit). **Proposal:** the loops become core timers here only if #762 has landed; otherwise the loop Task sends, and its epoch is the keeper's existing loop generation (to name in rev 1, after reading the loop code at the PR's base). The pending fold leaves the actor: it rides `.tickDue`, as K2-1 already does on the core path.
- The replay owner keeps today's bodies without a core until #612 (K2 §7.2). Its path needs a replay branch for every step-only check added here (a token or a ticket), or replay skips it; the reevaluation E2E (0 mismatch) and the harness pass catch a divergence.
- The census gets a `live.` group for `LiveLandTurns` (K2 §8). The actor's rows leave as they move; `coreTwinForTesting` and the differential read [#938] are rewritten against the facade, or retired once the keeper's own path is gone (commit 6).

**5. The K2-Q1 docs** (K2 §5): `LandContext.services`' doc; `docs/core/land-dsl.md` and `.zh-TW.md` (constant services and sinks in handlers, outside data through resolvers; a service and a resolver's error hold no keeper reference, from K2 §4.5's audit); runtime.md (both languages) names K2's stops instead of Swift's exclusivity check (K2 §7.2).

**6. K2-3: the deletions.** One commit per path proven unreachable on live keepers and in the replay owner: the actor's `withTurn` drivers, `runInputDrain`, the keeper-side job lane (`jobTasks`, `slotWaiters`, `callerCancelled`), `inputTurnResults` once the results ride the effect (§4 item 15), `coreInputReplies` and `coreSlotReplies` once the keeper's path that keeps them empty is gone, and the differential's twin hook. Each deletion's proof is the K2-2 tests rerun. K9 keeps the deletions that need K3–K7.

### 3.1 Commit 1's mapping of K2-1b's requests

This follows #942's boundary table (K2-1b plan, § "The boundary with K2-2", at d7fb97d8, which carries Review's correction of the `.waitForTick` row). On a land with a recorder, K2-2 keeps `ticksInFlight` and the work count until `.recordTaken` (K2 plan §18, #938's note). So the drain's first segment waits for `.recordTaken`, not just for the tick's step. Where the two disagree, #942's merged table governs, and this table is updated in the same PR.

| K2-1b request or staged call | On the core | Result input | Routed in |
|---|---|---|---|
| `.runResolvers` (initialization) | the resolver effect | `.initializeResolved` (deferred at #938) | 1 |
| `.submitRecord` | the record effect | `.initializeRecorded` (new) | 1 |
| `.startLoops` | an **owner call after the step**: it writes the actor fields `tickTask` and `syncTask`. It stays so until #762's core timers replace the loops; commit 4's drivers keep it | `.initializeDone(loopsConfigured:)` (new; sets `didInitialize` after the loops, and asserts they are configured on a tick land) | 1 |
| `fail`'s staged teardown (`Task { tearDownAfterFailedInitialization }`) | an **effect**, `.teardownAfterFailedInitialization`, whose `perform` calls the owner. It must not be dropped: mutant 5 and `LandManagerFailedInitializationTests` pin it | none: the teardown starts its own leave and drain flows | 1 |
| `.replayHeader` (re-evaluation) | none: re-evaluation keepers keep the non-turn path until #612 | `initializeAfterReplay`: **outside the routed subset**, in a third route set, `legacyOnly`, that names #612 | not routed |
| `.waitForTick` | a **barrier**: the drain's first step records its waiter while a tick's record is not yet taken (`ticksInFlight > 0`), and the `.recordTaken` step answers it (or the drain's start is deferred until that step). Without a recorder, the tick's step ends the hold, so it replies at once | `.drainAfterTicks` (new) | 1 |
| `.runDestroyResolvers` | the resolver effect | `.destroyHandlerResolved` (deferred at #938) | 1 |
| `.runAfterFinalize` | an effect: the land's AfterFinalize handler runs off the core with the snapshot, in its scope | `.drainAfterFinalize` (new) | 1 |
| `.notifyTransport` | the port effect | `.drainFinished` (deferred at #938); then `setTransport(nil)`, which is the driver's owner call until commit 3's binding token makes it a step | 1 (3 for `setTransport`) |

So the routed subset gains four new result inputs, `.initializeRecorded`, `.initializeDone`, `.drainAfterTicks` and `.drainAfterFinalize`, beside the three already deferred. It also gains one owner call, `.startLoops`, and one new effect, the teardown.

**So that commit 4's totality check can't pass hollow:**
- K2-2a adds the four new inputs to `KeeperInput` as cases in `KeeperInputRoutes.deferred`, each with a precondition arm naming commit 1. If K2-1b's payload types aren't merged yet, the cases carry K2-2a's own plain payloads, and commit 1 replaces those.
- Commit 1 adds a `CaseIterable` route enum over K2-1b's request type, derived from an exhaustive switch, like #938's `KeeperInputRoute`. Each request maps to one of: an effect plus a result input, an owner call, or `legacyOnly`. The census checks that every request has a row. A request K2-1b or a later change adds without a row fails the build, at the switch, or fails the census.

### 3.2 #938's refusals and the commit that lifts each

| Refused on the core at #938 | How | Lifted in | By |
|---|---|---|---|
| a join that syncs in the turn | `KeeperCoreRefusal` | 3 | the package admission path and the binding token |
| any input of a tickless land with a transport (except `.startLand`) | `KeeperCoreRefusal` | 3 | the binding token (the attached transport rides the input) |
| a tickless `.admitServerInput` | a precondition (the answer has no error channel) | 0 | the drain kick as a core queue entry (commit 0's last bullet) |
| `scheduleJoinSyncTurn`, `requestSyncTurnAfterThisTurn`, `retrySyncOnlyTurnAfterWriterDrain` (#938 round 2) | **dropped after the completed phase**, by name (`refusesSyncFollowUpOnCore`, #938 round 3): the step's inputs, port events and sync result are applied, and only the follow-up is skipped. A core that holds this refusal isn't stepped again; the differential's `violations == []` ends the comparison there | 3 | each follow-up becomes a core queue entry carrying the binding token. The follow-ups' own redesign stays K3's |
| `actionTableViolations`, core side: "a job intake" | a violation entry | 0 | the job lane on the core |
| `actionTableViolations`, core side: "requested sync work / pending follow-up" | a violation entry | 3 | with the follow-ups above |

**Commit 4's precondition, all three must hold:**
- `KeeperInputRoutes.deferred` and `KeeperQueryRoutes.deferred` are empty. `legacyOnly` holds only the rows that name #612.
- No refusal is reachable. Each refusal and each core-side violation kind becomes a case of a `CaseIterable` reason enum in K2-2a, and the commit that lifts it deletes its case. The census asserts that both enums are empty at commit 4, and the precondition arm goes with the last case.
- No core-side `actionTableViolations` entry is reachable: every differential case reads `violations == []` on the core.

So the cut-over can't wire while a refused shape is in place. Otherwise a live land of that shape would end on its first input.

## 4. The open items from K2 §16

| Item | K2-2's answer | Depends on |
|---|---|---|
| 14, the frame's isolation on the core | **keep K2-1's shape**: `preconditionOnOwner` at step entry, `withSide` per borrow, and every staged start begins with a call into the owner (§16 item 13's shape). Passing the owner as `isolation:` through `assumeIsolated` makes the frame's own `#isolation` the owner, but a Task staged in the flush closure still doesn't run on it (P-K22-1), so it buys nothing the check doesn't | [#938] if Review asks for a different frame shape |
| 15, the tickless results onto the effect | in **commit 0** (the first commit that touches the action replies): `.awaitRecordTaken` and `.recordTaken` carry the batch's results as plain `[seq: InputResult]`: a failure is its `FailureID`, and the error stays in the side's failure table. The waiters are answered from `.recordTaken`'s step. `inputTurnResults` and `coreInputReplies` go in commit 6. Two points need an answer first. **K22-Q5**: the failure table's owner check. **K22-Q6**: what the differential compares. Both are in §4.2 | [#938]: the reply plumbing (a) as merged; K22-Q5, K22-Q6 |
| 16, the input drain's hold and idle waiters | **proposal: drop the hold from the core path.** `.inputDrain` is a test hold; on the core, a test holds the drain by holding its effect (`.awaitRecordTaken`) in the harness's `perform`, which the differential already does (`recordGate`). The idle waiters become a test read of the core (`inputDrainScheduled` false and no drain step pending). The tests that use it today and their replacement are in §4.1 | Review (K22-Q1: yes, after the list) |
| 17, the action jobs | commit 0, before the wiring | [#938]: `actionTableViolations`' entries as merged |
| 18, init and the destroy drain | K2-1b, then commit 1 | K2-1b's merge |

### 4.1 Item 16's tests

These are the tests that hold `.inputDrain` or wait on the drain's idle waiters, found at #938's head with `grep -rn '\.inputDrain)\|waitForInputDrainIdle' Tests`.

The keeper-path versions of these tests stay as they are until commit 6, because the keeper's own path keeps the hold until then. Each one gets a core-path counterpart when its commit routes the flow:
- the hold becomes a hold on `.awaitRecordTaken` in the adopter's `perform` (`recordGate`, as #938's differential does);
- an idle wait becomes a core read (`inputDrainScheduled == false` and no `.inputDrainDue` entry queued).

**Tests that hold `.inputDrain`:**

| Test | Holds the drain to | Core-path replacement | Commit |
|---|---|---|---|
| `TicklessActionJobTests`: "A leave between a job's delivery and its apply…" and "A land failure between a job's delivery and its apply…" (:423, :455) | place a leave or a failure between a job's delivery and its apply | hold `.awaitRecordTaken`; deliver `.actionResolved` and the leave or failure while it is held | 0 |
| `LandKeeperInputTurnTests`: the 64-input cap (:365), "a tickless client event's caller returns once its turn applied it" (:411), "client events applied by one drain each get their own outcome" (:448), "a throw at P in a batch" (:605) | queue inputs before one drain takes them | hold `.awaitRecordTaken`; the intakes queue as core entries behind it | 0 |
| `LandKeeperInputTurnTests`: "a client event queued behind the shutdown gets landClosed…" (:513) | queue an event behind the shutdown turn | the same hold, with `.shutdown` routed | 1 |
| `ClosedGatePendingFailureTests`: "a batch [A, a failure item, B]…" (:411) | one batch with a failure in it | hold `.awaitRecordTaken` | 0 |
| `TicklessPassOrdinalTests`: "A failure applied as an input in a tickless pass ends that pass…" (:478) | the same | the same; the replay half stays on the replay owner | 0 |
| `ShutdownTurnTests`: "Concurrent forceShutdown calls…" (:375) and "Tickless: an empty-room drain that starts before the shutdown turn…" (:448) | start a drain before the shutdown | hold `.awaitRecordTaken`; send `.shutdown` while it is held | 1 |
| `GracefulShutdownTests`: "at .afterAdmit OnJoin may not have run yet…" (:1894) | hold OnJoin's drain at admission | hold `.awaitRecordTaken`, with commit 3's admission path | 3 |

**Tests that wait on the idle waiters** (`waitForInputDrainIdleForTesting`, `KeeperProbeSignals.waitForInputDrainIdle`):

| Test | Core-path replacement | Commit |
|---|---|---|
| `KeeperTurnSkeletonTests`: "A tickless input batch that holds only a failure…" (:961) | the core read | 0 |
| `ShutdownTurnTests` :375 and :448 (above) | the core read | 1 |
| `GracefulShutdownTests`: #634's two cases (:1824, :1864) | the core read | 3 |
| `DiffScenarios` (NIO differential): "disconnect-at-registration" and "join-during-writer-backlog" (their "OnJoin's drain is idle" checks) | the core read | 3 |

`KeeperCoreDifferentialTests`' two keeper-side holds (`sourceDrainHold`) go with the twin hook in commit 6. The census row `actor.inputDrainIdleWaitersForTesting` stays `.replaced(by: "K2")` until commit 6.

### 4.2 Item 15's two points (rev 4)

Both were found while drafting commit 0, at #938's head fbc27f72. Each is a proposal for Review to answer.

**K22-Q5, the failure table's owners.** `actionTableViolations` counts the owners of each held failure: the initialization failure, the action slots, and `inputTurnResults`' `.failed(id)` entries (LK:5313). A failure with no owner is a violation ("has no owner"). On the core path, a batch's results leave the model when the step runs `.awaitRecordTaken`. While the record is in flight, a failed input's `FailureID` would therefore have no owner, and the check would report a violation that isn't real.

**Proposal:**
- The effect carries `InputResult`, which is plain and holds the `FailureID`, not the error.
- The **model** keeps an in-flight owner table, `inFlightRecordResults: [FailureID: Int64]`, which maps each failure to its sequence. It is plain data, so the digest covers it on both paths (Review, rev 4). The step that runs the effect writes it, and `.recordTaken`'s step clears it when it answers the waiter. On the keeper's path it stays empty, because `inputTurnResults` owns those failures there.
- The owner count reads that table as a fourth owner.
- Commit 6 removes `inputTurnResults` as an owner, and the in-flight table stays.

**K22-Q6, what the differential compares.** #938's digest compares the model whole (`otherModelFields`), `inputTurnResults` included. In K2-2a the keeper path keeps that table until commit 6, and the core path doesn't. So the field differs while a record is in flight.

**Proposal:**
- `inputTurnResults` becomes a stated asymmetry, like `hasHeldTransport`, with its reason. It is checked per path against that path's fixture: on the keeper's path it holds the in-flight results, and on the core it is always empty.
- The digest compares instead each path's results as its callers received them: the `InputOutcome`, or the error's description, in sequence order.
- `expectSame` also asserts that both sides hold none once the record is taken: `inputTurnResults` on the keeper path, and the in-flight table on the core path.

The asymmetry goes with the keeper path in commit 6.

## 5. Tests and measurement

- K2 §8's list, unchanged: each entry contract, the order test, the barriers, the result slot, cancellation with its mutant, the entry end and the seal; the census's `live.` group; the replay owner holds no `TurnCore` (a `Mirror` test).
- The differential [#938] grows with commits 0–3 (no difference allowed), then becomes the facade's own suite at commit 4: the same cases, one path.
- `KeeperReentryTrapTests` point at K2's stops; the refused entry is a count, so it runs in the normal suite with the `isDebugBuild` gate removed. The core's stop runs one case per process in the cloud.
- Full verification: both test legs, the two example packages, E2E in three encodings and the game E2E with reevaluation (CI and cloud), release and must-not-compile (CI), a mutant per new rule (cloud), and a release run with `-DTURNS_EXCLUSIVITY_CHECKED` (cloud).
- Host A/B after the merge, on the merged SHA (K2 §8): tick actions with and without resolvers, tickless client events; G3 (#760) checked before it is read.

## 6. Questions

| # | Question | For |
|---|---|---|
| K22-Q1 | Item 16: drop the `.inputDrain` hold on the core path (§4)? | **Yes** (Review, rev 2), after §4.1's list |
| K22-Q2 | `.admitClientEvent`'s answer: no value, as today (commit 2)? | **No value** (Review, rev 2): no caller in Sources reads a sequence from the client-event intake. `Result<Int64>` is dropped |
| K22-Q3 | The loop drivers: core timers only if #762 is in, else the loop Task sends with the existing loop generation as its epoch (commit 4)? | **Yes** (Review, rev 2), with the epoch named. Reading the loop code at #938's head shows there is **no** loop generation; see the note below the table |
| K22-Q4 | One PR for K2-2 + K2-3 (K2 §6), or two: K2-2a (commits 0–3, unwired) and K2-2b (4–6, the cut-over)? | **Two** (Review, rev 2). The parent's §6 is amended in this PR (§8) |
| K22-Q5 | Item 15: an in-flight owner table for the failures a record effect carries (§4.2)? | **Yes** (Review, rev 4), with the table in the model, not the side |
| K22-Q6 | Item 15: `inputTurnResults` as a stated asymmetry, with the callers' results compared instead (§4.2)? | **Yes** (Review, rev 4), with the asymmetry checked per path |

**The Q3 note.** There is no loop generation to reuse:
- `configureTickLoop` (LK:3019 at fbc27f72) cancels the old `tickTask` and starts a new one. `configureSyncLoop` (LK:4539) does the same with `syncTask`.
- A stale iteration is stopped only by its own task's cancellation, `runTick`'s `guard !Task.isCancelled` (LK:3449).
- That guard isn't enough on the core: a loop can send `.tickDue` and then be cancelled before the input steps. The send already left the cancelled task, so the step can't see its cancellation.

**So commit 4 adds the epoch.** It is a `loopEpoch: UInt64` in the model. `configureTickLoop` has one caller, the initialization (LK:1623), so the loops start once per keeper and stop once:
- **Starting.** The initialization's finishing step (K2-1b's `initializeFinish`, which returns `.startLoops`) bumps the epoch. The `.startLoops` request carries the new value to the owner call, which configures the loops after that step. Then `.initializeDone(loopsConfigured:)` (§3.1) only sets `didInitialize`. The owner's loop Tasks capture the epoch, and every `.tickDue` and `.syncDue` they send carries it.
- **Stopping.** The step that stops the loops, `.shutdown`'s or the drain's first step, bumps it again, and the owner call that cancels the tasks follows it.
- **A stale input.** A `.tickDue` or `.syncDue` whose epoch isn't current is dropped. A `.tickDue` can carry a folded sync (the pending fold rides it). Dropping it drops that fold too, with no outputs. The only bump after the start is the stop, which moves on to the drain, and the drain's own final sync covers what the fold held. So nothing a live loop needs is lost. If a later change adds a reconfigure, that change must re-queue the fold as a sync-only `.syncDue` with the new epoch, and the precondition on the bump names this.

A differential case pins it: a `.tickDue` with a fold, sent before the stop and stepped after it, applies nothing, and the drain's sync still runs.

## 7. Probes

Run on macOS, Apple Swift 6.4.2, `swiftc -swift-version 6`, one-file programs outside the repository. None traps: the checks print instead of asserting.

**P-K22-1 (item 14).** An actor `Owner` whose isolated `submit` calls a synchronous, nonisolated `step`, as the core calls `handle`. The step runs a frame with the K2-1 signature, `run(isolation: isolated (any Actor)? = #isolation, flush:, body)`, (a) with the default and (b) inside `owner.assumeIsolated { iso in run(isolation: iso, …) }`; the flush stages a Task with no capture (b1) and one that captures `iso` (b2); (c), a control, stages a Task capturing `iso` directly in the `assumeIsolated` closure. Each Task prints whether its `#isolation` is the owner. Output:

```
frame #isolation is owner: false
(a) flush: isolation nil statically
frame #isolation is owner: true
(b1) staged Task, no capture: on owner = false
(b2) staged Task capturing iso: on owner = false
(c) Task in the iso-isolated closure, capturing iso: on owner = false
log: ["b2 ran"]
```

So passing `isolation:` changes the frame's own isolation and nothing staged from it: no Task here inherits the owner, the control included. A staged start's work reaches the owner only by calling it (b2's `await iso.note`). §4's item 14 row follows from this. (c) is narrower than SE-0420's capture rule suggests, so no K2-2 design point relies on inheritance either way.

**P-K22-2 (commit 0): settled by reading the code, no probe.** The core's side is pinned by its own test: CancellationTests.swift:78, test 24, `.cancelsCall` after the step, where "the work goes on and its reply finds no waiter". The keeper's side is `awaitActionResult`'s cancel handler and `.actionResolved`'s segment at #938's head (LK:2370, LK:5963). The two differ, and commit 0's caller-cancel bullet keeps the box for that reason. The differential case in commit 0 is the evidence once written.

**P-K22-3 (commit 4): run on Linux only.** Three actors share one executor: the adapter's `unownedExecutor` is the facade's, and the facade's is `LiveLandTurns`'. The adapter calls `facade.assumeIsolated`, and the facade forwards with `live.assumeIsolated`; each level checks the others with `preconditionIsolated`. A wrong executor traps, so the probe ran in a throwaway `swift:6.4.3-noble` container (x86_64, "Swift version 6.4.3 (swift-6.4.3-RELEASE)"), not on macOS. Output, the same plain and with `-O`:

```
$ swiftc -swift-version 6 p_k22_3.swift -o p     # no diagnostics, rc 0
$ ./p
steps: 1 2 3 - one executor, no trap             # exit 0
```

So the three-level chain compiles under Swift 6's checking and runs on one serial executor, which is §3 commit 4's layout. Two-level sharing is already production evidence: the adapter runs on the keeper's executor (TA:113) and calls `keeper.assumeIsolated` (TA:3831). macOS is not run; K2-2b's own suites, on both platforms, are the evidence there.

## 8. The parent plan's §6

K2 §6 defines K2-2 and K2-3 as one PR. K22-Q4's answer splits them into two, K2-2a and K2-2b. This PR adds a dated entry to the parent, "§19. Draft 9 → draft 10 (K2-2's plan, 2026-11-27)", after #938's §18. That keeps #938's own amendment form (§13–§18). The planned text above it stays as it was.

#942 says K2-2's commit 1 routes the initialization and the drain "with the jobs". This plan puts the jobs in commit 0, independent of K2-1b. #942's rev is asked to say commit 0.

## 9. Commit 3's scope after reading the code (2026-11-27, while drafting K2-2a, #948)

This section records two changes to commit 3. The text above stays as it was planned; where the two disagree, this section governs.

| Point | Before (§3, commit 3) | Now |
|---|---|---|
| The services table | "the 10 write sites become outputs `flush` applies" | **The writes stay in the step, on the side.** At main 354e1f35, four writes are reachable on the core: the join's insert (LK:6281), the generation-checked remove (`KeeperTurnSide.swift:215`), and two `removeAll` calls (`failLand`, LK:6592; the shutdown item, LK:7455). Two more run on the keeper's own path only (LK:1355, :2606). An output that `flush` applies would change reads in the step: `makeContext` reads the table in the step that wrote it (LK:5210), so a handler after the insert would see the table as it was before. Also, `KeeperOutput.services(PlayerID, Epoch, LandServices?)` can't express a `removeAll`. The side store is already storage that the adopter holds, bound to its owner, so commit 4 moves only the table's slot to `LiveLandTurns`, with a `live.` census row. `KeeperOutput.services` is removed if nothing emits it by commit 4 |
| The owner identity for the sync queries | needed commit 4's facade (rev 3 prep) | **Not blocked.** `coreTwinForTesting` returns the owner, the source keeper whose executor the core shares. `.syncTurnNow`, `.syncTurnTicket` and `.settle` carry the port. Before each query, the adopter runs the keeper entry's checks, `port.runsSyncPhaseInTurn(of: owner)` and `bindSyncRequester`. Commit 4 replaces the owner with the facade, and no stand-in is needed |

The admission path still waits for #940 (§3, commit 3).
