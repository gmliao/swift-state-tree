---
module: Examples/GameDemo (ws-loadtest)
date: 2026-11-08
problem_type: measurement_pitfall
component: input-to-visible-latency
symptoms:
  - "input-to-visible: almost every input timed out, with the server healthy"
  - "inputToVisible seen about 5 % of sent, the seen ones with plausible latencies"
  - "the same in an unimpaired control as under impairment"
root_cause: client_side_matcher_keyed_to_one_wire_shape_of_a_value_whose_encoding_changed
resolution_type: code_fix
severity: high
tags:
  - measurement
  - load-test
  - encoding
  - wire-format
  - methodology
related:
  - "#271"
  - "#301"
---

# A client-side matcher keyed to a wire shape breaks silently when the encoding changes

## Problem

ws-loadtest times an input from its send to the first state frame that shows its point
(`--input-latency on`). After #271, runs in the opcode encodings timed out about 95 % of their
inputs in every phase, the unimpaired control included, while the server was healthy and every
other metric was normal. The inputs that were seen had plausible latencies, so the report looked
like a slow or lossy echo, not a broken measurement.

## Root cause

#271 sends atomic values positionally in the opcode encodings: a `Position2` is `[x, y]` on the
wire, also nested in added objects, first syncs and (since #301) merged entries. Events stay
keyed. The matcher only looked for the keyed `{ v: { x, y } }`, so it never found an echo in the
state. It also scanned the whole frame, so an opcode-107 frame's events still matched now and
then: a `PlayerShootEvent.from` equals the player's position, which is the target once it arrives.
In a local unimpaired messagepack run at main, the old matcher saw 72 of 3291 inputs (2.2 %), all
of them in the events part and none in the state part. That is where the archived runs' few "seen"
inputs came from too, at a later time than the real echo. JSON mode stayed keyed and was not
affected.

## Fix

The matcher (`input-latency.ts`) finds the positional `[x, y]` as well as the keyed form, and only
in a frame's state part (`statePartOf`: the second element of an opcode-107 frame). A test replays
GameServer frames recorded at main in all three encodings (with merged entries) through the real
SDK decoder: every new `targetPosition` must be found in the frame that sets it. The old matcher
fails it.

The failure is now loud. A phase fails when fewer than `--input-latency-min-seen` (default 0.95) of
its inputs were seen, with a message naming the matcher; unimpaired, every input is seen
(2997 of 2997 messagepack, 2998 of 2998 JSON, in a 10-room local run). Runs whose phase holds an
impairment set it to 0, and the network-impairment analysis gates the baseline segment instead:
under 95 % seen there is a missing input that fails every criterion.

## Prevention

- A client that recognises a value by its wire shape breaks when the encoding changes, and the
  failure looks like a measurement (timeouts, a low share), not an error. Gate the hit rate in a
  condition where it must be near 100 %, and make it fail the run.
- Test such a matcher against frames from the real encoder in every encoding, not against
  hand-written frames in the shape the matcher expects. Re-record those frames when the wire
  format changes (`scripts/record-frames.mjs`).
- Scan only the part of a frame the metric is about: an event that carries the same value can
  match by accident and makes a broken matcher look partly working.
