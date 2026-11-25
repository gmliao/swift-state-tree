# K1b-2: failure ids, the failure table and the action side tables (#700)

**Status:** rev 2.1, plan only. Review: GO once rev 2.1 corrects the `EpochCounter` line (2026-11-25), with only that line re-checked. Read at #835's head 6657fce4, without the LSP. K1b-2 needs K1b-1, because the job's `item` must be plain first. It re-runs this census with the LSP on its base.

**Parent plan:** `Notes/plans/2026-11-22-keeper-on-turncore.md` rev 5.8: Appendix A.6 F1 with Review's S1 and S4, and A.7's K1b-2 row. This plan writes S1 and S4 against K1a's code.

**Rev 2.1** answers Review's read of rev 2 (1 must-fix, 5 shoulds, 1 nit, all taken):
- **MF1:** `EpochCounter` isn't plain. It gains `@PlainData` too, as the second public additive conformance, which Main approved. A.1 already puts `entryGenerations` (an `EpochCounter`) and `GenerationTable` (which holds one) in Model, so K1b-4 needs the mark anyway, and the failure ids reuse the same counter type (§2, §7).
- **S1:** the alignment check returns its violations instead of asserting. Mutant 3 then fails a test, instead of trapping inside `removeActionJob`.
- **S2:** a table miss is logged with the land ID, the lookup path and the sequence.
- **S3:** the split's checklist.
- **S4:** the test matrix, and a named seam for mutant 5.
- **S5:** K2's holder between the applying step and `.recordTaken`.
- **Nit:** the no-waiter tickless cost.

**Rev 2** answers Review's NOT GO on rev 1 (2 must-fix, 6 shoulds, 3 nits, all taken). Review agreed to rev 1's three departures from S1 (§6).
- **MF1:** `Epoch` gains `@PlainData`, a public additive conformance (Main approved, 2026-11-25). `FailureID` declares `Hashable` and `Sendable`.
- **MF2:** the three tests that couldn't pass on the base are rewritten (§4). They cover join's error mapping, `ActionLimitRejection` as an intake refusal, and a defined non-removing reader that mutant 4 can break.
- **S1:** the census is narrowed to stored reply errors, with what's out of scope and why.
- **S2:** `inputTurnResults` goes through a setter that consumes a displaced id, and the resume takes the id before it branches.
- **S3:** the assertion runs after each completed pair, with tighter invariants.
- **S4:** the split's readers are named.
- **S5:** a late read through teardown is pinned.
- **S6:** the boundaries with K1b-3, K1b-4 and K2 are written out.
- **Nits:** both hooks are listed, the success path's extra dictionary work is named, and the access levels are fixed.

