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

**As merged (2026-11-27, §12):** K2-2a is #948, commits 0, 2 and 3. Commit 1 follows as two PRs of its own, both before K2-2b: **1a**, the initialization; **1b**, the destroy drain, the stop and the tick-record hold (§11.1), after #953.

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

**Review's conditions** (both points nodded, 2026-11-27):
- **The services table.**
  - The census lists the four sites as in-step side writes; commit 4 moves them with the slot. Review's reason: an output applied at the flush would split one decision across the flush, which the staged-action rule forbids.
  - The two keeper-only sites go with their flows:
    - LK:1355 is `tearDownAfterFailedInitialization`. Commit 1 routes it, as the teardown effect (§3.1).
    - LK:2606 is `runForceShutdown`'s branch without a turn (the drain already started, a failed initialization, or re-evaluation). Commit 1 routes it with `.shutdown`; the re-evaluation arm stays on the replay owner until #612.
- **The sync queries.** `runsSyncPhaseInTurn(of: owner)` runs in the same segment as the query's send, with no await between, as the keeper's entry does. `bindSyncRequester` runs in the query's step. **No other step runs between the two:** a query is answered synchronously, in place, on the shared executor (`TurnActor.query`), so the read and the query's step are one actor job. The adopter calls it from the owner's isolation with no await: the harness in K2-2a, the facade's `assumeIsolated` forward from commit 4. The read still rides the query (`inTurnForOwner`), so the step uses the value read at the send and never reads the port again.

The admission path still waits for #940 (§3, commit 3).

## 10. K2-2a as built (2026-11-27, #948 rounds 1–3)

This section records where K2-2a's code differs from §3's commits 0 and 2. The text above stays as it was planned; where the two disagree, this section governs.

