# Recomputation cost: sync stream vs re-evaluation record

## Question

How large is the re-evaluation record that reproduces a land's sync stream, compared with the stream itself?
- **A:** the sync stream: every frame the server sends, summed over a room's sessions (A_total), and per session (one client's stream, the lower bound).
- **B:** the record, which re-evaluation turns back into that stream. B_asStored is everything the record holds. B_minimal is inputs only.

Both are measured with the same encoders and the same compressor, per input cadence and per player count. The cost of recording itself (recording on vs off) and how fast a record replays are reported alongside.

## Environment

Not run yet. Every run uses the pinned toolchain (`swift:6.2.4-noble`) on the measurement host, release builds, every process pinned to the server CPUs (`taskset -c 0-7`) with the client CPUs idle. `run.sh` records the git commit, whether the tree was clean and `swift --version` in `raw/<RUN_ID>/run.json`; The Results section opens with the measured commit, dirty flag, Swift version and build, which `regenerate.py` writes from the results' `meta` (`--check` verifies the line). `regenerate.py` refuses results from more than one commit, a debug build, a dirty tree, a Swift version other than 6.2.4 and a smoke sweep.

## Command(s)

```bash
cd deep-research/recomputation-cost
bash run.sh                       # the whole matrix, one sweep (about 45 min on the host)
python3 collect.py                # raw/<RUN_ID>/ -> results/<RUN_ID>/<process>.json
python3 regenerate.py --markdown  # the Results below; regenerate.py writes them, --check compares
python3 test_topic.py             # no build needed
python3 regenerate.py --self-test # the MessagePack encoder and the 3.0 reader
```

`DRY_RUN=1 bash run.sh` prints every command. A smoke run off the host: `CELLS="p2-c5 p10-c5" SIZE_ROOMS=2 COST_ROOMS=4 STEADY=5 RAMP=2 OPEN_REPEAT=5 COST_REPEATS=2 PIN_CPUS= RUN_ID=smoke bash run.sh`; `collect.py` skips such a sweep and `regenerate.py` refuses its values.

`run.sh` runs one ServerLoadTest process per directory under `raw/<RUN_ID>/`, each with 5 s ramp-up, 30 s steady and 5 s ramp-down, and the input cadence as `--actions-per-player-per-second` (cadence 5 ticks: 4 per second; 20 ticks: 1, at 50 ms ticks):

1. **Sizes** (`sizes-<enc>-p<P>-c<C>-r<n>`): recording on with `--record-dir` and `--stream-dir`, 10 rooms, once with messagepack and once with `TRANSPORT_ENCODING=json`, plus a second messagepack repeat at 10 players, cadence 5 (how much sizes move between repeats). For each messagepack process, the first two records are replayed: `ReevaluationRunner --input` (replay time), `--input --verify` (must verify) and `--time-open --repeat 200` (open time).
2. **Recording cost** (`cost-p<P>-c<C>-r<n>-<on|off>`): recording on with `--record-dir` against recording off, neither with `--stream-dir`, 200 rooms, profiling on (`TRANSPORT_PROFILE_JSONL_PATH`). Four repeats in ABBA order: on-off, off-on, off-on, on-off. After each recording-on process, the first record is verified and `regenerate.py --record-check` checks every record (see Gates); the records are then deleted.
3. **Noise floor** (`noise-p10-c5-<a|b>`): two recording-off processes at 10 players, cadence 5, 200 rooms.

The raw sweep directories (records, streams) aren't in this repository; they are archived outside it. `results/<RUN_ID>/<process>.json` holds what the tables need, so `--check` runs without them.

## Method