Code pointers: `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, at 6657fce4.

## 1. What holds an error today

**In scope: stored reply errors.** These are errors of any type, kept on the keeper after the segment that produced them, until a caller reads them. Three stores hold `any Error`, which isn't `PlainData`. A fourth holds continuations, which K2 replaces.

| Store (LK line) | Form | Written | Read |
|---|---|---|---|
| `initializationFailure` (:720, private) | `LandInitializationError?` (the type is public; `underlying: any Error`) | `performInitialization`'s five failure paths (:1460, :1476, :1517, :1531, :1554) | thrown by `ensureInitialized` (:1258, :1263, :1276); checked for `nil` at :2977 and :6220 |
| `ActionSlot.result` (:2452–2455, in `actionSlots` :2458) | `Result<InputOutcome, any Error>?` | `fillActionSlot` (:2640), when no caller waits yet | `awaitActionResult` (:2661), which removes the slot; `actionSlotIsFilledForTesting` |
| `inputTurnResults` (:5952) | `[Int64: Result<InputOutcome, any Error>]` | `runInputTurn` (:6014), from `applyInputs`' outcomes | `resumeInputTurnWaiters` (:6030), after the turn's record was submitted (an await); `awaitInputTurn`'s presence check (:5905) |
| `ActionSlot.waiter`, `inputTurnWaiters` (:877) | continuations | the waiting caller | the fill or the resume |

**The values matter.** The adapter maps a caller's error by its type to a client error code. So a caller must get the same error value its handler, rejection or resolver threw. The errors include:
- whatever a handler's `validate` throws;
- `LandInputRejection` and `CancellationError`;
- `ResolverExecutionError`;
- a replayed payload's rebuilt decode error.

`ActionLimitRejection` is thrown at intake, before a sequence or a slot exists (:3203–3209), so it never reaches a store.

**Out of scope, and why (S1):**
- `applyInputs`' `outcomes` (:4182) and `InputApplication.outcomes` (:4163): locals of one synchronous segment. The tick land's turn drops its outcomes, because a tick land acknowledges an action at delivery.
- `PendingLandFailureItem` and `LandFailure`: a concrete type, which K1b-1 marks plain.
- `RecordedPayloadDecodeFailure`: already plain.
- `DrainFlag` and `LandFailureMailbox`: they hold a `LandFailure`.
- The join's and leave's resolver outcomes: they live in async frames, not in stored properties. K1b-5 names their segments, and K2 carries them as inputs.
- `forceShutdownFlight`'s `Task`, and the `Never` continuations of the freeze and shutdown waiters: they carry no error.

## 2. The change

### `FailureID` and the failure table

- **`Epoch` gains `@PlainData` (MF1).** `Epoch` (Support/SingleFlight.swift:140) is public, so this is a public additive conformance; Main approved it under the additive-API rule. Without it, neither `FailureID` nor `ActionTicket` (`Epoch?`) passes the macro's field check.
- **`EpochCounter` gains `@PlainData` (rev 2.1, MF1).** It is public (Support/SingleFlight.swift:156) and holds one `UInt64`. Marking `Epoch` doesn't mark it. Main approved it as the second public additive conformance. A.1 already needs it: `entryGenerations` is an `EpochCounter`, and `GenerationTable` (Generations.swift:32) holds one, and both are Model rows.
- **`FailureID`**: a package struct, `@PlainData`, `Hashable` and `Sendable` declared explicitly, holding one `Epoch`.
  - It is minted by a keeper-local `EpochCounter`, `failureIDs`, which is never reset and never restored from a record. Replay mints its own.
  - `EpochCounter` traps on overflow, so it can't wrap around and reuse a value. A stale id can't name a newer entry.
  - It isn't `Error`, so it can't be thrown to a caller by mistake.
- **`InputResult`**: a package `@PlainData` enum, `case outcome(InputOutcome)` or `case failed(FailureID)`.
  - It replaces `Result<InputOutcome, any Error>` in the stores.
  - It isn't a `Result`: a `Result`'s failure must be an `Error`, and `FailureID` deliberately isn't one.
  - `InputOutcome` is already `@PlainData` (InputOutcome.swift:11).
- **The failure table**: `failures: [FailureID: any Error]` on the actor. It is Outside in the parent plan's split, and never enters `KeeperModel`.
- **Three accessors.** None runs the alignment check, so each can be half of a pair (S3):
  - `recordFailure(_ error: any Error) -> FailureID` mints an id and stores the value;
  - `takeFailure(_ id: FailureID) -> any Error` removes the entry and returns the value;
  - `failure(for id: FailureID) -> any Error` returns the value and leaves the entry. Only `initializationFailure`'s reader uses it.
  - **A missing id** in `takeFailure` or `failure(for:)` is a broken invariant. It doesn't trap, in any build:
    - it returns a sentinel error, `FailureTableMiss(id:)` (package), so the caller still gets an error;
    - it logs the miss at error level, with the land ID, the lookup path (`slot`, `inputTurn` or `initialization`) and the sequence, and counts it in `failureTableMissesForTesting`.
    - The log matters in production. A sentinel takes the adapter's generic error-frame path, while an event's `LandInputRejection` suppresses the error frame (TransportAdapter.swift:2674–2724). So a miss changes what the client sees while the land keeps running.
    - A consuming read removes the dangling owner along with the entry, so the alignment check can't catch a miss after the fact. Only the log and the count show it.
  - So under a mutant a test fails on the error's identity, or on the miss count, instead of the test process trapping. Every test in §4 also checks that the count is 0. A trap would have to be set before `LandKeeper.init`'s eager task reads the entry, and no flag can be set that early.

### Each store

- **`initializationFailure: FailureID?`.**
  - **Written** through one helper, `failInitialization(with error: any Error)`, used by the five `performInitialization` writers. It records `LandInitializationError(underlying: error)` and stores the id.
  - **Read** through one helper, `throwIfInitializationFailed()`, at :1258, :1263 and :1276. It throws `failure(for:)`'s value and doesn't remove it: the entry lives as long as the land.
  - The `nil` checks are unchanged.
- **`ActionSlot.result: InputResult?`.**
  - `fillActionSlot` keeps its signature, `Result<InputOutcome, any Error>`, because its callers hold the error in one segment.
  - When a caller waits, it resumes the caller with the value directly, and nothing is stored.
  - When no caller waits, a failure goes into the table, and the slot holds the id.
  - `awaitActionResult` takes the value out with `takeFailure`, inside its continuation closure, in the segment that removes the slot.
- **`inputTurnResults: [Int64: InputResult]` (S2).**
  - **Writes** go through `setInputTurnResult(_ sequence:, _ result: Result<InputOutcome, any Error>?)`, which consumes any id the write displaces.
    - A failure is recorded, and a success is stored as is.
    - `nil` removes the entry and takes its id, if any.
    - Live sequencing never displaces an entry. A concurrent manual replay step could, because `stepTickOnce` has no single-flight, so the helper is safe anyway.
  - **The resume** (`resumeInputTurnWaiters`, :6030) removes the entry and takes the id at once, before it branches on `ticklessJobTurns` or `inputTurnWaiters`. So it always holds the error value.
    - A waiter is resumed with the value.
    - A tickless job goes through `fillActionSlot`. With no caller waiting, that records the same error under a fresh id.
  - These outcomes wait across the record's submit (an await) while their callers already wait. So in K1b every failed input-turn outcome passes through the table. K2 removes that wait (§5).

### S4: the action jobs' side tables

- **`ActionJob` splits.**
  - The Model part, in `actionJobs`, keeps `item`, `ticket`, `input`, `completed` and `cancelledByKeeper`. `item` is plain after K1b-1. `ActionTicket` holds an `Epoch?`, and gets `@PlainData` once `Epoch` has it.
  - A new `actionJobTasks: [Int64: ActionJobTask]` on the actor holds `task`, `abandonment` and `callerCancelled`. K5 ends `task` and `abandonment`, and K2's `JobCancellation` ends `callerCancelled`.
- **`ActionSlot` splits.**
  - `actionSlots` keeps `result`.
  - A new `actionSlotWaiters: [Int64: CheckedContinuation<InputOutcome, any Error>]` holds the waiter, until K2's `InputID`.
- **The readers of the split (S4):**
  - `completeAction` (:2534–2548) reads `actionJobTasks[sequence]` (the abandonment and the caller's flag) before `removeActionJob` removes both halves;
  - `cancelActionJob` reads the model fields and the task together, from both tables;
  - `awaitActionResult` reads the task and the flag from `actionJobTasks`, and the slot from `actionSlots`;
  - `waitForActionJobsForTesting` captures each job's task and abandonment before its first await.

### The alignment check (S3; returns its violations, rev 2.1)

`actionTableViolations() -> [String]` is a function, not an assertion. Each call site logs what it returns and adds the count to `alignmentViolationsForTesting`. A debug assertion inside the function a mutant changes would trap there, before the test's hook or `#expect` could observe anything, as with the table miss. The function checks:
1. `actionJobTasks`' keys equal `actionJobs`' keys;
2. each slot holds at most one of `result` and a waiter: `actionSlotWaiters`' keys are a subset of `actionSlots`' keys, and no key has both a `result` and a waiter;
3. each id in the failure table has exactly one owner among `initializationFailure`, the slots' results and `inputTurnResults`, and every id those name is in the table.

