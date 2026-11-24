# #771: handler closures infer their types; the payload type is written once

**Status:** rev 1, plan only, no code. It follows the maintainer's 2026-11-22 decision on #771, and it is aligned with the #769 plan (`2026-11-24-resolvers-as-values.md`): the builders are generic over `<State, Services>` from the start. Open questions are in §8.

Code pointers are at main bb385c57. `DSL` is `Sources/SwiftStateTree/Land/LandDSL.swift`; `LB` is `Sources/SwiftStateTree/Land/LandBuilder.swift`. The issue's probe ran on Swift 6.4.2. The pin is moving to 6.4.3 (a bump PR is in flight), so D0 probes on 6.4.3, and on 6.2.4 too if the bump hasn't landed when D1 starts.

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
- **Client events register themselves:** `HandleEvent(X.self)` registers `X`. `ClientEvents { Register(X.self) }` is needed only for an event declared without a handler. Server events keep `ServerEvents { Register(…) }`, since they have no handler.
- **Annotated closures keep compiling.** The migration only removes annotations; a closure it can't match stays as it is.

## 2. Inputs and order

| From | What | Why |
|---|---|---|
| #769 plan | the builders carry `Services`; `Land(_:using:services:)` and `NoServices` | one generic shape for both issues. D1 adds `Services` as a parameter that nothing reads yet; #769's R1 adds the resolver entries that use it |
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
                                  @LandDSL<State, Services> _ content: () -> [LandNode]) -> LandDefinition<State>
public func Land<State>(_ id: String, using: State.Type,
                        @LandDSL<State, NoServices> _ content: () -> [LandNode]) -> LandDefinition<State>
