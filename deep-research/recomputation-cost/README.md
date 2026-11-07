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
# record to <run>/records/spool while it runs and saves it as <run>/records/*.sstr when it
# closes. Input cadence in ticks is 20 / actions-per-player-per-second (50 ms ticks):
# 4 → 5 ticks, 1 → 20 ticks.
swift run -c release ServerLoadTest --rooms <n> --players-per-room <2|5|10> \
  --actions-per-player-per-second <4|1> \
  --record on --record-dir <run>/records --stream-dir <run>/streams
# Recording overhead: the same run with --record off and no directories. The result file's
# summary.process has the steady-phase CPU mean (steadyCPUPercentMean, % of one core, the
# whole process: server and simulated clients) and the peak and end RSS; each second's sample
# has processCPUPercent and processRSSBytes.
# The JSON-to-JSON appendix: the same run with TRANSPORT_ENCODING=json.

# Replay speed: each run prints a REPLAY_TIMING line (wall ms, ticks/s, multiple of realtime).
swift run -c release ReevaluationRunner --input <run>/records/<room>.sstr           # run 1 only
swift run -c release ReevaluationRunner --input <run>/records/<room>.sstr --verify  # runs 1 and 2
```

Then copy each run under `results/<run>/` (with ServerLoadTest's result file as `loadtest.json`), and run `python3 regenerate.py`.

`python3 regenerate.py --self-test` checks the MessagePack encoder and decoder against known vectors, the 3.0 reader, and the helpers. `--check` fails if the Results below are stale.

## Method

- **Sizes are computed offline** in `regenerate.py`, from the stored records and the dumped streams. There's one compressor for both sides: gzip at level 9, mtime 0.
- **Records are 3.0 files** (`.sstr`, #245): a header, one length-prefixed canonical MessagePack record per keeper turn, and a footer. `regenerate.py` reads them with a small standard-library MessagePack decoder and rebuilds the 2.x structure the runtime gives the same file as its JSON view (`ReevaluationRunner --convert`): the record metadata, and one frame per tick with the tick's turns merged. The rebuilt value equals that JSON view, so B_asStored keeps its definition (everything the record holds, re-encoded), and 2.x JSON records are still read as they are. Only complete records are measured (the room saved them when it closed).
- **B_native** is the 3.0 file as stored, raw and gzipped: the canonical MessagePack of each turn, plus 4 bytes of framing per record, the header and the footer. It differs from B_asStored's MessagePack column by that framing and by the turn structure (a tick written in several turns repeats its tickId).
- **Peak RSS:** earlier records were held in memory and written at the end of the run, so a run's peak RSS included them (#245). A 3.0 run streams the record while it runs; its RSS doesn't grow with the record.
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
