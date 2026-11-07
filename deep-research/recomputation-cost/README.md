# Recomputation cost: sync stream vs re-evaluation record

## Question

How large is the re-evaluation record that reproduces a land's sync stream, compared with the stream itself?
- **A:** the sync stream: every frame the server sends, summed over a room's sessions (A_total), and per session (one client's stream, the lower bound).
- **B:** the record, which re-evaluation turns back into that stream. B_asStored is everything the record holds. B_minimal is inputs only.

Both are measured with the same encoders and the same compressor, per input cadence and per player count. The cost of recording itself (recording on vs off) and how fast a record replays are reported alongside.

## Environment

Not run yet. Performance runs use the pinned toolchain (`swift:6.2.4-noble`) on the perf baseline machine. Each result file records `swift --version`, the encoding, and whether recording was on.

- Every tool runs as one process, pinned to the server CPUs (`taskset -c 0-7`), with the client CPUs idle.
- Replay memory is the peak resident set of the `ReevaluationRunner` process, from GNU time 1.9 (`/usr/bin/time -v`, "Maximum resident set size").

## Command(s)

```bash
cd Examples/GameDemo
# One run: recording on, records and per-session streams kept. Each room streams its 3.0
# record to $RUN/records/spool while it runs and saves it as $RUN/records/*.sstr when it
# closes. Input cadence in ticks is 20 / actions-per-player-per-second (50 ms ticks):
# 4 → 5 ticks, 1 → 20 ticks. The profiling lines give the recording cost's latency figures.
TRANSPORT_PROFILE_JSONL_PATH=$RUN/profile.jsonl taskset -c 0-7 .build/release/ServerLoadTest \
  --rooms <n> --players-per-room <2|5|10> --actions-per-player-per-second <4|1> \
  --record on --record-dir $RUN/records --stream-dir $RUN/streams
# Recording cost: the same run with --record off and no directories (profiling still on).
# The JSON-to-JSON appendix: the same run with TRANSPORT_ENCODING=json.
# Flat RSS: one run with recording on, --duration-seconds 600 and no --stream-dir.
# Copy ServerLoadTest's result file to $RUN/loadtest.json.

# Replay, per replayed record <name>: replay speed (REPLAY_TIMING: wall ms, ticks/s, multiple of
# realtime), verification, the open (decode) time, and the peak RSS of a replay and of an open alone.
/usr/bin/time -v taskset -c 0-7 .build/release/ReevaluationRunner --input <record>.sstr          > $RUN/replay-<name>.txt 2>&1
/usr/bin/time -v taskset -c 0-7 .build/release/ReevaluationRunner --input <record>.sstr --verify > $RUN/verify-<name>.txt 2>&1
/usr/bin/time -v taskset -c 0-7 .build/release/ReevaluationRunner --time-open <record>.sstr --repeat 1 > $RUN/open1-<name>.txt 2>&1
taskset -c 0-7 .build/release/ReevaluationRunner --time-open <record>.sstr --repeat 200 > $RUN/open-<name>.json 2>&1
```

Then summarize each run and render the tables:

```bash
python3 regenerate.py --summarize $RUN   # writes results/<run>/summary.json from the raw run directory
python3 regenerate.py                    # renders the Results below from results/*/summary.json
```

The raw run directories (records, streams) aren't in this repository: each is archived as `<run>.tar.gz`, listed in `MANIFEST` with its sha256 and size. `results/<run>/` holds the summary and the run's text outputs (`loadtest.json`, the replay, verify and open files, `profile.jsonl`). Anyone with an archive can unpack it, rerun `--summarize` and compare the summary.

`python3 regenerate.py --self-test` checks the MessagePack encoder and decoder against known vectors, the 3.0 reader and the helpers, and runs `--summarize` on a synthetic recording-on/off pair and a long run, then checks that the tables render and `--check` passes from the summaries alone, with the raw files deleted. `--check` fails if the Results below differ from `results/*/summary.json`.

## Method

