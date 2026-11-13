---
module: Examples/GameDemo (EncodingBenchmark)
date: 2026-11-13
problem_type: measurement_pitfall
component: load-testing
symptoms:
  - "Inputs are submitted and accepted, with no error frame, but the state never changes"
  - "An input benchmark measures decode cost while the handlers never run"
  - "A run with injected moves reports applied 0"
root_cause: input_takes_effect_in_a_phase_the_run_does_not_configure
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - measurement
  - benchmark
  - methodology
  - inputs
  - tick
related:
  - "#540"
  - "#521"
---

# An input that takes effect only in a later phase, measured without that phase

## Problem

EncodingBenchmark's `--inputs-from-wire` sends hero-defense `MoveTo` events to the adapter as client frames (#540). With the hero runner's default `--ticks-per-sync 0`, a smoke run submitted 40 frames, got no error frame back, and applied none: the moves sat queued and the `MoveTo` handler never ran, in both `IN_TURN_SYNC` modes. Nothing in the timing or the bytes showed it. The run measured the transport's decode and the queueing, not the workload it was named for.

## Root cause

A hero-defense event is applied on the land's next tick, not when the adapter receives it. The run configured no tick, so the phase where the input takes effect never happened. The same shape applies to any input whose effect lands in a later phase: a tick, a sync, a flush, a batch boundary. Counting at submission (frames sent) or acceptance (no error frame) can't see it, because both happen before that phase.

## Fix

- The run counts **applied** where the effect happens: a per-room `InputProbe` that the handler notes once it changed the state (only in the found-player branch for `MoveTo`). It records submitted, accepted (submitted minus error frames) and applied per room, and exits 1 unless all three equal the expected count in every room (#540).
- `--inputs-from-wire` refuses hero-defense with `--ticks-per-sync 0` at startup (exit 2), since such a run can never apply its inputs.

## Prevention

- When a benchmark or load test injects inputs, count them where they take effect, not where they are sent, and fail the run on a mismatch. A count taken before the phase that applies them overstates the workload.
- Check which phase applies each input kind (event vs action, tick vs immediate) before choosing the run's defaults. A configuration that skips that phase should be refused at startup, not caught at the end.
- Count per room or per unit, not only in total, so a shortfall in one place can't cancel an excess in another.
- Related: [A counter incremented at plan or send time overcounts when the target goes away in between](2026-11-08-counter-at-plan-time-overcounts-when-target-goes-away.md), [A benchmark option honoured on one path only](2026-11-07-benchmark-option-honoured-on-one-path-only.md).
