# Two-phase handlers: validate, then apply (#586, minimal)

Status: open (rev 5, 2026-11-18: GO on rev 4, with its should and nits folded in). Issue: #586. Replaces #535 PR 4 (#585, parked) as the fix for #87: a handler can no longer write and then throw, because the closure that writes can't throw.

## Decision (maintainer, 2026-11-18)

- #586's minimal version comes before #585. The project is pre-release, so the source break is direct, with no deprecation step.
- With no counted handler able to throw after a write, #585's write mark has nothing to detect. #585 stays a draft as the fallback.

## Scope

### 1. The DSL

| Entry point | Today | After |
|---|---|---|
| `HandleAction(A.self) { state, action, ctx in ... }` (no resolvers, `resolvers: R1.self`, `resolvers: (R1, R2)`) | body `throws -> some Codable & Sendable` | body non-throwing |
| `HandleAction(A.self, [resolvers:], validate:, apply:)` | none | new, for each resolver arity: `validate: (State, A, ValidateContext) throws -> Plan`, `apply: (inout State, A, Plan, LandContext) -> A.Response` |
| the same with a `Void` plan | none | new, for each resolver arity: `validate: (State, A, ValidateContext) throws -> Void`, `apply: (inout State, A, LandContext) -> A.Response` |
| `HandleEvent(E.self) { ... }` | body `throws -> Void` | body non-throwing, plus `validate:`/`apply:` (Plan and Void forms; events take no resolvers) |
| `HandleServerInput(I.self) { ... }` | body `throws -> Void` | body non-throwing, plus `validate:`/`apply:` (Plan and Void forms) |
| `OnJoin` / `OnLeave` (each with 0–3 resolvers) | body `throws -> Void` | body non-throwing. `CanJoin` stays the join check. |
| `OnInitialize`, `OnFinalize`, `Tick`, `DestroyWhenEmpty` | throwing | unchanged: not inputs, and outside the guarantee (OnInitialize keeps its own failure path) |

- `validate` and `apply` sit in one call, so Swift infers `Plan` from `validate`'s return type.
- They run back to back in the same synchronous turn segment, so nothing runs between the check and the write.
- **Return type (Main, 2026-11-18): closes #561.** Every action body and `apply` returns `A.Response`, not `some Codable & Sendable`, so a handler can't return a type other than its declared response. A compile test checks that a wrong response type doesn't compile.
- **Erased shapes (S2).**
  - `AnyActionHandler` and `AnyClientEventHandler` keep their throwing invoke as a non-public (`package`) stored closure, used for the payload type check and for `validate`.
  - Their public inits take the two stages: a throwing `validate` that returns the plan, and a non-throwing `apply`.
  - The DSL's single-closure form doesn't go through that init. It builds the `package` invoke directly around the body, so the hot path is one closure call, as today (§9). Only the public init is two-stage.
  - No public init that takes a throwing body remains, since it would be an escape hatch around the rule.
  - `AnyServerInputHandler`'s init is already internal and stays so.
