# multiroom-load-2026-11: multi-room load test, November 2026 method

## Question

With the send backlog bound at its shipped defaults, does the server at `ee8a407a` hold 100, 300 and 500 Hero Defense rooms of 5 players each? The bar is zero disconnects in every run. At each room count, what are the RTT, the update interval, and the server and host CPU, and how stable are they across three suites? How do they compare with the 2026-11-05 comparison runs and the 2026-02-06 suite (`../multiroom-load-2026-02/`)?

Metric definitions (start and end events, clocks, windows, aggregation) are in [`Examples/GameDemo/ws-loadtest/METRICS.md`](../../Examples/GameDemo/ws-loadtest/METRICS.md).

## Environment

The refreeze sweep's provenance (its full commit, dirty flag, Swift and Node versions and build) opens its Results section: `regenerate.py` writes it from `sweep.json` and refuses a sweep with no commit, a dirty tree, or no dirty flag (`collect.py` refuses a run.json without it first) (`--check` verifies the line). The list below is the pre-refreeze record's.

- **Server:** `ee8a407a` (`data/provenance/SHA.txt`), release build. Swift 6.2.4 (`swift-6.2.4-RELEASE`, x86_64 Linux) in the `swift:6.2.4-noble` image.
- **Load client:** ws-loadtest from the same checkout, Node v24.22.2 (`toolchain.txt` next to each report).
- **Host:** AMD Ryzen 5 7600X (6 cores, 12 logical CPUs), Windows with WSL2 (kernel `6.18.54.1-microsoft-standard-WSL2`). Server and client ran in the same Linux environment on `localhost`.
- **Pinning:** two `PATH` shims, as run (`data/provenance/shim/`):
  - `stdbuf` → `taskset -c 0-7`. The script starts GameServer through `stdbuf`, so the server ran on logical CPUs 0–7.
  - `node` → `taskset -c 8-11`, so the load client ran on logical CPUs 8–11.

  The CPU numbers are the logical IDs as the WSL2 VM numbers them. Which of them are SMT siblings wasn't recorded. The server's startup line reports `availableCPUs=8`, `threads=8`, `machineCPUs=12` (`data/provenance/startup-line.txt`).
- **Server configuration** (startup line): `sendBacklogMaxBytes=8388608`, `sendBacklogMaxUnwritableMs=30000` (the `WS_SEND_BACKLOG_*` variables were unset), `listenBacklog=4096`, `somaxconn=4096`, `pongTimeoutMs=20000`. Encoding is messagepack with opcode MessagePack state updates and path hashes.
- **Host CPU** was sampled once per second on the Windows host. Only the whole machine's total is published here (`data/host-cpu.json`: mean and p95 over each run's steady measured window). It includes the WSL2 VM, which runs the server and the client, and everything else on the host.

## Commands

From `Examples/GameDemo/ws-loadtest` at `ee8a407a`, with the shims first on `PATH`:

```bash
# Preflight (gate before the suites), profiled
PATH=/workspace/shim:$PATH bash scripts/run-scalability-test.sh --room-counts "500" --profile --output-dir results/61-preflight

# Three suites, one invocation per room count, profiled
for s in 1 2 3; do for n in 100 300 500; do
  PATH=/workspace/shim:$PATH bash scripts/run-scalability-test.sh --room-counts "$n" --profile --output-dir results/61-rerun-suite-$s-$n
done; done

# Profiler-overhead pair, back to back
PATH=/workspace/shim:$PATH bash scripts/run-scalability-test.sh --room-counts "500" --profile --output-dir results/61-overhead-profiled
PATH=/workspace/shim:$PATH bash scripts/run-scalability-test.sh --room-counts "500" --output-dir results/61-overhead-unprofiled
```

**`run.sh` runs the same matrix** (the preflight, the three suites, the overhead pair, in that order) and writes under `raw/<RUN_ID>/` (ignored):
- it waits for TIME_WAIT before each run (below), logged to `chain.log`;
- it builds GameServer once and starts it fresh for each run;
- it writes the same shims, with server CPUs 0–7 and client CPUs 8–11, checks them before the first run, and checks each running server's CPU list;
- it writes a header per run, `runmeta.py`'s `run.json` (commit, dirty tree, Swift and Node versions) and the server's log.

