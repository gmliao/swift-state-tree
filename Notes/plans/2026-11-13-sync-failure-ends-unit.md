# A sync failure ends the unit it corrupted (#535)

**Status:** rev 5, plan only. No code before this plan is reviewed.
- Rev 4 (7471e833) got a no-GO: 1 must-fix, the settle's placement. Rev 5 moves the queue part of the settle into the apply segment itself, as `completeShutdownTurn` does for a shutdown at the end of its batch (LK 3876-3878); `InputApplication` carries `consumed`, and only the consumed prefix is published. The record finalize and the teardown start stay at the turn's end, touch no keeper state, and their order relative to `submitTurnRecord` is stated (§3.2).
- Rev 3 (334595b6) got a no-GO: 2 must-fix and 6 should. Rev 4 answers them:
  - P1 (mid-batch failure): §3.2 is split into the mark, made where the failure is seen, and the settle, run at the end of the turn after the consumed prefix is removed and its outcomes published. Only the unexecuted suffix gets `landClosed`.
  - P2 (the terminal entry): §3.2 step 5 is an unconditional finalize step at the end of every turn that failed, of any kind, ordered after any turn record and before any teardown entry. The legacy output position needs `beginSync` to return the position with in-turn sync off (§3.3).
  - Shoulds: D10 (a) is worded as the cause as of the router's close request, with the window named; D11 has a testable definition (clock, interval, reset, retry scheduling, tickless, skipped plans, recorded); action responses are best effort until membership ends; D5 names the mechanism, its install, its false positive and its real gap; N2's skipped effects are listed; the resync-view docs row stays "target" until PR 2.
- Rev 2 (131ff6d3) got a no-GO: 6 must-fix and 5 should. Rev 3 (on `main` 9755a625 merged with `origin/main`, which brings `docs/core/failure-handling.md`) answers them:
  - N1: §3.2 step 3. `failLand` cancels the action jobs still in their resolvers, after the drain flag, as the empty-room drain does; each slot is filled once. The resolvers' delivery check citation is corrected.
  - N2: §3.4 and D4. OnLeave resolvers on a failed land are a decision; the recommended option skips them by checking the failure before they start, and keeps the membership cleanup.
  - N3: §3.4 and D10. Where the close code is decided is a decision; the recommended option reads it at each session's close.
  - N4: §4. The registration gaps are restated (struct, tuple and enum-payload values the default instance doesn't hold, not only existentials), with a "default init is deterministic" contract, and the user's `init()` runs outside the cache's lock.
  - N5: §3.1, §3.2 step 5 and D9. The terminal entry goes through the ordered recorder pipeline after the failing turn's record; the legacy path records two positions.
  - N6: §3.3. Debug settle and the action-result output are added, action responses after a failure are specified, and `keeper.endSync()` still runs on a stale generation.
  - Shoulds: D5's detector (where the count lives, no state byte changes, what it can't see, the cost); row 15's bound as D11; D8's promise limited to library conversion; P1 under the purity contract; §7 names the failure-handling page rows each PR flips.