- **Sizes are computed offline** (`collect.py`, with `regenerate.py`'s functions), from the stored records and the dumped streams. There's one compressor for both sides: gzip at level 9, mtime 0.
- **Records are 3.0 files** (`.sstr`, #245): a header, one length-prefixed canonical MessagePack record per keeper turn, and a footer. `regenerate.py` reads them with a small standard-library MessagePack decoder and rebuilds the 2.x structure the runtime gives the same file as its JSON view (`ReevaluationRunner --convert`): the record metadata, and one frame per tick with the tick's turns merged. The rebuilt value equals that JSON view, so B_asStored keeps its definition (everything the record holds, re-encoded). Only complete records are measured (the room saved them when it closed).
- **B_native** is the 3.0 file as stored, raw and gzipped: the canonical MessagePack of each turn, plus 4 bytes of framing per record, the header and the footer. It differs from B_asStored's MessagePack column by that framing and by the turn structure (a tick written in several turns repeats its tickId).
- **B** is re-encoded from the stored record in two ways: compact JSON with sorted keys, and MessagePack with sorted keys. The MessagePack encoder is a small standard-library one for the JSON subset, and always uses each value's smallest format. Each is reported raw and gzipped.
- **B_minimal** keeps:
  - the record metadata, seed included;
  - for each tick that has an input, its tickId, sequence fields, actions, clientEvents and lifecycleEvents. Resolver outputs are inside those.

  It drops stateHash, serverEvents, syncOutputs and syncMarkers, and ticks without inputs. It is a size bound, not a replayable format.
- **A** is the bytes of the frames each session received, as the server encoded them (no WebSocket framing). A's gzip compresses each session's whole stream as one blob, which is fair against B's whole-file gzip. A live stream is sent frame by frame and can't be compressed that way.
- **Where B's overhead lands:** a second table drops one thing at a time from B_asStored (stateHash only, then only the ticks with no input), next to B_minimal, each over A. At 2 players and a 20-tick cadence most ticks have no input, so this is where a fixed per-tick cost would show.
- **The headline ratio** is B_asStored as MessagePack plus gzip, over A_total as MessagePack plus gzip, per input cadence (5 and 20 ticks) and per player count (2, 5, 10).
- **Replay:** per replayed record, run 1's wall time per recorded tick and as a multiple of realtime, and the open (decode) median of 200 opens. `--verify` must report the state hashes verified.
- **Open cost of a 3.0 record against 2.x JSON** (#245, measured once on the measurement host, release build, `taskset -c 0-7`; `ReevaluationRunner --time-open`, the median of each run's opens, json and 3.0 runs interleaved; the figure is the median over runs). The gate: a 3.0 open no slower than the JSON open of the same recording. At 3ef15c2c it failed on the small input (192 KB JSON, 67.6 KB 3.0: json 3.258 ms, 3.0 3.383 ms, ratio 1.038) and passed on the large one (29.4 MB JSON, 11.0 MB 3.0: 999.4 ms against 800.8 ms, ratio 0.801). The cost was per decoded field: three key lookups per optional field, each copying the key. After the decoder fix (#280, decode side only, no byte change), at 3e1c9bc5: small input json 3.266 ms [3.161–3.330], 3.0 2.658 ms [2.575–2.837], ratio 0.814; large input 1000.5 ms against 725.8 ms, ratio 0.725 (7 runs each; the same input files). No host CPU samples were taken for the second run.
- **Recording cost**, recording on against off at 200 rooms. Neither side dumps the streams. An earlier version of this method ran the "on" side with `--stream-dir` and the "off" side without, so its overhead would have included the stream dump; that was wrong. The "on" side writes its records (`--record-dir`), which is part of recording's cost.
  - ServerLoadTest runs the simulated clients in the same process, so its CPU is the server's and the clients' together. The table gives the difference on − off (CPU points of one core, and core-ms per room-tick), which is the recording's cost, and the paired ratio on ÷ off per repeat (median and [min–max] over the four), which understates it, since its denominator includes the clients.
  - Also on / off, mean over repeats: throughput (actions completed per steady second), the ticker's lag p99 (over the profiling windows), the median of the windows' `encode_ms` and `send_ms` p99, and the sync phase means per full plan (`sync_extract_ms`, `sync_broadcast_ms`, `sync_perplayer_ms`). Tick and sync *duration* p99 aren't sampled (#282); tick lag p99 is.
  - The noise floor: the CPU difference and ratio of two recording-off processes at the heaviest cell, to read the overhead against.
- **Memory is not reported.** The recorder's memory and the replay's and open's peak RSS are out of scope here.

## Gates

`regenerate.py` refuses the results unless:
- every process is a release build from a clean tree with Swift 6.2.4, with the matrix constants (10 rooms for sizes, 200 for cost and noise, 30 s steady, 5 s ramps, 200 opens, 4 cost repeats);
- every process ran in the intended wire form: messagepack with the path index and field merge on (main's defaults since #308), JSON with neither. The form is read from the `stateUpdateFeatures` every join was given (ServerLoadTest records them; joins that disagree fail the run), resolved with `deep-research/wireform.py`: a process that recorded no features counts as "off" only if its commit predates the knob, otherwise it is refused;
- every cell has its messagepack and json sizes processes, two replayed records with `--verify` passed and open timings, and the second sizes repeat exists;
- every cell has on and off in each of the four cost repeats, in the ABBA order (by the processes' start times), and both noise processes exist;
- no cost or noise process was saturated (`lateSeconds` and `skippedByCap` 0) or lacks profiling windows;
- every recording-on cost process passed the record check: as many records as rooms, all complete, nothing left in the spool, every record spanning at least the steady phase's ticks, the records' inputs (client events and actions) adding up to the actions completed, and the first record verified.

Mutation checks (`test_topic.py`): dropping the saturation gate, the order gate or the action count from the record check, a cost run with `--stream-dir`, and a non-ABBA order each fail a test, and so does dropping the wire-form comparison.

## Parameter matrix

| parameter | values |
|---|---|
| players per room | 2, 5, 10 |
| input cadence (ticks between inputs) | 5, 20 |
| encoding | messagepack (main), json (sizes appendix) |
| recording | on (sizes, replay, cost), off (cost) |
| rooms | 10 (sizes), 200 (cost, noise) |
| repeats | sizes 1 (2 at 10 players, cadence 5), cost 4 (ABBA), noise 1 pair |

## Results

Provenance, from the results' meta: commit `ca904c8c0690d62695f9a5a14e24c35ad953466e`, clean tree; Swift 6.2.4; build release.

Wire form (checked per run): messagepack runs: messagepack, pathIndex on, fieldMerge on; json runs: json, pathIndex off, fieldMerge off.

Per room, KiB; A is per room-minute of stream; B covers the same run length. gzip level 9 on both sides. 10 rooms per run.

| enc | players | cadence | repeat | A raw/min | A gz/min | A session min/med/max | B_native / gz | B_asStored msgpack / gz | B_asStored json / gz | B_minimal msgpack / gz | B_minimal json / gz | B_asStored msgpack gz ÷ A gz |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| json | 2 | 5 | 1 | 509.1 | 54.6 | 150.9/168.0/198.8 | 178.8 / 29.4 | 205.0 / 29.0 | 253.8 / 27.4 | 59.0 / 4.5 | 75.4 / 4.7 | 0.795 |
| json | 2 | 20 | 1 | 508.3 | 54.4 | 151.5/168.7/187.4 | 147.8 / 26.1 | 176.0 / 25.8 | 216.3 / 25.2 | 16.7 / 2.0 | 21.3 / 2.0 | 0.712 |
| json | 5 | 5 | 1 | 1409.2 | 148.8 | 159.5/188.4/210.6 | 241.3 / 34.1 | 265.1 / 33.6 | 329.9 / 31.5 | 134.2 / 9.0 | 171.0 / 8.9 | 0.339 |
| json | 5 | 20 | 1 | 1398.8 | 148.2 | 164.2/186.6/214.4 | 165.6 / 28.8 | 192.6 / 28.5 | 238.0 / 27.1 | 40.4 / 4.0 | 51.6 / 4.0 | 0.288 |
| json | 10 | 5 | 1 | 3351.4 | 343.9 | 192.6/225.0/256.3 | 341.4 / 40.7 | 362.4 / 40.2 | 456.1 / 36.8 | 251.4 / 15.5 | 321.3 / 14.4 | 0.175 |
| json | 10 | 20 | 1 | 3346.1 | 345.2 | 190.6/224.6/249.5 | 194.9 / 32.3 | 220.2 / 31.9 | 272.9 / 30.1 | 77.7 / 7.1 | 99.0 / 6.9 | 0.139 |
| messagepack | 2 | 5 | 1 | 68.9 | 33.5 | 20.7/22.2/26.7 | 188.5 / 25.4 | 214.7 / 25.1 | 264.8 / 23.5 | 59.0 / 4.5 | 75.4 / 4.7 | 1.121 |
| messagepack | 2 | 20 | 1 | 69.0 | 33.6 | 20.5/22.8/27.3 | 157.4 / 22.1 | 185.6 / 21.9 | 227.3 / 21.5 | 16.8 / 2.1 | 21.3 / 2.0 | 0.977 |
| messagepack | 5 | 5 | 1 | 192.2 | 92.0 | 22.6/25.4/29.6 | 250.9 / 30.1 | 274.8 / 29.7 | 341.1 / 27.6 | 133.9 / 8.9 | 170.7 / 8.8 | 0.485 |
| messagepack | 5 | 20 | 1 | 191.5 | 91.9 | 23.1/25.2/29.2 | 175.7 / 24.8 | 202.7 / 24.5 | 249.6 / 23.2 | 40.4 / 4.0 | 51.6 / 4.0 | 0.401 |
| messagepack | 10 | 5 | 1 | 461.4 | 215.7 | 25.9/31.3/33.5 | 351.4 / 36.7 | 372.4 / 36.2 | 467.5 / 32.9 | 251.5 / 15.4 | 321.5 / 14.4 | 0.252 |
| messagepack | 10 | 5 | 2 | 460.4 | 215.2 | 27.1/31.3/32.7 | 351.2 / 36.7 | 372.2 / 36.2 | 467.3 / 32.9 | 251.5 / 15.4 | 321.4 / 14.4 | 0.252 |
| messagepack | 10 | 20 | 1 | 460.0 | 216.0 | 27.8/30.6/34.0 | 204.8 / 28.3 | 230.2 / 28.0 | 284.3 / 26.3 | 77.7 / 7.1 | 99.0 / 6.9 | 0.194 |

The A gzip column compresses each session's whole stream as one blob; a live stream is sent frame by frame and can't be compressed that way.

Where B's overhead lands (MessagePack plus gzip, KiB per room, each over A gz). Each middle column drops one thing from B_asStored; B_minimal drops both, plus serverEvents, syncOutputs and syncMarkers.

| enc | players | cadence | repeat | ticks / with input | B_asStored | no stateHash | no input-free ticks | B_minimal |
|---|---|---|---|---|---|---|---|---|
| json | 2 | 5 | 1 | 754 / 208 | 29.0 (0.795) | 20.5 (0.562) | 11.7 (0.320) | 4.5 (0.123) |
| json | 2 | 20 | 1 | 754 / 64 | 25.8 (0.712) | 17.0 (0.468) | 4.0 (0.111) | 2.0 (0.056) |
| json | 5 | 5 | 1 | 754 / 379 | 33.6 (0.339) | 25.1 (0.253) | 21.9 (0.221) | 9.0 (0.090) |
| json | 5 | 20 | 1 | 754 / 150 | 28.5 (0.288) | 19.8 (0.201) | 9.2 (0.093) | 4.0 (0.041) |
| json | 10 | 5 | 1 | 754 / 585 | 40.2 (0.175) | 31.3 (0.136) | 35.5 (0.155) | 15.5 (0.067) |
| json | 10 | 20 | 1 | 754 / 266 | 31.9 (0.139) | 23.3 (0.101) | 15.9 (0.069) | 7.1 (0.031) |
| messagepack | 2 | 5 | 1 | 754 / 208 | 25.1 (1.121) | 16.4 (0.736) | 10.5 (0.469) | 4.5 (0.201) |
| messagepack | 2 | 20 | 1 | 754 / 64 | 21.9 (0.977) | 12.9 (0.578) | 3.9 (0.174) | 2.1 (0.092) |
| messagepack | 5 | 5 | 1 | 754 / 376 | 29.7 (0.485) | 21.0 (0.342) | 19.6 (0.319) | 8.9 (0.146) |
| messagepack | 5 | 20 | 1 | 754 / 149 | 24.5 (0.401) | 15.8 (0.258) | 8.5 (0.138) | 4.0 (0.066) |
| messagepack | 10 | 5 | 1 | 754 / 586 | 36.2 (0.252) | 27.0 (0.188) | 32.1 (0.223) | 15.4 (0.107) |
| messagepack | 10 | 5 | 2 | 754 / 586 | 36.2 (0.252) | 27.0 (0.188) | 32.1 (0.224) | 15.4 (0.108) |
| messagepack | 10 | 20 | 1 | 754 / 266 | 28.0 (0.194) | 19.3 (0.134) | 14.4 (0.100) | 7.1 (0.049) |

Replay, per replayed record (the first two of each messagepack sizes run): run 1's wall time, and the open (decode) median of 200 opens. `--verify` passed on every one.

| players | cadence | record | ticks | replay ms | µs / tick | × realtime | open median ms |
|---|---|---|---|---|---|---|---|
| 2 | 5 | hero-defense-2026-11-08T10-27-30Z-25FE8D99 | 789 | 170.7 | 216.3 | 231 | 8.410 |
| 2 | 5 | hero-defense-2026-11-08T10-27-30Z-5766C33B | 729 | 149.5 | 205.1 | 244 | 7.128 |
| 2 | 20 | hero-defense-2026-11-08T10-28-17Z-19D61894 | 719 | 151.7 | 211.0 | 237 | 5.264 |
| 2 | 20 | hero-defense-2026-11-08T10-28-17Z-2E832DB4 | 729 | 148.4 | 203.6 | 246 | 5.286 |
| 5 | 5 | hero-defense-2026-11-08T10-29-02Z-0541DBF9 | 729 | 248.7 | 341.2 | 147 | 12.150 |
| 5 | 5 | hero-defense-2026-11-08T10-29-02Z-29DB26D8 | 779 | 258.0 | 331.3 | 151 | 12.028 |
| 5 | 20 | hero-defense-2026-11-08T10-29-52Z-067DF3AC | 769 | 235.1 | 305.7 | 164 | 6.987 |
| 5 | 20 | hero-defense-2026-11-08T10-29-52Z-5EF1AC4E | 799 | 243.7 | 305.0 | 164 | 6.985 |
| 10 | 5 | hero-defense-2026-11-08T10-30-39Z-067C5B03 | 779 | 480.0 | 616.2 | 81 | 19.131 |
| 10 | 5 | hero-defense-2026-11-08T10-30-39Z-4B0312FB | 759 | 464.4 | 611.8 | 82 | 19.506 |
| 10 | 20 | hero-defense-2026-11-08T10-31-33Z-125E60F0 | 779 | 435.2 | 558.6 | 90 | 8.504 |
| 10 | 20 | hero-defense-2026-11-08T10-31-33Z-4CCF0EF8 | 789 | 473.5 | 600.1 | 83 | 9.211 |

Recording cost, 200 rooms, recording on against off, 4 repeats in ABBA order (on-off, off-on, off-on, on-off). ServerLoadTest runs the simulated clients in the same process, so CPU is the server's and the clients' together: the on − off difference is the recording's cost, and the on ÷ off ratio understates it (its denominator includes the clients). CPU % is of one core; core-ms per room-tick is CPU over rooms × ticks. The paired ratio is each repeat's on ÷ off, its median and [min–max] over the repeats.

| players | cadence | actions/s on / off | CPU % on / off | on − off, CPU points | on − off, core-ms / room-tick | CPU on ÷ off, median [min–max] |
|---|---|---|---|---|---|---|
| 2 | 5 | 1599.5 / 1599.5 | 208.0 / 113.2 | +94.9 | +0.2371 | 1.837 [1.830–1.850] |
| 2 | 20 | 399.9 / 399.9 | 188.7 / 91.6 | +97.0 | +0.2426 | 2.051 [2.038–2.096] |
| 5 | 5 | 3998.7 / 3998.7 | 271.0 / 162.8 | +108.2 | +0.2704 | 1.663 [1.650–1.683] |
| 5 | 20 | 999.7 / 999.7 | 228.6 / 117.9 | +110.7 | +0.2768 | 1.938 [1.929–1.950] |
| 10 | 5 | 7997.3 / 7997.3 | 379.0 / 226.1 | +153.0 | +0.3825 | 1.674 [1.659–1.700] |
| 10 | 20 | 1999.3 / 1999.3 | 294.4 / 155.9 | +138.4 | +0.3461 | 1.888 [1.868–1.906] |

The sync and send figures, mean over the repeats, on / off (tick lag: the ticker's lag p99 over the profiling windows; encode and send: the median of the windows' p99; the sync phases: means per full sync plan).

| players | cadence | tick lag p99 ms | encode p99 ms | send p99 ms | extract mean ms | broadcast mean ms | per-player mean ms |
|---|---|---|---|---|---|---|---|
| 2 | 5 | 4.76 / 0.92 | 0.24 / 0.21 | 0.04 / 0.04 | 0.053 / 0.054 | 0.033 / 0.032 | 0.001 / 0.001 |
| 2 | 20 | 4.63 / 0.75 | 0.26 / 0.23 | 0.04 / 0.04 | 0.053 / 0.052 | 0.033 / 0.032 | 0.001 / 0.001 |
| 5 | 5 | 3.86 / 0.70 | 0.29 / 0.24 | 0.06 / 0.08 | 0.064 / 0.066 | 0.039 / 0.040 | 0.001 / 0.001 |
| 5 | 20 | 5.19 / 1.01 | 0.28 / 0.24 | 0.07 / 0.08 | 0.064 / 0.065 | 0.040 / 0.040 | 0.001 / 0.001 |
| 10 | 5 | 3.74 / 0.70 | 0.34 / 0.28 | 0.10 / 0.11 | 0.084 / 0.083 | 0.052 / 0.050 | 0.001 / 0.001 |
| 10 | 20 | 4.69 / 0.69 | 0.34 / 0.29 | 0.10 / 0.13 | 0.082 / 0.084 | 0.052 / 0.054 | 0.001 / 0.001 |

Noise floor: two recording-off processes at 10 players, cadence 5: CPU 226.3 % and 224.9 %, ratio 0.994, difference -1.4 points.

<!-- results end -->

## Caveats

- B_minimal is not a format the runtime reads; it bounds what an input-only record could weigh.
- A counts encoded frames handed to the in-process transport, not bytes on a socket (no WebSocket or TCP framing).
