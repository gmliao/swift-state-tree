---
title: "A regression case must hold before every write that would give the right answer by another route"
module: SwiftStateTree
date: 2026-11-28
problem_type: testing_practice
component: debug-freeze-drain
symptoms:
  - "a regression case passes with the fix reverted, and every named mutant survives it"
  - "a mutant dies only at the hang bound (60 s), in a case that waits on held work before its assertions"
  - "a case for a window between a commitment and its effect is staged after the effect"
root_cause: hold_placed_after_the_masking_write
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - hold-points
  - mutants
  - regression-test
  - drain
related:
  - "#987"
  - "#730"
  - "2026-11-09-an-ordering-check-must-fail-under-its-mutant"
  - "2026-11-26-a-close-decided-in-one-component-must-be-seen-by-the-others-in-its-segment"
---

## Problem

#987 refuses a debug drain at admission once a forced shutdown has committed. That way a second freeze can't resume inputs the first freeze held back. Its round 2 regression case held the stop at `.shutdownTurnApplied` on the keeper and at the drain start on the core. Both points come after `completeShutdownTurn`. That step sets the drain flag and calls `releaseHeldInputsForDrain`, which empties the held inputs. So the drain answered closed through the drain flag, and its resume had nothing left to re-queue. With the admission refusal removed, the case still passed: the cloud mutants m6, m11 and m12 all survived it.

Two more cases of the same kind failed in other ways:
- **The window cases.** They read the drain with an hour-long budget. A mutant let the drain freeze and park behind the held work, so the case hung until the 60 s bound instead of failing on a value.
- **The failed-initialization case.** It drained after a failed initialization without holding the keeper's teardown task. Whether that task had already set the drain flag was up to the scheduler, so the mutant that drops the failed-initialization check survived 5 of 5 runs.

## Root cause

Each case's hold sat after a write that produces the expected answer by another route: the drain flag, the emptied held-input list, the teardown's flag. The assertions held, but they no longer depended on the code under test.

## Fix

- **The held-input case** is staged in the window before the shutdown turn. A join is held at its record (joins run while frozen), and the stop has committed with its shutdown item queued behind the join. While held, it asserts that the masking writes haven't happened: no drain flag, one input still held. Then:
  - G2's drain answers closed, and nothing froze;
  - G2's resume leaves the queue's count unchanged and the held count at 1.
- **The window cases** read the admission with a zero budget. An admitted drain then answers `.timedOut` at once and leaves the land frozen, so a mutant fails on the value.
- **The failed-initialization case** holds the teardown at its start (`.failedInitializationTeardown`) and drains while it's held.

## Prevention

- For a case that pins a window, name the write that would make the expected answer true without the fix (a flag, a cleared list, a teardown). Hold before it, and assert it hasn't happened while held.
- Run the fix's mutants against the case before calling it a regression test. A mutant that survives, or dies only at the hang bound, means the hold is late or the read waits.
- Read a call that a mutant would park with no wait: a zero budget, or an answer read alongside a bounded wait. Then a mutant fails fast on a value.
- A task staged from the segment under test (a teardown started with `Task { }`) can run before or after the case's next step. Hold it at its start, or the outcome is the scheduler's.
