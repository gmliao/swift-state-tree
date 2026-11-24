# Swift 6.4.3 A/A baseline

**Question.** With the toolchain pinned to Swift 6.4.3 (#775), how far apart are two builds of the same commit, cell by cell, in retired user-mode instructions? The answer is the noise floor that later 6.4.3 A/Bs are gated against.

This is a new baseline, not a comparison with 6.2.4. Both the compiler and SwiftPM's default build system (swift-build from 6.4) changed with the bump, so 6.2.4 numbers don't compare with these.

## Environment

- **Commit:** `fa992e647a74f61a71cf202e0e5e90975a477165` (`main`, the #775 merge), built twice: side A and side B are two separate clones with their own scratch paths, both clean. Their binaries differ by SHA-256 (the build paths differ), so the floor covers clone-to-clone differences as well as run noise, as a real A/B between two clones does.
- **Image:** `swift:6.4.3-noble@sha256:4ed5e0210b244aab174450e0b79014c17db60c63c6daf0709347fe50c767293a` plus `linux-tools-generic` (perf 6.8.12). `swift --version`: `Swift version 6.4.3 (swift-6.4.3-RELEASE)`, `Target: x86_64-unknown-linux-gnu`.
- **Builds:** `swift build -c release --product <name>` for TurnsBench and TurnsMailboxBench (root package) and EncodingBenchmark and ServerLoadTest (`Examples/GameDemo`), in a throwaway container from that image.
- **Runs:** a second throwaway container from the same image with `--security-opt seccomp=unconfined` (perf needs `perf_event_open`), `--network none` and read-only mounts. **No added capabilities, no `--privileged`**. Every process is pinned with `taskset -c 0-7` inside the container; 12 CPUs are visible, `perf_event_paranoid` is 2, so only user-mode counters (`:u`) are used.
- **Machine:** AMD Ryzen 5 7600X, Windows 11 with Docker Desktop on WSL 2. No other measurement or build ran during the window, and the OS update services were stopped.
- **Date:** 2026-11-24, one window of about 28 minutes (build about 21, runs about 7).

Later 6.4.3 A/Bs compare against this floor only in the same setup: the same image digest, no added capabilities, `taskset -c 0-7`, and separate clones per side.

## Commands

For each rep (5) and side (A, B, interleaved), in the run container:

```bash
# TurnsBench and TurnsMailboxBench: one cell, one implementation per process; per op = (count(n) - count(0)) / n
perf stat -x, -e instructions:u -- taskset -c 0-7 TurnsBench <cell> <turn|direct> <n>
perf stat -x, -e instructions:u -- taskset -c 0-7 TurnsBench <cell> <turn|direct> 0
perf stat -x, -e instructions:u -- taskset -c 0-7 TurnsMailboxBench <cell> <mailbox|mailboxoff> <n>   # and 0

# EncodingBenchmark, whole process
SWIFT_DETERMINISTIC_HASHING=1 perf stat -x, -e instructions:u -- taskset -c 0-7 EncodingBenchmark \
  --format messagepack-pathhash --players-per-room 5 --parallel false --ticks-per-sync 1 --output json --iterations 100

# ServerLoadTest, short, whole process
perf stat -x, -e instructions:u -- taskset -c 0-7 ServerLoadTest \
  --rooms 100 --players-per-room 5 --duration-seconds 30 --ramp-up-seconds 5 --ramp-down-seconds 2 --log-level error
```

`n` is 1,000,000 for `idle`, `emit`, `issue-end`, `now`, `held-lookup`, `read1` and `read4`; 100,000 for `park`, `follow-up-join`, `call`, `request` and `follow-up`; 99,968 (a multiple of 64) for `park-64`. The mailbox bench runs `emit` at 1,000,000 and `call` at 100,000.

`collect.py <raw dir>` turns the raw perf output into `results/per-op.csv` (one row per cell, implementation, side and rep, with the n and 0 counts) and `results/whole-process.csv`. `python3 regenerate.py --check` confirms the tables below match them.

**Toolchain record.** ServerLoadTest's results file records `metadata.build.swiftVersion` (shown in the table). EncodingBenchmark with `--format <one>` takes its single-format path, which prints JSON to stdout and saves no results file, so its toolchain comes from the build provenance: both sides were built in the image above, and `swift --version` was recorded per side.

## Results

Per op is retired `instructions:u` per operation. Spread is (max − min) / mean over a side's 5 reps; B vs A is (B − A) / A. Classes:
- **tight:** both spreads and |B vs A| at most 0.05 %;
- **noisy:** anything else. Its floor is the largest of the two spreads and |B vs A|;
- **not measurable:** under 1 instruction per op, because the loop was optimized away.

<!-- BEGIN generated tables -->
### TurnsBench (instructions:u per op)

| cell | impl | n | A instr/op | A spread | B instr/op | B spread | B vs A | class | floor |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|
| call | direct | 100000 | 388.98 | 0.026% | 389.02 | 0.040% | +0.012% | tight | 0.040% |
| call | turn | 100000 | 2,992.90 | 0.003% | 2,992.88 | 0.005% | -0.001% | tight | 0.005% |
| emit | direct | 1000000 | 548.01 | 0.002% | 548.01 | 0.002% | -0.000% | tight | 0.002% |
| emit | turn | 1000000 | 1,068.01 | 0.001% | 1,068.01 | 0.001% | -0.000% | tight | 0.001% |
| follow-up | direct | 100000 | 7,301.63 | 0.343% | 7,294.91 | 0.370% | -0.092% | noisy | 0.370% |
| follow-up | turn | 100000 | 19,791.28 | 1.020% | 19,738.48 | 0.593% | -0.267% | noisy | 1.020% |
| follow-up-join | direct | 100000 | -0.00 | n/a | -0.02 | n/a | n/a | not measurable | n/a |
| follow-up-join | turn | 100000 | 558.09 | 0.020% | 558.06 | 0.015% | -0.006% | tight | 0.020% |
| held-lookup | direct | 1000000 | 151.60 | 7.262% | 153.80 | 7.149% | +1.452% | noisy | 7.262% |
| held-lookup | turn | 1000000 | 243.41 | 4.524% | 245.60 | 4.473% | +0.902% | noisy | 4.524% |
| idle | direct | 1000000 | 0.00 | n/a | 0.00 | n/a | n/a | not measurable | n/a |
| idle | turn | 1000000 | 16.00 | 0.045% | 16.00 | 0.046% | +0.001% | tight | 0.046% |
| issue-end | direct | 1000000 | 808.81 | 19.907% | 778.00 | 18.895% | -3.809% | noisy | 19.907% |
| issue-end | turn | 1000000 | 1,201.00 | 13.406% | 1,191.80 | 12.335% | -0.766% | noisy | 13.406% |
| now | direct | 1000000 | 498.00 | 0.003% | 498.00 | 0.004% | +0.000% | tight | 0.004% |
| now | turn | 1000000 | 604.00 | 0.002% | 604.01 | 0.011% | +0.002% | tight | 0.011% |
| park | direct | 100000 | 3,229.25 | 0.005% | 3,229.31 | 0.003% | +0.002% | tight | 0.005% |
| park | turn | 100000 | 10,834.15 | 0.007% | 10,834.11 | 0.009% | -0.000% | tight | 0.009% |
| park-64 | direct | 99968 | 366.50 | 0.045% | 366.52 | 0.032% | +0.005% | tight | 0.045% |
| park-64 | turn | 99968 | 6,828.37 | 0.026% | 6,829.16 | 0.040% | +0.011% | tight | 0.040% |
| read1 | direct | 1000000 | 160.37 | 2.829% | 160.59 | 2.331% | +0.137% | noisy | 2.829% |
| read1 | turn | 1000000 | 172.91 | 2.794% | 172.53 | 1.907% | -0.215% | noisy | 2.794% |
| read4 | direct | 1000000 | 622.75 | 2.408% | 628.38 | 3.482% | +0.904% | noisy | 3.482% |
| read4 | turn | 1000000 | 641.50 | 1.559% | 646.00 | 5.902% | +0.702% | noisy | 5.902% |
| request | direct | 100000 | 393.04 | 0.041% | 393.03 | 0.015% | -0.002% | tight | 0.041% |
| request | turn | 100000 | 13,497.59 | 0.049% | 13,509.43 | 0.119% | +0.088% | noisy | 0.119% |

### TurnsMailboxBench (instructions:u per op)

| cell | impl | n | A instr/op | A spread | B instr/op | B spread | B vs A | class | floor |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|
| call | mailbox | 100000 | 3,444.02 | 0.002% | 3,444.01 | 0.002% | -0.000% | tight | 0.002% |
| call | mailboxoff | 100000 | 2,909.03 | 0.005% | 2,909.03 | 0.004% | +0.000% | tight | 0.005% |
| emit | mailbox | 1000000 | 1,538.02 | 0.001% | 1,538.01 | 0.000% | -0.000% | tight | 0.001% |
| emit | mailboxoff | 1000000 | 1,057.02 | 0.001% | 1,057.01 | 0.001% | -0.000% | tight | 0.001% |

### Whole process (instructions:u per run, 5 runs per side)

| workload | A instructions | A spread | B instructions | B spread | B vs A | exit codes | detail |
|---|---:|---:|---:|---:|---:|---|---|
| EncodingBenchmark | 188,162,523 | 0.197% | 188,077,207 | 0.175% | -0.045% | 0 | bytesPerSync 137 |
| ServerLoadTest | 36,759,647,337 | 0.445% | 36,892,344,462 | 0.994% | +0.361% | 0 | Swift version 6.4.3 (swift-6.4.3-RELEASE) |
<!-- END generated tables -->

## Gate guidance for 6.4.3 A/Bs in this setup

- **Tight cells** (`emit`, `call`, `now`, `park`, `park-64`, `turn` `idle`, `turn` `follow-up-join`, `direct` `request`, every mailbox cell): a difference above 0.05 % is outside the A/A floor. Gates that use max(0.5 %, 3 × spread) stay at 0.5 % for these.
- **Noisy cells:** gate at no less than three times the floor in the table, or rerun with more reps before reading a change.
  - `turn` `request`: floor 0.12 %.
  - `follow-up`: up to 1.0 % on `turn`, 0.4 % on `direct`.
  - `read1`, `read4`: 2–6 %.
  - `held-lookup`: 4.5–7.3 %.
  - `issue-end`: 12–20 %. At these spreads a 1 % change in it can't be seen.
- **Not measurable:** `direct` `idle` and `direct` `follow-up-join` count about 0 instructions per op. Don't use them as controls; `turn` `idle` (16 per op, tight) is the control.
- **Whole process:** EncodingBenchmark's runs agree within 0.2 % (B vs A −0.045 %). ServerLoadTest's short run is the noisiest at 0.45–0.99 % spread (B vs A +0.36 %): read a change under about 1 % there as noise.

## Caveats

- One window, one machine, 5 reps per side. A cell's spread is a range over 5 values, not a confidence interval.
- The noisy turn cells' spread is between reps of the same binary as much as between sides, so more reps narrow the mean but not the per-run range.
- Instruction counts don't measure time. Wall time wasn't recorded for the turn benches.