- **Sizes are computed offline** in `regenerate.py`, from the stored records and the dumped streams. There's one compressor for both sides: gzip at level 9, mtime 0.
- **Records are 3.0 files** (`.sstr`, #245): a header, one length-prefixed canonical MessagePack record per keeper turn, and a footer. `regenerate.py` reads them with a small standard-library MessagePack decoder and rebuilds the 2.x structure the runtime gives the same file as its JSON view (`ReevaluationRunner --convert`): the record metadata, and one frame per tick with the tick's turns merged. The rebuilt value equals that JSON view, so B_asStored keeps its definition (everything the record holds, re-encoded), and 2.x JSON records are still read as they are. Only complete records are measured (the room saved them when it closed).
- **B_native** is the 3.0 file as stored, raw and gzipped: the canonical MessagePack of each turn, plus 4 bytes of framing per record, the header and the footer. It differs from B_asStored's MessagePack column by that framing and by the turn structure (a tick written in several turns repeats its tickId).
- **Peak RSS:** earlier records were held in memory and written at the end of the run, so a run's peak RSS included them (#245). A 3.0 run streams the record while it runs; its RSS doesn't grow with the record.
- **Replay:** per replayed record, run 1's wall time per recorded tick; the open (decode) median of 200 opens next to it; and memory from GNU time's "Maximum resident set size": the replay's peak, the peak of an open alone (the process plus the decoded record), and their difference per recorded tick (what replay adds on top of holding the record). `--verify` must report the state hashes verified.
- **Open cost of a 3.0 record against 2.x JSON** (#245, measured once on the measurement host, release build, `taskset -c 0-7`; `ReevaluationRunner --time-open`, the median of each run's opens, json and 3.0 runs interleaved; the figure is the median over runs). The gate: a 3.0 open no slower than the JSON open of the same recording. At 3ef15c2c it failed on the small input (192 KB JSON, 67.6 KB 3.0: json 3.258 ms, 3.0 3.383 ms, ratio 1.038) and passed on the large one (29.4 MB JSON, 11.0 MB 3.0: 999.4 ms against 800.8 ms, ratio 0.801). The cost was per decoded field: three key lookups per optional field, each copying the key. After the decoder fix (#280, decode side only, no byte change), at 3e1c9bc5: small input json 3.266 ms [3.161–3.330], 3.0 2.658 ms [2.575–2.837], ratio 0.814; large input 1000.5 ms against 725.8 ms, ratio 0.725 (7 runs each; the same input files). No host CPU samples were taken for the second run.
- **Recording cost**, recording on against off, mean over repeats: throughput (actions completed per steady second), the steady-phase CPU mean, the peak RSS, and from the profiling lines the ticker's lag p99 (over the windows), the median of the windows' `encode_ms` and `send_ms` p99, and the sync phase means per full plan (`sync_extract_ms`, `sync_broadcast_ms`, `sync_perplayer_ms`). Tick and sync *duration* p99 aren't sampled (#282); tick lag p99 is.
- **Flat RSS:** one 600 s recording-on run. The least-squares slope of the per-second RSS over the steady phase's last 300 s; it passes when the growth over that window (slope × 300 s) is under 2 % of the window's mean RSS.
- **B** is re-encoded from the stored record in two ways: compact JSON with sorted keys, and MessagePack with sorted keys. The MessagePack encoder is a small standard-library one for the JSON subset, and always uses each value's smallest format. Each is reported raw and gzipped.
- **B_minimal** keeps:
  - the record metadata, seed included;
  - for each tick that has an input, its tickId, sequence fields, actions, clientEvents and lifecycleEvents. Resolver outputs are inside those.

  It drops stateHash, serverEvents, syncOutputs and syncMarkers, and ticks without inputs. It is a size bound, not a replayable format.
- **A** is the bytes of the frames each session received, as the server encoded them (no WebSocket framing). A's gzip compresses each session's whole stream as one blob, which is fair against B's whole-file gzip. A live stream is sent frame by frame and can't be compressed that way.
- **Where B's overhead lands:** a second table drops one thing at a time from B_asStored (stateHash only, then only the ticks with no input), next to B_minimal, each over A. At 2 players and a 20-tick cadence most ticks have no input, so this is where a fixed per-tick cost would show.
- **The headline ratio** is B_asStored as MessagePack plus gzip, over A_total as MessagePack plus gzip, per input cadence (5 and 20 ticks) and per player count (2, 5, 10).

## Parameter matrix

| parameter | values |
|---|---|
| players per room | 2, 5, 10 |
| input cadence (ticks between inputs) | 5, 20 |
| encoding | messagepack (main), json (appendix) |
| recording | on (sizes, replay speed), off (recording overhead) |

## Results

No runs yet.

<!-- results end -->

## Caveats

- B_minimal is not a format the runtime reads; it bounds what an input-only record could weigh.
- A counts encoded frames handed to the in-process transport, not bytes on a socket (no WebSocket or TCP framing).
