---
module: EncodingBenchmark
date: 2026-11-10
problem_type: measurement_pitfall
component: benchmark-drain
symptoms:
  - "a change that makes the sync faster makes the tick slower by about the same amount; total iteration time barely moves"
  - "the tick handler's own time grows 2-2.5x although the game logic didn't change"
  - "/usr/bin/time: elapsed far above user + sys (9.3 s against 5.0 s), involuntary context switches up 6x"
root_cause: idle_sleep_between_timed_spans_lowers_cpu_speed
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - measurement
  - benchmark
  - methodology
  - cpu-frequency
  - drain
related:
  - "#160"
---

# A sleep between timed spans slows the next span

## Problem

A throwaway upper bound replaced Hero Defense's sync path with a much cheaper one (EncodingBenchmark, serial, 1 room). The sync span fell from about 1600 to 165 µs per iteration, but the tick span rose from 700 to about 1900 µs. The game's tick handler itself measured 2.5× slower, even though its code hadn't changed. The bound's sync span was inflated too, about 2×. Read at face value, the result said the saving moved into the tick.

## Root cause

Between iterations, outside the timed spans, the benchmark waits for the outbound writer (`MeasuredSync.drain` → `TransportAdapter.waitForOutboundDrain`, #160). That wait polls the backlog with `safeTaskSleep(for: .milliseconds(1))`.

- **Today's path:** the sync is long, and the writer has usually finished by the time the drain asks, so the loop never sleeps.
- **The cheap sync:** the writer is still busy at the drain, so every iteration sleeps at least 1 ms.
- **The effect:** the core goes idle. On the macOS development machine (Apple silicon) it is then clocked down or the thread moves to an efficiency core, so the next timed spans run on a slower core. That is why the handler, which had no reason to change, got slower.

The probes that isolated it:
- An empty after-tick observer with the cheap sync still slowed the tick.
- The bound's after-tick work alone, with today's sync, did not.
- Skipping the sync entirely did not.
- `/usr/bin/time` showed elapsed 9.3 s against 5.0 s of user + sys, and 15.5k involuntary context switches against 2.3k.

## Fix

On the throwaway branch the drain polls with `await Task.yield()` instead of sleeping. The tick returned to today's value (718 against 700 µs, the difference being the bound's own work) and the sync span to 165 µs.

The harness change on main is held until it is known whether any published result ran the sleep path. Changing the drain could move published numbers, so that is decided separately.

## Prevention

- **Don't sleep between timed spans.** A benchmark wait that sits between timed spans must not let the core go idle: poll with `Task.yield()`, or await a completion. A timer-driven server (GameServer, ServerLoadTest) is a different case: idling between ticks is its real operating condition, and it measures process CPU, not spans.
- **Check for the sleep path when a span moves for no reason.** When a change in one span moves another span whose code didn't change, check whether the run slept between spans before reading the result:
  - elapsed against user + sys for the whole process (`/usr/bin/time -l` on macOS, `-v` on Linux);
  - the involuntary context switches;
  - both sides of a comparison measured with the same wait.
- **Verify the time split with a second clock.** A tick/sync split taken by subtraction (`timeMs − syncMs`) charges any slowdown to the tick. Checking each span with process CPU (`ProcessUsage.cpuSeconds`) catches a slow core but not its cause: CPU time on a clocked-down core is still CPU time. So check elapsed against CPU as well.