**Placement.** The check runs after each completed pair, never between its halves:
- at the end of `startActionJob`, `removeActionJob`, `cancelActionJob` and `fillActionSlot`;
- at each exit of `completeAction`: the fill, the keeper-cancelled exit and the tickless exit (S3);
- inside `awaitActionResult`'s continuation closure, after both the slot's removal and `takeFailure`, or after the waiter is stored (S3);
- at the end of `runInputTurn`'s outcome loop and of `resumeInputTurnWaiters`;
- in `failInitialization(with:)`.

`recordFailure`, `takeFailure` and `failure(for:)` don't run it.

**The split's checklist (S3):**
- `actionResultHasWaiterForTesting` reads `actionSlotWaiters`, not `ActionSlot.waiter`.
- `fillActionSlot` removes the waiter before the slot, so the subset invariant holds at every point.

No live path has an await between the halves of a pair (Review's reading and Codex's). During the record-submit await in `runInputDrain`, a result and its entry are both present, so an assertion in another function holds.

## 3. Hooks

Five package hooks are new, all for tests:
- `failureTableCountForTesting`;
- `failureTableMissesForTesting` (§2);
- `alignmentViolationsForTesting`, the count the call sites add to;
- `actionTableViolationsForTesting() -> [String]`, which runs the check on demand and returns what it found;
- `setInputTurnResultForTesting(_:_:)`, the seam for mutant 5. It calls the private setter with a sequence and a result, so a test can write the same sequence twice, and write `nil` while a result is stored.

