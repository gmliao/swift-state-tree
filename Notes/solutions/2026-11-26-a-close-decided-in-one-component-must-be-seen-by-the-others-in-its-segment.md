---
title: "A close decided in one component must be seen by every other component that can decide one, in the same segment"
module: SwiftStateTreeTransport
date: 2026-11-26
problem_type: bug_class
component: session-close
symptoms:
  - "a client is closed with another code (1008) than the one the server decided (1000), and the error sent before the decided close is lost"
  - "two paths answer one waiter differently (released vs closed, drained vs closed) when a stop and a freeze overlap"
  - "the client gets a run of refusals (JOIN_SESSION_NOT_CONNECTED) after a failure that already ended its session"
root_cause: second_close_decider_did_not_see_the_first_decision
resolution_type: established_pattern
severity: medium
tags:
  - ordering
  - close
  - segment
  - router
related:
  - "#912"
  - "#987"
  - "2026-11-18-a-server-close-goes-around-the-send-queue"
  - "2026-11-26-a-precedence-test-must-stage-a-pair-production-can-produce"
---

# A close decided in one component must be seen by every other component that can decide one, in the same segment

## Problem

A join that failed before its flip (inbound overflow) gets its error and a plain 1000 through the adapter's writer. The router ended the attempt in the same segment, which put the session back in the handshake. Each frame the client kept sending was refused there (JOIN_SESSION_NOT_CONNECTED) and counted against the pre-join refusal budget (8). The ninth refusal closed the session with 1008, directly on the transport, ahead of the error still waiting in the writer. The error was then dropped behind the close marker. #896's macOS log shows it: nine refusals, then "Too many refused frames before join; closing the session budget=8".

## Root cause

Two components can decide a session's close: the adapter (the final frame and its close) and the router (its refusal budget). The router made the first decision, but its own state didn't record it. To the router's refusal path the session still looked open and pre-join, so it decided a second close, and the second one went out first.

## Fix

In the segment that ends the attempt, the router also puts the session in `refusedSessions`, for every failure that closes it: the final-frame failures and the supersede. Every later frame is then dropped, not refused or counted, until the close is reported.

## Prevention

- When a component decides a session's close, list every other component that can decide one for the same session: a budget, a timer, a supersede, a land failure. In the segment of the decision, each of them must be able to see it, through a flag or a phase that its own close path reads.
- A test holds the first close's frames (a held send), then drives the second decider past its threshold, and expects the first close's code alone.
- Record the decision at the level of the event, not of one class of party it affects. #987 first recorded a forced shutdown as "the freeze generation the stop ended", so only that generation's drain waiters answered closed. Two cases fell outside: a freeze that arrived in the stop's window before the drain flag was set, and an older generation still parked when the stop ended the active one. Both answered drained or released, and the keeper and the core differed. The fix keys the answer on the stop's own commitment (`shutdownRequested`, set first in the stop's segment on tick and tickless lands). Every waiter answered after that sees it, whichever generation it holds and whenever it arrived.
- A deadline that fires for a party the event has since superseded must answer the way the woken party's own re-check does. The keeper's woken drain waiter checks its generation before its deadline, so it answers released, and the core's timer arm must also answer released. A test holds the timer after it fires (a hold point before it wakes the waiter) and registers the newer party, so the order isn't left to timing.
- Once a closing decision exists, refuse new waiters at admission; answering them closed when they wake isn't enough. In #987's round 1, a drain admitted after the stop committed still froze the land and installed its generation, and only its answer said closed. Resuming that generation put inputs the earlier freeze had held back into the queue, ahead of the stop's drain. The admission check runs before any state change or timer, and a test asserts the refusal while the stop's holds are still closed: released holds let the drain flag answer for the commitment, so a mutant that drops the commitment survives.
- Decide each waiter's answer in the segment that resolves it, on every path. The keeper's drain waiters used to read the land's state when their continuation ran. The core decided in the resolving step. So a stop committing between the two answered closed on one path and released on the other. Resume each continuation with its decided value.
