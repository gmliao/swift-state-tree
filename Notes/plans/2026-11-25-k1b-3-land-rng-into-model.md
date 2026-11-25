# K1b-3: the land RNG moves into the keeper's state (#700, #765)

**Status:** rev 2.1, plan only. Review: GO once rev 2.1's must-fix is in, with no further round (2026-11-25); rev 2.1 adds it and the shoulds and nits (§12). K1b-Q2 is decided (a) (Main, 2026-11-25; `2026-11-22-keeper-on-turncore.md` §9). K1b-3 needs K1a only (K1b-Q3). Read at #835's head 5baa1887 (K1a). The implementation re-checks every site with the LSP on its base: #835's branch after Code-2's shoulds push, then main once #835 merges.

- **Rev 2** answers Review's NOT GO on rev 1.2 (1 must-fix, 7 shoulds, 3 nits, all taken; §11).
- **Rev 1.2** folded in an LSP pre-read.
- **Rev 1.1** corrected the keeper's line numbers, which rev 1 took from main instead of 5baa1887.

## 1. Goal

`ctx.random` keeps its API. The land's generator state stops being a locked class in `services`:
- it becomes a plain `DeterministicRng` held by the keeper, which K1b-4 moves into `KeeperModel`;
- each handler invocation that replay repeats from the record draws from a service built for that step, and the state is written back when the step's synchronous body ends.

That closes #765's class:
- a resolver can't reach the land RNG;
- a handler that keeps `ctx.random` past its step draws from a copy that no longer moves the land.

**The limit, stated on `random`.** Draws must be synchronous inside the handler. `LandContext` and the service are `Sendable`, so a handler can hand `ctx.random` to a `Task`. A draw from that task that takes the lock before the step's write-back reads the generator lands in the land's state, live only, and replay can't repeat it. Draws after the step ends are isolated. The retained-service test pins that half.

## 2. Today (5baa1887)

- **The service.** `DeterministicRngService` (`Core/DeterministicRngService.swift:9`) is a public final class: an `NSLock` (a class too) around a `DeterministicRng` struct (`Core/DeterministicRng.swift:8`, one `UInt64` of state), plus `seed`.
- **Registration.** `LandKeeper.init` registers one in `services` when the caller didn't (LK:1176–1182). Its seed is `DeterministicSeed.fromLandID(landID)`.
- **Replay's seed.** Replay registers its own seeded service: `ReevaluationEngine` at :287–299, `ReevaluationRunnerImpl` at :233 and :310. The keeper reads the seed back for the record header through `getRngSeed()` (LK:612), which `LandManager`:669 calls.
- **The draw.** `LandContext.random` (`Land/LandContext.swift:179`) looks the service up in `ctx.services`. `makeContext` (LK:3569) merges the land services, an override and the player's services (LK:3580–3582), so every context carries the land RNG.
- **#765.** `ResolverContext` copies `landContext.services` (`ResolverContext.swift:88`), so resolvers reach the same instance. A resolver's draw moves the land RNG live, and replay, which doesn't run resolvers, diverges.

## 3. Shape

### 3.1 Types (SwiftStateTree)

- **`DeterministicRng` gains `@PlainData`.** It is one `UInt64`, so this is an addition, and K1b-4's `KeeperModel` needs it.
- **`DeterministicRngService`:**
  - It gains `init(continuing generator: DeterministicRng, seed: UInt64)` and `var generator: DeterministicRng`, read under the lock. Both are package or internal, so the public surface is unchanged.
  - **Its lock becomes `Synchronization.Mutex<DeterministicRng>`,** stored inline, so a service is one allocation, not two (`NSLock` is a class). `Mutex` needs macOS 15, so the floor goes from `.macOS(.v14)` to `.macOS(.v15)`. The standing OS-floor authorization covers it, and the PR states it. Linux and Windows have `Synchronization` on the pinned 6.4.3.
  - **The floor moves in every manifest that depends on the root package**, or a macOS build of it fails on the deployment target:
    - `Package.swift`;
    - `Examples/Demo/Package.swift`:8;
    - `Examples/GameDemo/Package.swift`:8;
    - `Tools/AutobahnEcho/Package.swift`:11;
    - the consumer manifest that `scripts/check-must-not-compile.sh`:52 generates.

    Linux CI doesn't see this; the macOS CI job (#847, non-blocking) and the Macs do. `ws-loadtest`'s poc and the inlinable negative control build only their own sources, so they stay at 14.
  - **A comment beside `platforms`:** only macOS is listed, so other Apple platforms keep their defaults. `Mutex` would need iOS, tvOS and Mac Catalyst 18, watchOS 11 and visionOS 2 if the package ever builds for them.
  - The public `init(seed:)` and the three draws stay.