- Read at `main` 9755a625. TA = `Sources/SwiftStateTreeTransport/TransportAdapter.swift`, SE = `Sources/SwiftStateTree/Sync/SyncEngine.swift`, ST = `Sources/SwiftStateTree/Sync/SyncTables.swift`, LK = `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, LM = `Sources/SwiftStateTreeTransport/LandManager.swift`.
- The sweep on #535 was read at 9bf7df61; since then only TA moved (about +11 lines after TA 1420).
- Rev 1 (28adb8e9) got a no-GO: 10 must-fix and 8 should. Rev 2 answers them:
  - M1: §1 and D2c. `allRecipients` is now a policy for the maintainer, not detection. It counts unique players and names whether joiners count. A structured type cause is the land before any per-recipient test.
  - M2: Appendix A.2. Precedence across all of a frame's failures (the broadcast scope wins), and a whole-frame fallback that doesn't call an encoder-wide defect per-recipient.
  - M3: Appendix A.3. Per-player decisions are staged in the plan and applied at commit, after the land verdict.
  - M4: §3.4. The teardown is keeper-owned and doesn't depend on the transport.
  - M5: §3.2 and §3.3. Every waiter is listed with how it is settled, and so is every resume-side check.
  - M6: §3.2 and §3.4. The cause is set once, in the failing turn, through the drain flag. No `LandMode` case is added. OnLeave is under D4.
  - M7: §3.4. The epoch check and the detach happen in one manager segment. The close code follows the keeper's cause.
  - M8: §3.7 and D5. The contract is "mutable access", with its coverage and gaps listed. The batch stops and the tick handler is skipped.
  - M9: §4. `SchemaExtractor` calls the shared function; the empty-collection claim is corrected; colliding keys are detected in the live conversion (D8); the cache is specified.
  - M10: §3.2 and D9. The record holds a terminal position (sequence, pass and stage), and replay stops there.
  - Shoulds: rows 15, 17 and 18 in §2; #536's per-player staged entry in Appendix A.3; PR 1's interim in §5; D7's rationale; §6; the holds in §8.
- **The main change from rev 1 (§1, D2a):** in the code at 9755a625, no failure is shown to depend on the recipient in a way that a rejoin repairs. This plan therefore recommends that every sync conversion or encode failure ends the land. The per-session path (4015 and its bound) moves to Appendix A as the alternative, fully specified, for the maintainer to choose.

**Inputs:**
- #535's body: a sync conversion or encode failure is no longer absorbed.
- The rule (maintainer, 2026-11-13): "If a failure can't be brought back to fully correct, end it; continuing is meaningless." A path that truly restores correct state stays.
- The scope decision (maintainer, 2026-11-13): end the smallest unit the failure has corrupted.

| Failure | What is wrong | Action |
|---|---|---|
| One player's per-player encode fails (#532) | only that player's view | close that session with a distinct code; it rejoins to a full view |
| Type errors | every recipient | refuse at registration where the type is knowable, otherwise close the land at the first throw |
| A broadcast encode fails, or the whole frame encoder fails | every recipient | close the land |
| A handler throws after partial state writes (#87) | the land's state | close the land |

The decision adds two notes. Closing a session must not loop: a repeat after rejoining escalates to the land. A malformed client input is rejected as today, and nothing else ends.

**Settled since rev 1 (maintainer, relayed 2026-11-13):**
- #521 D9 = (b): an event encode failure always ends the land.
- The per-session row keeps only failures shown to depend on the recipient. If none is left after that test, the 4015 path can shrink to nothing.

**Related:**
- #532: total per-player frame failure.
- #87: partial writes, folded in here.
- #531: a second session of one player.
- #102, #511, #512: the land stop and its OnLeave.
- #387: server-originated turn inputs.
- #536: per-player sync tables.
- #521: typed events and actions. Its plan uses this plan's stop for EV4 and EV7 (§3.6) and owns the replay loading skips (its A5).

## 0. Summary

- **Every sync failure ends the land (§1, D2a recommended).** That covers a conversion, a diff, a frame encode, an event encode, a sync plan past its bound, and a handler write before a throw. The land closes with a new code, 4016 `landFailed`. Types knowable at registration are refused there (§4).
- **The failing turn (§3.2).** The keeper marks the land failed through the existing drain flag, with cause `.failed`, in the turn where the failure is seen. That one segment closes intake for every existing `isDraining` check and settles every waiter. The rest of the batch and the tick handler don't run.
- **The adapter (§3.3).** It stops sending in the segment where it sees the failure. After every await it checks a ticket before acting. On the legacy sync path, it hands the failure to the keeper as a turn input with a ticket (#387).
- **The teardown (§3.4).** It is keeper-owned: it works with no transport, a custom one, or an adapter without a host. With a host, the stop path (#102) runs with an epoch-conditioned detach.
- **The sweep (§2).** The 19 rows, each with a verdict and the PR that changes it. The replay loading skips belong to #521's A5.
- **Delivery.** Four PRs (§7), with an interim rule (§5) until each lands.

## 1. Is any failure genuinely per-recipient?

#521's finding applies to every row. An event value is encoded once, before fan-out, so its failure is a fact about the value, and that is land-wide. The maintainer's direction: the per-session path keeps only failures shown to depend on the recipient. Each candidate at 9755a625:

**(P1) A per-player field's value in one player's view.** This is the output of the field's filter or policy for that player (`extractPerPlayerSnapshot`, SE 1456). The input does differ per recipient: which entities a player sees, or a value the policy derives for that player. But for policies that keep the documented purity contract (SyncPolicy.swift 129-131: "a policy expression must be pure … a filter closure must be a pure function of its arguments"), the view is a deterministic function of the land's state and the player. A policy that breaks the contract (a `@Sendable` closure that captures mutable state, or reads the clock or a random source) is outside this argument, as it is outside #514's byte-identity contract. A rejoin recomputes the same view from the same state and fails again, unless the state changed in between.
- So the failure is per-recipient in *who* hits it.
- But it isn't repaired by what the session close offers. The failing value is in the land's state, or is derived from it, and the next player to see it fails too.
- A session close only delays the land's end by one rejoin, and meanwhile the land keeps running with a state some views can't carry.

**(P2) The recipient's frame encode state**: its player slot, `.perPlayer` key scope, resync flag and sync sequence.
- None of these throws in the shipped encoders. The only explicit encoder throw is `pathNotInSchema` (OpcodeMessagePack…:435, OpcodeJSON…:423), and that is shared schema. The serializer's value errors are P1 or broadcast.
- Today only `syncEncodeFaultForTesting` produces #532's total per-player failure.
- A custom encoder (public, TA 1168, 1208) could fail per recipient. Nothing in the library shows one does, and the plan can't distinguish a per-recipient custom-encoder defect from an encoder-wide one by a single throw.

**Structured type causes** are type facts whatever the scope:
- `classRefusal`;
- `SyncError.unsupportedValue` "Unsupported type";
- `SyncError.unsupportedKey`;
- the #179 player-dependent node refusal;
- colliding keys (§4).

**Conclusion.** No failure in the shipped code is shown to depend on the recipient in a way a rejoin repairs. The plan recommends **D2a (a): no per-session path.** Every sync conversion or encode failure ends the land. The 4015 code, the rejoin bound, the `allRecipients` policy, the scope precedence and the staged closes aren't needed. Appendix A specifies them in full, in case the maintainer keeps the per-session row (D2a (b)). If a per-recipient source appears later (a custom encoder with per-session state, or per-player tables that encode per recipient), Appendix A is the design to add.

**What stays recoverable.** These paths restore fully correct state and are kept:
- a sync plan that throws as a whole, within its bound: it sent and committed nothing (row 15);
- the fallbacks that produce the same output by another route (rows 2, 5, 7);
- diagnostics (rows 6's oracle path, 18).

## 2. The sweep, row by row

Verdicts:
- **land**: ends the land;
- **stays**: the path restores fully correct state, and is kept.

Under D2a (b), the rows marked † are classified by Appendix A instead.

| # | Site at 9755a625 | Today | Verdict | PR |
|---|---|---|---|---|
| 1 | SE 1405-1431 `extractDroppingThrowingFields` | a field whose conversion throws is dropped, and its cached value is kept | land† | 2 |
| 2 | SE 1484-1500 `extractWithSnapshotForSync` | `try? snapshotForSync`, falling back to per-field extraction | stays: a route, and its drops are row 1. The fallback must surface the per-field error to row 1, not swallow it | none |
| 3 | SE 1508-1534 `lateJoinSnapshot` (dropping); TA 4640-4660 | a full view without the fields that don't convert, filled from caches | land†. The cache fill goes | 2 |
| 4 | ST 1639-1662 `diff`, ST 1521-1535 `stageSeed` | a broadcast slot whose diff or seed throws is dropped | land | 2 |
| 5 | ST 559-590 `SyncEquatableDiffer.diff` | a `.standard` leaf whose convert throws falls back to the snapshot diff, with a release log | stays: the same output as the snapshot diff, whose own throw is row 4 | none |
| 6 | ST 1142-1144, 1194-1196 `lastSentSnapshot` | a last-sent value that no longer converts reads nil | view path (TA 4655): land; the view would miss a field. Oracle path (ST 1555): stays, as diagnostics | 2 |
| 7 | ST 1612-1620 `viewPatches` | `try?`: a field whose rows don't convert keeps today's patches | stays: today's patches carry the same field, and their own conversion is rows 1 and 3 | none |
| 8 | TA 4453-4463, 4603-4612 (row drop and remake) | rows whose patches don't encode are dropped from the tables, and the plan is remade with key scopes reset | land. The leak (below) goes, and so do the remake, `planFailedRows`, `rowRetryFields` and the repair result | 2 |
| 9 | TA 4745-4813 `planMergedBroadcastFrame` | re-encode dropping; a total failure unstages the broadcast tables and sends the events as 103 frames | land (drop or total) | 1 |
| 10 | TA 4897-4958 `planPerPlayerFrames` | re-encode dropping; on nil the player's staged cache is dropped and nothing is sent (#532) | land† (dropped patch or total) | 1 (total), 2 (patches) |
| 11 | TA 4929-4938, 3574-3586, 3633-3635, 3686-3721 (resync and first-view retry, 4012) | not sent, retried, closed with 4012 after `snapshotEncodeFailureLimit` (3) | land† (D3). 4012 stays reserved and is no longer sent | 2 |
| 12 | TA 5473-5535 broadcast-only frames | re-encode dropping per player; on nil, skip | land | 1 |
| 13 | TA 5764-5830 `planFirstSync` | re-encode dropping; even empty fails → `unencodableFirstViews` | land†. With row addressing on, the standalone first sync is refused anyway (TA 5767-5771) | 2 |
| 14 | TA 5652-5689 `encodeDroppingUnencodablePatches` | each patch tried alone; `pathNotInSchema` counted, others dropped (or the row) | removed. An encode that throws is a failure; nothing is retried to drop patches. The error goes into the log and `LandFailure.detail`. A diagnostic pass may find the first failing patch for the log only (D6 for `pathNotInSchema`) | 1 (callers in 1), 2 (the rest) |
| 15 | TA 3287-3331, 3200-3205; in-turn TA 2896-2917 → LK 4423-4436 | a plan that throws commits nothing; ordinary follow-ups are bounded at `syncFailedPlanFollowUpLimit` (3) without periodic sync; past the limit, join-sync turns keep being scheduled with a doubling delay (LK 4427-4434); with periodic sync every tick retries | stays within one bound for both kinds of land: consecutive failed plans, **join-sync attempts included**, end the land at the bound (D11). A committed plan resets it: a plan that threw sent nothing, so a later success is fully correct. The doubling join-sync retry goes away. With periodic sync this is a behavior change: today it retries forever | 1 |
| 16 | TA 5706-5761 `_syncStateForNewPlayer` | logged, then a follow-up. With row addressing in effect: closed with 1011 | a conversion or encode failure in the joiner's view: as row 13. A plan throw: row 15. 1011 is unchanged (an invariant, not a sync failure) | 2 |
| 17 | TA 3127-3138 `appendEventFrames` (`try? pack`); TA 2792-2806 (merged body at enqueue) | a frame that fails `pack` is skipped. At enqueue, a nil merged body falls back to a standalone frame (`.sentAlone`) or is `.lost` | land on `pack` failure and on `.lost`. **A nil merged body that is sent alone isn't a loss** and doesn't end the land (#521 D10 removes that attempt). The same rule as #521 EV4 | 1 |
| 18 | TA 3989-3993 `canonicalEvent` | a payload that doesn't convert makes the digest's events scope unverifiable | stays: diagnostics, not client state. The canonical snapshot conversion and the wire encode are different operations, so neither implies the other | none |
| 19 | TA 202-209 `leavesKeyTablesAhead`, set at 4780, 4950, 5482, 5524 | the key scopes are reset in the next plan | removed in PR 1. Its four setters are rows 9, 10 (total) and 12, which PR 1 converts | 1 |

**Row 8's leak.** The path is TA 4689 → 5678 → 4603 → 4453, for patches that carry row metadata. `encodeDroppingUnencodablePatches` adds a row to `planFailedRows` whatever frame it encodes. A joiner's or unsynced recipient's full view carries broadcast row patches, so a per-recipient encode failure drops broadcast rows for every recipient. Under this plan the failure ends the land, so no broadcast state is changed on its behalf.

**Replay loading.** LK 4126-4139 and 4251-4256 go to #521's A5 staged batch, per Main. This plan has no PR for them.

## 3. The mechanism

### 3.1 Types (core, `SwiftStateTree`)

```swift
/// Why a land was ended by a failure (#535).
public struct LandFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable {
        case syncConversion   // a synced value didn't convert
        case syncEncode       // a state frame didn't encode
        case syncPlan         // the sync plan kept throwing past its bound (row 15)
        case eventEncode      // an event didn't encode (row 17; #521 EV4, EV7)
        case handlerWrite     // a handler threw after mutable access to synced state (#87, §3.7)
    }
    public let kind: Kind
    public let field: String?     // the root field, when known
    public let detail: String     // the error's text
    public let position: LandFailurePosition   // where the land stopped (D9)
}