## 4. Tests and mutants

**Tests first, green on K1b-1's base** (except those that read a new hook, which land with the change):
- **`failedActionResultReachesItsCallerAsTheSameValue`.** "Waiting and not yet waiting" applies only to resolver jobs: a tickless action without resolvers waits inside `submit`, so it is never read late (S4).
  - a resolver's error on both land kinds;
  - a handler's `validate` error on a tickless land;
  - on a tickless land, a resolver action whose `validate` throws. That covers `inputTurnResults`, the resume, and `fillActionSlot`.
- **`actionLimitRejectionIsAnIntakeRefusal`:** `ActionLimitRejection` is thrown by `submit`, no sequence is taken, and no slot exists. Once the table exists, the test also checks the count is unchanged.
- **`failedInputTurnOutcomeReachesItsCaller`:** a client event whose `validate` throws, on a tickless land. The caller gets the same error after the record is in.
- **`initializationFailureReachesEachCallerAsTheSameValue` (MF2).**
  - After OnInitialize times out, an action, a client event and a leave (:2813) each get a `LandInitializationError` whose `underlying` is the timeout. The test compares the value, not only the type.
  - The test makes two successive external calls, and both get it. It doesn't rely on "the second caller": `LandKeeper.init`'s eager `Task { try? await ensureInitialized() }` (:1242) reads first.
  - A join maps it to `JoinError.landShuttingDown` through `ensureInitializedForJoin` (:1330–1336), as `InitializeTwoStageTests:655` and `ResolverDeadlineTests:444` pin. It is asserted separately.
  - A server input gets `.refused(.draining)`.
- **`failureTableHoldsOnlyWhatIsUnread`:**
  - after a failed action that was read, and a failed client-event turn, the table holds only the initialization entry, if any;
  - an unread failed action keeps exactly one entry until it is read, and none after;
  - a failed input-turn outcome of a tickless job with no waiter yet keeps one entry, under the slot, until it is read (S2).
- **`aFailedSlotIsReadThroughTeardown` (S5).**
  - A failed action's slot is left unread through a completed drain.
  - Its late `awaitActionResult` reads the exact rejection, and the entry is then gone.
  - A second read gets `ActionResultUnavailable`.
  - The adapter always reads (`trackActionResponse`, TransportAdapter.swift:5456–5493). A package caller that discards `.pending` can grow unread slots without bound. That is today's behavior; noted, not fixed.
- **`actionTablesStayAlignedThroughAJobsLife`:** a job is admitted, resolved, abandoned, cancelled by a leave, and cancelled by the drain. After each, `actionTableViolationsForTesting()` is empty, and `alignmentViolationsForTesting` is 0.
- **`inputTurnResultSetterConsumesWhatItDisplaces`:** through `setInputTurnResultForTesting`, a failure replaced by another failure, and a failure replaced by `nil`, while the result is still stored. Each leaves exactly one table entry or none, and no violation.

