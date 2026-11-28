---
title: "A flight that has finished still answers late callers: a barrier answered only at completion leaves every later caller waiting forever"
module: SwiftStateTree
date: 2026-11-28
problem_type: logic_error
component: keeper-turn-core
symptoms:
  - "a second stop after the first returned never gets an answer on the core"
  - "a first stop after a land failure's drain finished hangs"
  - "a test that awaits a harness call with .ignoresCancel dies only at the suite's time limit"
  - "a list of parked callers is answered by an event that already happened before they parked"
root_cause: callers_parked_on_a_completion_event_after_it_fired
resolution_type: code_fix
severity: high
tags:
  - single-flight
  - barrier
  - late-joiner
  - drain
  - turn-core
related:
  - "#700"
  - "#969"
---

**Problem.** On the keeper, a stop is a `SingleFlight`: callers during the flight join it, and a caller after it ends gets the finished result at once. The core's stop (#969, K2-2 commit 1b) parked every `.shutdown` caller in `coreBarrierWaits.drained` and answered the list at `.drainFinished`. Three callers came after that event and were never answered:
- a second stop after the first returned;
- a first stop after a land failure's drain had finished;
- a second stop after a first that found players, so no drain ran.

A related case: a stop that arrived during the initialization was parked in the same list. A land failure's drain that finished during OnInitialize's resolvers then answered it before the initialization ended. The keeper's stop waits in `ensureInitialized` first.

**Root cause.** The barrier was answered only at the completion event, with no state saying "already completed". A caller that parks after the event waits for an event that won't come again. The keeper's flight keeps its finished task, so `await flight.value` returns at once. The port to the core kept the waiting half of that behavior and dropped the finished half.

**Fix.**
- `StopPhase.ended` marks the flight returned.
- `admitStop` answers a stop at once when the flight has ended or the drain has finished, and otherwise parks it and starts the flight for the first caller.
- Stops that arrive before the initialization ends wait in their own list (`stopsAwaitingInitialization`), and `beginStopAfterInitialization` moves them through `admitStop`. So a drain that finishes first finds no stop to answer early.

**Prevention.**
- Porting a `SingleFlight`, a `Task` that callers await, or any "wait for X" onto a barrier takes two states, in progress and done. A barrier that is answered only at the event needs a check for "the event already happened" at the point where a caller parks.
- For each such barrier, write the late-joiner case: a caller after completion, by each path that can complete it (here, a stop, a failure's drain, a stop that found players). Assert it is answered and the parked list is empty.
- Callers that come before a precondition holds (the initialization) wait apart from the callers of the flow itself. Then one flow's completion can't answer the other flow's callers.
- Bound every wait for an answer that a bug would leave missing. Read the parked list right after the completing step, so the case fails at that read, not at the suite's time limit.
- Related: [A flow moved onto the core needs a core case per exit](2026-11-27-a-flow-moved-onto-the-core-needs-a-core-case-per-exit.md).
