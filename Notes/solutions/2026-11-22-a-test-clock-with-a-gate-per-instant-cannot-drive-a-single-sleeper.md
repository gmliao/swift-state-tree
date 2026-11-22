---
module: SwiftStateTurns
date: 2026-11-22
problem_type: testing_practice
component: test-clock
symptoms:
  - "a test opens a later deadline's gate and nothing fires"
  - "a generated-order test passes a later instant before an earlier one"
  - "after moving to one shared timer, a test waits for a deadline that never wakes"
root_cause: test_clock_gates_each_instant_independently
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - test-clock
  - timers
  - deadline
  - monotonic-time
  - turns
related:
  - "#621"
---

# A test clock with a gate per instant can't drive a single sleeper

## Problem

The turn core's tests drove time with one fixture gate per instant: a sleep until N waited at `"deadline N"`, and the test opened that gate. Every deadline and timer had its own sleeping task, so opening `"deadline 60"` woke exactly that task. #621 item 2 replaced those tasks with one sleeper per core, which sleeps until the earliest armed instant. Opening `"deadline 60"` then woke nothing while an earlier entry, even a stale one, was still the sleeper's target. The `room` example in `ConceptsTests` shows it: its completed 5 s save deadline stays the head, so opening `"deadline 60"` alone can't fire the idle timer at 60.

## Root cause

Independent gates let a test say "60 has passed" while 5 hasn't. Real time never does that, and a single sleeper depends on it: it only learns about 60 after it has woken for 5. The generated-order harness used the same freedom on purpose. It opened a random open request's gate, which is "deadline 9 passes before deadline 3".

## Fix

`TestClock` became monotonic, after `swift-clocks`' `TestClock`:
- `release(through:)` raises a horizon and wakes every sleep until an instant at or before it, in instant order. A later sleep until a released instant returns at once.
- `advance(to:)` is `set` plus `release(through:)`. `set` never moves `now` back.
- A sleep that starts waiting opens `"sleeping deadline N #k"`, and `holdAfterWake(N)` holds a woken sleep at `"resume deadline N"`, so tests wait for events instead of polling.

Every `f.open("deadline N")` became a release. The generated-order harness advances the clock to one pending item's instant and waits for every request deadline and timer due by then.

## Prevention

- A test clock models time as one ordered horizon, never one gate per instant: the code under test may share one sleep across many deadlines.
- A test that needs "the fire ran late" moves `now` forward (`set`); it never releases a later instant while an earlier one is pending, unless that is what it checks.
- When a change merges per-item sleeps into one, grep the tests for gates or waits named after single instants first: each one assumes a sleep per item.
