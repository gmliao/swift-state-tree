# Two-phase handlers: validate, then apply (#586, minimal)

Status: open (rev 1, 2026-11-18). Issue: #586. Replaces #535 PR 4 (#585, parked) as the fix for #87: a handler can no longer write and then throw, because the closure that writes can't throw.

## Decision (maintainer, 2026-11-18)

- #586's minimal version comes before #585. The project is pre-release, so the source break is direct, with no deprecation step.
- With no counted handler able to throw after a write, #585's write mark has nothing to detect. #585 stays a draft as the fallback.

## Scope

### 1. The DSL

| Entry point | Today | After |
|---|---|---|
| `HandleAction(A.self) { state, action, ctx in ... }` (no resolvers, `resolvers: R1.self`, `resolvers: (R1, R2)`) | body `throws -> some Codable & Sendable` | body non-throwing |
| `HandleAction(A.self, [resolvers:], validate:, apply:)` | none | new, for each resolver arity: `validate: (State, A, ValidateContext) throws -> Plan`, `apply: (inout State, A, Plan, LandContext) -> Response` |
| the same with a `Void` plan | none | new, for each resolver arity: `validate: (State, A, ValidateContext) throws -> Void`, `apply: (inout State, A, LandContext) -> Response` |
| `HandleEvent(E.self) { ... }` | body `throws -> Void` | body non-throwing, plus `validate:`/`apply:` (Plan and Void forms; events take no resolvers) |
| `HandleServerInput(I.self) { ... }` | body `throws -> Void` | body non-throwing, plus `validate:`/`apply:` (Plan and Void forms) |
| `OnJoin` / `OnLeave` (each with 0–3 resolvers) | body `throws -> Void` | body non-throwing. `CanJoin` stays the join check. |
| `OnInitialize`, `OnFinalize`, `Tick`, `DestroyWhenEmpty` | throwing | unchanged: not inputs |

- `validate` and `apply` sit in one call, so Swift infers `Plan` from `validate`'s return type.
- They run back to back in the same synchronous turn segment, so nothing runs between the check and the write.
- The type-erased handlers (`AnyActionHandler`, `AnyClientEventHandler`, `AnyServerInputHandler`) keep a throwing invoke internally, used for the payload type check and for `validate`. Their public `init(handler:)` now takes the non-throwing body.

### 2. `ValidateContext` and `ReadOnlyLandService`

- `public struct ValidateContext`, `@dynamicMemberLookup`. It wraps the input's `LandContext` privately, so building one is a stored copy and adds no allocation.
- Exposed: `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`, `isGuest`, `metadata`, `tickId`, `playerSlot`, `logger`, and the resolver outputs through the same `subscript(dynamicMember:)` as `LandContext`.
- `services` is a `ReadOnlyLandServices` view whose `get<S: ReadOnlyLandService>(_:)` only accepts conforming types.
- Not exposed: `emitEvent`, `serverInputs`, `random`, scheduling.
- `public protocol ReadOnlyLandService: Sendable {}` is a marker. Its doc states the promise: the service only reads, and the same inputs give the same answer, because replay runs `validate` again.

### 3. Errors

- **Actions:** a `validate` throw takes today's handler-throw path (`ACTION_HANDLER_ERROR` with the `requestID`); the input fails alone with nothing written. A tick land keeps its intake ACK; the error doesn't reach the caller (unchanged).
- **Client events:** a `validate` throw goes where an event throw goes today: the `ErrorPayload` to the client and the fail-alone log.
- **Server inputs:** a `validate` throw is logged, and the input fails alone.
- **`try!` in `apply`** crashes the process. That's explicit, and the docs name it with the other non-compiler-enforced cases from #586: a swallowing `do/catch`, and side effects in `validate` through globals or captured references.

### 4. Replay

- Replay applies the recorded inputs, so `validate` runs again. It must be deterministic: the same state and payload give the same plan or the same error.
- **There is no rejected/applied marker in the record today.** `ReevaluationRecordedPass.inputs` lists every input the pass applied, failed ones included. A divergence shows up only as a state hash or server event mismatch at the tick. A `validate` that rejects live and passes in replay (or the reverse) is missed when `apply` writes nothing the hash covers.
- **Proposal (D1):** record format 3.5 adds `rejected: [Int64]?` to `ReevaluationRecordedPass`: the sequences in `inputs` whose handler threw (validate, or the payload type check). The field is additive and optional, and an older record decodes it as nil.
  - `replayRecordedPasses` collects the sequences that throw in replay and compares them with the recorded set. A difference goes into `recordedPassMismatches[tickId]` ("input <seq> was rejected live and applied in replay", or the reverse), with the same verdict path as a pass mismatch.
  - A nil field (older record) isn't compared.
  - Cost: one append per rejected input, nothing on the success path.

