# Lifecycle handler shapes before the turn core (#593)

Status: rev 1, plan only, for review. Issue: #593. It follows #586's rule (`2026-11-18-two-phase-handlers.md`, #591): a handler that can fail is two-phase, a handler that can't fail is single and non-throwing, and nothing throws after it has written state.

Base: main @ 6f568ff6 (#739 merged). Line numbers are at that head: LK = `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, DSL = `Sources/SwiftStateTree/Land/LandDSL.swift`, LD = `Sources/SwiftStateTree/Land/LandDefinition.swift`. Gathered with grep and reads only; no build.

## 0. Scope

#593's "Now" list, as of this head:

| Item | State | Here |
|---|---|---|
| Duplicate `HandleAction` refused | done in #591 (96902b99, issue comment 2026-11-18) | no |
| `OnFinalize`, `OnDestroyWhenEmpty` non-throwing | open | §1 |
| `OnInitialize` two-phase | open | §2 |
| Client-event decode failure | folds into #521 PR 2 (typed decoding) | no |

Join (#588) and resolvers on every handler kind wait for the turn core (#546 / #551), as #593 says. §2 uses the same `ValidateContext` that #588's `CanJoin` will take, so the join work reuses this shape.

One PR, two commits (§1, then §2), each with its tests and docs. The project is pre-release: the source break is direct, with no deprecation step, as for #586.

## 1. `OnFinalize` and `OnDestroyWhenEmpty` become non-throwing

**Today.** Both are `(inout State, LandContext) throws -> Void`:
- DSL `OnFinalize` ×4 arities (:737, :751, :764, :780) and `DestroyWhenEmpty(after:_:)` (:624);
- the stored fields `LifetimeConfig.onFinalize` (:412) and `.onDestroyWhenEmpty` (:424), and `LifetimeHandlers.onFinalize` (LD :161) and `.onDestroyWhenEmpty` (LD :137), all public `var`s.

`runDestroyHandler` (LK :6285) wraps the resolvers and the handler in one `do`. A throw from either is logged and the drain goes on. A handler that threw keeps what it wrote before the throw (#87, LK :3514).

**After.**
- Every one of those closure types drops `throws`, the public stored fields included. A throwing closure assigned to a public field would be the escape hatch #586 closed for actions.
- `runDestroyHandler`'s `do` covers only the resolvers. A resolver failure still skips the handler and logs; the handler's call moves out of the `do`, as a plain call.
- A handler that calls throwing code handles its errors itself. The land is ending, so nothing would act on a refusal.
- `AfterFinalize` and the deprecated `OnShutdown` already don't throw: unchanged.

`DestroyWhenEmpty` takes no resolvers in the DSL. `LifetimeHandlers.onDestroyWhenEmptyResolverExecutors` (LD :140), settable by hand, keeps working.

## 2. `OnInitialize` becomes two-phase

**Today** (LK :1236 `performInitialization`):
1. The resolvers run. A timeout, or a throw with `.failLand`, fails the initialization: `initializationFailure` is set, the land is torn down without its destroy handlers (`tearDownAfterFailedInitialization`, LK :1175), every caller waiting in `ensureInitialized` gets `LandInitializationError`, and a join gets the retryable `JoinError.landShuttingDown` (`JOIN_DENIED`).
2. The handler runs. A throw is logged, and the land starts with whatever was written before it (#87, the "fails alone, keeping its writes" path).

Replay runs it at two sites: `replayInitializeBeforeTickZero` (LK :1197, record format 2.1) and the lifecycle item path (LK :3930, older records). Both log a throw and go on.

**After.**

### 2.1 The DSL

| Form | Signature |
|---|---|
| single | `OnInitialize { (state: inout State, ctx: LandContext) in ... }`, non-throwing |
| two-phase | `OnInitialize(validate: (State, ValidateContext) throws -> Plan, apply: (inout State, Plan, LandContext) -> Void)` |
| two-phase, no plan | `OnInitialize(validate: (State, ValidateContext) throws -> Void, apply: (inout State, LandContext) -> Void)` |

Each form comes in four arities: no resolvers, and `resolvers:` with 1, 2 or 3 types. The resolver arities keep `onResolverFailure:` (#238).

`validate` gets `ValidateContext`, so it can't emit events, draw random numbers or schedule anything. It reads the resolver outputs through the same dynamic members as `LandContext`. `validate` and `apply` run back to back in one synchronous segment, as for actions.

### 2.2 Storage

`LifetimeConfig.onInitialize` and `LifetimeHandlers.onInitialize` change from a public throwing closure to a public struct `InitializeHandler<State>`, shaped like #586's `AnyActionHandler` (LD :231):
- public inits take the two stages, or a non-throwing body;
- a `package` stored `invoke: (inout State, LandContext) throws -> Void` throws only from `validate`, before `apply` writes;
- no public init takes a throwing body.

### 2.3 The keeper

- **Live** (LK :1335). A throw from `invoke` takes the existing failed-initialization path, the one a resolver failure takes:
  - `initializationFailure = LandInitializationError(underlying: error)`;
  - `tearDownAfterFailedInitialization`;
  - return before the initialize record, the sync marker and the turn outputs.

  Nothing was written, and `validate` emitted nothing. The destroy handlers are skipped, since `initializationFailure` is set (LK :6221).
- **`.continue`.** With `onResolverFailure: .continue`, `validate` runs without the group's outputs and may refuse. That is the place for the check the docs already ask the handler to make.
- **Replay** (both sites). Each runs `invoke` with the recorded resolver outputs. A record holds an initialize entry only when the live `validate` passed, since the record is written after the handler. So a replayed `validate` that throws contradicts the record: `validate` was not deterministic. Q2 decides what replay does then.
- **Comments.** LK :3514 and :3938, and `LandFailure.swift:22`'s #87 note, stop naming OnInitialize and the destroy handlers as handlers that throw after a write.

### 2.4 What the creator sees

#593 says the creator gets the error. At this head no creator waits for the initialization: the keeper starts it in a `Task` from its init (LK :1125). `LandManager` sees a failure only when the teardown wins the race with the land's publication (`LandManagerFailedInitializationTests`: the creation fails with `landShuttingDown`). Otherwise the join that created the land gets the retryable `JOIN_DENIED`.

This PR keeps that, since it is the path a resolver failure already takes. Q1 is whether a `validate` refusal should be retryable.

## 3. Docs (both languages)

- `docs/core/land-dsl.md` / `.zh-TW.md` :229. Drop "may throw, and keep what they wrote". Add the OnInitialize forms, and the rule that the destroy handlers handle their own errors.
- `docs/core/failure-handling.md` / `.zh-TW.md`. The row "an input handler that throws after writing state" (:90 / :84) gains the lifecycle handlers. A new row: an OnInitialize `validate` that throws fails the initialization, as a resolver failure does.
- `docs/core/resolver.md` / `.zh-TW.md`. The `.continue` row: the place to check missing outputs is `validate`.
- `docs/core/reevaluation.md` / `.zh-TW.md`, per Q2.

## 4. Tests

- **Must-not-compile** (`scripts/must-not-compile/`, `check-must-not-compile.sh`). Each of these doesn't compile:
  - a throwing body for `OnFinalize`, for `DestroyWhenEmpty(after:_:)` and for the single `OnInitialize`;
  - a throwing closure assigned to each public field (`onInitialize`, `onFinalize`, `onDestroyWhenEmpty`);
  - an `OnInitialize` whose `apply` throws.
- **OnInitialize, live** (`InitializeResolverFailureTests` sits next to these):
  - `validate` throws: the state equals the initial state, the land is torn down, a waiting join gets `landShuttingDown`, an action gets `LandInitializationError`, the destroy handlers don't run, no initialize record is written and no event goes out;
  - `validate` passes: `apply` gets the plan (and the Void form gets none);
  - `validate` reads a resolver output; with `.continue` it sees none and can refuse.
- **OnInitialize, replay.** A recorded initialize replays through `validate`/`apply` with an equal state hash, at both sites (format 2.1 and the lifecycle item). The divergence case follows Q2.
- **Destroy handlers.** A resolver failure skips the handler and the drain goes on (it exists today; keep it). The handler runs exactly once.
- **Existing throwing bodies.** Every test or example whose lifecycle body throws stops compiling. The compiler lists them, and each is rewritten or moved to `validate`; the PR lists them. In `Examples/`, no `OnInitialize`, `OnFinalize` or `DestroyWhenEmpty` body throws (checked in all five files that declare one; the one `try` nearby is inside `AfterFinalize`, which already handles it).
- **Mutants.**
  - A `validate` throw made to log and go on, as today: the live refusal test fails.
  - `apply` run before `validate`: the state-equals-initial check fails.

## 5. What could collide

| Plan | Owner | Touches | With #593 |
|---|---|---|---|
| L2d-3, `2026-11-21-l2d3-delete-legacy-sync.md` (#546) | Code-1 | LK's legacy pass, `beginSync`/`endSync`/latch, settle retry, `LandKeeperTransport` defaults, and the test transport fakes (its §3 list includes `InitializeResolverFailure`, `LandDSL`, `LandFailure`, `ResolverDeadline`) | Same file LK, different regions: `performInitialization`, both replay sites and `runDestroyHandler` aren't in its delete list. The shared test files get a new fake method there and edited lifecycle bodies here, so the conflicts are textual. Recommend #593 after L2d-3 merges, rebased on it. |
| Shared deadline timer, `2026-11-21-turns-shared-deadline-timer.md` (#621 item 2) | Code-1 | `SwiftStateTurns` (`TurnActor`, `Runtime`), its tests | No overlap: another module. |
| #522, the land-stop drain's bookkeeping into a turn | unassigned | `drainAfterIdleCheck`, `runDestroyHandler` | #593 only changes the handlers' type and narrows the `do`. #522 then moves calls that no longer throw. Either order works. |
| #588 join, turn-core resolvers (#551) | later | `CanJoin`/`OnJoin`, resolver delivery | Out of scope. #588 reuses `ValidateContext` and this plan's storage shape. |
| #716 S1a-3 (refusal path in `settleTurn`) | Code-2 | `settleTurn`'s catch | No overlap. |

## 6. Measurement

None. `OnInitialize` runs once per land and the destroy handlers once per teardown, so no hot path changes and no host A/B is needed. A Mac build and the touched suites, then CI.

## 7. Questions

- **Q1. A `validate` refusal: retryable?** Today an initialization failure gives a join the retryable `JOIN_DENIED` ("retry the join": the land is torn down, so a retry gets a new one). A refusal that comes from configuration recurs on every retry, so clients would keep creating lands that refuse. A resolver failure with `.failLand` has the same property today.
  - (a) Keep the retryable path, the same as a resolver failure. **Recommended.**
  - (b) A non-retryable reason for a `validate` refusal. That is a wire-visible change to the join error, and it would leave #238's resolver failure inconsistent, so it belongs to its own issue covering both.
- **Q2. A replayed `validate` that throws.** The live run's record says it passed.
  - (a) Log it, leave the state as before OnInitialize, and let the existing checks report the divergence: the initialize event check at tick -1 and the state hashes from tick 0. No new mechanism. **Recommended**, with a test that a divergent `validate` fails the replay's verification.
  - (b) A typed re-evaluation failure (`initializeRefusedInReplay`) that stops the replay at once. Clearer, but a new failure kind in the runner and its report.
- **Q3. The storage type.** A public struct `InitializeHandler` (§2.2, like `AnyActionHandler`), or keep a closure field and make it `package`? The struct keeps hand-built definitions possible without a throwing escape hatch. **Recommended: the struct.**
- **Q4. A metric.** Should a `validate` refusal count somewhere? `ResolverDeadline.metrics.initFailures` counts resolver groups; it is not the place. **Recommended: log only**, the same error log a resolver failure writes, with the handler named.
