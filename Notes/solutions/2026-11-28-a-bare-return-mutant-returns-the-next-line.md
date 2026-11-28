---
title: "A mutant written as a bare `return` returns the next line: Swift parses `return` followed by a Void call as `return call()`"
module: SwiftStateTree
date: 2026-11-28
problem_type: testing_practice
component: mutation-testing
symptoms:
  - "a \"never fires\" mutant makes unrelated cases fail at once, far from the guard it changed"
  - "the mutant's failures don't include the read written to kill it"
  - "the compiler warns 'expression following return is treated as an argument of the return'"
root_cause: a_return_on_its_own_line_takes_the_next_expression_as_its_value
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - mutation
  - swift
related:
  - "#969"
---

**Problem.** In #969 a hand mutant for the stop's resume (`resumeStopAfterShutdownTurn`) was meant to read "the resume never fires". It replaced the function's guard with a line holding only `return`. The cases that failed were unrelated (a fold drop, a refusal, a settle outcome), and the read written for the mutant never fired. The report then said the mutant "fails fast", which was wrong.

**Root cause.** In a function that returns `Void`, `return` followed by a newline and an expression is parsed as `return <expression>`. A `Void` call is a valid value there. The next line was `stopStartsDrain(behavior, store, &turn)`, so the mutant became "always start the drain", the reverse of what it meant. The compiler only warns.

**Fix.** Write a "skip the rest" mutant so that nothing can follow the `return`:
- `if true { return }`, or
- `return;` (with the semicolon), or
- `guard false else { return }`.

**Prevention.**
- Before reading a mutant's result, check that its first failure is the read written for it. Failures elsewhere mean the mutant isn't the one you meant.
- When a mutant narrows a condition (`a || b` → `b`) rather than removing a branch, name it as a reading of its own. It can need a different killer from the "never fires" reading.
- Read the build log for "expression following 'return'" warnings on a mutant build.
- Related: [An effect's result in the harness's log marks the attempt, not the step](2026-11-28-an-effect-results-log-entry-marks-the-attempt-not-the-step.md).