| Point | Before (§3) | Now |
|---|---|---|
| The tickless `.admitServerInput` | commit 0's drain kick lifts its precondition | **Still a precondition in K2-2a.** The kick's work count needs a core wait on the input's sequence (`.serverInputKick`, added in round 2 for the resume's kick), and a query has no step that can queue the drain. It is lifted in K2-2b with the binding token, which routes the tickless land's port inputs |
| K2-1b's four new inputs | commit 0 adds them as deferred commit-1 rows | **Added when K2-2a merges main after K2-1b (#942).** They don't exist at K2-2a's base, so the census can't list them yet |
| `.awaitResume` | commit 2 routes it as a barrier input | **Removed.** The intake's own step is the barrier: a tickless action or client event, while frozen and not draining, is held in `coreInputReplies.heldWhileFrozen` and steps again once the land thaws or drains (`releaseCoreHeldIntakes`, at the end of every step). A separate barrier input let a freeze settle between the barrier and the intake (Review on #948, MF3) |
| `.freeze` on a tick land | commit 2 routes it | **Refused until commit 1.** The core drops the tick's work count when it stages the record, while the keeper holds it across `submitTurnRecord`'s await. Commit 1 brings that hold, and the refusal goes |
| The freeze's deadline | one core timer per generation | **One timer per caller** (`KeeperKey.freezeWait(InputID)`), as `debugFreeze` gives each call its own deadline. Every generation's callers are answered when the work ends, and at the resume, as the keeper wakes all its drain waiters |
| The resume's held intakes, in order | (not stated) | **The core runs them all in the resume's own step, in arrival order: a stated choice.** The keeper resumes each `debugWaitWhileFrozen` waiter as its own actor job, and each re-checks the barrier, so a freeze that arrives between two of them parks the second again. On the core every held intake is admitted before any later freeze. That is the stricter order, and it is one of the keeper's possible orders, chosen deterministically. `twoHeldIntakesReleasedInOrder` pins it with an action and a client event (Review r2 on #948) |
| A held caller cancelled before the resume | the sender reads the cancellation | **A set-once flag rides the input.** The sender wraps its call in `withTaskCancellationHandler`, whose `onCancel` sets an `ActionJobCallerCancellation` synchronously, inside `cancel()`. `.action` carries it into the held intake, and the release reads it where the keeper reads `Task.isCancelled` after `debugWaitWhileFrozen`, so the release throws `CancellationError` with no job. This is `awaitActionResult`'s `box.callerCancelled` shape. Round 3's `TurnMachine.handleCallerCancelled` hook was reverted in round 4: its cancellation came through a Task hop, so a `.resume` that stepped first still started the job. The differential sends the resume right after `cancel()` returns, with no await between (Review r2 on #948, MF2; r3, MF1) |
| The settle's witness | the sender reads `runsSyncPhaseInTurn(of: owner)` | **The settle's body asks it, through `callOut`, after its fence** (the land, the deadline, the generation), as the keeper's body does, so a re-entry from it ends the land in the settle and a closed or timed-out settle asks no port. The query names the owner; a core's side has no keeper reference, so its staged closures can't reach the source keeper (Review r2 on #948, MF1) |
| `.syncTurnNow` and `.syncTurnTicket` | the sender reads the witness | **The arm checks the land, then asks the witness outside the frame**, in `acceptsSyncTurn`'s order. A refused land asks no port. The answer is carried into `.syncTurnNow`'s step for the body's own reads (`syncsInTurn`): the keeper's body asks the witness again inside `callOut`, the core's doesn't. That is #938's stated asymmetry for tick and sync steps, now for a requested turn too, and K2-2's binding token removes both (Review r2 on #948) |
| A tickless job's apply window and reply order | (not stated) | **The core's `.inputDrainDue` follows the job's delivery in the same batch.** The keeper applies in a separate drain task, so a failure can land between delivery and apply. For a mixed batch `[job J, action A]`, the core stages A's reply first, and it publishes the slot replies before the freeze replies. The core's order is one of the keeper's possible orders. A case that pins the window with a failure between delivery and apply goes in K2-2b, with the facade's drain (Review on #948, S1) |
| `.actionJobReleased`'s case | commit 0's differential | **In K2-2b.** A release needs an abandonment that is still running when the job completes, which needs resolver deadlines on, and the suite runs with them off. The deadline's task-local read in a step is checked there too (`Notes/solutions/2026-11-27-a-core-step-reads-the-drivers-task-not-the-callers.md`) |
| The caller's cancel for `.awaitActionResult` in K2-2b | `.cancelsCall` with the box | **The box with `.ignoresCancel`**, as the harness does. `.cancelsCall` would let a cancelled caller skip a filled slot and leak its failure |

## 11. Commit 1 against K2-1b's code (2026-11-27, read at #944's head ec99ae89)

This section records where #944's segments differ from §3.1, and the stop flow, which K2-1b leaves unsegmented. The text above stays as it was planned; where the two disagree, this section governs. Line numbers are #944's `LandKeeper.swift`.

### 11.1 The stop (M11): `runForceShutdown` on the core

#944 segments the initialization and the drain, not the stop. `runForceShutdown` (LK:2585) still awaits four times, and `forceShutdown` (LK:2569) joins callers through a `SingleFlight`. On the core, `.shutdown` becomes a `sendAndWait` input (`.control`, from #948 round 2). Its caller is answered when the drain ends. Each await maps as follows:

| Await or call today | On the core | Result input | Re-checks in its step | Held server inputs |
|---|---|---|---|---|
| `forceShutdown`'s `SingleFlight` (one flight, later callers wait for it) | model state: `shutdownStarted`, plus a waiter list in the model's barrier waits (`coreBarrierWaits`). A second `.shutdown` records its caller and is answered with the first | none | `shutdownStarted` | — |
| the guard: no drain started, the initialization didn't fail, live mode (LK:2589); otherwise the no-turn branch | `.shutdown`'s step, arm 1: clears players, services and reservations, drops the pending inputs, then the drain start below | — | `isDraining`, `drainStarted`, `initializationFailure`, `mode`: the step's own reads, no ticket | dropped with the drain (`dropServerInputsHeldWhileFrozen`) |
| `endDebugFreezeForShutdown` (sync) | in `.shutdown`'s step, arm 2: the generation is released, every freeze caller is answered false, and the held intakes go on through `releaseCoreHeldIntakes` at the step's end. A tickless land's shutdown item is appended first, so the intakes re-enter behind it and its turn's `completeShutdownTurn` drops them with `landClosed`, as on the keeper | — | — | **kept out of the queue**, then dropped by the drain. The difference from resume: `resumeStep` appends them and kicks a counted drain |
| tick land: `shutdownRequested = true`, then `await waitForTickInFlight()` | a **barrier**, the same one as the drain's `.waitForTick`: the step records the wait while `ticksInFlight > 0`, and the tick's `.recordTaken` answers it (the tick-record hold commit 1 brings) | `.shutdownAfterTicks` (new) | `isDraining` / `drainStarted`: an empty-room drain that started during the wait is joined instead (LK:2605) | — |
| tick land: `applyShutdownTurnBetweenTicks` → `submitTurnRecord`'s await | the shutdown body in `.shutdownAfterTicks`' step; its record is the record effect | `.shutdownRecorded` (new); without a recorder its work is done in the same step | — | — |
| tickless: the shutdown item appended, `scheduleInputDrain`, `await shutdownTurnWaiters` | a core wait on the item's sequence (`KeeperCoreInputWait.shutdown(caller)`), answered by the input turn's step (`completeShutdownTurn`), or with `landClosed` by a drain that dropped the item | the `.recordTaken` that carries the turn | the wait's sequence | — |
| `holds.at(.shutdownTurnApplied)` (tests) | an owner hold before the drain start, in the facade (commit 4); in K2-2a's harness, a gate at the effect | — | — | — |
| `shutdownIfIdle(cause: .forceShutdown)`: joins a started drain, or checks emptiness, sets the drain flag, releases the held inputs, cancels the jobs, then starts and awaits the drain | the drain start (M7's owner call, then `drainBegin`) in the same step. The caller's wait is answered by `.drainFinished`'s step, as a joined drain's callers are | `.drainFinished` | `drainStarted`, `players.isEmpty` | `releaseHeldInputsForDrain` drops them |
| `holds.at(.forceShutdownReturn)` (tests) | an owner hold after the reply, in the facade | — | — | — |

**Probes (run 2026-11-27, macOS, debug, at #944's head a78339fc: hold points only, throwaway test code, not committed).**

*P11-1, a tick land: a leave arrives while the stop waits for the tick in flight.*
- Setup: p1 and p2 joined. A tick is held at `.turnRecord`, so `ticksInFlight > 0`. `forceShutdown` then reaches `shutdown-stop-gate`, and `leave(p1)` is sent.
- The leave's segment appends its lifecycle item while the stop waits. The probe waited for that with bounded `Task.yield()`s, which took 2; the committed case will use a hold. Then the tick's record is released.

```
PROBE1 leave=leave: done
PROBE1 log=["join:p1", "join:p2", "tick"]
PROBE1 events=["probe turn-begin", "probe turn-end", "hold turnRecord", "probe force-shutdown-joined", "probe shutdown-stop-gate", "pending before release: [\"lifecycle(SwiftStateTree.LandKeeper<SwiftStateTreeTests.Shut\"] after 2 yields", "forceShutdown returned"]
PROBE1 frame tick 0: actions 0 lifecycle ["join", "join"] serverInputs 0
PROBE1 frame tick 1: actions 0 lifecycle ["shutdown"] serverInputs 0
```

What it shows:
- The queued leave goes neither into the tick in flight nor into the shutdown turn. `completeShutdownTurn` drops it (`dropPendingInputs`), so **OnLeave doesn't run**.
- The leave's caller gets a normal return, as `leave`'s doc says for a dropped OnLeave.
- The shutdown turn is a frame of its own, the next tick ID, holding only `"shutdown"`.
- So the core's barrier needs no ordering rule for the leave: the shutdown step drops what is pending, as the keeper's does.
- This is open issue #512. The maintainer's decision (2026-11-11): the shutdown turn applies the queued leaves first, so OnLeave runs, and then destroys. Actions and joins are still dropped. The leaves are recorded in the same frame, before `"shutdown"`.
- **Commit 1 ports today's behavior unchanged**, for differential parity: the core's `.shutdown` drops the queued leave, as the keeper does at a78339fc.
- **#512's fix lands after the cut-over**, in the core's `.shutdown` step, so the change is made in one place instead of two. Review agreed (r3 on #948).
- **Commit 1b makes P11-1 a differential case named for #512**: it holds the tick at `.turnRecord`, queues the leave at the stop's gate, and asserts the drop (no OnLeave, the leave's caller returns, the shutdown frame holds only `"shutdown"`) on both paths. #512's fix flips that assertion.

*P11-2, a tickless land: a shutdown while frozen, with a held intake and a held server input.*

```
PROBE2 froze=true serverInput=accepted(sequence: 1)
PROBE2 action=action: landClosed
PROBE2 log=["join:p1"] heldServerInputs=0 inFlight=0 frozen=false
PROBE2 events=["probe input-held-frozen", "held server inputs before stop: 1, in flight 1", "probe force-shutdown-joined", "probe shutdown-queued", "probe action-queued", "probe turn-begin", "probe input-batch-2", "probe turn-end", "probe input-drain-end"]
PROBE2 frame tick 0: actions 0 lifecycle ["join", "shutdown"] serverInputs 0
```

What it shows:
- The held action re-enters behind the shutdown item (`shutdown-queued`, then `action-queued`), and both are taken in one batch of 2. The shutdown applies first, so the action gets `landClosed` and is never recorded.
- The held server input is never queued: `heldWhileFrozen` and `inFlight` go to 0, `input:9` is never applied, and it isn't in the frame.
- This matches the `endDebugFreezeForShutdown` row above, and the core's arm 2 must produce the same batch: the shutdown item first, then the released intakes.
- Both probes become committed differential cases in commit 1, held with hold points.

### 11.2 The initialization and the drain (M1–M10, M12)

| # | #944 | §3.1 said | Commit 1 does |
|---|---|---|---|
| M1 | `.finish`: without a recorder, the guard runs in a turn of its own after OnInitialize's, so that turn's late backstop has run (LK:7932) | no row | a fifth new input, `.initializeFinish`, which the step queues behind `.land`. `.initializeRecorded`'s step calls `initializeFinish` directly, as #944 does |
| M2 | `.done` | no row | answers the initialization barrier's waiters (commit 2's table). The init-wait watchers are a test hook on the owner |
| M3 | re-evaluation: `.checkReplayHeader(source)` and `.runReplayBeforeTickZero`, with the result `initializeAfterReplayHeader(encoding:failure:)` | `.replayHeader`, `initializeAfterReplay` | both requests in `legacyOnly` (#612), under #944's names |
| M4 | `initializeDone(tickLoopConfigured:syncLoopConfigured:)` | `initializeDone(loopsConfigured:)` | the two flags, which the owner call reads after `configureLoops` |
| M5 | no `loopEpoch` | the bump in `initializeFinish`'s step, carried on `.startLoops` (rev 5) | commit 1 adds the field; it isn't in #944 |
| M6 | `initializeResolved(…, cancelled:)`, read on the initialization's task | no mention | the resolver effect's perform reads its own task's cancellation and carries it on `.initializeResolved` (`Notes/solutions/2026-11-27-a-core-step-reads-the-drivers-task-not-the-callers.md`) |
| M7 | the drain's start: `holds.at(.drainStart)`, then the tick and sync tasks are cancelled, before `drainBegin` (LK:4678) | no row | an owner call before the first drain step: the loops are actor fields until #762 |
| M8 | `DestroyHandlerStep` and `AfterFinalizeStep` hold closures, a context and the generator | — | they ride the effect and come back on its result input, never in the model, as commit 0's job box does |
| M9 | `runAfterFinalize` runs in `openStepScope(…, droppingInto: destroyHandlerOutputsDropped)` | "an effect … in its scope" | the effect carries the scope's counter from the side |
| M10 | `.notifyTransport`: the port is `transport ?? boundSyncRequester`; after `drainFinished`, `releasedTransport = …` and then `setTransport(nil)` | `setTransport(nil)` only | the port effect takes the bound requester as a fallback. Two owner calls follow the step, in that order |
| M12 | — | §3.2 | commit 1 lifts none of #938's refusals. It lifts #948's tick-land `.freeze` refusal, through the tick-record hold that `.waitForTick` and the stop's barrier also need, so the hold is built once. The tickless `.admitServerInput` precondition stays with K2-2b (§10) |

## 12. Commit 1a as built (2026-11-27, its own PR after #948)

K2-2a merged as #948 without commit 1 (§3). Commit 1a routes the initialization; 1b takes the rest of §11.

**One phase per flow.** The initialization's state is one enum, `InitializationPhase`, in the model: `.notStarted`, `.replaying` (the keeper's legacy re-evaluation path, #612), `.resolving(sequence:)`, `.recording(sequence:)`, `.finishing`, `.startingLoops`, `.done`, `.failed`, `.abandonedByDrain` (#952: a drain began during OnInitialize's resolvers, so OnInitialize is dropped). It replaces the `didInitialize` flag, which is now computed (`isOver`: `.done`, `.failed` or `.abandonedByDrain`).
- Each segment sets the phase it enters, in the shared bodies, so the keeper's path and the core's write the same field and the differential compares it.
- Each result step on the core (`.initialize`, `.initializeResolved`, `.initializeRecorded`, `.initializeDone`, and the finish, which round 1 made a second step in the same handler instead of the `.initializeFinish` input) switches over all nine phases. The phase its request left runs; every other phase is named in a `preconditionFailure`. Only the flow's own effects and queue send those inputs, and until 1b no drain or failure moves the phase from outside the flow, so another phase is a broken flow, not a race.
- The rule is the maintainer's, for every multi-step flow moved onto the core, after #952 r1's two must-fixes: one exit of three checked, and a teardown keyed on a still-racing outcome.
- **#952's `initializationApplied` flag is part of `InitializationPhase`** (folded in when 1a was rebased onto #952): it is computed, `phase.applied`, true for the phases after `.resolving` on the live path (`.recording`, `.finishing`, `.startingLoops`, `.done`). #952's `initializeEndedByDrain` sets `.abandonedByDrain`. #954 is the later flow version, where each link of the chain is an effect plus a result input and the helper does the ticket and phase check. 1a's hand-written version is the baseline for that swap.

**What 1a routes.** §3.1 and §11.2's M1–M4 and M6, as written there. The re-evaluation pair (M3) is a `preconditionFailure` on the core (#612). The test switch `LandKeeperTesting.defersInitialization` is `package`, and a census case checks that no source in the package sets it.

**Left for 1b.**
- M5's `loopEpoch` goes with the tick-record hold, since the epoch guards the stale `.tickDue` that the tick routing reads.
- M7–M10 and M12: the drain, the stop and the tick-land `.freeze` refusal.
- `initializeFail` stages its teardown through `keeperReference`, which is empty on the core twin, so no teardown runs on the core in 1a. That's 1b's drain.

**Round 1 on #966 (Review's NOT GO at 5fce0d13), answered.**
- **The owner's two sends are `.control`:** `.initialize` and `.initializeDone`, as #948 made `.resume`. A full or closed queue never refuses the only input that answers the initialization's waiters.
- **The finish steps directly**, in the handler that ran OnInitialize's step, with the same phase check. `.initializeFinish` is gone as an input: queued behind `.land`, it let queued inputs step between OnInitialize and the finish, which the keeper never does, and its `_ =` dropped a refusal. M1's reason for a separate step holds: the step that returned `.finish` has ended, so its late backstop has run (T11).
- **A failure is thrown to the waiters** (K2 §3.3.1). `answerInitializationWaits` and a late `.awaitInitialized` reply `.failure(error)`, where the error is the side's error for `initializationFailure` (the keeper's `failure(for:path:sequence:)`). The facade's `awaitInitialization` drops it with `try?`, as the keeper's does.
- **`markDrainingForTesting`** sets the flag without the clears, unlike every production drain start. Its doc and the OnJoin assert name it as the one exception. `drainStartClearsWhileOnJoinIsHeld` pins the clears for `failLand` and the forced stop, before OnJoin's release.
- **`.recording`** carries no sequence: no step read it. `InitializeResolving` is plain `Sendable`. `coreWaitsLeft` counts the model's barrier waits.
- **Core twins:** `initializationHeldRecordTwoWaiters` (a), `initializationFailureAnswersTheWaiters` (b, the resolver's throw), `initializationStartsLoops` (c: the twin answers `.startLoops` with `.initializeDone`). Still to come: (b)'s `validate` refusal, (d) T11's late re-entry, and (e) a drain during the resolvers and during the record.
- **`parkedCallerCancelRacesResume`** is replaced by `parkedCallerResumedThenCancelled`, the resume-first order, forced. The job is held at its resolver while the caller is cancelled, and the comparison waits for the core's `input-drain-end`. The cancel-first order stays `parkedCallerCancelledBeforeResume`.

**Round 2 on #966.**
- **The seam, built from what exists:** `CoreDiffInitGates` holds and fails the resolvers. `armedRecordGate` holds the record on the core, and the pair's `keeperRecordGate` holds it on the keeper. The harness's `markDraining(cause:)` sets the twin's drain flag only (`store.withSide`); its cases join no player, so the keeper's clears have nothing to clear. T11's twin reuses `CoreDiffHandlerReentry`, fired from OnInitialize's body. `CoreDiffShape.initializeRefuses` is the two-stage OnInitialize whose `validate` throws.
- **New twins:**
  - `initializationValidateRefuses`, (b)'s validate: `.failed`, nothing applied, no loop, and both waiters get the failure.
  - `initializationLateReentry`, (d): one late re-entry per path, `keeperReentry` on both, no loop. The initialization itself ends `.done` on both paths, and the waiter is answered `.done`; the land fails after it.
  - `initializationDrainDuringResolvers`, (e): `.abandonedByDrain`, nothing applied, no loop, and the waiter gets `LandInitializationError` (the closed land).
  - `initializationDrainDuringRecord`, (e): still applied, no loop.
- **`markDrainingForTesting`** now clears `players`, the services and the rejoin reservations in one turn, as every drain start does. The OnJoin assert has no exception left. The in-body re-entry case in `KeeperTurnSkeletonTests` uses `setDrainFlagInBodyForTesting`.
- **Expected survivors until 1b:**
  - Mutant (h), `.initializeDone` left `.normal`: no 1a case fills or closes the queue while the owner's answer is in flight.
  - The flag-swap half of mutant (c): with no tick or sync interval in the init shape, no loop is configured, so `initializeDone`'s two flags reach only asserts on a land with no loops.

  1b's stop and drain cases cover both: a closed queue at `.initializeDone`, and a tick land's init.

**Round 3 on #966 (Review's NOT GO at fdeca5d9).**
- **`applied` in `.recording` is pinned.** `applied` (true) and `didInitialize` (false) differ in `.recording`, `.finishing` and `.startingLoops`, where the drain's `stateIsSetUp` reads `applied`. They also differ the other way in `.failed` and `.abandonedByDrain`, where `initializationFailure` guards the drain first. `.recording` is the one the keeper awaits in. `.startingLoops` is awaited on the core, so 1b's drain case pins `applied` there.
  - The keeper's T2b now lets the failure's drain finish while the record is held, bounded by an event as T12 is. It asserts that the destroy handlers ran on the set-up state, and only then releases the record.
  - T2 and the core's `initializationHeldRecordTwoWaiters` read `initializationApplied && !didInitialize` at the hold (`LifecycleFlagsForTesting.initializationApplied` is new).
  - Two mutants are killed: `applied` false for `.recording`, and `initializationApplied = didInitialize`.
- **Every new waiter read is bounded** by an event the task's end appends (`resultWithinHangBound`). The harness calls with `.ignoresCancel`, so a cancel can't free a lost reply. The held-probe and drain-end reads in `parkedCallerResumedThenCancelled` are bounded the same way.
- **The failures' causes are asserted**, for the core's early and late caller and for the keeper's late leave: `CoreDiffError(token: -1)` for the resolver's throw, `token: -2` for the validate refusal, and `LandInputRejection.landClosed` for the drain during the resolvers. The last case now has a late `.awaitInitialized` after `.abandonedByDrain`.
- **The record's hand-off, on both paths** (cloud mutant (a); Review r3 should 1). The recorder's queue is a FIFO, so a held submission ahead of the initialization's record keeps the record from being taken. The harness's `armedRecordGate` holds the effect, not the recorder; this case holds the recorder.
  - **The keeper (T2c):** a read is forced right after the segment that resumes at `.turnRecord`, through the new resumed hook (below). It expects `applied && !didInitialize` and no "initialized" event; once the queue moves, the order is queue moved → initialized.
  - **The core (`initializationWaitsForTheRecorderOnTheCore`):** the harness notes each record effect as it starts its wait, "awaiting the hand-off" or "no submission". The case expects the first and a phase still `.recording` while the queue is held.
  - **Mutants, run by hand 20× each:** stage the record without awaiting `taken()` (cloud (a)), killed 20/20. Delete the `taken()` await in `submitTurnRecord`, killed 20/20. `.initializeRecord(submission: nil)` on the core, killed 20/20.
- **The resumed hook** (`HoldPoints.installResumed`, `LandKeeper.installResumedHoldsForTesting`, package, test-only). It is a synchronous hook that `at` calls on the caller's executor right after the async hook returns. A task it starts there (capturing the `isolated` parameter) runs once that segment ends, at the caller's next suspension. A read from the async hook's own task can't be ordered after that segment: the hook is nonisolated, and its return enqueues the caller's resumption from another thread. With nothing installed, `at` is unchanged: one `nil` check more, no suspension.
- **Cloud mutant (f), the sequence check in `.initializeResolved`.** Review calls it equivalent in 1a: one initialization, one resolver effect. It stays as a check that a broken flow traps, and `staleInitializeResolutionStops` (an exit test) sends a resolution of another sequence while the core is in `.resolving` and expects the trap. The sequence stays in `.resolving`, since the check reads it.
- **Nits:** stale "queued behind `.land`" comments, `== .done` on both paths in the record-drain twin, the keeper-side `tickLoopConfigured` checks in the tickless twins dropped (the core's `.startLoops` checks are the real ones), the harness's `markDraining` doc, and the `.land` liveness assert before `.startLoops`.

**Round 4's leftovers on #948, carried here.**
- A cancel concurrent with the resume: `parkedCallerCancelRacesResume`, 8 runs. Either outcome, consistent on each path, and nothing left waiting.
- The registration watcher is bounded: it returns false after `within:`.
- `actionJobCallerCancel` waits for the resolver at its gate before the cancel.
- `firstSignal`'s doc.


## 13. Commit 1b's plan (2026-11-27, drafted on #966's head 5fce0d13)

1b takes what §12 left: the tick-record hold (M12, with M5's `loopEpoch`), the destroy drain (M7–M10), and the stop (§11.1). The order inside the PR: first the hold, then the drain, then the stop. The drain needs the hold for `.waitForTick`, and the stop needs both.

### 13.1 The tick-record hold (M12, M5)

Today on the core, a tick land's tick ends its work in the step that runs it:
- `tickDueStep`'s `defer`s call `tickEnd` and `debugEndWork`;
- its record goes out as a `KeeperOutput.record` for the driver's flush.

The keeper's tick instead holds `ticksInFlight` and the work count across `submitTurnRecord`'s await. The freeze and the drain read both.

1b makes the tick's record an effect, in the shape of the tickless batch's `.awaitRecordTaken`:
- **The effect:** `.awaitTickRecord(submission:tickId:)`. Its `perform` awaits the submission and returns a new input, `.tickRecordTaken(tickId:)`.
- **The result step** calls `tickEnd` and `debugEndWork`, then answers the waits that read the count, in that order:
  - the freeze's work wait;
  - the drain's `.waitForTick` (§13.2);
  - the stop's tick barrier (§13.3).
- **Without a recorder,** the step that ran the tick also ends it, as today. No effect, so there's no extra ordinal.
- **The stale `.tickDue`:** `loopEpoch` (M5) is a model field. `initializeFinish`'s step bumps it, as rev 5 planned, and so does the drain start. The owner's tick and sync Tasks capture it, and `.tickDue` and `.syncDue` carry it. A step whose epoch is not current folds into a no-op that takes no work count. That keeps a tick due before a drain from starting after the drain's `drainBegin`.
- **What it lifts:** `KeeperCoreRefusal.tickLandFreeze` is deleted, together with its census row and its `liftedIn`.
- **New differential cases:**
  - `tickLandFreezeWaitsForTheRecord`: a freeze arrives while the tick is held at `.turnRecord`, and is answered only after the record is taken, on both paths;
  - `staleTickDueAfterDrainStart`: a `.tickDue` with the old epoch is a no-op.

### 13.2 The destroy drain (M7–M10)

Each `DrainRequest` maps as follows:

| `DrainRequest` (K2-1b) | On the core | Result input | Notes |
|---|---|---|---|
| the start (`holds.at(.drainStart)`, cancel the loops, `drainBegin`) | an owner call (M7): the facade's hold, then the loop Tasks cancelled, then `.drainStart` (new, `.control`) | `.drainStart` | the step bumps `loopEpoch` (§13.1), then calls `drainBegin` |
| `.waitForTick` | model state: `drainWaitsForTick = true` | none: `.tickRecordTaken`'s step calls `drainAfterTicks` once `ticksInFlight == 0` | a tick land only: a tickless batch never counts in `ticksInFlight` (§13.2.1) |
| `.runDestroyResolvers(step)` | effect `.destroyResolvers(step)`: the step (closures, context, generator) rides the effect, never the model (M8) | `.destroyHandlerResolved(step, result)` | replaces K2-2a's placeholder `.destroyHandler(index:)` |
| `.runAfterFinalize(step)` | effect `.afterFinalize(step, dropCounter:)`: `perform` opens the step scope with the side's counter (M9), runs the handler and closes the scope | `.afterFinalizeReturned` (new) | its outputs are dropped, as on the keeper (#893) |
| `.notifyTransport` | effect `.notifyTransport(port:)`, where the port is `transport ?? boundSyncRequester`, read in the step (M10) | `.drainFinished` | then two owner calls, in order: the released stand-in, then `setTransport(nil)` |

#### 13.2.1 The tickless batch and `ticksInFlight` (settled 2026-11-27, read at 5fce0d13)

**It never counts.** The only increment is `tickStart` (`Sources/SwiftStateTree/Runtime/KeeperModel+Drivers.swift:44`–`46`). It has two callers:
- **The keeper's `runTick`** (`LandKeeper.swift:3648`). A live tickless land returns before that line, at `LandKeeper.swift:3621`–`3627` (`scheduleInputDrain`, then `runInputDrain`).
- **The core's `tickDueStep`** (`KeeperMachine.swift:1016`). The core's tickless path, `ticklessTickStep` (`KeeperMachine.swift:1063`–`1070`), goes to `inputDrainStep` without it.

So on a tickless land `drainBegin` never returns `.waitForTick`, even while a batch's record is in flight:
- on the keeper, `runInputDrain`'s `await submitTurnRecord` (`LandKeeper.swift:4652`);
- on the core, `.awaitRecordTaken`.

The drain doesn't wait for that record on either path.

**What follows for the code.** On the core, a batch's `.recordTaken` can step after `.drainStart`. Its step resumes the batch's callers, as the keeper's loop does after its await. Then `nextInputTurnBatch` is empty, because the drain dropped the pending inputs. So `.recordTaken` needs no drain arm. A differential case pins it: `ticklessRecordInFlightAtDrainStart`, with the record held by the recorder, the stop sent, then the record released. On both paths the batch's callers get their results, and the drain finishes.

Only re-evaluation tickless lands go through `tickStart`, and that path is `legacyOnly` (#612).

The drain's callers (the stop, `shutdownIfIdle`'s joiners) wait in `coreBarrierWaits.drained`. `.drainFinished`'s step answers them.

The initialization's teardown: today on the core, `initializeFail` stages it through `keeperReference`, which is empty there (§12). 1b makes it a drain start in the same step (the failed-initialization arm of §11.1's guard), so `teardownWaitsForTheFailingTurn`'s scenario runs on the core path end to end (K2 §16 item 13).

**Phases.** The drain gets one enum, as the initialization did (§12's rule): `DrainPhase`, with the cases `.notStarted`, `.waitingForTick`, `.destroyResolving(kind)`, `.afterFinalize`, `.notifyingTransport` and `.finished`. Each result step switches over all of them: the phase its request left runs, and every other phase is a `preconditionFailure`. Now a drain can move the initialization's phase from outside its flow (`.abandonedByDrain`), so the initialization's result steps check that arm too: a `.initializeResolved` after a drain start goes through `initializeEndedByDrain`, as on the keeper (#952).

### 13.3 The stop (§11.1)

As §11.1's table, with these choices:
- **`.shutdown`** is routed (`.control`, `sendAndWait`). A second `.shutdown` waits in `coreBarrierWaits.drained`, the SingleFlight's join.
- **The tick land's barrier** is `stopWaitsForTick`, answered by `.tickRecordTaken`'s step (§13.1). The shutdown body then runs in that step; its record is an effect, with `.shutdownRecorded` (new) as its result.
- **The tickless shutdown item** waits through `KeeperCoreInputWait.shutdown(caller)`, as §11.1 says.
- **Hold points** (`.shutdownTurnApplied`, `.forceShutdownReturn`) are owner holds on the facade. In 1b's harness they are gates at the effect.
- **#512** keeps today's behavior: the queued leave is dropped.

Differential cases, each held with hold points:
- P11-1 as `shutdownDropsQueuedLeave512` (§11.1);
- P11-2 as `shutdownWhileFrozenDropsHeldIntakes`;
- K2-1b's drain hold cases, one per await;
- `teardownWaitsForTheFailingTurn` on the core path.

### 13.4 Census and routes

These move from `deferred` to `routed`: `.shutdown`, `.destroyHandlerResolved` and `.drainFinished`.

These are added as routed:
- `.drainStart`;
- `.afterFinalizeReturned`;
- `.tickRecordTaken`;
- `.shutdownRecorded`.

After 1b, `KeeperInputRoutes.deferred` is empty. The census asserts that.

### 13.5 Probes

**P1b-1** (needs the slot, so it runs 2026-11-28 before the draft PR goes up). The question: on the core twin, does the owner's `.drainStart` call keep `drainAfterIdleCheck`'s order?

Throwaway test, hold points only:
1. A tick land with p1 joined.
2. Hold a tick at `.turnRecord`.
3. Start a stop, held at `.drainStart`.
4. While the stop is held, record whether the tick and sync Tasks are still set, and send one `.tickDue` with the current epoch.
5. Release the hold, then release the tick's record.

**Expected output, on both paths.** If the actual output differs, this plan is revised before the code:
```
P1b1 events=["probe turn-begin", "probe turn-end", "hold turnRecord", "hold drainStart", "probe drain-waits-for-tick", "probe input-drain-end"?]
P1b1 at drainStart hold: tickTask=set syncTask=set
P1b1 after release: tickTask=nil syncTask=nil
P1b1 tickDue during hold: no "turn-begin" (tickStart refused: isDraining)
P1b1 drain: drainAfterTicks after the record, then finished
```
- The hold comes before the loops are cancelled, and the cancel comes before `drainBegin`. That is `drainAfterIdleCheck`'s order (`LandKeeper.swift:4855`–`4864`).
- `isDraining` is already set at the hold, because `shutdownIfIdle` sets the flag before it calls `drainAfterIdleCheck`. So a `.tickDue` during the hold starts no tick on either path, and no `loopEpoch` check is needed for that case. `loopEpoch` still guards a `.tickDue` that was sent before the epoch bump and steps after the drain finishes.
- `"probe input-drain-end"?` marks an event that may or may not appear. The tick land has no input drain, so if it appears, that is a finding for this plan.

No other probe is needed: every other row ports a body that #944 already segmented, unchanged.

### 13.6 Written on 2026-11-27 (unbuilt), and what the code found

Everything in §13.1–§13.4 is written, except the cases listed under "Left" below. The code found these points, and they now govern:
- **The drain's join keys on its request, not on `isDraining`.** The tickless shutdown turn (`completeShutdownTurn`, `LandKeeper.swift:6997`) sets the drain flag before any drain runs. The keeper's `shutdownIfIdle` keys on `drainTask`, so on the core `startDrainIfIdle` keys on `drainRequested`. That field is set when the step asks the owner for the start, and is never cleared, as `drainTask` isn't.
- **A land failure's teardown runs on the core too.** `failLand` stages `runFailureTeardown` through `keeperReference` (`LandKeeper.swift:6845`), and that reference is empty on the core. So at the end of the failing step, the core emits `.failureTeardown(failure, port:)`. The owner calls `landDidFail`, then sends `.drainStart`. A failed initialization tears down in the step that failed it (`tearDownAfterFailedInitialization`), as §13.2 says.
- **A stop waits for the initialization's end** (`stopAwaitsInitialization`), as `forceShutdown` waits in `ensureInitialized`. With that, no `.shutdown` steps during the flow. A failure's drain during OnInitialize's resolvers still ends the flow inside `initializeResolved` and `initializeApply` (`.abandonedByDrain`, #952, `LandKeeper.swift:8270`, `:8337`). The initialization's result steps need no new arm.
- **The tickless stop's wait is model state, not a core wait.** `resumeStopAfterShutdownTurn` runs at the end of every step: once `shutdownTurnApplied` is set, or a drain has started, the stop goes on. No `KeeperCoreInputWait.shutdown` case is needed.
- **`loopEpoch`.** It is an optional `epoch` on `.tickDue` and `.syncDue`; nil (the tests' `drive`) is never stale. `.startLoops(epoch:)` carries the value to the owner. A stale `.syncDue` matters most, because `syncDueStep` doesn't read `isDraining`.
- **The differential's stated asymmetries** gain `drainPhase`, `stopPhase`, `stopAwaitsInitialization`, `loopEpoch` and `drainRequested`. Each is a model field that only the core's flows use.

**Written since** (2026-11-28):
- **The two stop holds.** The keeper's `.shutdownTurnApplied` window is, on the core, the owner's held drain start, because the core's stop runs the shutdown turn and asks for the start in one step (`shutdownTurnHeldBeforeTheDrain`, through the harness's `armedDrainStartGate`). `.forceShutdownReturn` is after the caller's answer, so it stays the facade's (commit 4).
- **The cases:**
  - `shutdownDropsQueuedLeave512` (P11-1). The keeper's leave append is observed through the resumed hook on `.leave`.
  - `shutdownWhileFrozenDropsHeldIntakes` (P11-2). The held server input is set on both keepers before the twin copies the source.
  - `ticklessRecordInFlightAtDrainStart`.
  - `staleTickDueAfterDrainStart`.
- **The freeze hold.** `tickLandFreezeWaitsForTheRecord` pins "not answered before the release" by events: the keeper's freeze registration, and the core's caller parked in `coreBarrierWaits.freeze`.
- **The stale-epoch case** is delivered mid-drain: a tick is held at its record, so the drain waits with the port attached. Delivered after the drain had finished, neither epoch guard's mutant was killed, because no port or sync handler is left by then.
  - The sync guard's mutant is killed 5/5 by hand.
  - The tick guard's mutant is equivalent here: `tickStart` refuses on a draining land.

**Left:**
- K2-1b's drain hold cases on the core path, one per await;
- `teardownWaitsForTheFailingTurn` on the core path.
