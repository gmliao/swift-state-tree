# A failure policy for OnInitialize's resolvers (#238)

Status: open. Rev 1, for Review.

## Decision (maintainer, 2026-11-07)

Option C of #238: a per-definition choice of what a **throwing** OnInitialize resolver does, defaulting to failing the land's initialization. `RESOLVER_INIT_TIMEOUT_MS` stays at 30 s (#241 closed).

## Today

`LandKeeper.performInitialization` runs the OnInitialize resolvers through `ResolverExecutor.executeInitializeResolvers`:

- **Timed out** (`ResolverExecutionError.timedOut`, #237): the initialization fails. `initializationFailure` is set, OnInitialize doesn't run, and `tearDownAfterFailedInitialization` drains the land without its destroy handlers. Every waiter gets `LandInitializationError`, a join gets it as `JoinError.landShuttingDown` (`JOIN_DENIED`, retryable).
- **Threw** (any other error): logged, and OnInitialize runs with the context from before the resolvers. That context has **none** of the group's outputs, not only the failing resolver's, because the group's `LandContext` is never assigned. The handler can't tell a throw from an output it never requested.

## API

A new enum in `SwiftStateTree` (`Land/LandDSL.swift`, next to the OnInitialize overloads):

```swift
/// What a land does when one of its OnInitialize resolvers throws (#238). A timeout
/// (`RESOLVER_INIT_TIMEOUT_MS`) always fails the initialization.
public enum InitializeResolverFailure: Sendable {
    /// The initialization fails, as for a timeout: OnInitialize doesn't run, every waiter
    /// gets `LandInitializationError` (a join: `JOIN_DENIED`, retryable), and the land is torn
    /// down without its destroy handlers. The default.
    case failLand
    /// OnInitialize runs without the resolvers' outputs (the behaviour before #238). The
    /// handler must check for every output it reads.
    case `continue`
}
```

The three OnInitialize overloads that take `resolvers:` get a defaulted parameter between `resolvers:` and the trailing body, so the body stays a trailing closure:

```swift
OnInitialize(resolvers: ConfigResolver.self) { state, ctx in ... }                          // .failLand
OnInitialize(resolvers: ConfigResolver.self, onResolverFailure: .continue) { state, ctx in ... }
```

The resolver-less overload gets no parameter, since it has no resolvers.

It is stored as `LifetimeConfig.onInitializeResolverFailure` and `LifetimeHandlers.onInitializeResolverFailure` (default `.failLand`), next to `onInitializeResolverExecutors`, and passed through `LandBuilder`.

Why the policy sits on the directive and not on the land: it belongs to the resolvers it governs, and it can't be set without them. `.continue` follows the maintainer's example name. The alternative `.continueWithoutOutputs` says more but is longer; if Review prefers it, it is a rename in this PR only.

## Runtime

In `performInitialization`, the catch becomes one path for "the group failed":

- `timedOut`: unchanged (fails, whatever the policy).
- Another `ResolverExecutionError`, or any other error:
  - `.failLand`: the timeout's path. Log `❌ OnInitialize resolvers failed: the land is torn down`, set `initializationFailure = LandInitializationError(underlying: error)`, start `tearDownAfterFailedInitialization`, return. OnInitialize doesn't run, and no initialize lifecycle record is written (as for the timeout).
  - `.continue`: today's path. Log it, and run OnInitialize with the pre-resolver context.
- **`CancellationError`:** an initialization cancelled by the land's shutdown. It is treated as today, logged and continued, for either policy: the land is already going away, and failing it would only change which error its waiters get. (To check against the shutdown path while implementing; if it turns out to matter, follow the timeout.)

`LandInitializationError`'s doc and `underlying` doc widen from "timed out" to "timed out, or threw under `.failLand`".

Out of scope: **OnInitialize's handler throwing**, as opposed to a resolver. It is still logged, with the land serving. That isn't what #238 asks, and changing it would be a second behaviour change; a separate issue if wanted.

Re-evaluation is unaffected: it replays recorded outputs, and a land that failed its initialization recorded none.

## Compatibility

The default changes behaviour: a land whose OnInitialize resolver throws today keeps serving with missing outputs, and after this PR it is torn down, with joins denied as retryable. There are no such lands in `Examples/`: no example declares OnInitialize resolvers. In `Tests/`, four definitions use `OnInitialize(resolvers:)`, and none relies on a throw. The release note and `docs/core/resolver` (en, zh-TW) say so, and say to opt out with `onResolverFailure: .continue`.

## Tests

In `Tests/SwiftStateTreeTests/ResolverDeadlineTests.swift`, next to the init-timeout tests (or `LandManagerFailedInitializationTests` for the drain):

1. **A throw fails init by default.** A resolver that throws: OnInitialize doesn't run, and a join throws `JoinError.landShuttingDown`. A later action awaiting init gets `LandInitializationError` with the resolver's error as `underlying`. The land drains without OnFinalize or OnDestroyWhenEmpty. `resolverInitTimeouts` doesn't move, since it wasn't a timeout.
2. **`.continue` runs OnInitialize without the output.** The same resolver with `onResolverFailure: .continue`: OnInitialize runs, its context has no output for the resolver, the join succeeds and the land serves.
3. **A timeout is unchanged under `.continue`.** A stuck resolver with `.continue` still fails init at the (test-shortened) deadline. The existing timeout tests cover the default.
4. **DSL:** the default is `.failLand`, and the parameter reaches `LandDefinition`.

Mutations to check: the policy ignored (always continue; always fail); `.failLand` without the teardown; the timeout gated on the policy.

## Docs

- `docs/core/resolver.md` and `.zh-TW.md`, in the table at "OnInitialize (a resolver throws)": the default fails the initialization like a timeout, and `onResolverFailure: .continue` keeps the old behaviour, with no outputs at all, not only the failing one's.
- `docs/core/land-dsl.md` and `.zh-TW.md`: one line on the parameter where OnInitialize with resolvers is shown.

## PR

One core PR, branch `feat/init-resolver-failure-policy`, after #243 (#242) merges.
