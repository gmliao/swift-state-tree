# A sync failure ends the unit it corrupted (#535)

**Status:** rev 1, plan only. No code before this plan is reviewed.
- Read at `main` 9755a625. TA = `Sources/SwiftStateTreeTransport/TransportAdapter.swift`, SE = `Sources/SwiftStateTree/Sync/SyncEngine.swift`, ST = `Sources/SwiftStateTree/Sync/SyncTables.swift`, LK = `Sources/SwiftStateTree/Runtime/LandKeeper.swift`.
- The sweep on #535 was read at 9bf7df61. Since then only TA moved: about +11 lines after TA 1420. SE, ST and LK are unchanged. Line numbers below are at 9755a625.

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

Two notes come with the decision. Closing a session must not loop: a repeat after rejoining escalates to the land. A malformed client input is rejected as today, and nothing else ends.

**Related:**
- #532: total per-player frame failure.
- #87: partial writes, folded in here.
- #531: a second session of one player.
- #102, #511, #512: the land stop and its OnLeave.
- #387: server-originated turn inputs.
- #521: typed events and actions. Its plan, `2026-11-13-typed-events-actions.md` on its branch, uses this plan's stop and session-close mechanism for EV4, EV5 and EV7 (§3.6).

## 0. Summary

- **What a failure ends.** Every failure is classified by where its input is computed (§1):
  - Once for all recipients: the land ends.
  - Per recipient: that player's sessions close with a new code, 4015 `viewFailed`.
  - The bound: a player's second close in the same land instance ends the land. So does a plan in which every recipient fails. No success resets it.
