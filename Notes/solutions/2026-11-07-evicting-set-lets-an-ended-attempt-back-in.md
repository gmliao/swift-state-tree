---
module: SwiftStateTreeTransport
date: 2026-11-07
problem_type: bug_class
component: join-admission
symptoms:
  - "After a join timed out or its session disconnected, the queued admission still runs and kicks the player's live connection"
  - "The player ends up with no connection, and the router's cleanup can't restore the old one"
  - "Only on large or busy lands: it needs many other sessions to end while the admission waits"
root_cause: bounded_evicting_set_used_as_a_refusal_record
resolution_type: design_change
severity: medium
tags:
  - join
  - admission
  - timeout
  - eviction
  - token
related:
  - "#104"
  - "#239"
  - "#242"
  - "#243"
---

# An evicting set lets an ended attempt back in

## Problem

An admission still on its way to a land's membership queue was refused through the adapter's `EndedSessionSet` (`Sources/SwiftStateTreeTransport/TransportAdapter+Outbound.swift`), both when its join budget ran out (#239) and when its session disconnected. The set keeps the most recent `capacity` sessions, 4096 by default (#242):

1. Player P is connected as A, reconnects as R, and R's admission waits in the queue.
2. R hits `JOIN_TIMEOUT_MS` and goes into the ended set.
3. 4096 other sessions of the land end, and R is evicted.
4. R's queued admission now passes `staleJoinAttempt`, since A is older. The keeper's join kicks A, then the router undoes R.
5. P is left with no connection.

## Root cause

A bounded set that evicts is fine for "drop late frames for an ended session", where forgetting an old entry costs nothing. It is wrong as the only record that an operation must be refused, because eviction silently turns "refuse" into "allow".

A non-evicting set of refused attempts (the first proposal) doesn't work either: the adapter can't tell an admission still on its way from one that already ended, so for any removal rule some interleaving leaves an entry behind, for example a timeout that reaches the adapter after the admission already returned with a denial.

## Fix

PR #243 (open at the time of writing): a per-attempt token, `JoinAttemptEnd`. The router creates one per join attempt and passes it to the admission. The adapter marks it when the budget's timeout ends an admission that hasn't started, in the same segment as that decision (`endJoinBeforeAdmission`); the router marks it when the session disconnects during the attempt. The queued admission checks it before the keeper's join and is refused when it is marked. The token lives exactly as long as the admission that reads it, so there is nothing to bound or evict. `endedSessions` still drops late frames.

## Prevention

- When state answers "must this be refused?", give it the lifetime of the thing being refused (a token the operation carries), not a shared bounded collection.
- If a bounded collection is used for refusals anyway, write down what happens on eviction and test it.
- Test: shrink the capacity (here, to 1) so one more ended session evicts the attempt, assert the eviction precondition, then let the admission run and assert it is refused and the live session is untouched. Hold-driven, no timing.
