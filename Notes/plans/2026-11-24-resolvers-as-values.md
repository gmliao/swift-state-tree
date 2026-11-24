# #769: a resolver is a PlainData value

**Status:** rev 1, plan only, no code. It follows the maintainer's 2026-11-22 decisions on #769 (the issue body, then three comments: `currentState` removed, the value form, and capability protocols for dependencies). Open questions are in §8.

Code pointers are at main d4ce2317. `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`. The dependency probe in §3.4 is a one-file probe kept outside the repository. It passed on Swift 6.4.2 and 6.4.3. **The pin is moving to 6.4.3** (a bump PR is in flight), so R0 probes on 6.4.3 as the target toolchain, in the pinned image once the bump lands. If the bump hasn't landed when R1 starts, R0 also probes on 6.2.4, since CI still gates on it.

## 1. What changes

A resolver is no longer a type with a static `resolve(ctx:)` that reads what it wants from a context. It is a **value**: a `PlainData` struct whose fields are its parameters. The land builds it **in the turn**, at the handler's declaration, from the State and the input. Off the actor, `resolve` sees only its own fields and the dependencies it declares.

```swift
protocol HasProductDatabase { var productDatabase: ProductDatabase { get } }

@PlainData
struct ProductInfo<D: HasProductDatabase>: Resolver, Codable, Hashable {
    typealias Dependencies = D
    let productID: ProductID
    func resolve(_ deps: D) async throws -> ProductInfoOutput {
        try await deps.productDatabase.fetchProduct(by: productID)
    }
}

Land("cart", using: CartState.self, services: AppServices.self) {
    Rules {
        HandleAction(UpdateCart.self,
                     resolvers: { state, action, ctx in      // in the turn, synchronous
                         state.productCache[action.productID] == nil
                             ? ProductInfo(productID: action.productID) : nil
                     }) { state, action, info, ctx in        // info: ProductInfoOutput?
            …
        }
    }
}
```

Each piece answers a defect of today's form:
- **`ResolverContext` is removed** (ResolverContext.swift:37–95). Today a resolver gets `currentState` (a type-erased whole-State snapshot), `actionPayload` / `eventPayload` (`any Sendable`, cast with `as?`), and `services`. It works out for itself what to fetch, and nothing records what it asked for.
- **The effect depends only on its request and the outside world**, never on the keeper's current state. A value the resolver needs from State or the session (`playerID`, `landID`) is copied into a field when the value is built.
- **The record holds what was asked.** The value is `PlainData` and `Codable`, so the record stores it beside the output. A replay rebuilds the value, checks it equals the recorded one before the handler runs, and feeds the recorded output without calling `resolve`.
- **Dependencies are checked at compile time.** `LandServices.get(_:)` (Types.swift:132) returns an optional and fails at run time. A missing capability now fails at the declaration.
- **Outputs are typed.** Today a handler reads `ctx.productInfo` through `@dynamicMemberLookup` (LandContext.swift:301): a name derived from the resolver's type name (`convertResolverTypeToPropertyName`, ResolverExecutor.swift:242), cast to the type the handler asks for, `nil` on a mismatch. The handler now gets the outputs as parameters, in declaration order.

## 2. Inputs and order

| From | What this plan takes | Why |
|---|---|---|
| PlainData P3 | typed payloads (the builder closure gets the typed action); `ResolverOutput` refines `PlainData` | the builder reads `action.productID`; the output is held in the model |
| PlainData P4 | `State` is `PlainData` | the builder reads State in the turn |
| #700 K5 | resolvers as keyed requests on the core (#700 §3.4): an action's request under its entry's key or `.land`, OnInitialize under `.initialization` | the value is the request's payload. #769 lands **with K5** (the issue's "with #700's action slice") |
| #700 K6 | CanJoin, OnJoin, OnLeave requests | §6 R3 |
| #771 | the rules builders generic over State, closures without annotations, done by a throwaway codemod | every `HandleAction(…, resolvers:)` call site changes once, for both (#771's "Order") |
| #765 | a resolver drawing from the land's RNG makes replay diverge | §3.6: this plan closes it by construction |
| #768 | the machine's immutable behavior | the builder closures live in the land definition, which steps reach through it |