- **How the land ends (§3).** In the turn where the failure is seen, the keeper marks the land failed. From then on it applies no input and sends nothing, and that change is made only in a turn. The teardown runs outside the turn on the existing stop path (#102), with a new code, 4016 `landFailed`.
  - On the legacy (not in-turn) sync path, the adapter stops sending at once. It submits the failure as a turn input with a ticket, as #387 does.
- **Registration (§4).** The type checks run at every entry point. `LandKeeper.ensureInitialized` is the backstop for keepers built directly.
- **The sweep (§2).** It gives a verdict on each of the 19 rows and the two replay loading skips, with the PR that changes each.
- **Delivery.** Five PRs (§7). The interim rule (§5) applies until each lands.

## 1. What makes a failure per-recipient

#521's finding applies to every row. An event value is encoded once, before fan-out, so its failure is a fact about the value, and that is land-wide. A failure is **per-recipient** only if the input that failed was computed for that recipient. At 9755a625 these inputs are per-recipient:

- **(P1) A per-player field's value in that player's view**: the output of the field's filter or policy for that player (`extractPerPlayerSnapshot`, SE 1456; `.perPlayer(playerID)` scope). A value-caused throw can be specific to one player's slice. Examples: a non-finite number under `JSONEncoder` in an entity only that player sees, or a user `toSnapshotValue` that throws on a value.
- **(P2) The recipient's frame encode state**: its player slot, its `.perPlayer` key scope, its resync flag and its sync sequence. None of these throws in today's encoders. The only explicit encoder throw is `pathNotInSchema`, plus the serializer's value errors. Today only `syncEncodeFaultForTesting` produces #532's total failure. The decision table still names #532 a session failure, and a future encoder or header field could reach it, so P2 is per-recipient.

Everything else is **computed once**, and its failure ends the land:
- **Broadcast fields**: their conversion, table diff, seed and encode. `SyncTableBroadcastDiff` is broadcast-only (ST 1485), so every ST row is here.
- The merged opcode 107 broadcast frame.
- Every event: encoded once, before fan-out (#521 §1.1).
- A broadcast-only update: the same update for every recipient, and only P2 differs.
- A patch path outside the schema (`pathNotInSchema`): the schema is shared.
- A sync plan that throws as a whole.

**Two refinements:**

- **A frame that mixes scopes.** Combined frames (json, opcodeJsonArray), late-join views, first views and resync views mix both scopes. A failing patch in them is classified by its root field's policy:
  - a broadcast root fails the same way for every recipient, so it ends the land;
  - a per-player root is P1.
  The adapter knows each root's policy (`slotFields` and the schema's sync policy).

- **A type-caused P1 throw.** A P1 failure caused by the field's type recurs for every player, because the type is shared. A single throw can't tell a type cause from a value cause. Two rules catch the type case without guessing (§3.4):
  - in one plan, every recipient fails, with at least two recipients;
  - the rejoin bound.

  A type error knowable from the type alone is refused at registration (§4) and never reaches run time.

## 2. The sweep, row by row

Each row has a verdict, and the PR that changes it (§7). Verdicts:
- **land**: ends the land;
- **session**: closes the player's sessions, under the bound;
- **by scope**: classified per §1;
- **stays**: the path restores fully correct state, and it is kept.

| # | Site at 9755a625 | Today | Verdict | PR |
|---|---|---|---|---|
| 1 | SE 1405-1431 `extractDroppingThrowingFields` | a field whose conversion throws is dropped, and its cached value is kept | by scope: `.broadcast` → land; `.perPlayer(p)` → session (P1) | 2 |
| 2 | SE 1484-1500 `extractWithSnapshotForSync` | `try? snapshotForSync`, falling back to per-field extraction | stays (a route; its drops are row 1) | none |
| 3 | SE 1508-1534 `lateJoinSnapshot` (dropping); TA 4640-4660 | a full view without the fields that don't convert, filled from caches | by scope of each dropped field. The fill from caches goes: a view is sent whole or not at all | 2 |
| 4 | ST 1639-1662 `diff`, ST 1521-1535 `stageSeed` | a broadcast slot whose diff or seed throws is dropped | land | 2 |
| 5 | ST 559-590 `SyncEquatableDiffer.diff` | a `.standard` leaf whose convert throws falls back to the snapshot diff, with a release log | stays: the same output as the snapshot diff, whose own throw is row 4 | none |
| 6 | ST 1142-1144, 1194-1196 `lastSentSnapshot` | a last-sent value that no longer converts reads nil | view path (TA 4655): land. A value that converted when sent and doesn't now means conversion isn't deterministic, and the view would miss a field. Oracle path (ST 1555): stays, as diagnostics | 2 |
| 7 | ST 1612-1620 `viewPatches` | `try?`: a field whose rows don't convert keeps today's patches | stays: today's patches carry the same field, and their own conversion is rows 1 and 3 | none |
| 8 | TA 4453-4463, 4603-4612 (row drop and remake) | rows whose patches don't encode are dropped from the tables, and the plan is remade with key scopes reset | land, for a broadcast row. The **leak** goes too (below). The remake, `planFailedRows`, `rowRetryFields` and the repair result go with it | 2 |
| 9 | TA 4745-4813 `planMergedBroadcastFrame` | re-encode dropping; a total failure unstages the broadcast tables, sets `leavesKeyTablesAhead`, and sends the events as 103 frames | land (drop or total) | 1 |
| 10 | TA 4897-4958 `planPerPlayerFrames` | re-encode dropping; on nil, the player's staged cache is dropped and nothing is sent (#532) | 107 per-player frame: session, dropped patch (P1) or total (P2). Combined frame: by scope of the failing patch's root; total → session (P2) | 1 (total), 2 (patches) |
| 11 | TA 4929-4938, 3574-3586, 3633-3635, 3686-3721 (resync and first-view retry, 4012) | not sent, retried, closed 4012 after `snapshotEncodeFailureLimit` (3) | by scope. A per-player failure is a session failure at once, under the bound, merged with row 10's rule (D3) | 2 |
| 12 | TA 5473-5535 broadcast-only frames | re-encode dropping per player; on nil, skip | land: the same update for all, and only P2 differs. A total failure for one recipient only is P2 → session | 1 |
| 13 | TA 5764-5830 `planFirstSync` | re-encode dropping; even empty fails → `unencodableFirstViews` | by scope, as row 3. With row addressing on, the standalone first sync is refused anyway (TA 5767-5771) | 2 |
| 14 | TA 5652-5689 `encodeDroppingUnencodablePatches` | each patch tried alone; `pathNotInSchema` is counted, others dropped (or the row) | replaced by a classifier: it finds the first failing patch and returns its scope and error, and drops nothing. `pathNotInSchema` → land (D6) | 1 (helper), 2 (callers) |
| 15 | TA 3287-3331, 3200-3205; in-turn TA 2896-2917 → LK 4423-4436 | a plan that throws commits nothing; follow-ups bounded at 3 without periodic sync, **unbounded** with it | stays while bounded: a plan that threw sent nothing, so a later success is fully correct. New bound for both: `syncFailedPlanFollowUpLimit` (3) consecutive failed plans → land | 1 |
| 16 | TA 5706-5761 `_syncStateForNewPlayer` | logged; follow-up. Row addressing in effect: closes 1011 | the joiner's view is classified as row 13. A plan throw stays row 15. 1011 is unchanged (an invariant, not a sync failure) | 2 |
| 17 | TA 3127-3138 `appendEventFrames` (`try? pack`), TA 2792-2795 (body nil at enqueue) | the event is skipped | land (encoded once, §1). The same rule as #521 EV4 | 1 |
| 18 | TA 3989-3993 `canonicalEvent` | nil makes the digest's events scope unverifiable | stays: diagnostics, not client state. Row 17 ends the land first for any event that doesn't encode | none |
| 19 | TA 202-209 `leavesKeyTablesAhead`, set at 4780, 4950, 5482, 5524 | the key scopes are reset in the next plan | removed: every path that sets it now ends the session or the land | 1, 2 |
| R1 | LK 4126-4139 in `runTick` (replay) | an action whose handler isn't found, or isn't `ActionPayload`, gets a warning and `continue` | the tick fails into `recordedPassMismatches` and the run stops failed. LK 4188-4196 and 4217-4224 already do this | 5 |
| R2 | LK 4251-4256 in `runTick` (replay) | a source read that throws is logged, and the tick runs without its inputs | as R1 | 5 |

**Row 8's leak.** `encodeDroppingUnencodablePatches` adds a row to `planFailedRows` whatever frame it is encoding (TA 5678). A joiner's or unsynced recipient's full view carries broadcast row patches (TA 4689). So a per-recipient encode failure, for example `syncEncodeFaultForTesting(p)`, drops broadcast rows for every recipient. Under this plan a per-recipient failure never touches broadcast state: it closes that player's sessions (§3.4). A broadcast row that fails ends the land.

**What else goes.** With rows 8, 9, 10, 12 and 19, these leave the plan and commit paths:
- the drop counters' "data loss" paths: `droppedUpdates`, `logDroppedUpdatesIfDue`, `ExtractionDrops` as a carry-forward;
- `encodeDropScopes`;
- the repair turn.

`ExtractionDrops` stays only as the classifier's report: the first drop, with its scope and field.

## 3. The mechanism

### 3.1 Types (core, `SwiftStateTree`)

```swift
/// Why a land was ended by a failure (#535).
public struct LandFailure: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable {
        case syncConversion   // a broadcast field (or every recipient's per-player field) didn't convert
        case syncEncode       // a frame computed once didn't encode (107 broadcast, broadcast-only, path outside the schema)
        case syncPlan         // the sync plan kept throwing past its bound (row 15)
        case eventEncode      // an event didn't encode (row 17; #521 EV4, EV7)
        case viewRepeat       // a player's view failed again after a viewFailed close (§3.4)
        case allRecipients    // every recipient (two or more) failed in one plan (§1)
        case handlerWrite     // a handler threw after writing synced state (#87, §3.7)
    }
    public let kind: Kind
    public let field: String?        // the root field, when known
    public let playerID: PlayerID?   // viewRepeat
    public let detail: String        // the error's text
}
```

**`LandDestructionCause` gains `.failed`** (LK 5334). This adds a public enum case: a caller's exhaustive `switch` gets a "switch must be exhaustive" error, and the PR body states that.

### 3.2 The land fails in a turn

`LandKeeper.failLand(_ failure: LandFailure)` is private and synchronous, and is called only inside a turn. In one segment it:
1. Sets `failure` (the first one wins; later ones are logged at debug) and `mode = .failed`.
2. From then on, input submission is refused:
   - actions and events get a new `failed` refusal;
   - `submitServerInput` returns `.refused(.notLive)`;
   - joins get `JoinError.landShuttingDown`.
3. The tick schedule is cancelled. Pending inputs are left unapplied: the land's state no longer goes anywhere.
4. Records the end: the recorder writes the failure into the record's metadata. It isn't an input; replay runs the inputs up to that tick and reports the run as ended by a live failure (D9).
5. Starts the teardown **outside** the turn: a `Task` that calls `transport.landDidFail(failure)` (§3.3) and holds no keeper state across its awaits.

Callers:
- **In-turn sync**: `applyInTurnSyncResult` on a new `InTurnSyncResult.landFailed(LandFailure)`. The adapter returns it from the synchronous sync phase: it committed nothing and sent no state frame. Events enqueued before the plan in that turn are already in the writer. This adds a public enum case on a public protocol's result; the switch break is named in the PR.
- **Input application**: `applyPendingItems` on a #87 handler write (§3.7).
- **Server failures arriving as turn inputs** (§3.3, the legacy path): the turn applies them.

### 3.3 Paths outside a turn

**The adapter stops at once, in its own state.** In the segment where the adapter sees the failure, it sets its own `landFailure`. From then on:
- every send path (sync, broadcast-only, events, first sync) returns without sending;
- every plan returns `.landFailed`.

That is adapter state, so the keeper's rule doesn't bind it, and it closes the window before the keeper's turn.

**The legacy sync path.** `withSyncState` and the legacy event flush run outside the keeper's turns, and they await. A failure there is submitted as a turn input:

```swift
extension LandKeeper {
    /// The transport reports a failure that ends the land. Applied in a turn of its own, as a
    /// server input (#387); `ticket` is the keeper's lifecycle generation captured when the work
    /// that failed began. A stale ticket (the land restarted meanwhile) is ignored.
    package func submitLandFailure(_ failure: LandFailure, ticket: LandLifecycleTicket) async
}
```

- The item is internal (a `PendingItem.landFailure`), not a user `HandleServerInput`, and it isn't recorded as an input.
- The turn that applies it re-reads `mode` and validates the ticket, then calls `failLand`.
- A tickless idle land schedules that turn the way `submitServerInput` does.

**The teardown: `LandKeeperTransport.landDidFail(_:)`.**
- It is a new protocol requirement with a default implementation, so it is additive. The default is the keeper's own `shutdownIfIdle(cause: .failed)`, for keepers used without a host.
- `TransportAdapter` forwards it to an `onLandFailure` closure. `LandManager` installs that closure at creation, and it calls the server's stop:
  - `NIOLandServer.stopLand` gains a package overload `stopLand(landID:epoch:close:)`;
  - the epoch is the land's `LandRouter` epoch captured when the land was created: a stop for an epoch that is no longer current is ignored (`GenerationTable.ifCurrent`);
  - `close` is `.landFailed` (4016) instead of `.landStopped`.
- The stop path is #102/#511's: `detachForStop`, then the sessions closed with the code, then `forceShutdown` (destroy handlers, save), then `endClosing`. OnLeave runs as #512 settles it for any stop. Destroy handlers see `.failed` (D4).
- `SingleFlight` makes an admin `DELETE` racing a failure stop run once.

### 3.4 A session closes, with a bound

**`SessionClose.Code.viewFailed = 4015`.** It means: this player's view failed to encode; the land is fine; a rejoin gets a full view. Unlike 4010–4012, the client may rejoin.

When a plan meets a per-recipient failure (P1 or P2) for player `p`, in the same synchronous segment the adapter:
1. Leaves `p` out of the commit: its staged per-player snapshot, its first-sync mark and its resync are dropped. Nothing is sent to it this plan.
2. Closes **every** session of `p` with 4015 through `endAndCloseSession`. That is synchronous marking plus the close `Task`, as 4012 does today (TA 3730-3751). Every session, because a player's sessions share the per-player value (#531).
3. Checks and updates the bound: `viewFailedPlayers: Set<PlayerID>` on the adapter, kept for the land instance.
   - `p` not in it: insert `p`.
   - `p` already in it: the plan returns `.landFailed(kind: .viewRepeat, playerID: p)` instead.
   - The set has **no reset**: no later success of `p`, of another player or of another value removes `p`. A healthy encode of other values can't show that the failing value is gone (#521's finding). It is removed only with the land.
