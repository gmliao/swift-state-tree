---
title: "A test-scope trait's async cleanup after `function()` is skipped when the test throws"
module: SwiftStateTreeTransport
date: 2026-11-28
problem_type: testing_practice
component: test-support-traits
symptoms:
  - "a fixture's keepers, recorders and spool files leak only in failing runs"
  - "a test that fails at try #require leaves its spool file in the temporary directory"
  - "cleanup in provideScope runs for #expect failures but not for thrown errors"
root_cause: async_cleanup_placed_after_a_throwing_call_instead_of_on_both_paths
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - test-scoping
  - trait
  - cleanup
  - leak
related:
  - "#910"
  - "#965"
---

**Problem.** `.drainsFixtureKeepers` (#965) ran its drain and spool check after `try await function()` in `provideScope`. A test that throws (a `try #require`, a thrown error, the cancellation from a `.timeLimit`) skipped both, and a `defer` only threw away the registered drains. Those tests kept their keepers, recorders and spool files until the process exited. The trait exists to stop that leak, and it missed it on the failing runs, where one failure leads to more.

**Root cause.** The cleanup is async, and `defer` can't `await`, so it went after the call. Code after a `try` call runs only on the success path. An `#expect` failure records an issue and doesn't throw, so the passing and `#expect`-failing runs hid the gap.

**Fix.** Catch the test's error, run the drain and the spool check, then rethrow the original error. The spool poll sleeps with `safeTaskSleep` and stops when it throws: a cancelled test records the check as not done instead of spinning on a sleep that throws at once, and nothing outlives the test.

**Prevention.**
- A `TestScoping` trait with cleanup uses `do { try await function() } catch { thrown = error }`, cleans up, and then `if let thrown { throw thrown }`. A `defer` is enough only for synchronous cleanup.
- Test the trait by calling `provideScope(for: Test.current!, …)` directly with a body that throws, and check the cleanup's effect after the scope rethrows (`DrainsFixtureKeepersTraitTests.drainsOnThrow` checks `keeper.isDraining`).
- Cleanup that a cancelled test runs stays structured: a wait that throws on cancellation ends the wait and is reported, never retried in a loop or moved to a detached task that outlives the test.
