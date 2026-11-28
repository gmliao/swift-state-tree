---
title: "An effect's result in the harness's log marks the attempt, not the step: a model read after waiting on it can see the state before the step"
module: SwiftStateTree
date: 2026-11-28
problem_type: testing_practice
component: keeper-turn-core
symptoms:
  - "a case waits for an input's name (waitForInputs) and then reads the model, and the read sometimes shows the state before that input's step"
  - "a fast killer added for a mutant passes or fails depending on scheduling"
  - "the effect's result name is in inputsSeen, but the phase it should have moved hasn't moved"
root_cause: the_log_entry_is_written_in_perform_before_the_core_steps_the_returned_input
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - turn-core
  - harness
  - race
  - effects
related:
  - "#700"
  - "#969"
---

**Problem.** In #969's round 2, several cases read the model right after `waitForInputs(named:count:)` on an effect's result. Examples: `initializeResolved` before the stop's phase in `stopDuringTheInitializationWaitsForIt`, and `tickRecordTaken` before `stopPhase` in `shutdownDropsQueuedLeave512` (m5's fast killer). Review found the read can run before the step it means to check.

**Root cause.** `KeeperCoreHarness.perform` runs an effect and notes its result (`noteResult`) before it returns the input. The core steps that input only after `perform` returns, when it completes the effect. So the log entry means "the effect returned this input", not "the input has stepped". A waiter woken by the entry can read the model in the gap. The harness already warned about this for counts of results (above `waitForInputs`). The same holds for any wait on a result's name followed by a model read.

**Fix.** Wait for an event that is appended after the step:
- an output that the step flushes (the harness's `flush` runs after the step), such as `.detachTransport` for the drain's end;
- the reply of a call that the step answers;
- or a post-step event appended on the core's executor after the input's step.

A name noted in `perform` stays useful as a precondition ("the effect ran"), never as "the step ran".

**Prevention.**
- For each wait followed by a model read, name the step that writes what the read checks, and wait for an event that comes after that step.
- An input sent by `drive` is stepped before it returns only when the core is idle (`TurnActor.send` queues it behind a step in progress). `call` returns at the reply, which a parked call gets in a later step. Neither marks a step for an input an effect returns: that input's log entry comes before its step.
- A read that must fail fast for a mutant is still bounded on a post-step event. A pre-step event makes the killer flaky, which is worse than a slow one.
- Related: [Force the interleaving with hold points, not timing](2026-11-05-hold-points-not-timing-in-race-tests.md), and [A flight that has finished still answers late callers](2026-11-28-a-flight-that-has-finished-still-answers-late-callers.md).
