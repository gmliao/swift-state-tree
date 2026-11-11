# Recomputation cost: sync stream vs re-evaluation record

## Question

How large is the re-evaluation record that reproduces a land's sync stream, compared with the stream itself?
- **A:** the sync stream: every frame the server sends, summed over a room's sessions (A_total), and per session (one client's stream, the lower bound).
- **B:** the record, which re-evaluation turns back into that stream. B_asStored is everything the record holds. B_minimal is inputs only.

Both are measured with the same encoders and the same compressor, per input cadence and per player count. The cost of recording itself (recording on vs off) and how fast a record replays are reported alongside.

## Environment

Measured at `75222b87` (the Results' provenance line). Every run uses the pinned toolchain (`swift:6.2.4-noble`) on the measurement host, release builds, every process pinned to the server CPUs (`taskset -c 0-7`) with the client CPUs idle. `run.sh` records the git commit, whether the tree was clean and `swift --version` in `raw/<RUN_ID>/run.json`; The Results section opens with the measured commit, dirty flag, Swift version and build, which `regenerate.py` writes from the results' `meta` (`--check` verifies the line). `regenerate.py` refuses results from more than one commit, a debug build, a dirty tree, a Swift version other than 6.2.4 and a smoke sweep.

## Command(s)

```bash
cd deep-research/recomputation-cost
bash run.sh                       # the whole matrix, one sweep (about 45 min on the host)
python3 collect.py                # raw/<RUN_ID>/ -> results/<RUN_ID>/<process>.json
python3 regenerate.py --markdown  # the Results below; regenerate.py writes them, --check compares
python3 test_topic.py             # no build needed
python3 regenerate.py --self-test # the MessagePack encoder and the 3.x reader
```

`DRY_RUN=1 bash run.sh` prints every command. A smoke run off the host: `CELLS="p2-c5 p10-c5" SIZE_ROOMS=2 COST_ROOMS=4 STEADY=5 RAMP=2 OPEN_REPEAT=5 COST_REPEATS=2 PIN_CPUS= RUN_ID=smoke bash run.sh`; `collect.py` skips such a sweep and `regenerate.py` refuses its values.

`run.sh` runs one ServerLoadTest process per directory under `raw/<RUN_ID>/`, each with 5 s ramp-up, 30 s steady and 5 s ramp-down, and the input cadence as `--actions-per-player-per-second` (cadence 5 ticks: 4 per second; 20 ticks: 1, at 50 ms ticks):

1. **Sizes** (`sizes-<enc>-p<P>-c<C>-r<n>`): recording on with `--record-dir` and `--stream-dir`, 10 rooms, once with messagepack and once with `TRANSPORT_ENCODING=json`, plus a second messagepack repeat at 10 players, cadence 5 (how much sizes move between repeats). For each messagepack process, the first two records are replayed: `ReevaluationRunner --input` (replay time), `--input --verify` (must verify) and `--time-open --repeat 200` (open time).
2. **Recording cost** (`cost-p<P>-c<C>-r<n>-<on|off>`): recording on with `--record-dir` against recording off, neither with `--stream-dir`, 200 rooms, profiling on (`TRANSPORT_PROFILE_JSONL_PATH`). Four repeats in ABBA order: on-off, off-on, off-on, on-off. After each recording-on process, the first record is verified and `regenerate.py --record-check` checks every record (see Gates); the records are then deleted.
3. **Noise floor** (`noise-p10-c5-<a|b>`): two recording-off processes at 10 players, cadence 5, 200 rooms.

The raw sweep directories (records, streams) aren't in this repository; they are archived outside it. `results/<RUN_ID>/<process>.json` holds what the tables need, so `--check` runs without them.

## Method

- **Sizes are computed offline** (`collect.py`, with `regenerate.py`'s functions), from the stored records and the dumped streams. There's one compressor for both sides: gzip at level 9, mtime 0.
- **Records are 3.x files** (`.sstr`, #245; 3.1 since #325, which adds a tickless land's `passes`, absent on this tick land): a header, one length-prefixed canonical MessagePack record per keeper turn, and a footer. `regenerate.py` reads them with a small standard-library MessagePack decoder and rebuilds the 2.x structure the runtime gives the same file as its JSON view (`ReevaluationRunner --convert`): the record metadata, and one frame per tick with the tick's turns merged. The rebuilt value equals that JSON view, so B_asStored keeps its definition (everything the record holds, re-encoded). Only complete records are measured (the room saved them when it closed).
- **B_native** is the 3.x file as stored, raw and gzipped: the canonical MessagePack of each turn, plus 4 bytes of framing per record, the header and the footer. It differs from B_asStored's MessagePack column by that framing and by the turn structure (a tick written in several turns repeats its tickId).
- **B** is re-encoded from the stored record in two ways: compact JSON with sorted keys, and MessagePack with sorted keys. The MessagePack encoder is a small standard-library one for the JSON subset, and always uses each value's smallest format. Each is reported raw and gzipped.
- **B_minimal** keeps:
  - the record metadata, seed included;
  - for each tick that has an input, its tickId, sequence fields, actions, clientEvents and lifecycleEvents. Resolver outputs are inside those.

  It drops stateHash, serverEvents, syncOutputs and syncMarkers, and ticks without inputs. It is a size bound, not a replayable format.
- **A** is the bytes of the frames each session received, as the server encoded them (no WebSocket framing). A's gzip compresses each session's whole stream as one blob, which is fair against B's whole-file gzip. A live stream is sent frame by frame and can't be compressed that way.
- **Where B's overhead lands:** a second table drops one thing at a time from B_asStored (stateHash only, then only the ticks with no input), next to B_minimal, each over A. At 2 players and a 20-tick cadence most ticks have no input, so this is where a fixed per-tick cost would show.
- **The headline ratio** is B_asStored as MessagePack plus gzip, over A_total as MessagePack plus gzip, per input cadence (5 and 20 ticks) and per player count (2, 5, 10).
- **Replay:** per replayed record, run 1's wall time per recorded tick and as a multiple of realtime, and the open (decode) median of 200 opens. `--verify` must report the state hashes verified.
- **Open cost of a 3.x record (3.0 at the time) against 2.x JSON** (#245, measured once on the measurement host, release build, `taskset -c 0-7`; `ReevaluationRunner --time-open`, the median of each run's opens, json and 3.0 runs interleaved; the figure is the median over runs). The gate: a 3.0 open no slower than the JSON open of the same recording. At 3ef15c2c it failed on the small input (192 KB JSON, 67.6 KB 3.0: json 3.258 ms, 3.0 3.383 ms, ratio 1.038) and passed on the large one (29.4 MB JSON, 11.0 MB 3.0: 999.4 ms against 800.8 ms, ratio 0.801). The cost was per decoded field: three key lookups per optional field, each copying the key. After the decoder fix (#280, decode side only, no byte change), at 3e1c9bc5: small input json 3.266 ms [3.161–3.330], 3.0 2.658 ms [2.575–2.837], ratio 0.814; large input 1000.5 ms against 725.8 ms, ratio 0.725 (7 runs each; the same input files). No host CPU samples were taken for the second run.
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

Provenance, from the results' meta: commit `75222b87eb008b1ad94e99d7ae96b83528c9d0a4`, clean tree; Swift 6.2.4; build release.

Wire form (checked per run): messagepack runs: messagepack, pathIndex on, fieldMerge on; json runs: json, pathIndex off, fieldMerge off.

Per room, KiB; A is per room-minute of stream; B covers the same run length. gzip level 9 on both sides. 10 rooms per run.

| enc | players | cadence | repeat | A raw/min | A gz/min | A session min/med/max | B_native / gz | B_asStored msgpack / gz | B_asStored json / gz | B_minimal msgpack / gz | B_minimal json / gz | B_asStored msgpack gz ÷ A gz |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| json | 2 | 5 | 1 | 518.2 | 58.3 | 157.9/166.2/198.2 | 178.3 / 29.4 | 204.8 / 29.0 | 253.5 / 27.4 | 59.0 / 4.5 | 75.4 / 4.7 | 0.746 |
| json | 2 | 20 | 1 | 518.3 | 58.2 | 150.0/171.7/192.2 | 147.4 / 26.0 | 175.8 / 25.9 | 216.2 / 25.2 | 16.8 / 2.1 | 21.4 / 2.0 | 0.666 |
| json | 5 | 5 | 1 | 1440.7 | 158.9 | 167.7/191.4/223.0 | 241.0 / 34.1 | 265.1 / 33.6 | 330.0 / 31.5 | 134.1 / 9.0 | 170.9 / 8.9 | 0.318 |
| json | 5 | 20 | 1 | 1423.8 | 157.8 | 167.5/189.8/213.5 | 165.4 / 28.7 | 192.6 / 28.5 | 238.1 / 27.1 | 40.6 / 4.1 | 51.8 / 4.1 | 0.271 |
| json | 10 | 5 | 1 | 3398.3 | 362.7 | 200.1/230.2/245.1 | 341.8 / 40.6 | 363.0 / 40.2 | 456.8 / 36.9 | 251.7 / 15.5 | 321.7 / 14.4 | 0.166 |
| json | 10 | 20 | 1 | 3391.6 | 364.5 | 193.6/223.5/249.4 | 194.7 / 32.2 | 220.3 / 31.9 | 272.9 / 30.2 | 78.1 / 7.1 | 99.5 / 7.0 | 0.131 |
| messagepack | 2 | 5 | 1 | 70.8 | 35.4 | 21.5/24.0/26.3 | 188.2 / 25.4 | 214.7 / 25.1 | 264.8 / 23.5 | 59.0 / 4.5 | 75.4 / 4.7 | 1.064 |
| messagepack | 2 | 20 | 1 | 70.8 | 35.3 | 21.1/23.8/25.7 | 157.3 / 22.1 | 185.6 / 21.9 | 227.4 / 21.5 | 16.8 / 2.1 | 21.4 / 2.0 | 0.930 |
| messagepack | 5 | 5 | 1 | 197.4 | 96.7 | 23.1/26.8/29.3 | 250.8 / 30.1 | 275.0 / 29.8 | 341.2 / 27.7 | 134.0 / 8.9 | 170.8 / 8.9 | 0.462 |
| messagepack | 5 | 20 | 1 | 195.7 | 96.0 | 22.5/26.7/29.4 | 175.2 / 24.8 | 202.3 / 24.6 | 249.3 / 23.2 | 40.7 / 4.1 | 51.9 / 4.1 | 0.384 |
| messagepack | 10 | 5 | 1 | 471.2 | 224.7 | 29.1/31.4/34.3 | 351.4 / 36.6 | 372.7 / 36.2 | 467.8 / 32.9 | 251.8 / 15.5 | 321.7 / 14.4 | 0.242 |
| messagepack | 10 | 5 | 2 | 472.3 | 225.3 | 29.5/30.6/34.3 | 351.4 / 36.6 | 372.7 / 36.2 | 467.8 / 32.9 | 251.9 / 15.5 | 321.9 / 14.4 | 0.241 |
| messagepack | 10 | 20 | 1 | 470.0 | 225.0 | 26.2/32.1/34.7 | 204.6 / 28.2 | 230.2 / 28.0 | 284.3 / 26.3 | 78.0 / 7.1 | 99.3 / 6.9 | 0.186 |

The A gzip column compresses each session's whole stream as one blob; a live stream is sent frame by frame and can't be compressed that way.

Where B's overhead lands (MessagePack plus gzip, KiB per room, each over A gz). Each middle column drops one thing from B_asStored; B_minimal drops both, plus serverEvents, syncOutputs and syncMarkers.

| enc | players | cadence | repeat | ticks / with input | B_asStored | no stateHash | no input-free ticks | B_minimal |
|---|---|---|---|---|---|---|---|---|
| json | 2 | 5 | 1 | 754 / 207 | 29.0 (0.746) | 20.5 (0.528) | 11.7 (0.300) | 4.5 (0.116) |
| json | 2 | 20 | 1 | 754 / 64 | 25.9 (0.666) | 17.0 (0.439) | 4.0 (0.104) | 2.1 (0.053) |
| json | 5 | 5 | 1 | 754 / 377 | 33.6 (0.318) | 25.1 (0.237) | 21.8 (0.206) | 9.0 (0.085) |
| json | 5 | 20 | 1 | 754 / 150 | 28.5 (0.271) | 19.8 (0.189) | 9.3 (0.088) | 4.1 (0.039) |
| json | 10 | 5 | 1 | 754 / 585 | 40.2 (0.166) | 31.3 (0.129) | 35.5 (0.147) | 15.5 (0.064) |
| json | 10 | 20 | 1 | 754 / 267 | 31.9 (0.131) | 23.3 (0.096) | 15.9 (0.066) | 7.1 (0.029) |
| messagepack | 2 | 5 | 1 | 754 / 207 | 25.1 (1.064) | 16.5 (0.698) | 10.5 (0.445) | 4.5 (0.191) |
| messagepack | 2 | 20 | 1 | 754 / 64 | 21.9 (0.930) | 13.0 (0.550) | 3.9 (0.165) | 2.1 (0.087) |
| messagepack | 5 | 5 | 1 | 754 / 376 | 29.8 (0.462) | 21.0 (0.326) | 19.6 (0.304) | 8.9 (0.139) |
| messagepack | 5 | 20 | 1 | 754 / 150 | 24.6 (0.384) | 15.8 (0.247) | 8.4 (0.132) | 4.1 (0.064) |
| messagepack | 10 | 5 | 1 | 754 / 586 | 36.2 (0.242) | 27.0 (0.180) | 32.1 (0.214) | 15.5 (0.103) |
| messagepack | 10 | 5 | 2 | 754 / 587 | 36.2 (0.241) | 27.0 (0.180) | 32.2 (0.214) | 15.5 (0.103) |
| messagepack | 10 | 20 | 1 | 754 / 266 | 28.0 (0.186) | 19.3 (0.128) | 14.4 (0.096) | 7.1 (0.047) |

Replay, per replayed record (the first two of each messagepack sizes run): run 1's wall time, and the open (decode) median of 200 opens. `--verify` passed on every one.

| players | cadence | record | ticks | replay ms | µs / tick | × realtime | open median ms |
|---|---|---|---|---|---|---|---|
| 2 | 5 | hero-defense-2026-11-09T11-08-13Z-1CD85A01 | 749 | 152.7 | 203.9 | 245 | 7.511 |
| 2 | 5 | hero-defense-2026-11-09T11-08-13Z-307670BE | 719 | 161.4 | 224.5 | 223 | 7.764 |
| 2 | 20 | hero-defense-2026-11-09T11-09-00Z-0CBE355B | 789 | 158.0 | 200.3 | 250 | 5.636 |
| 2 | 20 | hero-defense-2026-11-09T11-09-00Z-28ADAA3C | 759 | 153.9 | 202.7 | 247 | 5.225 |
| 5 | 5 | hero-defense-2026-11-09T11-09-45Z-02209B45 | 749 | 238.2 | 318.1 | 157 | 11.219 |
| 5 | 5 | hero-defense-2026-11-09T11-09-45Z-041B9BA1 | 769 | 238.2 | 309.8 | 161 | 12.014 |
| 5 | 20 | hero-defense-2026-11-09T11-10-35Z-0309C479 | 759 | 261.2 | 344.1 | 145 | 6.822 |
| 5 | 20 | hero-defense-2026-11-09T11-10-35Z-2DCE97A5 | 739 | 218.9 | 296.3 | 169 | 6.430 |
| 10 | 5 | hero-defense-2026-11-09T11-11-22Z-0C6EF62D | 759 | 481.7 | 634.6 | 79 | 19.998 |
| 10 | 5 | hero-defense-2026-11-09T11-11-22Z-24E7171B | 739 | 482.9 | 653.5 | 77 | 20.020 |
| 10 | 20 | hero-defense-2026-11-09T11-12-16Z-1C1F7241 | 719 | 378.6 | 526.6 | 95 | 8.219 |
| 10 | 20 | hero-defense-2026-11-09T11-12-16Z-35FB1029 | 789 | 445.2 | 564.2 | 89 | 8.818 |

Recording cost, 200 rooms, recording on against off, 4 repeats in ABBA order (on-off, off-on, off-on, on-off). ServerLoadTest runs the simulated clients in the same process, so CPU is the server's and the clients' together: the on − off difference is the recording's cost, and the on ÷ off ratio understates it (its denominator includes the clients). CPU % is of one core; core-ms per room-tick is CPU over rooms × ticks. The paired ratio is each repeat's on ÷ off, its median and [min–max] over the repeats.

| players | cadence | actions/s on / off | CPU % on / off | on − off, CPU points | on − off, core-ms / room-tick | CPU on ÷ off, median [min–max] |
|---|---|---|---|---|---|---|
| 2 | 5 | 1599.5 / 1599.5 | 215.3 / 120.9 | +94.4 | +0.2361 | 1.782 [1.763–1.796] |
| 2 | 20 | 399.9 / 399.9 | 195.3 / 99.1 | +96.2 | +0.2405 | 1.972 [1.959–1.977] |
| 5 | 5 | 3998.7 / 3998.7 | 281.3 / 171.0 | +110.3 | +0.2758 | 1.645 [1.638–1.652] |
| 5 | 20 | 999.7 / 999.7 | 236.1 / 126.1 | +110.0 | +0.2751 | 1.874 [1.856–1.887] |
| 10 | 5 | 7997.3 / 7997.3 | 391.3 / 240.5 | +150.7 | +0.3769 | 1.640 [1.576–1.654] |
| 10 | 20 | 1999.3 / 1999.3 | 305.7 / 165.3 | +140.4 | +0.3509 | 1.844 [1.841–1.867] |

The sync and send figures, mean over the repeats, on / off (tick lag: the ticker's lag p99 over the profiling windows; encode and send: the median of the windows' p99; the sync phases: means per full sync plan).

| players | cadence | tick lag p99 ms | encode p99 ms | send p99 ms | extract mean ms | broadcast mean ms | per-player mean ms |
|---|---|---|---|---|---|---|---|
| 2 | 5 | 3.93 / 0.79 | 0.25 / 0.22 | 0.04 / 0.04 | 0.054 / 0.055 | 0.033 / 0.033 | 0.001 / 0.001 |
| 2 | 20 | 3.93 / 0.79 | 0.27 / 0.23 | 0.03 / 0.04 | 0.054 / 0.054 | 0.034 / 0.033 | 0.001 / 0.001 |
| 5 | 5 | 3.28 / 0.79 | 0.30 / 0.26 | 0.06 / 0.07 | 0.065 / 0.067 | 0.040 / 0.040 | 0.001 / 0.001 |
| 5 | 20 | 4.11 / 0.82 | 0.29 / 0.26 | 0.06 / 0.07 | 0.065 / 0.067 | 0.040 / 0.041 | 0.001 / 0.001 |
| 10 | 5 | 2.83 / 2.02 | 0.35 / 0.30 | 0.10 / 0.11 | 0.086 / 0.086 | 0.053 / 0.052 | 0.001 / 0.001 |
| 10 | 20 | 3.62 / 0.79 | 0.35 / 0.30 | 0.11 / 0.13 | 0.083 / 0.087 | 0.054 / 0.054 | 0.001 / 0.001 |

Noise floor: two recording-off processes at 10 players, cadence 5: CPU 236.5 % and 243.2 %, ratio 1.028, difference +6.7 points.

<!-- results end -->

## Caveats

- B_minimal is not a format the runtime reads; it bounds what an input-only record could weigh.
- A counts encoded frames handed to the in-process transport, not bytes on a socket (no WebSocket or TCP framing).
