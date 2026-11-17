# A sync failure ends the unit it corrupted (#535)

**Status:** rev 11, decided. GO on rev 10 (a0f4de83), with its two shoulds folded in (§8: the join tests' hold, D8's integration backstop). GO on rev 7 (c2a146fc, 2026-11-13); rev 8 (3a55d139) folded in its two shoulds. The maintainer decided D1–D11 and the drain exception on 2026-11-13 (§9); rev 9 updates the plan to match. Two decisions change the mechanism and went to review as a delta: D11 (d), a sync plan's first throw ends the land, and D8 (b), existential fields are refused at registration. Plan only; no code yet.
- Rev 9 (05223505) got a no-GO on the decisions' delta: 1 must-fix, 5 should. Rev 10 answers them:
  - Must-fix: PR 1 removes only the plan-throw paths; the follow-up limit, `noteFailedPlanForFollowUp` and `startDelayedFollowUpSync`, which the row repair and the first-view retry share, go in PR 2 (§7).
  - Shoulds: `InTurnSyncResult.failed(repairAllowed:)` loses its payload in PR 2 (§6, D12); the legacy `landFailure` item on a draining keeper (§3.3); the alias-typed fixtures as the D8 gap's tests; D8's commitment worded as "where the syntax shows it", with `AnyHashable` and `AnyCodable` as rules by name; the tests that rely on a plan throw (§8); debug settle's plan throw; row 15's docs status.
- Rev 9: the decisions. The per-session path (Appendix A, 4015 `viewFailed`, the rejoin bound, `allRecipients`) is dropped (D2a (a)); D11's time bound, its clock, the fixed-delay repair retries and the doubling join-sync retry are dropped (D11 (d)); `committedWithRepairPending` is removed, not deprecated (D7 (b)); existential fields are refused (D8 (b), §4); the drain is a named interim exception to the reentrancy rule, removed by #522 (§3.4).
- Rev 6 (400b9608) got a no-GO: 2 must-fix and 4 should. Rev 7 answers them:
  - S1: §3.2 step 5. On a failure, the legacy paths' turn record goes through the ordered recorder pipeline with the terminal entry after it, both enqueued in the failing segment; nothing is written directly after an await, so a teardown save can't come first.
  - S2: §3.4. "Sessions closed" is a set-once latch per epoch, created in the segment that detaches, that a late joiner can await; a hook whose epoch-conditioned detach finds no instance and no latch returns at once.
  - Shoulds: the legacy A/B/C construction is replaced by what can be built (§8); §3.8 lists `resumeInputTurnWaiters`' bookkeeping as an existing exception and drops action responses; the output gate's contract is "no new enqueue", with action responses and errors exempt; a custom transport's `closeOutputs` is its own responsibility.
- Rev 5 (a74f6145) got a no-GO: 3 must-fix and 4 should, all one class: keeper state read or changed across an await. Rev 6 answers them, and checks every step of §3 against the reentrancy rule, with the awaits the failure path crosses listed in §3.8:
  - Q1: §3.2 step 4 and §3.3. A synchronous output gate: the mark closes it in the failing segment (a set-once, lock-protected flag on the transport, `closeOutputs(for:)`), every adapter send point checks it, the failing turn skips `runTurnOutputs`, and the sync-only, repair and writer-drain entries check the failure.
  - Q2: §3.2 step 5. The terminal entry is enqueued in the same synchronous segment as the turn's record, before any await; the enqueue point is listed per turn kind.
  - Q3: §3.2 step 6 and §3.4. The teardown's synchronous part (clearing `players`, installing `drainTask`) runs in the failing segment, as `shutdownIfIdle` does before its first await; the task does only external work, then the existing drain, whose post-await steps are named.
  - Shoulds: the terminal entry versus an admin stop (§8); the legacy A/B/C construction; replay doesn't run the live settle (§3.2); whole-state replacement tested as a pinned gap; `inputTurnResults` asserted to hold no suffix entry.
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
- **It shrank to nothing (D2a (a), decided 2026-11-13).** The table's first row has no case in the code (§1): every sync failure ends the land, and no 4015 code exists.

**Related:**
- #532: total per-player frame failure.
- #87: partial writes, folded in here.
- #531: a second session of one player.
- #102, #511, #512: the land stop and its OnLeave.
- #387: server-originated turn inputs.
- #536: per-player sync tables.
- #521: typed events and actions. Its plan uses this plan's stop for EV4 and EV7 (§3.6) and owns the replay loading skips (its A5).

## 0. Summary

- **Every sync failure ends the land (§1, D2a (a)).** That covers a conversion, a diff, a frame encode, an event encode, a sync plan's first throw (D11 (d)), and a handler write before a throw. The land closes with a new code, 4016 `landFailed` (D1). Types knowable at registration are refused there, existential fields included (§4, D8 (b)).
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

