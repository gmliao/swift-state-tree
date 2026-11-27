---
title: "A task executor preference picks the thread only for an idle actor: a test that asserts the thread must first make sure nothing else drives the actor"
module: SwiftStateTree
date: 2026-11-25
problem_type: testing_practice
component: large-stack-tests
symptoms:
  - "an encode or decode checked to run on the large-stack executor's thread sometimes runs on a pool thread ([nil] instead of the marker)"
  - "a thread-marker assertion fails once on Linux CI and passes on macOS and locally"
root_cause: actor_drained_by_a_thread_outside_the_executor_preference
resolution_type: established_pattern
severity: low
tags:
  - task-executor
  - large-stack
  - flaky-test
  - pool-thread
related:
  - "#872"
  - "#802"
---

## Problem

`deepRecursiveInputIsRefusedOnTheWayDown` runs the deep server-input encode on an 8 MiB thread (a `TaskExecutor` set with `withTaskExecutorPreference`) and asserts that the encode saw the executor's thread marker. It failed once on Linux CI with `[nil]`: the encode had run on a thread without the marker. The encoder's bound held, so only the thread check failed.

## Root cause

An unstructured `Task {}` doesn't inherit the creator's task executor preference (probe on Swift 6.4.3, Linux: the body and an `async let` child see the marker; `Task {}` and a `Task {}` that calls into a default actor don't). `LandKeeper.init` starts its own initialization in such tasks, so a pool thread can be driving the keeper actor when the test's call is enqueued. A default actor runs a queued job on whichever thread is draining it, so the submit, and the encode inside it, can run on that thread. The preference decides the thread only when the actor is idle.

It reproduces rarely, even with the initialization held on purpose (a blocking `OnInitialize`: 17 of 200 runs without the fix, 0 of 200 with it), which is why it showed up once in CI.

## Fix

Bring the actor to idle before the call that is checked: `await keeper.awaitInitialization()`, then one more round trip (`_ = await keeper.currentState()`). After the round trip no initialization work is left for a pool thread. The assertions stay.

## Prevention

A test that asserts which thread a keeper call ran on must first make sure no task outside its executor preference can be holding the keeper: wait for the keeper's own start-up work, then make a round trip. The warm-up covers only the start-up tasks. It is not sufficient for a re-evaluation keeper's replay: 1 run in 50 of the deep-input and replay suites together still ran the replay handler on a pool thread (`probe.all → [nil]`), with some other path (perhaps the keeper's hops to the `JSONReevaluationSource` actor) driving it; that residual is tracked from #872. Where the stack use itself can be measured, prefer that over the thread check: #874 replaced the replay suite's thread `#require`, which a re-evaluation keeper's resumes still broke, with a bound on the measured stack ([the entry](2026-11-27-bound-the-stack-a-test-uses-not-the-thread-it-runs-on.md)). Where it can't, keep the thread check: it is what keeps a regression of a stack-depth bound from crashing the run on a pool thread instead of failing by name.