4. **All recipients failed:** every recipient of the plan failed, and there are at least two. That is the type case (§1), so the plan returns `.landFailed(kind: .allRecipients)` and closes nothing first.

The rest of the plan commits for the other recipients. The keeper learns of the leave through the normal disconnect path. The adapter mutates nothing in the keeper.

**Memory.** The set holds one `PlayerID` per player that ever failed in this land instance. Sessions are tens of minutes (the target session length), so it stays small.

**4012 `unencodableView`.** Its sources move under this rule (D3):
- a resync or first view that fails on a per-player field closes with 4015 at once, under the same bound;
- on a broadcast field, it ends the land.

4012 stays reserved and is no longer sent.

### 3.5 Counters and logs

**Counters** go on the adapter's profiler counters and the land's stats:
- `landFailures` by `Kind`;
- `viewFailedCloses`.

**Logs.** One `error` log per failure. Its fields: land type and ID, kind, field, player (for a session), error text, sync sequence and target. A session close is logged at `warning`. A malformed client input is unchanged: rejected, and counted as today.

### 3.6 Names for #521 (coordinated through Main)

#521's EV4, EV5 and EV7 use:
- `LandFailure.Kind.eventEncode`;
- in a turn, the adapter's `.landFailed` result;
- on the legacy flush, `submitLandFailure(_:ticket:)` with the ticket captured when the flush began.