**Conclusion.** No failure in the shipped code is shown to depend on the recipient in a way a rejoin repairs. **Decided, D2a (a): no per-session path.** Every sync conversion or encode failure ends the land. The 4015 code, the rejoin bound, the `allRecipients` policy, the scope precedence and the staged closes are not built (rev 8's Appendix A, at 3a55d139, has their design). If a per-recipient source appears later (a custom encoder with per-session state, or per-player tables that encode per recipient), it needs its own plan.

**What stays recoverable.** These paths restore fully correct state and are kept:
- the fallbacks that produce the same output by another route (rows 2, 5, 7);
- diagnostics (rows 6's oracle path, 18).

## 2. The sweep, row by row

Verdicts:
- **land**: ends the land;
- **stays**: the path restores fully correct state, and is kept.

| # | Site at 9755a625 | Today | Verdict | PR |
|---|---|---|---|---|
| 1 | SE 1405-1431 `extractDroppingThrowingFields` | a field whose conversion throws is dropped, and its cached value is kept | land | 2 |
| 2 | SE 1484-1500 `extractWithSnapshotForSync` | `try? snapshotForSync`, falling back to per-field extraction | stays: a route, and its drops are row 1. The fallback must surface the per-field error to row 1, not swallow it | none |
| 3 | SE 1508-1534 `lateJoinSnapshot` (dropping); TA 4640-4660 | a full view without the fields that don't convert, filled from caches | land. The cache fill goes | 2 |
| 4 | ST 1639-1662 `diff`, ST 1521-1535 `stageSeed` | a broadcast slot whose diff or seed throws is dropped | land | 2 |
| 5 | ST 559-590 `SyncEquatableDiffer.diff` | a `.standard` leaf whose convert throws falls back to the snapshot diff, with a release log | stays: the same output as the snapshot diff, whose own throw is row 4 | none |
| 6 | ST 1142-1144, 1194-1196 `lastSentSnapshot` | a last-sent value that no longer converts reads nil | view path (TA 4655): land; the view would miss a field. Oracle path (ST 1555): stays, as diagnostics | 2 |
| 7 | ST 1612-1620 `viewPatches` | `try?`: a field whose rows don't convert keeps today's patches | stays: today's patches carry the same field, and their own conversion is rows 1 and 3 | none |
| 8 | TA 4453-4463, 4603-4612 (row drop and remake) | rows whose patches don't encode are dropped from the tables, and the plan is remade with key scopes reset | land. The leak (below) goes, and so do the remake, `planFailedRows`, `rowRetryFields` and the repair result | 2 |
| 9 | TA 4745-4813 `planMergedBroadcastFrame` | re-encode dropping; a total failure unstages the broadcast tables and sends the events as 103 frames | land (drop or total) | 1 |
| 10 | TA 4897-4958 `planPerPlayerFrames` | re-encode dropping; on nil the player's staged cache is dropped and nothing is sent (#532) | land (dropped patch or total) | 1 (total), 2 (patches) |
| 11 | TA 4929-4938, 3574-3586, 3633-3635, 3686-3721 (resync and first-view retry, 4012) | not sent, retried, closed with 4012 after `snapshotEncodeFailureLimit` (3) | land (D3 (a)). The retry and `snapshotEncodeFailureLimit` go; 4012 stays reserved and is no longer sent | 2 |
| 12 | TA 5473-5535 broadcast-only frames | re-encode dropping per player; on nil, skip | land | 1 |
| 13 | TA 5764-5830 `planFirstSync` | re-encode dropping; even empty fails → `unencodableFirstViews` | land. With row addressing on, the standalone first sync is refused anyway (TA 5767-5771) | 2 |
| 14 | TA 5652-5689 `encodeDroppingUnencodablePatches` | each patch tried alone; `pathNotInSchema` counted, others dropped (or the row) | removed. An encode that throws is a failure; nothing is retried to drop patches. The error goes into the log and `LandFailure.detail`. A diagnostic pass may find the first failing patch for the log only. `pathNotInSchema` ends the land too (D6 (a)): it arises only from a server-side bug (a stale schema, a framework bug, a manual conformance), never from a client | 1 (callers in 1), 2 (the rest) |
| 15 | TA 3287-3331, 3200-3205; in-turn TA 2896-2917 → LK 4423-4436 | a plan that throws commits nothing; ordinary follow-ups are bounded at `syncFailedPlanFollowUpLimit` (3) without periodic sync; past the limit, join-sync turns keep being scheduled with a doubling delay (LK 4427-4434); with periodic sync every tick retries | land at the first throw (D11 (d)), a join-sync plan included: a server-side computation failure, with no transient cause in the code. The follow-up limit, the failed-plan follow-ups and the doubling join-sync retry go. With periodic sync this is a behavior change: today it retries forever | 1 |
| 16 | TA 5706-5761 `_syncStateForNewPlayer` | logged, then a follow-up. With row addressing in effect: closed with 1011 | a conversion or encode failure in the joiner's view: as row 13. A plan throw: row 15. 1011 is unchanged (an invariant, not a sync failure) | 2 |
| 17 | TA 3127-3138 `appendEventFrames` (`try? pack`); TA 2792-2806 (merged body at enqueue) | a frame that fails `pack` is skipped. At enqueue, a nil merged body falls back to a standalone frame (`.sentAlone`) or is `.lost` | land on `pack` failure and on `.lost`. **A nil merged body that is sent alone isn't a loss** and doesn't end the land (#521 D10 removes that attempt). The same rule as #521 EV4 | 1 |
| 18 | TA 3989-3993 `canonicalEvent` | a payload that doesn't convert makes the digest's events scope unverifiable | stays: diagnostics, not client state. The canonical snapshot conversion and the wire encode are different operations, so neither implies the other | none |
| 19 | TA 202-209 `leavesKeyTablesAhead`, set at 4780, 4950, 5482, 5524 | the key scopes are reset in the next plan | removed in PR 1. Its four setters are rows 9, 10 (total) and 12, which PR 1 converts | 1 |

Row 19, as built in PR 1: one setter stays with the full-view retry (`planPerPlayerFrames`, a retried first view or resync snapshot that doesn't encode even empty); removed in PR 2 with rows 11 and 13. `unencodableJoinerIsSkippedAndRetried` pins it until then.

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
        case syncPlan         // a sync plan threw (row 15, D11 (d))
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
- **Steps 5 and 6 also run in the failing segment** (rev 6): the terminal entry is enqueued to the recorder, and the teardown's synchronous part runs, before the turn's first await. Nothing in §3.2 runs after an await.
- **Replay doesn't run any of this.** Replay applies inputs with `removingFromQueue: false` (LK 3944-3981) and never calls `failLand`: it stops at the terminal position and reports (D9). The live settle and teardown don't exist in a replay run.

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
4. **Stops the batch, the tick and every output** (§3.7, Review Q1).
   - The input loop (`applyPendingItems`, LK 3849-3874) breaks after the failing item. `runTick` checks the failure before `handler(&state, ctx)` (LK 4472) and doesn't run it. Later ticks don't start: the tick loop checks `isDraining`.
   - **The output gate closes in the mark.** The keeper calls `transport.closeOutputs(for: failure)`, a new synchronous, `nonisolated` `LandKeeperTransport` requirement (default: nothing). `TransportAdapter` implements it with a set-once, lock-protected `OutputGate` (the `DrainFlag` pattern, LK 5313-5331), readable from any isolation without an await. Every adapter send point checks the gate in the segment that enqueues the frame (§3.3), so a legacy cycle that holds a valid output ticket still sends nothing once the gate is closed. The adapter doesn't wait for the teardown's `landDidFail` to learn of the failure.
   - **The failing turn's own outputs don't run.** `runInputTurn` and `runTick` check the failure after applying and skip `runTurnOutputs` (LK 4995-4999): neither the sync phase on the partially written state nor the turn's events (the prefix's included) are sent.
   - **The scheduled sync-only entries check it.** `runSyncOnlyTurn` (LK 4722), `runSyncOnlyTurnIfInTurn` (LK 4740), the writer-drain retry (LK 4747-4758) and the repair turn (LK 4792-4804) return at once when the land has failed, before calling the transport.
5. **Finalizes the record** (D9), unconditionally, **in the failing segment** (Review P2, Q2). The terminal entry can't ride on the failing turn's own submission, because some failing turns submit nothing:
   - a sync-only turn (`runSyncOnlyTurn`) never calls `submitTurnRecord`, and its `enqueueTicklessTurnEnd(since:)` returns early when nothing was submitted (LK 4680-4683);
   - the turn that applies a `landFailure` item: the item isn't an input, and `runInputDrain` skips submission when `outcome.record.isEmpty` (LK 4952-4957);
   - legacy tick-land recording calls `recorder.record` directly and conditionally (LK 3690-3706, and the tick's last write at LK 4298-4324).

   `enqueueRecorderSubmission` is synchronous and bumps `recorderSubmissionCount` (LK 4671-4673), so it must not run after an await. The terminal entry is enqueued with `enqueueRecorderSubmission` in the same synchronous segment as the turn's own record enqueue, right after it, before any await; the turn carries the submission handles out and awaits them afterwards, as `submitTurnRecord` does (LK 4713-4717: enqueue, then the hold and the await). Per turn kind:
   - **in-turn input drain:** today `runInputDrain` calls `submitTurnRecord` after `runInputTurn` returns. On a failure, `runInputTurn` itself enqueues the turn's record and then the terminal entry at its end, and returns the handles; `runInputDrain` awaits them. (A turn without a failure keeps today's path.)
   - **tick turn (in-turn):** the tick's record is enqueued in `runTick`'s segment; the terminal entry follows it there.
   - **sync-only turn:** the terminal entry is enqueued in `runSyncOnlyTurn`'s segment, and is then the turn's only submission; `enqueueTicklessTurnEnd(since:)` follows it, since the count moved.
   - **the `landFailure` item's turn:** the entry is that turn's only submission, enqueued where the item is applied.
   - **the tickless legacy pass** already records through the pipeline (`finishTicklessLegacyPass`, LK 3737-3768, `enqueueRecorderSubmission`): on a failure, its record and then the terminal entry are enqueued in the apply segment, before the pass's awaits.
   - **the legacy tick path** today writes its input record with `await recorder.record(...)` directly, after `holds.at(.turnRecord)` (LK 3683-3706), outside the pipeline; a teardown save, whose submission tracker waits only for the pipeline's tail (ReevaluationRecorderService 26-37, 45-58), could get in first. **On a failure, that write moves into the pipeline:** the apply segment already holds the recorded inputs (`applied`), so it enqueues one submission that writes them (`recorder.record(...)`, as today, with the tick ID captured in that segment as today's `nextTickId - 1`, and under today's condition that something was recorded) and then the terminal entry, and the direct write after `.turnRecord` is skipped. No sync phase ran and the tick handler didn't run, so the tick's later block (LK 4298-4324) isn't written. That block holds more than the state hash and snapshot (4299-4308): its `recorder.record(...)` writes the tick's watermarks `sequenceBeforeInputs` (W1) and `sequenceBeforeTickHandler` (W2) (4316-4324). On a failure:
     - **W1 is recorded:** the captured `sequenceBeforeInputs` goes into the failing tick's input record, enqueued in the same submission;
     - **W2 is "not recorded":** the tick handler never ran, so there is no W2. The terminal entry (stage `.input`) says so, and replay (D9) reads a failed tick's missing W2 as "stopped before the tick handler", not as a malformed record. No state hash is recorded for that tick, and replay compares none. A path without a failure keeps today's direct write.
   - **without a recorder:** nothing is enqueued, and the stored entry is cleared in the segment.

   The teardown's record entries (the destroy's save) are submitted later, by the drain, so the terminal entry precedes them. The entry isn't an input.
6. **Starts the teardown, synchronously, in the failing segment** (§3.4, Review Q3): it clears `players`, and installs `drainTask`, as `shutdownIfIdle` does before its first await (LK 5169-5176). Only external work and the existing drain run in that task.

**Callers:**
- **In-turn sync.** `applyInTurnSyncResult` is called on a new `InTurnSyncResult.landFailed(LandFailure)`, which the adapter returns from the synchronous sync phase, on a conversion or encode failure and on a plan that throws (row 15, `.syncPlan`, stage `.syncPhase`). The sync phase committed nothing and sent no state frame. Events enqueued before it in that turn are already in the writer; they are correct events, sent before the land ended.
- **Input application**, on `.handlerWrite` (§3.7).
- **The turn that applies a `landFailure` item** from the legacy path (§3.3), including a legacy plan that throws (TA 3287-3331), which today schedules a follow-up (`noteFailedPlanForFollowUp`).

### 3.3 The adapter

**It stops at once, through the output gate (§3.2 step 4).** A failure the adapter sees itself closes the same gate.

**The gate's contract: no new enqueue.** The gate is checked where a frame is enqueued to the outbound writer. Frames already in the writer when it closes still go out (`OutboundWriter` 173-182 has no gate), as do events enqueued earlier in the failing turn; no dequeue policy is added. **Action responses and errors are exempt:** the shared `writeElement` path checks the gate only for state and event frames, and a response or error goes out best effort until the session's membership ends (below). A custom transport's `closeOutputs(for:)` is its own responsibility: the protocol's doc says that its empty default blocks nothing, and that a transport that sends on its own schedule must stop new state and event output when it is called.
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
- The turn that applies it re-reads the drain flag and validates the ticket, then calls `failLand`. When the flag is already set:
  - **already failed, with the same ticket:** the item is ignored (idempotent); the first failure, its terminal entry and its teardown stand.
  - **an admin or idle drain already started:** the first cause stays (`DrainFlag.set`). The item is dropped and logged; the sessions close with 4014, the window D10 accepts, and no terminal entry is written: the drain's own save ends the record, and replay sees a stopped land, not a failed one.
  - **no normal turn runs once draining**, so a dropped item needs no turn: `submitLandFailure` refuses it at intake when `isDraining` is already set, as `submitServerInput` does (LK 2980), and the settle drops one queued earlier.
- A tickless idle land schedules that turn as `submitServerInput` does.

### 3.4 The teardown (keeper-owned)

**The synchronous part runs in the failing segment** (§3.2 step 6, Review Q3):
- `players.removeAll()` without OnLeave (D4 (a));
- `drainTask = Task { ... }` installed, the same field `shutdownIfIdle` installs (LK 5175-5176), so any later `forceShutdown` or `shutdownIfIdle` joins it (`if let drainTask { await drainTask.value; return }`, LK 5164-5167) instead of starting a second destruction. The cause is already `.failed` (step 2).

**The task** holds no keeper state across its awaits, and runs:

1. **`await transport.landDidFail(failure)`**, a new `LandKeeperTransport` requirement whose default does nothing. A custom transport therefore compiles, and the keeper still tears the land down. **It returns once the sessions are closed, never after the destroy**: the host's stop awaits `forceShutdown`, which joins this `drainTask`, so waiting for the stop's end here would deadlock. `TransportAdapter` implements it:
   - **With a host hook** (`onLandFailure`, which `LandManager` installs at creation with the instance's epoch): it starts the server's stop in the stop's own task (its `SingleFlight`), with the epoch, and awaits that epoch's **sessions-closed latch**. The stop's own task then calls `forceShutdown`, which joins `drainTask`; by then `landDidFail` has returned, so there is no cycle.
     - **The latch is lasting state, not an event (Review S2).** It is a set-once completion keyed by epoch, held in the server's stop flights (`LandStopFlights`) beside the flight. It is created in the same synchronous segment as the detach that starts a stop for that epoch, whichever stop does it (an admin `DELETE` or a failure), and set after that stop's `closeSessions` returns. A late joiner awaits it and returns at once if it is already set.
     - **An admin stop already past `closeSessions`** set the latch earlier: the failure's hook finds the epoch's latch set and returns at once.
     - **An epoch-conditioned detach that finds no instance** (the epoch was detached by an earlier stop, or the land is gone): the hook looks up that epoch's latch in the same segment. If a latch exists, it awaits it (the earlier stop will set it); if none exists, no stop of this epoch will ever raise one, and the hook returns at once.
     - The cycle `drainTask` → `landDidFail` → latch → stop → `forceShutdown` → `drainTask` can't close: the latch is set before the stop calls `forceShutdown`, and a stop that never ran leaves no latch to wait for.
     - **Removal.** `LandStopFlights.finish(_:id:)` (NIOLandServer 326-340) removes a flight by `LandID`; the latch is keyed by epoch and is removed **by epoch**, by the stop that created it, after its `forceShutdown` and `endClosing`. A waiter that already holds the latch keeps its reference and isn't affected. Removing an old epoch's latch never touches a newer instance's latch for the same `LandID`.
     - `LandManager.detachForStop(landID:epoch:)` detaches only if the stored instance has that epoch, in one synchronous segment (Review M7). The epoch check and the detach can't be split by an await. Epochs are the manager's (LM 125-126).
     - The stop then closes the bound sessions. **Where the code is decided is D10.** Today the server picks the `SessionClose` value before `await landRouter.closeSessions` (NIOLandServer 181), and the router then awaits its snapshot (LandRouter 469), each adapter lookup (474) and the leave forwarding (482-486) before it closes anything. Under D10 (a), decided, `closeSessions` takes a closure the router evaluates when it **issues** each session's close request, after that session's leave and `afterLeave` (LandRouter 425-440, 479-487); it reads `keeper.destructionCause` (nonisolated) and gives 4016 for `.failed`, 4014 otherwise. The code is "the cause as of the router's close request". The request then hops to the `WebSocketTransport` actor to close, so a failure in that last hop still leaves 4014; the plan accepts that window rather than threading the closure into the transport.
     - The destroy sees `.failed` whenever the failing turn set the drain cause first (step 2). `SingleFlight` keeps the stop's work to one run.
     - **OnLeave on the router's leave (D4).** The router's close forwards each session's leave to the keeper (`adapter.onDisconnect` → `keeper.leave`, LandRouter 425-440, 462-487). `leave` removes the player, then runs the OnLeave resolvers (LK ~2398-2420), and checks `isDraining` only after them (LK 2439). On a failed land, under D4 (a), `leave` checks `failure` **before** the resolvers: the player was already removed in the failing segment, so it finds none, and it skips the resolvers and the handler. The membership in the adapter and the router ends as today, in the adapter's `onDisconnect` before the keeper is called (TA 1577-1609) and in the router's bindings (LandRouter 463-467). Everything the OnLeave input would have done is skipped with them: its sequence allocation, its lifecycle record, the handler, and the broadcast-only removal sync it requests (LK 3639-3643). The keeper's membership removal doesn't remove the player's entry in the application's state (for example `state.players[id]`): that is OnLeave's job, and the destroy handlers see it. The other drain causes keep today's order.
   - **Without a hook** (an adapter built directly): the adapter closes every session it holds with 4016 through `endAndCloseSession`.
2. **The existing drain**, `drainAfterIdleCheck()` (LK 5180 on), unchanged: it cancels the tick, sync and destroy tasks, waits for a tick in flight, drops pending inputs (none are left after the settle), runs the destroy handlers and the save with `.failed`, and calls `transport.onLandDestroyed()`.
   - **Its post-await steps are the existing drain's**, shared with every destruction cause: the task cancellations after `holds.at(.drainStart)`, `dropPendingInputs` after `waitForTickInFlight`, `destroyHandlersStarted`, the destroy handlers' own writes, and the final bookkeeping. They are safe for the reason they are safe today: intake has been closed since `isDraining` was set, no tick starts, and nothing else mutates the keeper's turn state. They are an exception to the reentrancy rule that predates this plan, and this plan adds no new post-await keeper mutation. **Decided (2026-11-13): the drain is a named interim exception, removed by #522.** #522's list now holds it (a ticket at stop start, completion as a #387 turn input, the bookkeeping in that turn). The change that edits the reentrancy rule's text (its own direct change, or PR 1) lists it as "the land-stop drain's post-await bookkeeping (#522)".
   - The host's `forceShutdown`, reached from the stop's task, sees `isDraining` (LK 2515-2518), clears `players` (already empty) and joins `drainTask`. Its `.forceShutdown` cause is ignored, because the first cause stays.

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

**The detector (D5 (a), decided).** The contract is **mutable access**, not actual change.
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

  For these, debug builds keep the existing snapshot compare and warn; release builds keep today's behavior (the input fails alone). A test covers a caught case (an in-place write through a copy of a nested node, written back through `_modify`) and pins each uncaught case as a named gap.

### 3.8 The awaits on the failure path (the reentrancy check)

Every step of §3 was checked against the rule "keeper state is mutated only inside synchronous turns". The failure path crosses these awaits; for each, what is captured before it and what may happen after it:

| Await | Where | Captured before it | After it |
|---|---|---|---|
| none in §3.2 | the mark, the settle, the record enqueue, the teardown's synchronous part | — | — (all in the failing segment) |
| `await submission?.value` / `holds.at(.turnRecord)` | `runInputDrain` after `runInputTurn` (LK 4713-4717 pattern) | the record and terminal handles (both enqueued) | `resumeInputTurnWaiters`' existing bookkeeping (LK 4958-4961, 5015-5022): it removes the prefix's `inputTurnResults`, the job-turn marks and the waiters, and fills slots. That is an existing post-await exception of every input drain, not added here; on a failure it touches only the prefix |
| the legacy pass's awaits (`finishTicklessLegacyPass`, `.turnRecord`; LK 3663-3690) | legacy pass | the suffix was already dropped and the prefix removed in the apply segment; the record and terminal entry are already in the pipeline | the existing legacy publication of `outcomes` (prefix only), the same existing exception |
| `await transport.landDidFail` | the teardown task | `failure` (a value) | none on the keeper; the drain follows |
| the drain's awaits (`.drainStart`, `waitForTickInFlight`, destroy handlers, save, `onLandDestroyed`) | `drainAfterIdleCheck` | — | the drain's existing bookkeeping (§3.4 step 2), a named interim exception until #522 |
| adapter: legacy state read → send (TA 3301-3318), first-sync suspensions (TA 5722-5740), legacy event flush, broadcast-only, debug settle (TA 6671-6682) | adapter, outside turns | the output generation (`GenerationTable` ticket) | a state or event enqueue only through `ifCurrent` **and** an open output gate; `keeper.endSync()` always (TA 3327-3328). Action responses (TA 5941-5993) are exempt from the gate (§3.3) |
| `await keeper.submitLandFailure` | adapter, legacy path | `failure`, both positions, the lifecycle ticket | nothing on the adapter; the keeper applies it in its own turn, re-reading the drain flag and the ticket |
| router: snapshot, adapter lookup, leave and `afterLeave`, the hop to the transport | host stop | the epoch (detach), the close-code closure | the close code read at the close request (D10) |

## 4. Registration refusals

**Knowable from the type**, checked by walking the schema and the type:
- **A class type in a synced field** (`classRefusal`). `SyncValueSemantics.validate` walks declared element and value types of collections, including empty ones (SyncValueSemantics 72-80). Plain structs, tuples and enum payloads, though, are looked into through the default instance's **values** (SyncValueSemantics 18-26). So a class is unseen behind an existential (`Any`, `any P`), inside a struct inside an empty `[Holder]`, or in an enum case the default instance doesn't take.
- **An unsupported key type** (`SyncError.unsupportedKey`, SnapshotValue.swift:476). This check is new.
- **A player-dependent node under a broadcast field** (#179). `SyncPolicyNesting.validate` covers it, with the same value-walk gaps (SyncPolicyNesting 29-32, 114-134).
- **An existential field (D8 (b), decided 2026-11-13).** A synced field whose declared type is, or contains, an existential is refused: its value isn't knowable from the type, and that hides a class, an unsupported key or a player-dependent node from every check above. No `@Sync` field in `Sources/`, `Examples/` or `Tests/` is spelled `any …` or `Any` today (checked 2026-11-13); three test fields reach an existential through a typealias (below). A refusal can be loosened later without breaking anyone, while tightening later would break users.
  - **The commitment: refused where the syntax shows it; the rest is a listed gap.** `@StateNodeBuilder` and `@SnapshotConvertible` read each stored property's declared type as syntax (they already emit `FieldMetadata(type: X.self)` from it). They refuse `Any`, `AnyObject` and any `any P`, also inside a generic argument, an optional, an array, a dictionary or a tuple (`[String: Any]`, `(any P)?`).
  - **Rules by name.** `AnyHashable` and the library's `AnyCodable` (Support/AnyCodable.swift, which holds `base: Any`) are concrete structs, not existentials, but each boxes a value of any type, with the same effect. Both are refused by name, as a stated rule, not as existential detection: at macro expansion when spelled, and `AnyCodable` also at registration through the walked element and value types, which see it by name. No `@Sync` field in the repo uses either (checked 2026-11-13).
  - **What syntax can't see:** a protocol spelled bare (`P` instead of `any P`, still legal for a protocol without associated types), and a typealias that names an existential. Those, and every type without the macros (a hand-written conformance), are a **listed gap**: no public, supported API tells an arbitrary existential metatype apart (`Mirror` describes instances, and the metadata kind isn't public reflection). The runtime backstop applies: the land ends at the first throw. If a supported check appears, `validateForRegistration` adds it.
  - **The gap's tests exist already.** `SyncValueSemanticsTests.swift` declares `typealias ValueCheckAnyPayload = any ValueCheckPayload` (L103), used by three `@Sync` fields (L107, 113, 115), and its tests at L205-249 rely on them. Under the gap they keep compiling; PR 3 keeps them as the gap's backstop tests (the land ends at the first throw) and names them in its body. They call `snapshot`/`fullStateSnapshot` directly, with no keeper or adapter, so they show the conversion throws, not that the land ends; PR 3 adds one integration case with the alias fixture (the failure, every session closed with 4016, the teardown with `.failed`), and that case is the backstop the API docs promise. If a runtime check is ever added, they become refusal tests.
  - **The API docs say it too** (PR 3): the `@Sync`, `@StateNodeBuilder` and `@SnapshotConvertible` docs state the refusal ("where the declared syntax shows `any` or `Any`", plus the two names) and the gap (a bare protocol, a typealias, a hand-written conformance: the land ends at the first throw), in English and in the bilingual `docs/` page.

For every gap, the runtime backstop stays: the land ends at the first throw.

**Not knowable from the type**, so the land ends at the first throw:
- a value the default instance doesn't hold: a struct inside an empty collection, an enum case not taken (as above), and an existential the refusal can't see;
- a user `toSnapshotValue` that throws;
- a non-finite number under JSON.

**Colliding keys** (D8 (b)). Today they throw only in `makeFull`, the replay-hash path. The sync `make` path overwrites silently (SnapshotValue.swift:427), so "close the land at the first throw" would never fire for a type error the maintainer listed. They are detected in the live conversion:
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
| `InTurnSyncResult.failed(repairAllowed:)` (LandKeeperTransport.swift 222) | **becomes `.failed`, with no associated value** (D12), in PR 2, in the same break as `committedWithRepairPending`'s removal. After D11 (d) the payload means nothing: the keeper's handling (LK 4423-4436: the repair turn and the doubling join-sync retry) goes in PR 1. From PR 1 the library's adapter returns `.landFailed` on a plan throw, and a custom transport that returns `.failed` ends the land as `.syncPlan` (stage `.syncPhase`); between PR 1 and PR 2, `repairAllowed` is read by nothing, and its doc says so |
| `InTurnSyncResult.committedWithRepairPending` | **removed** in PR 2 (D7 (b)), with the repair turn that handles it; a custom transport that returns it no longer compiles (named in the PR) |
| `LandKeeperTransport.landDidFail(_:)` | new requirement with a do-nothing default |
| `LandKeeperTransport.closeOutputs(for:)` (synchronous, `nonisolated`) | new requirement with a do-nothing default; its doc names stopping a custom transport's own output as that transport's responsibility |
| `SessionClose.Code.landFailed` (4016); `SessionClose.landFailed` (package, as `.landStopped`) | new constant |
| `SyncError.collidingKeys` | new enum case (D8; the same switch note) |
| `SyncRegistrationError`; `LandDefinition.validateForRegistration(context:)` | new; thrown by entry points that already throw. One case is an existential field (D8 (b)) |
| `@StateNodeBuilder` / `@SnapshotConvertible`: an existential field type | a new compile error (D8 (b)) |
| `@Sync`'s accessors: the thread-local access count (D5) | no public API; package-level, and no stored property on any state |
| `TransportAdapter.unmappedPathPatches` | kept; it counts `pathNotInSchema` failures (D6) |
| TS SDK: `LAND_FAILED_CLOSE_CODE` (4016) in `protocol.ts` | new export; the docs say the instance is gone |

- **No `LandMode` case.** No new keeper access for the transport: the teardown is the keeper's own (§3.4).
- **`package`-only members:** `submitLandFailure`, `detachForStop(landID:epoch:)`, the adapter's `onLandFailure` hook.
- **Behavior changes,** named in each PR body and in `docs/` (bilingual):
  - a land with a sync failure ends with 4016;
  - 4012 is no longer sent;
  - a handler that throws after mutable access ends the land;
  - colliding keys end the land;
  - a sync plan's first throw ends the land; with periodic sync it retried forever before (D11 (d));
  - a field typed with an existential no longer compiles, or is refused at registration (D8 (b)).

## 7. PRs

1. **PR 1, the mechanism and the total failures.**
   - §3.1–3.5, `submitLandFailure`, `landDidFail`, the epoch-conditioned detach, 4016.
   - Rows 9, 10 (total), 12, 15, 17 and 19. Row 15 removes only the plan-throw paths (D11 (d)): the in-turn `.failed` return and the keeper's handling of it, the doubling join-sync retry (reached only from that branch, LK 4426-4434), and the legacy plan throw's follow-up (TA 3287-3331), which becomes `submitLandFailure`. `syncFailedPlanFollowUpLimit`, `noteFailedPlanForFollowUp` and `startDelayedFollowUpSync` stay: the row repair reads the limit (TA 2904, `consecutiveRowRepairs <= syncFailedPlanFollowUpLimit`) and the first-view and skipped-joiner retry uses all three (TA 4240-4258), and both stay until PR 2.
   - The SDK constant and the docs.
   - The reentrancy rule's text gains "the land-stop drain's post-await bookkeeping (#522)", unless a direct change lands it first.
2. **PR 2, the conversion and per-patch paths.**
   - Rows 1, 3, 4, 6, 8 (with the leak), 10 (patches), 11, 13, the rest of 14, and 16.
   - Colliding keys in the live conversion (D8).
   - The repair's removal, `committedWithRepairPending` included (D7 (b)), and `InTurnSyncResult.failed` without its payload (D12), one break; D3's first-view retry; with their last users gone, `syncFailedPlanFollowUpLimit`, `noteFailedPlanForFollowUp` and `startDelayedFollowUpSync` are removed here, and `TransportAdapterJoinHeldEventsTests` L351-370, which depends on the limit, moves with them.
3. **PR 3, registration.** §4, `validateForRegistration`, the existential refusal in the two macros and at registration (D8 (b)), and the backstop. It is independent of PRs 1 and 2, so it may go first.
4. **PR 4, #87.** §3.7, after D5. It settles #87's (B) and leaves (A) open.

**The failure-handling page.** `docs/core/failure-handling.md` and its `.zh-TW.md` (on `main`, 44f15d90) list each path with its status. Each PR flips its rows from "target" to "current", in both languages, in the same PR:
- PR 1: "A sync plan that throws" to "the first throw ends the land" (row 15); "A server event that fails to encode" (with #521); "One player's state frame fails to encode entirely" (#532, to "the land"); and the "Close codes" section (4016).
- PR 2: "A resync's full view keeps failing to encode" (D3 (a)), since its per-patch part is row 11, which PR 2 converts; it stays "target" until then.
- PR 2 also: "A field whose conversion throws at run time"; "A patch the encoding can't carry … or a path outside the schema".
- PR 3: "Other type errors the type alone decides" (refused at registration, existential fields included), with the gaps of §4 named.
- PR 4: "A handler that throws after writing state".
- Under D2a (a), decided, the "If a failure is confined to one player's view" row of the summary table says no such failure is known, and why (§1).

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
- **Row 15 (D11 (d)):**
  - the first throwing plan ends the land (`.syncPlan`, stage `.syncPhase`), with and without periodic sync, in-turn and legacy;
  - a throwing join-sync plan does too;
  - no follow-up or repair sync-only turn is scheduled after it, and no further plan runs.
  - a legacy plan throw held before its `submitLandFailure` while an admin stop starts: the stop's cause stays, the item is dropped, every session closes with 4014, and no terminal entry is written; the same item submitted twice with one ticket after a failure changes nothing.
- **Tests that rely on a plan throw today (PR 1 migrates them):**
  - `LandKeeperInputTurnTests` L640-655 expects a repair after a throw: it now expects the land to end;
  - the `failNextPlan()` cases in `TransportAdapterSyncPhaseTests` that expect recovery: each becomes a land-ends case, or is removed where another case covers it;
  - `JoinPendingInboundTests` and `LandRouterJoinTimeoutTests` use a plan throw to hold a join for a while. In-turn sync is a synchronous call with no await to hold at, and `.initialSync`/`.initialSyncAfterRead` (TA 349-375) belong to the standalone first sync, so they hold at the existing `.registerSession` point (TA 2312-2316), where the join is admitted but not yet ready to flip. Both await the join call directly today (`JoinPendingInboundTests` 195-203, `LandRouterJoinTimeoutTests` 458-459), which the hold would block, so each changes shape: start the join in a Task, wait for the gate, assert, release, await the join's completion.
  - `TransportAdapterJoinFlipTests` 355-390 tests recovery and backoff after a throw; a hold can't keep that purpose, so it becomes a land-ends test.
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
- **Debug settle:** a failure during debug settle's state read sends nothing and still calls `endSync`. Its own plan throw submits the land failure first, then throws to the debug caller: the test checks the land ended with `.syncPlan` and the caller got the error.
- **A mid-batch failure (Review P1):** a batch of A (succeeds), B (throws after a write) and C (not executed), each once as an action with a tickless job slot and once with an ordinary turn waiter: A gets its response, B its handler error, C `landClosed`; each slot is filled exactly once (a slot hook that fails on a second fill). It fails if the settle moves after the publication:
  - in-turn: C's waiter gets `landClosed`, never `.success(())`, and `appliedItems` holds A and B only;
  - in-turn: `inputTurnResults` holds no entry for C after the turn;
  - the batch cut is tested **in-turn only**, where A, B and C can be one batch (queued while a hold keeps the input drain from starting). On the legacy path each `runLegacyPass` applies every ready input synchronously before its first await (LK 3798-3812), so A's and C's callers apply their own inputs; three legacy callers can't be made to share one batch without changing the code, and this plan claims no legacy batch-cut coverage.
  - legacy, separately: (i) a legacy caller whose input arrives after the failure is rejected with `landClosed` at intake and never applied; (ii) an input queued behind the failing one in the same `pendingItems` (queued by a tick land's intake while its tick is held, then applied by the legacy tick) is dropped by the settle with `landClosed`, filling `legacyPassResults` and `legacyPassAppliedBy` where it has a legacy caller (LK 4894-4899).
  - Tickless action jobs use `runTicklessJobPass` (LK 2112), which has no legacy caller, so the job-slot part runs on the in-turn variant only.
- **The finalize step (Review P2):** the terminal entry is recorded for a failure in a sync-only turn (nothing else submitted), in the turn applying a `landFailure` item, on the legacy tick-land recording path, and in an input drain; it comes after any record of that turn and before any teardown entry; without a recorder nothing is written.
- **The legacy output position:** with in-turn sync off and a recorder, a legacy sync failure records the position of the state it read, and the turns run between it and the turn that applied the item replay.
- **D5's thread-local:** two keepers run in turn on the same thread (a single-thread executor), the second starting from a clean count; a nested handler call restores the outer count; the temporary-`@Sync` false positive is pinned.
- **Record order (D9):** the terminal entry comes after the failing turn's record, for a tick land, a tickless pass and a sync-only turn; on the legacy path, the record holds both positions, and the turns between them replay.
- **The teardown:**
  - with a host, a hold right before the manager's detach, with an admin `DELETE` racing it. The stop runs once.
  - The close code (D10): a failure arriving while the router is held after its snapshot (`stopSnapshot`) gives 4016 to every session whose close request is issued after it, under D10 (a).
  - A failure for an old epoch (the land ID has a new instance) detaches nothing.
  - Without a host, and with a custom transport using the default, the land is destroyed with `.failed` while players were still in it.
  - Destroy handlers see `.failed`; OnLeave doesn't run (D4 (a)).
- **Registration (PR 3):**
  - each type-knowable error at each entry point of §4, including `SchemaExtractor` and the backstop for a directly built keeper;
  - an existential field (`Any`, `AnyObject`, `AnyHashable`, `any P`, and each nested in `[String: Any]`, `(any P)?`, a tuple) is a macro diagnostic in `@StateNodeBuilder` and `@SnapshotConvertible` (macro expansion tests); a hand-written conformance with one is refused at registration where the runtime check exists, and otherwise pinned as the named gap;
  - all failures in one error;
  - a cached failure refuses the second keeper too.
- **Colliding keys (PR 2):** two keys that collide in conversion end the land.
- **#87 (PR 4):**
  - a handler that throws after a root write, after an in-place container write, and after a nested node write ends the land, with stage `.input` and its sequence; a whole-state replacement before the throw is pinned as the named gap (release: the input fails alone, as today; debug: the snapshot compare warns);
  - the tick handler doesn't run, and the later inputs of the batch aren't applied;
  - a handler that throws before any access is rejected alone, and the batch and tick continue;
  - a manual conformance keeps today's behavior in release builds.
- **Record (D9):** a failed run's record ends with the failure and its position. Replay stops there, without applying the rest, and reports "ended by a live failure". A multi-pass tickless replay with a terminal entry in a middle pass: no rerun of the pass, no false pass mismatch, no tick handler after it.
- **The output gate (Q1):** after a `.handlerWrite`, with a hold at `.turnRecord`, a pending repair sync-only turn, a writer-drain retry and a legacy cycle holding a valid output ticket: nothing is sent, and the failing turn's own sync phase and events (the prefix's included) are not sent.
- **The record enqueue (Q2):** the terminal entry is enqueued before the `.turnRecord` hold (asserted at the hold), for each turn kind of §3.2 step 5.
- **The terminal entry versus an admin stop:** the failing turn held at `.turnRecord`, then an admin `DELETE`, then the save: the persisted record holds the turn's record and the terminal entry, in order. The entry was enqueued before the hold, so the tail the save's submission tracker captures (ReevaluationRecorderService 45-58) includes it.
- **The legacy terminal entry (S1):** the legacy tick path held at `.turnRecord` after a failure, then an admin stop and its save: the saved record holds the turn's input record and then the terminal entry, last. The same for the tickless legacy pass.
- **The sessions-closed latch (S2):** (i) an admin stop held right after `closeSessions` (latch set), then a failure: the hook returns at once and the teardown finishes; (ii) an admin stop that has detached the epoch and is held before `closeSessions`, then a failure: the hook's detach finds no instance, awaits the existing latch, and returns once the admin stop sets it; (iii) a failure after the land was fully destroyed for that epoch: no instance and no latch, the hook returns at once. None deadlocks (each test has a time-boxed await that fails the test, not a wall-clock poll).
- **The legacy tick's watermarks:** in the legacy terminal-entry test, the failing tick's record holds W1 (the captured `sequenceBeforeInputs`) and no W2, the terminal entry follows, and replay of that record applies the inputs up to the failing one and stops, with the replayed sequence equal to live's.
- **Latch cleanup:** repeated stop/create cycles of one `LandID` leave no latch behind once each stop finishes; removing an old epoch's latch while a new instance's stop is held leaves the new latch in place; a waiter holding a latch when it is removed still returns.
- **The output gate's contract:** a state frame already in the writer when the gate closes is sent; none is enqueued after; an action response enqueued after the gate is still sent while the session's membership lasts.
- **The teardown's synchronous part (Q3):** after the failing segment, `players` is empty and `drainTask` is set before any await (a hold at the teardown task's start); a host stop and the teardown task racing don't deadlock (the stop's `forceShutdown` joins `drainTask` after `landDidFail` returned).

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
- a throwing sync plan retried or followed up instead of ending the land (the row 15 tests);
- an existential field accepted by a macro (the macro expansion tests);
- `cancelAllActionJobs` left out of `failLand` (the held-resolver test);
- the failure check in `leave` moved after the resolvers (the held-OnLeave test);
- the close code latched before the router's awaits (the `stopSnapshot` test);
- the terminal entry written before the turn's record (the record-order test);
- the settle moved after the publication or after the turn record's await (the A/B/C in-turn and legacy-hold tests);
- `runTurnOutputs` run in the failing turn, or a sync-only entry without its failure check, or a send point that skips the gate (the output-gate test);
- the terminal entry enqueued after an await (the record-enqueue test);
- the teardown's `players` clear or `drainTask` install moved into the task (the teardown test);
- `landDidFail` awaiting the stop's end (the no-deadlock test);
- the latch made a one-shot event, or created after the detach's segment (the latch tests (i) and (ii));
- the hook waiting when no latch exists (latch test (iii));
- the legacy tick's record written directly on a failure (the legacy terminal-entry test);
- `appliedItems` or `inputTurnResults` written for the whole batch (the in-turn A/B/C test);
- the finalize step made conditional on the turn's submission (the sync-only and `landFailure`-item tests);
- the thread-local install without restore (the nested-call and reused-thread tests);
- the validation run inside the cache's lock (a test whose `init()` re-enters validation for another type).

## 9. Decisions (decided 2026-11-13)

The maintainer decided D1–D11 and the drain on 2026-11-13. D12 and D8's scope details came from review afterwards and were answered by Main from the maintainer's stated preferences. Rev 8 (3a55d139) has each one's options and arguments.

- **D1, the close code: (a).** A new code, 4016 `landFailed`. An operator and a client can tell a failure from an admin stop (4014 `landStopped`).
- **D2a, a per-session path: (a), none.** Every sync failure ends the land (§1). D2b (the rejoin bound) and D2c (the `allRecipients` policy) are moot: 4015 `viewFailed`, `viewRepeat` and `allRecipients` aren't built.
- **D3, 4012's retry: (a).** A resync or first view that fails ends the land. The retry goes; 4012 is reserved and no longer sent.
- **D4, OnLeave on a failed land: (a).** No OnLeave, resolvers included: `leave` checks the failure before the resolvers. Membership still ends in the keeper, the adapter and the router, and the destroy handlers and the save see `.failed` (§3.4).
- **D5, the #87 detector: (a).** Mutable access, a thread-local write counter installed around a handler, with the gaps of §3.7.
- **D6, `pathNotInSchema`: (a).** It ends the land. It arises only from a server-side bug (a stale schema, a framework bug, a manual conformance), never from a client.
- **D7, `committedWithRepairPending`: (b), removed** in PR 2, not deprecated (the same reasoning as #521 D13).
- **D8, unknowable-type fields: (b), changed from rev 8's recommendation.** Existential fields are refused where the syntax shows them, at macro expansion, with `AnyHashable` and `AnyCodable` refused by name; a bare protocol spelling, a typealias and a hand-written conformance are a listed gap (§4). Colliding keys are detected in the live conversion and end the land. No `@Sync` field in `Sources/`, `Examples/` or `Tests/` is typed `any …` or `Any`; tightening later would break users, while loosening never does.
- **D9, the record of a failed land: (a).** The record ends with the terminal position (§3.1). Replay applies exactly what live applied:
  - for `.input`, the inputs before the sequence, then the failing input, which must throw again (a mismatch otherwise), then nothing: no later input and no tick handler;
  - for `.syncPhase` and `.eventFlush`, the whole turn;
  - for a failure from the legacy path, every turn up to the end position (§3.3), since they ran live;
  - a tickless land counts by pass, and a sync-only turn by its tick, with no inputs.

  The entry is written after the last live turn's record, through the ordered pipeline (§3.2 step 5). The run reports "ended by a live failure", not a mismatch.
- **D10, where the close code is decided: (a).** Per session, the cause as of the router's close request (§3.4). A failure during the final hop to the transport still leaves 4014.
- **D11, a sync plan that throws: (d), the maintainer's option.** The first throw ends the land; no retry, no bound. A server-side computation failure ends the land at once and is logged, like every other row, and the code has no transient cause.
  - Removed: rev 8's time bound and its `SyncFailureClock`, the count and reset rules, the fixed-delay repair turns after a failed plan, `syncFailedPlanFollowUpLimit` and the failed-plan follow-ups, and the doubling join-sync retry, with their tests.
  - The terminal entry (D9) records stage `.syncPhase`. Replay doesn't run sync phases, so it computes nothing for it.
  - Row 15 is "first throw → land".
- **D12, `InTurnSyncResult.failed(repairAllowed:)`: the payload is dropped** (`.failed`, no associated value) in PR 2, with D7's removal, as one break (§6). Raised by review after D11 (d), answered by Main from the maintainer's stated preference (public API that loses its meaning is removed, not deprecated: #521 D13 (b), D7 (b)); the maintainer may overrule.
- **The drain: an interim named exception** to the reentrancy rule, removed by #522 (§3.4).

## 10. Out of scope

- Row 18's digest scope: diagnostics only.
- The replay loading skips: #521's A5.
- The `1011` close for a join that didn't complete in a turn: an invariant, unchanged.
- #531: a second session of one player.
- #87's (A) undo log: flat storage step 3.
