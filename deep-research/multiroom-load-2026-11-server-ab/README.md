# multiroom-load-2026-11-server-ab: two server builds under the same load client

## Question

How much of the change in multi-room load results between `b629861` (2026-09-12) and `ee8a407a` (2026-11-06) comes from the server itself? Both GameServer builds ran under the same load client, scenario, pinning and host procedure, and only the server binary changed. At 100, 300, 500 and 1000 Hero Defense rooms of 5 players, what are each build's server CPU, RTT and update interval? With MoveTo input at 2 per player per second, what is each build's input-to-visible latency?

- **A** = GameServer built from `b629861`.
- **B** = GameServer built from `ee8a407a`. That's the build of `../multiroom-load-2026-11/`.

Metric definitions are in [`Examples/GameDemo/ws-loadtest/METRICS.md`](../../Examples/GameDemo/ws-loadtest/METRICS.md).

## Environment

- **Load client:** ws-loadtest at `9b41c5a9` (`main`), Node v24.22.2. Its scripts start a prebuilt server through `GAMESERVER_BIN` (from `16622147`) and pass the input-latency options (from `49ef2b74`). `toolchain.txt` next to each report records `GAMESERVER_BIN` and `GAMESERVER_SOURCE_SHA`.
- **Server builds:** both are release builds with Swift 6.2.4 (`swift-6.2.4-RELEASE`, x86_64 Linux) in the `swift:6.2.4-noble` image, with no source changes to either.
  - A was built with the default job count.
  - B's first build was interrupted by a restart of the WSL2 VM and was rebuilt with `-j 4`. The compiler flags are the same.
- **Host:** AMD Ryzen 5 7600X (6 cores, 12 logical CPUs), Windows with WSL2 (kernel `6.18.54.1-microsoft-standard-WSL2`). The SQL Server and MySQL services were stopped. Server and client ran in the same Linux environment on `localhost`.
- **Pinning:** the same `PATH` shims as `../multiroom-load-2026-11/` (`data/provenance/shim/`).
  - **Server:** `stdbuf` → `taskset -c 0-7`.
  - **Client:** `node` → `taskset -c 8-11`.
  - The operator recorded these as physical cores 0–3 for the server and 4–5 for the client.