- **One handler per client-event type and per server-input type (M1, maintainer, 2026-11-18: (a)).** Today the keeper runs several handlers for one type in sequence in one input (`LandKeeper.swift:3538-3541`, `3568-3573`). Handler 1's `apply`, then handler 2's `validate` throw, would still be a half-write. So a land may declare only one handler per type, and an input is exactly one `validate` plus one `apply`, as for actions.
  - **Storage.** `LandBuilder` keeps the first handler per type and records the later ones as duplicates. `LandDefinition` holds one handler per type: `eventHandlers` becomes keyed by type, and `serverInputHandlers` maps to a single handler.
  - **Refusal.** `validateForRegistration` refuses a land with duplicates, beside the other #535 checks, through a new `duplicateHandlers` part of `LandRegistrationError`. It names the type and both declaration sites: `HandleEvent` and `HandleServerInput` gain defaulted `fileID:`/`line:` parameters (additive), stored in the erased handler.
  - **The keeper.** The per-type loops in `applyPendingItem` become one call.
  - **Every entry point.** A keeper built without registration is covered too: the #535 backstop in `performInitialization` (`LandKeeper.swift` ~1004), which today checks only `SyncRegistration.cachedProblems`, also checks the definition's duplicate list. On duplicates it tears the land down with the same `duplicateHandlers` error, so a directly built keeper never silently drops a handler. Registration, replay (`ReevaluationEngine.swift:211`) and SchemaGen already call `validateForRegistration`.
  - **Inventory.** The examples have one handler per event type. Test files that declare `HandleEvent` or `HandleServerInput` for one type more than once (per file; the build and the refusal show which are in one land):
    - `ActionEventSyncTests`, `LandDSLTests`, `LandKeeperClientEventQueueTests`, `ServerInputTests` (events and server inputs), `SyncTablesLandCellTests`, `ThrowingInputWriteWarningTests` (deleted), `TicklessReplayPassTests`;
    - `PerPlayerSyncTablesScenarioTests`, `TransportAdapterOpcode107Tests`.

    The ones that are one land get their handlers merged, or the test moves to what it meant to test; the PR lists each.
  - **Tests:** a land with two handlers for one event type is refused, and so is one for a server-input type, with the type and both sites in the error.

### 2. `ValidateContext` and `ReadOnlyLandService`

- `public struct ValidateContext`, `@dynamicMemberLookup`. It wraps the input's `LandContext` privately, so building one is a stored copy and adds no allocation.
- Exposed: `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`, `isGuest`, `metadata`, `tickId`, `playerSlot`, `logger`, and the resolver outputs through the same `subscript(dynamicMember:)` as `LandContext`.
- `services` is a `ReadOnlyLandServices` view whose `get<S: ReadOnlyLandService>(_:)` only accepts conforming types.
- Not exposed: `emitEvent`, `emitAnyServerEvent`, `requestSyncNow`, `requestSyncBroadcastOnly`, `serverInputs`, `random`, scheduling.
- `public protocol ReadOnlyLandService: Sendable {}` is a marker, and a trust contract the compiler can't check. Its doc states the promise: the service only reads, and the same inputs give the same answer, because replay runs `validate` again. A read that isn't deterministic (a clock, a remote call) belongs in a resolver, whose output is recorded.
- A service registered under an existential type (`services.register(x, as: (any P).self)`) can't be fetched through `get<S: ReadOnlyLandService>`, because an existential doesn't conform to the marker. Register it under a concrete type to use it from `validate`; the docs say so.

### 3. Errors

- **Actions:** a `validate` throw takes today's handler-throw path (`ACTION_HANDLER_ERROR` with the `requestID`); the input fails alone with nothing written. A tick land keeps its intake ACK; the error doesn't reach the caller (unchanged).
- **Client events:** a `validate` throw goes where an event throw goes today: the `ErrorPayload` to the client and the fail-alone log.
- **Server inputs:** a `validate` throw is logged, and the input fails alone.
- **`try!` in `apply`** crashes the process. That's explicit, and the docs name it with the other non-compiler-enforced cases from #586: a swallowing `do/catch`, and side effects in `validate` through globals or captured references.

### 4. Replay

- Replay applies the recorded inputs, so `validate` runs again. It must be deterministic: the same state and payload give the same plan or the same error.
- **There is no rejected/applied marker in the record today.** `ReevaluationRecordedPass.inputs` lists every input the pass applied, failed ones included. A divergence shows up only as a state hash or server event mismatch at the tick. A `validate` that rejects live and passes in replay (or the reverse) is missed when `apply` writes nothing the hash covers.
- **The marker (D1, approved).** Record format 3.5 carries the rejected sequences: the inputs whose handler threw (`validate`, or the payload type check).
  - **Tickless lands:** `rejected: [Int64]?` on `ReevaluationRecordedPass`, as a subset of that pass's `inputs`.
  - **Tick lands (M3):** `ReevaluationTickFrame.passes` is empty there (`ActionRecorder.swift:477`). The frame itself carries `rejected: [Int64]?`, a subset of the inputs it applied before the tick handler.