- **`LandContext`** gains an internal stored `stepRandom: DeterministicRngService? = nil`. The default lets the 14 `@testable` initializer calls compile unchanged. `random` then returns, in order:
  1. `stepRandom`, if set;
  2. else the `services` lookup, as today. Contexts built without a keeper (the GameDemo's `MonsterSystemTests` and `DeterministicTests`) register a service themselves, and this keeps them working;
  3. else today's `fatalError`, with its message updated.

  Its doc comment states §1's rule and limit. The line "can be used concurrently" goes.

### 3.2 The keeper

- **New fields:**
  - `private var landRandom: DeterministicRng`, model state, which K1b-4 moves into `KeeperModel`;
  - `private let landRandomSeed: UInt64`, fixed at init, which K1b-4 places in Behavior.

  No field holds a service (S1): each service is local to the call that made it.
- **Init (LK:1176):**
  - The seed is `services.get(DeterministicRngService.self)?.seed ?? DeterministicSeed.fromLandID(landID ?? definition.id)`. `landID` is optional at LK:1161.
  - The keeper doesn't register a service any more. After reading the seed, it **strips the land services once**: `services = services.removing(DeterministicRngService.self)`. A replay that registered its seed service then costs no extra work per context.
  - Replay passes its seed exactly as before: the keeper reads the seed before the removal.
  - With the land services stripped, reverting `getRngSeed()` to the services lookup loses a custom seed, so test 6 kills R-M6.
- **`makeContext` strips the RNG** (S6). It removes `DeterministicRngService` from the merged services (land, override and player, LK:3580–3582), with a new internal `LandServices.removing(_:)`. This is the single point where every context's services are built, so no context and no resolver holds a caller's RNG instance, whichever registration it came from. A miss costs one dictionary lookup: `removeValue` returns without copying.
  - **The concrete key only.** `LandServices` keys by `ObjectIdentifier` of the registered type, so a service registered as `(any RngSeedProvider).self` survives, and `extractRngSeed()` scans every value. The keeper strips `DeterministicRngService.self` only. A protocol-typed registration is the caller's own object, and the land's generator never reaches it.
- **`getRngSeed()`** returns `landRandomSeed`.
- **The helper** replaces `withMutableStateSync` (LK:3618) at its callers:
  ```swift
  private enum HandlerRandom { case step; case detached(DeterministicRngService) }

  private func withHandlerStep<R>(_ ctx: LandContext, random: HandlerRandom = .step,
                                  _ body: (inout State, LandContext) throws -> R) rethrows -> R {
      var bound = ctx
      switch random {
      case .detached(let service):
          bound.stepRandom = service
          return try body(&state, bound)
      case .step:
          let service = DeterministicRngService(continuing: landRandom, seed: landRandomSeed)
          defer { landRandom = service.generator }
          bound.stepRandom = service
          return try body(&state, bound)
      }
  }
  ```
  - **One segment.** The body is synchronous, so reading `landRandom` and writing it back happen in one segment, and no turn runs between them.
  - **No nesting.** §3.5 shows none. A nested call would already trap: a second `&state`, and after K1b-4 a second `&model`, breaks the Law of Exclusivity (SE-0176). So the helper has no nesting branch and no "step open" field.
  - **K1b-4 fit.** The `defer` write-back runs after the body's access of `state` (later `model`) ends.
  - **Draws before a throw are kept** by the `defer`. The public DSL can't reach this: `ValidateContext` has no `random` (ValidateContext.swift:37–68), apply doesn't throw, and the one throwing handler that gets a `LandContext` is CanJoin, which is detached. So it is defensive, for package-level `invoke` closures, and test 5 uses one (S4).

### 3.3 The sites (15 at 5baa1887)

| Site (LK) | Handler | Repeated from the record? | Generator |
|---|---|---|---|
| 1385 `replayInitializeBeforeTickZero` | OnInitialize | is replay | step (helper) |
| 1546 `performInitialization` | OnInitialize | yes | step (helper) |
| 3861 `applyPendingItem` | action | yes | step (helper) |
| 3917, 3919 `applyPendingItem` | client event (decoded / undecoded) | yes | step (helper) |
| 3969 `applyPendingItem` | server input | yes | step (helper) |
| 4061, 4084, 4107 `applyLifecycleItem` | OnJoin, OnLeave, and the legacy OnInitialize fallback (4061) | yes | step (helper) |
| 5022 `runTickTurn` | tick, live (`routesThroughTurn`, LK:4545) | yes | step: wrap the call in the helper |
| **4814 `runTick`, inline** | **tick, reevaluation keeper** (`mode != .live`; ctx at :4797) | **is replay** | **step**: the call becomes `if !shutdownTurnApplied, let tickHandler { withHandlerStep(ctx) { … } }`, so a tickless or shutdown frame allocates nothing (MF1) |
| 2103 `joinReportingAdmission` | CanJoin | **no**: not repeated from the record; a viewer joining a reevaluation keeper runs it live (LK:2074–2103) | detached, a fresh copy per call |
| 6098 `runSync` | the read-only sync handler | **no**: it runs on the sync loop, also on a reevaluation keeper with its sync loop on (LK:6039–6098), never from the record | detached, a fresh copy per call |
| 6322 `runDestroyHandler` | OnDestroyWhenEmpty, OnFinalize | **no**: only the live drain calls it | detached, **the drain's generator** |
| 6262 `drainAfterIdleCheck` | AfterFinalize (async) | no | detached, **the drain's generator** |

- **Detached.** A handler that isn't repeated from the record draws from a copy of `landRandom`, and nothing is written back. Its draws never reach replayed state. Today a draw in CanJoin or the sync handler moves the land RNG, and replay can't repeat it: #765's divergence through another door.
- **The drain's generator** (S2). `drainAfterIdleCheck` builds one service from `landRandom` when the drain starts and passes it to OnDestroyWhenEmpty, OnFinalize and AfterFinalize in order. So their draws continue one sequence instead of repeating each other's. Nothing is written back, and replay is unaffected, since the drain is live only (#826).
  - **When it's built.** After `waitForTickInFlight` and both guards (`initializationFailure`, `mode`), just before the destroy handlers. The early exits allocate nothing.
  - **When it's bound.** `runDestroyHandler` binds it after the handler's resolvers succeed, so a skipped handler draws nothing. AfterFinalize's context gets it before the await.
- **A fresh copy per call** for CanJoin and the sync handler: two such calls draw the same values, and each draws what the next step will draw. That's harmless, since none of it reaches state. `random`'s doc says so.
- **Binding at the call.** Every site's own `makeContext` is unchanged, and the binding happens at the call. That matters where an `await` sits between the two (`performInitialization` with its resolvers, `join`, `runDestroyHandler`).
- **`runSync` stays A.6 S3's non-turn writer** until K2. Its handler is detached, so it adds no RNG write to that exception.

### 3.4 What doesn't change, and what does

- **The draw sequence.** For a land whose draws all come from handlers that are repeated from the record, it is today's sequence: the state carries across steps.
- **The record format** keeps the seed in the header.
- **Existing records.** They replay with 0 mismatch when their draws follow the new contract. A legacy record whose land drew in a resolver, in CanJoin or in the sync handler moved the land RNG live. Replay under K1b-3 doesn't, so such a record now replays differently (S6). None exists in the repository (§3.5).
- **Public signatures** stay.

### 3.5 Call-site reading (rev 1.2's LSP pass, plus rev 2)

- **The 9 `withMutableStateSync` callers** (incoming calls): `applyLifecycleItem` ×3, `applyPendingItem` ×3, `performInitialization`, `replayInitializeBeforeTickZero` and `runDestroyHandler`. None is reached from inside another's body.
- **Every handler call that takes a context** (rev 2, at 5baa1887; the grep covers optional calls such as `tickHandler?(&state, ctx)`, which rev 1.2's pass missed): 15 call expressions, in the 12 rows of §3.3. The resolver builders' `ValidateContext(ctx)` calls (1500, 3200, 6304) have no `random`.
- **Paths by mode.** One function can branch on the mode. `runTick` sends a live tick to `runTickTurn` (LK:4545) and runs a reevaluation keeper's tick inline (LK:4814). So the table lists each mode's path as its own row.
- **What replay repeats from the record:** `applyInputs` (reached from `replayRecordedPasses`), the inline tick (`stepTickOnce` ← `ReevaluationEngine` :388, `ReevaluationRunnerImpl` :388), and `replayInitializeBeforeTickZero`.
- **`LandContext.random`'s references:**
  - `ReplayRecordedRngSeedTests`;
  - the GameDemo's tick handler (`HeroDefenseLand`, `MonsterSystem`) and OnJoin.

  No resolver, CanJoin, sync or destroy handler draws.

## 4. Public API

- **Additions:**
  - `DeterministicRng: PlainData`;
  - `Package.swift`'s macOS floor moves to 15 (`Mutex`).
- **Behavior changes** (no signature changes):
  - The land's RNG service is no longer in `ctx.services` or `ResolverContext.services`, and neither is a `DeterministicRngService` that a caller registers in player services or an override: `makeContext` strips the type. A handler uses `ctx.random`; a resolver gets no land RNG (#765's direction).
  - A caller-registered service gives only its seed. A service that was already advanced before registration starts the land from its seed, not from its position.
  - `LandServices.extractRngSeed()` on a context's services finds no RNG any more. The keeper's `getRngSeed()` is the source.
  - A `ctx.random` kept past its step no longer moves the land. Draws must be synchronous inside the handler (§1).
  - CanJoin, the sync handler and the drain's three handlers draw from detached copies (§3.3).
  - Legacy records that drew outside repeated handlers replay differently (§3.4).
- The strip removes the concrete key `DeterministicRngService.self` only (§3.2).
- **Census:** no resolver, CanJoin, sync or destroy handler in Sources, Tests or Examples draws. The implementation re-checks this with the LSP on its base.
- Main approves the additive public API. The behavior changes go in the PR's Public API list.

## 5. Tests (SwiftStateTreeTests)

1. **Sequence continuity.** OnInitialize, join (OnJoin), an action, a client event, a server input, a tick, and leave each draw once. The values equal `DeterministicRng(seed:)` drawn seven times in that order. Then the record is replayed through `ReevaluationEngine`: every tick hash matches, and the replayed tick handler draws through the inline path (MF1).
2. **#765, now passing.**
   - `ResolverContext.services.get(DeterministicRngService.self) == nil`, also when the caller registered one for its seed, and when one is in a player's services.
   - The issue's repro, with the resolver using its own generator, replays with 0 mismatch.
3. **Retained service.** A handler keeps `ctx.random` in a test box. A later step draws from the box between two land draws. The land's draws equal an uninterrupted sequence.
4. **Detached handlers.**
   - CanJoin draws, including a viewer admission on a reevaluation keeper (S5).
   - The sync handler draws.
   - OnDestroyWhenEmpty, OnFinalize and AfterFinalize each draw: they continue one sequence (S2). A drained keeper takes no more steps, so the test compares `landRandom` before and after the drain through a package read: unchanged (R-M8).
   - The land's next draws equal an uninterrupted sequence, and a record with a drawing CanJoin replays with 0 mismatch.
5. **Draws before a throw are kept.** The public DSL can't reach this (S4), so the test uses `AnyActionHandler`'s package `invoke:` initializer: an action whose handler draws, then throws. A rejected action leaves the land running, so the next step's draw can be read; a throwing OnInitialize would tear the land down. The next step's draw is the one after the thrown handler's draws.
6. **Seed sources.**
   - `getRngSeed()` returns a caller-registered seed, else `fromLandID(landID ?? definition.id)`.
   - The record header holds it.
   - `ReplayRecordedRngSeedTests` stay green unchanged.
7. **A context without a keeper.** `LandContext.random` falls back to a service in `services`, as the GameDemo's `MonsterSystemTests` and `DeterministicTests` use.

## 6. Mutants (cloud worker)

| # | Mutant | Killed by |
|---|---|---|
| R-M1 | the helper doesn't write back | 1 |
| R-M2 | one long-lived service, reset each step (option (b)) | 3 |
| R-M3 | `makeContext` doesn't strip the RNG type | 2 |
| R-M4 | CanJoin bound to the step (written back) | 4 |
| R-M5 | the write-back skipped on a throw (not in `defer`) | 5 |
| R-M6 | `getRngSeed()` reads `services` again | 6 (a custom seed is lost from the header) |
| R-M7 | the live tick call (5022) left unwrapped | 1 (`random` finds no service and traps) |
| R-M8 | the drain's handlers bound to the step (written back) | 4 |
| R-M9 | the reevaluation tick call (4814) left unwrapped | 1's replay (traps on the replayed draw) |
| R-M10 | each drain handler gets its own fresh copy | 4 (OnFinalize repeats OnDestroyWhenEmpty's draws) |

## 7. Performance

**Cost.** One allocation per handler invocation (the service, with `Mutex` inline): per action, event, input, lifecycle item and tick. With `NSLock` it would be two (S7).

**Small A/B** (K1b-Q2 (a)'s cost line, with the parent plan's K1b cells):
- the default production cell and `rows-mp`;
- off-path gate: windowed `instructions:u` (#517 (a)); time is reported only;
- **malloc/action on `wide-tickless-mp`**, next to `instructions:u`, because K1a gated +1 malloc/action there. Expected: +1 per handler invocation.

If the cost shows, a lazy box still allocates the box on every call, so it doesn't help. The remaining option is a per-keeper service reset each step, with a step generation that a retained service checks. That brings back a shared object, so it needs Review.

## 8. Docs (EN and zh-TW where bilingual)

- `docs/core/reevaluation.md`: replay still registers a seeded service; the keeper reads the seed and keeps no service in contexts.
- `docs/core/resolver.md`:186: resolvers don't get the land RNG.
- `docs/core/runtime.md`:60 and :159: the RNG lines.
- Comments: `LandContext.random`, `ResolverContext.services`, `getRngSeed`, and `LandManager`:667.
- `docs/quickstart.md`:8 and `docs/FAQ.md`:25, EN and zh-TW: macOS 15 or later.
- **Lesson** (`Notes/solutions/`, with `title:`, index regenerated): "a handler that replay doesn't repeat must not move replayed state; list each mode's path as its own row". The CanJoin and sync-handler doors, and the inline reevaluation tick, were found that way.

## 9. Size

- **Source:** about 70 lines: two types, the helper and 15 sites, the drain's generator, `LandServices.removing`, and the platform floor.
- **Tests:** 7.
- One PR, on #835's branch until #835 merges.

## 10. For Review

- **The `Mutex` floor raise in this PR** (§3.1). The alternative is to keep `NSLock`, at two allocations per invocation, and raise the floor in its own PR.
- **Stripping in `makeContext`** (§3.2): one dictionary removal per context. The alternative is to strip at each registration point (init, join, override).

## 11. Review rev 1.2 → rev 2

| Finding | Taken | Where |
|---|---|---|
| MF1: the reevaluation tick runs inline (LK:4814), outside `runTickTurn` | yes | §3.3 row, §3.5 "paths by mode", test 1, R-M9 |
| S1: drop the `stepRandom` keeper field | yes | §3.2; no nesting branch, no field |
| S2: one drain-local generator for the three drain handlers | yes | §3.3, test 4, R-M10 |
| S3: narrow the guarantee (synchronous draws; a task can race the write-back) | yes | §1, `random`'s doc |
| S4: test 5 needs a package-level handler | yes | §3.2, test 5 |
| S5: "not repeated from the record", plus a viewer admission and a reevaluation keeper's sync loop | yes | §3.3, test 4 |
| S6: four behavior changes to list; strip player/override registrations | yes | §3.2 (`makeContext` strips), §3.4, §4 |
| S7: two allocations; malloc/action on `wide-tickless-mp` | yes, plus the `Mutex` upgrade for one | §3.1, §7 |
| Nits: the `landID ?? definition.id` seed, the docs list, the `stepRandom = nil` default | yes | §3.2, §8, §3.1 |

## 12. Review rev 2 → rev 2.1

| Finding | Where |
|---|---|
| MF: the floor raise misses the consuming manifests (Demo, GameDemo, AutobahnEcho, the snippet checker's generated manifest) and the docs | §3.1, §8 |
| §10 answers: `Mutex` and the floor raise in this PR, with a comment on the other Apple platforms; `makeContext` stripping fine, plus strip the land services once at init (kills R-M6) | §3.1, §3.2 |
| S: where the drain's generator is built and bound | §3.3 |
| S: test 4 reads `landRandom` around the drain | §5 test 4 |
| S: test 5 uses `AnyActionHandler`'s package `invoke:` | §5 test 5 |
| S: the strip is by the concrete key only | §3.2, §4 |
| Nits: 15 calls in 12 rows; the legacy OnInitialize fallback in the 4061 row; the 4814 wrap inside `if !shutdownTurnApplied, let tickHandler` | §3.5, §3.3 |
