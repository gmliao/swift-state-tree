---
title: "A debug assertion inside the function a mutant changes crashes the run before the test can observe it"
module: SwiftStateTree
date: 2026-11-25
problem_type: gotcha
component: testing
symptoms:
  - "a plan's mutant is expected to fail a test through an invariant check"
  - "the invariant is a debug assertion that also runs inside the mutated function"
root_cause: a_trapping_check_in_the_mutated_code_ends_the_test_process_before_any_expectation_runs
resolution_type: design_rule
severity: low
tags:
  - mutants
  - testing
  - assertions
related:
  - "Notes/plans/2026-11-25-k1b2-failure-ids.md"
  - "#700"
---

**Problem.** The K1b-2 plan (rev 2) checked its action tables' alignment with a debug assertion that ran at the end of `removeActionJob`, and named a mutant that breaks `removeActionJob`. Under that mutant a debug test build traps inside `removeActionJob`, before the test's hook or `#expect` runs. The same plan had already met the trap with its failure-table miss.

**Root cause.** A trap ends the test process. The runner then reports a crash, not a failed expectation, and every later test in the process is lost. A crash can still count as killing the mutant, but only if the runner treats it so, and the report no longer says which invariant broke.

**Fix.** K1b-2 rev 2.1 makes the check a function that returns its violations. Each call site logs them and adds them to a test-visible count, and a test hook returns them for `#expect`. The table miss returns a sentinel error and counts the miss, in the same way.

**Prevention.** When a plan names a mutant, find every check that runs inside the mutated function. A check that a test should observe returns or counts what it found, and doesn't trap. If a trap is acceptable, the plan says the mutant is killed by a crash on the runner.
