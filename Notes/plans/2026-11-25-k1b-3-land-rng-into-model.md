# K1b-3: the land RNG moves into the keeper's state (#700, #765)

**Status:** rev 1, plan only. Read at #835's head 5baa1887 (K1a), without the LSP. The implementation re-checks every site with the LSP on its base: #835's branch after Code-2's shoulds push, then main once #835 merges. K1b-Q2 is decided (a) (Main, 2026-11-25; `2026-11-22-keeper-on-turncore.md` §9). K1b-3 needs K1a only (K1b-Q3).

## 1. Goal

`ctx.random` keeps its API. The land's generator state stops being a locked class in `services`:
- it becomes a plain `DeterministicRng` held by the keeper, which K1b-4 moves into `KeeperModel`;
- each handler invocation that replay repeats draws from a service built for that step, and the state is written back when the step ends.

Afterwards no code outside a step can move the land's RNG. That closes #765's class:
- a resolver can't draw from the land RNG;
- a handler that keeps `ctx.random` past its step draws from a copy that no longer moves the land.

## 2. Today (5baa1887)

- `DeterministicRngService` (`Core/DeterministicRngService.swift:9`) is a public final class: an `NSLock` around a `DeterministicRng` struct (`Core/DeterministicRng.swift:8`, one `UInt64` of state), plus `seed`.
- `LandKeeper.init` registers one in `services` when the caller didn't (LK:1176–1182). Its seed is `DeterministicSeed.fromLandID(landID)`.
- Replay sets the seed by registering its own service: `ReevaluationEngine` at :287–299, `ReevaluationRunnerImpl` at :233 and :310. The keeper reads the seed back for the record header: `getRngSeed()` (LK:612), called from `LandManager`:669.
- `LandContext.random` (`Land/LandContext.swift:179`) looks the service up in `ctx.services`. `makeContext` (LK:3512) merges the land services, an override and the player's services, so every context carries the land RNG.
- `ResolverContext` copies `landContext.services` (`ResolverContext.swift:88`), so resolvers reach the same instance. That is #765: a resolver's draw moves the land's RNG live, and replay, which doesn't run resolvers, diverges.

## 3. Shape

### 3.1 Types (SwiftStateTree)

- `DeterministicRng` gains `@PlainData`. It is one `UInt64`, so this is an addition, and K1b-4's `KeeperModel` needs it.
- `DeterministicRngService` gains two members, package or internal, so the public surface is unchanged:
  - `init(continuing generator: DeterministicRng, seed: UInt64)`;
  - `var generator: DeterministicRng`, read under the lock.

  The public `init(seed:)` and the three draws stay.
- `LandContext` gains an internal stored `stepRandom: DeterministicRngService?`. Then `random` returns, in order:
  1. `stepRandom`, if set;
  2. else the `services` lookup, as today. This keeps contexts built without a keeper working: tests, and the GameDemo's `MonsterSystemTests`, which register a service themselves;
  3. else today's `fatalError`, with its message updated.

  Its doc comment changes: "the step's generator; one kept past its step draws from a copy that no longer moves the land". The "can be used concurrently" line goes.

### 3.2 The keeper

- **New fields.**
  - `private var landRandom: DeterministicRng`: model state; K1b-4 moves it into `KeeperModel`.
  - `private let landRandomSeed: UInt64`: fixed at init; K1b-4 places it in Behavior.
  - `private var stepRandom: DeterministicRngService?`: the step in progress (see nesting below).
- **Init (LK:1176).**
  - The seed is `services.get(DeterministicRngService.self)?.seed ?? DeterministicSeed.fromLandID(landID)`, as today's two sources.
  - The keeper doesn't register a service any more. It removes a caller's from the land services with a new internal `LandServices.removing(_:)`. So no context's `services` and no resolver holds the land RNG.
  - Replay's way of passing the seed (register a seeded service) keeps working unchanged, because the keeper reads the seed before removing the service.
