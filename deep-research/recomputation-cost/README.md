# Recomputation cost: sync stream vs re-evaluation record

## Question

How large is the re-evaluation record that reproduces a land's sync stream, compared with the stream itself?
- **A:** the sync stream: every frame the server sends, summed over a room's sessions (A_total), and per session (one client's stream, the lower bound).
- **B:** the record, which re-evaluation turns back into that stream. B_asStored is everything the record holds. B_minimal is inputs only.

Both are measured with the same encoders and the same compressor, per input cadence and per player count. The cost of recording itself (recording on vs off) and how fast a record replays are reported alongside.

## Environment

Not run yet. Every run uses the pinned toolchain (`swift:6.2.4-noble`) on the measurement host, release builds, every process pinned to the server CPUs (`taskset -c 0-7`) with the client CPUs idle. `run.sh` records the git commit, whether the tree was clean and `swift --version` in `raw/<RUN_ID>/run.json`; `regenerate.py` refuses a debug build, a dirty tree, a Swift version other than 6.2.4 and a smoke sweep.

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

No runs yet.

<!-- results end -->

## Caveats

- B_minimal is not a format the runtime reads; it bounds what an input-only record could weigh.
- A counts encoded frames handed to the in-process transport, not bytes on a socket (no WebSocket or TCP framing).
