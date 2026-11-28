---
title: "An abandoned request whose worker isn't cancelled keeps its actor alive: abandoning a request must cancel its worker"
module: SwiftStateTurns
date: 2026-11-28
problem_type: bug_class
component: turn-core-effects
symptoms:
  - "an actor that ended every key (endAll) is never released; a weak reference to it stays non-nil"
  - "a request that hit its deadline or was cancelled still has its effect running long after"
  - "a wait inside perform (a writer drain, a load) outlives the teardown that abandoned its request"
root_cause: abandoning_a_request_closed_its_record_but_left_its_worker_task_running
resolution_type: architectural_fix
severity: medium
tags:
  - turn-core
  - cancellation
  - structured-concurrency
  - effects
  - leak
related:
  - "#700"
---

**Problem.** The binding-token plan for K2-2 commit 3 (`Notes/plans/2026-11-28-k2-2-commit-3-binding-token.md`) runs the writer-drain retry as a turn-core request whose `perform` awaits the adapter's writer drain. Review found that the await has no bounded end. If the port is replaced while its writer is back-pressured, the drain later finishes only the new port's writer. `cancel` and `endAll` closed the old request's record, which took it out of `.requests`, but nothing cancelled its worker. The worker kept the actor alive: `launch` holds it strongly, so that an effect is never dropped.

**Root cause.** A request's two halves had separate lifetimes. The record (`rt.open`) closed on every abandonment: a cancel, a deadline, its key's `end`, `endAll`. The worker task (`launch`'s `Task`) had no handle, so no abandonment could reach it. Its late result was correctly stale (`handleLateResult`), but the work itself, and the actor it held, ran on.

**Fix.** Structured cancellation, the rule of Swift's task groups and Trio's cancel scopes: work a key owns ends with the key. `TurnCore.workers` keeps each tracked request's worker by `RequestID`.
- Stepping an abandonment cancels the worker once, before `handleAbandoned`.
- `launch` cancels a worker at once if its request closed before the launch, for example one abandoned in the step that made it.
- Completion removes the handle on every path, live or late, so a worker that has returned is never cancelled.
- `run`'s untracked workers have no handle and are never cancelled.

The effect contract (`TurnActor.perform`'s doc, docs/turns) now says that a tracked request's `perform` honours `Task.isCancelled` at safe points only. A cancellation asks the work to stop; it doesn't stop it. Work that changes something outside settles that change before it returns, because an `.untilWorkerReturns` hold ends when the worker returns: a writer that returns at the cancel would release the next write before its own lands. Work that must finish goes through `run`. With a mailbox, the adopter's contract is that a cancelled `perform` returns nil. A replay's completion then matches only when the cancel landed before the worker's last safe point.

**Prevention.** Honour a cancellation at safe points, never mid-change. An async task that is started on behalf of a record must be cancelled through the same paths that close the record. Keep its handle next to the record, and remove the handle when the work returns. A test holds the worker inside a cancellation-aware await, then takes each abandonment path. It asserts that the worker saw the cancellation, that its result went to `handleLateResult`, that no handle or request is left, and that a weak reference to the actor goes nil (`AbandonedWorkerCancellationTests`).