public func Rules<State, Services>(@LandDSL<State, Services> _ content: () -> [LandNode]) -> RulesNode<State, Services>
```

- **No catch-all `buildExpression`.** One per node type. A generic `some LandNode` overload would accept a node for another State, and inference would lose its anchor.
- **A wrong-State node becomes a compile error.** Today `LandBuilder` matches nodes with casts such as `case let canJoinNode as CanJoinNode<State>` (LB:61), so a node built for another State type matches no case and falls to `default: continue` (LB:141): it is **silently dropped**. With typed `buildExpression`, it doesn't compile. A must-not-compile snippet pins it.
- **Nested blocks:** `Rules` is generic, and its `State` and `Services` come from the outer builder's `buildExpression(RulesNode<State, Services>)`. `Lifetime`'s `LifetimeBuilder<State>` (DSL:458) is already generic. Its `State` now comes from `buildExpression(LifetimeNode<State>)` instead of from the `Tick` closure's annotation. D0 probes both nestings.
- **`LandNode` stays the stored element,** so `LandBuilder.build` and `LandDefinition<State>` don't change. How the definition stores `Services` is #769's R-Q1. Until R1, `Services` is only a type parameter of the builder.
- **The deprecated forms** (`ServerEventNode`, `OnShutdown`, DSL:960) get a `buildExpression` while they exist, or are removed here (D-Q2).

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
- **`AllowedClientEvents`** is unchanged: it lists events the transport may reject early, which is a separate thing.
- **The schema of a land whose events are all handled** is unchanged. The registry is ordered by registration, so self-registration has to keep each land's order. Rule: explicit `Register`s first, in their order, then handled events not already listed, in declaration order. That keeps every current land's schema byte-identical. A codegen diff over `Examples/*/schema.json` checks it.

## 4. The codemod (shared with #769)

A throwaway SwiftSyntax tool. It is not part of the library and not a product of `Package.swift`.

- **Where it lives:** in its own package under `Tools/Codemods/DSL/`, committed in D2's PR so Review can read it, and deleted in that PR's last commit (D-Q1).
- **#771's rewrites:**
  - strip parameter and return-type annotations from closures passed to the entries in §3.2. A parameter named `_` stays `_`;
  - remove a `Register(X.self)` that duplicates a `HandleEvent(X.self)` in the same land, and a `ClientEvents { }` left empty by that.
- **#769's rewrites, mechanical part only:**
  - `resolvers: X.self` whose resolver reads neither `actionPayload` nor `currentState` (checked on its declaration) becomes `resolvers: { _, _, _ in X() }`;
  - the handler gains an output parameter named after the old dynamic member, and `ctx.<name>` reads in its body become that parameter.

  Resolvers that read the payload or State are **listed, not edited**: making them values is a design change per resolver (#769 §3.7).
- **Where it stops:** a closure it can't match (a closure passed through a variable, a helper that builds handlers) is listed with its file and line, never half-edited.
- **Verification:**
  1. the compiler;
  2. a re-run is a no-op (idempotence);
  3. `swift test` and E2E;
  4. the schema/codegen diff (§3.3).

  The listed sites are fixed by hand in the same PR.
- **Scale** (the issue's counts on main): `HandleAction(X.self` 193, `HandleEvent(X.self` 59, `HandleServerInput(X.self` 30. Annotated handler closures, matched by `(state: inout` / `(_: inout` / `(state: <Type>`: about 700, nearly all in `Tests/`. There are 279 `Land("` declarations.

## 5. Tests and measurement

**D0 probes** (6.4.3; 6.2.4 if needed), each a one-file package. Results go in this plan:
1. `HandleAction(Add.self) { state, action, ctx in }` in `Rules` in `Land`: the nesting;
2. the same for every entry in §3.2, `Tick` in `Lifetime` included;
3. the two-stage form with a multi-statement `validate`, `Plan` inferred;
4. all 9 `HandleAction` overloads in scope, in a land of 30 handlers: type-check time with `-Xfrontend -warn-long-expression-type-checking=200`. None may exceed it;
5. a node for another State: refused, with the message pinned;
6. `<State, Services>` with #769's resolver form: `D` inferred through the builder closure's return (the #769 R0 case, run once for both plans).

**Must-not-compile:**
- an `OnJoin` for another State type inside a land: `no exact matches in call to static method 'buildExpression'`, or D0's actual text;
- an action closure whose body assigns to a `let` `action` field: the inferred types are the real ones.

**Runtime:**
- `selfRegistersHandledClientEvent`: a land with `HandleEvent(X.self)` and no `ClientEvents` accepts `X` and lists it in the schema;
- `explicitRegisterOrderIsKept`: a land with `Register(B)`, `Register(A)` and a handler for `C` lists B, A, C;
- every existing test, unchanged in what it asserts, after the codemod.

**Mutant:** self-registration skipped. Caught by `selfRegistersHandledClientEvent`.

**Build time** (the cost a user feels): a clean debug build of `SwiftStateTreeTests` on one machine and toolchain, before D2 and after, three runs each. The gate is no more than 10% slower, and no expression over the D0 threshold. If it is slower, the codemod keeps annotations in the files that cost the most, and those files are listed.

**Harness and E2E:** no wire or record change, so the goldens stay byte-identical. E2E in three encodings.

## 6. Slices

| Slice | Content | After | Measurement |
|---|---|---|---|
| **D0** | The probes (§5), in a scratch package; results in this plan | now | type-check times only |
| **D1** | The generic builders and typed `buildExpression`s (§3.1), `Land(_:using:services:)` and `NoServices`, client-event self-registration (§3.3), the wrong-State refusal. No call site is edited: annotated closures keep compiling. Docs show the inferred form | D0 | build time of `SwiftStateTreeTests`, before and after (no call-site change, so it isolates the builder's own cost) |
| **D2** | The codemod run over Sources, Tests and Examples, with #769 R1 in the same PR. The listed sites are fixed by hand. The tool is committed, then deleted | D1, #769 R1 | §5's build-time gate |

Examples go in their own commit in D2. `docs/` pages that show handler closures (`quickstart`, `programming-model`, `core/*`) move to the inferred form in D1, both languages in the same commit.

## 7. Public API

- **Breaking:**
  - `LandDSL` becomes generic (`LandDSL<State, Services>`);
  - `Rules` returns `RulesNode<State, Services>`;
  - `RulesNode` gains its parameters.

  A user writing `@LandDSL` by name (a helper returning `[LandNode]`) must add the parameters. No deprecation path; there are no external users yet.
- **Added:** `Land(_:using:services:)` and `NoServices`, which #769 also needs.
- **Behavior:** a handled client event is registered (§3.3).
- **Unchanged:** every entry's name and parameter labels, the handler types, and `LandDefinition<State>`.

## 8. Questions for the maintainer

| # | Question | Options | Recommendation |
|---|---|---|---|
| D-Q1 | Where the codemod lives | (a) committed under `Tools/Codemods/DSL/` in D2's PR, deleted in its last commit; (b) never committed: run from a scratch package, and the PR body describes it | **(a):** Review can read what rewrote 700 closures, and history keeps it if a later migration needs the same matcher |
| D-Q2 | The deprecated `ServerEventNode` and `OnShutdown` | (a) remove them in D1; (b) give them a `buildExpression` and keep them | **(a):** each would need its own overload in the generic builder, and they are deprecated already |
| D-Q3 | A helper that returns handlers outside a `Land` (a function returning `[LandNode]` under `@LandDSL`) | (a) it writes `@LandDSL<MyState, NoServices>`; (b) a typealias per land (`typealias MyDSL = LandDSL<MyState, AppServices>`) | **(a)** in docs, with (b) shown as the shorter spelling. The codemod lists every such helper |
