# Off-path A/B gates judge instructions, not time (#517)

**Status:** decided 2026-11-13, option (a). The EncodingBenchmark perf window is on main (24600fe5). The first A/B under the rule runs both rules side by side.

## Problem

Off-path gates judged wall time:
- "non-sync within ±3 %";
- head's mean above base's mean by more than max(2 %, base's spread).

Code and data layout alone moved those metrics past the bar three times, with no source on the path changed:
- #513's off-path A/B: +3.2 to +3.9 %, tables off;
- Hero Defense non-sync: ±3–4 %, the case #517 was opened for;
- #523's vis tick: +20 %. Tick instructions were 1.03× (inside the run spread), cycles 1.18×, IPC 2.00 → 1.74.

A time gate can't tell a moved function from added work.

## Options considered

- **(a) Judge user-mode retired instructions (`instructions:u`) over the off-path span only. Report time.**
  - Instructions don't move with code placement or cache behaviour.
  - They do move with real work: added calls, copies, allocations, different inlining.
- **(b) Build both sides with `-align-all-functions=6 -align-all-nofallthru-blocks=5`.**
  - This removes alignment effects only. Heap and data layout, cache-set conflicts and branch-predictor aliasing remain.
  - It measures a binary nobody ships, larger by the padding.
  - Whether it closes #517's gaps is still #517's open check.
- **(c) Both.** Costs both. It adds little, since under (a) time isn't judged.

**Chosen: (a).** (b) stays a one-off diagnostic in #517: the aligned-functions build, beside the padded-adapter build.

## The rule

- **Judged:** the mean `instructions:u` over the off-path window, per cell and side, from `perf stat` runs.
  - **REGRESSION:** head's mean is above base's mean by more than **max(0.5 %, 3 × base's spread)**. Spread is (max − min) / mean of base's runs, as in the time bar.
  - **GAIN:** head's mean is below base's min.
- **Reported:** time (`timeMs`, `syncMs`, `nonSyncMs`, `tickMs`, `cpuMs`), with its old bar printed beside it.
  - A cycles-only move, with time up and instructions inside the bar, prints as "layout move (#517)". It doesn't fail the set.
- **Calibration:** the first A/B under the rule judges by instructions and also prints the old time verdict. The bar is revisited after the first two sets, from base's instruction spread.
- **On-path (sync) metrics:** unchanged. A sync change is supposed to change sync time, and sync work is measured where it happens.

## The window (EncodingBenchmark, 24600fe5)

- **Env:**
  - `ENCODING_BENCHMARK_PERF_CONTROL=<ctl-fifo>,<ack-fifo>`: the FIFOs given to `perf stat --delay=-1 --control fifo:<ctl>,<ack>`.
  - `ENCODING_BENCHMARK_PERF_WINDOW=nonsync|ticks`. `nonsync` is the default.
- **Spans:**
  - `nonsync`: per room and iteration, everything in the timed iteration except `syncNow()`. That is the span `timeMs − syncMs` measures; in Hero Defense it includes the move injection.
  - `ticks`: the `stepTickOnce()` loop only.
  - In the generic runner (visibility test), both name the tick loop.
- **Toggles:** each `enable` / `disable` waits for perf's ack, so the counters are on exactly for the span. There are 2 toggles per room and iteration; both sides pay the same toggle cost.
- **Refused:** `--parallel true` (the default, so pass `--parallel false`), `--all`, `--compare-parallel`, `--scalability`, `--hash-cost`, the worker-pool modes, and the single-room path.
- **Result JSON:** `perfWindow {mode, toggles}`. It is absent without the env, and the output is otherwise unchanged.
- **Failures are loud:**
  - a malformed setting, or a FIFO that can't be opened, exits 2;
  - a missing ack, or unbalanced brackets, stop the run;
  - a run whose window never toggled, or ended enabled, stops before printing.

## Brief template changes

- **The perf step becomes the judged step.** It covers every judged off-path cell, not only cap100-local/router: the Hero Defense cells and `vis-tick`.
- **Container scope:** unchanged (user-only counters, `seccomp=unconfined` only, `--network none`, read-only mounts). The FIFOs go in a tmpfs inside the container (`--tmpfs /perfctl`), since the mounts are read-only.
- **Command, per run:**
  ```
  mkfifo /perfctl/ctl /perfctl/ack
  SWIFT_DETERMINISTIC_HASHING=1 \
  ENCODING_BENCHMARK_PERF_CONTROL=/perfctl/ctl,/perfctl/ack \
  ENCODING_BENCHMARK_PERF_WINDOW=nonsync \
  perf stat -x, -e instructions:u,cycles:u --delay=-1 --control fifo:/perfctl/ctl,/perfctl/ack \
    -- taskset -c 0-7 <cell command> --parallel false
  rm /perfctl/ctl /perfctl/ack
  ```
  - `SWIFT_DETERMINISTIC_HASHING=1` on both sides. Per-process hash seeds change Dictionary/Set probe lengths, and with them the instruction count (`Notes/solutions/2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md`). The timed runs keep the shipped default.
  - Check the measurement machine's `perf --version` once; `--control` needs perf 5.10 or later. Record it in PROVENANCE.
- **Repeats:** per cell, ABBA, one warm-up pair (discarded), then 5 pairs. That is 5 rather than the old 3, since this is now the judged number.
- **Cost:** the perf step runs as long as the timed set's judged cells, about doubling the set's run time. No extra builds: it reuses the timed binaries.
- **ws-loadtest / GameServer CPU gates (#501-type):** not covered. Attaching perf to GameServer needs a networked container, beyond the standing scope.

## Summary script changes

- **`perf_counts`:** unchanged; it reads the `-x,` lines for `instructions:u` and `cycles:u`.
- **`perf_section` becomes judged for off-path cells:**
  - it computes mean, min, max and spread of `instructions:u` per side, and applies the bar above. It prints REGRESSION / GAIN / within, and the exit code follows;
  - it requires `perfWindow` in every perf run's JSON, with the same `mode` on both sides, and fails otherwise;
  - it requires the same `toggles` across all runs of a cell, both sides. The count is rooms × iterations × 2, fixed by the command;
  - it keeps the bytes check against the timed set.
- **The time section** stays, marked "reported (old bar)". When time is above the old bar and instructions are within the new one, it prints "layout move (#517)" instead of REGRESSION.
- **New synthetic cases:**
  - a perf run without `perfWindow`: exit 1;
  - modes differing between sides: exit 1;
  - unequal toggles: exit 1;
  - instructions +1 % over a tight base: REGRESSION, exit 1;
  - time +5 % with instructions flat: "layout move", exit 0;
  - the 0.5 % floor, where base's spread is smaller.

## Follow-ups

- After two sets: the bar's calibration, and a `Notes/solutions/` entry ("judge off-path work by windowed instructions, not time") with the numbers.
- #517 stays open for the vis move's own split, code placement against heap layout.
