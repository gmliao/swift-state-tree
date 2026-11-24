# #769: a resolver is a PlainData value

**Status:** rev 2, plan only, no code. It follows the maintainer's 2026-11-22 decisions on #769 (the issue body, then three comments: `currentState` removed, the value form, and capability protocols for dependencies), and R-Q1 as decided 2026-11-24 (§3.4). Rev 2 answers Review's NOT GO on rev 1 (1ee8b88f); what changed is listed in §9. Open questions are in §8.

Code pointers are at main c9f149ad. `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`. The dependency probe in §3.4 is a one-file probe kept outside the repository. It passed on Swift 6.4.2 and 6.4.3, without the real `@PlainData` (§3.1.1). **The pin is moving to 6.4.3** (a bump PR is in flight), so R0 probes on 6.4.3 as the target toolchain, in the pinned image once the bump lands. If the bump hasn't landed when R1 starts, R0 also probes on 6.2.4, since CI still gates on it.

## 1. What changes

A resolver is no longer a type with a static `resolve(ctx:)` that reads what it wants from a context. It is a **value**: a `PlainData` struct whose fields are its parameters. The land builds it **in the turn that admits the input**, at the handler's declaration, from the State and the input. Off the actor, `resolve` sees only its own fields and the dependencies it declares.

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

