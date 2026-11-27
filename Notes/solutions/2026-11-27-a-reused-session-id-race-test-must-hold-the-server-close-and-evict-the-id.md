---
title: "A reused-session-ID race test must hold the server close's disconnect and evict the ID from the ended set"
module: SwiftStateTreeTransport
date: 2026-11-27
problem_type: testing_practice
component: join-path-tests
symptoms:
  - "A test that holds the router at .flipFailed after a supersede never arrives there and hits the suite's time limit"
  - "A routed join under a session ID that just disconnected is answered \"Join denied\" with staleJoinAttemptsRefused incremented"
  - "A reused-ID test never reaches the code it was written for, so it can't fail first"
root_cause: harness_order_not_the_race_under_test
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - hold-points
  - reconnect
  - generation
  - session
  - supersede
related:
  - "#941"
  - "#945"
  - "#956"
  - "#242"
---

# A reused-session-ID race test must hold the server close's disconnect and evict the ID from the ended set

## Problem

#941 and #945 are about an answer that reaches a later connection under the same session ID. Their tests (#956) need the old connection's answer to arrive after a new connection took the ID. Written as the plan described them, both tests missed the race, for two different harness reasons. One hung at its hold point. In the other, the second join was refused before it reached the code under test. Neither test could fail for the bug.

## Root cause

**1. A server close's disconnect beats a flip wait.** A supersede closes the old session with 4017. `WebSocketTransport.closeSession` calls `handleDisconnection` first, and the router's `onDisconnect` with it; only then does it close the connection. The router's disconnect ends the session's join attempt. The old join's flip wait resumes in a Task of its own, finds the attempt is no longer current (`isCurrent`), and returns without answering. A hold at `.flipFailed`, after that check, is therefore never reached. The window the bug needs, where the failure path has passed `isCurrent` while the disconnect is still on its way, is not the order a plain test produces.

**2. An ended session ID can't join again until it leaves the ended set.** The adapter records every ended session in `endedSessions`, and `staleJoinAttempt` refuses an admission for a session in it. A routed rejoin under an ID that just disconnected is answered "Join denied", before any membership the test wants to check exists. The set is bounded (`EndedSessionSet`, 4096 by default) and evicts its oldest entries. Only then is the rejoin admitted, which is the production path where a stale undo by session ID alone could remove it.

## Fix

- **#941, superseded row:** the test also holds the router at `.disconnectEntry` (arrival 1). Then:
  1. Wait for the failure path's `.flipFailed`.
  2. Open the disconnect hold and wait for the connection's close. `closeSession` closes only after the router's `onDisconnect` returned, so no poll is needed.
  3. Confirm the server's own disconnect callback (`handleDisconnection`), so the transport accepts a new connection under the ID.
  4. Reconnect, then release `.flipFailed`.
- **#945:** `setEndedSessionCapacityForTesting(1)`, wait for the old disconnect to reach the adapter (`router.waitForDisconnectForwardsForTesting()`), then end another session (`adapter.onDisconnect` of an unrelated ID) to evict the old one. #242's `timedOutAdmissionRefusedAfterEviction` does the same.

## Prevention

- In a test of a server-closed session (a supersede, a refused join, a failed flip), name every path that reacts to the close: the router's disconnect runs before the connection closes. Hold it at `.disconnectEntry` when the race under test is the other order.
- A test that reconnects and rejoins under the same session ID has to evict the ID from the adapter's ended set first, through a capacity of 1 and another session's end. Otherwise it tests the stale refusal, not the reuse.
- A test that hangs at its hold or is refused before the code under test is a harness that missed the race, not a passing fix. Check that it fails first, for the bug's reason (see [hold points, not timing](2026-11-05-hold-points-not-timing-in-race-tests.md)).
