---
module: SwiftStateTurns
date: 2026-11-21
problem_type: performance_collapse
component: turn-driver
symptoms:
  - "TurnsBench emit and call instructions per op rise after a feature the bench's machine doesn't use (emit +11.9 %, call +3.8 %)"
  - "idle (a step that skips runSegment) doesn't move"
  - "perf report shows Hasher or another stdlib symbol's share doubling, but its call count is unchanged"
root_cause: per_segment_checks_for_an_optional_feature_ran_for_every_machine_and_a_call_per_segment_cost_a_frame
resolution_type: established_pattern
severity: medium
tags:
  - turns
  - driver
  - performance
  - instruction-gate
  - specialization
  - measurement
related:
  - "#702"
  - "2026-11-20-a-budget-break-strands-the-work-kinds-after-it.md"
---

# A feature path in the driver costs machines that don't use it

## Problem

#702 added follow-ups and the quiescence wait to `runSegment` and `drainProducts`. On the bench's machine, which declares no follow-ups, the §10 instruction gate measured emit at 1025 → 1147 instructions per op and call at 2956 → 3068. The plan's estimate had been "a few per segment".

## Root cause

No one check was at fault. Removing one addition at a time (one variant build each, `perf stat -e instructions:u`, n minus n = 0) gave the emit saving of each:
- the epilogue (the follow-up job check plus a `settleQuiescence()` call): 67;
- the `followUpsToStep` pop in the loop: 31;
- the gate-launch check in the drain: 19;
- the deadline-sweep condition: 4;
- the `capped` path: 4.

Every one ran on every segment of every machine. A call per segment to an out-of-line function cost a whole frame even when its first line returned.

The profile misled at first. Its Hasher share doubled (7 % → 15 %), but lldb hit counts showed the same two hashes per op on both sides. The real per-op difference was smaller and spread out.

## Fix

- `TurnCore.usesFollowUps` is `M.FollowUpSlot.self != Never.self`, a constant once the core is specialized. Every follow-up path in the driver is gated on it, so it folds away for a machine that keeps the default. The specialized `runSegment` came out at 942 bytes against base's 916.
- The waiter check that stays generic (a wait can count requests and timers on any machine) runs inline at the call site, `if !core.quiescenceWaiters.isEmpty { settleQuiescence() }`, not inside the call.

The result was emit at 1037 and call at 2958. About 5 of emit's remaining +12 is codegen: LLVM merged identical new array specializations, and the `outputs` append now goes through a thunk.

## Prevention

- A feature whose state is keyed on an associated type with a `Never` default gets a static gate on that type, and every per-segment path for it checks the gate first.
- Keep per-segment epilogue checks inline: test the condition at the call site, and call out only when there is work.
- Before trusting a profile's shares, count calls: lldb breakpoint hit counts at n and at n = 0, per side. Bisect with variant builds that each remove one addition, rather than reading the diff.
