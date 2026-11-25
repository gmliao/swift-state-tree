# K1b-2: failure ids, the failure table and the action side tables (#700)

**Status:** rev 1, plan only, for Review. Read at #835's head 6657fce4, without the LSP. K1b-2 needs K1b-1, because the job's `item` must be plain first. It re-runs this census with the LSP on its base.

**Parent plan:** `Notes/plans/2026-11-22-keeper-on-turncore.md` rev 5.7: Appendix A.6 F1 with Review's S1 and S4, and A.7's K1b-2 row. This plan writes S1 and S4 against K1a's code. Three points differ from S1's text, and Review is asked to agree to them (§4).

Code pointers: `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, at 6657fce4.

## 1. What holds an error today

Three stores hold `any Error`, which isn't `PlainData`. A fourth holds continuations, which K2 replaces.

| Store (LK line) | Form | Written | Read |
|---|---|---|---|
| `initializationFailure` (:720) | `LandInitializationError?` (public; `underlying: any Error`) | `performInitialization`'s failure paths (:1460, :1476, :1517, :1531, :1554) | thrown by every call that awaits the initialization (:1258, :1263, :1276); checked for `nil` at :2977 and :6220 |
| `ActionSlot.result` (:2452–2455, in `actionSlots` :2458) | `Result<InputOutcome, any Error>?` | `fillActionSlot` (:2640), when no caller waits yet | `awaitActionResult` (:2662), which removes the slot; `actionSlotIsFilledForTesting` |
| `inputTurnResults` (:5952) | `[Int64: Result<InputOutcome, any Error>]` | `runInputTurn` (:6014), from `applyInputs`' outcomes | `resumeInputTurnWaiters` (:6030), after the turn's record was submitted (an await); `awaitInputTurn`'s presence check (:5905) |
| `ActionSlot.waiter`, `inputTurnWaiters` (:877) | continuations | the waiting caller | the fill or the resume |

**The values matter.** The adapter maps a caller's error by its type to a client error code. So a caller must get the same error value its handler, rejection or resolver threw. The errors include:
- whatever a handler's `validate` throws;
- `LandInputRejection`, `ActionLimitRejection` and `CancellationError`;
- `ResolverExecutionError`;
- a replayed payload's rebuilt decode error.

**Not stores:** `applyInputs`' `outcomes` (:4182) and `InputApplication.outcomes` (:4163) are locals of one synchronous segment, so they can keep `any Error`. The tick land's turn drops its outcomes: a tick land acknowledges an action at delivery.

## 2. The change

### `FailureID` and the failure table

- **`FailureID`**: a package `@PlainData` struct holding one `Epoch`, minted by an `EpochCounter` on the actor (`Support/SingleFlight.swift:157`). The counter never reuses a value, so a stale id can't name a newer entry. S1 asked for a slot index with a generation (a slotmap); a never-reused counter gives the same guarantee with a dictionary. It isn't `Error`, so it can't be thrown to a caller by mistake.
- **`InputResult`**: a package `@PlainData` enum, `case outcome(InputOutcome)` or `case failed(FailureID)`. It replaces `Result<InputOutcome, any Error>` in the stores, and isn't a `Result`, because a `Result`'s failure must be an `Error` and `FailureID` deliberately isn't one. `InputOutcome` is already `@PlainData` (InputOutcome.swift:11).
- **The failure table**: `failures: [FailureID: any Error]` on the actor. It is Outside in the parent plan's split: it never enters `KeeperModel`. Every write goes through two helpers:
  - `recordFailure(_ error: any Error) -> FailureID` mints an id and stores the value;
  - `takeFailure(_ id: FailureID) -> any Error` removes the entry and returns the value. Every path that drops an id without resuming anyone also removes its entry.

### Each store

- **`initializationFailure: FailureID?`.** The writers store `LandInitializationError(underlying: error)` in the table. The readers throw the table's value, without removing it: the entry lives as long as the land, as S1 says. The `nil` checks are unchanged.
- **`ActionSlot.result: InputResult?`.**
  - `fillActionSlot` keeps its signature, `Result<InputOutcome, any Error>`, because its callers hold the error in one segment.
  - When a caller waits, it resumes the caller with the value directly. Nothing is stored, as S1 says.
  - When no caller waits, a failure goes into the table, and the slot holds the id.
  - `awaitActionResult` takes the value back out with `takeFailure` in the segment that removes the slot.
- **`inputTurnResults: [Int64: InputResult]`.**
  - `runInputTurn` puts each failure into the table.
  - `resumeInputTurnWaiters` takes it back out, in the segment that removes the result.
  - These outcomes wait across the record's submit (an await) while their callers already wait. So in K1b every failed input-turn outcome passes through the table. K2 removes that wait: the step's output carries the value to the facade, and the table is used only when nobody waits. That is S1's waiter case.

### S4: the action jobs' side tables

- **`ActionJob` splits.**
  - The Model part (`actionJobs`) keeps `item`, `ticket`, `input`, `completed` and `cancelledByKeeper`. `item` is plain after K1b-1, and `ActionTicket` holds an `Epoch?`, so it gets `@PlainData`.
  - A new `actionJobTasks: [Int64: ActionJobTask]` on the actor holds `task`, `abandonment` and `callerCancelled`. K5 ends `task` and `abandonment`. K2's `JobCancellation` ends `callerCancelled`.
- **`ActionSlot` splits.**
  - `actionSlots` keeps `result`.
  - A new `actionSlotWaiters: [Int64: CheckedContinuation<InputOutcome, any Error>]` holds the waiter. K2's `InputID` ends it.
- **The invariants,** checked by a debug-only `assertActionTablesAligned()`:
  1. `actionJobTasks`' keys equal `actionJobs`' keys;
  2. `actionSlotWaiters`' keys are a subset of `actionSlots`' keys. A slot has a waiter only while someone waits, so S4's "equal key sets" holds for the jobs, not for the slots;
  3. the table's ids are exactly the ids named by `initializationFailure`, `actionSlots` and `inputTurnResults`.

  K1b has no step boundary yet. So the assertion runs at the end of each function that inserts or removes in these tables: start, complete, release, fill, await, cancel, the input turn and its resume. K2 moves it to the step boundary.

## 3. Tests and mutants

**Tests first, green on K1b-1's base** (each through public or package paths, no new hooks beyond one count):
- `failedActionResultReachesItsCallerAsTheSameValue`, with the caller waiting and not yet waiting.
  - On a tickless land, the caller gets the handler's `validate` error, with its type and value.
  - On both land kinds, it gets a resolver's error and `ActionLimitRejection`. A tick land acknowledges an action at delivery, so its handler's error never reaches the caller.
- `failedInputTurnOutcomeReachesItsCaller`. A client event whose `validate` throws, on a tickless land. The caller gets the same error after the record is in.
- `initializationFailureIsThrownToEveryCaller`. A join, an action and a client event after OnInitialize timed out each get the same `LandInitializationError` value.
- `failureTableHoldsOnlyWhatIsUnread` (S1's tests, reshaped; see §4).
  - After a failed action that was read, and a failed client-event turn, the table holds only the initialization entry, if any.
  - An unread failed action keeps exactly one entry until it's read, and none after.
  - It reads a package `failureTableCountForTesting`. This test is new in the K1b-2 commit, since the count doesn't exist before it.
- `actionTablesStayAlignedThroughAJobsLife`. A job is admitted, resolved, abandoned, cancelled by a leave, and cancelled by the drain. After each, the assertion's three invariants hold, checked by a package hook that runs it.

**Mutants (cloud):**
1. `awaitActionResult` reads the value but doesn't remove the entry. Caught by `failureTableHoldsOnlyWhatIsUnread`.
2. `resumeInputTurnWaiters` resumes with a generic error instead of the table's value. Caught by `failedInputTurnOutcomeReachesItsCaller`.
3. `releaseCompletedActionJob` removes the job but not its `actionJobTasks` entry (S4's mutant). Caught by the assertion in `actionTablesStayAlignedThroughAJobsLife`.
4. `initializationFailure`'s readers take the entry instead of reading it. The second caller then gets a different error; caught by `initializationFailureIsThrownToEveryCaller`.

## 4. Where this differs from S1's text (for Review)

1. **The id is a never-reused counter, not a slot index with a generation.** Same guarantee, and no slot reuse to manage. The parent plan's mention of a "slotmap" only names the guarantee.
2. **No kind or description is stored beside the id.**
   - S1 put "a plain kind and description beside it, for the record and the logs". Nothing in the model reads one in K1b: the record lists a rejected input by its sequence, and the logs print the error where it's thrown (`applyInputs`, :4219).
   - Adding them is cheap if K2's step output wants them. Until then they would be fields nothing reads.
3. **S1's drain and `endAll` tests assume slots are cleared there. Today they aren't.**
   - The drain cancels the jobs, and that fills their slots with a rejection (`cancelAllActionJobs`, :5834 and :6188). An unread slot stays until it's read or the keeper is gone, and a late `awaitActionResult` still gets its outcome.
   - Clearing those slots at the drain's end would change what a late reader gets, from the rejection to `ActionResultUnavailable`. K1b-2 doesn't change it.
   - So the table's lifetime is tied to the slot's, and checked by invariant 3, instead of "empty after the drain".
   - The tests are `failureTableHoldsOnlyWhatIsUnread` and the alignment test. The mutant moves to the read path (mutant 1). If Review wants the slots cleared at the drain's end, that's a behavior change for its own question.

## 5. Public API, measurement, boundaries

- **Public API:** none. `LandInitializationError` keeps `underlying: any Error`: the table holds the public value, and the model holds only the id. Every new type is package.
- **Measurement:** none proposed; Review judges.
  - On the success path, the only change is `InputResult` in place of `Result`, with the same payload.
  - A failure costs one dictionary insert and one remove. Failures are the refused-input path, not the hot path. K1b-2 checks the benchmark cells for refused inputs on its base.
- **K1b-3 (the RNG):** no shared lines. K1b-2 touches the action-job section (:2370–2790), `runInputTurn`'s outcome loop and `resumeInputTurnWaiters` (:6010–6035), and `initializationFailure`'s readers and writers. None of these is a handler-call wrapper.
- **K1b-4:** its Model rows copy `actionJobs`, `actionSlots` (`result` only), `inputTurnResults` and `initializationFailure` in these forms. The failure table and the two side tables are Outside. Its census test runs `assertActionTablesAligned()` through a job's life, as its §3 says.
