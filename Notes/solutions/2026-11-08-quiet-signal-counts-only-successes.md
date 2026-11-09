---
module: deep-research
date: 2026-11-08
problem_type: measurement_pitfall
component: external-input-failure cell driver
symptoms:
  - "abandonedResolvers didn't read 0 within 11500 ms"
  - "the gauge is flat during the load and never reaches 0 in the tail"
  - "resolverTimeouts keeps counting after the load client stopped sending"
root_cause: quiet_signal_counted_only_successes_and_offered_rate_exceeded_service_rate
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - deep-research
  - load-test
  - backlog
  - methodology
related:
  - "deep-research/external-input-failure"
---

# A quiet signal that counts only successes, and an offered rate above the service rate

## Problem

The external-input topic's `framework-deadline-ignored` cell stopped on the measurement host: after the sends stopped, the `abandonedResolvers` gauge never read 0 within its bound. The cooperative `framework-deadline` cell had passed the same drain gate.

## Root cause

Two faults in the cell driver, neither in the framework:

1. **The quiet signal counted only successes.** `cell.py` took "the sends have stopped" from two profiler intervals with `actions == 0`. The profiler's `actions` counts only actions that succeeded (`TransportAdapter.handleActionRequest` increments it after the keeper answers); a timed-out action counts in `errors`. In a cell where every action times out, `actions` is 0 for the whole run, so "quiet" fired on the first tail line while the server was still busy.
2. **The offered rate was above the service rate.** A session's inputs go through one serial inbound chain: an action whose resolvers are running holds that player's later actions until it is answered. The deadline cells offered 2 actions/s per player against a hold of up to 1000 ms (the framework deadline), so each session served 1/s and queued one more message every second. `inboundQueuedMessagesMax` climbed by one per second; after a 60 s steady phase about 60 actions per session were still queued, and the server kept handling (and timing out) them for about a minute after the client stopped.

With cancellation ignored, every handled action leaves an abandoned resolver running for 500 ms more, so the gauge stayed above 0 while the backlog drained. With cooperative cancellation the gauge was 0 throughout, so the same backlog passed the drain gate without the gate testing anything.

## Fix

In `deep-research/external-input-failure`:
- quiet is two consecutive profiler lines with `messagesReceived == 0`: the server handled nothing (`cell.quiet_point`);
- the deadline cells offer 0.5 actions/s, and `cells.check` refuses any cell whose `actions_per_second × hold_ms` reaches 1000 (offered ≥ served per session);
- a no-backlog check: over the load, no session may queue more than `BACKLOG_BOUND` (4) messages; `cell.py` stops the cell and `collect.py` gates on it (`no_backlog`).

## Prevention

- A "the load has stopped" signal must count everything the server handles, not one outcome. Test it with a run in which every request fails.
- Check that each session's offered rate is below what it can serve, given that a session's inputs are handled one at a time: rate × the longest hold < 1. Put the check in the matrix's source, so a cell that would build a backlog can't run.
- Gate on a queue-depth signal over the load. A backlog otherwise shows only as later work, which a drain gate on one resource can miss.
- A gate that passes in every cell should be shown to fail on the case it guards (a mutation run), not only to pass.