- **`getRngSeed()`** returns `landRandomSeed`. Today it reads `services`, which no longer holds the service.
- **The helper.** It replaces `withMutableStateSync` (LK:3561) at its nine callers. It takes the context, binds the step's service and writes the state back:
  ```swift
  private func withHandlerStep<R>(_ ctx: LandContext, _ body: (inout State, LandContext) throws -> R) rethrows -> R {
      if let open = stepRandom {            // nested: share the outer step's generator
          var bound = ctx; bound.stepRandom = open
          return try body(&state, bound)
      }
      let service = DeterministicRngService(continuing: landRandom, seed: landRandomSeed)
      stepRandom = service
      defer { landRandom = service.generator; stepRandom = nil }
      var bound = ctx; bound.stepRandom = service
      return try body(&state, bound)
  }
  ```
  - The body is synchronous, so the read and the write-back of `landRandom` happen in one segment. No turn can run between them.
  - **Nesting.** An inner call shares the outer step's generator; only the outermost call writes back. A second service would repeat the outer's draws, and its write-back would be overwritten. The implementation checks with the LSP whether any nesting exists; if none does, it adds a debug assertion instead of the sharing branch. Review's call.
  - **Draws before a throw are kept.** The `defer` writes them back. Handlers throw only from `validate`, before they write state. Live and replay both run `validate`, so either choice replays. Kept is the simpler one, and a test pins it.

### 3.3 The sites

The keeper calls handlers at 14 places (5baa1887):

| Site (LK) | Handler | Replayed? | Generator |
|---|---|---|---|
| 1351 `replayInitializeBeforeTickZero` | OnInitialize | is replay | step (helper) |
| 1496 `performInitialization` | OnInitialize | yes | step (helper) |
| 3799 `applyPendingItem` | action | yes | step (helper) |
| 3851, 3853 `applyPendingItem` | client event (decoded / undecoded) | yes | step (helper) |
| 3897 `applyPendingItem` | server input | yes | step (helper) |
| 3989, 4012, 4035 `applyLifecycleItem` | OnJoin, OnLeave and the other lifecycle handlers | yes | step (helper) |
| 6220 `runDestroyHandler` | OnFinalize | yes, if replay runs destroy; the implementation checks | step (helper) |
| 4920 `runTickTurn` | tick | yes | step: wrap the call in the helper |
| 2053 `joinReportingAdmission` | CanJoin | **no**: admission isn't recorded; the join's lifecycle item is | **detached** (below) |
| 5996 `runSync` | the read-only sync handler | **no**: it runs on the sync loop, outside the record | **detached** |
| 6160 `drainAfterIdleCheck` | AfterFinalize (async) | no: the land is gone | **detached** |

- **Detached.** A handler that replay doesn't repeat gets a service built from a copy of `landRandom`, and nothing is written back: `ctx.stepRandom = DeterministicRngService(continuing: landRandom, seed: landRandomSeed)`.
  - Today, a draw in CanJoin or the sync handler moves the land RNG, and replay doesn't repeat it: #765's divergence through another door. Detached closes it.
  - The cost: such a handler draws the same values as the next step's first draws. That is harmless, because its draws never reach the state. Document it on `random`.
- Every site's own `makeContext` is unchanged. The binding happens at the call, not when the context is built. That matters where an `await` sits between the two (`performInitialization` with its resolvers, `join`, `runDestroyHandler`): the step is the synchronous segment that runs the handler.
- **`runSync` is A.6 S3's non-turn writer until K2.** Its handler is detached, so it adds no RNG write to that exception.

### 3.4 What doesn't change

- **The draw sequence.** A land without resolver, CanJoin or sync-handler draws draws exactly today's sequence, because the state carries across steps.
- **The record format.** The seed is still in the header, and existing records replay with 0 mismatch.
- **Public signatures.**

## 4. Public API

- **Additions:** `DeterministicRng: PlainData`.
- **Behavior changes** (no signature changes):
  - the land's `DeterministicRngService` is no longer in `ctx.services` or `ResolverContext.services`. A handler uses `ctx.random`, and a resolver gets no land RNG (#765's direction);
  - a `ctx.random` kept past its step no longer moves the land;
  - CanJoin, the sync handler and AfterFinalize draw from a detached copy.