- **Nil (M2).** Nil means "nothing rejected" from 3.5 on, and is written that way (the field is omitted when empty, so there's no append on success). Comparison is gated on the record version, the way the 3.4 ordinal check is (`replayRecordsPassOrdinals`, `LandKeeper.swift:3992`):
  - a 3.5 record's nil is `[]` and is compared;
  - an older record's nil isn't compared.
- **Checks.** On a 3.5 record, each listed sequence must be in the pass's or the frame's inputs and appear once; otherwise the record is malformed, reported as a mismatch.
- **Compare.** Replay collects the sequences that throw and compares them with the recorded set. A difference goes into `recordedPassMismatches[tickId]` ("input <seq> was rejected live and applied in replay", or the reverse) on both land kinds, through the verdict path a pass mismatch already takes on each.
- **Tests (D1), each on a tickless and a tick land** (the #563 class, `Notes/solutions/2026-11-14-a-verdict-never-checked-on-one-land-kind`):
  - rejected live and applied in replay, and the reverse, are reported with their sequence and tick;
  - a malformed list (an unknown or duplicate sequence) is reported;
  - a 3.4 record replays clean.
- **Validate's state (S4).** `validate` reads the existing `inout` binding inside the same `withMutableStateSync`. It gets a borrow, not a copy: no copy-on-write and no snapshot.

### 5. Removed as dead

- The debug write-then-throw warning: `Sources/SwiftStateTree/Runtime/ThrowingInputWriteCheck.swift` (`warnIfThrowWrote`), the `DEBUG_WARN_THROWING_INPUT_WRITES` key in `EnvKeys.swift`, `setWarnsThrowingInputWritesForTesting`, the `throwWriteInput:` parameter of `withMutableStateSync` and its call sites, `Tests/SwiftStateTreeTests/ThrowingInputWriteWarningTests.swift`, and its paragraphs in `docs/core/runtime.md` (en/zh). `validate` gets a `let` state, so there's nothing to warn about.
- **The in-turn join and leave failure (S1), removed structurally.**
  - The lifecycle item's apply becomes a non-throwing function that calls the non-throwing OnJoin or OnLeave, outside `applyInputs`' shared `catch`.
  - The `isJoin` failure branch in that `catch` (`LandKeeper.swift:3921-3926`: the failed `JoinInputResult` and `discardIfFailedJoin`) is then deleted, and so is the OnLeave failure log.
  - **`JoinInputResult.failed`:** removed (public break, §8). An applied join input can no longer fail, so `noteJoinInputsConsumed` reports only sequences.
  - In `TransportAdapter`, the `inTurn.failed` flag (`TransportAdapter.swift:2064`) and the `joinFailed:` path of `deferInbound` (`:2597`) go with it.
  - Join rejections from resolvers and from `CanJoin` stay; they happen before the input is queued.
- Doc text that says "a handler that throws keeps what it wrote before the throw" (the `HandleAction`/`HandleEvent` docs, `runtime.md`, `land-dsl.md`, `failure-handling.md`).

### 6. Migration

From a scan of handler bodies that contain `throw`, or a `try` that isn't `try?`, `try!` or `try await`; the build confirms the final list:

- Tests:
  - `PerSequenceResultTests` (an action, OnLeave)
  - `ServerInputTests` (a server input)
  - `ThrowingInputWriteWarningTests` (deleted, §5)
  - `LandKeeperInputTurnTests` (an action, an event)
  - `LandRouterTests` (OnJoin)
  - `TransportAdapterJoinFlipTests` (two OnJoin)
  - `TransportAdapterJoiningAdmissionTests` (three OnJoin)
- The OnJoin tests use a throwing OnJoin to reject a join in the turn. They move to `CanJoin` returning `.deny` or throwing, or, where the test is about the in-turn join failure itself, the case is deleted with that path (§5).
- Tests that only call a handler node's closure with `try` get a warning, not an error, and are cleaned up in the same pass.
- Main's count was 18 files. The scan finds 7 test files plus the 2 example lands; any further files the build turns up get listed in the PR.
- **`VisibilityTestLand` `PlaceEntityAction`** (also fixes the latent write-then-throw Main found):
  ```swift
  HandleAction(PlaceEntityAction.self,
      validate: { (state: State, action: PlaceEntityAction, _: ValidateContext) in
          // Before the lazy spawn, the ids are the ones it will create.
          let known = state.entities.isEmpty
              ? VisibilityTest.isSpawnedEntityID(action.id, settings: settings)  // "e<i>", i < entityCount
              : state.entities[action.id] != nil
          guard known else { throw VisibilityTestError.unknownEntity(action.id) }
      },
      apply: { (state: inout State, action: PlaceEntityAction, _: LandContext) in
          spawnEntitiesIfNeeded(&state, settings: settings)
          for position in action.positions {
              state.entities[action.id]?.position = position
              updateVisibility(&state, settings: settings)
          }
          return VisibilityTestResponse(viewEntries: state.viewEntries, viewExits: state.viewExits)
      })
  ```
  - The empty-entities check parses `e<i>` (no set is built), so the steady-state path does one dictionary lookup, as today.
  - New test: an unknown id on a fresh land is rejected alone, nothing is spawned, the land stays open, and a later valid placement applies.
- **`ResolverTestLand` `CallServiceAction`:** the "resolver output missing" guard moves to `validate`, which returns the `ServiceCall` as the plan; `apply` writes from the plan.
- The other example lands (Demo Cookie/Counter, CardGame, HeroDefense) don't throw in handlers; they only recompile.

### 7. Docs (en and zh-TW)

- `docs/core/land-dsl.md`: the signatures, the `validate`/`apply` section with the resolve/validate/apply table from #586, `ValidateContext`, `ReadOnlyLandService`, and the cases the compiler can't stop.
- `docs/core/runtime.md`, Inputs and Turns: a handler can't throw after a write. A `validate` throw fails the input alone with nothing written. The debug warning paragraph is removed.
- `docs/core/failure-handling.md`: the #87 row becomes "impossible by type (#586)".
- `docs/core/land-dsl.md` and `docs/core/failure-handling.md`: the D2 interim note. `CanJoin` runs at join intake and `OnJoin` in a later turn, so a state-dependent check in `CanJoin` can be stale; `OnJoin` handles a misfit joiner; `maxPlayers` is unaffected; links #588.
- `docs/core/reevaluation.md`: `validate` reruns and must be deterministic; the rejected marker (D1).
- `Notes/plans/2026-11-13-sync-failure-ends-unit.md`: a status note that #87 is closed by #586's types instead of PR 4; §3.7 and D5 (a) are superseded. Its row in `Notes/plans/README.md` is updated in the same commit.

### 8. Public API (source breaks; direction approved by the maintainer 2026-11-18)

- **Breaks:**
  - The non-throwing body for `HandleAction` (3 overloads), `HandleEvent`, `HandleServerInput`, `OnJoin` (4), `OnLeave` (4).
  - The handler types of `OnJoinNode`/`OnLeaveNode`.
  - The public inits of `AnyActionHandler`/`AnyClientEventHandler`: two-stage, with no throwing-body init left (§1). `AnyServerInputHandler`'s init is internal: no public change.
  - An action body and `apply` return `A.Response` instead of `some Codable & Sendable` (closes #561).
  - `JoinInputResult.failed` and the `failed:` init parameter are removed (§5).
  - **Behavior:** a land that declares two handlers for one client-event or server-input type is refused at registration (M1). `LandDefinition.eventHandlers` changes shape.
  - A body that throws, or calls a throwing function with `try`, stops compiling.
  - The `DEBUG_WARN_THROWING_INPUT_WRITES` env var is removed.
- **Additions:**
  - `HandleAction(_:resolvers:validate:apply:)`: 3 arities × Plan/Void = 6 overloads.
  - `HandleEvent(_:validate:apply:)` and `HandleServerInput(_:validate:apply:)`: 2 overloads each.
  - `ValidateContext`, `ReadOnlyLandService`, `ReadOnlyLandServices`.
  - `LandRegistrationError.duplicateHandlers`, and defaulted `fileID:`/`line:` on `HandleEvent`/`HandleServerInput`.
- **Record:** format 3.5's optional `rejected` on the pass and on the tick frame (D1). An older record replays as before, without the comparison.
- **Wire, schema and client SDK:** unchanged.

### 9. Measured path and A/B

- The success path of an action or event changes:
  - The single-closure form calls the body directly, as today (only `throws` is gone).
  - The split form adds a second closure call, the plan's pass, and a `ValidateContext` built from the `LandContext`.
  - Server inputs aren't in the benchmark cells.
- Cells touched:
  - `vis-actions`: an action per player per iteration, through `PlaceEntityAction`'s new split form.
  - `cap100-moves`: a client event per player per iteration, through HeroDefense's single-closure `HandleEvent`, now non-throwing.
  - Controls: `vis-tick`, `cap100-events`, `cap100-noevents`.
  - The ab-568/ab-585 five-cell set fits.
- The A/B runs after review, on the PR head, before merge.

## Open for Main and the maintainer

- **D1: decided (maintainer, 2026-11-18): the rejected marker.** Record format 3.5, an optional `rejected` on the pass, compared in replay; an older record (nil) isn't compared. Tests:
  - a `validate` divergence (rejected live, applied in replay, and the reverse) is reported with its sequence and tick;
  - a 3.4 record still replays clean.
- **D2: decided (maintainer, 2026-11-18): (a).** `OnJoin` becomes non-throwing, and the `CanJoin` staleness is accepted and documented in `land-dsl.md` and `failure-handling.md` (en/zh), with an interim note linking #588.
  - A check that depends on changing state doesn't belong in `CanJoin`. `OnJoin` handles a misfit joiner itself: it makes them a spectator, or emits an event asking them to leave.
  - `LandConfig.maxPlayers` is checked in the segment of the insert, after the last await (`LandKeeper.swift:1650`). Pending joiners count, because `players` is inserted at intake (`LandKeeper.swift:1685`). So a plain player cap is unaffected.
  - The in-turn join validate is tracked as #588, for the turn core's join move.
- **D3: decided (Main, 2026-11-18):** no `rethrows`-style escape hatch. The single-closure body is non-throwing.

## PRs

One PR, with commits split by kind:
1. Sources and Tests: DSL, `ValidateContext`, keeper/record (D1), removals, test migration.
2. Examples: the two example lands, the VisibilityTestLand test, and the remaining recompiles.
3. Docs (en/zh), plus the #535 plan note and the index row.

Verification:
- `swift test` on both `IN_TURN_SYNC` settings, and GameDemo `swift test`.
- Compile tests:
  - each `HandleAction` arity × Plan/Void, and the `HandleEvent`/`HandleServerInput` forms;
  - a throw-only `validate` (returns Void);
  - multi-statement `validate` and `apply` closures (the inference of `Plan`);
  - must-not-compile checks for a throw in `apply` or in a single-closure body, and for a wrong response type (#561).
    - The repo has no style for this yet, so it's a new script, `scripts/check-must-not-compile.sh`. It runs `swiftc -typecheck` on each snippet in `scripts/must-not-compile/` against the built debug modules and expects the diagnostic named in the snippet's header.
    - A new CI step runs it after the build; shellcheck covers the script.
- Mutants:
  - `validate`'s error not routed (an input applied after a rejection);
  - `apply` running after a rejection;
  - the rejected marker not compared in replay;
  - VisibilityTestLand's fresh-land check removed.
- A release build of EncodingBenchmark, then the A/B (§9).
