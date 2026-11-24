# #771: handler closures infer their types; the payload type is written once

**Status:** rev 2.1, plan only, no code. D0's probes and build baseline are done (§5); D-Q1 to D-Q3 are decided, D-Q4 is open. It follows the maintainer's 2026-11-22 decision on #771, and it is aligned with the #769 plan (`2026-11-24-resolvers-as-values.md`, rev 2): the builders are generic over `<State, Services>` from the start, and `Land(_:using:services:)` returns #769's `TypedLand` (R-Q1 (c), decided 2026-11-24). Review gave rev 1 a GO (1ee8b88f) with 5 shoulds and 2 nits; rev 2 folds them in (§9). Open questions are in §8.

Code pointers are at main 13390afb. `DSL` is `Sources/SwiftStateTree/Land/LandDSL.swift`; `LB` is `Sources/SwiftStateTree/Land/LandBuilder.swift`. The issue's probe ran on Swift 6.4.2. The pin is moving to 6.4.3 (a bump PR is in flight), so D0 probes on 6.4.3, and on 6.2.4 too if the bump hasn't landed when D1 starts.

## 1. What changes

```swift
// Today
HandleAction(BuyUpgradeAction.self) { (state: inout CookieGameState, action: BuyUpgradeAction, ctx: LandContext) -> BuyUpgradeResponse in … }
CanJoin { (_: CookieGameState, session: PlayerSession, _: LandContext) in … }
ClientEvents { Register(Chat.self) }
HandleEvent(Chat.self) { (state: inout CookieGameState, event: Chat, ctx: LandContext) in … }

// After
HandleAction(BuyUpgradeAction.self) { state, action, ctx in … }
CanJoin { state, session, ctx in … }
HandleEvent(Chat.self) { state, event, ctx in … }        // registers Chat itself
```

- **Root cause:** `LandDSL` isn't generic (DSL:974). `buildBlock(_ components: LandNode...)` gives a closure no contextual State, so each closure annotates State and, with it, every other parameter.
- **The fix:** the builders become generic over the land's State (and, for #769, its Services) and take each node through a typed `buildExpression`. The entry's return type then fixes `State`, and the closure infers the rest.
- **The payload metatype stays,** as the one place the payload type is written.
- **Client events register themselves:** `HandleEvent(X.self)` registers `X`. A client event registered without a handler is refused at every intake today (§3.3), so D-Q4 decides whether `ClientEvents { Register(X.self) }` without a handler stays legal. Server events keep `ServerEvents { Register(…) }`, since they have no handler.
- **Annotated closures keep compiling.** The migration only removes annotations; a closure it can't match stays as it is.

## 2. Inputs and order

| From | What | Why |
|---|---|---|
| #769 plan | the builders carry `Services`; `Land(_:using:services:)` returns `TypedLand<State, Services>` (R-Q1 (c)); `NoServices` | one generic shape for both issues. D1 adds `Services` as a parameter that nothing reads yet, and `TypedLand` with only its `.definition`: both are inert until #769's R1 adds the resolver entries and the registration that use them |
| #769 macro slice | `@PlainData` constrains only the generic parameters stored content names (#769 §3.1.1) | the codemod's `{ _, _, _ in X() }` builds a resolver generic over its dependencies, which is `PlainData` only after it |
| #769 R1 | every `resolvers:` call site changes | **the codemod runs once for both** (D2 with R1), so each call site changes once (#771's "Order") |
| the toolchain bump to 6.4.3 | D0's target | result-builder inference changes between releases |

**Order:** D0 (probes) now → D1 (generic builders; no call site changes) as soon as D0 passes → **D2 (the codemod) in the same PR as #769 R1**. D1 doesn't depend on P3 or P4. D2 waits for R1, which waits for them.

## 3. Design

### 3.1 The builders

