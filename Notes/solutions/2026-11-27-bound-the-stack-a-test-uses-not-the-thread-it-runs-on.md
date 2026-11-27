---
title: "Assert the stack a deep test uses, not the thread it runs on: an executor preference is headroom, not a precondition"
module: SwiftStateTree
date: 2026-11-27
problem_type: testing_practice
component: large-stack-tests
symptoms:
  - "a `#require` that the replay handler ran on the large-stack executor's thread fails rarely (`[nil]` instead of the marker): once in a 50-run Linux loop"
  - "the warm-up from #872 is in place and the thread check still flakes on a re-evaluation keeper"
root_cause: a_thread_identity_precondition_the_scheduler_cannot_promise
resolution_type: established_pattern
severity: low
tags:
  - task-executor
  - large-stack
  - flaky-test
  - pool-thread
  - stack-depth
related:
  - "#874"
  - "#872"
  - "#804"
  - "#612"
---

## Problem

`ReplayServerInputDecodeFailureTests` ran a replay with a too-deep server input on an 8 MiB task executor, and first checked with a shallow replay that the handler ran on that executor's thread (`try #require(probe.all == [executor.marker])`). The check still failed after #872's warm-up: once in a 50-run Linux loop.

## Root cause

A re-evaluation keeper's legacy tick makes nine awaits before the handler. Each resume can land the keeper on a pool thread (1 to 4 in 200 per site), and nothing pins it back until #612 routes replay through turns. So the precondition asked for something the scheduler doesn't promise.

The reason for the precondition had also gone away. The test dated from when a deep decode boxed the whole tree before the depth check. Since #804 the reader refuses at level `maxDepth + 1` on the way down, so the replay's deepest point is the same at `maxDepth + 1` and at `maxDepth + 201` levels: 255,616 bytes from the thread's top, Darwin, debug, Swift 6.4.2.

## Fix

Measure instead of pinning:
- `CanonicalMessagePack.stackProbeForTesting` (debug only) is called at every codec probe point, plus a second hook, `depthRefusalProbeForTesting`, on the reader's refusal leaf in `enter()`. Each call notes `threadTop − SP` for whichever thread it runs on. `threadTop` comes from `pthread_get_stackaddr_np` on Darwin, `pthread_getattr_np` + `pthread_attr_getstack` on glibc, and `GetCurrentThreadStackLimits` on Windows.
- The test asserts that the refusal was sampled (so the bound can't pass on the shallow decodes alone), and that the deepest sampled point is under a stated bound, and prints it. On a platform with none of those calls, it skips only the measurement, by name.
- The executor stays as a preference.

The bound is derived, not guessed:
- `pthread_get_stacksize_np` on a Darwin cooperative-pool thread reports 536,576 bytes (524 KiB), 20 KiB less than the 544 KiB quoted across the repository;
- a pool worker's job starts shallower than the executor's run loop (624 bytes from the top against 1,632), so nothing is taken off for that;
- the reserve is a quarter of the thread.

That gives 393 KiB against the measured 249 KiB. On Linux a pool thread gets the soft `RLIMIT_STACK` at process start, 8 MiB in CI (`pthread_getattr_np`; `Thread.stackSize` reads 8 MiB for every pthread there, so it tells you nothing), so Darwin's bound is the one that binds.

## Prevention

- When a test needs a resource (stack, memory) that only a particular thread is sure to have, assert the resource use against the smallest thread it can land on. Don't assert the thread. A thread-identity check is only as good as the scheduler's promise, and a task executor preference promises nothing across an actor's resumes.
- Measure the use from the thread's top, not from a point inside the test. That way, frames above the code under test (the test runner, the keeper, the replay loop) count too, and a regression there fails the bound.
- Probe the leaf, not just the entries: a refusal throws from a frame below the last visit probe. Then assert the leaf was sampled, since a bound met by the shallow paths alone checks nothing.
- Swift's Glibc module doesn't expose `pthread_getattr_np` (a GNU extension). Look it up with `dlsym(nil, "pthread_getattr_np")` and call it through an `@convention(c)` type, treating nil as "can't measure". Don't use `@_silgen_name`: that binds with the Swift calling convention, which matches C only by accident. #935's first round didn't build on Linux for want of it.
- Count a sample only when it was measured, in the same update as its depth. Otherwise a "the deep part was sampled" check passes with nothing measured, and the bound passes at 0.
- Give every platform the CI runs a measurement, or skip the measurement there explicitly. An `#else return nil` turns into a failure on a platform nobody built locally: Windows, in #935's first round.
- Read a pool thread's size from inside a task on that thread (`pthread_get_stacksize_np`, `pthread_getattr_np`). Don't use `Thread.stackSize`, and don't take a figure from another note.
- The trade-off: a regression large enough to overflow a pool thread still crashes on the rare run that lands there, but on the usual run (on the executor) it fails the bound by name, and the bound sits a quarter below the overflow point.
