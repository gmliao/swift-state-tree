---
title: "A gated test under a wall-clock deadline fails once the suite grows"
module: Tests
date: 2026-11-17
problem_type: testing_practice
component: resolver-deadline
symptoms:
  - "Resolvers timed out after 5.0 seconds"
  - "a gated resolver test fails on CI after an unrelated merge"
  - "drained action not applied before freeze returned"
root_cause: gated_resolver_raced_the_wall_clock_resolver_deadline
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - resolver
  - deadline
  - cooperative-pool
  - parallel-tests
  - hold-points
related:
  - "#447"
  - "#576"
  - "#904"
  - "#928"
---

**Problem.** After #576 merged, main's `build (in-turn sync true)` job failed in `LandKeeperDebugFreezeTests` "Tickless: a resolver in flight at freeze time completes before freeze returns". It reported two issues: `currentState().value == "resolved"` was false, and "Resolvers timed out after 5.0 seconds: DebugFreezeGatedResolver". #576's own CI had passed both modes, and the test passed 50 of 50 runs on the Mac before and after #576.

**Root cause.** The test holds its resolver behind a gate until it opens it, so the interleaving is forced, not timed. But the resolver still ran under the default resolver deadline, 5 s of wall clock (`RESOLVER_TIMEOUT_MS`). The test therefore assumed that the time from "the resolver waits" to "the test opens the gate" stays under 5 s. On a CI runner, Swift Testing runs the whole target in parallel on 2 to 4 pool threads, and that window grew with the suite: this test took 4.5 s at 93fb108d, 6.7 s and 8.7 s on later commits, and 11.0 s when it failed. In the failed run, unrelated fast tests that started with it took 11 s too. Once the window passed 5 s, the deadline ended the resolver, the freeze drained the ended job, and the action never applied. Setting `RESOLVER_TIMEOUT_MS=10` reproduced the same issues on every run at both commits. Under 10 ms deadlines (`RESOLVER_TIMEOUT_MS` and `RESOLVER_INIT_TIMEOUT_MS`), 9 tests in 6 suites failed the same way in both in-turn sync modes: the two debug freeze suites, `DrainTurnTests`, `PerSequenceResultTests`, `TicklessActionJobTests` and `TicklessReplayPassTests`. Their windows are only shorter on an idle machine.

**Fix.** A suite trait, `.resolverDeadlinesOff` (`TestScoping`; one copy per test target), runs each test with `ResolverDeadline.overrideForTesting` and `initOverrideForTesting` set to `.zero`, the pattern #447 used for one test. It's on every suite and test whose resolvers wait on a gate under the default deadline: 14 suites and two single tests, `LandReleaseTests.ticklessLandWithHeldJob` and `LandDSLTests`' "OnInitialize completes before tick starts". That includes 9 that already passed at 10 ms, because on a stalled runner any held window can outlast 5 s. With the trait, all of them pass at 10 ms. A test that sets its own deadline still gets it, because the inner `withValue` wins. Suites that test the deadline or abandonment themselves don't get it: the two abandonment suites in `ActionJobTests`, `ResolverDeadlineTests`, `ResolverDeadlineSettledResultTests`, and in `LandReleaseTests` the tests of an OnInitialize deadline. Each of them has a `.timeLimit` (three suites and the `LandDSLTests` test got one in this change), so a gate that never opens fails the test at its limit instead of hanging the job.

**Prevention.**
- A resolver that waits on a gate, a hold point or a continuation runs with the deadline off (`.resolverDeadlinesOff`), unless the deadline is what the test is about. In that case the test sets its own short deadline and opens the gate after it.
- The same goes for any wall-clock deadline in the code under test: a held test is about order, and the time between its steps is unbounded on a loaded runner.
- To check a held test for this, run it with the deadline set very short (`RESOLVER_TIMEOUT_MS=10`). If it fails, it depends on the deadline.
- When a test fails on CI right after a merge that didn't touch its code, compare its duration across recent runs before blaming the merge (see [CPU-bound tests starve the cooperative pool](2026-11-11-cpu-bound-tests-starve-the-cooperative-pool.md)).

**Recurrences.**
- #904: Windows CI. The test windows were about 20 s, and `debugFreeze`'s 10 s drain fired inside two held tests. Fixed by #905 (105bb6c4).
- #928: the same class through the adapter's settle deadline (10 s) and its 30 s auto-resume, which the held-settle tests left at their defaults. Fixed by fixture defaults: `freezeWithoutDeadline` in the test support, set by the fixtures that hold work while frozen.
- The rule: a fixture whose tests hold work while frozen sets every deadline in the code under test to `freezeWithoutDeadline`. A test of a deadline sets its own short one.
- #978: the other side of the same class. A test of a deadline asserted the call's elapsed wall time (`ContinuousClock.now - start < .seconds(3)`) and failed on a stalled macOS runner at 5.6 s, though the deadline had fired. The test keeps its resolver held until after the call, so the deadline is the only thing that can end it. It now waits for the call's end event under the hang bound (`EventLog.waitFor`), opens the gate if that runs out, and then checks the throw. A test of a deadline proves that the call ended and how it ended. It doesn't time the call.
