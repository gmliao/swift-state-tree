---
module: SwiftStateTree
date: 2026-11-08
problem_type: testing_practice
component: resolver-deadline
symptoms:
  - "a test that cancels a caller passes even with the cancellation forwarding removed"
  - "mutant survives: the caller still gets an error, from the resolver deadline"
root_cause: a_fallback_timeout_produces_the_same_outcome_class_as_the_path_under_test
resolution_type: established_pattern
severity: low
tags:
  - testing
  - cancellation
  - deadline
  - mutants
related:
  - "Notes/plans/2026-11-08-action-completion-queue.md"
---

*The code, tests and plan named here are on the `exp/action-completion-queue` branch until it merges into `main`.*

**Problem.** An action job's caller is cancelled, and that cancellation should cancel the job's resolvers, so the caller gets `CancellationError` at once. The first version of the test checked only that the caller didn't succeed. With the forwarding removed (`cancelActionJobForCaller` doing nothing), the test still passed: the held resolver ran into the resolver deadline (`RESOLVER_TIMEOUT_MS`, 5 s by default), and the caller got `ResolverExecutionError.timedOut`, which was also a non-success.

**Root cause.** A backstop that exists for the production failure (the deadline) produces an outcome of the same class as the path under test. An assertion that only distinguishes "failed" from "succeeded" can't tell which one ended the wait.

**Fix.** The test asserts the specific outcome (`error is CancellationError`). It also sets the deadline far past the test's own time limit, with `ResolverDeadline.$overrideForTesting.withValue(.seconds(120))`, so only the forwarded cancellation can end the wait inside `withinDeadline`'s 10 s. With the forwarding removed, the test now fails (`Tests/SwiftStateTreeTests/ActionJobTests.swift`, "Cancelling the caller cancels its job").

**Prevention.** When a test checks that one mechanism ends a wait (a cancellation, a rejection, a wake-up), list the other mechanisms that can end it too: a deadline, a timeout, a drain, a retry. Then either assert the exact outcome only the mechanism under test produces, or push the others out of the test's window. Run the mutant that removes the mechanism: if the test still passes, a backstop is answering for it.
