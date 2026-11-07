---
module: SwiftStateTree
date: 2026-11-07
problem_type: gotcha
component: resolver-executor
symptoms:
  - "`catch is CancellationError` around a resolver call never matches, although a resolver threw a cancellation"
  - "A resolver's own CancellationError (a cancelled HTTP request) is treated as a shutdown, so the land serves without the resolver's outputs"
  - "A special case for one error type around `ResolverExecutor` is silently dead code"
root_cause: resolver_group_wraps_every_error_so_type_checks_on_the_bare_error_miss
resolution_type: design_rule
severity: medium
tags:
  - resolver
  - error-handling
  - cancellation
  - initialization
related:
  - "#237"
  - "#238"
---

# Resolver errors arrive wrapped: unwrap before you classify them

## Problem

#238 makes a throwing OnInitialize resolver fail the land's initialization by default (`onResolverFailure: .failLand`), but exempts a cancellation caused by the land shutting down. The first design matched that cancellation with a bare `catch is CancellationError`. That check would never have matched: a resolver's error doesn't reach the caller as it was thrown.

## Root cause

`ResolverExecutor.runGroup` (`Sources/SwiftStateTree/Resolver/ResolverExecutor.swift`) runs a group's resolvers in a task group, and wraps every error a resolver throws as `ResolverExecutionError.resolverFailed(name:underlyingError:)`. The caller of `executeResolvers` / `executeInitializeResolvers` sees:

- `resolverFailed(name:underlyingError:)` for any error a resolver threw, `CancellationError` included;
- `multipleResolversFailed([...])` only if a resolver itself throws it (`runGroup` never does), and then wrapped in `resolverFailed`;
- `timedOut(names:after:)` from the deadline (#237);
- a bare `CancellationError` only when the **caller** was cancelled (the deadline race returns at once).

A type check on the bare error therefore distinguishes "the caller was cancelled" from "a resolver threw", but cannot see what a resolver threw.

The second half of the trap is the opposite mistake. Unwrapping everything and exempting every cancellation would let a resolver's own `CancellationError`, such as a cancelled HTTP client, bypass the policy, and the land would serve with missing data.

## Fix

`ResolverExecutionError.isCancellation(_:)` (`Sources/SwiftStateTree/Resolver/ResolverContext.swift`) unwraps `resolverFailed` recursively. It treats a `multipleResolversFailed` as a cancellation only when every failure in it is one. The OnInitialize decision (`LandKeeper.initializeResolverFailureFailsLand`) exempts a cancellation only while the land is actually shutting down (`isDraining || Task.isCancelled`). Any other cancellation follows the policy. `InitializeResolverFailureTests` covers both: a resolver's own `CancellationError` outside a shutdown fails the initialization, and the decision function is tested for wrapped, bare, all-cancelled and mixed errors.

## Prevention

- **Unwrap first.** Before you classify an error from `ResolverExecutor`, unwrap it with `ResolverExecutionError.isCancellation`, or switch on `ResolverExecutionError`. Never use `is SomeError` on the bare error, unless you mean the caller's own cancellation.
- **Gate exemptions on state, not on the error type.** An exemption keyed on an error type should also check a state that proves its premise, such as "the land is shutting down". Otherwise a resolver can trigger it for unrelated reasons.
- **Test the wrapped form.** A test should throw the error from inside a resolver, so it arrives wrapped, not construct the bare error at the call site.
