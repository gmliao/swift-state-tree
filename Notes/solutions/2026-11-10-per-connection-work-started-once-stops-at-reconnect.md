---
module: ws-loadtest
date: 2026-11-10
problem_type: measurement_pitfall
component: send-schedule
symptoms:
  - "inputsSent median 0 in the recovery windows of the impaired group"
  - "recovery sends = expected sends minus the keys that reconnected"
  - "a reconnected connection receives state but never sends an action or event again"
root_cause: per_connection_loop_started_by_a_one_shot_join_hook
resolution_type: code_fix
severity: high
tags:
  - ws-loadtest
  - measurement
  - reconnect
  - timers
  - testing
related:
  - "deep-research/network-impairment-2026-11"
---

# Per-connection work started once stops at the first reconnect

## Problem

With `--reconnect on-server-close`, a connection that the server closed reconnected, joined and received state again, but sent no action or event for the rest of the phase. In the network-impairment run, the impaired group's recovery windows showed a median of 0 inputs sent for the slow-reader and burst-loss profiles. For the rate-limited profile, the recovery sends were the expected count minus the number of keys that reconnected.

## Root cause

Each connection's spread send loop (`worker-runner.ts`) re-armed its timer only while `client.isUsable()`, so it stopped once the connection closed, as intended. The only thing that started it was `client.onJoined(...)`, and `WorkerClient` dropped its join callbacks after the first join. A reconnect's join therefore fired nothing, and the loop stayed stopped. The event loop had the same shape. Lockstep mode was not affected, because its single timer checks `isUsable()` on every tick and never stops.

The reconnect tests checked the reconnect record (attempts, downtime, first sync) and the active spans, but nothing checked that the connection kept sending afterwards.

## Fix

`WorkerClient.onJoined` now calls its callback on every join, a reconnect's included, and returns a function that removes it. `runSendLoop` (`send-schedule.ts`) runs one connection's sends for both actions and events:
- every join restarts the schedule from the join time, so the outage's slots aren't sent in a burst;
- it holds at most one timer, so a repeated join can't double the rate;
- its stop function removes the join callback and clears the timer.

`tests/send-loop.test.ts` drives a real `WorkerClient` through join, server close, reconnect and second join, and checks that the rate resumes with no outage slots sent. A second test counts timers across a repeated join, a close and `stop()`. Each test fails under its mutant: one-shot join callbacks, and `arm` without clearing the previous timer.

## Rule

- Per-connection work that a join starts must be started by every join, not the first one. Hook it to an every-join callback that the work's owner removes when it stops, rather than a one-shot callback list that is cleared after firing.
- A restartable timer loop holds one timer handle and clears it before arming, so a second start can't run two chains.
- A reconnect test asserts that the connection resumes its work (sends at the configured rate), not only that it rejoined.
- A load-tool fix that changes what a measured run sends changes the data's meaning: name the tools commit that is the boundary and the metrics it affects, and keep runs from either side of it apart.