```swift
@resultBuilder
public enum LandDSL<State: StateNodeProtocol, Services: Sendable> {
    public static func buildExpression(_ node: AnyActionHandler<State>) -> [LandNode]
    public static func buildExpression(_ node: AnyClientEventHandler<State>) -> [LandNode]
    public static func buildExpression(_ node: AnyServerInputHandler<State>) -> [LandNode]
    public static func buildExpression(_ node: CanJoinNode<State>) -> [LandNode]
    public static func buildExpression(_ node: OnJoinNode<State>) -> [LandNode]
    public static func buildExpression(_ node: OnLeaveNode<State>) -> [LandNode]
    public static func buildExpression(_ node: LifetimeNode<State>) -> [LandNode]
    public static func buildExpression(_ node: RulesNode<State, Services>) -> [LandNode]
    public static func buildExpression(_ node: AccessControlNode) -> [LandNode]
    public static func buildExpression(_ node: AllowedClientEventsNode) -> [LandNode]
    public static func buildExpression(_ node: ClientEventsNode) -> [LandNode]
    public static func buildExpression(_ node: ServerEventsNode) -> [LandNode]
    public static func buildBlock(_ parts: [LandNode]...) -> [LandNode]
    // buildArray, buildOptional, buildEither as today, over [LandNode]
}

public func Land<State, Services>(_ id: String, using: State.Type, services: Services.Type,
                                  @LandDSL<State, Services> _ content: () -> [LandNode]) -> TypedLand<State, Services>
public func Land<State>(_ id: String, using: State.Type,
                        @LandDSL<State, NoServices> _ content: () -> [LandNode]) -> LandDefinition<State>
public func Rules<State, Services>(@LandDSL<State, Services> _ content: () -> [LandNode]) -> RulesNode<State, Services>
```

- **No catch-all `buildExpression`.** One per node type. A generic `some LandNode` overload would accept a node for another State, and inference would lose its anchor.
- **A wrong-State node becomes a compile error.** Today `LandBuilder` matches nodes with casts such as `case let canJoinNode as CanJoinNode<State>` (LB:61), so a node built for another State type matches no case and falls to `default: continue` (LB:141): it is **silently dropped**. With typed `buildExpression`, it doesn't compile. A must-not-compile snippet pins it.
- **Nested blocks:** `Rules` is generic, and its `State` and `Services` come from the outer builder's `buildExpression(RulesNode<State, Services>)`.
- **`Rules` is flattened in `buildExpression`,** which returns `node.nodes`. Today `LandBuilder.build` flattens it with `case let rules as RulesNode` (LB:57). Once `RulesNode` is generic, that cast would have to name `Services`, which `LandBuilder` (generic over `State` only) doesn't know. A `RulesNode<State, Services>` that reached it would match no case and be dropped like a wrong-State node (LB:141), with every handler inside. Flattening in the builder means no `RulesNode` reaches `LandBuilder`, and its case is deleted. The other way, a non-generic `NestedNodes` protocol that `LandBuilder` matches, keeps a run-time match that a later node type could miss. D0's nested-`Rules` probe pins it, and a runtime test checks that a handler declared inside `Rules` is in the definition (mutant: `buildExpression` returns `[node]` and the `LandBuilder` case is gone). `Lifetime`'s `LifetimeBuilder<State>` (DSL:458) is already generic. Its `State` now comes from `buildExpression(LifetimeNode<State>)` instead of from the `Tick` closure's annotation. D0 probes both nestings.
- **`LandNode` stays the stored element,** so `LandBuilder.build` and `LandDefinition<State>` don't change, apart from the `RulesNode` case leaving it. `TypedLand<State, Services>` holds the `LandDefinition<State>` (#769 R-Q1 (c)). Until R1, `Services` is only a type parameter of the builder, and a `TypedLand`'s only use is `.definition`.
- **The deprecated forms are removed in D1** (D-Q2, decided (a)): `ServerEvent(_:)` and `ServerEventNode` (DSL:1254–1272, and LandBuilder's legacy case, LB:139), and `OnShutdown` (DSL:964) with the `onShutdown` it sets (`LifetimeConfig`, `LifetimeHandlers` in LandDefinition.swift:176, and the keeper's call, LK:5955). Neither gets a `buildExpression`. Neither is called anywhere in Sources, Tests or Examples today (the matches for the names are other identifiers, such as `saveOnShutdown`).

### 3.2 The handler entries

The entries' signatures don't change. Their generic `State` is now inferred from the builder's `buildExpression` parameter instead of from the closure.

