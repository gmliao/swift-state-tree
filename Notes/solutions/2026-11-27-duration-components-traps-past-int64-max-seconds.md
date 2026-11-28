---
title: "`Duration.components` traps past Int64.max seconds; convert caller durations through `attoseconds`"
module: SwiftStateTree
date: 2026-11-27
problem_type: gotcha
component: safe-task-sleep
symptoms:
  - "SIGILL with `Swift/Integers.swift:3641: Fatal error: Not enough bits to represent the passed value`"
  - "a sleep or timeout given a huge caller-supplied Duration stops the process"
root_cause: duration_components_converts_seconds_to_int64
resolution_type: code_fix
severity: medium
tags:
  - duration
  - safe-task-sleep
  - trap
  - overflow
related:
  - "#963"
  - "#959"
---

## Problem

`safeTaskSleep(for:)` read `duration.components` before its guards. `Duration.components` converts the seconds part to `Int64`, so `(Duration.seconds(Int64.max) + .seconds(1)).components` stops the process. Measured on Linux with Swift 6.4.3: SIGILL in debug and release alike, `Swift/Integers.swift:3641: Fatal error: Not enough bits to represent the passed value`. The sum itself is fine: `Duration` holds 128 bits, and `attoseconds` (`Int128`) reads it back.

A caller-supplied duration that large therefore trapped inside the sleep, and so did every helper that sleeps a caller's budget.

## Root cause

`components` is a narrowing read. The guards that followed it (`seconds >= 0`, `UInt64(exactly:)`, overflow checks) looked like overflow handling, but they ran after the trap.

## Fix

Compute from `duration.attoseconds`: a negative value returns at once, otherwise nanoseconds are `attoseconds / 1_000_000_000`, clamped to `UInt64.max`. The turn core's barrier wait (#959) had the same trap and reads `attoseconds` too.

## Prevention

- Convert a duration that a caller supplies through `attoseconds` (`Int128`), never `components`. `components` is fine only for a value whose size the code bounds itself (a measured interval, a `min(..., cap)`).
- `SafeTaskSleepForTests` pins it: a `.seconds(Int64.max) + .seconds(1)` sleep, cancelled at once, must end with `CancellationError`; with the `components` read restored the test process stops.