Land("cart", using: CartState.self, services: AppServices.self) {   // TypedLand<CartState, AppServices>
    Rules {
        HandleAction(UpdateCart.self,
                     resolvers: { state, action, ctx in      // at admission, synchronous
                         state.productCache[action.productID] == nil
                             ? ProductInfo(productID: action.productID) : nil
                     }) { state, action, info, ctx in        // info: ProductInfoOutput?
            …
        }
    }
}
```

`ProductInfo<D>` is `PlainData` for every `D` only after the macro change in §3.1.1. Today's macro makes it `PlainData` only where `D: PlainData`, and a services type holds references, so it never is.

Each piece answers a defect of today's form:
- **`ResolverContext` is removed** (ResolverContext.swift:37–95). Today a resolver gets `currentState` (a type-erased whole-State snapshot), `actionPayload` / `eventPayload` (`any Sendable`, cast with `as?`), and `services`. It works out for itself what to fetch, and nothing records what it asked for.
- **The effect depends only on its request and the outside world**, never on the keeper's current state. A value the resolver needs from State or the session (`playerID`, `landID`) is copied into a field when the value is built.
- **The record holds what was asked.** The value is `PlainData` and `Codable`, so the record stores it beside the output. A replay rebuilds the value at the same point, checks it equals the recorded one, and feeds the recorded output without calling `resolve`.
- **Dependencies are checked at compile time.** `LandServices.get(_:)` (Types.swift:132) returns an optional and fails at run time. A missing capability now fails at the declaration.
- **Outputs are typed.** Today a handler reads `ctx.productInfo` through `@dynamicMemberLookup` (LandContext.swift:301): a name derived from the resolver's type name (`convertResolverTypeToPropertyName`, ResolverExecutor.swift:242), cast to the type the handler asks for, `nil` on a mismatch. The handler now gets the outputs as parameters, in declaration order.

## 2. Inputs and order

| From | What this plan takes | Why |
|---|---|---|
| PlainData P3 | typed payloads (the builder closure gets the typed action); `ResolverOutput` refines `PlainData` | the builder reads `action.productID`; the output is held in the model |
| PlainData P4 | `State` is `PlainData` | the builder reads State in the turn |
| `@PlainData` (P1/P2's macro) | a generic parameter is constrained only when stored content names it (§3.1.1) | a resolver generic over its dependencies is `PlainData` |
| #700 K5 | resolvers as keyed requests on the core (#700 §3.4): an action's request under its entry's key or `.land`, OnInitialize under `.initialization`. Admission is a step, so it has a position in the record (§3.5) | the value is the request's payload. #769 lands **with K5** (the issue's "with #700's action slice") |
| #700 K2 | the per-player services table, and its OnLeave test (§3.4) | R3 changes what that test asserts |
| #700 K6 | CanJoin, OnJoin, OnLeave requests | §6 R3 |
| #771 | the rules builders generic over State, closures without annotations, done by a throwaway codemod. Its D1 adds `Land(_:using:services:)`, returning `TypedLand` and inert until R1 | every `HandleAction(…, resolvers:)` call site changes once, for both (#771's "Order") |
| #765 | a resolver drawing from the land's RNG makes replay diverge | §3.6 |
| #773 | the determinism lint, and its L-Q2 on where the land's RNG state lives | §3.6 states the same rule for randomness as #773 |
| #768 | the machine's immutable behavior | the builder closures live in the land definition, which steps reach through it |

**Order:** P3 → P4 → (#700 K1a … K4) → **R1 with #771** → **R2 with K5** → R3 with K6. R0 (probes) can run now. The macro change (§3.1.1) goes before R1.

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
- **The resolver's name** is the base type name without generic arguments (`ProductInfo`, not `ProductInfo<AppServices>`). This holds in `ResolverExecutionError.resolverFailed(name:)`, in the deadline's `timedOut(names:)`, and in the record's name field (§3.5).

### 3.1.1 `@PlainData` on a type generic over something it doesn't store

Today `@PlainData` writes `where T: PlainData` for **every** generic parameter (PlainDataMacro.swift:34). A resolver generic over its dependencies stores no `D`, but `D` is a services type that holds references. So `ProductInfo<AppServices>` isn't `PlainData`, and it can't satisfy `Resolver: PlainData`.

**The change (recommended): constrain only the parameters that stored content names.** The macro writes `T: PlainData` for a generic parameter only when a stored property's type, or an enum case's associated value, names it:
- **Named** means the parameter's name appears as a type identifier anywhere in the annotation: `D`, `[D]`, `Box<D>`, `D.Element`. The macro already requires every stored property to have an annotation (PlainDataMacro.swift:47–48), so there is no inferred type to miss.
- **Conservative for what the macro can't see through:** a field whose type names a typealias or a nested type declared in the same body constrains **every** generic parameter, since either can capture any of them.
- A parameter named nowhere in stored content gets no constraint. The value holds nothing of that type, so it is plain data for every argument.
- The `_plainDataCheck` lines don't change. They still check each field's type, so a field of type `D` still fails to compile unless `D: PlainData`.

Constraining the fields' types instead (`where [D]: PlainData`, "perfect derive") isn't expressible: a Swift `where` clause needs a type parameter or an associated type on the left. Constraining by parameter is what serde's derive does: it bounds the type parameters that fields use.

**The alternatives:**
- An explicit opt-out (`@PlainData(unconstrained: D)`). It is a second spelling of the same fact, and the macro would still have to check that `D` isn't stored.
- `Dependencies` not generic (`any HasProductDatabase`). This loses the compile-time check: no Swift constraint says "`Services` conforms to the protocol that `R` names".

**R0 probes it with the real macro** (P1/P2's `@PlainData`, not a stand-in), on the toolchains in the header:
- `ProductInfo<AppServices>` is `PlainData` with a class-holding `AppServices`;
- `struct Box<T> { let t: T }` with a class `T` still fails, naming the field;
- the nested-type and member-typealias cases constrain everything;
- `Codable` and `Hashable` synthesis on the generic resolver.

The macro change is a small core PR before R1, with its own macro tests and must-not-compile snippets. A mutant that drops the "named" check (no constraint at all) must fail the `Box<T>` snippet.

### 3.2 The builder closure: in the turn that admits the input

```swift
HandleAction(A.self,
             resolvers: (State, A, ValidateContext) -> R?,
             _ body: (inout State, A, R.Output?, LandContext) -> A.Response)
