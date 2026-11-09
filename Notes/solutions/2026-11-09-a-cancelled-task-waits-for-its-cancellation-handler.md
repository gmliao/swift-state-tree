---
module: SwiftStateTree
date: 2026-11-09
problem_type: concurrency_semantics
component: resolver-deadline
symptoms:
  - "a test holding a cancellation handler (on the cancelling thread) waits for the cancelled task's result and only gets it after a timeout"
  - "a suspected race between a cancellation handler's late bookkeeping and the cancelled task's next step can't be reproduced"
root_cause: a_task_cannot_leave_withTaskCancellationHandler_while_its_handler_runs_on_another_thread
resolution_type: established_pattern
severity: low
tags:
  - concurrency
  - cancellation
  - testing
  - hold-points
related:
  - "Notes/solutions/2026-11-08-cancellation-test-passes-on-the-deadline.md"
  - "Notes/plans/2026-11-08-action-completion-queue.md"
---

**Problem.** In the resolver deadline race, a caller's cancellation settles the race in the job's `onCancel` (on the cancelling thread), and publishes the outcome before running `onWin`, which counts the abandonment. A review asked whether the job could see the outcome in `install`, resume, and complete (freeing its place in the caps) before `onWin` ran. The test that forced it held the cancelling thread right after the outcome was published, then waited for the cancelled caller's result. That result came only when the hold timed out, 10 s later. The job had resumed in `install` and then stopped.

**Root cause.** `Task.cancel()` runs the task's cancellation handlers while holding the task's status-record lock. Leaving `withTaskCancellationHandler` removes the handler's record, which takes the same lock. So a task whose handler is running on another thread can't return from `withTaskCancellationHandler` until that handler returns, even if its operation already finished. The window the review described can't be reached in practice: `onWin` runs inside that handler, before the job can move on. A hold inside a cancellation handler blocks the cancelled task too, and with it everything waiting on that task.

**Fix.** `onWin` now runs under the race's lock, before the outcome is published (`ResolverDeadline.swift`, `settle`). So the ordering no longer depends on this runtime detail. The test holds the canceller after the settle, releases it, and only then checks that the job kept its place and the abandonment was counted (`Tests/SwiftStateTreeTests/ActionJobTests.swift`, "A caller cancelled from another thread just before the job waits on its race"). The mutant that moves `onWin` back after the publish survives, because the runtime ordering already protects it.

**Prevention.** A test that holds code inside a cancellation handler must not wait for the cancelled task in the meantime: release the hold first, or observe a side effect that doesn't need the task to return. Before designing a fix for a race whose one side runs in a cancellation handler, check whether the other side has to leave `withTaskCancellationHandler` first; if so, the handler finishes before it. Don't rely on that ordering in library code, though; keep bookkeeping ahead of the publish.