Under #521 D9 (b), the recommended option, EV5 doesn't exist. Under D9 (a), a targeted event's failure would use §3.4's close and bound, keyed by player. This plan recommends (b): the event is encoded once, which §1 classifies as land-wide.

**Registration.** #521's `validatePayloads(context:)` runs at the same entry points as §4's checks. Both are called from one function, `LandDefinition.validateForRegistration(context:)`:
- PR 3 of this plan adds it with the sync-type checks;
- #521 adds its payload checks into it.

Whichever PR merges first adds the function.

### 3.7 #87: a handler that throws after writing

**Today.** A throwing input fails alone, and its writes before the throw are kept. The debug builds warn by comparing `fullStateSnapshot` (LK 3141-3191). The maintainer's 2026-11-10 decision on #87 was (B) for now and (A), an undo log, with flat storage step 3.

**Under #535's table.**
- A handler that throws **after writing synced state** ends the land (`.handlerWrite`).
- A handler that throws **before any write** is a rejected input, as today: an error to the client, removed from the queue, recorded with its failure, and nothing else ends.
- When #87's (A) undo log exists, a rollback restores fully correct state, so the throw goes back to rejecting the input alone, and the land no longer ends.

The release build needs a cheap "did it write" test (D5).

## 4. Registration refusals