Deliberate deviations from the 2026-11-06 procedure:
- **One build, before the first run.** In 2026-11-06 each run's `run-ws-loadtest.sh` ran `swift build` itself, after the TIME_WAIT wait. `run.sh` builds once and passes the binary in `GAMESERVER_BIN`, so nothing builds between the wait and the load.
- **The server is the checkout's HEAD, not `ee8a407a`.** `run.json` and each run's `toolchain.txt` record the commit (`GAMESERVER_SOURCE_SHA`).
- **The wire form.** Since #301 and #308 a HEAD server sends merged entries and path indices by default; the 2026-11-06 set used neither. So a sweep at the new defaults isn't byte-comparable with that set, and its bytes and CPU aren't like for like with it. `PATH_INDEX=false FIELD_MERGE=false bash run.sh` is the like-for-like rerun. `run.json` records the declared form, each report counts its joins by the features the server's JoinResponse named, and `regenerate.py --sweep` refuses a run whose joins differ from the declared form.
- **The send backlog stays at its shipped defaults:** `WS_SEND_BACKLOG_*` are recorded, and `regenerate.py --sweep` refuses a sweep with either set.

A failed preflight stops the sweep (it is the gate before the suites); any other failed run is recorded and the sweep goes on. A run whose summary doesn't name its room count, or whose report file is missing, stops the sweep (`failed-no-summary`).

**The refreeze sweep becomes this topic's data set.** `python3 collect.py --run-id <RUN_ID>` converts that sweep into `results/<RUN_ID>/`, and `python3 regenerate.py` puts its tables first in Results, after every `--sweep` gate. A second sweep in `results/` is refused. The 2026-11-06 set stays under `data/` and renders after it as the pre-refreeze record, captioned with its wire form (path index and field merge off, by its commit's ancestry). It isn't compared with the sweep. `python3 regenerate.py --results <dir> --markdown` prints the whole section from another directory, as a dry run that leaves README.md alone.

`DRY_RUN=1 bash run.sh` prints every command; its header lists the options. A smoke run off the host: `RUNS=suite-1-100 ROOMS=10 PRE_S=2 STEADY_S=5 POST_S=2 SERVER_CPUS= CLIENT_CPUS= RUN_ID=smoke bash run.sh`. `python3 test_topic.py` checks the dry run's plan. Its output isn't wired to `regenerate.py`, which reads the published `data/`.

Each run's exact command, start and end time, shims, toolchain and kernel are in `data/provenance/chain/<run>.run-header.txt`. The scenario is `scenarios/hero-defense/default.json`: preflight 10 s (2 players per room), steady 60 s (5 players per room), postflight 10 s (2 players per room), 1 action per player per second. The client used its defaults: `--layout rooms`, `--send spread`, `--connect ramp` at 1000/s, `--boundary clean`, 12 workers.

