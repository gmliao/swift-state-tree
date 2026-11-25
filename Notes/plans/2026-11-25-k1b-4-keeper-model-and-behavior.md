# K1b-4: `KeeperModel<State>` and `KeeperBehavior<State>`, with the census test (#700)

**Status:** rev 2.2, plan only. Rev 2.2 is two corrections found in implementation prep, after Review's GO on rev 2.1: a tuple field needs a struct, and the model row has 58 fields, not 59 (§13). Review on rev 2: 1 must-fix (a one-row correction; GO once fixed), 4 should, 1 nit; rev 2.1 takes all of them (§12). Rev 2 answered Review's NOT GO on rev 1.2 (3 must-fix, 5 should, 1 nit; §11). It was read at #853's reviewed head 2afb96fc (K1b-3, on #835's K1a). The review fix round a87e0278 changes no line of `LandKeeper.swift`, so its line numbers hold there too. Rev 1.2 took Appendix A's F5–F8 (#700 plan rev 5.8) and K1b-3's fields (§10). Rev 1.1 settled D2 and took the K2 survey's shape (§9).
- K1b-4 needs K1b-1 (the plain forms), K1b-2 (`FailureID` and the side tables), K1b-3 (the RNG) and P4-1 (K1b-Q3). It names their results by their planned shapes. It rebases on their landed types and regenerates its references and its census then (§8).
- The census is Appendix A of `2026-11-22-keeper-on-turncore.md` (draft 3 and A.7), with this plan's changes in §2.

## 1. Goal