```

- **It runs where today's code captures the snapshot:** `startActionJob`, LK:2289, in the intake segment, with `tickId: lastCommittedTickId`. After K2 that is the admission step. It reads State, the typed input and a read-only context. It mutates nothing.
- **The context is `ValidateContext`** (#586): read-only, with `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`, `isGuest`, `metadata`, `tickId`. It has no `random` (§3.6). No new context type.
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
- **Replay decode (#707)** moves with them. Today the subscript decodes an `AnyCodableResolverOutput` with the record's codec when the handler asks. Now the replay decodes **all** of an input's recorded outputs into their `R.Output` types before the handler runs, with the same codec (`RecordPayloadSource`, or K1a's bytes):
  - **An output that doesn't decode is a divergence.** It is reported as a pass mismatch (`recordedPassMismatches`, LK:4194) naming the input's sequence, the output's position, the resolver's name and the decode error.
  - **Nothing is applied.** The decode finishes for every output before the handler is called, so one bad output means the handler never runs: no state change and no partial apply. The input counts as refused in the replay, and that refusal is reported by the mismatch above, not as a silent `nil`.
  - **The test** records two resolvers, one output good and one with a wrong-typed field. The handler isn't called, State is unchanged, and the mismatch names position 1. The control, both outputs good, applies.

### 3.4 Dependencies: capability protocols, checked at compile time

- **A land declares its services type:** `Land("cart", using: CartState.self, services: AppServices.self)`. Lands without resolver dependencies use `NoServices`, an empty struct.
- **How the definition carries `Services` (R-Q1, decided 2026-11-24: option (c)):**
  - `LandDefinition<State>` keeps one generic parameter.
  - `Land(_:using:services:)` returns a thin `TypedLand<State, Services>` that holds `.definition`.
  - `Land(_:using:)` without services still returns `LandDefinition<State>`, so the existing `makeLand() -> LandDefinition<X>` functions stay.
  - `register(_: TypedLand<State, Services>, services: (LandID, [String: String]) -> Services)` is the only registration that takes it, so a wrong factory type fails to compile.
  - The no-services `register(LandDefinition)` stays. It doesn't accept a `TypedLand`.
  - Main's probe (6.4.2, a stand-in for `@PlainData`) runs the positive case and refuses the wrong factory, the missing capability and the untyped registration. **R0 re-runs it with the real `@PlainData`** (§3.1.1).
- **Lands that declare services at main:** one, GameDemo's `ResolverTest.makeLand()` (ResolverTestLand.swift:363). Its three resolvers (`JoinCheckResolver`, `LeaveCheckResolver`, `ServiceCallResolver`, lines 313–350) read `SimulatedExternalService`. No resolver in `Tests/` reads services. The test resolvers that build a `ResolverContext` by hand pass an empty `LandServices()`. Its return type becomes `TypedLand<ResolverTestState, ResolverTestServices>`. It has 10 call sites in 7 files:
  - registration in `GameServer/main.swift`;
  - the replay factory (`GameReevaluationFactory.swift`, `ReevaluationRunner/main.swift`), `SchemaGen/main.swift` and the schema fingerprint test add `.definition`. A replay never calls `resolve` (§3.5), so a replay keeper needs no `Services`;
  - the live keepers in `ResolverTestLandTests.swift` (3) and `TickProbeTests.swift` (1) need the services value. They use a typed keeper initializer, `LandKeeper(land: TypedLand<State, S>, resolverServices: S, …)`.
  
  A live keeper built from `.definition` alone, for a land that declares services, is refused when it's created: a precondition naming the land and its services type. That is the one run-time check left, and only a hand-built keeper reaches it. R0 probes the typed initializer next to the registration.
- **The builders are generic over `Services` too:** #771 makes them `RulesBuilder<State>`, and this plan adds a second parameter, `<State, Services>`, so each entry knows the land's services type.
- **The declaration requires `R.Dependencies == Services`.** So `D` is inferred at the declaration: the user writes `ProductInfo(productID:)`, never `ProductInfo<AppServices>`. A missing capability fails to compile there: "generic struct 'ProductInfo' requires that 'ThinServices' conform to 'HasPriceCache'" (the probe's text on 6.4.2).
- **A resolver sees only what it declares.** `resolve` gets `D`, constrained to the protocols it lists with `&`. Its body can use those members only.
- **Tests pass fakes:**
  - a resolver's unit test calls `ProductInfo<FakeDB>(productID:).resolve(FakeDB())`;
  - a land test builds the land from a function generic over its services (`makeCartLand<S: HasProductDatabase>(services: S.Type)`) and passes a fake.
- **Two things don't change:**
  - **Handlers' `ctx.services`** (`LandServices`) stays for handlers. The monitor and replay lands use it (ReevaluationMonitorLand.swift, GenericReplayLand.swift), as do `ctx.random`, the recorder service, GameDemo's `TickProbe` and `InputProbe` (read in handlers, ResolverTestLand.swift:392, VisibilityTestLand.swift:372), and `TwoPhaseHandlerTests`' validate (line 103). A follow-up issue can type it the same way.
  - **Per-join `services:`** on `LandKeeper.join` (LK:1724) stays for handlers. Resolvers stop seeing it, from R3 on (next bullet). The transport always passes an empty `LandServices()` (TransportAdapter.swift:2239). No test passes a non-empty one to `join`.
- **Per-join services and #700's K2.** #700 K2 stores the per-player overrides in a table keyed by `(PlayerID, EntryID)`. Its leave step puts the outgoing override into the OnLeave resolver's effect, and K2 tests that "the OnLeave resolver sees the leaving player's override" (#700 plan §3.1, `services` row, and §6 K2). That stays true through K5, because R1 and R2 keep today's merged context for CanJoin, OnJoin and OnLeave. R3, with K6, moves those three to values with the land's `Services`. From then on the override is visible to the leave's handlers only, and R3 rewrites the K2 test to assert that: the OnLeave **handler** sees the override, and the resolver gets the land's `Services`. Neither plan has a step where both rules hold at once.

### 3.5 The record and replay

- **Recorded per resolver, in declaration order:**
  - its position;
  - its name: the base type name without generic arguments (§3.1), for diagnostics;
  - the value (`request`), or that the builder returned `nil`;
  - the output.

  Both values are in the record's payload form: K1a's bytes in the header's `payloadEncoding`. This replaces `ReevaluationRecordedResolverOutput { typeIdentifier, value }` keyed by a derived property name (ActionRecorder.swift:6, :410, :749).
- **The admission point.** Live builds the value when it admits the input (§3.2), and applies the input later, after `resolve` returns (`resolvedAtTick`). State can change in between. A replay that built the value at apply would read a later State and report a false divergence. So the record says where each request was built:
  - **Where:** the admission's position, the same locator the sync outputs use (#563): on a tick land, the tick the admission observed (`lastCommittedTickId`); on a tickless land, the pass it read after (`afterPass`). After K2 the admission is a step, and its position is that step's.
  - **How:** the requests go in the frame of their admission point, as an `admitted` list (sequence, then per resolver position, name, `request` or `nil`). The apply frame carries the outputs only, keyed by sequence and position. A streaming source never has to look ahead.
- **Replay:**
  1. right after the admission point, it runs the builder closure with the replayed State and the recorded input, for each input admitted there;
  2. it compares each value with the recorded `request` at once. A difference, or a `nil` against a recorded value, is a divergence. It is reported as a pass mismatch (`recordedPassMismatches`, LK:4194) naming the input's sequence, the position and both values;
  3. at apply, it decodes every recorded output (§3.3), feeds them, and never calls `resolve`.
- **The test for the admission point,** on both land kinds:
  - an action A with a resolver whose builder reads `state.x`; its `resolve` is held at a `HoldPoints` hold;
  - while it is held, an action B without resolvers changes `state.x` and is applied;
  - A is released and applied after B. The record has A's request built from the old `x`;
  - replay reports no mismatch. A mutant that builds at apply reports one, on the request. It is caught.
- **Format:** a version after K1a's 3.7. Whether older records stay replayable is **R-Q2**.
- **R1 keeps today's record.** R1 changes how outputs reach the handler, not the record. So until R2:
  - R1 writes each output under the derived name of the resolver's base type name, as today (`convertResolverTypeToPropertyName` of `ProductInfo`, not of `ProductInfo<AppServices>`). Goldens don't change in R1;
  - R1's replay maps each recorded name to the declaration's position;
  - two resolvers of the same base type in one declaration would collide under one name, as they do today. R1 refuses that at registration, until R2's positions make it possible.

  The derived-name code goes in R2, with the new format.
- **Failures** are recorded as today: a group that fails or times out refuses the input before its record, and the init failure policy (`2026-11-07-init-resolver-failure-policy.md`) is unchanged.

### 3.6 Randomness, and #765

**The rule, the same sentence in this plan, #773's and L-Q2:** handlers draw `ctx.random` (the land's RNG, whose state moves into the model if L-Q2 (a) is decided); builders get none until admission is a recorded turn (K2/K5); resolvers use their own source, recorded.

- **Resolvers can't reach the land's RNG.** The keeper creates it (LK:1012) and registers it in `LandServices`, which handlers reach as `ctx.random`. Under §3.4 a resolver gets the land's `Services` value. The land's factory makes it, and the keeper never puts its RNG into it. That is how #765 closes by construction: the only way a resolver gets randomness is its own source, part of the outside world. Its output is recorded, and replay doesn't call `resolve`.
- **Builders draw nothing.** `ValidateContext` has no `random`, and the builder mutates nothing (§3.2). Before K2, admission isn't a turn: drawing from the land's RNG there would advance it outside turn order, which is #765 again. Once admission is a step with a recorded position (§3.5), a builder that draws could replay. Whether to allow it is a later decision, not part of this plan.
- **The test:** #765's repro, rewritten in the new form, as a regression test. Its resolver has its own RNG, and replay matches every tick. A must-not-compile snippet pins the other side: a resolver whose `Dependencies` asks for `DeterministicRngService` fails at a land that doesn't provide one. Whether `Services` may hold a `DeterministicRngService` at all is **R-Q3**.

### 3.7 What else moves

- **Examples:**
  - GameDemo's `ResolverTestLand.swift:343–349` casts `ctx.actionPayload` and reads `tickCount` from `ctx.currentState`; both become fields;
  - `ResolverTest.makeLand()` declares `ResolverTestServices` (§3.4);
  - `UserLevelResolver.swift` and `AsyncTestResolver.swift` become values;
  - `HeroDefenseLand.swift`'s declaration changes.

  Examples go in their own commit.
- **Docs** (bilingual, same commit per page): `docs/core/resolver.md`, `docs/programming-model.md`, `docs/quickstart.md`, `docs/FAQ.md`, each with its `.zh-TW.md`. `Sources/SwiftStateTree/Resolver/README.md` (in Chinese, inside `Sources/`) is rewritten in English in R1 (agreed with Main, 2026-11-24).
- **The schema:** resolver outputs aren't in the client schema today. Nothing changes there.

## 4. Public API

All breaking, with no deprecation path; there are no external users yet (the issue's "Shape and order"):
- `ContextResolver`, `ResolverContext`, `AnyResolverExecutor`, `ResolverExecutorWrapper` and `ResolverExecutor.executeResolvers(executors:resolverContext:landContext:)` are removed;
- `Resolver` is added;
- `@PlainData` stops constraining generic parameters that stored content doesn't name (§3.1.1). A type that relied on the extra constraint loses nothing: it was only ever narrower;
- every `resolvers:` parameter changes from metatypes to a builder closure, and the handler closures gain the outputs parameter;
- `LandContext`'s dynamic member subscript for outputs is removed;
- `Land(_:using:services:)`, `TypedLand<State, Services>`, `NoServices`, `register(_: TypedLand, services:)` and `LandKeeper(land:resolverServices:…)` are added (§3.4);
- `ReevaluationRecordedResolverOutput` and the record's resolver fields change in R2 (R-Q2).

## 5. Tests

**Must-not-compile** (scripts/must-not-compile/):

| Snippet | Pins |
|---|---|
| a resolver whose `D` needs `HasPriceCache` at a land whose services lack it | the probe's `requires that … conform to 'HasPriceCache'` |
| a resolver value with a class field | `@PlainData`'s refusal |
| `@PlainData struct Box<T> { let t: T }` used with a class `T` | §3.1.1: a stored parameter is still constrained |
| a builder closure that mutates State | `State` is passed immutably (`cannot assign`) |
| a builder closure that reads `ctx.random` | `ValidateContext` has no `random` (§3.6) |
| a handler reading `ctx.productInfo` | the subscript is gone |
| a resolver using a capability it didn't declare | `value of type 'D' has no member` |
| `register(_:services:)` with a factory returning another services type | R-Q1 (c) |
| the no-services `register` given a `TypedLand` | R-Q1 (c) |

**Runtime** (Swift Testing):
- the builder runs at admission: a hold at the admission step shows the value was built from the State at that step, not later;
- the admission point in the record (§3.5): State changed between admission and apply, both land kinds, replay clean;
- `nil` skips: no `resolve` call, a `nil` output, recorded as skipped;
- outputs reach the handler typed and in order, for one, two and three resolvers;
- replay equality: a recorded value that the replayed builder doesn't rebuild is reported at its admission point, with position and both values. The control replays clean;
- replay decode (§3.3): one good output and one bad. The handler isn't called, State is unchanged, and the mismatch names position 1;
- replay feeds recorded outputs: `resolve` is never called during replay (a counter in the fake);
- #765's regression (§3.6);
- a live keeper built from `.definition` of a land with services is refused at creation (§3.4);
- deadlines, abandonment and failure policy: today's suites (`ResolverDeadline*`, `ResolverFeasibilityTests`, the init failure policy tests) ported to the new form and unchanged in what they assert.

**Mutants:**
- M1: replay skips the equality check. Caught by the replay-equality test;
- M2: replay calls `resolve` instead of feeding the record. Caught by the fake's counter;
- M3: the builder runs after the resolvers instead of at admission. Caught by the hold test;
- M4: outputs are passed in reverse order. Caught by the two-resolver ordering test;
- M5: replay builds at apply instead of after the admission point. Caught by the admission-point test;
- M6: replay decodes outputs lazily and calls the handler with the good one. Caught by the decode test;
- M7: the macro constrains no generic parameter. Caught by the `Box<T>` snippet.

**Harness and E2E:** in R2, every golden with a resolver changes its record (the new fields), classified by a new class in `classify-golden-changes.py`, added in a tool-only commit first; frames don't change. R1 changes no golden (§3.5). E2E record/replay in three encodings and the game's reevaluation E2E end with 0 mismatches.

## 6. Slices

| Slice | Content | After | Measurement |
|---|---|---|---|
| **R0** | Probes on 6.4.3, the pin after the bump (and on 6.2.4 too if the bump hasn't landed when R1 starts), all with the real `@PlainData`: §3.1.1's cases; the dependency probe (positive and missing-capability cases); Main's R-Q1 (c) probe with the typed keeper initializer; their combination with #771's generic builder and `D`'s inference through the builder closure's return; the parameter pack of §3.2. Results go in this plan; no library code | now | none |
| **macro** | §3.1.1's change to `@PlainData`, its macro tests, must-not-compile snippets and M7 | R0 | none |
| **R1** | `Resolver`, `TypedLand` and the registration (§3.4), the builder closures at admission and typed outputs, `ResolverContext` deleted for actions, OnInitialize and OnFinalize, every call site migrated with #771's codemod, Examples, docs. Resolvers still run as today's jobs (the value replaces the snapshot). The record is today's (§3.5) | P3, P4, R0, macro, #771's builders | the resolver cell: an action with one resolver, live, A/B against main |
| **R2** | The record and replay (§3.5): the admission point, requests and positions, eager decode; #765's regression. With K5, so the value is the keyed request's payload | R1, K1a, K5 | the record part of the goldens; frames none |
| **R3** | CanJoin, OnJoin and OnLeave carry values with the land's `Services`; per-join services leave resolvers, and #700's K2 OnLeave test is rewritten (§3.4). With K6 | R2, K6 | none beyond K6's |

R1 doesn't depend on #700 and could go before K1a. That is **R-Q4**.

## 7. Prior art

- **Haxl** (Facebook): data-source requests are values (GADTs) that a scheduler batches and dedupes. That is the model for `Hashable` and later coalescing.
- **Elm's `Cmd` with arguments:** the effect is a value built by the update function.
- **ZIO's environment `R` and Haskell mtl's `HasX` classes:** capabilities named in the type, provided once.
- **serde's derive bounds:** a derived impl bounds the type parameters that fields use, the rule §3.1.1 adopts.
- **TCA's `@Dependency`**, the alternative the maintainer turned down: a task-local, implicit and checked only at run time.

## 8. Questions for the maintainer

| # | Question | Options | Recommendation |
|---|---|---|---|
| R-Q1 | How the land definition carries `Services` | **Decided 2026-11-24: (c)**, `TypedLand<State, Services>` from `Land(_:using:services:)`, taken only by `register(_:services:)` (§3.4) | — |
| R-Q2 | Records from before this format | (a) replayable: a missing `request` skips the equality check, and outputs are mapped from today's derived names to positions; (b) not replayable: raise `minimumReplayable` | **(b)**, as K1-Q1 decided for 3.6: no external users, and (a) keeps today's derived-name code alive for old records only |
| R-Q3 | May a land's `Services` hold a `DeterministicRngService`? | (a) allowed: it is the user's own RNG, not the land's, and its draws are outside world; (b) refused at registration, so nobody mistakes it for the land's | **(a)**, with the docs saying the land's RNG is reachable only in handlers (§3.6) |
| R-Q4 | When R1 lands | (a) after #700's K4, right before K5 (the plan's order); (b) as soon as P3, P4 and #771 are in, before #700's K slices | **(b)** if #771 is ready first: R1 changes no keeper flow, and it shrinks K5's diff. (a) if the maintainer wants one public break for resolvers |

## 9. Revisions

**Rev 2** answers Review's NOT GO on rev 1 (at 1ee8b88f: 3 must-fix, 3 should, 1 nit), and records R-Q1.
- **MF1** (`@PlainData` constrains every generic parameter): new §3.1.1. Recommended: constrain only the parameters that stored content names. The alternatives and the R0 probe with the real macro are listed; a macro slice goes before R1; M7.
- **MF2** (live builds at admission, replay built at apply): §3.2 and §3.5. The record holds each request in its admission point's frame; replay builds right after that point and compares there; a test with State changed in between, on both land kinds; M5.
- **MF3** (§3.6 let the builder draw `ctx.random`, against §3.2): that way is dropped. Builders draw nothing; resolvers use their own recorded source; #765 closes by construction through that way alone. The randomness sentence is shared with #773 and L-Q2.
- **Should, per-join services against #700 K2:** §3.4, last bullet. K2's OnLeave test stands until R3, which rewrites it.
- **Should, R1 against R2 record:** §3.5. R1 keeps today's record, with the derived name taken from the base type name and mapped to positions. Duplicate base types in one declaration are refused until R2.
- **Should, eager decode:** §3.3. Every output is decoded before the handler runs; a failure is a pass mismatch at that point, and nothing is applied. Test with one good and one bad output; M6.
- **Nit:** the base type name without generic arguments is pinned for the record's name field too (§3.1, §3.5).
- **R-Q1 (c)**, decided: §3.4. It counts the lands that declare services (one, GameDemo's, 10 call sites), and adds a typed keeper initializer for live keepers built in tests.
