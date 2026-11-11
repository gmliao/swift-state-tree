---
module: deep-research
date: 2026-11-10
problem_type: measurement_pitfall
component: network-impairment-analysis
symptoms:
  - "recoveryMs: not recovered, not recovered, not recovered for the impaired group of SR, BO75 and RATE, while per-session recovery shows every session rebuilt by a firstSync"
  - "every recovery window of the group is insufficient (inputsSent below the minimum), or fails the sends share"
  - "sync-lag cross-check: fail (resyncs: clients 1676, server 2107) in RATE"
root_cause: unjudgeable_result_printed_as_failure
resolution_type: tool_fix_and_method_rule
severity: high
tags:
  - deep-research
  - measurement
  - load-client
  - reconnect
  - sync-lag
  - testing
related:
  - "#422"
  - "2026-11-10-per-connection-work-started-once-stops-at-reconnect"
  - "deep-research/network-impairment-2026-11"
---

# Unmeasured is not a failure

## Problem

The first network-impairment set printed "not recovered" for the impaired group's recoveryMs in SR, M-BO75, U-BO75 and U-RATE, in every repeat. In the same runs, per-session recovery showed every impaired session rebuilt by a firstSync. A reader would take the first table as a server result. It wasn't one: nothing had been measured.

The same set failed U-RATE's sync-lag cross-check: the clients counted about 450 fewer resyncs than the server.

## Root cause

- **The load client.** In its spread and event send modes, ws-loadtest stopped a connection's actions and events once it reconnected (#422). Lockstep mode checks every tick and wasn't affected. Each send timer re-armed only while the connection is usable, and its only restart, the join callback, was cleared after the first join. Fixed in f90471d4; the client side is [Per-connection work started once stops at the first reconnect](2026-11-10-per-connection-work-started-once-stops-at-reconnect.md). Groups whose sessions all reconnect (SR, BO75) sent no inputs in the recovery segment. RATE's sent only from the sessions that never reconnected: 1500 − 652 = 848, which is the recovery's sends median exactly.
- **The rule.** `recovery_ms` returned `None` both when no run of healthy windows fitted and when no window could be judged (too few inputs). The table printed `None` as "not recovered". So "couldn't judge" and "judged and failed" looked the same.
- **The cross-check.** "Clients' resyncs equal the server's" assumes every frame the server sends arrives. Under a throttle, a server close drops the frames still queued behind it. In U-RATE r1 only 84 of 329 server 4010s reached the client as a 4010 close frame.

## Fix

- `regenerate.py` marks a group recovery that can't be judged as insufficient, never "not recovered". The group must have been fully joined for `RECOVERY_RUN` windows in a row, but never fully joined with enough inputs sent (at least `MIN_INPUT_SAMPLES` and `MIN_SEND_SHARE` of the target) for `RECOVERY_RUN` windows in a row. A group that was never fully joined that long has sessions missing, not silent, and stays "not recovered".
- The #422 label needs reconnects in the group and a run commit that predates the fix. That is checked by git ancestry (`git merge-base --is-ancestor f90471d4 <commit>`), so a run at or after the fix with an unloaded recovery gets the generic label.
- The Results lead-in names the unmeasured rows and what they don't affect. It's generated only while such a row exists.
- In RATE and COMBO, fewer clients' resyncs than the server's is reported as "in flight at close", with the totals' difference. The shortfall must be at most the number of sessions closed in the run, whatever the cause: a `connectionLost` drops queued frames too, and the server keeps at most one resync unacked per session. The server counts resyncs per run, so the difference can't be attributed per connection. More clients' resyncs than the server's, or a shortfall over that bound, still fails.
- Tests cover each label (no inputs with and without reconnects, a sends shortfall, loaded windows that never run five in a row, loaded windows that miss the band), the lead-in, and each branch of the RATE rule.

## Prevention

- A table cell that can mean "couldn't judge" or "failed" needs two values. Let the rule return why it couldn't judge, and print that. Tell silent subjects (there, too few inputs) from missing ones (not there).
- A label that names a known cause should be keyed on the evidence for that cause (here, the run's commit against the fix), not on the symptom alone.
- When one table says a group failed and another says its sessions recovered, check the inputs each table reads before reading either as a result. Here, the per-session table read received updates and the group table read sent inputs.
- A count cross-check between sender and receiver must say what may be lost between them: a close drops frames still queued. Gate the loss by the event that causes it (any close, under a throttle) and bound it by what the sender can have outstanding (one unacked resync per session). Keep failing everything else.
- The load client's behaviour after a reconnect is part of the measurement. A test should pin that a reconnected connection sends again (#422).
