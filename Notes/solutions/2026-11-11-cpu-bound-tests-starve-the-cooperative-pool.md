---
module: Tests
date: 2026-11-11
problem_type: testing_practice
component: swift-testing-parallelism
symptoms:
  - "a timeout that never fires on CI"
  - "closeSessionAfterQueuedFrames never sees the close"
  - "fails on a branch, never on its base, only on Linux runners"
root_cause: cpu_bound_parameterized_tests_hold_every_pool_thread
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - linux
  - concurrency
  - cooperative-pool
  - parallel-tests
related:
  - "#483"
  - "#488"
---

**Problem.** After a branch added a byte report test, `WebSocketTransportSessionIDTests.closeSessionAfterQueuedFrames` failed in 4 of 5 CI runs on that branch and never on its base. It never failed on the Mac. The test ran 10.5 s, and neither the drain's close nor the transport's own 5 s close timeout ran in that time.

**Root cause.** The byte report is a parameterized test with 4 shapes, each several seconds of synchronous work. Swift Testing runs a parameterized test's cases in parallel, and a synchronous test body keeps its cooperative pool thread until it returns. A CI runner has 2 to 4 cores, so its pool has 2 to 4 threads, and the report's cases held all of them. Every other test's tasks, the close timeout among them, waited. A slow poll can't stretch past its own deadline like that; only a starved pool does.

**Fix.** The report's suite is `.serialized`, so it uses one thread at most. The test is `async` and calls `await Task.yield()` before each sync, so that thread is handed back regularly. The numbers it reports are unchanged.

**Prevention.**
- A test that does more than about a second of CPU work, especially a parameterized one, gets `.serialized` and yields inside its loop, or does less work in CI.
- When a timing test fails only on a branch, and only on small runners, look for new CPU-bound tests on that branch before blaming the timing test.
- Print what the failing test saw. Here, entries `[one, error]` with no close is what showed that nothing in the transport ran.
