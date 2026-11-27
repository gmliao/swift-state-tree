---
title: "A new terminal answer must go through every path that can answer the attempt: a deferred answer and a timer that ends the attempt drop it otherwise"
module: SwiftStateTreeTransport
date: 2026-11-27
problem_type: bug_class
component: land-router-join
symptoms:
  - "a superseded join gets JOIN_DENIED but its connection stays open, with no 4017"
  - "a superseded join gets the admission timeout and a 1000 close"
  - "the client rejoins and kicks the newer session, the kick loop a 4017 close prevents"
root_cause: the_new_answer_was_added_to_the_handler_only_while_the_budget_timer_could_answer_the_same_attempt_from_a_deferred_record_or_from_its_own_guess
resolution_type: code_fix
severity: high
tags:
  - reentrancy
  - join
  - deadline
  - close-code
  - router
related:
  - "#860"
  - "#861"
  - "#104"
  - "2026-11-27-after-an-await-recheck-the-slot-by-identity-not-key"
---

## Problem

#860 gave a routed join superseded during its OnJoin resolvers a new answer: its `JOIN_DENIED` as the last frame, then the 4017 `superseded` close, as on the flip-stage supersede (#861). The answer was added in the join handler's `.failure` branch. Two orderings with the join budget's timer (#104) took it away:

- **The timer is waiting for the adapter when the keeper throws.** The timer marks the attempt `expiring` and awaits `endJoinBeforeAdmission`, which answers false: the admission is in the keeper's join. The handler then gets `.superseded`. Because the attempt is expiring, `leaveAnswerToExpiry` stores the answer for the timer and returns, before the new branch. It stored only `(code, message)`. So the timer sent a plain `JOIN_DENIED` with no close and no refused mark, and the session stayed open.
- **The timer runs after the keeper threw, before the router resumes.** The adapter's admission has returned, and its `defer` removed the expected admission. So `endJoinBeforeAdmission` took the join for one that never started. It ended the attempt and sent the admission timeout with a 1000 close. The handler then found its attempt ended and returned.

Either way the client may rejoin and kick the newer session.

## Root cause

An attempt has more than one path that can answer it. The handler answers directly. The handler can also leave its answer to the timer (`unanswered`). And the timer can answer on its own, from its guess about where the admission is. The new answer went into one of the three. The deferred record carried a reduced form of the answer (no close). The timer's guess read "no expected admission" as "never started", but that state also means "finished".

## Fix

- `unanswered` carries whether the answer is a supersede. The handler and the timer both answer it through one helper, `answerSupersededJoin`. The helper reads the connection generation, ends the attempt, marks the session refused, and sends the final frame with the 4017 close behind it, all in the segment that checked the attempt.
- The attempt records that its keeper join started (`JoinAttemptEnd.markKeeperJoinStarted`). The adapter sets it in the segment of the admission's checks, before it calls the keeper. `endJoinBeforeAdmission` reads it, so once the keeper's join has started, its outcome is the attempt's answer, even after the join has returned.
- `RoutedJoinSupersededTests` forces each ordering with router hold points: `.joinBudgetAdmissionAnswered` after the adapter's answer, and `.joinBudgetExpired` with `.afterAdmit`. Each expects exactly `[JOIN_DENIED superseded, close 4017]` in one ordered log.

## Prevention

- When you add a terminal answer (a new close code, a new final frame), list every path that can answer the same attempt or session: the direct handler, any deferred-answer record, timers and their own fallback answers, disconnect cleanup. Route the new answer through each of them, or make the other paths hand the answer back to the one that has it.
- A deferred answer stores the whole answer (frame, close, refused mark), not a reduced tuple that the deferring path reconstructs.
- "Not expected any more" has two meanings, not started and finished. Record "started" on the attempt where the work begins, instead of inferring it from a table that both states leave empty.
- Test each ordering with a hold at the await. Check the frames and closes in one ordered log, so the test pins the order too.
