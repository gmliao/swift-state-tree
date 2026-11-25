---
title: "A thrown sweep cell hides the cells after it"
module: Tests/SwiftStateTreeNIOTests/Differential
date: 2026-11-20
problem_type: gotcha
component: differential-harness
symptoms:
  - "a golden diff report counts fewer changed files than the recorder later finds"
  - "the harness fails on one scenario's error, and the scenarios after it are missing from the report"
  - "the summary line (compared / replaced / listed) is not printed"
root_cause: a_throw_inside_the_sweep_loop_ends_the_sweep
resolution_type: design_rule
severity: low
tags:
  - test-harness
  - differential
  - golden
  - fail-closed
  - reporting
related:
  - "Notes/solutions/2026-11-19-a-test-harness-under-errexit-dies-unnamed.md"
---

**Problem.** In #546 L2a, one differential scenario (a row about to be retired) threw on a hold timeout. The harness test failed, which was correct. But the throw came from inside the loop over scenarios and cells (`try await runChecked(...)`), so it ended the whole sweep. The scenarios after it (`land-stop`'s six in-turn cells) were never compared, and the summary line was never printed. The per-file differences reported before the throw looked like a complete list. Quoted as the total, it gave 264 changed leaves in 72 files. The recorder later found 282 in 78.

**Root cause.** A sweep that `try`s each case without catching treats the first error as the end of the run. Fail-closed still holds, because the test fails. What is lost is the report: a reader can't tell "these are all the differences" from "these are the differences before the sweep stopped".

**Fix.** The sweep is `DiffSweep.run`. It catches each cell's error, records it as an issue and goes on, so every later cell is still compared and reported. The summary always prints, with the number of cells that threw. A self-check forces a throw in one scenario and a difference in a later one, and asserts both are reported. A mutant that stops at the throw fails it.

**Prevention.**
- **A sweep over independent cases catches per case and goes on.** One case's error is that case's failure, not the end of the run. The shell form of the same rule is the errexit entry in `related`.
- **The summary line is the count to quote,** not a list of differences collected before it. If there is no summary line, the run didn't finish, and its list is partial.