**Mutants (cloud):**
1. `awaitActionResult` reads the value but doesn't remove the entry. Expected to fail `failureTableHoldsOnlyWhatIsUnread`.
2. `resumeInputTurnWaiters` resumes with a generic error instead of the table's value. Expected to fail `failedInputTurnOutcomeReachesItsCaller`.
3. `removeActionJob` removes the job but not its `actionJobTasks` entry (S4's mutant). Expected to fail the alignment test: the check returns a violation and counts it, and the test fails on that. Nothing traps.
4. `throwIfInitializationFailed()` uses `takeFailure` instead of `failure(for:)`. The eager task takes the entry, so the first external caller gets the sentinel (`FailureTableMiss`), and the miss count is 1. Expected to fail `initializationFailureReachesEachCallerAsTheSameValue` on the value.
5. `setInputTurnResult` stores without consuming a displaced id. Expected to fail `inputTurnResultSetterConsumesWhatItDisplaces` (invariant 3), through `setInputTurnResultForTesting`.

## 5. Boundaries (S6)

- **K1b-3 (the RNG).** One adjacent merge area: `performInitialization` (:1486–1557). K1b-2 routes its five failure writes through `failInitialization(with:)`, and K1b-3 wraps OnInitialize's handler call in its step RNG helper. They are different lines, but the same region, and maybe both add an `import SwiftStateTurns`. The second lander merges by hand. K1b-2 doesn't touch a handler-call wrapper.
- **K1b-4 (the model).**
  - **Model rows:** `actionJobs` (its plain part), `actionSlots` (`result: InputResult?`), `inputTurnResults` (`InputResult`), `initializationFailure` (`FailureID?`), and `failureIDs`, the keeper-local `EpochCounter` that mints failure ids. It is plain once `EpochCounter` is marked (MF1).
  - **Outside rows:** the failure table, `actionJobTasks` and `actionSlotWaiters`.
  - Its census test runs the alignment hook through a job's life.
- **K2.**
  - **Who owns the exact error (rev 2.1, S5).** The applying step is synchronous and flushes its outputs when it ends, and `.recordTaken` is a later step. So the error needs a holder in between:
    - it is an Outside table keyed by the record request's `RequestID` (the `.awaitRecordTaken` request, scoped to `.land`), holding the errors of the inputs that request's record covers;
    - `flush` writes it from the applying step's output;
    - `.recordTaken`'s completion consumes it: the facade resumes each waiter with its value, and anything with no waiter goes to the failure table under the input's slot;
    - `handleAbandoned` for that request releases it: its waiters get `landClosed`, as they do today when the land ends;
    - this is a K2 design note, not a K1b-2 change.
  - S1's "empty after `endAll`" test waits for K2, which owns `endAll`.

## 6. The departures from S1's text (agreed by Review on rev 1)

1. **A never-reused counter, not a slot index with a generation.** It gives the same guarantee, as long as it stays keeper-local and is never reset or restored (§2).
2. **No kind or description stored beside the id.** Nothing in the model reads one: the record lists a rejected input by its sequence, and the logs print the error where it's thrown (:4219).
3. **The table's lifetime is tied to the slot's, not "empty after the drain".**
   - The drain fills unread slots with a rejection (`cancelAllActionJobs`, :5834 and :6188), and a late `awaitActionResult` still reads it.
   - The adapter's `trackActionResponse` depends on that, and `aFailedSlotIsReadThroughTeardown` pins it.

## 7. Public API and measurement

- **Public API: two additions.** `Epoch` and `EpochCounter` conform to `PlainData` (rev 2 MF1 and rev 2.1 MF1; Main approved both). `LandInitializationError` keeps `underlying: any Error`: the table holds the public value, and the model holds only the id. Every other new type is package.
- **Measurement: none (Review).**
  - On the success path, `InputResult` replaces `Result` with the same payload.
  - Each resolver job also gains a side-table insert and remove in `actionJobTasks`, plus a waiter lookup in `actionSlotWaiters`.
  - A failure costs one table insert and one remove, and failures are the refused path. A tickless job with no waiter costs two pairs: the input turn's id, then a second id for the unread slot.
  - If K1b-1's small A/B runs after K1b-2 is on the branch, it adds one resolver-action cell.
