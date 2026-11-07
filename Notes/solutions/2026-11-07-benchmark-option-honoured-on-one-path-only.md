---
module: Examples/GameDemo (EncodingBenchmark, ServerLoadTest, ws-loadtest)
date: 2026-11-07
problem_type: measurement_pitfall
component: load-testing
symptoms:
  - "Active-input and passive-input runs give the same bytes per sync"
  - "A flag is accepted without error but the result doesn't change"
  - "A result field the model declares is always missing from the JSON"
  - "A suite script rejects an option that the per-run script accepts"
  - "A one-room run reports a different player count or 0 monsters"
  - "A per-run output written twice under one name keeps only the second run"
root_cause: option_parsed_but_dropped_on_some_code_paths
resolution_type: tool_fix_and_method_rule
severity: high
tags:
  - measurement
  - benchmark
  - load-test
  - methodology
related:
  - "9027f4a1"
  - "f375c89a"
  - "f7f79e3b"
---

# A benchmark option honoured on one path only

## Problem

Measurement tools accepted inputs and then did less than asked, without an error:

- **EncodingBenchmark** parsed `--active-players` and `--monster-cap` into its config, but only the `--scalability` path passed them to `runMultiRoomBenchmark`. The single-format, all-formats and serial-vs-parallel multi-room paths called it with the defaults, so an "active players" run on those paths measured passive input. Once the flags reach the runner, a 4-room smoke sends 19,415 bytes passive and 153,910 active.
- **EncodingBenchmark with `--rooms 1`** took a legacy single-room path that runs a different land (its own encoding-benchmark state, not Hero Defense) with `--players` (default 10), and ignored `--players-per-room`, `--ticks-per-sync`, `--monster-cap` and `--active-players`. A "hero-defense, 1 room, 5 active players" run reported 10 players and 0 monsters.
- **ServerLoadTest** declared CPU and RSS fields on its per-second sample and its summary, but nothing filled them, and nil fields were left out of the JSON. Its results had no resource data, and nothing said so.
- **EncodingBenchmark `--scalability`** ignored `--parallel`: it always ran a serial and a parallel pass and reported both, so `--parallel false` changed nothing. When per-run output was added (`--capture-views`, one directory per run), the parallel pass wrote over the serial pass's files under the same name, and the gate that read them checked only the parallel pass.
- **`run-scalability-test.sh`** forwarded only three of `run-ws-loadtest.sh`'s client options. `--layout` and `--connect` failed with `Unknown option`, so a documented suite command could not run as written.

## Root cause

The options and fields were added for one path and never wired through the others, or the dispatch picked a path by one option (`--rooms`) while others implied a different one. Each tool has several entry paths (single format, all formats, comparison, scalability; a suite script and a per-run script) that duplicate the call to the shared runner, and a defaulted parameter makes the missing argument compile silently. Nothing in the output recorded which options the run actually used.

## Fix

- Every multi-room call in EncodingBenchmark passes `monsterCap` and `activePlayers`, and the single-format JSON records them under `config` (9027f4a1).
- A shared `ProcessUsage` helper fills ServerLoadTest's per-second `processCPUPercent` / `processRSSBytes` and its `summary.process`, and EncodingBenchmark's `cpuMs` and `syncMs` (9027f4a1).
- The suite script forwards every client option of `run-ws-loadtest.sh` (f375c89a).
- Any hero-defense option, or `--game-type`, selects the hero-defense runner even with one room; the runner records the peak live monster count and exits nonzero when an active-player run never sees a monster (f7f79e3b).

- `--scalability` with an explicit `--parallel true|false` runs that mode alone and records `config.mode`; without it, both, as before. Per-run outputs are named by every axis the runner varies, the mode included.

## Prevention

- Write the options a run actually used into its result (the `config` block), not just the ones it was given, and check them before reading the numbers.
- Smoke each new option on every entry path with a pair of runs whose output must differ (active vs passive bytes). An option whose two settings give identical results is unwired until shown otherwise.
- Avoid defaulted parameters on a shared runner for measurement inputs; when one exists, grep every call site when adding the option.
- A declared result field that is always nil is a bug: either fill it or remove it.
- When options select between paths, route on every option that only one path honours, not on a single switch; and add a sanity check on the workload itself (players joined, entities seen) that fails the run instead of reporting it.
- Name per-run output files by every axis the runner varies inside one invocation (mode, room count, players), and count what a reader checked (runs, rooms, syncs) against what the invocation should have produced.
- A wrapper script must forward or refuse every option of the script it wraps; see [The load tool is the bottleneck](2026-11-05-load-tool-is-the-bottleneck.md), Prevention.