- **Event-loop threads differ, by design of each build** (`data/provenance/startup-line-{A,B}.txt`). Neither was overridden.
  - **A** logs `threads=12`. It sizes its event-loop group from NIO's `System.coreCount`, which doesn't read the affinity mask.
  - **B** logs `threads=8, availableCPUs=8, machineCPUs=12, cpuSource=cpusAllowedList`. Sizing the group to the CPUs the process may use came in `e0033a93` (#153).
  - So under the same pinning, A runs 12 event loops on 8 CPUs.
- **Server configuration:** messagepack with opcode MessagePack state updates and path hashes in both; reevaluation recording off (`ENABLE_REEVALUATION=false`). B logs `sendBacklogMaxBytes=8388608`, `sendBacklogMaxUnwritableMs=30000` (its defaults); A has no send backlog bound.
- **Host CPU** was sampled once per second on the Windows host; only the machine total is published (`data/host-cpu.json`, steady measured window per run).

## Procedure

From `Examples/GameDemo/ws-loadtest` at the client commit. The exact command of each run is in `data/provenance/chain/<run>.run-header.txt`:

```bash
GAMESERVER_BIN=<A or B binary> GAMESERVER_SOURCE_SHA=<b629861|ee8a407a> PATH=/workspace/shim:$PATH \
  bash scripts/run-scalability-test.sh --room-counts "N" [--profile | --input-latency on --move-to-rate 2 --event-seed 1] \
  --output-dir results/ab-<run>
```

One invocation per room count. Scenario `scenarios/hero-defense/default.json`: preflight 10 s (2 players per room), steady 60 s (5 per room), postflight 10 s (2 per room), 1 action per player per second. The client used its defaults: rooms layout, spread sends, connect ramp at 1000/s, 12 workers.

1. **Smoke:** 100 rooms, one run per build.
2. **Matrix,** unprofiled: 100/300/500/1000 rooms × 3 suites × 2 builds, 24 runs. The builds are interleaved per suite: suite 1 runs A then B, suite 2 B then A, suite 3 A then B. Each build runs its four room counts in order within a suite. Server CPU is the primary metric, so these runs are unprofiled: the two builds' profilers record different counters and would cost each build a different amount.
3. **Profiled suite:** one per build, 100/300/500/1000 rooms with `--profile`, for the server counters. A's profiler predates the sync and send counters, so they're n/a for A.
4. **Input-to-visible latency:** 100/500/1000 rooms, A then B at each, unprofiled, with `--input-latency on --move-to-rate 2 --event-seed 1`.
   - Every player also sends MoveTo events at 2/s, so this is a different workload from steps 1–3. Its CPU compares only A with B within step 4.
   - `HeroDefenseLand.swift` and the inbound decoders are the same in both builds, so both handle the event the same way.

Before each run the driver waited for the host's TIME_WAIT socket count to drain. It was 0–200 at each start, after waits of 0–56 s (`data/provenance/chain/chain.log`). The steps ran back to back on 2026-11-06, 08:23–10:01 UTC. There were 40 runs and no disconnect in any of them.

**Rebuilding the results:** `python3 regenerate.py` rewrites the Results section from `data/`, and `python3 regenerate.py --check` fails if it is stale. `summarize_host.py` produced `data/host-cpu.json` from the per-second host samples, which aren't published.

## Data

| Path | What it is |
|---|---|
| `data/runs/<run>/report.json.gz` | The ws-loadtest report (JSON, gzip) of each of the 40 runs: `smoke-{A,B}`, `suite-{1,2,3}-{A,B}-{100,300,500,1000}`, `prof-{A,B}-{100,300,500,1000}`, `latency-{A,B}-{100,500,1000}` |
| `data/runs/<run>/summary.json`, `toolchain.txt` | The scalability script's summary and the toolchains, with `GAMESERVER_BIN` and `GAMESERVER_SOURCE_SHA` |
| `data/host-cpu.json` | Host CPU summary per run (mean, p95, sample count, sampler) |
| `data/provenance/` | The commits (`SHA.txt`), pinning shims, each build's startup line, per-run headers, the driver's chain log (TIME_WAIT waits) and the SHA-256 manifest of the full raw result set |

The full raw set (HTML reports, transport-profile JSONL, server logs, build logs, the per-second host samples) is kept by the maintainer. `data/provenance/MANIFEST-raw.sha256` lists its files and hashes. Each published report is the gzip of the file with the same run in the manifest.

## Results

<!-- results start -->

### Step 1: smoke, 100 rooms, steady phase

| build | rooms | joined / connections | RTT p50 / p95 / p99 (ms) | server CPU mean / p95 (%) | disconnects | join failures (by code) | phases passed (pre / steady / post) |
|---|---|---|---|---|---|---|---|
| A | 100 | 499 / 500 | 0.71 / 1.82 / 1.95 | 104.1 / 107.9 | 0 | 1 (NOT_CONNECTED 1) | PFP |
| B | 100 | 500 / 500 | 0.75 / 1.82 / 1.97 | 80.5 / 82.9 | 0 | 0 | PPP |

### Step 2: matrix, steady phase, each run (unprofiled)

| suite | build | rooms | joined at measured start / connections | RTT p50 / p95 / p99 (ms) | update p95 / p99 (ms) | server CPU mean / p95 (%, 100 = 1 core) | host CPU mean (% of machine) | client CPU total (% of 1 core) | disconnects | join failures (by code) | phases passed (pre / steady / post) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | A | 100 | 499 / 500 | 0.74 / 1.85 / 1.98 | 100 / 101 | 105.4 / 107.9 | 21.2 | 28.5 | 0 | 1 (NOT_CONNECTED 1) | FFP |
| 1 | A | 300 | 1497 / 1500 | 0.70 / 1.85 / 1.98 | 100 / 101 | 235.0 / 239.7 | 36.7 | 56.7 | 0 | 3 (NOT_CONNECTED 3) | PFF |
| 1 | A | 500 | 2494 / 2500 | 0.79 / 1.87 / 1.99 | 101 / 101 | 353.7 / 364.7 | 48.4 | 89.3 | 0 | 6 (NOT_CONNECTED 4, timeout 2) | FFF |
| 1 | A | 1000 | 4982 / 5000 | 1.36 / 4.74 / 8.10 | 102 / 104 | 578.0 / 590.3 | 71.5 | 166.7 | 0 | 18 (NOT_CONNECTED 14, timeout 4) | FFF |
| 1 | B | 100 | 500 / 500 | 0.75 / 1.86 / 1.97 | 100 / 101 | 81.3 / 84.0 | 16.0 | 27.3 | 0 | 0 | PPP |
| 1 | B | 300 | 1500 / 1500 | 0.75 / 1.85 / 1.98 | 100 / 101 | 220.8 / 226.8 | 31.4 | 53.9 | 0 | 0 | PPP |
| 1 | B | 500 | 2500 / 2500 | 0.78 / 1.89 / 2.00 | 100 / 101 | 351.8 / 359.7 | 44.6 | 84.3 | 0 | 0 | PPP |
| 1 | B | 1000 | 5000 / 5000 | 1.16 / 2.87 / 7.61 | 101 / 104 | 631.1 / 645.4 | 75.7 | 167.5 | 0 | 0 | PPP |
| 2 | A | 100 | 500 / 500 | 0.74 / 1.84 / 1.98 | 100 / 101 | 105.7 / 107.9 | 17.7 | 27.9 | 0 | 0 | PPP |
| 2 | A | 300 | 1499 / 1500 | 0.73 / 1.83 / 1.97 | 100 / 101 | 231.3 / 235.8 | 33.6 | 55.9 | 0 | 1 (NOT_CONNECTED 1) | PFF |
| 2 | A | 500 | 2494 / 2500 | 0.79 / 1.86 / 1.99 | 101 / 101 | 352.9 / 358.7 | 47.7 | 87.7 | 0 | 6 (NOT_CONNECTED 5, timeout 1) | PFF |
| 2 | A | 1000 | 4978 / 5000 | 1.15 / 2.94 / 5.19 | 101 / 103 | 578.6 / 588.2 | 69.1 | 162.4 | 0 | 22 (NOT_CONNECTED 21, timeout 1) | FFF |
| 2 | B | 100 | 500 / 500 | 0.75 / 1.86 / 1.96 | 100 / 101 | 81.9 / 83.9 | 15.2 | 26.9 | 0 | 0 | PPP |
| 2 | B | 300 | 1500 / 1500 | 0.75 / 1.86 / 1.98 | 100 / 101 | 219.7 / 225.8 | 31.7 | 54.3 | 0 | 0 | PPP |
| 2 | B | 500 | 2500 / 2500 | 0.80 / 1.89 / 2.00 | 100 / 101 | 358.5 / 366.7 | 44.8 | 84.5 | 0 | 0 | PPP |
| 2 | B | 1000 | 5000 / 5000 | 1.31 / 3.22 / 7.99 | 101 / 104 | 628.0 / 645.2 | 73.3 | 167.0 | 0 | 0 | PPP |
| 3 | A | 100 | 500 / 500 | 0.71 / 1.83 / 1.96 | 100 / 101 | 104.9 / 106.9 | 17.7 | 28.0 | 0 | 0 | PPP |
| 3 | A | 300 | 1498 / 1500 | 0.71 / 1.84 / 1.98 | 100 / 101 | 232.3 / 236.9 | 32.3 | 56.1 | 0 | 2 (NOT_CONNECTED 2) | FFF |
| 3 | A | 500 | 2495 / 2500 | 0.77 / 1.88 / 1.99 | 101 / 101 | 347.3 / 353.5 | 46.9 | 86.9 | 0 | 5 (NOT_CONNECTED 4, timeout 1) | PFF |
| 3 | A | 1000 | 4979 / 5000 | 1.25 / 3.40 / 5.71 | 101 / 103 | 572.0 / 581.3 | 69.5 | 162.5 | 0 | 21 (NOT_CONNECTED 20, timeout 1) | FFF |
| 3 | B | 100 | 500 / 500 | 0.76 / 1.84 / 1.97 | 100 / 101 | 80.2 / 81.9 | 14.6 | 27.0 | 0 | 0 | PPP |
| 3 | B | 300 | 1500 / 1500 | 0.77 / 1.86 / 1.98 | 100 / 101 | 219.6 / 225.8 | 33.3 | 53.9 | 0 | 0 | PPP |
| 3 | B | 500 | 2500 / 2500 | 0.79 / 1.89 / 2.12 | 100 / 101 | 352.8 / 359.8 | 46.5 | 84.5 | 0 | 0 | PPP |
| 3 | B | 1000 | 5000 / 5000 | 1.24 / 5.28 / 27.74 | 102 / 110 | 644.1 / 659.4 | 84.5 | 176.4 | 0 | 0 | PPP |

### Step 2 per room count and build: median [min–max] over the 3 suites

| rooms | build | joined at measured start | RTT p50 (ms) | RTT p99 (ms) | update p99 (ms) | server CPU mean (%) | server CPU per 1000 joined players (%) | host CPU mean (%) | join failures (sum) | disconnects (sum) |
|---|---|---|---|---|---|---|---|---|---|---|
| 100 | A | 500 [499–500] | 0.74 [0.71–0.74] | 1.98 [1.96–1.98] | 101 [101–101] | 105.4 [104.9–105.7] | 211.3 [209.8–211.3] | 17.7 [17.7–21.2] | 1 | 0 |
| 100 | B | 500 [500–500] | 0.75 [0.75–0.76] | 1.97 [1.96–1.97] | 101 [101–101] | 81.3 [80.2–81.9] | 162.5 [160.5–163.8] | 15.2 [14.6–16.0] | 0 | 0 |
| 300 | A | 1,498 [1,497–1,499] | 0.71 [0.70–0.73] | 1.98 [1.97–1.98] | 101 [101–101] | 232.3 [231.3–235.0] | 155.1 [154.3–157.0] | 33.6 [32.3–36.7] | 6 | 0 |
| 300 | B | 1,500 [1,500–1,500] | 0.75 [0.75–0.77] | 1.98 [1.98–1.98] | 101 [101–101] | 219.7 [219.6–220.8] | 146.5 [146.4–147.2] | 31.7 [31.4–33.3] | 0 | 0 |
| 500 | A | 2,494 [2,494–2,495] | 0.79 [0.77–0.79] | 1.99 [1.99–1.99] | 101 [101–101] | 352.9 [347.3–353.7] | 141.5 [139.2–141.8] | 47.7 [46.9–48.4] | 17 | 0 |
| 500 | B | 2,500 [2,500–2,500] | 0.79 [0.78–0.80] | 2.00 [2.00–2.12] | 101 [101–101] | 352.8 [351.8–358.5] | 141.1 [140.7–143.4] | 44.8 [44.6–46.5] | 0 | 0 |
| 1000 | A | 4,979 [4,978–4,982] | 1.25 [1.15–1.36] | 5.71 [5.19–8.10] | 103 [103–104] | 578.0 [572.0–578.6] | 116.0 [114.9–116.2] | 69.5 [69.1–71.5] | 61 | 0 |
| 1000 | B | 5,000 [5,000–5,000] | 1.24 [1.16–1.31] | 7.99 [7.61–27.74] | 104 [104–110] | 631.1 [628.0–644.1] | 126.2 [125.6–128.8] | 75.7 [73.3–84.5] | 0 | 0 |

### Server CPU, B − A (step 2)

| rooms | A median (%) | B median (%) | B − A (points) | B − A (relative) | per-suite B − A, suites 1 / 2 / 3 (points) |
|---|---|---|---|---|---|
| 100 | 105.4 | 81.3 | -24.2 | -22.9 % | -24.2, -23.7, -24.7 |
| 300 | 232.3 | 219.7 | -12.6 | -5.4 % | -14.2, -11.6, -12.7 |
| 500 | 352.9 | 352.8 | -0.1 | -0.0 % | -1.9, +5.6, +5.4 |
| 1000 | 578.0 | 631.1 | +53.0 | +9.2 % | +53.0, +49.4, +72.1 |

### Server CPU against joined players (step 2 medians)

| build | marginal CPU per 1000 players: 100→300 / 300→500 / 500→1000 rooms (%) | fit over 100–500 rooms: intercept (%) | fit: slope per 1000 players (%) | fit's value at 1000 rooms (%) | measured at 1000 rooms (%) | measured − fit (points) |
|---|---|---|---|---|---|---|
| A | 127.2 / 121.1 / 90.6 | 44.4 | 124.1 | 662.3 | 578.0 | -84.3 |
| B | 138.5 / 133.1 / 111.3 | 14.3 | 135.8 | 693.1 | 631.1 | -62.0 |

The two fitted lines cross at 2,584 joined players. The slope difference, 11.7 points per 1000 players, is 11.7 µs of CPU per state frame at 10 frames per player per second.

### Step 3: one profiled suite per build, steady phase

| build | rooms | joined / connections | RTT p50 / p95 / p99 (ms) | server CPU mean / p95 (%) | sync cycles | folds / cycles | send: buffered bytes max / unwritable episodes / longest (ms) / backlog closes | disconnects | join failures (by code) |
|---|---|---|---|---|---|---|---|---|---|
| A | 100 | 499 / 500 | 0.70 / 1.84 / 1.97 | 106.8 / 111.9 | n/a | n/a | n/a | 0 | 1 (NOT_CONNECTED 1) |
| A | 300 | 1500 / 1500 | 0.73 / 1.84 / 1.97 | 240.1 / 245.8 | n/a | n/a | n/a | 0 | 0 |
| A | 500 | 2499 / 2500 | 0.76 / 1.88 / 1.99 | 351.1 / 364.6 | n/a | n/a | n/a | 0 | 1 (NOT_CONNECTED 1) |
| A | 1000 | 4978 / 5000 | 1.10 / 3.92 / 7.88 | 580.4 / 589.3 | n/a | n/a | n/a | 0 | 22 (NOT_CONNECTED 16, timeout 6) |
| B | 100 | 500 / 500 | 0.75 / 1.84 / 1.97 | 81.4 / 83.9 | 56,012 | 0.332 | 0 / 0 / 0 / 0 | 0 | 0 |
| B | 300 | 1500 / 1500 | 0.77 / 1.86 / 1.96 | 220.1 / 224.9 | 165,038 | 0.357 | 0 / 0 / 0 / 0 | 0 | 0 |
| B | 500 | 2500 / 2500 | 0.80 / 1.89 / 2.05 | 350.7 / 358.6 | 270,079 | 0.387 | 0 / 0 / 0 / 0 | 0 | 0 |
| B | 1000 | 5000 / 5000 | 1.18 / 3.04 / 9.52 | 629.8 / 644.2 | 520,234 | 0.365 | 0 / 0 / 0 / 0 | 0 | 0 |

### Step 4: input-to-visible latency, MoveTo at 2/s per player, steady phase (unprofiled)

| rooms | build | joined / connections | input-to-visible p50 / p95 / p99 / max (ms) | sent / seen / superseded / timed out | RTT p50 / p95 / p99 (ms) | update p95 / p99 (ms) | server CPU mean / p95 (%) | client CPU total / worst worker (%) / worst loop delay p99 (ms) | disconnects | join failures (by code) |
|---|---|---|---|---|---|---|---|---|---|---|
| 100 | A | 500 / 500 | 56 / 100 / 140 / 151 | 57,409 / 57,409 / 0 / 0 | 0.72 / 1.86 / 1.97 | 100 / 101 | 124.0 / 127.9 | 35.6 / 3.1 / 0.69 | 0 | 0 |
| 100 | B | 500 / 500 | 54 / 96 / 99 / 101 | 57,421 / 57,421 / 0 / 0 | 0.74 / 1.85 / 1.97 | 100 / 101 | 100.3 / 101.9 | 35.1 / 3.1 / 0.79 | 0 | 0 |
| 500 | A | 2494 / 2500 | 56 / 102 / 141 / 166 | 276,427 / 276,118 / 309 / 0 | 0.87 / 1.95 / 2.81 | 101 / 101 | 446.4 / 459.5 | 121.6 / 10.3 / 0.96 | 0 | 6 (NOT_CONNECTED 6) |
| 500 | B | 2500 / 2500 | 50 / 96 / 100 / 111 | 277,147 / 277,147 / 0 / 0 | 0.82 / 1.92 / 2.49 | 101 / 101 | 457.5 / 466.5 | 118.0 / 10.0 / 0.96 | 0 | 0 |
| 1000 | A | 4960 / 5000 | 2063 / 3688 / 3898 / 4951 | 485,685 / 110,384 / 375,288 / 13 | 7022.95 / 16747.33 / 17965.01 | 134 / 158 | 746.6 / 756.1 | 220.9 / 18.6 / 2.00 | 0 | 40 (NOT_CONNECTED 33, timeout 7) |
| 1000 | B | 5000 / 5000 | 191 / 318 / 381 / 641 | 527,481 / 527,480 / 0 / 1 | 158.00 / 262.85 / 320.20 | 179 / 221 | 747.5 / 753.3 | 207.8 / 17.6 / 1.42 | 0 | 0 |

### Build A's join failures by phase: JOIN_SESSION_NOT_CONNECTED / timeout (no response in 5 s)

| run | preflight | steady | postflight |
|---|---|---|---|
| latency-A-100 | 0 / 0 | 0 / 0 | 0 / 0 |
| latency-A-1000 | 5 / 5 | 33 / 7 | 0 / 2000 |
| latency-A-500 | 1 / 0 | 6 / 0 | 4 / 1 |
| prof-A-100 | 0 / 0 | 1 / 0 | 0 / 0 |
| prof-A-1000 | 2 / 1 | 16 / 6 | 16 / 1 |
| prof-A-300 | 0 / 0 | 0 / 0 | 0 / 0 |
| prof-A-500 | 0 / 0 | 1 / 0 | 4 / 2 |
| smoke-A | 0 / 0 | 1 / 0 | 0 / 0 |
| suite-1-A-100 | 1 / 0 | 1 / 0 | 0 / 0 |
| suite-1-A-1000 | 2 / 0 | 14 / 4 | 14 / 0 |
| suite-1-A-300 | 0 / 0 | 3 / 0 | 1 / 1 |
| suite-1-A-500 | 1 / 0 | 4 / 2 | 1 / 0 |
| suite-2-A-100 | 0 / 0 | 0 / 0 | 0 / 0 |
| suite-2-A-1000 | 6 / 0 | 21 / 1 | 16 / 0 |
| suite-2-A-300 | 0 / 0 | 1 / 0 | 1 / 0 |
| suite-2-A-500 | 0 / 0 | 5 / 1 | 5 / 2 |
| suite-3-A-100 | 0 / 0 | 0 / 0 | 0 / 0 |
| suite-3-A-1000 | 1 / 0 | 20 / 1 | 14 / 1 |
| suite-3-A-300 | 1 / 0 | 2 / 0 | 1 / 0 |
| suite-3-A-500 | 0 / 0 | 4 / 1 | 4 / 0 |

Build B had no join failure in any phase of any run.

<!-- results end -->

## Reading the results

- **Server CPU, step 2:** B is lower than A at 100 and 300 rooms, equal at 500, and 9.2 % higher at 1000.
  - Against joined players, B has the smaller intercept and the larger slope: about 136 against 124 CPU points per 1000 players over 100–500 rooms.
  - The difference at 1000 rooms isn't specific to 1000 rooms. It's B's higher per-player cost, which B's smaller fixed cost no longer offsets past about 2,600 players.
  - Both builds come in under their 100–500 line at 1000 rooms, A by more.
- **The work is the same per player.** In the step 3 profiles at 1000 rooms, A sends 49,890 state updates and handles 4,979 actions per 1 s profile window, against 50,015 and 5,001 for B. These are per-window medians over the steady measured window, from the profile JSONL, which isn't published. A's 18–22 fewer joined players at 1000 rooms are 0.4 % of the load: at A's slope, under 3 CPU points.
- **Latency at the same CPU, step 4:** at 1000 rooms both builds run at about 747 % of the 8 pinned CPUs.
  - A falls behind: RTT p50 7.0 s, input-to-visible p50 2.1 s, and 375,288 of 485,685 inputs superseded before they were seen. In its postflight, none of the 2,000 joins was answered within 5 s.
  - B keeps up, slower: RTT p50 158 ms, input-to-visible p50 191 ms and p99 381 ms, with 0 superseded.
  - At 100 and 500 rooms, input-to-visible p99 is 99–100 ms for B and 140–141 ms for A.

## Diagnosis of B's per-player cost

*Pending.* B alone, with no code change, unprofiled, at 100 and 1000 rooms, 3 suites, interleaved:

- **D:** default.
- **T12:** `EVENT_LOOP_THREADS=12`, A's thread count. This tests the fixed-cost side, #153.
- **L:** `IN_TURN_SYNC=false`. The legacy sync path tests whether the in-turn sync and the ordered writer carry the per-frame cost: `ba76ca21` #86, `1eb1e161` #91, `8ca24f76` #114.

The results go here when the runs are in.

## Caveats

- **A's join failures are a connect race that B doesn't have.**
  - At `b629861` the WebSocket handler hands a session's connect and its first messages to the transport as separate, unordered tasks (`WebSocketSessionHandler.swift`: the connect in `handlerAdded`, the messages in `flushPendingMessages`). A client's join can then reach the router before the connection is registered.
  - **If the session's send queue already exists,** the router answers `JOIN_SESSION_NOT_CONNECTED`.
  - **If the queue doesn't exist yet,** the transport drops that answer, so the client hears nothing and times out after 5 s.
  - `0a4f9be2` (#112) runs each session's connect, messages and disconnect in one serial chain, and B had no join failure in any run.
  - A's failed connections don't send actions (the client sends only on joined connections), so A carried slightly fewer players. The joined counts are in the tables.
- **A's phases fail the pass bar on those join failures** (a join failure fails its phase), and the script exits nonzero for those runs. Their RTT, update and CPU figures are still measured over the joined connections.
- **The thread counts differ** (above). They're part of the measured difference between the builds, not a separate setting. A has no override for them.
- **B was rebuilt with `-j 4`.** The job count changes build parallelism, not the compiler's output flags.
- **RTT on Hero Defense is an intake round trip.** The server queues the action and answers before the tick runs it, so RTT doesn't include the action's execution, the tick or the sync (METRICS.md, "RTT"). It grows with how long a session's inbound messages wait to be handled.
- **Step 4's workload differs** from steps 1–3: MoveTo events on top of the actions, plus the client's tracker. Compare its server CPU only between A and B within step 4.
- **Pinning uses logical CPU IDs** as the WSL2 VM numbers them. The physical core mapping is as the operator recorded it.
- **The profiled suite (step 3)** costs each build differently. The sync and send counters exist only for B, and step 2's unprofiled CPU is the comparison.