- **Single-closure and two-stage forms (#586):**
  - `HandleAction(X.self) { state, action, ctx in }` and `HandleAction(X.self, validate: { state, action, ctx in … }, apply: { state, action, plan, ctx in … })`;
  - `Plan` is inferred from `validate`'s return, including from a multi-statement closure (SE-0326). D0 probes it with a `guard … throw` before the return.
- **The same for** `HandleEvent`, `HandleServerInput` (ServerInput.swift:140–166), `CanJoin`, `OnJoin`, `OnLeave`, `OnInitialize`, `OnFinalize`, `AfterFinalize`, `Tick`, `StateSync`, `DestroyWhenEmpty`, `PersistSnapshot`.
- **Overload pressure.** `HandleAction` has 9 overloads (DSL:1041–1168): plain or two-stage, with or without `Plan`, and with 0–2 resolvers. Without annotations, the type checker picks among them inside a result builder. D0 measures this (§5) before D1 commits to it. #769 replaces the resolver overloads with one builder-closure form per arity, which shrinks the set.

### 3.3 Client events register themselves

- `LandBuilder.ingest` appends a handler's `eventType` to `clientEventRegistrations` when it meets an `AnyClientEventHandler` (LB:96). A type listed twice is kept once (LB:182–184), so an explicit `Register` beside a handler is harmless. The codemod removes it as redundant.
- **The behavior change:** today a land with `HandleEvent(X.self)` and no `Register(X.self)` refuses every `X`. The keeper throws `LandError.eventNotRegistered` (LK:3102–3110), and `X` is missing from the schema (SchemaExtractor.swift:130). After D1, `X` is accepted and in the schema. No test expects `eventNotRegistered` today (0 matches in `Tests/`). The codemod lists every land in this case, so its schema change is seen.
- **An event registered without a handler is refused at every intake.** The keeper finds its descriptor, then finds no handler and throws `eventNotRegistered` (LK:3115). So a `Register(X.self)` with no `HandleEvent(X.self)` only puts `X` in the schema, for a client that can never send it. No land in Examples does this. About 15 test lands do (a file-level match, `Register(X.self)` in `ClientEvents` with no `HandleEvent(X.self)` in the file), for schema, fingerprint and registration tests. **D-Q4** decides between refusing it at registration (those tests add a no-op handler) and documenting it.
- **`AllowedClientEvents`** is unchanged: it lists events the transport may reject early, which is a separate thing.
- **The schema of a land whose events are all handled** is unchanged. The registry is ordered by registration, so self-registration has to keep each land's order. Rule: explicit `Register`s first, in their order, then handled events not already listed, in declaration order. That keeps every current land's schema byte-identical. A codegen diff over `Examples/*/schema.json` checks it.

## 4. The codemod (shared with #769)

A throwaway SwiftSyntax tool. It is not part of the library and not a product of `Package.swift`.

- **Where it lives:** in its own package under `Tools/Codemods/DSL/`, committed in D2's PR so Review can read it, and deleted in that PR's last commit (D-Q1, decided (a)).
- **#771's rewrites:**
  - strip parameter and return-type annotations from closures passed to the entries in §3.2. A parameter named `_` stays `_`;
  - remove a `Register(X.self)` that duplicates a `HandleEvent(X.self)` in the same land, and a `ClientEvents { }` left empty by that.
- **#769's rewrites, mechanical part only:**
  - `resolvers: X.self` whose resolver reads none of `actionPayload`, `currentState` and `services` (checked on its declaration) becomes `resolvers: { _, _, _ in X() }`. This form needs #769's macro slice: `X` is `PlainData` only once `@PlainData` stops constraining a dependency parameter it doesn't store;
  - the handler gains an output parameter named after the old dynamic member, and `ctx.<name>` reads in its body become that parameter.

  Resolvers that read the payload, State or `ctx.services` are **listed, not edited**: making them values, or giving them a `Dependencies` type, is a design change per resolver (#769 §3.4, §3.7).
- **Where it stops:** a closure it can't match (a closure passed through a variable, a helper that builds handlers) is listed with its file and line, never half-edited.
- **A stripped closure that costs too much is restored, not tuned.** After the strip, the build runs with `-Xfrontend -warn-long-expression-type-checking=200`. A closure that no longer type-checks, or whose expression crosses 200 ms, gets its original annotations back from the tool (by file and line) and is listed in the PR body with the reason. Nobody hand-edits such a closure to make it pass; a listed site can be revisited later, on its own.
- **Verification:**
  1. the compiler;
  2. a re-run is a no-op (idempotence);
  3. reproducibility: re-running the committed tool at the PR's base reproduces commit (b) below byte for byte;
  4. `swift test` and E2E;
  5. the schema/codegen diff (§3.3).
- **D2's commits, in this order,** so Review can check the mechanical part apart from the hand-made one:
  - (a) the tool itself;
  - (b) the tool's output only. Its message says "re-running the tool at <base> reproduces this commit";
  - (c) hand fixes: the listed sites, and the restored annotations of the previous bullet;
  - (d) #769 R1's design changes: `Resolver`, the builder closures, the typed outputs;
  - (e) the tool's deletion (D-Q1).
- **Scale** (the issue's counts on main): `HandleAction(X.self` 193, `HandleEvent(X.self` 59, `HandleServerInput(X.self` 30. Annotated handler closures, matched by `(state: inout` / `(_: inout` / `(state: <Type>`: about 700, nearly all in `Tests/`. There are 279 `Land("` declarations.

## 5. Tests and measurement

**D0 probes** (6.4.3; 6.2.4 if needed), each a one-file package. Results go in this plan:
1. `HandleAction(Add.self) { state, action, ctx in }` in `Rules` in `Land`: the nesting;
2. the same for every entry in §3.2, `Tick` in `Lifetime` included;
3. the two-stage form with a multi-statement `validate`, `Plan` inferred;
4. all 9 `HandleAction` overloads in scope, in a land of 30 handlers: type-check time with `-Xfrontend -warn-long-expression-type-checking=200`. None may exceed it;
5. a node for another State: refused, with the message pinned;
6. `<State, Services>` with #769's resolver form: `D` inferred through the builder closure's return (the #769 R0 case, run once for both plans). It uses the real `@PlainData`, with #769 §3.1.1's change, not a stand-in.

**D0 results (2026-11-24).** The probes model the new shape in one module: `LandDSL<State, Services>` with a typed `buildExpression` per node and `Rules` flattened, `TypedLand`, and today's entry overload sets copied from LandDSL.swift (9 `HandleAction`, 3 `HandleEvent`, 2 `HandleServerInput`, `CanJoin`/`OnJoin`/`OnLeave`/`OnFinalize` with 0–3 resolvers, every `OnInitialize` form, and `Lifetime`'s directives). Run with `swiftc -typecheck` on Apple Swift 6.4.2 and in the pinned `swift:6.2.4-noble` image, the results were identical. 6.4.3 waits for the measurement host.

| # | Result |
|---|---|
| 1 | Compiles unannotated: a handler in `Rules` in `Land`, `Rules` in `Rules`, `Land(_:using:services:)` returning `TypedLand` (its definition's `servicesType` is the services type), and a D-Q3 helper under `@LandDSL<GameState, NoServices>`. Run: the handlers inside nested `Rules` are in the definition. With the mutant (`buildExpression` returns `[node]`), the definition holds a `RulesNode<GameState, NoServices>` instead |
| 2 | Compiles unannotated, every entry, **once `LifetimeBuilder` has a typed `buildExpression(LifetimeDirective<State>)`**. With only today's variadic `buildBlock(LifetimeDirective<State>...)`, `Tick(every:) { state, ctx in }` inside `Lifetime` fails: "cannot infer type of closure parameter 'state' without a type annotation". The outer builder's `buildExpression(LifetimeNode<State>)` fixes `Lifetime`'s `State`, but it doesn't reach a builder closure without a typed `buildExpression`. Removing `Lifetime`'s configure-closure overload doesn't help; a struct directive alone doesn't either |
| 3 | Compiles: `Plan` inferred from a multi-statement `validate` (a `guard … throw`, a local, a tuple return), for `HandleAction`, `HandleEvent`, `HandleServerInput` and `OnInitialize` |
| 4 | 30 handlers (all `HandleAction` forms) and 6 events in one land, with every overload in scope. No expression over 200 ms. Typecheck medians over 7 runs: new shape unannotated 0.461 s, new shape annotated 0.469 s, today's shape annotated 0.471 s. The slowest single expression is 4.3, 4.5 and 4.2 ms |
| 5 | Refused, with the text pinned for the must-not-compile snippet: "cannot convert value of type 'OnJoinNode<OtherState>' to expected argument type 'OnJoinNode<GameState>'". The same holds for a prebuilt node at the land's top level |
| 6 | With a stand-in `PlainData` protocol, `D` is inferred through the builder closure's return at a land with services. A missing capability is refused: "generic struct 'ProductInfo' requires that 'ThinServices' conform to 'HasProductDatabase'". **The real `@PlainData` run waits for #769's macro slice**, since today's macro constrains `D: PlainData`; it is #769 R0's |

**The build-time baseline** (for D1's and D2's gate). Taken at main c3d416d9, Apple Swift 6.4.2, debug, on the Mac that holds the build slot, in a scratch path of its own:
- a clean build of the `SwiftStateTreeTests` target, dependencies included: 155 s;
- the test module alone, rebuilt with its sources touched: 73, 70 and 65 s, median **70 s**;
- `-warn-long-expression-type-checking=200` over the tree finds two expressions, neither in the DSL. Both are `Set(frames.flatMap { a + b + c })` concatenations: ReplaySequenceWatermarkTests.swift:534 (1.8–2.0 s) and ResolverDeliveryTests.swift:220 (1.7–2.2 s). They are the baseline's, and the gate counts only new ones.

**Must-not-compile:**
- an `OnJoin` for another State type inside a land: `no exact matches in call to static method 'buildExpression'`, or D0's actual text;
- an action closure whose body assigns to a `let` `action` field: the inferred types are the real ones.

**Runtime:**
- `selfRegistersHandledClientEvent`: a land with `HandleEvent(X.self)` and no `ClientEvents` accepts `X` and lists it in the schema;
- `explicitRegisterOrderIsKept`: a land with `Register(B)`, `Register(A)` and a handler for `C` lists B, A, C;
- `nestedRulesHandlersAreKept`: a handler declared inside `Rules` (and inside `Rules` inside `Rules`) is in the definition and handles its input (§3.1);
- every existing test, unchanged in what it asserts, after the codemod.

**Mutants:**
- self-registration skipped. Caught by `selfRegistersHandledClientEvent`;
- `Rules` not flattened in `buildExpression`. Caught by `nestedRulesHandlersAreKept`.

**Build time** (the cost a user feels): the test module's rebuild, on the same machine and toolchain as D0's baseline (median 70 s), three runs each, before and after D1 and D2. The gate is a median no more than 10% slower, and no expression over 200 ms other than the baseline's two. If it is slower, the codemod keeps annotations in the files that cost the most, and those files are listed.

**Harness and E2E:** no wire or record change, so the goldens stay byte-identical. E2E in three encodings.

## 6. Slices

| Slice | Content | After | Measurement |
|---|---|---|---|
| **D0** | The probes (§5), in a scratch package; results in this plan | now | type-check times only |
| **D1** | The generic builders and typed `buildExpression`s (§3.1), `Rules` flattened in the builder, `Land(_:using:services:)` returning `TypedLand` and `NoServices` (inert until R1), client-event self-registration (§3.3) and D-Q4's answer, the wrong-State refusal. **Required by D0:** `LifetimeBuilder` gains a typed `buildExpression(LifetimeDirective<State>)`, with a test that `Tick(every:) { state, ctx in }` inside `Lifetime` compiles unannotated (D0 result 2). No call site is edited: annotated closures keep compiling. Docs show the inferred form | D0 | build time of `SwiftStateTreeTests`, before and after (no call-site change, so it isolates the builder's own cost) |
| **D2** | The codemod run over Sources, Tests and Examples, with #769 R1 in the same PR, as commits (a) to (e) (§4). The listed sites are fixed by hand | D1, #769 R1, #769's macro slice | §5's build-time gate |

Examples go in their own commit in D2. `docs/` pages that show handler closures (`quickstart`, `programming-model`, `core/*`) move to the inferred form in D1, both languages in the same commit.

## 7. Public API

- **Breaking:**
  - `LandDSL` becomes generic (`LandDSL<State, Services>`);
  - `Rules` returns `RulesNode<State, Services>`;
  - `RulesNode` gains its parameters.

  A user writing `@LandDSL` by name (a helper returning `[LandNode]`) must add the parameters. No deprecation path; there are no external users yet.
- **Removed (D-Q2):** `ServerEvent(_:)`, `ServerEventNode`, `OnShutdown`, and `onShutdown` on `LifetimeConfig` and the land's lifetime handlers. None is called in the repository. A user's `OnShutdown` moves to `AfterFinalize`, which also runs after the last turn and gets the context.
- **Added:** `Land(_:using:services:)`, returning `TypedLand<State, Services>`, and `NoServices`, which #769 also needs. Both are inert until #769's R1: nothing reads `Services`, and nothing takes a `TypedLand` except through `.definition`.
- **Behavior:**
  - a handled client event is registered (§3.3);
  - **self-registration can newly surface #599's shared-name refusal.** The registry is keyed by event name, and two registered types with one name refuse the land at registration (LB:182–184, `sharedEventNames`). Today a handled but unregistered type isn't in the registry, so it can share a name with a registered one unnoticed (its events are refused at intake instead). After D1 it is registered, and the land is refused at registration. The codemod's run lists any land this hits;
  - D-Q4's answer for a client event registered without a handler.
- **Unchanged:** every entry's name and parameter labels, the handler types, and `LandDefinition<State>`.

## 8. Questions for the maintainer

| # | Question | Options | Recommendation |
|---|---|---|---|
| D-Q1 | Where the codemod lives | **Decided 2026-11-24: (a).** Committed under `Tools/Codemods/DSL/` in D2's PR, as commit (a) of §4, and deleted in its last commit (e). Option (b), never committed and only described in the PR body, was declined | — |
| D-Q2 | The deprecated `ServerEventNode` and `OnShutdown` | **Decided 2026-11-24: (a).** Removed in D1, with no `buildExpression` (§3.1, §7). Option (b), an overload each in the generic builder, was declined | — |
| D-Q3 | A helper that returns handlers outside a `Land` (a function returning `[LandNode]` under `@LandDSL`) | **Decided 2026-11-24: (a).** The docs use the full generic `@LandDSL<MyState, NoServices>` as the standard spelling, and show a per-land typealias (`typealias MyDSL = LandDSL<MyState, AppServices>`) as the optional shorter form. The codemod lists every such helper. D0 probe 1 compiles one | — |
| D-Q4 | A client event registered without a handler, which every intake refuses (LK:3115) | (a) refused at registration, like #599's shared names; the test lands that do it (about 15, schema and registration tests) add a no-op handler; (b) a registration warning; (c) documented only | **(a):** a land that declares an event its clients can never send has a bug, and it should show at startup, not as a refusal per event. The tests that need the event only in the schema get a one-line handler |

## 9. Revisions

**Rev 2** folds in Review's GO notes on rev 1 (1ee8b88f: 5 should, 2 nits), and #769's R-Q1 (c):
- **S1** (`RulesNode<State, Services>` can't be matched by `LandBuilder`): `Rules` is flattened in `buildExpression` (§3.1); a runtime test and a mutant.
- **S2** (an event registered without a handler is always refused): §3.3 says so, with the count; D-Q4.
- **S3** (D2's commits): (a) to (e), with reproducibility at the base and idempotence (§4).
- **S4** (a stripped closure that stops type-checking or crosses 200 ms): its annotations are restored and it is listed, never tuned by hand (§4).
- **S5** (resolvers reading `ctx.services`): listed, not edited; `{ _, _, _ in X() }` waits on #769's macro slice; D0 probe 6 uses the real macro (§4, §5).
- **Nits:** `Land(_:using:services:)` is inert until R1 (§2, §7); self-registration can surface #599's refusal (§7).
- **#769 R-Q1 (c):** `Land(_:using:services:)` returns `TypedLand<State, Services>` from D1 on (§3.1).

**Rev 2.1** records D0 and the maintainer's decisions:
- **D0** (§5): every probe passes on 6.4.2 and 6.2.4. One finding is now a D1 requirement: `LifetimeBuilder` needs a typed `buildExpression` (result 2). The pressure numbers and the build baseline are D1's and D2's gate.
- **D-Q1 (a), D-Q2 (a), D-Q3 (a)**, decided 2026-11-24 (§3.1, §4, §7, §8).