- **Not a break by the repository's census:** no resolver, CanJoin or sync handler in Sources, Tests or Examples draws. The implementation re-checks this with the LSP's references to `DeterministicRngService` and `random`.
- Main approves additive public API. The behavior changes go in the PR's Public API list.

## 5. Tests (SwiftStateTreeTests)

1. **Sequence continuity.** OnInitialize, join (OnJoin), an action, a client event, a server input, a tick, leave and OnFinalize each draw once. The values equal `DeterministicRng(seed:)` drawn eight times in that order. Then replay the record: every tick hash matches.
2. **#765, now passing.** A resolver can't reach the land RNG: `ResolverContext.services.get(DeterministicRngService.self) == nil`, also when the caller registered one for its seed. The issue's repro, with the resolver using its own generator, replays with 0 mismatch.
3. **Retained service.** A handler keeps `ctx.random` in a test box. A later step draws from the box between two land draws. The land's draws are unchanged (equal to an uninterrupted sequence).
4. **Detached handlers.** CanJoin draws, and the sync handler draws. The land's next draws equal an uninterrupted sequence, and replay of a record with a drawing CanJoin matches.
5. **Draws before a validate throw are kept.** The next step's draw is the one after them, and replay matches.
6. **Seed sources.**
   - `getRngSeed()` returns a caller-registered seed, else `fromLandID`.
   - The record header holds it.
   - `ReplayRecordedRngSeedTests` stay green unchanged.
7. **A context without a keeper.** `LandContext.random` falls back to a service in `services`, as the GameDemo tests use.
8. **Nesting.** Only if §3.2 finds a nested site: the inner handler's draws continue the outer's.

## 6. Mutants (cloud worker)

| # | Mutant | Killed by |
|---|---|---|
| R-M1 | the helper doesn't write back | 1 |
| R-M2 | one long-lived service, reset each step (option (b)) | 3 |
| R-M3 | the keeper still registers the service in `services` | 2 |
| R-M4 | CanJoin bound to the step (written back) | 4 |
| R-M5 | the write-back skipped on a throw (not in `defer`) | 5 |
| R-M6 | `getRngSeed()` reads `services` again | 6 (a custom seed is lost from the header) |
| R-M7 | the tick call left unwrapped (`random` falls back to `services`, which is empty → crash) | 1 |

## 7. Performance

**Cost.** One `DeterministicRngService` allocation, with its lock, per handler invocation: per action, event, input, lifecycle item and tick. Contexts are already allocated per call, so this adds one small object.

**Small A/B** (K1b-Q2 (a)'s cost line):
- the default production cell on the measurement host;
- off-path gate: windowed `instructions:u` (#517 (a)); time is reported only.

If it shows:
- the service can be created lazily on the first `random` read, through a per-step box: still one allocation, but only for steps that draw;
- or the service can be reused per keeper, reset each step, with a step generation that a retained service checks. That puts back a shared object, so it needs Review.

## 8. Docs

- `docs/core/reevaluation.md` (EN and zh-TW) shows replay registering a seeded service. That still works; add one line saying that the keeper reads the seed from it and doesn't keep the service in `services`.
- The `LandContext.random` and `ResolverContext.services` doc comments change.
- If a docs page on resolvers mentions the RNG, it says that resolvers don't get the land RNG (grep at implementation).
- **Lesson** (`Notes/solutions/`, with `title:`, index regenerated): "a handler that replay doesn't repeat must not move replayed state". The CanJoin and sync-handler doors were found by asking, at each call site, "is this replayed?".

## 9. Size

- Source: about 60 lines (two types, the keeper helper and 14 sites, and `LandServices.removing`).
- Tests: 7 or 8.
- One PR, on #835's branch until #835 merges.

## 10. For Review

- **§3.3 "replayed?" column.** Confirm with the LSP on the base: whether replay runs OnFinalize, and that CanJoin never runs in replay.
- **§3.2 nesting.** Is there a nested call?
- **§4: removing a caller's service from `services`.** The alternative is to leave it there. A handler or resolver reading it directly would then draw from an instance that isn't the land's. That doesn't move the land, but it's confusing. Removing it is recommended.
