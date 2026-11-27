---
title: "A harness that stands in for the loops must start each sync phase with an idle writer"
module: testing
date: 2026-11-26
problem_type: test_flake
component: differential-harness
symptoms:
  - "a differential golden differs on one CI leg only: one sync output fewer, every later stream index and sync sequence one lower"
  - "a tick output is recorded as sync-only on a slow runner"
root_cause: harness_phases_could_find_the_writer_busy_and_take_the_drain_retry_path
resolution_type: established_pattern
severity: medium
tags:
  - differential-harness
  - back-pressure
  - goldens
  - determinism
related:
  - "#908"
  - "#917"
  - "2026-11-26-read-the-failing-logs-codes-before-calling-a-flake"
---

# A harness that stands in for the loops must start each sync phase with an idle writer

## Problem

#908: on macOS CI the differential harness's record for `disconnect-during-keeper-join` had one sync output fewer than the golden, and every later stream index and sync sequence was one lower. Linux and local runs matched.

## Root cause

The harness turns the keeper's loops off and runs each tick and sync itself. A sync phase that finds the writer still holding an earlier sync-cycle element is deferred (`.deferredBackPressure`): it builds no output, and a land without periodic sync gets one writer-drain retry per binding. Whether a harness phase found the writer busy depended on how fast the recording connections took their frames. A probe that forces each phase busy in turn (`DiffBackPressureProbeTests`) shows every deferral changes the record:

- one deferral: the output is built by the retry or by the next sync, so a tick output becomes sync-only;
- two in a row: both requests share the one retry, so one output is missing.

## Fix

Before every sync it runs and before each tick, the harness waits for the writer's sync-cycle drain (`outboundWriter.waitForSyncCycleDrain()`, with no test override), and it waits again after the sync. The phases the keeper starts on its own inside a step wait too: a leave's turn (a disconnect, a kick, the stop's leaves) at the keeper's `leave` hold, and a join's sync turn at the adapter's `joinSyncRequested` hold. There the harness first waits for the keeper's input drain to go idle (tickless), then for the writer. A first version drained only around the harness's own syncs; review found two keeper-started pairs (the stop's two leaves, a kick followed by the replacement's join sync) that could still meet a pending element. No phase starts behind a pending element, so no run depends on the connections' speed. The goldens didn't change: they were recorded without back-pressure. The run reports its deferrals beside its differences (not compared), and the sweep fails a cell that deferred a phase outside the scenario that forces the back-pressure. It also fails that scenario if it reports none.

## Prevention

- List every place a phase starts, not only the ones the harness calls: the component under test starts some on its own (here leaves, kicks and join syncs), and those need the same settling.
- A harness that replaces a timer or a loop with explicit steps must also remove the timing-dependent conditions the loop would have absorbed. Here that condition was the writer's backlog; it could be another queue's depth or an in-flight cycle. Settle it at each step, and count it, so a run that met it says so.
- Don't loosen the oracle where the condition hits. That's exactly where a real merge bug would show.
- Test the behaviour under the condition in its own row, which forces it with a gate or an override. Then check that the row really forced it.
