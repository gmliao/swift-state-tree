---
title: "A fast read in a test races any worker left unheld: hold every worker that can change the value before reading it"
module: SwiftStateTreeTests
date: 2026-11-28
problem_type: testing_practice
component: core-differential-harness
symptoms:
  - "a count read right after a step is sometimes one lower than expected on correct code"
  - "a check added so a mutant fails fast instead of at the hang bound is flaky"
root_cause: the_read_held_one_worker_but_another_could_finish_and_change_the_count_first
resolution_type: test_fix
severity: low
tags:
  - testing
  - race
  - holds
  - turn-core
  - harness
related:
  - "#990"
---

**Problem.** In the core differential suite, `consumedSlotAndASecondArm` got a fast read so that a mutant would fail on a value instead of at the 60 s hang bound. It read the number of follow-up records right after `.syncTurnNow`, expecting two: A's, whose wake was held, and B's, made at the query's end. Only A's wake was held. B's worker could perform, and its step could remove B's record, before the read ran in a separate actor call. Then the count was 1, on correct code. Review caught it (r1 on #990). The mutant run had passed, because there the mutant made the count 1 anyway.

**Root cause.** A read between steps sees the state the last step left, plus whatever any unheld worker changed by the time the read runs. Holding one worker pins only that worker's effect.

**Fix.** Arm a second hold after A's wake entered and before `.syncTurnNow`, so B's wake is held too. Read with both held, then release B and go on as before.

**Prevention.** Before you add a read that a later step could move, list every worker or wake that can change that value, and hold each of them at the read. A value only one step can change can be read right after that step, because `drive` steps on the actor before it returns. A mutant that dies on a racy read doesn't prove the read is sound: check the read against the correct code's interleavings too.
