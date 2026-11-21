---
module: SwiftStateTurns
date: 2026-11-21
problem_type: gotcha
component: quiescence-wait
symptoms:
  - "a waitForQuiescence called from inside the actor never returns; the process sits at 0 % CPU"
  - "the stuck actor shows its follow-up already stepped (pending 0) and one waiter still registered"
  - "the hang is intermittent: n=10 sometimes finishes, n=1000 hangs, under lldb it may not reproduce"
  - "every continuation-based wait passes its tests from outside the actor, and loses wakes under parallel load"
root_cause: a_non_sendable_closure_inherits_an_actor_instance_isolation_only_when_it_captures_that_instance
resolution_type: design_rule
severity: high
tags:
  - turns
  - concurrency
  - isolation
  - continuation
  - lost-wakeup
  - quiescence
related:
  - "#702"
---

# A closure that captures only actor state runs off the actor

## Problem

`TurnActor.waitForQuiescence` checked the pending count, then suspended in `withTaskCancellationHandler { withCheckedContinuation { … } }`. The continuation body re-checked the count and stored the waiter in `core.quiescenceWaiters`. Each segment's epilogue (`settleQuiescence`) wakes the waiters whose count has been reached. The `follow-up` cell of `TurnsBench` (arm, then wait, in a loop) hung at 0 % CPU with no task running. A stress run (8 actors × 3000 arm-and-wait rounds, release) hung every time. In each stuck actor the follow-up had stepped (pending 0), yet a waiter was registered: it was stored after the settle that should have woken it.

## Root cause

Both closures used only a local `let core = self.core`, never `self`. Under Swift 6's closure isolation inference, a non-`Sendable` closure formed in an actor-isolated context inherits an actor **instance's** isolation only when it captures that instance, the isolated parameter: `self` here (SE-0420's rule for isolated parameters). Global-actor isolation is inherited regardless. So the operation closure was nonisolated. `#isolation` inside it was nil, and `withCheckedContinuation` ran its body on the generic executor. The re-check and the store then ran concurrently with the actor's own segments: re-check (pending 1), the follow-up job steps and settles (no waiter yet), the store. That waiter is never woken. Nothing warned: `core` is non-`Sendable`, but region isolation let the closure take it.

`sendAndWait` uses the same pattern without the bug: its continuation body calls `self.submit`, so it captures `self` and stays isolated.

## Fix

The continuation body calls an isolated method, `self.registerQuiescenceWaiter(id, waiter)`. That method does the re-check and the store and starts with `preconditionIsolated`. Because the body calls an actor-isolated method synchronously, it has to be isolated to compile, so going back to the old shape needs a visible edit. `onCancel` is `@Sendable` and runs concurrently with the cancelled task, so it can never be isolated. It still hops (`Task { await self.quiescenceWaiterCancelled(id) }`) and touches no core state itself.

Case 39 in `Tests/SwiftStateTurnsTests/FollowUpTests.swift` runs the wait on an actor backed by a dispatch-queue `SerialExecutor`. A test hook at the registration point records, without trapping, whether it ran on that queue. The old shape records `false` in debug and release builds. Release-only case 38 is the parallel load that showed the race. It is bounded, so a regression fails instead of parking.

## Prevention

- In an actor (or an actor-constrained protocol extension), a closure that must run on the actor has to capture `self`. The cleanest way is a call to an isolated method that does the state work. Capturing a stored property's value (`let core = self.core`) is not enough.
- `withCheckedContinuation`, `withUnsafeContinuation` and `withTaskCancellationHandler` take `isolation: #isolation`, which inside an uncaptured closure is nil: their body runs off the actor.
- A check-then-register against state that another segment settles has to run in one isolated segment. Test that with an executor the test can ask ("am I on it?"), not only with load.