### 5. Removed as dead

- The debug write-then-throw warning: `Sources/SwiftStateTree/Runtime/ThrowingInputWriteCheck.swift` (`warnIfThrowWrote`), the `DEBUG_WARN_THROWING_INPUT_WRITES` key in `EnvKeys.swift`, `setWarnsThrowingInputWritesForTesting`, the `throwWriteInput:` parameter of `withMutableStateSync` and its call sites, `Tests/SwiftStateTreeTests/ThrowingInputWriteWarningTests.swift`, and its paragraphs in `docs/core/runtime.md` (en/zh). `validate` gets a `let` state, so there's nothing to warn about.
- The in-turn OnJoin and OnLeave failure handling: the join input's failure branch (`discardIfFailedJoin` for a handler throw, a `JoinInputResult` with `failed: true` from the handler) and the OnLeave failure log. Each is removed only where the compiler confirms it's unreachable: a `try` over a non-throwing call warns. Join rejections from resolvers and from `CanJoin` stay.
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
- `docs/core/reevaluation.md`: `validate` reruns and must be deterministic; the rejected marker (D1).
- `Notes/plans/2026-11-13-sync-failure-ends-unit.md`: a status note that #87 is closed by #586's types instead of PR 4; §3.7 and D5 (a) are superseded. Its row in `Notes/plans/README.md` is updated in the same commit.

### 8. Public API (source breaks; direction approved by the maintainer 2026-11-18)

- **Breaks:**
  - The non-throwing body for `HandleAction` (3 overloads), `HandleEvent`, `HandleServerInput`, `OnJoin` (4), `OnLeave` (4).
  - The handler types of `OnJoinNode`/`OnLeaveNode`.
  - The public inits of `AnyActionHandler`/`AnyClientEventHandler`/`AnyServerInputHandler`.
  - A body that throws, or calls a throwing function with `try`, stops compiling.
  - The `DEBUG_WARN_THROWING_INPUT_WRITES` env var is removed.
- **Additions:**
  - `HandleAction(_:resolvers:validate:apply:)`: 3 arities × Plan/Void = 6 overloads.
  - `HandleEvent(_:validate:apply:)` and `HandleServerInput(_:validate:apply:)`: 2 overloads each.
  - `ValidateContext`, `ReadOnlyLandService`, `ReadOnlyLandServices`.
- **Record:** format 3.5's optional `rejected` (D1). An older record replays as before, without the comparison.
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

- **D1:** the rejected marker in record format 3.5 (§4), or rely on the hash and events as today.
- **D2:** `OnJoin` loses its in-turn failure. `CanJoin` runs at join intake, in the segment of the insert, but `OnJoin` is a queued input applied in a later turn. A `CanJoin` state check can be stale by then; that is today's timing for `maxPlayers` too. Options:
  - (a) Accept and document it: state checks for a join go in `CanJoin`, and `OnJoin` may assume nothing changed.
  - (b) Also give `OnJoin` a `validate:`/`apply:` form. A rejected join then needs a path that undoes the player insert, which is the in-turn join failure path §5 removes.
  - I recommend (a).
- **D3:** keep `try` out of the single-closure body entirely (the compiler enforces this), with no `rethrows`-style escape hatch.

## PRs

One PR, with commits split by kind:
1. Sources and Tests: DSL, `ValidateContext`, keeper/record (D1), removals, test migration.
2. Examples: the two example lands, the VisibilityTestLand test, and the remaining recompiles.
3. Docs (en/zh), plus the #535 plan note and the index row.

Verification:
- `swift test` on both `IN_TURN_SYNC` settings, and GameDemo `swift test`.
- Mutants:
  - `validate`'s error not routed (an input applied after a rejection);
  - `apply` running after a rejection;
  - the rejected marker not compared in replay;
  - VisibilityTestLand's fresh-land check removed.
- A release build of EncodingBenchmark, then the A/B (§9).