/// Where in the land's input stream a failure stopped it (D9).
public struct LandFailurePosition: Sendable, Equatable, Codable {
    public enum Stage: String, Sendable, Codable {
        case input          // while applying the input `sequence`; later inputs weren't applied
        case tickHandler    // in the tick handler (not used by this plan; reserved for #87 (A))
        case syncPhase      // after the turn's inputs and tick handler, in its sync phase
        case eventFlush     // in the legacy event flush after the turn
    }
    public let tickId: Int64?
    public let pass: Int?        // tickless: the pass
    public let sequence: Int64?  // the input applied when the failure happened, for .input
    public let stage: Stage
}
```

- **`LandDestructionCause` gains `failed`** (LK 5334). This is a public enum case: an exhaustive `switch` breaks, and the PR body says so. The `LandFailure` itself is readable on the keeper as `nonisolated var failure: LandFailure?`, set in the same segment as the cause.
- **No `LandMode` case** (Review M6). The failure is the drain flag's cause plus a private stored `LandFailure`.

### 3.2 The failing turn

`LandKeeper.failLand(_ failure: LandFailure)` is private and synchronous, and is called only inside a turn. It follows `completeShutdownTurn` (LK 4852-4861), which already does this for a shutdown input, at the end of its batch.

**Two parts (Review P1, rev 4's fix corrected in rev 5).** A failure can be seen in the middle of a batch (`.handlerWrite`), while `applyInputs` still holds the whole batch in `pendingItems` and removes the consumed prefix only after its loop (`removePendingItems(Array(items.prefix(consumed)))`, LK 3876). The settle can't wait for the turn's end: the publication covers the whole batch and comes after an await.
- In the in-turn input drain, `runInputTurn` stores a result for every item of the batch and returns `appliedItems: batch` (LK 5002-5010); `runInputDrain` awaits `submitTurnRecord` and only then resumes the waiters, giving an item with no outcome `.success(())` (LK ~4954-4958, 5016). An unexecuted item would be resumed with success, and a settle after that await would mutate keeper state after a suspension.
- In the legacy pass, `processPendingActions` awaits between `applyInputs` and its publication (`finishTicklessLegacyPass`, `holds.at(.turnRecord)`, the recording, LK 3663-3690), with the suffix still in `pendingItems`, and `applyInputs` doesn't check the drain: another caller's pass could apply it after the failure.

So the queue part of the settle runs **in the apply segment**, where `completeShutdownTurn` already ends a batch at a shutdown (LK 3876-3878):
- **The mark** (steps 1, 2 and 4) runs where the failure is seen: it stores the failure, sets the drain flag, and breaks the loop.
- **The settle** (step 3) runs right after the loop, in the same synchronous segment: `applyInputs` removes the consumed prefix (the items before the failing one, and the failing item with its handler error as its outcome), then drops the unexecuted suffix and everything queued behind it with `landClosed`, then calls `cancelAllActionJobs`, `releaseHeldInputsForDrain` and `resumeShutdownTurnWaiters`. No await separates any of it from the failure.
- **`InputApplication` carries `consumed`.** `runInputTurn` writes `inputTurnResults` and `appliedItems` for the consumed prefix only, so the suffix, already failed by the settle, is never resumed with `.success(())`. The legacy publication already filters by `outcomes`. The prefix's waiters, the failing item's included, get their real outcomes through the normal publication.
- A failure seen in the sync phase (in-turn) or applied from a `landFailure` item comes after the turn's inputs were applied and published from the same segment's state, so its mark and settle are adjacent there.
- **The turn's end** (steps 5 and 6) touches no keeper state: the terminal entry and the teardown's start are taken out of the keeper into locals in the apply segment (the stored entry is cleared there), and the end of the turn hands them on (step 5 gives the order).

Setting the drain flag in the middle of the batch changes nothing for the rest of the turn's completion: publishing the prefix's outcomes and building the turn's record don't check `isDraining`. The PR asserts that.

The steps:
1. **Stores `failure`**: the first one wins, and later ones are logged at debug.
2. **Closes intake:** `drainFlag.set(cause: .failed)`. The first cause stays (`DrainFlag.set`, LK 5326), so a later `forceShutdown` can't overwrite it.
   - From here every existing `isDraining` check refuses. In LK: 1426, 1474, 1649 and 1703 (joins resumed after their awaits), 1805-1870 (the join and leave resolvers), 2439, 2515-2529 (`forceShutdown`), 2980 (`submitServerInput`), 3392, 4060, 4785, 4823 and 5193-5195.
   - In LM, 373, 427, 475 and 483 count a draining keeper as absent, so a join to the land ID waits for this instance to be dropped, then builds a new one.
   - The PR lists each site with the test that reaches it.
3. **Settles every waiter** (in the apply segment): `dropPendingInputs(reason: "landFailed")` on the suffix and what is queued behind it, `releaseHeldInputsForDrain()` and `resumeShutdownTurnWaiters()`, as the shutdown turn does. `dropPendingInputs` already fails:
   - `inputTurnWaiters` (LK 628);
   - legacy pass callers;
   - tickless action job slots, with `LandInputRejection.landClosed`.

   Inputs applied in this turn, the failing one included, were removed as the consumed prefix before the drop: they keep the outcomes the turn publishes, and no slot is filled twice. Three more waiters are added to the settle:
   - **Action jobs still in their resolvers** aren't in `pendingItems`, so `dropPendingInputs` doesn't reach them. The settle calls `cancelAllActionJobs()` (LK 2244), after the drain flag was set by the mark, in the same order as the empty-room drain (LK 5171-5174). `cancelActionJob` fills each caller's slot at once with the delivery check's rejection (`rejectIfLandClosed`, LK 1869-1872, which now throws `landClosed`) and cancels the job's task. It skips a job already completed or already cancelled (LK 2252), so every slot is filled exactly once, including a job whose result was delivered earlier in this turn. A job whose resolvers resume later finds its slot filled and its delivery refused (`deliverResolvedAction` checks `rejectIfLandClosed`).
   - **Server inputs in flight:** counted down by the drop.
   - **The input that failed** (for `.handlerWrite`): its caller gets the handler's error, as today.
4. **Stops the batch and the tick** (§3.7). The input loop (`applyPendingItems`, LK 3849-3874) breaks after the failing item. `runTick` checks the failure before `handler(&state, ctx)` (LK 4472) and doesn't run it, and it runs no sync phase. Later ticks don't start: the tick loop checks `isDraining`.
5. **Finalizes the record** (D9), unconditionally (Review P2). The terminal entry can't ride on the failing turn's own submission, because some failing turns submit nothing:
   - a sync-only turn (`runSyncOnlyTurn`) never calls `submitTurnRecord`, and its `enqueueTicklessTurnEnd(since:)` returns early when nothing was submitted (LK 4680-4683); a failing plan commits nothing;
   - the turn that applies a `landFailure` item: the item isn't an input, and `runInputDrain` skips submission when `outcome.record.isEmpty` (LK 4952-4957);
   - legacy tick-land recording calls `recorder.record` directly and conditionally (LK 3690-3706).

   So every turn that ran `failLand` ends with a finalize step, `finalizeFailureRecord(entry)`, of its own. The entry was moved out of the keeper into a local in the apply segment, so the step mutates no keeper state:
   - **with a recorder:** the step runs after the turn's own submission (`submitTurnRecord`, when the turn has one) has been handed to the recorder, and submits the entry to the same ordered recorder pipeline, so it lands after that turn's record whatever the pipeline's internal awaits. When the turn submits nothing (the three cases above), it is the turn's only submission. On the legacy tick path, which records directly, the same task writes it after the tick's record;
   - **without a recorder:** nothing is written (the stored entry was already cleared in the apply segment).

   The teardown (step 6) starts only after this step has handed the entry to the recorder, so any entry the teardown writes comes later.

   The entry isn't an input.
6. **Starts the teardown outside the turn** (§3.4).

**Callers:**
- **In-turn sync.** `applyInTurnSyncResult` is called on a new `InTurnSyncResult.landFailed(LandFailure)`, which the adapter returns from the synchronous sync phase. The sync phase committed nothing and sent no state frame. Events enqueued before it in that turn are already in the writer; they are correct events, sent before the land ended.
- **Input application**, on `.handlerWrite` (§3.7).
- **The turn that applies a `landFailure` item** from the legacy path (§3.3).

### 3.3 The adapter

**It stops at once, in its own state.**
- In the segment where it sees a failure, the adapter sets its private `landFailure` and bumps a `GenerationTable` generation for the land's output.
- From then on, every send path (state, broadcast-only, events, first sync) returns without sending.
- Every plan returns `.landFailed`.

This state belongs to the adapter, not the keeper, so the keeper rule doesn't bind it. It closes the window before the keeper's turn.

**Resume-side checks.** Every adapter path that awaits between reading state and sending captures the output generation before the await. After the await, it acts only through `ifCurrent`:
- the legacy `withSyncState`, from its state read (TA 3301) to its commit and sends (TA 3318);
- the first-sync suspensions (TA 5722-5740);
- the legacy event flush, per event;
- the broadcast-only sync;
- **debug settle** (TA 6671-6682): it reads the state with an await (`beginSyncLocatedIfRecording`), then runs `runFullSyncPhase`; the run is skipped on a stale generation;
- **the action-result output** (TA 5941-5993): it has its own ticket domain (the action's sequence), and is covered below.

The PR lists every `await` in these paths, and a test holds at each (§8).

**On a stale generation, the mandatory cleanup still runs.** A sync that read the state calls `keeper.endSync()` (TA 3327-3328, 6677-6682) whether or not it sends, so the keeper's sync bookkeeping isn't left open.

**Action responses and errors after the failure.** "No output after the failure" means no state frame and no event frame. Action responses and errors are sent **best effort, until the session's membership ends**: they report what the keeper decided for that request, which stays true, and carry no land state. The teardown forwards each session's disconnect before it closes the socket, and that ends the session's response tickets and cancels its response tasks (TA 1559-1563: "nothing is sent to the closed session"); a `finishActionResponse` suspended at TA 5974-5993 is then dropped. So a response to an input applied before the failure, or a dropped input's `landClosed`, can be lost while the socket is still open. No barrier is added: the client gets the 4016 close, which tells it the land failed, and an in-flight request's outcome is undefined after a close in any case.

**The legacy path's failure becomes a turn input.**

```swift
extension LandKeeper {
    /// The transport reports a failure that ends the land. Applied in a turn of its own, as
    /// server inputs are (#387); `ticket` is the keeper's lifecycle generation captured when the
    /// failing work began. A stale ticket (the land restarted meanwhile) is ignored.
    package func submitLandFailure(_ failure: LandFailure, ticket: LandLifecycleTicket) async
}
```

- The item is internal (`PendingItem.landFailure`), not a user `HandleServerInput`, and it isn't recorded as an input.
- **It carries two positions** (D9). The *output position* is the last committed tick or pass whose state the failing output read. **This needs a code change:** `beginSyncLocatedIfRecording` returns no position when in-turn sync is off (TA 3855-3861), so the legacy state read (TA 3301) can't capture it today. The keeper's `beginSync` returns the last committed tick and pass with the state whenever a recorder exists, in-turn or not, and the adapter keeps it with the failure. The *end position* is the turn that applies the item. Turns between the two ran live, with their inputs applied and recorded, so replay runs them; the run ends at the end position.
- The turn that applies it re-reads the drain flag and validates the ticket, then calls `failLand`.
- A tickless idle land schedules that turn as `submitServerInput` does.

### 3.4 The teardown (keeper-owned)

After `failLand`, the keeper starts one `Task` that holds no keeper state across its awaits and runs:

1. **`await transport.landDidFail(failure)`**, a new `LandKeeperTransport` requirement whose default does nothing. A custom transport therefore compiles, and the keeper still tears the land down. `TransportAdapter` implements it:
   - **With a host hook** (`onLandFailure`, which `LandManager` installs at creation with the instance's epoch): the server's stop, with the epoch.
     - `LandManager.detachForStop(landID:epoch:)` detaches only if the stored instance has that epoch, in one synchronous segment (Review M7). The epoch check and the detach can't be split by an await. Epochs are the manager's (LM 125-126).
     - The stop then closes the bound sessions. **Where the code is decided is D10.** Today the server picks the `SessionClose` value before `await landRouter.closeSessions` (NIOLandServer 181), and the router then awaits its snapshot (LandRouter 469), each adapter lookup (474) and the leave forwarding (482-486) before it closes anything. Under the recommended D10 (a), `closeSessions` takes a closure the router evaluates when it **issues** each session's close request, after that session's leave and `afterLeave` (LandRouter 425-440, 479-487); it reads `keeper.destructionCause` (nonisolated) and gives 4016 for `.failed`, 4014 otherwise. The code is "the cause as of the router's close request". The request then hops to the `WebSocketTransport` actor to close, so a failure in that last hop still leaves 4014; the plan accepts that window rather than threading the closure into the transport.
     - The destroy sees `.failed` whenever the failing turn set the drain cause first (step 2). `SingleFlight` keeps the stop's work to one run.
     - **OnLeave on the router's leave (D4).** The router's close forwards each session's leave to the keeper (`adapter.onDisconnect` → `keeper.leave`, LandRouter 425-440, 462-487). `leave` removes the player, then runs the OnLeave resolvers (LK ~2398-2420), and checks `isDraining` only after them (LK 2439). On a failed land, under D4 (a), `leave` checks `failure` **before** the resolvers: it removes the player and ends its membership in the adapter and router as today, and skips the resolvers and the handler. Everything the OnLeave input would have done is skipped with them: its sequence allocation, its lifecycle record, the handler, and the broadcast-only removal sync it requests (LK 3639-3643). The keeper's membership removal doesn't remove the player's entry in the application's state (for example `state.players[id]`): that is OnLeave's job, and the destroy handlers see it. The other drain causes keep today's order.
   - **Without a hook** (an adapter built directly): the adapter closes every session it holds with 4016 through `endAndCloseSession`.
2. **The keeper's own destroy:** a private `destroyFailedLand()`.
   - It clears `players` without OnLeave (D4 (a); under D4 (b) the router's leaves have already run them).
   - It runs the destruction that `shutdownIfIdle` runs after its guard: the destroy handlers, the save and `transport.onLandDestroyed()`. The emptiness guard is skipped because the players were just cleared, and the cause is already `.failed`.
   - Whoever reaches the drain first runs it, the host's `forceShutdown` or this task. The other waits on `drainTask`. `runForceShutdown`'s non-live branch (LK 2515-2518) sees `isDraining`, clears the players and waits. Its `.forceShutdown` cause is ignored, because the first cause stays.

**So:**
- with no transport, a custom one, or an adapter without the hook, the land ends and its destroy handlers run with `.failed`;
- with a host, the sessions close with 4016 and the land detaches.

### 3.5 Counters and logs

- **Counter:** `landFailures`, by `Kind`, on the adapter's profiler counters and the land's stats.
- **Log:** one `error` log per failure. Its fields:
  - land type and ID;
  - kind and field;
  - error text;
  - position;
  - sync sequence and target.
- **A malformed client input** is unchanged: rejected, and counted as today.

### 3.6 Names for #521 (coordinated through Main)

#521's EV4 and EV7 use:
- `LandFailure.Kind.eventEncode`;
- in a turn, the adapter's `.landFailed`;
- on the legacy flush, `submitLandFailure(_:ticket:)`, with the ticket captured when the flush began.

EV5 doesn't exist (#521 D9 = (b)).

Registration goes through one function, `LandDefinition.validateForRegistration(context:)` (§4). This plan's PR 3 adds it with the sync-type checks, and #521 adds its payload checks into it. Whichever merges first adds the function.

### 3.7 #87: a handler that throws after mutable access

**Today.** A throwing input fails alone, and its writes before the throw are kept. Debug builds warn by comparing `fullStateSnapshot` (LK 3141-3191). The maintainer's 2026-11-10 decision on #87 was (B) for now, and (A), an undo log, with flat storage step 3.

**Under #535's table.**
- A handler that throws after writing synced state ends the land (`.handlerWrite`, stage `.input`, its sequence). The batch stops and the tick handler is skipped (§3.2 step 4). Today the loop continues past a throw (LK 3849-3874) and `runTick` then runs the tick handler (LK 4462-4472), so both are asserted.
- A handler that throws with no write is a rejected input, as today.
- When #87's (A) exists, a rollback restores state, and the throw goes back to rejecting the input alone.

**The detector (D5).** The recommended contract is **mutable access**, not actual change.
- `@Sync`'s `_modify` already sets `_isDirty` before its yield, "so a write made before the throw is kept" (SyncPolicy.swift 140-156). The detector uses that same point: `@Sync`'s setter and `_modify` bump an access count at entry.
- **Where the count lives: not in the state.** It is a thread-local counter that `withMutableStateSync` installs for the handler call and reads back after it. The handler path has no await (LK 3141-3159), so the call runs on one thread, and a thread-local is sound where a `@TaskLocal` isn't needed. The mechanism is a POSIX thread-specific key (`pthread_key_create` / `pthread_getspecific`), which works on macOS and Linux, in a small `Support` helper. The install saves the previous value and restores it with `defer`, so a nested or re-entrant handler call and a later keeper on the same pooled thread start from their own count. `@Sync`'s accessors increment it when installed; otherwise they do one thread-local read. No stored property is added to any `StateNode`, so `Equatable`, `Codable`, snapshots, the state hash and the record don't change by a byte.
- **Cost:** one thread-local read per `@Sync` write outside handlers, plus an increment inside them; the install and read-back per handler call. Wrap-around is harmless (`&+=`, only equality before and after is compared). The off-path A/B measures it.
  - So `try validateThenMutate(&state.x)` counts as a write even when the validation throws first.
  - The documented rule is: validate before taking `inout` access. This is the rule #87's (B) already states.
- **Coverage:**
  - Root fields' setters and `_modify` count.
  - Containers and nested nodes are reached through their root field's `_modify`, so they count.
  - A nested node's own fields count through the root's access.
- **What it can't see** (named in the docs, beside #87's (B) rule):
  - **whole-state replacement** (`state = other`): no accessor runs;
  - **a copy held from before the handler, assigned back** (the same replacement);
  - **storage without `@Sync`**: a hand-written `StateNodeProtocol` conformance, or any synced storage that doesn't go through `@Sync`. A manual conformance that uses `@Sync` is counted.
- **Its false positive:** a handler that writes a temporary `@Sync` value of its own (a local wrapper, not the land's state) counts as a write, and a throw after it ends the land. The docs name it; the PR's tests pin it.

  For these, debug builds keep the existing snapshot compare and warn; release builds keep today's behavior (the input fails alone). A test covers a caught case (an in-place write through a copy of a nested node, written back through `_modify`) and pins each uncaught case as a named gap. D5 (b) and (c) are the alternatives.

## 4. Registration refusals

**Knowable from the type**, checked by walking the schema and the type:
- **A class type in a synced field** (`classRefusal`). `SyncValueSemantics.validate` walks declared element and value types of collections, including empty ones (SyncValueSemantics 72-80). Plain structs, tuples and enum payloads, though, are looked into through the default instance's **values** (SyncValueSemantics 18-26). So a class is unseen behind an existential (`Any`, `any P`), inside a struct inside an empty `[Holder]`, or in an enum case the default instance doesn't take.
- **An unsupported key type** (`SyncError.unsupportedKey`, SnapshotValue.swift:476). This check is new.
- **A player-dependent node under a broadcast field** (#179). `SyncPolicyNesting.validate` covers it, with the same value-walk gaps (SyncPolicyNesting 29-32, 114-134).

For every gap, the runtime backstop stays: the land ends at the first throw.

**Not knowable from the type**, so the land ends at the first throw:
- a value the default instance doesn't hold: an existential field's value, a struct inside an empty collection, an enum case not taken (as above);
- a user `toSnapshotValue` that throws;
- a non-finite number under JSON.

**Colliding keys** (D8). Today they throw only in `makeFull`, the replay-hash path. The sync `make` path overwrites silently (SnapshotValue.swift:427), so "close the land at the first throw" would never fire for a type error the maintainer listed. The recommended answer is to detect them in the live conversion:
- `make` checks the insert's previous value (`updateValue` returns non-nil) and throws `SyncError.collidingKeys`;
- it is a structured type cause, so the land ends;
- the cost is a nil check per dictionary entry, which the off-path A/B measures on the actual code.
- **The promise covers the library's conversion only.** A custom `toSnapshotValue` that builds its own `.object` has merged its keys before the library sees them; that stays the type's own contract, and the docs say so.

**Entry points:**

| Entry point | Today | Under this plan |
|---|---|---|
| `NIOLandHost.register` (NIOLandHost.swift:354) | throws; validates at :363-364 | calls `validateForRegistration` |
| `LandTypeRegistry.init` (LandTypeRegistry.swift:33-39) | throws; validates | calls `validateForRegistration` |
| `SchemaExtractor.extract` (:20-21) | calls the two validators directly | calls `validateForRegistration` explicitly |
| `ReevaluationEngine.run` (ReevaluationEngine.swift:192) | throws, no validation | validates before the keeper is built; the run fails with the error |
| `LandManager.getOrCreateLand` (LM 367) | no validation | none needed: a manager from a host or registry is validated there, and a manager built directly is covered by the backstop |
| `LandKeeper.init` (LK 807) | doesn't throw | unchanged |
| `LandKeeper.ensureInitialized` (LK 893) | async throws; a failure tears the land down (LK 927-932) | **the backstop**: runs `validateForRegistration`. A refusal fails initialization, as an OnInitialize throw does today |

**The backstop's cache.**
- The sync-type checks call `State.init()` and inspect its values, so their result depends on a sample. It may be cached only under a stated contract: **a state type's default `init()` is deterministic** (the same values on every call, no clock, random source or global state). The docs state it next to the existing purity contract, and a type that breaks it is outside the cache's promise; the runtime backstop still ends the land at the first throw.
- Under that contract the result, **failures included**, is cached process-wide by `ObjectIdentifier(State.self)`, in a `Mutex`-guarded dictionary. The user's `init()` and the walk run **outside** the lock: the lock is taken only to read the entry and to insert the result. Two keepers racing on a new type may both validate; the first insert wins, and both results are the same under the contract.
- Definition-dependent checks aren't cached; tests reuse definition IDs. They run per keeper, and they are cheap: #521's checks look up the registered types.

All failures are reported in one error, `SyncRegistrationError`, with one case per row, the field path and the reason. It sits beside #521's `PayloadRegistrationError` under `validateForRegistration`.

## 5. The interim rule

- **Until each row's PR lands, a known absorb path keeps today's behavior.** Its tests pin today's output and cite #535, as #514's plan does.
- **New code adds no absorb path.** Before PR 1, a new failure path logs at `error`, counts, and pins the gap with a test that cites #535.
- **After PR 1, new code uses the mechanism.**
- **Between PR 1 and PR 2:**
  - PR 1 converts only the total-failure paths (rows 9, 10 total, 12, 15 and 17), and it removes `leavesKeyTablesAhead`, whose four setters are those paths.
  - The patch-drop paths (rows 1, 3, 4, 6, 8, 10 patches, 11, 13 and 14's helper) keep their recovery until PR 2, including the row repair (`planFailedRows` and `committedWithRepairPending`).
  - These don't interact: a dropped patch never sets the key-reset flag, and a total failure never reaches the row repair.
  - The pinned interim tests name which PR replaces them.
- **#514 and #536 (per-player tables).** Their interim outputs for a throwing conversion and a failed encode are replaced in PR 2. The failure half of #514's byte-identity contract holds once PR 2 is in: after it, no failed land keeps running.

## 6. Public API

| Change | Kind |
|---|---|
| `LandFailure`, `LandFailure.Kind`, `LandFailurePosition` | new types |
| `LandKeeper.failure` (nonisolated) | new property |
| `LandDestructionCause.failed` | new enum case (an exhaustive switch breaks; named in the PR) |
| `InTurnSyncResult.landFailed(LandFailure)` | new enum case on a public protocol's result (the same note) |
| `InTurnSyncResult.committedWithRepairPending` | no longer returned after PR 2; deprecated (D7) |
| `LandKeeperTransport.landDidFail(_:)` | new requirement with a do-nothing default |
| `SessionClose.Code.landFailed` (4016); `SessionClose.landFailed` (package, as `.landStopped`) | new constant |
| `SyncError.collidingKeys` | new enum case (D8; the same switch note) |
| `SyncRegistrationError`; `LandDefinition.validateForRegistration(context:)` | new; thrown by entry points that already throw |
| `@Sync`'s accessors: the thread-local access count (D5) | no public API; package-level, and no stored property on any state |
| `TransportAdapter.unmappedPathPatches` | kept; it counts `pathNotInSchema` failures (D6) |
| TS SDK: `LAND_FAILED_CLOSE_CODE` (4016) in `protocol.ts` | new export; the docs say the instance is gone |

- **No `LandMode` case.** No new keeper access for the transport: the teardown is the keeper's own (§3.4).
- **`package`-only members:** `submitLandFailure`, `detachForStop(landID:epoch:)`, the adapter's `onLandFailure` hook.
- **Behavior changes,** named in each PR body and in `docs/` (bilingual):
  - a land with a sync failure ends with 4016;
  - 4012 is no longer sent;
  - a handler that throws after mutable access ends the land;
  - colliding keys end the land.

## 7. PRs

1. **PR 1, the mechanism and the total failures.**
   - §3.1–3.5, `submitLandFailure`, `landDidFail`, the epoch-conditioned detach, 4016.
   - Rows 9, 10 (total), 12, 15, 17 and 19.
   - The SDK constant and the docs.
2. **PR 2, the conversion and per-patch paths.**
   - Rows 1, 3, 4, 6, 8 (with the leak), 10 (patches), 11, 13, the rest of 14, and 16.
   - Colliding keys in the live conversion (D8).
   - The repair's removal (D7).
3. **PR 3, registration.** §4, `validateForRegistration` and the backstop. It is independent of PRs 1 and 2, so it may go first.
4. **PR 4, #87.** §3.7, after D5. It settles #87's (B) and leaves (A) open.

**The failure-handling page.** `docs/core/failure-handling.md` and its `.zh-TW.md` (on `main`, 44f15d90) list each path with its status. Each PR flips its rows from "target" to "current", in both languages, in the same PR:
- PR 1: "A server event that fails to encode" (with #521); "One player's state frame fails to encode entirely" (#532, to "the land"); and the "Close codes" section (4016).
- PR 2: "A resync's full view keeps failing to encode" (if D3 (a)), since its per-patch part is row 11, which PR 2 converts; it stays "target" until then.
- PR 2 also: "A field whose conversion throws at run time"; "A patch the encoding can't carry … or a path outside the schema".
- PR 3: "Other type errors the type alone decides" (refused at registration), with the gaps of §4 named.
- PR 4: "A handler that throws after writing state".
- Under D2a (a), the "If a failure is confined to one player's view" row of the summary table says no such failure is known, and why (§1).

**Gates.** PRs 1 and 2 touch the sync phase. Each gets:
- the in-turn on/off and sync-tables-off CI builds;
- an off-path A/B on the healthy path, judged by the instruction gate (#517).

PR 4 gets the same A/B, for the access count on every write. PR 2 gets it for the collision check.

## 8. Tests

Swift Testing. An interleaving is forced with a hold at the `await` (`HoldPoints`, `TestGate`), never with timing.

**Faults:**
- **Existing hooks:**
  - `syncEncodeFaultForTesting(PlayerID)`;
  - `syncPlanFaultForTesting`;
  - `firstSyncPlanFaultForTesting`;
  - `eventEncodingFaultForTesting`.
- **Throwing test types** (`TransportAdapterSyncPhaseTests`, `RowAddressingAdapterTests`, `SyncTableDiffTests`), and NaN under JSON.
- **New package hooks:**
  - a merged-107 encode fault (today `syncEncodeFaultForTesting` doesn't reach it);
  - a broadcast-only encode fault.

**Cases.** Each runs on all three encodings, with in-turn sync on and off where both paths exist.

- **Each land row (§2):**
  - the land ends with `.failed` and the right `Kind`;
  - every session closes with 4016;
  - no state frame of the failing plan, and nothing after it, is sent;
  - another land on the same host keeps syncing;
  - a join to the same land ID afterwards gets a new instance;
  - with #536's per-player tables on, the same.
- **Row 15:**
  - throwing plans end the land at D11's bound, with and without periodic sync;
  - join-sync attempts count toward the three;
  - a committed plan in between resets the count.
- **Row 17:**
  - a `pack` failure and a `.lost` event end the land;
  - a nil merged body sent alone doesn't.
- **The failing turn:**
  - after `failLand`, actions, events, server inputs and joins are refused;
  - every waiter of §3.2 step 3 is settled with `landClosed`: an input queued behind the failure, a legacy pass caller, a tickless action job, a server input in flight, and an action job resumed from its resolver;
  - a join held at each of LK 1426, 1474, 1649 and 1703 is refused on resume.
- **The adapter's resume checks:**
  - holds right after the legacy state read (TA 3301), at each first-sync suspension (TA 5722-5740), and in the legacy flush between events;
  - a failure during the hold means nothing is sent after it.
- **The legacy path:**
  - a failure on the legacy sync and on the legacy event flush reaches the keeper as a turn input;
  - a stale ticket (the land restarted under a hold at the flush's await) is ignored.
- **Action jobs (N1):** an action held in its resolver when the land fails gets `landClosed` at once, before the teardown's `landDidFail` returns; its resolver resuming later doesn't fill the slot again.
- **OnLeave on a failed land (D4):** with a host, an OnLeave resolver held when the failure arrives; under D4 (a), a leave forwarded by the router after the failure runs no resolver and no handler, and the player's membership ends in the adapter and the router.
- **Debug settle:** a failure during debug settle's state read sends nothing and still calls `endSync`.
- **A mid-batch failure (Review P1):** a batch of A (succeeds), B (throws after a write) and C (not executed), each once as an action with a tickless job slot and once with an ordinary turn waiter: A gets its response, B its handler error, C `landClosed`; each slot is filled exactly once (a slot hook that fails on a second fill). It fails if the settle moves after the publication:
  - in-turn: C's waiter gets `landClosed`, never `.success(())`, and `appliedItems` holds A and B only;
  - legacy: with a hold at `.turnRecord`, C's own caller runs its pass during the hold, and C stays unapplied (its handler never runs) and gets `landClosed`.
- **The finalize step (Review P2):** the terminal entry is recorded for a failure in a sync-only turn (nothing else submitted), in the turn applying a `landFailure` item, on the legacy tick-land recording path, and in an input drain; it comes after any record of that turn and before any teardown entry; without a recorder nothing is written.
- **The legacy output position:** with in-turn sync off and a recorder, a legacy sync failure records the position of the state it read, and the turns run between it and the turn that applied the item replay.
- **D5's thread-local:** two keepers run in turn on the same thread (a single-thread executor), the second starting from a clean count; a nested handler call restores the outer count; the temporary-`@Sync` false positive is pinned.
- **Record order (D9):** the terminal entry comes after the failing turn's record, for a tick land, a tickless pass and a sync-only turn; on the legacy path, the record holds both positions, and the turns between them replay.
- **The teardown:**
  - with a host, a hold right before the manager's detach, with an admin `DELETE` racing it. The stop runs once.
  - The close code (D10): a failure arriving while the router is held after its snapshot (`stopSnapshot`) gives 4016 to every session whose close request is issued after it, under D10 (a).
  - A failure for an old epoch (the land ID has a new instance) detaches nothing.
  - Without a host, and with a custom transport using the default, the land is destroyed with `.failed` while players were still in it.
  - Destroy handlers see `.failed`; OnLeave runs or doesn't, per D4.
- **Registration (PR 3):**
  - each type-knowable error at each entry point of §4, including `SchemaExtractor` and the backstop for a directly built keeper;
  - all failures in one error;
  - a cached failure refuses the second keeper too.
- **Colliding keys (PR 2):** two keys that collide in conversion end the land.
- **#87 (PR 4):**
  - a handler that throws after a root write, after an in-place container write, after a nested node write, and after a whole-state replacement ends the land, with stage `.input` and its sequence;
  - the tick handler doesn't run, and the later inputs of the batch aren't applied;
  - a handler that throws before any access is rejected alone, and the batch and tick continue;
  - a manual conformance keeps today's behavior in release builds.
- **Record (D9):** a failed run's record ends with the failure and its position. Replay stops there, without applying the rest, and reports "ended by a live failure".

**Mutants.** Each is run once and caught by a named test:
- a dropped patch still sent (rows 1, 3, 10);
- the batch continuing after a `.handlerWrite`;
- the tick handler run after it;
- the adapter sending between the failure and the keeper's turn;
- each resume check removed, caught by its hold test;
- `failLand` called from a task instead of in the turn (the cause test with the racing stop catches it);
- the legacy failure applied without its ticket check;
- the detach not epoch-conditioned (the old-epoch test);
- 4014 sent for a failed land;
- the teardown waiting for an empty land (the hostless test);
- a waiter left unsettled (each waiter's test);
- the row 8 leak restored;
- the validation skipped in `ensureInitialized`;
- a cached failure not cached;
- the row 15 count not including join-sync attempts;
- `cancelAllActionJobs` left out of `failLand` (the held-resolver test);
- the failure check in `leave` moved after the resolvers (the held-OnLeave test);
- the close code latched before the router's awaits (the `stopSnapshot` test);
- the terminal entry written before the turn's record (the record-order test);
- the settle moved after the publication or after the turn record's await (the A/B/C in-turn and legacy-hold tests);
- `appliedItems` or `inputTurnResults` written for the whole batch (the in-turn A/B/C test);
- the finalize step made conditional on the turn's submission (the sync-only and `landFailure`-item tests);
- the thread-local install without restore (the nested-call and reused-thread tests);
- D11's reset on a skipped plan, or its bound on count alone or time alone (the manual-clock tests);
- the validation run inside the cache's lock (a test whose `init()` re-enters validation for another type).

## 9. Decisions for the maintainer

Each has options and a recommendation.

- **D1, the close code.**
  - (a) A new code, 4016 `landFailed`.
  - (b) Reuse 4014 `landStopped`.
  - **Recommend (a).** An operator and a client can tell a failure from an admin stop, and 4014's docs say "stopped". Under D2a (b), 4015 `viewFailed` is added too (Appendix A).
- **D2, split three ways (Review M1).**
  - **D2a, a per-session path at all.**
    - (a) None: every sync failure ends the land (§1).
    - (b) Keep the per-session row for P1 and P2, as Appendix A specifies.
    - **Recommend (a).** No failure in the shipped code is shown to depend on the recipient in a way a rejoin repairs (§1). (b) adds staging, precedence, a bound and a policy, for a path that today only a test hook reaches.
  - **D2b, the rejoin bound (only under D2a (b)).**
    - (a) Per `(land instance, player)`, no reset.
    - (b) Per `(player, root field)`.
    - (c) Reset after a quiet period.
    - **Recommend (a).** (c) resets on healthy success, which the scope decision rules out.
  - **D2c, the `allRecipients` escalation policy (only under D2a (b)).** This is a conservative policy, not detection. Two players with independent bad values both fail, and a runtime type error hits each new player once.
    - (a) End the land when every unique player who received a frame in the plan failed, with at least two. Joiners in the plan count.
    - (b) No policy: only the bound escalates.
    - **Recommend (a) under D2a (b).** It ends a type-caused failure one rejoin round sooner. Its false positive, every player at once with independent bad values, also ends the land under the bound one round later.
- **D3, 4012's retry.**
  - (a) Merge it: a resync or first view that fails ends the land (or, under D2a (b), Appendix A applies). 4012 is reserved and no longer sent.
  - (b) Keep the three-plan retry and 4012 for resync views.
  - **Recommend (a).** A resyncing client is already behind, and the retry recomputes the same view from the same state (§1 P1).
- **D4, OnLeave on a failed land, and the destroy handlers.** Today, on a host's stop, the router's close forwards each session's leave before the destroy, and `leave` runs the OnLeave resolvers before it checks the drain (LK 2398-2439). So on a failed land, OnLeave resolvers (with their external effects) would still run, and the failure close would wait for them.
  - (a) No OnLeave: `leave` checks the failure before the resolvers, skips the resolvers and the handler, and still ends the player's membership in the keeper, the adapter and the router. The destroy handlers and the save run with `.failed` visible, so a land can skip saving.
  - (b) OnLeave runs as on any stop (#512), resolvers included, except after `.handlerWrite`. The destroy handlers run with `.failed`.
  - (c) Skip every handler, the destroy handlers included.
  - **Recommend (a).** A failed land applies no more inputs, and OnLeave is an input; its resolvers' external effects (a write to another service) would act on a state the land has given up on. The land knows what its save means, so the cause is passed to it, not decided for it.
- **D5, the #87 write detector.**
  - (a) Mutable access: `@Sync`'s setter and `_modify` bump a thread-local count at entry, installed only around a handler; nothing is stored in the state. Whole-state replacement, a held copy assigned back and manual conformances aren't seen, and keep today's behavior in release builds (§3.7). Cost: one thread-local read per write, an increment inside handlers; the A/B measures it.
  - (b) Actual change: the debug build's snapshot compare also in release builds. That costs a copy-on-write retain per input and a container copy on each input's first write, which #87's decision rejected.
  - (c) No PR 4 until #87's (A) undo log, which restores instead of ending.
  - **Recommend (a).** It reuses the point `_modify` already marks dirty, and its rule ("validate before inout access") is #87's (B) rule. (c) leaves the partial-write row open until flat storage step 3.
- **D6, `pathNotInSchema`.**
  - (a) End the land: the schema is shared.
  - (b) Keep dropping and counting.
  - **Recommend (a).** (b) is an absorb path.
- **D7, `InTurnSyncResult.committedWithRepairPending`.**
  - (a) Deprecate it, and never return it after PR 2.
  - (b) Remove it.
  - **Recommend (a).** The exhaustive-switch break comes anyway with `.landFailed`. Deprecating keeps a custom transport that *returns* the case compiling, and removing a case is a removal, which goes to the maintainer.
- **D8, unknowable-type fields and colliding keys.**
  - (a) Existential fields stay allowed and end the land at the first throw. Colliding keys are detected in the live conversion and end the land (§4).
  - (b) Existential fields are refused at registration; colliding keys as (a).
  - (c) As (a), and colliding keys are left open (they keep overwriting silently), named as a known gap.
  - **Recommend (a).** (b) breaks lands that use existentials today, and (c) leaves a type error the maintainer listed with no effect.
- **D9, the record of a failed land.**
  - (a) The record ends with the failure's terminal position (§3.1): tick or pass, the input sequence and the stage. Replay applies exactly what live applied:
    - for `.input`, the inputs before the sequence, then the failing input, which must throw again (a mismatch otherwise), then nothing: no later input and no tick handler;
    - for `.syncPhase` and `.eventFlush`, the whole turn;
    - for a failure from the legacy path, every turn up to the end position (§3.3), since they ran live;
    - a tickless land counts by pass, and a sync-only turn by its tick, with no inputs.

    The entry is written after the last live turn's record, through the ordered pipeline (§3.2 step 5).

    The run reports "ended by a live failure", not a mismatch.
  - (b) Nothing is recorded, and the record just ends.
  - **Recommend (a).** Without it, a replay can't tell a failed run from a truncated one, and for `.input` it would run work the live land skipped.

- **D10, where the close code is decided** (with a host).
  - (a) Per session, as of the router's close request: the router evaluates a closure when it issues each close, reading the keeper's cause. A failure during the router's awaits gives 4016 to every session whose close is requested after it; a failure during the final hop to the transport doesn't.
  - (b) Latched once when the stop starts: a stop that began as an admin stop closes every session with 4014, and a failure arriving later changes only the destroy cause.
  - **Recommend (a).** The code then says what ended each session as of its close. (b) is simpler, but a client closed after the failure would be told "stopped" for a land that failed.
- **D11, row 15's bound on a sync plan that keeps throwing.** Today, with periodic sync, a throwing plan retries on every tick, forever; without it, three follow-ups and then doubling join-sync retries.
  - (a) Three consecutive failed plans (join-sync attempts included): about 150 ms at 20 Hz.
  - (b) A time bound: failed plans for at least 1 s and at least three plans.
  - (c) Keep retrying (no bound).
  - **Recommend (b).** A plan that threw sent nothing and committed nothing, so a retry can still restore a fully correct state; (a) ends a land after a few ticks of a transient fault, and (c) leaves clients frozen indefinitely, which the rule rules out. One second is short against a tens-of-minutes session.
  - **The definition under (b), testable:**
    - **Clock:** a monotonic clock (`ContinuousClock`), injected through a package `SyncFailureClock` so a test drives it by hand.
    - **The interval** starts at the first failed plan after a committed plan (or after the land started). Each failed plan counts one; join-sync attempts are plans and count.
    - **Reset:** a committed plan (`.committed`) resets the count and the start. A plan that was skipped (no members, frozen) or deferred by back-pressure neither counts nor resets: no plan ran.
    - **The bound:** the land ends at the first failed plan with count ≥ 3 **and** elapsed ≥ 1 s since the start.
    - **Retries:** with the doubling join-sync retry gone, a land without periodic sync schedules one repair sync-only turn after each failed plan, at a fixed `inTurnRepairDelay`, until the bound ends the land; so three quick failures inside 1 s still get further attempts until the second passes. A land with periodic sync retries on its next tick, as today. A tickless land is a land without periodic sync, through its repair turns; the legacy path's follow-up (`noteFailedPlanForFollowUp`) schedules the same fixed-delay follow-up.
    - **Recorded, not recomputed:** the end is the terminal entry (D9) with stage `.syncPhase`. Replay doesn't run sync phases, so it never recomputes the bound.
  - **Tests:** a manual clock with three failures inside 1 s (no end; a fourth after 1 s ends it), a manual clock past 1 s with two failures (no end; the third ends it), a commit in between that resets both, a skipped and a deferred plan that change nothing, and a tickless land's repair-turn progression to the end.

## 10. Out of scope

- Row 18's digest scope: diagnostics only.
- The replay loading skips: #521's A5.
- The `1011` close for a join that didn't complete in a turn: an invariant, unchanged.
- #531: a second session of one player.
- #87's (A) undo log: flat storage step 3.

## Appendix A. The per-session path (only under D2a (b))

### A.1 What is per-recipient

- P1 and P2 of §1, and only after the structured type causes of §1, which end the land first.
- The new close code is `SessionClose.Code.viewFailed = 4015`: the land is fine, and a rejoin gets a full view.

### A.2 Precedence and the whole-frame fallback (Review M2)

For a frame that fails, the plan collects **every** failure, not the first. It tries each patch alone, then the patches that encoded, then an empty frame, as the helper does today (TA 5670-5688). Then:

1. Any structured type cause → land.
2. Any failing patch whose root field is broadcast → land. The broadcast scope wins over every P1 failure in the same frame.
3. The patches each encode alone, but not together, or the empty frame fails:
   - for the merged broadcast frame, a broadcast-only update, or every unique player of the plan → land (an encoder-wide defect);
   - for some recipients only → P2 for those recipients.

   A custom encoder's error is treated the same way, because nothing about its internals is assumed.
4. Otherwise, the failing patches are per-player roots → P1 for that player.

### A.3 Staging and commit (Review M3)

- The plan stages per-player decisions in a set deduplicated by player, and closes nothing while planning.
- After the last recipient, still in the plan, it decides land escalation:
  - the bound (D2b);
  - the policy (D2c).
- If the land escalates, the plan returns `.landFailed`, and no 4015 is sent.
- Otherwise, the commit:
  - leaves each staged player out: its per-player snapshot, first-sync mark, resync, and #536's `SyncTablePerPlayerStaged` entry are discarded;
  - commits the rest;
  - only then closes each staged player's sessions **that were recipients of this plan** with 4015;
  - inserts the player into the bound set.
- A plan that throws after staging closes nothing, so "a thrown plan committed nothing" still holds.
- A join or reconnect for that player in flight isn't a recipient of this plan, so it isn't closed. If its first view fails, the bound ends the land.

### A.4 The bound and the policy

- `viewFailedPlayers: Set<PlayerID>` is kept per land instance, with no reset (D2b (a)).
- `allRecipients` counts unique players who received a frame in the plan, joiners included (D2c (a)).
- Two kinds are added: `LandFailure.Kind.viewRepeat` and `.allRecipients`.
- Tests and mutants follow rev 1 §8's session cases, plus:
  - the precedence (a P1 failure listed before a broadcast failure → land);
  - the staging (a plan that escalates or throws sends no 4015);
  - the denominator (two sessions of one player are one recipient).
