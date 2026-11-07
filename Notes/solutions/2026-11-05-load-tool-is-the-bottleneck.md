---
module: Examples/GameDemo (ws-loadtest, ServerLoadTest)
date: 2026-11-05
problem_type: measurement_pitfall
component: load-testing
symptoms:
  - "RTT tails grow with load, read as server-side queueing"
  - "Server CPU per player looks higher than the per-room design suggests"
  - "Periodic CPU and latency spikes on the server, in step with the client's send period"
  - "A suite reports \"3 runs\" or a passing phase when fewer runs happened or joins were rejected"
root_cause: load_generator_artifacts_measured_as_server_behaviour
resolution_type: tool_fix_and_method_rule
severity: high
tags:
  - measurement
  - load-test
  - rtt
  - coordinated-omission
  - methodology
related:
  - "#105"
  - "#106"
  - "#107"
  - "#134"
---

# The load tool is the bottleneck

## Problem

Several defects in the load generators were measured as server behaviour:

- **Every connection in its own land (#105).** ws-loadtest opened `rooms × playersPerRoom` connections, but each joined a different land (`landInstanceId = ${phaseName}-${workerIndex}-${i}`). "500 rooms × 5" was 2500 one-player lands, so per-room work (one broadcast encode per room, events to several recipients) was never exercised as the scenario said.
- **Lockstep sends and the wrong RTT origin (#106).** One `setInterval` per worker sent for all of its clients in the same millisecond, all connections opened at once, and RTT was timestamped at the actual send. The server saw synchronized bursts; RTT mixed in client-side queueing, and sends the timer skipped were never measured (coordinated omission).
- **Bursty ServerLoadTest (#107).** Each second's actions went out as one burst, and the loop drifted against the sampler.
- **Silent suite errors.** ws-loadtest passed a phase even when joins were rejected (#134). The scalability script ignored `--runs` with a room list, so each room count ran once (`a398f5d5`), skipped room counts after a TIME_WAIT wait (`e6f30a74`), and exited zero when a run failed or was skipped (`15986f23`).

## Root cause

The client was never measured as a component. Its own CPU, its event-loop delay and its send schedule weren't in the report, so client artifacts were indistinguishable from server behaviour.

## Fix

- `--layout rooms` (default) puts `playersPerRoom` players in each land; `--layout per-connection` keeps the old topology for bridging older numbers ([ws-loadtest README](../../Examples/GameDemo/ws-loadtest/README.md), "Room layout and connections").
- `--send spread` staggers sends, `--connect ramp` ramps connections, and RTT runs from the **intended** send time, with unanswered requests counted by intended send time ([METRICS.md](../../Examples/GameDemo/ws-loadtest/METRICS.md)). The full list is in METRICS.md, "Method changes since February 2026".
- Reports carry the client's CPU per worker and its worst loop delay, and the scalability script fails loudly.

## Prevention

- Before reading a latency or CPU number as the server's, check the client: its CPU, its loop delay, and whether its send schedule is what the scenario says. A tail that moves with the client's settings belongs to the client.
- Measure from the intended send time, so a stalled client shows up as latency instead of disappearing.
- Check that the topology is what the scenario claims (lands count, players per land) in the report.
- A suite script must refuse options it doesn't honour and exit nonzero when a run fails. Silently doing less than asked is the worst failure for a measurement tool.
- State method changes next to old numbers; see [the multiroom-load-2026-11 topic](../../deep-research/multiroom-load-2026-11/README.md), "Comparison columns", for how the February numbers are qualified.