`LandKeeper`'s stored state splits by home, with no behavior change:
- `var model: KeeperModel<State>`: `@PlainData`, the core's machine;
- `nonisolated let behavior: KeeperBehavior<State>`: fixed at init (the definition and the keeper's own configuration);
- the outside, replay and K2–K9 fields stay on the actor. The replay fields are grouped in one struct, which K2 moves into `ReplayLandOwner` (and #612 deletes, with the owner).

A census test makes each stored property's home a checked fact. `@PlainData` on `KeeperModel` makes "the model is plain" a compile-time fact.

K1b-5 (turn bodies as `mutating` methods on `KeeperModel`) builds on it.

## 2. The census

**Counts.** The actor body has 126 stored instance properties at 5baa1887 (K1a) and 128 at #853's reviewed head 2afb96fc: K1b-3 added `landRandom` and `landRandomSeed` (LK:424–427). Three of them are DEBUG-only (the filled-slot ring, LK:2495–2502), so a release build has 125. The pass skipped computed properties and `static`. Rev 2's list came from a script over the actor body. K1b-4 repeats it on its base with the LSP's `documentSymbol`.

**Where each one goes** (the destination inventory; a path is relative to the actor):

| Destination | Fields |
|---|---|
| `model` (58: 55, plus the 3 DEBUG-only ring fields) | `state`, `players` (§3.3: without `services`), `entryGenerations`, `landRandom`, `pendingItems`, `serverInputsHeldWhileFrozen`, `pendingItemScans`, `initializationFailure` (as K1b-2's failure record), `actionJobs` and `actionSlots` (their plain halves, K1b-2), `inputTurnResults`; the counters `stateHashUnavailableTotal`, `serverInputsInFlight`, `serverInputCapRejections`, `syncStreamCounter`, `passOrdinal`, `foldedSyncs`, `overdueFoldedSyncs`, `lateFoldedSyncs`, `inTurnDeferredTurns`, `recorderSubmissionCount`, `inputsSkippedAfterDestroy`, `joinSyncTicks`, `supersededSenderRejections`, `actionJobsStarted`, `nextTickId`, `lastCommittedTickId`, `ticksInFlight`, `requestedSyncWork`; the flags `destructionFinished`, `transportRecordsFolds`, `didInitialize`, `inTurnSyncDue`, `inputDrainScheduled`, `joinSyncWaitsForCommit`, `shutdownRequested`, `hasHeldTransport`, `destroyHandlersStarted`, `shutdownTurnApplied`, `passInProgress`; `inTurnSyncTurnKind`, `syncOutputIndexCursor`; the bindings `syncBinding`, `inTurnDrainRetryBinding`, `joinSyncTurnBinding`; `ticklessJobWork`, `ticklessJobTurns`; the freeze's plain part `debugFrozen`, `debugInFlightWork`, `debugNextWaiterID`, `debugActiveGeneration`, `debugReleasedGeneration`; the test counters `joinSyncRequestTurnsForTesting`, `joinSyncTurnsForTesting`, `requestedSyncTurnsForTesting`; and, DEBUG only, `filledActionSlotsForAssert`, `filledActionSlotsOrderForAssert`, `filledActionSlotsNextForAssert` |
| `behavior` | `definition`, `services`, `resolverServices`, `payloadDecoders`, `logger` |
| `behavior.config` (`KeeperConfig`, internal; §3.2) | `autoStartLoops`, `enableLoopPhaseOffset`, `enableLiveStateHashRecording`, `reevaluationOutputMode`, `mode`, `actualLandID`, `landRandomSeed`, `systemPlayerID`, `systemClientID`, `systemSessionID` |
| `replay` (`ReplayFields`, D2) | `reevaluationSource`, `reevaluationSink`, `replayHeaderPayloadEncoding`, `replayedInitializeBeforeTickZero`, `replayedInitializeRefusal`, `replayPassObserver`, `replayFailureEnd`, `replayRecordsPassOrdinals`, `replayRecordsRejected`, `replayRejected`, `recordedPassMismatches` |
| actor, the containers themselves | `model`, `behavior`, `replay`; and `behavior.config` inside `behavior` |
| actor, the output collector (D1; K2) | `outputCollector` |
| actor, the player-services table (new, §3.3) | `playerServices` |
| actor, the binding token's parts (K2) | `transport`, `releasedTransport`, `boundSyncRequesterObject`, `pendingSyncTurnAfterTurn` |
| actor, the recorder (K2) | `reevaluationRecorder`, `recorderSubmissions` |
| actor, the drain flag (K2) | `drainFlag` |
| actor, resolver abandonment (K5) | `abandonmentCounter` |
| actor, the loop driver's time (K2; F4, F8) | `nextTickDeadline`, `pendingFold` (its deadline and its overdue flag together: they are set and read as one optional, LK:852, 5124–5135, 6176–6182), `tickLoopConfiguredAt`, `tickLoopClock`, `appliedTickPhaseOffset`, `appliedSyncPhaseOffset` |
| actor, the server-input cap (§3.2) | `serverInputMaxInFlight` |
| actor, K1b-2's tables | the failure table, `failureIDs`, `actionJobTasks`, `actionSlotWaiters` (K1b-2's names; K1b-4 takes the labels from its base). The plain halves of jobs and slots are the `model` row's `actionJobs` and `actionSlots` |
| actor, replaced in K2 | `tickTask`, `syncTask`, `inputTurnWaiters`, `initializationWaits`, `initializationWaitWatchers`, `actionJobRemovalWaiters`, `tickIdleWaiters`, `shutdownTurnWaiters`, and the test waiters `drainStartedWaitersForTesting`, `nextDrainStartedWaiterForTesting`, `freezeWaitWatchersForTesting`, `inputDrainIdleWaitersForTesting`, `requestedSyncWorkWaitersForTesting`, `nextRequestedSyncWorkWaiterForTesting`, `failureWaitersForTesting`, `nextFailureWaiterForTesting` |
| actor, replaced in K4 | `pendingTransportFailure` |
| actor, replaced in K5 | `initializationTask` |
| actor, replaced in K7 | `destroyTask`, `drainTask`, `forceShutdownFlight`, the freeze's continuations `debugHeldInputs`, `debugDrainWaiters` |
| actor, test hooks | `holds`, `inTurnProbeForTesting`, `inTurnYieldForTesting`, `syncClockForTesting`, `tickClockForTesting` |

**Changes from Appendix A:**
- `appliedTickPhaseOffset` and `appliedSyncPhaseOffset`: Outside, not Model (F8). K1b-4 checks first, with `findReferences` on its base, that no turn reads them. If one does, that offset stays in Model and joins S3's exception (§4.3).
- `pendingFold`: wholly Outside. A.3 says its flag part is already in Model in K1b. It isn't: the deadline and the flag are one optional, read and written together.
- `serverInputMaxInFlight`: Outside, not Behavior (§3.2).
- `players[…].services`: the new `playerServices` table, Outside (§3.3).
- The per-keeper configuration: an internal `KeeperConfig`, not the public `LandConfig` (§3.2).
- The freeze's counts and generations go to Model now; its continuations stay until K7 (A.4).

## 3. Shape

### 3.1 The model (SwiftStateTree, `Runtime/KeeperModel.swift`, internal)

```swift
@PlainData
struct KeeperModel<State: StateNodeProtocol> {
    var state: State
    var players: [PlayerID: KeeperPlayerEntry]   // InternalPlayerSession without `services`
    var pendingItems: [PendingItem]
    var landRandom: DeterministicRng
    // … every `model` row of §2 (each field keeps its name)
}
```

- `StateNodeProtocol` refines `PlainData` after P4-1, so the macro's conditional conformance holds for every land.
- **Field names don't change.** `model.players` reads the same as `players` does today, so the diff is a prefix and a reader can follow it.
- **The conformances the model needs** beyond K1b-1's (the queued items, `LandFailure`, the held resolver outputs) and K1b-2's (`FailureID`, the split job and slot halves):

| Type | Where (at 2afb96fc) | Visibility | Change |
|---|---|---|---|
| `InternalPlayerSession` → `KeeperPlayerEntry` | `private struct` at file level, LK:6450 | private → internal, moved to `KeeperModel.swift` | `@PlainData`, without `services` (§3.3). Its fields: `ClientID?`, `SessionID?`, `Epoch`, `String?`, `Bool`, `[String: String]` |
| `Epoch` | Support/SingleFlight.swift:141 | **public** | `PlainData`, additive |
| `EpochCounter` | Support/SingleFlight.swift:157 | **public** | `PlainData`, additive |
| `Ticket<Key>` | Support/Generations.swift:8 | package | `@PlainData` on the definition, so the macro generates the conditional conformance (`where Key: PlainData`); explicit annotations where a stored field's type is inferred |
| `GenerationTable<Key>` | Support/Generations.swift:31 | package | the same |
| `SyncBindingKey` | LK:47 | package | `@PlainData` (so `SyncTurnTicket`, LK:52, is plain) |
| `SyncBindingState` | `private struct`, nested in the actor, LK:5503 | private → internal, moved to `KeeperModel.swift` as `KeeperSyncBinding` | `@PlainData` |
| `ActionTicket` | internal, nested in the actor, LK:2387 | moved to `KeeperModel.swift` as `KeeperActionTicket` | `@PlainData` |
| `SyncTurnReason` | LandKeeperTransport.swift:318 | package | `@PlainData` (a dictionary key in `requestedSyncTurnsForTesting`) |
| `ReevaluationRecordedSyncOutput.TurnKind` | ReevaluationSyncStream.swift:13 | **public** | `PlainData`, additive |
| `syncOutputIndexCursor`'s tuple `(observedTickId: Int64?, count: Int)` | LK:538 | — | the macro refuses a tuple field (`PlainDataDiagnostic.tuple`), so it becomes `KeeperSyncOutputCursor`, an internal `@PlainData` struct with the same two labels; its two reads (LK:5299–5300) stay the same, and the assignment at LK:5304 calls its init |
| `PlayerID`, `ClientID`, `SessionID` | Sync/PlayerID.swift, Land/Types.swift | public | already `@PlainData` |

- **Nested types move out.** `KeeperModel` is a separate generic type, so it can't name a type nested in `LandKeeper<State>` without the generic parameter. `SyncBindingState` and `ActionTicket` are nested; `InternalPlayerSession` is at file level but private. All three move to `KeeperModel.swift` as internal types, with a `Keeper` prefix. None depends on `State`, and none is exposed publicly. Their uses in `LandKeeper.swift` are renamed in the same commit.
- **Internal stored fields that tests read** (`foldedSyncs`, `lateFoldedSyncs`, `requestedSyncTurnsForTesting` and the other `private(set)` counters) become computed getters over `model`, with the same name and access. K1b-4 lists them with `findReferences` from the test targets on its base.
- **Public members that are stored today stay public,** as computed accessors over the new homes: `definition` (`public let`, now `nonisolated public var definition { behavior.definition }`) and `serverInputCapRejections` (`public private(set) var`, now a `public var` with a getter over `model`). The package ones too: `replayedInitializeRefusal` and `joinSyncRequestTurnsForTesting` (getters); `abandonmentCounter` stays a stored `nonisolated let`.

### 3.2 The behavior, and the keeper's own configuration (MF3)

```swift
struct KeeperBehavior<State: StateNodeProtocol>: Sendable {
    let definition: LandDefinition<State>
    let config: KeeperConfig
    let services: LandServices            // outside-world services only (K1b-3 strips the RNG)
    let resolverServices: (any Sendable)? // nil: the land declares services and was given none
    let payloadDecoders: RecordPayloadDecoders
    let logger: Logger
}

struct KeeperConfig: Sendable {          // internal
    let autoStartLoops: Bool
    let enableLoopPhaseOffset: Bool
    let enableLiveStateHashRecording: Bool
    let reevaluationOutputMode: ReevaluationOutputMode
    let mode: LandMode
    let actualLandID: String?
    let landRandomSeed: UInt64
    let systemPlayerID: PlayerID, systemClientID: ClientID, systemSessionID: SessionID
}
```

- **Not `LandConfig`.** `LandConfig` is public (Land/LandConfig.swift:6), the DSL's flattened configuration, exposed through `LandDefinition.config`. It holds `allowPublic`, `maxPlayers`, `allowedClientEvents`, `tickInterval`, `destroyWhenEmptyAfter` and `persistInterval`, and none of the per-keeper values. Checked with the LSP at 2afb96fc:
  - `landRandomSeed` has 6 references, all in `LandKeeper.swift`;
  - `autoStartLoops` has 31, all in `LandKeeper.swift`;
  - the other per-keeper fields are `private` on the actor, so nothing outside the file can read them.

  So nothing outside the package reads any of them through `LandConfig`, and K1b-4 adds nothing to `LandConfig`. `behavior.definition.config` keeps meaning what it means today.
- **The server-input cap stays Outside.** It is set from the environment at init (`ServerInputLimits.maxInFlightPerLand()`). Three callers set it after init through `setServerInputMaxInFlightForTesting` (LK:3556): ServerInputTests.swift:571 and 588, and ServerInputDecodeAtSubmitTests.swift:148. Moving it into Behavior would need a new init parameter on the public `LandKeeper.init`, or a second init. K1b-4 keeps it a stored actor field, read by the intake segment as today. K2 places it with `LiveLandTurns`' configuration, where a package init exists.

### 3.3 The player-services table (MF2)

`InternalPlayerSession.services` (a `LandServices`, references) can't be in the model. It moves to an actor-side table:

```swift
private var playerServices: [PlayerID: (generation: Epoch, services: LandServices)] = [:]
```

- **Written in the same synchronous segment as every insert and remove of `players`,** keyed by the entry's generation, so a late writer never removes a newer entry's services:
  - two inserts: LK:1949–1960 (the public `join(playerID:…)`), LK:2157–2181 (`joinReportingAdmission`);
  - three generation-guarded rollbacks: LK:2005–2008, LK:2232–2235, LK:6212–6216 (the resolver-error rollback);
  - one ordinary removal: the leave, LK:2855–2887;
  - four bulk clears: LK:1354–1357, LK:2992–2995, LK:4049 (live only: `if mode == .live`, kept), LK:5894.

  K1b-4 re-takes this list with `findReferences` on `players` at its base. A site that writes `players` without writing the table is a bug the census can't see, so §6's tests pin it.
- **A lookup belongs to the current entry.** The table's entry for a player is the one whose generation equals `players[id]?.generation`; a lookup with no current entry finds nothing.
- **`makeContext` keeps its merge precedence** (LK:3595–3601): the land's services, then the override, then the player's, then the RNG strip. It reads the player's services from the table's current entry instead of `players[playerID]?.services`.
- **The OnLeave resolver's services:** the leave reads the outgoing entry's services from the table before it removes the entry, and hands that snapshot to the resolver context, as it does today from the entry.
- **The queued OnLeave handler looks up at apply time,** as today: it builds a fresh context when the lifecycle item applies (LK:4146). If the entry is gone, it gets the land's services. If the player has rejoined, it gets the newer entry's services. That is today's behavior through `players[id]?.services`, and the table keeps it. §6 has a test that tells the two apart.
- **K2** replaces this table with `LiveLandTurns`' table keyed by `(PlayerID, EntryID)` (parent §3.1). The census places it `outside(playerServices)` until then.

### 3.4 Exclusivity: one inout access of the model per step (S1)

- **The trap.** `model` is a stored property of an actor, so Swift enforces exclusive access to it dynamically, in release builds too (SE-0176: class and actor storage is checked at run time). Today a handler runs on `&state`, a property of its own, so the keeper can read `players` while the handler holds `state`. After the move, `&model.state` is an access to all of `model`, and any read of another model field during it traps.
- **The rule.** A step takes `inout KeeperModel` once and reaches every field through that binding (Rust's split borrows, through one `&mut`). The K1b-3 helper becomes:
  ```swift
  private func withHandlerStep<R>(_ ctx: LandContext, random: HandlerRandom = .step,
                                  _ body: (inout KeeperModel<State>, LandContext) throws -> R) rethrows -> R
  ```
  The body gets `&model` and calls the handler with `&m.state`. K1b-3's write-back becomes `defer { model.landRandom = service.generator }`: it runs after the body's access ends, so it doesn't overlap.
- **The access audit (Review and Codex, at 2afb96fc), the evidence for the rule.** There are 11 `withHandlerStep` sites. No current modify access has a closure or callee that reads another model field:
  - the queue predicates capture locals;
  - `sort` is nonmutating;
  - the subscript-default sites use constants;
  - `&applied` is a local.

  K1b-4 repeats this audit on its base for every modify access of a model field: the handler sites, the `removeAll(where:)` and `sort` calls on model collections, and every `inout` argument. The audit goes in the PR body.
- **The boundary that remains: user code re-entering the keeper synchronously.** A handler, or a service a handler calls, that captures its keeper and calls a keeper method through `assumeIsolated` reads `players` while `state` is borrowed. That works today, and traps once both live in `model`. The same holds for a hand-written `clearDirty()` (a public mutating requirement, StateNodeProtocol.swift:234; the keeper calls it at LK:1877 and 4980) that reaches back into the keeper.
  - A `swiftc -typecheck` probe of `model.items.removeAll { model.players.contains($0) }` on an actor compiles clean (Review), so the compiler won't catch it. It is a run-time trap only.
  - **The contract, stated in the docs** (`docs/core/runtime.md`, both languages; `LandContext`'s doc; and `clearDirty()`'s requirement doc at StateNodeProtocol.swift:234): a handler, and anything it calls, must not call back into its keeper synchronously. Work that needs the keeper goes through the context (emit, a sync request, a server input), which doesn't touch the model during the step.

### 3.5 Deviations from Appendix A (for Review)

- **D1: `outputCollector` stays a class until K2.** A.1 splits its plain fields (`nextSequence`, `checksOverflow`, `sequenceExhausted`, `syncRequestsByTick`) into Model. But the handler's context closures write them during the handler, while `&model` is held, so moving them now would turn every `ctx.emit` into an exclusivity trap. K2 stages outputs in the step (parent §3.6), and that is when they can move. So the collector stays on the actor as `actor.outputCollector`, placed `replaced(by: "K2")`. `KeeperModel` is `@PlainData`, and the macro checks every stored field, so a class field in the model wouldn't compile; no census exception could change that. The context closures already capture the collector before the handler borrows `state` (LK:3606).
- **D2: the replay group.** A.5's fields become one `struct ReplayFields` on the actor, non-optional, with today's defaults. The setters run on a keeper that already exists (`ReevaluationEngine`:351, `ReevaluationRunnerImpl`:350–358), and a live keeper reads the defaults today. `ReplayFields` stays non-plain: `replayPassObserver` is a closure set after init. Revisit at #612, which deletes `ReplayLandOwner` and with it this group (Q1 (c), maintainer, 2026-11-25).

## 4. The census test (`Tests/SwiftStateTreeTests/KeeperCensusTests.swift`)

### 4.1 Reading the labels on the keeper's executor (MF1)

`Mirror`'s children are lazy, and even reading a child's label loads and copies its field. So iterating `Mirror(reflecting: keeper)` from a nonisolated test races the keeper's own mutations, and the keeper starts initialization from its init (LK:1247–1257).

- **The accessor:** a synchronous, actor-isolated `package func censusLabelsForTesting() -> [String: [String]]` on the keeper. It exists in release builds too (not under `#if DEBUG`), so a release run checks that the three ring fields are absent. Inside isolation it reflects `self`, `model`, `behavior`, `behavior.config` and `replay`, materializes every label into a `[String]`, and returns only those arrays, keyed by storage path (`"actor"`, `"model"`, `"behavior"`, `"behavior.config"`, `"replay"`). It never returns a `Mirror` or its children, which would defer the reads past the isolation.
- **The label rules:**
  - `$defaultActor`, the actor's synthetic storage label, is allowed by name and nothing else synthetic is;
  - a lazy field's label is `$__lazy_storage_$_x` and a wrapped field's is `_x`; the table names them that way;
  - an unnamed label (`nil`), an unknown label, or a label that appears twice fails the test;
  - the three DEBUG-only ring fields are rows under `#if DEBUG` in the table, so a release run expects them absent.
- **Matching by storage path.** The table's key is the path, not the bare name: `"model.players"`, `"behavior.config.mode"`, `"replay.replayPassObserver"`, `"actor.playerServices"`. So a stray field inside `ReplayFields` or `KeeperConfig` fails too.
- **The manifest matches what the accessor reflects.** The containers have rows of their own (`actor.model`, `actor.behavior`, `actor.replay`, `behavior.config`), and so do K1b-2's tables, by the labels they have on the base.

### 4.2 What fails

- a stored label with no row (a new field must be placed);
- a row with no stored label (a stale row);
- a label in two paths.

### 4.3 The known exceptions, each with the slice that ends it

- F4's `Instant`s, Outside: `nextTickDeadline`, `pendingFold`, `tickLoopConfiguredAt`, `tickLoopClock` (K2, #759's clock). `runTickTurn` still reads the clock inside the turn, through `takePendingFold` (LK:5043). K2 moves that read out, with the deadline, when the loop driver passes the time in as the turn's input.
- S3's non-turn writer: `runSync` writes `model.foldedSyncs`, `model.overdueFoldedSyncs` and `model.inTurnSyncDue` outside a turn (F8; K2's `.syncDue` step).

The test checks that each exception's fields still exist at the paths it names, so the list can't go stale.

### 4.4 What it doesn't check

- **Writers (F6, F7).** `Mirror` sees fields, not writers. The turn-shaped entries and the post-await writers are K1b-5's lists.
- **The side tables' key sets** (S4) are K1b-2's assertion; the census suite runs it over a job's whole life (§6, M-5).
- **The player-services table's consistency** with `players`: §6's tests.

### 4.5 The plain pin

- **A compile-time use in the test target:** `func _requirePlain<T: PlainData>(_: T.Type) {}` called with `KeeperModel<CensusState>.self`. If the real model loses `@PlainData`, or a field stops being plain, the test target doesn't build.
- **Must-not-compile** (CI runs it; the Mac doesn't): `scripts/must-not-compile/keeper-model-not-plain.swift`, a `@PlainData` struct shaped like `KeeperModel` holding an `AnyCodable`. It expects the PlainData diagnostic, with the text taken from P4-1's snippets.

## 5. How the change is made

The change is mechanical but wide: 128 fields and thousands of references in a 6,300-line file. Commits:
1. **The types; the moved nested types; the plain conformances** (§3.1's table). Builds with nothing using them.
2. **Behavior's `let`s and `KeeperConfig`.** Read-only, so a pure rename; `definition` becomes the computed accessor.
3. **Model's fields in groups,** each group building green: counters and flags; queues; the bindings; the player table with `playerServices` (§3.3); the RNG; `state` last.
   - Use the LSP's `findReferences` per field and a script that prefixes `model.` at exactly those references. No textual replace: names like `state` and `players` also appear as locals and parameters.
   - The access audit (§3.4) runs after each group.
4. **The replay group.**
5. **The census test, the plain pin, the snippet and the docs** (§3.4's contract).

Each commit runs the touched suites. The full debug `swift test` runs before the push.

## 6. Tests and mutants

**New tests besides the census:**
- **The player-services table:**
  - a join with player services, then an action: the handler's context sees the player's service;
  - a leave with an OnLeave resolver: the resolver sees the outgoing services;
  - a rejoin with a newer generation, then the older join's rollback: the newer entry keeps its services;
  - a land stop: the table is empty after it, as `players` is;
  - the resolver snapshot against the queued handler's lookup: a player with services leaves through an OnLeave resolver and rejoins with other services before the queued OnLeave applies. The resolver sees the outgoing services; the queued handler sees the newer entry's.
- **The re-entry contract:** a DEBUG-only test whose handler calls back into the keeper synchronously can't be a normal test (it traps). It is a cloud-only, single-case process, like K1b-2's trap tests. The positive side: every handler kind runs under a debug build in the existing suites, which have dynamic enforcement.

**Mutants (cloud worker).** Each names the fixture it needs, so it compiles and fails at run time for the stated reason.

| # | Mutant | Fixture | Killed by |
|---|---|---|---|
| M-1 | a new stored field, unused, on the actor (`private var censusProbe = 0`) | none | census: unplaced label |
| M-2 | a field renamed at every reference, its row left under the old name | `lateFoldedSyncs` → `lateFoldedSyncsRenamed`, in `LandKeeper.swift` and in `InTurnSyncFoldReportTests` (an internal field with no public accessor) | census: stale row (and the new name unplaced) |
| M-3 | `@PlainData` removed from `KeeperModel` | none | the test target doesn't build (`_requirePlain`) |
| M-4 | one handler site reads `model.players` inside the step's access | an action handler in a test land, run through the `withHandlerStep` call in the action apply path; the mutant reads `model.players.count` in the body closure after `&m.state` is passed | a trap: **cloud only, one test case per process** (the K1b-2 lesson: a trap kills the whole test process). The structural check is the audit in the PR body |
| M-5 | S4's side-table removal skipped | K1b-2's job-life run | census suite: the key sets are checked after the abandoned resolver finishes and its job is removed (at abandonment the job deliberately stays). The job pair and the slot pair are checked separately, because a slot can outlive its job |
| M-6 | the resolver-error rollback (LK:6212–6216) removes `players` but not `playerServices` | a join whose OnJoin resolver throws | the rollback test: right after the matching-generation removal, the table's keys and generations equal `players`' (the newer-generation test skips this removal, and the live shutdown and failure paths clear the table anyway, so neither can kill it) |
| M-7 | `makeContext` reads the land's services after the player's (precedence swapped) | one ordinary service type registered with different values at land scope and at player scope (the RNG test strips its key, so it can't tell the orders apart) | a handler that reads the service sees the player's value |

## 7. Behavior and performance

- **No behavior change.** Goldens, the differential harness and replay stay byte-identical.
- **Performance is measured, not claimed** (S4). A read through `model` is the same field load. But a modify access now covers the whole model, and the dynamic exclusivity checks may change in number or cost. The small A/B:
  - **cells:**
    - `rows-mp`, which is also the production default: hero-defense, MessagePack with path hashes, row addressing, joined through the router (`--rooms 1 --players-per-room 5 --monster-cap 100 --ticks-per-sync 2 --iterations 47200`). Both cells Review names are this one line;
    - `wide-tickless-mp` (`visibility-test-tickless`, `--rooms 10 --inputs-from-wire --actions-per-player 4 --wide-response --iterations 3000`), a tickless action cell that samples the queue and outcome writes, which `rows-mp` (tick only, no inputs) doesn't reach;
  - **windows:** #517's. `instructions:u` in the `nonsync` window is judged by max(0.5 %, 3 × base's spread). The sync window (`iteration` minus `nonsync`) is reported separately. Time is reported only;
  - **base:** K1b-4's merge base; **head:** the PR.

## 8. Public API

**Additive conformances** (public types gaining `PlainData`; Main-approved under the standing rule, listed in the PR's Public API section):
- `Epoch: PlainData`;
- `EpochCounter: PlainData`;
- `ReevaluationRecordedSyncOutput.TurnKind: PlainData`.

**Unchanged:** `LandKeeper`'s public members keep their signatures. `definition` and `serverInputCapRejections` become computed over the new homes, with the same type and access. `LandConfig` doesn't change (§3.2). Every new type is internal.

**K1b-1's source break is K1b-1's.** K1b-Q5 (d) makes `PendingActionItem` and `PendingClientEventItem`, with their inits, `package`. That break is owned by K1b-1: the parent plan's public-API row, and F9's public-init fallback. K1b-4 rebases on the landed types and regenerates its references and its census then.

## 9. Rev 1 → rev 1.1

| Change | Where |
|---|---|
| Review's early read: the one-inout rule, D1 and D2 fine | §3.4, §3.5 |
| D2: non-optional with defaults; `replayPassObserver` stays off Behavior (Review's nit, declined and agreed), revisit at #612 | §3.5 |
| K1b-3 rev 2.1's helper (`random:`), with the write-back in `defer` after the model access | §3.4 |
| K2 survey: K1b-5's bodies as `mutating` methods on `KeeperModel` | §1 |

## 10. Rev 1.1 → rev 1.2

| Change | Where |
|---|---|
| F8: the loops' phase offsets are Outside (checked with `findReferences` first); `runSync`'s fold writes are S3's named exception until K2 | §2, §4.3 |
| K1b-3: `landRandom` is Model, `landRandomSeed` is Behavior, the `withMutableStateSync` test-hook row goes | §2 |
| F6 and F7 are K1b-5's writer lists; the census test checks homes, not writers | §4.4 |
| F5 (K1-Q7 (d)) is K1b-1's: the held resolver output is plain bytes before K1b-4 moves `pendingItems` | (no change) |

## 11. Rev 1.2 → rev 2 (Review's NOT GO at 7baba4c4)

| Finding | Answer | Where |
|---|---|---|
| MF1: the census must read on the keeper's executor | an actor-isolated `censusLabelsForTesting()` that returns label arrays by storage path; the label rules (`$defaultActor`, lazy and wrapped storage, unnamed, unknown and duplicate labels, DEBUG rows) | §4.1, §4.2 |
| MF2: a home for the player services; the model's conformances | the `playerServices` table, written at every insert and remove site, `makeContext`'s precedence kept, OnLeave's snapshot kept; the conformance table with each type's visibility; the nested types moved out | §3.1, §3.3 |
| MF3: `LandConfig` is public | an internal `KeeperConfig` in Behavior; the LSP check; `resolverServices` stays optional; the server-input cap stays Outside | §3.2 |
| S1: the full access audit | the audit as evidence, repeated on the base per modify access; the re-entry boundary and its docs contract | §3.4 |
| S2: mutants that compile | fixtures named; M-3 by a compile-time use; M-4 cloud-only, one case per process; M-5 checked after the job's removal, job and slot pairs separately; M-6, M-7 added | §4.5, §6 |
| S3: the destination inventory | 126 → 128 (125 without DEBUG); the full post-split list with paths; `pendingFold` wholly Outside | §2 |
| S4: measure, don't claim | `rows-mp` (the production default) and the tickless action cell `wide-tickless-mp`, #517's windows and rule, sync reported apart | §7 |
| S5: K1b-1's source break | owned by K1b-1; K1b-4 rebases and regenerates | §8 |
| Nit: counts and #853's status | "126 at 5baa1887, 128 at #853's reviewed head" | Status, §2 |

## 12. Rev 2 → rev 2.1 (Review on rev 2: 1 must-fix, 4 should, 1 nit)

| Finding | Answer | Where |
|---|---|---|
| MF1: `outputCollector` was back in Model, which the `@PlainData` macro refuses | on the actor, `actor.outputCollector`, replaced in K2; dropped from the model row and §4.3 | §2, §3.5, §4.3 |
| S1: the manifest matches the accessor | container rows and K1b-2's table rows; the accessor exists in release | §2, §4.1 |
| S2: the site list and the queued OnLeave | 2 inserts, 3 rollbacks (6212–6216 moved there), 1 removal, 4 clears (4146 dropped; 4049 live only); lookups by the current generation; the queued handler's apply-time lookup kept, with a test | §3.3, §6 |
| S3: M-6, M-7 and M-4 fixtures | M-6 on the resolver-error rollback, asserted right after the removal; M-7 with one ordinary service at two scopes; M-4's handler named | §6 |
| S4: conformance details | `@PlainData` on `Ticket`'s and `GenerationTable`'s definitions; `InternalPlayerSession` is file-level private; tests' internal getters; `clearDirty`'s contract on its requirement, first site LK:1877; `takePendingFold`'s clock read moves in K2 | §3.1, §3.4, §4.3 |
| Nit: `resolverServices == nil`; the parent's public-API row | nil means declared and not given (a land that declares none gets `NoServices()`, LK:1177); the parent's K1b row now points at K1b-Q5 (d) | §3.2; parent §8 |

## 13. Rev 2.1 → rev 2.2 (implementation prep, after GO)

| Change | Where |
|---|---|
| `syncOutputIndexCursor` is a tuple, which `@PlainData` refuses; it becomes an internal `@PlainData` struct with the same labels. A scan of the other model fields' types at #853's head found no other refusal: `Set`, `Dictionary`, `Array`, `Optional` and `Result` conform when their elements do, and the `any Error` in `inputTurnResults` and `initializationFailure` is K1b-2's to replace (`FailureID`) | §3.1 |
| The model row counts 58 fields (55, plus the 3 DEBUG-only ring fields); "59" counted the word `services` in "`players` (without `services`)" | §2 |
