---
module: tooling
date: 2026-11-10
problem_type: testing_practice
component: test-verification
symptoms:
  - "`swift test --skip-build` passes right after a change whose test target doesn't compile"
  - "Mutants all survive, or the new tests don't appear in the run's test count"
  - "A verification script reports green suites, and its build step printed `error:` lines above them"
  - "`warning: No matching test cases were run` right after a `git checkout` of another branch"
  - "A verification run right after a mutant loop fails the test the last mutant broke"
root_cause: skip_build_runs_the_last_linked_test_bundle
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - verification
  - swiftpm
  - skip-build
  - mutants
related:
  - "#464"
  - "#479"
  - "#504"
  - "#513"
---

# `--skip-build` after a failed build or a branch switch runs the old tests

## Problem

A verification script ran `swift build --build-tests`, then each suite with `swift test --skip-build --filter …`, then a mutant loop: mutate, build, run the suites again. A new test fixture didn't compile. A `@SnapshotConvertible` struct held a class member, and the macro's generated decoder needs every member to be `SnapshotValueDecodable`. The build step printed the errors and went on. Every later `swift test --skip-build` ran the test bundle from the previous successful build, which was without the new tests and without the change. The suites passed, the full suite passed, and the mutants "passed" too: none of them was compiled.

A second case (#504): a script verified two branches in turn, and ended on the second one. Back on the first branch, a one-off `swift test --skip-build --filter <a new test>` printed `No matching test cases were run`: `.build` held the second branch's test bundle, which doesn't have the first branch's tests. Had the filter matched a test both branches share, it would have run the other branch's code and passed.

A third case (#513): a mutant loop mutated a source, built, ran the suite, and restored the source by copying it back. The verification run that followed used `--skip-build`, so it ran the last mutant's binary: a new test failed in all four configurations, on code that was no longer in the tree. Restoring a file doesn't rebuild. A mutant that fails a test there is easy to read as a real bug; one that passes would have hidden one.

## Root cause

`--skip-build` doesn't check that the sources match the binary. It runs whatever test bundle is in `.build`: after a failed build, the last one that linked; after a `git checkout`, the other branch's. The script treated the build as a log line to print, not as a gate.

## Fix

The build step now stops the script when its output has no `Build complete`. A trap restores the mutated sources on exit, so a stop in the middle of the mutant loop doesn't leave a mutant in the tree. After the fix the rerun's first line was `Build complete!`, the new test appeared in the count (786 → 787), and each mutant failed its suite.

## Prevention

- Gate every `--skip-build` run on the build that precedes it. Check its exit status, or require `Build complete` in its output, and stop the run otherwise.
- Confirm a change reached the binary: the new tests appear in the run (a higher test count, or the new test's name in the output), and a mutant of the change fails. Mutants that all survive mean the change probably wasn't built.
- In a mutant loop, restore the sources on exit (a `trap`), not only at the end of the loop.
- After a mutant loop restores the sources, build before any `--skip-build` run. The binary in `.build` is the last mutant's.
- After any `git checkout`, build before the first `--skip-build` run, even for one test. A script that verifies several branches builds on each one, and the binary left in `.build` belongs to the last branch it built.
- `No matching test cases were run` is a failed step, not a pass: the filter missed, or the binary isn't the one the sources describe.
- Related: [A skipped test class reads as passing](2026-11-10-a-skipped-test-class-reads-as-passing.md) is the same failure of reading "no failures" as "verified".