**Hero Defense's spawn ramp, from the commit after the 2026-11-06 set:** `run.sh` exports `HERO_DEFENSE_SPAWN_RAMP_TICKS=0` for the servers it starts, so every land spawns at the game's final rate (an interval of 3 ticks) from its first tick instead of ramping over 3000 ticks (150 s; #425). run.json records it (`spawnRampTicks`) and, per run, the value the server reported at startup (`spawnRampTicksEffective`, from its log). A run whose server reports another value fails (`failed-spawn-ramp`). The 2026-11-06 set and the refreeze before it ran the game's own ramp; its runs are about 80 s long, so their steady phase saw the slow start of the ramp (a few monsters per room), not its plateau. Without the ramp a land's base reaches 0 within about a minute (health clamped at 0; play continues). A record doesn't carry the ramp: replay one with the value its run had.

**Steady's hold, with the ramp skipped:** a land's monster count settles at its plateau for the players in it, and preflight runs 2 players per room (its verify gate) before steady's 5. So steady holds 5 players per room for 30 s before it measures (`STEADY_WARMUP_S`, default 30): run.sh's scenario is always a copy of `default.json` in `raw/<RUN_ID>/scenario.json` with steady's `warmupSeconds` 30 and its length 90 s, and ws-loadtest leaves the warm-up out of the phase's metrics, so the measured window is still 60 s. run.json records the hold (`steadyWarmupS`). Each run's server writes its own `land-stats.jsonl` (`HERO_DEFENSE_STATS_PATH`); `collect.py` summarizes it over steady's measured window (`steadyLandStats` in sweep.json: per-10 s medians over lands of the live monster count, the spawned, killed and reached-base rates, and the base health; `deep-research/landstats.py`), and `regenerate.py` tables a sweep with the hold only when every report holds 30 s, every server ran without the ramp, and every run's window is stationary (per-10 s medians: coefficient of variation at most 0.10, none more than 20 % from their mean, and the last third's median within 10 % of the first third's). The drift bound is what refuses a slow trend: a rise of a third across the window is within the CoV bound (0.098) but drifts 23 %. Sweeps without the hold (the 2026-11-06 set and the refreeze) are checked against the phases they ran.

**One invocation per room count.** Until `e6f30a74`, the scalability script's TIME_WAIT wait reused its run-loop index. After a long enough wait it could skip the remaining room counts of a list, and the summary would still read as clean. This rerun's first suite-1 invocation with a room list was hit: it ran 100 and 300 only. It was replaced by the per-room-count invocations above and isn't used here. `--runs` with a room list is refused since `a398f5d5`.

**TIME_WAIT.** Before each run the driver waited until the host's TIME_WAIT socket count had drained: 0–200 at the start of each run, after waits of 0–54 s. The counts and waits are in `data/provenance/chain/*.chain.log`.

**Rebuilding the results:** `python3 regenerate.py` rewrites the Results section from `data/`; `python3 regenerate.py --check` fails if it is stale. `summarize_host.py` produced `data/host-cpu.json` from the per-second host samples, which aren't published.

## Data

| Path | What it is |
|---|---|
| `data/rerun/<run>/report.json.gz` | The ws-loadtest report (JSON, gzip) of each run: `preflight`, `rerun-suite-{1,2,3}-{100,300,500}`, `overhead-{profiled,unprofiled}` |
| `data/rerun/<run>/summary.json`, `toolchain.txt` | The scalability script's summary and the toolchains of each run |
| `data/b0/r{300,500}-B0-{1,2,3}/` | The 2026-11-05 comparison runs: report, toolchain, the scenario they used (`base-scenario.json`) and the run line (`meta.txt`) |
| `data/host-cpu.json` | Host CPU summary per run (mean, p95, sample count, sampler) |
| `data/provenance/` | Server SHA, pinning shims, the server's startup line, per-run headers, the driver's chain logs (TIME_WAIT waits, per-run checks), and the SHA-256 manifests of the full raw result sets |

The full raw sets (HTML reports, transport-profile JSONL, server logs, the per-second host samples) are kept by the maintainer. `data/provenance/MANIFEST-*.sha256` lists their files and hashes. Each published report is the gzip of the file with the same run in the manifest.

## Results

<!-- results start -->

### Refreeze sweep

Provenance, from the results' meta: commit `022d8fdbca966f8df56f1fc86d29421b154ce7a0`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

Sweep `20261109T140702Z-022d8fdb`, wire form messagepack, pathIndex on, fieldMerge on. Host CPU isn't sampled by run.sh (n/a). The 2026-11-06 set ran without path indices and merged entries, so its bytes and CPU aren't comparable with this sweep's like for like.

#### Steady phase, each run

| suite | rooms | connections | lands | RTT p50 / p95 / p99 (ms) | update interval p50 / p95 / p99 (ms) | server CPU mean / p95 (%, 100 = 1 core) | host CPU mean / p95 (% of machine) | client CPU total / worst worker (% of 1 core) | worst worker loop delay p99 (ms) | disconnects / join failures / errors | phase |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 500 | 100 | 0.72 / 1.83 / 1.96 | 100 / 100 / 101 | 84.1 / 86.9 | n/a / n/a | 25.9 / 2.3 | 0.75 | 0 / 0 / 0 | pass |
| 1 | 300 | 1,500 | 300 | 0.73 / 1.84 / 1.97 | 100 / 100 / 101 | 234.3 / 238.7 | n/a / n/a | 54.6 / 4.6 | 0.90 | 0 / 0 / 0 | pass |
| 1 | 500 | 2,500 | 500 | 0.77 / 1.87 / 1.98 | 100 / 100 / 101 | 367.9 / 376.6 | n/a / n/a | 83.9 / 7.2 | 0.95 | 0 / 0 / 0 | pass |
| 2 | 100 | 500 | 100 | 0.68 / 1.85 / 1.98 | 100 / 100 / 101 | 84.6 / 86.9 | n/a / n/a | 26.2 / 2.3 | 0.79 | 0 / 0 / 0 | pass |
| 2 | 300 | 1,500 | 300 | 0.75 / 1.86 / 1.97 | 100 / 100 / 101 | 233.4 / 237.7 | n/a / n/a | 54.5 / 4.6 | 0.92 | 0 / 0 / 0 | pass |
| 2 | 500 | 2,500 | 500 | 0.73 / 1.85 / 1.98 | 100 / 100 / 101 | 368.2 / 376.5 | n/a / n/a | 85.1 / 7.1 | 0.91 | 0 / 0 / 0 | pass |
| 3 | 100 | 500 | 100 | 0.68 / 1.77 / 1.96 | 100 / 100 / 101 | 85.1 / 88.9 | n/a / n/a | 26.2 / 2.3 | 0.82 | 0 / 0 / 0 | pass |
| 3 | 300 | 1,500 | 300 | 0.76 / 1.88 / 1.98 | 100 / 100 / 101 | 234.8 / 239.8 | n/a / n/a | 54.5 / 4.6 | 0.91 | 0 / 0 / 0 | pass |
| 3 | 500 | 2,500 | 500 | 0.79 / 1.89 / 1.99 | 100 / 100 / 101 | 368.2 / 375.6 | n/a / n/a | 84.9 / 7.2 | 0.97 | 0 / 0 / 0 | pass |

#### Server counters, steady phase, each run

| suite | rooms | sync cycles | sync skips (backlog + busy) | folds / cycles | overdue folds per 1000 cycles (scheduler race, see Caveats) | send buffered bytes max | unwritable episodes | longest unwritable (ms) | backlog closes (4008) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 56,022 | 0 | 0.322 | 313 | 0 | 0 | 0 | 0 |
| 1 | 300 | 165,064 | 0 | 0.393 | 373 | 0 | 0 | 0 | 0 |
| 1 | 500 | 270,125 | 0 | 0.403 | 365 | 0 | 0 | 0 | 0 |
| 2 | 100 | 56,017 | 0 | 0.268 | 255 | 0 | 0 | 0 | 0 |
| 2 | 300 | 165,076 | 0 | 0.405 | 387 | 0 | 0 | 0 | 0 |
| 2 | 500 | 270,129 | 0 | 0.408 | 375 | 0 | 0 | 0 | 0 |
| 3 | 100 | 56,028 | 0 | 0.372 | 354 | 0 | 0 | 0 | 0 |
| 3 | 300 | 165,064 | 0 | 0.378 | 365 | 0 | 0 | 0 | 0 |
| 3 | 500 | 270,144 | 0 | 0.374 | 333 | 0 | 0 | 0 | 0 |

#### Steady phase per room count: median [min–max] over the 3 suites

| rooms | runs | RTT p50 (ms) | RTT p99 (ms) | update p95 (ms) | update p99 (ms) | server CPU mean (%) | host CPU mean (%) | disconnects (sum) |
|---|---|---|---|---|---|---|---|---|
| 100 | 3 | 0.68 [0.68–0.72] | 1.96 [1.96–1.98] | 100 [100–100] | 101 [101–101] | 84.6 [84.1–85.1] | n/a | 0 |
| 300 | 3 | 0.75 [0.73–0.76] | 1.97 [1.97–1.98] | 100 [100–100] | 101 [101–101] | 234.3 [233.4–234.8] | n/a | 0 |
| 500 | 3 | 0.77 [0.73–0.79] | 1.98 [1.98–1.99] | 100 [100–100] | 101 [101–101] | 368.2 [367.9–368.2] | n/a | 0 |

#### Profiler overhead, 500 rooms, back to back

| steady phase | profiled | unprofiled | difference | relative |
|---|---|---|---|---|
| RTT p50 (ms) | 0.81 | 0.78 | 0.04 | 4.6 % |
| RTT p95 (ms) | 1.94 | 1.87 | 0.08 | 4.1 % |
| RTT p99 (ms) | 5.83 | 1.98 | 3.86 | 194.9 % |
| server CPU mean (%) | 367.9 | 370.0 | -2.1 | -0.6 % |

Both runs: 0 and 0 disconnects.

### Pre-refreeze record (2026-11-06, server `ee8a407a`: messagepack, pathIndex off, fieldMerge off)

The set this topic published before the refreeze: the path index and field merge didn't exist at its commit, so its bytes and CPU aren't like for like with the sweep above, and it isn't compared with it. Its own comparisons (2026-11-05, 2026-02-06) are kept as published.

#### Steady phase, each run

| suite | rooms | connections | lands | RTT p50 / p95 / p99 (ms) | update interval p50 / p95 / p99 (ms) | server CPU mean / p95 (%, 100 = 1 core) | host CPU mean / p95 (% of machine) | client CPU total / worst worker (% of 1 core) | worst worker loop delay p99 (ms) | disconnects / join failures / errors | phase |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 500 | 100 | 0.73 / 1.83 / 1.96 | 100 / 100 / 101 | 82.4 / 84.0 | 14.0 / 23 | 27.8 / 2.4 | 0.70 | 0 / 0 / 0 | pass |
| 1 | 300 | 1,500 | 300 | 0.76 / 1.86 / 1.97 | 100 / 100 / 101 | 225.4 / 233.8 | 30.5 / 40 | 54.9 / 4.7 | 0.90 | 0 / 0 / 0 | pass |
| 1 | 500 | 2,500 | 500 | 0.82 / 1.89 / 1.99 | 100 / 101 / 101 | 362.2 / 374.5 | 52.3 / 64 | 86.6 / 7.4 | 0.92 | 0 / 0 / 0 | pass |
| 2 | 100 | 500 | 100 | 0.73 / 1.83 / 1.97 | 100 / 100 / 101 | 82.5 / 84.9 | 14.3 / 26 | 28.0 / 2.5 | 0.70 | 0 / 0 / 0 | pass |
| 2 | 300 | 1,500 | 300 | 0.73 / 1.87 / 1.98 | 100 / 100 / 101 | 224.3 / 228.7 | 30.2 / 39 | 54.7 / 4.6 | 0.88 | 0 / 0 / 0 | pass |
| 2 | 500 | 2,500 | 500 | 0.78 / 1.88 / 1.99 | 100 / 100 / 101 | 357.6 / 371.6 | 44.7 / 57 | 84.4 / 7.1 | 0.91 | 0 / 0 / 0 | pass |
| 3 | 100 | 500 | 100 | 0.73 / 1.85 / 1.96 | 100 / 100 / 101 | 82.3 / 83.9 | 17.0 / 25 | 27.7 / 2.4 | 0.82 | 0 / 0 / 0 | pass |
| 3 | 300 | 1,500 | 300 | 0.76 / 1.85 / 1.97 | 100 / 100 / 101 | 224.5 / 231.7 | 32.4 / 45 | 54.8 / 4.6 | 0.91 | 0 / 0 / 0 | pass |
| 3 | 500 | 2,500 | 500 | 0.78 / 1.88 / 1.98 | 100 / 101 / 101 | 362.8 / 372.5 | 42.3 / 54 | 87.0 / 7.4 | 0.97 | 0 / 0 / 0 | pass |

#### Server counters, steady phase, each run

| suite | rooms | sync cycles | sync skips (backlog + busy) | folds / cycles | overdue folds per 1000 cycles (scheduler race, see Caveats) | send buffered bytes max | unwritable episodes | longest unwritable (ms) | backlog closes (4008) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 56,012 | 0 | 0.351 | 343 | 0 | 0 | 0 | 0 |
| 1 | 300 | 165,040 | 0 | 0.367 | 348 | 0 | 0 | 0 | 0 |
| 1 | 500 | 270,092 | 0 | 0.398 | 373 | 0 | 0 | 0 | 0 |
| 2 | 100 | 56,016 | 0 | 0.283 | 282 | 0 | 0 | 0 | 0 |
| 2 | 300 | 165,042 | 0 | 0.370 | 356 | 0 | 0 | 0 | 0 |
| 2 | 500 | 270,084 | 0 | 0.425 | 388 | 0 | 0 | 0 | 0 |
| 3 | 100 | 56,016 | 0 | 0.278 | 276 | 0 | 0 | 0 | 0 |
| 3 | 300 | 165,038 | 0 | 0.377 | 359 | 0 | 0 | 0 | 0 |
| 3 | 500 | 270,083 | 0 | 0.432 | 388 | 0 | 0 | 0 | 0 |

#### Steady phase per room count: median [min–max] over the 3 suites

| rooms | runs | RTT p50 (ms) | RTT p99 (ms) | update p95 (ms) | update p99 (ms) | server CPU mean (%) | host CPU mean (%) | disconnects (sum) |
|---|---|---|---|---|---|---|---|---|
| 100 | 3 | 0.73 [0.73–0.73] | 1.96 [1.96–1.97] | 100 [100–100] | 101 [101–101] | 82.4 [82.3–82.5] | 14.3 [14.0–17.0] | 0 |
| 300 | 3 | 0.76 [0.73–0.76] | 1.97 [1.97–1.98] | 100 [100–100] | 101 [101–101] | 224.5 [224.3–225.4] | 30.5 [30.2–32.4] | 0 |
| 500 | 3 | 0.78 [0.78–0.82] | 1.99 [1.98–1.99] | 101 [100–101] | 101 [101–101] | 362.2 [357.6–362.8] | 44.7 [42.3–52.3] | 0 |

#### Profiler overhead, 500 rooms, back to back

| steady phase | profiled | unprofiled | difference | relative |
|---|---|---|---|---|
| RTT p50 (ms) | 0.79 | 0.78 | 0.01 | 1.6 % |
| RTT p95 (ms) | 1.87 | 1.87 | 0.00 | 0.0 % |
| RTT p99 (ms) | 1.98 | 1.98 | 0.00 | 0.1 % |
| server CPU mean (%) | 360.9 | 359.2 | 1.7 | 0.5 % |

Both runs: 0 and 0 disconnects.

#### Comparison: this rerun, 2026-11-05 comparison runs, 2026-02-06 suite

This rerun and the 2026-11-05 runs: median [min–max] over 3 runs. 2026-02-06: one run per room count. Read the column caveats below before comparing.

| rooms | steady phase | 2026-11-06 (this rerun) | 2026-11-05 | 2026-02-06 |
|---|---|---|---|---|
| 100 | connections | 500 [500–500] | not run | 500 |
| 100 | lands | 100 [100–100] | not run | 500 |
| 100 | RTT p50 (ms) | 0.73 [0.73–0.73] | not run | 1 |
| 100 | RTT p95 (ms) | 1.83 [1.83–1.85] | not run | 3 |
| 100 | RTT p99 (ms) | 1.96 [1.96–1.97] | not run | 4 |
| 100 | update p50 (ms) | 100 [100–100] | not run | 100 |
| 100 | update p95 (ms) | 100 [100–100] | not run | 101 |
| 100 | update p99 (ms) | 101 [101–101] | not run | 101 |
| 100 | server CPU mean (%) | 82.4 [82.3–82.5] | not run | n/a |
| 100 | disconnect rate | 0 [0–0] | not run | 0 |
| 300 | connections | 1,500 [1,500–1,500] | 1,500 [1,500–1,500] | 1,500 |
| 300 | lands | 300 [300–300] | 300 [300–300] | 1,500 |
| 300 | RTT p50 (ms) | 0.76 [0.73–0.76] | 0.73 [0.72–0.74] | 3 |
| 300 | RTT p95 (ms) | 1.86 [1.85–1.87] | 1.86 [1.84–1.90] | 12 |
| 300 | RTT p99 (ms) | 1.97 [1.97–1.98] | 1.99 [1.96–7.09] | 15 |
| 300 | update p50 (ms) | 100 [100–100] | 100 [100–100] | 100 |
| 300 | update p95 (ms) | 100 [100–100] | 100 [100–100] | 102 |
| 300 | update p99 (ms) | 101 [101–101] | 101 [101–101] | 105 |
| 300 | server CPU mean (%) | 224.5 [224.3–225.4] | n/a | n/a |
| 300 | disconnect rate | 0 [0–0] | 0 [0–0] | 0 |
| 500 | connections | 2,500 [2,500–2,500] | 2,500 [2,500–2,500] | 2,500 |
| 500 | lands | 500 [500–500] | 500 [500–500] | 2,500 |
| 500 | RTT p50 (ms) | 0.78 [0.78–0.82] | 0.74 [0.74–0.78] | 34 |
| 500 | RTT p95 (ms) | 1.88 [1.88–1.89] | 1.86 [1.84–1.88] | 83 |
| 500 | RTT p99 (ms) | 1.99 [1.98–1.99] | 1.98 [1.98–2.05] | 147 |
| 500 | update p50 (ms) | 100 [100–100] | 100 [100–100] | 100 |
| 500 | update p95 (ms) | 101 [100–101] | 100 [100–101] | 114 |
| 500 | update p99 (ms) | 101 [101–101] | 101 [101–101] | 131 |
| 500 | server CPU mean (%) | 362.2 [357.6–362.8] | n/a | n/a |
| 500 | disconnect rate | 0 [0–0] | 0 [0–0] | 0 |

<!-- results end -->

## Caveats

### This rerun
- **The host's memory configuration changed after these runs (2026-11-07),** so later sets from this machine aren't directly comparable with this one. The pagefile moved to C: at 16–24 GB, which raised the commit limit from 33.5 GB to 48.2 GB. WSL2's `.wslconfig` is now `memory=24GB`, `swap=4GB`, `autoMemoryReclaim=gradual` (reclaim was disabled before). Windows Update is disabled, and about 160 GB was freed on C:. The next multi-room set is a new baseline.
- **Profiled runs.** The suites ran with `--profile`. The overhead pair above puts the profiler's cost at 500 rooms within the run-to-run spread: +1.7 server CPU points (+0.5 %), and RTT within 0.02 ms.
- **The overdue-fold count is a scheduler-race measure, not tick lateness.** A land's tick and sync loops are phase-locked, so whether a fold counts as overdue is decided by which loop runs first after a shared deadline (METRICS.md, "Sync folds"; #232). Read `folds / cycles`; the overdue count is kept as measured.
- **Host CPU** is the whole Windows machine, the WSL2 VM included. It shows how loaded the host was, not the server's share.
- **RTT on Hero Defense is an intake round trip.** The action is queued and answered before its tick runs it, so RTT doesn't include the action's execution, the tick or the sync (METRICS.md, "RTT").

### Comparison columns
- **2026-11-05:** 300 and 500 rooms only, 3 runs each, from build `6c7b04b`. The operator recorded that build; the run files don't carry the SHA. It isn't on `main`, and it carried turn-timing instrumentation. The client method is the November one (rooms layout, spread sends, connect ramp). Two differences remain:
  - **The scenario differs** (`data/b0/*/base-scenario.json`): every phase has 5 players per room, preflight is 8 s, steady 65 s and postflight 5 s. Steady keeps the preflight's connections and uses a 2 s warm-up.
  - **Server CPU is n/a:** those reports predate the interval-rate CPU sampler (`713ffd95`) and carry no `serverCpu`. Its RTT and update intervals compare with this rerun under those differences; its CPU doesn't.
  - **One of its 300-room runs** has an RTT p99 of 7.09 ms, against 1.96–1.99 ms for the other five runs. That's the top of its range in the table.
- **2026-02-06:** one run per room count, from the February 2026 client (`ac00e3a1`) and server. It is not comparable for latency or CPU:
  - **One land per connection:** that client gave each connection its own land (`landInstanceId` per connection), so "N rooms" there is N × 5 connections in N × 5 one-player lands. The lands row shows that.
  - **Lockstep sends:** one timer per worker sent for all its clients, and RTT ran from the actual send, not the intended one.
  - **No warm-up exclusion,** and integer-ms RTT percentiles, shown as recorded (1 means 1 ms ± 1).
  - **Its server CPU** was `ps -o %cpu`, a lifetime average on Linux, so it shows n/a here.
  - Its host and pinning weren't recorded with the load-test report.
  - The method changes since then are listed by commit in METRICS.md, "Method changes since February 2026".

  Its update-interval percentiles have the same definition (inter-arrival at one client, integer ms) and read the same way, but under that layout and load.