**Order:** P3 → P4 → (#700 K1a … K4) → **R1 with #771** → **R2 with K5** → R3 with K6. R0 (probes) can run now.

## 3. Design

### 3.1 The protocol

```swift
public protocol Resolver: PlainData, Codable, Hashable, Sendable {
    associatedtype Dependencies: Sendable
    associatedtype Output: ResolverOutput          // ResolverOutput: PlainData after P3
    func resolve(_ deps: Dependencies) async throws -> Output
}
```

- **`PlainData`** (written by `@PlainData`): the value is held in the model and can't hide a reference.
- **`Codable`:** the record stores it.
- **`Hashable`:** replay's equality check, and later the coalescing of equal requests in one tick (Haxl's data-source requests; the issue's "Later").
- **`ContextResolver` and `ResolverContext` are deleted**, with `AnyResolverExecutor`'s `execute(ctx:)`. The executor's group, deadline race, abandonment and failure wrapping (ResolverExecutor.swift, ResolverDeadline.swift, ResolverAbandonment.swift) stay. They run `value.resolve(deps)` in place of `R.resolve(ctx:)`.
- **The resolver's name** in `ResolverExecutionError.resolverFailed(name:)` and the deadline's `timedOut(names:)` is the base type name without generic arguments (`ProductInfo`, not `ProductInfo<AppServices>`).

### 3.2 The builder closure: in the turn, at the declaration

```swift
HandleAction(A.self,
             resolvers: (State, A, ValidateContext) -> R?,
             _ body: (inout State, A, R.Output?, LandContext) -> A.Response)
```

- **It runs in the turn,** where today's code captures the snapshot (`startActionJob`, LK:2303). After K2 that is the admission step. It reads State, the typed input and a read-only context. It mutates nothing.
- **The context is `ValidateContext`** (#586): read-only, with `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`, `isGuest`, `metadata`, `tickId`. No new context type.
- **`nil` means nothing is fetched,** and the handler gets `nil` for that output. That is today's cache check, made explicit.
- **Several resolvers:** the closure returns a tuple of optionals, and the handler gets a tuple of optional outputs, in the same order. R0 probes a parameter pack (`repeat (each R)?` in, `repeat (each R).Output?` out) on R0's toolchains. If it doesn't infer inside #771's generic builder, the arity overloads stay as today (one to three).
- **Entries, with what their closure reads:**
  - `HandleAction`: State, the action, `ValidateContext`;
  - `CanJoin`: State, `PlayerSession`, `ValidateContext`;
  - `OnJoin`, `OnLeave`: State, `ValidateContext`;
  - `OnInitialize`: State and the land's creation metadata;
  - `OnFinalize`: State.

  Counts at main, by `resolvers:` call lines: `HandleAction` 34, `OnInitialize` 17, `OnJoin` 10, `OnLeave` 7, `CanJoin` 3, `OnFinalize` 2. That is 73 call sites, nearly all in `Tests/`, and 4 in Examples. The `resolvers:` lines in `Sources/` are the DSL's own overloads. Resolver types: 57 in `Tests/` and Examples.
- **The validate/apply forms (#586)** keep their shape: the outputs go to `validate` and to `apply`.

### 3.3 Typed outputs replace the context's dynamic members

- `LandContext`'s `resolverOutputs`, `setResolverOutput`, `getResolverOutput` and the `dynamicMember` subscript (LandContext.swift:159–315) are deleted.
- **Replay decode (#707)** moves with them. Today the subscript decodes an `AnyCodableResolverOutput` with the record's codec when the handler asks. Now the replay decodes each recorded output into `R.Output` when it builds the handler's arguments, with the same codec (`RecordPayloadSource`, or K1a's bytes). An output that doesn't decode is a divergence: it is reported at that point (§3.5), not read as a silent `nil`.

### 3.4 Dependencies: capability protocols, checked at compile time

- **A land declares its services type:** `Land("cart", using: CartState.self, services: AppServices.self)`. Lands without resolver dependencies use `NoServices`, an empty struct, and the `Land(_:using:)` overload without `services:` defaults to it.
- **The builders are generic over `Services` too:** #771 makes them `RulesBuilder<State>`, and this plan adds a second parameter, `<State, Services>`, so each entry knows the land's services type.
- **The declaration requires `R.Dependencies == Services`.** So `D` is inferred at the declaration: the user writes `ProductInfo(productID:)`, never `ProductInfo<AppServices>`. A missing capability fails to compile there: "generic struct 'ProductInfo' requires that 'ThinServices' conform to 'HasPriceCache'" (the probe's text on 6.4.2).
- **A resolver sees only what it declares.** `resolve` gets `D`, constrained to the protocols it lists with `&`. Its body can use those members only.
- **Tests pass fakes:**
  - a resolver's unit test calls `ProductInfo<FakeDB>(productID:).resolve(FakeDB())`;
  - a land test builds the land from a function generic over its services (`makeCartLand<S: HasProductDatabase>(services: S.Type)`) and passes a fake.
- **Where the value comes from.** Today `LandManager`'s `servicesFactory: (LandID, [String: String]) -> LandServices` (LandManager.swift:191). A typed factory replaces it for resolvers: `(LandID, [String: String]) -> Services`. How the definition carries `Services` is **R-Q1**.
- **Two things don't change:**
  - **Handlers' `ctx.services`** (`LandServices`) stays for handlers. The monitor and replay lands use it (ReevaluationMonitorLand.swift, GenericReplayLand.swift), as do `ctx.random` and the recorder service. A follow-up issue can type it the same way.
  - **Per-join `services:`** on `LandKeeper.join` (LK:1724) is merged into today's resolver context. The transport always passes an empty `LandServices()` (TransportAdapter.swift:2239), and only tests pass more. Resolvers stop seeing it. The tests that relied on it move their service into the land's `Services`.

### 3.5 The record and replay

- **Recorded per resolver, in declaration order:**
  - its position;
  - its base type name, for diagnostics;
  - the value (`request`);
  - the output, or that the builder returned `nil`.

  Both values are in the record's payload form: K1a's bytes in the header's `payloadEncoding`. This replaces `ReevaluationRecordedResolverOutput { typeIdentifier, value }` keyed by a derived property name (ActionRecorder.swift:6, :410, :749).
- **Replay:**
  1. it runs the builder closure in the replayed turn, with the replayed State and input;
  2. it compares each value with the recorded `request`. A difference, or a `nil` against a recorded value, is a divergence. It is reported as a pass mismatch (`recordedPassMismatches`, LK:4194) naming the input's sequence, the position and both values, **before the handler runs**;
  3. it feeds the recorded outputs and never calls `resolve`.
- **Format:** a version after K1a's 3.7. Whether older records stay replayable is **R-Q2**.
- **Failures** are recorded as today: a group that fails or times out refuses the input before its record, and the init failure policy (`2026-11-07-init-resolver-failure-policy.md`) is unchanged.

### 3.6 #765 closes by construction

The land's RNG is created by the keeper (LK:1012) and registered in `LandServices`, which handlers reach as `ctx.random`. Under §3.4 a resolver gets the land's `Services` value, which the land's factory makes and the keeper never puts its RNG into. So no resolver can reach the land's RNG.

- **A resolver that wants randomness** has two ways, and both replay:
  - its own source, part of the outside world: the output is recorded, and replay doesn't call `resolve`;
  - a value the builder draws from `ctx.random` in the turn and puts in a field, so the land's RNG advances inside the turn, in turn order.
- **The test:** #765's repro, rewritten in the new form, as a regression test. It uses the second way, with a resolver that has its own RNG beside it, and replay matches every tick. A must-not-compile snippet pins the other side: a resolver whose `Dependencies` asks for `DeterministicRngService` fails at a land that doesn't provide one. Whether `Services` may hold a `DeterministicRngService` at all is **R-Q3**.

### 3.7 What else moves

- **Examples:**
  - GameDemo's `ResolverTestLand.swift:343–349` casts `ctx.actionPayload` and reads `tickCount` from `ctx.currentState`; both become fields;
  - `UserLevelResolver.swift` and `AsyncTestResolver.swift` become values;
  - `HeroDefenseLand.swift`'s declaration changes.

  Examples go in their own commit.
- **Docs** (bilingual, same commit per page): `docs/core/resolver.md`, `docs/programming-model.md`, `docs/quickstart.md`, `docs/FAQ.md`, each with its `.zh-TW.md`. `Sources/SwiftStateTree/Resolver/README.md` (in Chinese, inside `Sources/`) is rewritten in English in R1 (agreed with Main, 2026-11-24).
- **The schema:** resolver outputs aren't in the client schema today. Nothing changes there.

## 4. Public API

All breaking, with no deprecation path; there are no external users yet (the issue's "Shape and order"):
- `ContextResolver`, `ResolverContext`, `AnyResolverExecutor`, `ResolverExecutorWrapper` and `ResolverExecutor.executeResolvers(executors:resolverContext:landContext:)` are removed;
- `Resolver` is added;
- every `resolvers:` parameter changes from metatypes to a builder closure, and the handler closures gain the outputs parameter;
- `LandContext`'s dynamic member subscript for outputs is removed;
- `Land(_:using:services:)` and `NoServices` are added, with R-Q1's registration change;
- `ReevaluationRecordedResolverOutput` and the record's resolver fields change (R-Q2).

## 5. Tests

**Must-not-compile** (scripts/must-not-compile/):

| Snippet | Pins |
|---|---|
| a resolver whose `D` needs `HasPriceCache` at a land whose services lack it | the probe's `requires that … conform to 'HasPriceCache'` |
| a resolver value with a class field | `@PlainData`'s refusal |
| a builder closure that mutates State | `State` is passed immutably (`cannot assign`) |
| a handler reading `ctx.productInfo` | the subscript is gone |
| a resolver using a capability it didn't declare | `value of type 'D' has no member` |

**Runtime** (Swift Testing):
- the builder runs in the turn: a hold at the admission step shows the value was built from the State at that step, not later;
- `nil` skips: no `resolve` call, a `nil` output, recorded as skipped;
- outputs reach the handler typed and in order, for one, two and three resolvers;
- replay equality: a recorded value that the replayed builder doesn't rebuild is reported before the handler runs, with position and both values. The control replays clean;
- replay feeds recorded outputs: `resolve` is never called during replay (a counter in the fake);
- #765's regression (§3.6);
- deadlines, abandonment and failure policy: today's suites (`ResolverDeadline*`, `ResolverFeasibilityTests`, the init failure policy tests) ported to the new form and unchanged in what they assert.

**Mutants:**
- M1: replay skips the equality check. Caught by the replay-equality test;
- M2: replay calls `resolve` instead of feeding the record. Caught by the fake's counter;
- M3: the builder runs after the resolvers instead of in the admission step. Caught by the hold test;
- M4: outputs are passed in reverse order. Caught by the two-resolver ordering test.

**Harness and E2E:** every golden with a resolver changes its record (the new fields), classified by a new class in `classify-golden-changes.py`, added in a tool-only commit first; frames don't change. E2E record/replay in three encodings and the game's reevaluation E2E end with 0 mismatches.

## 6. Slices

| Slice | Content | After | Measurement |
|---|---|---|---|
| **R0** | Probes on 6.4.3, the pin after the bump (and on 6.2.4 too if the bump hasn't landed when R1 starts): the dependency probe (positive and missing-capability cases), its combination with #771's generic builder and `D`'s inference through the builder closure's return, and the parameter pack of §3.2. Results go in this plan; no library code | now | none |
| **R1** | `Resolver`, the services type on the land (R-Q1), the builder closures and typed outputs, `ResolverContext` deleted, every call site migrated with #771's codemod, Examples, docs. Resolvers still run as today's jobs (the value replaces the snapshot) | P3, P4, R0, #771's builders | the resolver cell: an action with one resolver, live, A/B against main |
| **R2** | The record and replay (§3.5), #765's regression. With K5, so the value is the keyed request's payload | R1, K1a, K5 | the record part of the goldens; frames none |
| **R3** | CanJoin, OnJoin and OnLeave requests carry values, with K6 | R2, K6 | none beyond K6's |

R1 doesn't depend on #700 and could go before K1a. That is **R-Q4**.

## 7. Prior art

- **Haxl** (Facebook): data-source requests are values (GADTs) that a scheduler batches and dedupes. That is the model for `Hashable` and later coalescing.
- **Elm's `Cmd` with arguments:** the effect is a value built by the update function.
- **ZIO's environment `R` and Haskell mtl's `HasX` classes:** capabilities named in the type, provided once.
- **TCA's `@Dependency`**, the alternative the maintainer turned down: a task-local, implicit and checked only at run time.

## 8. Questions for the maintainer

| # | Question | Options | Recommendation |
|---|---|---|---|
| R-Q1 | How the land definition carries `Services` | (a) a second generic parameter, `LandDefinition<State, Services>`: compile-time all the way to registration, but `LandDefinition<` appears 247 times in Sources/Tests/Examples, and `LandKeeper`, `LandManager` and `NIOLandServer` follow; (b) `LandDefinition<State>` keeps one parameter and stores the services type erased. The DSL checks each resolver against `Services` at compile time. Registration takes a typed factory and checks once, at startup, that its type is the definition's | **(b).** The check that matters, a resolver against the land's capabilities, is still compile-time. A wrong factory type fails at server start, not per request. It avoids a rename across the codebase |
| R-Q2 | Records from before this format | (a) replayable: a missing `request` skips the equality check, and outputs are mapped from today's derived names to positions; (b) not replayable: raise `minimumReplayable` | **(b)**, as K1-Q1 recommends for 3.6: no external users, and (a) keeps today's derived-name code alive for old records only |
| R-Q3 | May a land's `Services` hold a `DeterministicRngService`? | (a) allowed: it is the user's own RNG, not the land's, and its draws are outside world; (b) refused at registration, so nobody mistakes it for the land's | **(a)**, with the docs saying the land's RNG is reachable only in handlers and builders |
| R-Q4 | When R1 lands | (a) after #700's K4, right before K5 (the plan's order); (b) as soon as P3, P4 and #771 are in, before #700's K slices | **(b)** if #771 is ready first: R1 changes no keeper flow, and it shrinks K5's diff. (a) if the maintainer wants one public break for resolvers |
