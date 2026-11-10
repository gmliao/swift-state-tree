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

**The profiler-overhead pair runs right after the preflight, and gates the suites.** Every table's RTT comes from profiled runs, so after the pair (back to back, at the matrix's top room count: 500 unless `TOP_ROOMS` sets it), a profiled steady RTT p99 more than max(+1 ms, +25 %) over the unprofiled one stops the sweep (`failed-profiler-overhead`, `profiler_overhead.py`), and `regenerate.py` refuses an arm sweep whose pair broke the bound. The refreeze sweep's pair (archived) was 5.83 against 1.98 ms: in its profiled run, two consecutive 1 s windows 16–17 s into steady had the whole population's RTT shifted (p50 0.83 → 5.86 ms, p95 7.43 ms) and recovered the next second, with state updates at their 100 ms cadence and server CPU and RSS flat; no other window of that sweep, in any run or phase, had an RTT p50 over 2 ms, and its other ten profiled 500-room steady phases were at 1.98–2.00 ms. The report doesn't say why; the server's per-second lag for that second is in the run's raw transport profile. The 2026-11-06 pair was within 0.1 %. Sets before the arms ran the pair after the suites.

**The arm sweeps are this topic's data set.** `python3 collect.py --run-id <RUN_ID>` converts a sweep into `results/<RUN_ID>/`, and `python3 regenerate.py` puts the arms' tables first in Results, after every `--sweep` gate (the rules for what `results/` may hold are under the MoveTo arms above). The 2026-11-06 set stays under `data/` and renders after it as the pre-refreeze record, captioned with its wire form (path index and field merge off, by its commit's ancestry). It isn't compared with the sweep. `python3 regenerate.py --results <dir> --markdown` prints the whole section from another directory, as a dry run that leaves README.md alone.

`DRY_RUN=1 bash run.sh` prints every command; its header lists the options. A smoke run off the host: `RUNS=suite-1-100 ROOMS=10 PRE_S=2 STEADY_S=5 POST_S=2 SERVER_CPUS= CLIENT_CPUS= RUN_ID=smoke bash run.sh`. `python3 test_topic.py` checks the dry run's plan. Its output isn't wired to `regenerate.py`, which reads the published `data/`.

Each run's exact command, start and end time, shims, toolchain and kernel are in `data/provenance/chain/<run>.run-header.txt`. The scenario is `scenarios/hero-defense/default.json`: preflight 10 s (2 players per room), steady 60 s (5 players per room), postflight 10 s (2 players per room), 1 action per player per second. The client used its defaults: `--layout rooms`, `--send spread`, `--connect ramp` at 1000/s, `--boundary clean`, 12 workers.

**Hero Defense's spawn ramp, from the commit after the 2026-11-06 set:** `run.sh` exports `HERO_DEFENSE_SPAWN_RAMP_TICKS=0` for the servers it starts, so every land spawns at the game's final rate (an interval of 3 ticks) from its first tick instead of ramping over 3000 ticks (150 s; #425). run.json records it (`spawnRampTicks`) and, per run, the value the server reported at startup (`spawnRampTicksEffective`, from its log). A run whose server reports another value fails (`failed-spawn-ramp`). The 2026-11-06 set and the refreeze before it ran the game's own ramp; its runs are about 80 s long, so their steady phase saw the slow start of the ramp (a few monsters per room), not its plateau. Without the ramp a land's base reaches 0 within about a minute (health clamped at 0; play continues). A record doesn't carry the ramp: replay one with the value its run had.

**Steady's hold, with the ramp skipped:** a land's monster count settles at its plateau for the players in it, and preflight runs 2 players per room (its verify gate) before steady's 5. So steady warms up for 30 s before it measures (`STEADY_WARMUP_S`, default 30): run.sh's scenario is always a copy of `default.json` in `raw/<RUN_ID>/scenario.json` with steady's `warmupSeconds` 30 and its length 90 s, and ws-loadtest leaves the warm-up out of the phase's metrics, so steady measures exactly 60 s. The warm-up includes steady's connect ramp (0.5–2.5 s at 100–500 rooms), so the full 5 players per room are held a little under 30 s. The sets before the hold ran ws-loadtest's default warm-up (the connect ramp plus 2 s, `warmupMs` 2540–4520) and measured 55.5–57.5 s; every rate takes the measured window, so the rates stay comparable. run.json records the hold (`steadyWarmupS`). Each run's server writes its own `land-stats.jsonl` (`HERO_DEFENSE_STATS_PATH`); `collect.py` summarizes it over steady's measured window (`steadyLandStats` in sweep.json: per-10 s medians over lands of the live monster count, the spawned, killed and reached-base rates, and the base health; `deep-research/landstats.py`), and `regenerate.py` tables a sweep with the hold only when every report holds 30 s, every server ran without the ramp, and every run's window is stationary (per-10 s medians: coefficient of variation at most 0.10, none more than 20 % from their mean, and the last third's median within 10 % of the first third's). The drift bound is what refuses a slow trend: a rise of a third across the window is within the CoV bound (0.098) but drifts 23 %. Sweeps without the hold (the 2026-11-06 set and the refreeze) are checked against the phases they ran.

**The MoveTo arms (#430):** how sensitive the capacity results are to the players' input rate. Every topic so far used stationary players (one `PlayAction` per second each); interactive games send 2–10 inputs per player per second. `MOVE_TO_PER_S=<n>` (default 0) adds n `MoveTo` events per player per second through ws-loadtest's `--move-to-rate` overlay; 0 passes no flag, so arm 0's command and scenario are the ones before the arms. The set is three whole sweeps at one commit, in the order 0, 2, 5 (a sensitivity analysis, not an interleaved A/B), then `CONTROL=1`: one run, suite-1's at 300 rooms at arm 0, as a host-drift check. **The room counts are parameters:** `TOP_ROOMS` (default 500) is the preflight's and the overhead pair's, and `SUITE_ROOMS` (default `100 300 500`, ascending, none over the top) the suites'. So a host whose capacity is under 500 rooms with the spawn ramp skipped runs a lower top, and an arm can leave out room counts over capacity. run.json records both (`topRooms`, `suiteRooms`), regenerate tables what each sweep ran (the sensitivity table reads "not run" where an arm left one out), and the control is compared only if arm 0 ran 300 rooms.

**The arms' workload (`WORKLOAD`):** `plateau` (the default) skips the spawn ramp and holds steady 30 s, as the paragraphs above describe. `refreeze` runs the refreeze sweep's rules: Hero Defense's own spawn ramp (3000 ticks, 150 s; the variable unset, and every server must report 3000) and no hold (ws-loadtest's default warm-up, the connect ramp plus 2 s, as the refreeze had), so its arm 0 is like for like with the archived refreeze. run.json records the workload; `regenerate.py` tables one workload per arm set (the arms and the control), refuses a mixed set, captions the section by it, and applies the stationarity gate to `plateau` only. **The MoveTo arms run under `refreeze`.**

**The limit of the ramped windows, and the capacity without the ramp.** Under `refreeze` a land is about 0–70 s old from the preflight's start to the end of steady, inside the 150 s ramp, so its monster load rises through steady's measured window: the arm tables compare the arms at the same land ages, not at a stationary load. The plateau figures on this host, measured on 2026-11-10 with the ramp skipped, are the disclosed capacity at full load: 300 rooms × 5 players passed at 499 % server CPU, 500 rooms failed at 777 % of the 8 server CPUs (steady RTT p95 231 ms, p99 280 ms, update p95 171 ms), and network-impairment's 300-room P0 ran at about 545 %. `regenerate.py` tables each arm, a sensitivity table per room count (MoveTo sent, server CPU and CPU per room, update bytes per recipient per second, RTT p99, disconnects), and reports the control: its server CPU per room against the min–max of arm 0's three 300-room runs; outside it, the set is flagged for host drift. The control isn't tabled. **Limit: the input-turn cost #430 asks for isn't tabled.** It isn't in the client's report. Every profiled run (all but `overhead-unprofiled`, the control included) keeps its server profile, `transport-profile.jsonl`, in its raw run directory, which goes to the private store with the rest; `run.sh` stops a sweep whose profiled run left none (`failed-no-profile`). The profile has, per second, the messages and actions received and the sync phases' times, and latency distributions of message decode, handling, encode and send sampled 1 in 100. Its handling time is the transport's, not the land's per-input turn time. A table of the input cost per arm can be built from those raw files later without re-measuring. The profiler's own cost is measured in every sweep by its overhead pair (`overhead-profiled` and `overhead-unprofiled`, 500 rooms, back to back).

**The load client must not be the bottleneck** (`clientload.py`, the rule network-impairment applies, from the report rather than per-event samples). After every run, `run.sh` reads each phase's measured window from the report: the workers' CPU demand (`measurement.clientCpu`, the workers' share of one core over the client's pinned CPUs) and each worker's event-loop utilization (`measurement.clientElu`, ws-loadtest's per-phase report field; not network-impairment's run.json `meta.clientElu`, which has another shape). A demand of 70 % or more, a worker ELU over 0.5, or either figure missing for any of the configured workers stops the sweep (`failed-client-load`), and `regenerate.py` refuses an arm sweep whose run broke it.

**Earlier sets are archived, not deleted.** `results/` holds the arm sweeps and the control only; a sweep that records no arm is refused there. The refreeze sweep (`20261109T140702Z-022d8fdb`, run with the game's spawn ramp and no hold) is in `results/archive/20261109T140702Z-022d8fdb/`, which the results section doesn't read; `python3 regenerate.py --sweep results/archive/20261109T140702Z-022d8fdb` prints its tables as they were published.

**The sync path (#468).** `run.sh` records the sync-path and wire switches the shell had (`USE_SNAPSHOT_FOR_SYNC`, `IN_TURN_SYNC`, `USE_SYNC_TABLES`, `ROW_ADDRESSING`, `SYNC_STRATEGY`, and the send bounds `OUTBOUND_WRITER_MAX_BYTES` and `JOIN_FLIP_BUDGET`; run.json's `syncPathEnv` and each run header) and unsets them before any server starts, so every run takes the shipped sync path. The sets before that ran in-turn sync: every profiled run of the MoveTo arms (695fe86c), of the archived refreeze and of the 2026-11-06 record has sync folds, which only in-turn sync makes (the unprofiled run of each overhead pair records no counters). Before this, the topic's scripts didn't record the snapshot switch, which leaves no trace in a report.

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

### MoveTo arms (#430)

Workload: the refreeze sweep's rules, Hero Defense's own spawn ramp (3000 ticks, 150 s) and ws-loadtest's default warm-up (the connect ramp plus 2 s), so each land's monster load rises through steady (see the limit under the README's MoveTo arms).

#### MoveTo 0/s per player

Provenance, from the results' meta: commit `695fe86cb985752293dc184ff4d650b0689d90c2`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

Sweep `mr-20261110-arm0`, wire form messagepack, pathIndex on, fieldMerge on. Host CPU isn't sampled by run.sh (n/a). The 2026-11-06 set ran without path indices and merged entries, so its bytes and CPU aren't comparable with this sweep's like for like.

##### Steady phase, each run

| suite | rooms | connections | lands | RTT p50 / p95 / p99 (ms) | update interval p50 / p95 / p99 (ms) | server CPU mean / p95 (%, 100 = 1 core) | host CPU mean / p95 (% of machine) | client CPU total / worst worker (% of 1 core) | worst worker loop delay p99 (ms) | disconnects / join failures / errors | phase |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 500 | 100 | 0.70 / 1.83 / 1.97 | 100 / 100 / 101 | 86.0 / 88.9 | n/a / n/a | 26.8 / 2.3 | 0.68 | 0 / 0 / 0 | pass |
| 1 | 300 | 1,500 | 300 | 0.73 / 1.85 / 1.98 | 100 / 100 / 101 | 239.8 / 256.7 | n/a / n/a | 55.5 / 4.7 | 0.89 | 0 / 0 / 0 | pass |
| 1 | 500 | 2,500 | 500 | 0.74 / 1.88 / 2.00 | 100 / 101 / 101 | 373.4 / 381.5 | n/a / n/a | 85.8 / 7.2 | 0.94 | 0 / 0 / 0 | pass |
| 2 | 100 | 500 | 100 | 0.70 / 1.81 / 1.97 | 100 / 100 / 101 | 87.8 / 92.9 | n/a / n/a | 27.8 / 2.4 | 0.78 | 0 / 0 / 0 | pass |
| 2 | 300 | 1,500 | 300 | 0.75 / 1.87 / 2.07 | 100 / 100 / 101 | 243.4 / 251.7 | n/a / n/a | 57.5 / 4.8 | 0.89 | 0 / 0 / 0 | pass |
| 2 | 500 | 2,500 | 500 | 0.77 / 1.87 / 1.99 | 100 / 100 / 101 | 373.6 / 381.6 | n/a / n/a | 85.8 / 7.3 | 0.92 | 0 / 0 / 0 | pass |
| 3 | 100 | 500 | 100 | 0.76 / 1.84 / 1.98 | 100 / 100 / 101 | 87.7 / 92.9 | n/a / n/a | 27.8 / 2.4 | 0.74 | 0 / 0 / 0 | pass |
| 3 | 300 | 1,500 | 300 | 0.71 / 1.85 / 1.98 | 100 / 100 / 101 | 237.8 / 243.8 | n/a / n/a | 55.3 / 4.7 | 0.89 | 0 / 0 / 0 | pass |
| 3 | 500 | 2,500 | 500 | 0.78 / 1.89 / 2.00 | 100 / 100 / 101 | 376.6 / 383.5 | n/a / n/a | 85.6 / 7.3 | 0.94 | 0 / 0 / 0 | pass |

##### Server counters, steady phase, each run

| suite | rooms | sync cycles | sync skips (backlog + busy) | folds / cycles | overdue folds per 1000 cycles (scheduler race, see Caveats) | send buffered bytes max | unwritable episodes | longest unwritable (ms) | backlog closes (4008) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 56,018 | 0 | 0.375 | 366 | 0 | 0 | 0 | 0 |
| 1 | 300 | 165,071 | 0 | 0.373 | 360 | 0 | 0 | 0 | 0 |
| 1 | 500 | 270,133 | 0 | 0.394 | 368 | 0 | 0 | 0 | 0 |
| 2 | 100 | 56,023 | 0 | 0.356 | 343 | 0 | 0 | 0 | 0 |
| 2 | 300 | 165,075 | 0 | 0.370 | 349 | 0 | 0 | 0 | 0 |
| 2 | 500 | 270,139 | 0 | 0.387 | 356 | 0 | 0 | 0 | 0 |
| 3 | 100 | 56,024 | 0 | 0.368 | 357 | 0 | 0 | 0 | 0 |
| 3 | 300 | 165,078 | 0 | 0.364 | 348 | 0 | 0 | 0 | 0 |
| 3 | 500 | 270,119 | 0 | 0.391 | 351 | 0 | 0 | 0 | 0 |

##### Steady phase per room count: median [min–max] over the 3 suites

| rooms | runs | RTT p50 (ms) | RTT p99 (ms) | update p95 (ms) | update p99 (ms) | server CPU mean (%) | host CPU mean (%) | disconnects (sum) |
|---|---|---|---|---|---|---|---|---|
| 100 | 3 | 0.70 [0.70–0.76] | 1.97 [1.97–1.98] | 100 [100–100] | 101 [101–101] | 87.7 [86.0–87.8] | n/a | 0 |
| 300 | 3 | 0.73 [0.71–0.75] | 1.98 [1.98–2.07] | 100 [100–100] | 101 [101–101] | 239.8 [237.8–243.4] | n/a | 0 |
| 500 | 3 | 0.77 [0.74–0.78] | 2.00 [1.99–2.00] | 100 [100–101] | 101 [101–101] | 373.6 [373.4–376.6] | n/a | 0 |

##### Profiler overhead, 500 rooms, back to back

| steady phase | profiled | unprofiled | difference | relative |
|---|---|---|---|---|
| RTT p50 (ms) | 0.81 | 0.78 | 0.02 | 3.2 % |
| RTT p95 (ms) | 1.86 | 1.88 | -0.02 | -0.8 % |
| RTT p99 (ms) | 1.97 | 1.99 | -0.02 | -0.9 % |
| server CPU mean (%) | 374.0 | 379.0 | -5.0 | -1.3 % |

Both runs: 0 and 0 disconnects.

#### MoveTo 2/s per player

Provenance, from the results' meta: commit `695fe86cb985752293dc184ff4d650b0689d90c2`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

Sweep `mr-20261110-arm2`, wire form messagepack, pathIndex on, fieldMerge on. Host CPU isn't sampled by run.sh (n/a). The 2026-11-06 set ran without path indices and merged entries, so its bytes and CPU aren't comparable with this sweep's like for like.

##### Steady phase, each run

| suite | rooms | connections | lands | RTT p50 / p95 / p99 (ms) | update interval p50 / p95 / p99 (ms) | server CPU mean / p95 (%, 100 = 1 core) | host CPU mean / p95 (% of machine) | client CPU total / worst worker (% of 1 core) | worst worker loop delay p99 (ms) | disconnects / join failures / errors | phase |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 500 | 100 | 0.69 / 1.80 / 1.96 | 100 / 100 / 101 | 108.8 / 110.9 | n/a / n/a | 32.9 / 2.9 | 0.76 | 0 / 0 / 0 | pass |
| 1 | 300 | 1,500 | 300 | 0.74 / 1.85 / 1.98 | 100 / 101 / 101 | 306.4 / 320.9 | n/a / n/a | 71.7 / 6.1 | 0.87 | 0 / 0 / 0 | pass |
| 1 | 500 | 2,500 | 500 | 0.85 / 1.90 / 2.39 | 100 / 101 / 101 | 481.3 / 489.6 | n/a / n/a | 107.8 / 9.1 | 0.98 | 0 / 0 / 0 | pass |
| 2 | 100 | 500 | 100 | 0.73 / 1.79 / 1.96 | 100 / 100 / 101 | 110.3 / 114.9 | n/a / n/a | 34.5 / 3.0 | 0.76 | 0 / 0 / 0 | pass |
| 2 | 300 | 1,500 | 300 | 0.78 / 1.88 / 1.98 | 100 / 100 / 101 | 299.0 / 307.7 | n/a / n/a | 68.7 / 5.8 | 0.93 | 0 / 0 / 0 | pass |
| 2 | 500 | 2,500 | 500 | 0.93 / 1.97 / 2.85 | 100 / 101 / 101 | 483.8 / 502.4 | n/a / n/a | 111.0 / 9.4 | 0.98 | 0 / 0 / 0 | pass |
| 3 | 100 | 500 | 100 | 0.70 / 1.86 / 1.99 | 100 / 100 / 101 | 108.8 / 113.9 | n/a / n/a | 33.5 / 2.9 | 0.75 | 0 / 0 / 0 | pass |
| 3 | 300 | 1,500 | 300 | 0.74 / 1.85 / 1.97 | 100 / 100 / 101 | 298.9 / 304.6 | n/a / n/a | 69.0 / 5.8 | 0.93 | 0 / 0 / 0 | pass |
| 3 | 500 | 2,500 | 500 | 0.86 / 1.94 / 2.57 | 100 / 101 / 101 | 478.0 / 491.1 | n/a / n/a | 108.8 / 9.3 | 0.94 | 0 / 0 / 0 | pass |

##### Server counters, steady phase, each run

| suite | rooms | sync cycles | sync skips (backlog + busy) | folds / cycles | overdue folds per 1000 cycles (scheduler race, see Caveats) | send buffered bytes max | unwritable episodes | longest unwritable (ms) | backlog closes (4008) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 56,022 | 0 | 0.404 | 403 | 0 | 0 | 0 | 0 |
| 1 | 300 | 165,090 | 0 | 0.393 | 367 | 0 | 0 | 0 | 0 |
| 1 | 500 | 270,164 | 0 | 0.405 | 357 | 0 | 0 | 0 | 0 |
| 2 | 100 | 56,029 | 0 | 0.342 | 321 | 0 | 0 | 0 | 0 |
| 2 | 300 | 165,073 | 0 | 0.382 | 357 | 0 | 0 | 0 | 0 |
| 2 | 500 | 270,173 | 0 | 0.396 | 331 | 0 | 0 | 0 | 0 |
| 3 | 100 | 56,030 | 0 | 0.360 | 339 | 0 | 0 | 0 | 0 |
| 3 | 300 | 165,083 | 0 | 0.363 | 331 | 0 | 0 | 0 | 0 |
| 3 | 500 | 270,128 | 0 | 0.380 | 337 | 0 | 0 | 0 | 0 |

##### Steady phase per room count: median [min–max] over the 3 suites

| rooms | runs | RTT p50 (ms) | RTT p99 (ms) | update p95 (ms) | update p99 (ms) | server CPU mean (%) | host CPU mean (%) | disconnects (sum) |
|---|---|---|---|---|---|---|---|---|
| 100 | 3 | 0.70 [0.69–0.73] | 1.96 [1.96–1.99] | 100 [100–100] | 101 [101–101] | 108.8 [108.8–110.3] | n/a | 0 |
| 300 | 3 | 0.74 [0.74–0.78] | 1.98 [1.97–1.98] | 100 [100–101] | 101 [101–101] | 299.0 [298.9–306.4] | n/a | 0 |
| 500 | 3 | 0.86 [0.85–0.93] | 2.57 [2.39–2.85] | 101 [101–101] | 101 [101–101] | 481.3 [478.0–483.8] | n/a | 0 |

##### Profiler overhead, 500 rooms, back to back

| steady phase | profiled | unprofiled | difference | relative |
|---|---|---|---|---|
| RTT p50 (ms) | 0.87 | 0.91 | -0.04 | -4.0 % |
| RTT p95 (ms) | 1.93 | 1.92 | 0.00 | 0.1 % |
| RTT p99 (ms) | 2.46 | 2.32 | 0.14 | 5.8 % |
| server CPU mean (%) | 478.0 | 480.6 | -2.6 | -0.5 % |

Both runs: 0 and 0 disconnects.

#### MoveTo 5/s per player

Provenance, from the results' meta: commit `695fe86cb985752293dc184ff4d650b0689d90c2`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

Sweep `mr-20261110-arm5`, wire form messagepack, pathIndex on, fieldMerge on. Host CPU isn't sampled by run.sh (n/a). The 2026-11-06 set ran without path indices and merged entries, so its bytes and CPU aren't comparable with this sweep's like for like.

##### Steady phase, each run

| suite | rooms | connections | lands | RTT p50 / p95 / p99 (ms) | update interval p50 / p95 / p99 (ms) | server CPU mean / p95 (%, 100 = 1 core) | host CPU mean / p95 (% of machine) | client CPU total / worst worker (% of 1 core) | worst worker loop delay p99 (ms) | disconnects / join failures / errors | phase |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 500 | 100 | 0.68 / 1.82 / 1.97 | 100 / 100 / 101 | 128.0 / 130.9 | n/a / n/a | 38.6 / 3.4 | 0.77 | 0 / 0 / 0 | pass |
| 1 | 300 | 1,500 | 300 | 0.83 / 1.88 / 1.98 | 100 / 101 / 101 | 358.4 / 364.7 | n/a / n/a | 81.9 / 6.9 | 0.94 | 0 / 0 / 0 | pass |
| 1 | 500 | 2,500 | 500 | 1.07 / 2.22 / 2.98 | 100 / 101 / 101 | 573.7 / 585.3 | n/a / n/a | 128.0 / 10.8 | 0.99 | 0 / 0 / 0 | pass |
| 2 | 100 | 500 | 100 | 0.74 / 1.83 / 1.97 | 100 / 100 / 101 | 127.6 / 131.8 | n/a / n/a | 39.0 / 3.4 | 0.74 | 0 / 0 / 0 | pass |
| 2 | 300 | 1,500 | 300 | 0.81 / 1.86 / 1.98 | 100 / 101 / 101 | 355.4 / 361.6 | n/a / n/a | 80.5 / 6.8 | 0.93 | 0 / 0 / 0 | pass |
| 2 | 500 | 2,500 | 500 | 0.99 / 2.20 / 5.89 | 100 / 101 / 101 | 567.5 / 577.3 | n/a / n/a | 128.3 / 10.8 | 0.99 | 0 / 0 / 0 | pass |
| 3 | 100 | 500 | 100 | 0.65 / 1.81 / 1.96 | 100 / 100 / 101 | 127.7 / 131.0 | n/a / n/a | 38.9 / 3.4 | 0.69 | 0 / 0 / 0 | pass |
| 3 | 300 | 1,500 | 300 | 0.76 / 1.86 / 1.98 | 100 / 101 / 101 | 357.5 / 365.5 | n/a / n/a | 81.5 / 6.8 | 0.91 | 0 / 0 / 0 | pass |
| 3 | 500 | 2,500 | 500 | 1.09 / 2.00 / 2.97 | 100 / 101 / 101 | 572.9 / 584.3 | n/a / n/a | 127.3 / 10.8 | 0.99 | 0 / 0 / 0 | pass |

##### Server counters, steady phase, each run

| suite | rooms | sync cycles | sync skips (backlog + busy) | folds / cycles | overdue folds per 1000 cycles (scheduler race, see Caveats) | send buffered bytes max | unwritable episodes | longest unwritable (ms) | backlog closes (4008) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 56,027 | 0 | 0.356 | 355 | 0 | 0 | 0 | 0 |
| 1 | 300 | 165,083 | 0 | 0.375 | 356 | 0 | 0 | 0 | 0 |
| 1 | 500 | 270,158 | 0 | 0.392 | 334 | 0 | 0 | 0 | 0 |
| 2 | 100 | 56,024 | 0 | 0.302 | 295 | 0 | 0 | 0 | 0 |
| 2 | 300 | 165,092 | 0 | 0.417 | 396 | 0 | 0 | 0 | 0 |
| 2 | 500 | 270,184 | 0 | 0.389 | 311 | 0 | 0 | 0 | 0 |
| 3 | 100 | 56,029 | 0 | 0.323 | 290 | 0 | 0 | 0 | 0 |
| 3 | 300 | 165,082 | 0 | 0.426 | 388 | 0 | 0 | 0 | 0 |
| 3 | 500 | 270,150 | 0 | 0.355 | 283 | 0 | 0 | 0 | 0 |

##### Steady phase per room count: median [min–max] over the 3 suites

| rooms | runs | RTT p50 (ms) | RTT p99 (ms) | update p95 (ms) | update p99 (ms) | server CPU mean (%) | host CPU mean (%) | disconnects (sum) |
|---|---|---|---|---|---|---|---|---|
| 100 | 3 | 0.68 [0.65–0.74] | 1.97 [1.96–1.97] | 100 [100–100] | 101 [101–101] | 127.7 [127.6–128.0] | n/a | 0 |
| 300 | 3 | 0.81 [0.76–0.83] | 1.98 [1.98–1.98] | 101 [101–101] | 101 [101–101] | 357.5 [355.4–358.4] | n/a | 0 |
| 500 | 3 | 1.07 [0.99–1.09] | 2.98 [2.97–5.89] | 101 [101–101] | 101 [101–101] | 572.9 [567.5–573.7] | n/a | 0 |

##### Profiler overhead, 500 rooms, back to back

| steady phase | profiled | unprofiled | difference | relative |
|---|---|---|---|---|
| RTT p50 (ms) | 1.07 | 1.08 | -0.01 | -1.2 % |
| RTT p95 (ms) | 1.99 | 1.99 | 0.00 | 0.0 % |
| RTT p99 (ms) | 2.89 | 2.92 | -0.02 | -0.7 % |
| server CPU mean (%) | 569.2 | 566.7 | 2.4 | 0.4 % |

Both runs: 0 and 0 disconnects.

#### Sensitivity to the players' input rate: median [min–max] over the 3 suites

Each arm adds that many MoveTo events per player per second to the 1 PlayAction/s. Capacity is the room count with zero disconnects. The input-turn cost #430 asks for isn't in the client's report (the server's turn timings are in the profiler output only), so it isn't tabled.

| rooms | steady phase | MoveTo 0/s | MoveTo 2/s | MoveTo 5/s |
|---|---|---|---|---|
| 100 | MoveTo sent per player per s | 0 [0–0] | 2 [2–2] | 5 [5–5] |
| 100 | server CPU mean (%) | 87.7 [86.0–87.8] | 108.8 [108.8–110.3] | 127.7 [127.6–128.0] |
| 100 | server CPU per room (%) | 0.88 [0.86–0.88] | 1.09 [1.09–1.10] | 1.28 [1.28–1.28] |
| 100 | update bytes per recipient per s | 739.2 [736.8–740.1] | 1502.1 [1501.7–1505.1] | 1711.1 [1708.8–1715.9] |
| 100 | RTT p99 (ms) | 1.97 [1.97–1.98] | 1.96 [1.96–1.99] | 1.97 [1.96–1.97] |
| 100 | disconnects (sum) | 0 | 0 | 0 |
| 300 | MoveTo sent per player per s | 0 [0–0] | 2 [2–2] | 5 [5–5] |
| 300 | server CPU mean (%) | 239.8 [237.8–243.4] | 299.0 [298.9–306.4] | 357.5 [355.4–358.4] |
| 300 | server CPU per room (%) | 0.80 [0.79–0.81] | 1.00 [1.00–1.02] | 1.19 [1.18–1.19] |
| 300 | update bytes per recipient per s | 740.6 [740.4–741.4] | 1504.4 [1502.5–1504.5] | 1714.9 [1712.4–1715.4] |
| 300 | RTT p99 (ms) | 1.98 [1.98–2.07] | 1.98 [1.97–1.98] | 1.98 [1.98–1.98] |
| 300 | disconnects (sum) | 0 | 0 | 0 |
| 500 | MoveTo sent per player per s | 0 [0–0] | 2 [2–2] | 5 [5–5] |
| 500 | server CPU mean (%) | 373.6 [373.4–376.6] | 481.3 [478.0–483.8] | 572.9 [567.5–573.7] |
| 500 | server CPU per room (%) | 0.75 [0.75–0.75] | 0.96 [0.96–0.97] | 1.15 [1.14–1.15] |
| 500 | update bytes per recipient per s | 741.4 [741.4–742.0] | 1505.6 [1504.7–1506.3] | 1714.6 [1713.6–1714.7] |
| 500 | RTT p99 (ms) | 2.00 [1.99–2.00] | 2.57 [2.39–2.85] | 2.98 [2.97–5.89] |
| 500 | disconnects (sum) | 0 | 0 | 0 |

**Host-drift control** (`mr-20261110-control`, suite-1 at 300 rooms at arm 0, run after the arms): server CPU 0.786 % per room, against arm 0's 300-room runs [0.793–0.811]: **outside it: the set is flagged for host drift** (compare the arms' numbers with care). It isn't tabled.

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

### The MoveTo arms (695fe86c)
- **The host-drift control is flagged:** run after the three arms, it read 0.786 % server CPU per room at 300 rooms, against arm 0's three 300-room runs at 0.793–0.811 %, 0.8 % below the band's minimum (the server used less CPU per room, not more), so read the arms' differences against that spread.

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
