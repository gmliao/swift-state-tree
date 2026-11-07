---
module: SwiftStateTree, tests
date: 2026-11-05
problem_type: testing_practice
component: concurrency-tests
symptoms:
  - "A race test passes locally and fails intermittently on CI, or never fails at all"
  - "A test needs `sleep` calls to make the bad interleaving likely"
  - "TSan reports nothing, yet the bug reproduces in production-like runs"
root_cause: timing_based_interleaving_in_tests
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - reentrancy
  - hold-points
  - determinism
  - tsan
related:
  - "#146"
---

# Force the interleaving with hold points, not timing

## Problem

Reentrancy and ordering bugs depend on another call running at one specific `await`. A test that relies on `sleep`, `Task.yield()` or "run it 1000 times" makes that interleaving likely at best; it is flaky on a loaded CI runner and silent on a fast laptop. TSan doesn't help: actor reentrancy is not a data race.

## Fix

`HoldPoints` (`Sources/SwiftStateTree/Support/HoldPoints.swift`, #146): one optional hook per instance, awaited at named points.

```swift
enum HoldPoint: Hashable, Sendable { case afterLandLookup }
var holds = HoldPoints<HoldPoint>()
...
await holds.at(.afterLandLookup)
```

- The test installs a hook that suspends at the point, issues the competing call, then releases the hook.
- With nothing installed it is a single `nil` check and doesn't suspend, and it runs on the caller's executor (`isolation: isolated (any Actor)? = #isolation`), so production code before and after the point stays one synchronous segment. A plain nonisolated `async` method would hop off the actor there and open a reentrancy window in production.
- Tests combine it with a gate (for example `TestGate`) to wait until the held code has reached the point before issuing the competing call.

## Prevention

- Every reentrancy or ordering fix gets a test that holds the code at the `await` where the race happens. Without the fix the test fails every time, not sometimes.
- Check the test with mutations: remove the fix's check or mark and confirm the test fails.
- Assert the precondition that makes the interleaving meaningful (for example, that an entry was evicted before the admission runs), so a test can't pass because the setup didn't happen.
- No `sleep`-based waits in race tests (`CLAUDE.md` § Reentrancy: "Tests force the interleaving with a hold at the `await` (`HoldPoints`, `TestGate`), never timing").
