---
title: "A machine added to a gated bench binary moves its gated cells"
module: SwiftStateTurns
date: 2026-11-21
problem_type: measurement_pitfall
component: turns-bench
symptoms:
  - "a gated TurnsBench cell moves by tens of instructions per op on a change whose new paths fold away on the bench's machine"
  - "nm shows `merged generic specialization <BenchMachine>` thunks of a few bytes where base has the full specialization"
  - "check-turns-inlinable reports a specialization missing that the code still makes"
root_cause: llvm_function_merging_folds_identical_specializations_of_two_bench_machines_into_one_body_behind_thunks
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - turns
  - measurement
  - benchmark
  - instruction-gate
  - specialization
  - function-merging
related:
  - "#725"
---

# A machine added to a gated bench binary moves its gated cells

## Problem

The post lane (#725) added two machines to `TurnsBench` for its own lane-on and lane-off cells. Every lane path is behind a static gate, so on `BenchMachine` (`LaneReport == Never`) the driver's code should not change. The instruction gate still failed: `call` rose from 2945.10 to 2977.06 instructions per op (+32, limit 14.7), while `idle` and `emit` stayed flat. `check-turns-inlinable` also failed: it found no `settleQuiescence` specialization on `FollowUpBenchActor`.

## Root cause

LLVM's function merging. The new machines' specializations of the core's generic code were identical, or nearly identical, to `BenchMachine`'s and `FollowUpBenchActor`'s. The linker kept one body and turned the others into thunks that call it, with the differing values passed as extra arguments. `nm` showed it: `Runtime.park` on `BenchMachine` went from a 443-byte specialization to a 28-byte `merged generic specialization` thunk, and `closeRequests` from 1021 to 31 bytes. The thunk hop costs instructions on the gated path. `check-turns-inlinable` matched only lines that start with `generic specialization`, so a merged one looked missing. A TurnsBench built from the same head without the two machines measured base's `call` exactly (2945.07).

## Fix

- The lane cells moved to their own executable target, `TurnsLaneBench`, so their machines can't merge with TurnsBench's. The gated cells then measured base's counts (`call` 2945.04).
- `check-turns-inlinable` accepts `merged generic specialization` as a specialization. Its negative control still holds, since without `@inlinable` there is nothing to merge.

## Prevention

- A gated bench binary holds only the machines it gates. New cells for another machine get their own target.
- When a gated cell moves on a change that should fold away, diff the specialized symbols of base and head (`nm -S` plus `swift demangle`) before reading the code: new `merged` thunks, or sizes that shrink to a few bytes, point at the binary, not the library.
- Confirm by building head without the new machines. If the cell returns to base, the cost is the binary's layout.