**Knowable from the type**, checked by walking the schema and the type:
- a class type declared in a synced field (`classRefusal`). `SyncValueSemantics.validate` already checks declared class types and classes in a default instance;
- an unsupported key type (`SyncError.unsupportedKey`, SnapshotValue.swift:476). This is new in the validation;
- a player-dependent node under a broadcast field (#179). `SyncPolicyNesting.validate` covers it except where the walk can't see the type.

**Not knowable from the type**, so the land ends at the first throw (rows 1, 3, 4):
- an `Any` or `any P` field's value;
- an enum case not taken by the default instance;
- a class inside an empty-by-default collection;
- colliding keys (they throw only in `makeFull`; the sync `make` path overwrites silently at SnapshotValue.swift:427);
- a user `toSnapshotValue` that throws;
- a non-finite number under JSON.

Existential fields stay allowed (D8).

**Entry points:**

| Entry point | Today | Under this plan |
|---|---|---|
| `NIOLandHost.register` (NIOLandHost.swift:354) | throws; validates at :363-364 | adds the new checks |
| `LandTypeRegistry.init` (LandTypeRegistry.swift:33-39) | throws; validates | adds the new checks |
| `SchemaExtractor.extract` (:20) | validates | unchanged (it uses the same validation) |
| `LandManager.getOrCreateLand` (LandManager.swift:367) | no validation | none needed: a manager from a host or registry is validated there. A manager built directly is covered by the keeper's backstop |
| `ReevaluationEngine.run` (ReevaluationEngine.swift:192) | throws, no validation | validates before the keeper is built; the run fails with the error |
| `LandKeeper.init` (LK 807) | doesn't throw | unchanged |
| `LandKeeper.ensureInitialized` (LK 893) | async throws; a failure tears the land down (`tearDownAfterFailedInitialization`, LK 927-932) | **the backstop**: runs the validation, cached once per `(State type, definition id)`, so every keeper, including tests' and benchmarks', is checked once. A refusal fails initialization, as an OnInitialize throw does today |

All failures are reported in one error (`SyncRegistrationError`, one case per row, with the field path and reason). It sits next to #521's `PayloadRegistrationError` under `validateForRegistration`.

## 5. The interim rule

Until each row's PR lands:
- **A known absorb path keeps today's behavior.** Its tests pin today's output and cite #535, as #514's plan does.
- **New code adds no absorb path.** Before PR 1, a new failure path logs at `error`, counts and pins the gap with a test that cites #535. It must not drop silently.
- **After PR 1, new code uses the mechanism**: `LandFailure` and `.landFailed`, the 4015 close with its bound, or `submitLandFailure`.
- **#514 (per-player tables).** Its interim outputs (M7, T1, T2) are replaced by rows 1, 3 and 10 under PR 2. Its byte-identity contract's failure half holds once PR 2 is in: after it, no failed land keeps running.

## 6. Public API

| Change | Kind |
|---|---|
| `LandFailure`, `LandFailure.Kind` | new types |
| `LandDestructionCause.failed` | new enum case (an exhaustive switch breaks; named in the PR) |
| `InTurnSyncResult.landFailed(LandFailure)` | new enum case on a public protocol's result (the same note) |
| `InTurnSyncResult.committedWithRepairPending` | no longer returned. Deprecated, not removed (D7) |
| `LandKeeperTransport.landDidFail(_:)` | new requirement with a default implementation |
| `SessionClose.Code.viewFailed` (4015), `.landFailed` (4016); `SessionClose.landFailed` | new constants (the preset is package, as `.landStopped` is) |
| `SyncRegistrationError` | new type, thrown by entry points that already throw |
| action and event refusal `failed` | new enum case on the input refusal (named in the PR) |
| `TransportAdapter.unmappedPathPatches` | kept; it counts the failure that ends the land |
| TS SDK: `VIEW_FAILED_CLOSE_CODE`, `LAND_FAILED_CLOSE_CODE` in `protocol.ts` | new exports; docs say 4015 may rejoin, 4016 doesn't retry the instance |

Behavior changes named in each PR body and in `docs/` (bilingual):
- a land with a sync failure ends;
- a player whose view fails is closed with 4015;
- 4012 is no longer sent;
- a handler that throws after writing ends the land.

`package` members (`submitLandFailure`, `stopLand(landID:epoch:close:)`, `failLand`) aren't public.

## 7. PRs

1. **PR 1, the mechanism and the total failures.**
   - The mechanism: §3.1–3.5, `submitLandFailure`, `landDidFail`, the host hook, the codes and the bound.
   - Rows 9, 10 (total), 12, 15, 17 and 19 (partly), and the row 14 classifier.
   - The SDK constants and docs.
2. **PR 2, the conversion and per-patch paths.** Rows 1, 3, 4, 6, 8 (with the leak), 10 (patches), 11 (4012 merged), 13, 14's callers, 16 and the rest of 19. The removals in §2.
3. **PR 3, registration.** §4, `validateForRegistration`. Independent of PRs 1 and 2, so it may go first.
4. **PR 4, #87.** §3.7, after D5. It closes #87's (B) and leaves (A) open.
5. **PR 5, replay loading.** R1, R2. Small, and independent. If #521's PR 1 lands first, its A5 does this, and PR 5 is dropped (coordinated through Main).

PRs 1 and 2 touch the sync phase. Each gets the in-turn on/off and sync tables off CI builds, and an off-path A/B on the healthy path (no failure), run by the off-path instruction gate (#517). The healthy path should change only by a branch per failure check.

## 8. Tests

Swift Testing. An interleaving is forced with a hold at the `await` (`HoldPoints`, `TestGate`), never with timing.

**Faults.**
- Existing hooks:
  - `syncEncodeFaultForTesting(PlayerID)`: P2, per-player and combined frames;
  - `syncPlanFaultForTesting`: row 15;
  - `firstSyncPlanFaultForTesting`;
  - `eventEncodingFaultForTesting`: row 17;
  - throwing test types for conversions (`TransportAdapterSyncPhaseTests`, `RowAddressingAdapterTests`, `SyncTableDiffTests`);
  - NaN under JSON.
- Two new hooks (package): a broadcast-only encode fault and a merged-107 encode fault. Today `syncEncodeFaultForTesting` doesn't reach the merged frame.

**Cases.** Each runs on all three encodings, with in-turn sync on and off where both paths exist.

- **Land rows (4, 9, 12, 17, broadcast 1/3/6/8, `pathNotInSchema`):**
  - the land ends;
  - every session closes with 4016;
  - nothing from the failing plan is sent after the failure;
  - another land on the same host keeps syncing;
  - a join to the same land ID afterwards gets a new instance.
- **Session rows (10 P1 and P2, 11, 13, per-player 1/3):**
  - only `p`'s sessions close with 4015, and every session of `p` (a second session admitted through the diagnostics path);
  - the others get this plan's frames;
  - `p`'s rejoin gets a full view.
- **The bound:**
  - a second failure of `p` after a rejoin ends the land (`.viewRepeat`);
  - successes in between, of `p` with other values and of other players, don't reset it;
  - two failures of `p` in one plan close once;
  - every recipient failing, with two or more, ends the land at once (`.allRecipients`);
  - one recipient alone failing closes the session.
- **Row 15:** three consecutive throwing plans end the land, with and without periodic sync. A success in between resets the count, because a plan that threw sent nothing.
- **The legacy path:**
  - a failure on the legacy sync and on the legacy event flush stops sending at once;
  - it reaches the keeper as a turn input;
  - a stale ticket (the land restarted under a hold at the flush's await) is ignored.
- **Teardown:**
  - with a host, the stop runs once when an admin `DELETE` races it (hold);
  - without a host, `landDidFail`'s default destroys the land with `.failed`;
  - destroy handlers see `.failed`.
- **Inputs after failure:** actions, events, server inputs and joins are refused, and pending inputs aren't applied.
- **Registration (PR 3):** each type-knowable error at each entry point of §4; all failures in one error; the keeper backstop for a directly built keeper.
- **#87 (PR 4):**
  - a handler that throws after a write ends the land;
  - one that throws before any write is rejected alone, and is applied once;
  - the earlier inputs of the batch are applied once.
- **Replay (PR 5):** R1 and R2 each fail the tick with its reason, and the run stops failed.

**Mutants.** Each is run once and caught by a named test:
- a dropped patch still sent (row 1, 3, 10);
- a broadcast failure that closes only sessions;
- a per-player failure that ends the land;
- the bound reset by a success, by a leave, or by another player's success;
- the bound counting failures within one plan;
- `allRecipients` firing with one recipient;
- the adapter still sending between the failure and the keeper's turn;
- `failLand` called after an await (the in-turn rule; the stale-ticket test catches it);
- the legacy failure applied without its ticket check;
- 4014 sent instead of 4016;
- the row 8 leak restored (a per-recipient failure that drops a broadcast row);
- the validation skipped in `ensureInitialized`;
- #87 throw-before-write ending the land.

## 9. Decisions for the maintainer

Each has a recommendation.

- **D1, the close codes.**
  - (a) Two new codes: 4015 `viewFailed` (may rejoin) and 4016 `landFailed` (this instance is gone).
  - (b) Reuse 4014 `landStopped` for a failed land.
  - **Recommend (a).** An operator and a client can tell a failure from an admin stop, and 4014's docs say "stopped", which a failure isn't.
- **D2, the rejoin bound.**
  - (a) Per `(land instance, player)`, no reset, plus the every-recipient rule.
  - (b) Per `(player, root field)`: a later failure on another field closes the session again.
  - (c) Reset after a quiet period.
  - **Recommend (a).** (c) resets on healthy success, which the scope decision rules out. (b) gives a value that fails on several fields several closes. Sessions are tens of minutes, so a second unrelated failure in one instance is rare. When one happens, ending the land is the conservative reading of "fails again after rejoining".
- **D3, 4012's retry.**
  - (a) Merge it: a resync or first view that fails on a per-player field closes with 4015 at once, under the bound. On a broadcast field it ends the land. 4012 is reserved and no longer sent.
  - (b) Keep the 3-plan retry and 4012 for resync views only.
  - **Recommend (a).** A resyncing client is already behind. Waiting three plans leaves it wrong longer, and a rejoin gives it the same full view. (b) keeps a second rule for the same failure.
- **D4, destroy handlers on a failed land.**
  - (a) Run them, and the save, as on a stop, with `.failed` visible, so a land can skip saving.
  - (b) The framework skips the save for `.handlerWrite` only.
  - (c) Skip every destroy handler.
  - **Recommend (a).** A sync failure leaves the state itself correct, and only #87's leaves it wrong. The land knows what its save means. The cause is passed, not decided for it.
- **D5, detecting a write before a throw in release builds (#87).**
  - (a) A write generation counter on the state, bumped by the macro's setters, and compared around each handler. The cost is one increment per write; the off-path A/B checks it.
  - (b) Release builds use the debug build's snapshot compare. That costs a copy-on-write retain per input and a container copy on each input's first write. #87's decision rejected that cost.
  - (c) No PR 4 until #87's (A) undo log, which restores instead of ending.
  - **Recommend (a).** (c) would leave the partial-write row open until flat storage step 3.
- **D6, `pathNotInSchema`.**
  - (a) End the land: the schema is shared, so every recipient fails.
  - (b) Keep dropping and counting it.
  - **Recommend (a).** No production trigger is known. One would mean the state produced a path its own schema lacks, a land-wide fault, and (b) is an absorb path under the rule.
- **D7, `InTurnSyncResult.committedWithRepairPending`.**
  - (a) Deprecate it, never return it, and remove it in a later major change.
  - (b) Remove it now.
  - **Recommend (a).** Removal breaks a custom transport's switch, and removals go to the maintainer.
- **D8, existential and unknowable-type fields.**
  - (a) Allowed. A failure ends the land at the first throw.
  - (b) Refused at registration.
  - **Recommend (a).** (b) breaks lands that use them today, and (a) already ends the land on the first wrong value.
- **D9, the record of a failed land.**
  - (a) The record's metadata holds the failure and its tick. Reevaluation replays the inputs up to that tick and reports "ended by a live failure", not a mismatch.
  - (b) Nothing is recorded, and the record just ends.
  - **Recommend (a).** Without it, a replay can't tell a failed run from a truncated one.

## 10. Out of scope

- Row 18's digest scope: diagnostics only.
- The `1011` close for a join that didn't complete in a turn: an invariant, unchanged.
- #531: a second session of one player. It is its own bug. §3.4 closes every session of the player, which is correct whether or not #531 is fixed.
- #87's (A) undo log: flat storage step 3.
- A client SDK auto-rejoin on 4015: the SDK exports the code; rejoining stays the application's.
