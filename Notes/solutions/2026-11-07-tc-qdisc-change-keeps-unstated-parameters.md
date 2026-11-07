---
module: Examples/GameDemo (ws-loadtest impair.sh)
date: 2026-11-07
problem_type: measurement_pitfall
component: network-impairment
symptoms:
  - "Impaired clients don't converge after the impairment is lifted"
  - "An impaired connection goes stale or stays behind long after the lift"
  - "The after-snapshot of a lift still shows a rate limit"
root_cause: tc_qdisc_change_keeps_optional_netem_parameters
resolution_type: tool_fix_and_check
severity: high
tags:
  - measurement
  - network-impairment
  - netem
  - tc
  - methodology
---

# `tc qdisc change` keeps netem parameters you don't restate

## Problem

A combined profile (delay, jitter, loss and a rate limit) was lifted with `tc qdisc change dev veth-c1 root handle 1: netem delay 0ms limit 168`. The timeline's after-snapshot of that lift showed `qdisc netem 1: ... limit 168 rate 134904bit`: delay and loss were gone, the rate limit was not. The "recovery" phase and the convergence check then ran at 135 kbit/s shared by every impaired connection. Half the impaired clients went stale and were closed by the client's own stale detector; the rest were still draining a backlog when the convergence check's cap ended. It looked like a convergence failure.

## Root cause

`tc qdisc change ... netem` resets the base options a command omits: delay, jitter and loss went to zero, and `limit` goes to 1000 (seen earlier, which is why every change already passed it). `rate` is not a base option; tc sends it only when the command names it, and a `change` without it kept the old limit. The script changes in place on purpose (queued packets and counters survive a boundary), and its lift named only the base parameters.

## Fix

- Every profile states every parameter the script uses: `delay <d> [<jitter>] loss <p>% rate <r>`, with `rate 0bit` for none, plus the setup's `limit`.
- After each change, `scripts/netem-check.mjs` parses the `tc -s qdisc` after-snapshot and compares both shaped netems with the profile (rate within tc's whole-bytes-per-second rounding). A mismatch fails the command after its timeline entry is written. The test feeds it the captured dump of the faulty lift.

## Prevention

- With `tc qdisc change`, restate every parameter the qdisc has ever been given, not only the ones that change. Or replace the qdisc, when losing its queue is acceptable.
- Check the kernel's view after every change, from its own dump, against what the profile asked for; don't trust a command's exit status to mean the qdisc looks like the command.
- When a run fails only under one profile, compare that profile's after-snapshots first: the impairment may not be what the timeline's profile name says.
