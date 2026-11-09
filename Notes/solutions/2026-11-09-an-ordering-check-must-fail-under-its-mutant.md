---
module: SwiftStateTree
date: 2026-11-09
problem_type: testing_practice
component: legacy-tickless-pass
symptoms:
  - "a debug assert that pins an ordering invariant never fires, and the mutant that breaks the invariant survives"
  - "two concurrent callers capture the same 'next pass' number before an await"
root_cause: a_counter_captured_before_an_await_is_shared_by_concurrent_callers
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - mutants
  - reentrancy
  - concurrency
related:
  - "Notes/solutions/2026-11-05-await-resumes-on-stale-state.md"
  - "Notes/solutions/2026-11-05-hold-points-not-timing-in-race-tests.md"
  - "Notes/plans/2026-11-08-action-completion-queue.md"
  - "#349"
---

**Problem.** A tickless action job answers after its input's record is in, and that relies on an invariant: a legacy caller's input is applied by the caller's own pass (`runLegacyPass`). Today that holds because the pass applies the ready inputs before its first `await`. To keep a later change from breaking it silently, a debug `assert` was added. `runLegacyPass` captured `legacyPassApplications + 1` as "my pass", each pass incremented the counter when it applied, and the assert compared the two. The mutant that adds an `await` before the apply survived: with twenty concurrent callers, no assert fired.

**Root cause.** The number was captured before the `await` that the mutant adds. Two callers that both suspend there capture the same number, N + 1. The first pass to resume applies both callers' inputs as pass N + 1, so both callers find "my pass" and pass the check, although one input was applied by another caller's pass. The check stated the invariant ("applied by my pass"), but it identified the pass by something two passes can share.

**Fix.** Identify the pass by its owner, not by a count. `runLegacyPass` sets `legacyPassOwner = sequence` just before it calls `processPendingActions`, which takes the owner and clears it in its first, synchronous segment. When a pass applies a caller's input, it records that owner. The assert then checks `legacyPassAppliedBy[sequence] == sequence`. Under the mutant, a pass that applies another caller's input records its own owner, and the assert fires ("Input 1 was applied by another legacy pass, before its own"). Landed in #349 (merge commit 498e49ef).

**Prevention.**
- Run the mutant for every check that pins an invariant, and confirm in its output that the check itself is what kills it (here, the assert message), not something incidental.
- A token that identifies "my" unit of work must be unique per unit and fixed in the unit's own synchronous segment. A counter read before an `await` is a guess at the next value, and it's shared by everyone who reads it before the next increment.
