---
title: "A test barrier that finds its target through live state skips the targets being torn down"
module: SwiftStateTreeNIOTests
date: 2026-11-26
problem_type: testing_practice
component: differential-harness
symptoms:
  - "a barrier meant to wait for a close returns at once, and the capture reads the connection before its close frame"
  - "a harness wait guards on `connectionGeneration(for:)` or another lookup and `continue`s when it is nil"
  - "a golden mismatch that appears only when the close is in flight"
root_cause: barrier_selects_its_target_by_current_transport_state_which_teardown_already_removed
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - barrier
  - differential-harness
  - close
  - teardown
related:
  - "#909"
  - "#908"
  - "2026-11-10-a-returned-send-is-not-a-delivered-frame"
---

# A test barrier that finds its target through live state skips the targets being torn down

## Problem

#909 moved a superseded session's 4017 close behind its queued frames: the transport's drain closes the connection when it reaches the close marker. The first version of the harness barrier waited for each such close only when `transport.connectionGeneration(for: session)` still matched the close's generation. Review found the gap. At the marker, `closeSession` runs `handleDisconnection` first, which removes the session's queue, and only then sends the close frame. In that window, the lookup returns nil, the guard skips the connection, and the capture can read it before its 4017.

## Root cause

The barrier chose what to wait for by asking the system under test what exists now. A target in the middle of being torn down is exactly what the barrier is for, and exactly what that lookup no longer reports.

## Fix

The harness records each attempt's generation when the transport accepts its connection (`DiffAttempt.generation`). The barrier finds the connection for each close by session and recorded generation, and waits on it, whatever the transport reports at that moment. It skips only an attempt the scenario disconnected itself: its queue was retired, so its marker is never read.

## Prevention

- Key a barrier on what the test recorded when the target was created (an ID, a generation, a handle), not on a lookup of live state.
- When a wait has to skip some targets, skip them by a fact the test owns (the scenario disconnected this attempt), never by "the system no longer lists it".
- Review a barrier against the teardown order of what it waits for: list the steps between "removed from the table" and "the observable effect" (here, the leave, then the close frame). A barrier that reads the table falls into that gap.
