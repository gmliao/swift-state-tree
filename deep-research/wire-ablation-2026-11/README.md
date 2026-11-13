# Wire ablation: dirty tracking and dynamic-key compression

## Question

The 2026-11 rerun keeps two of the server's wire optimizations fixed at their shipped defaults: dirty tracking (auto, so on) and dynamic-key compression (on). This topic measures each against off in one hero-defense room, on `single-room-entity-scaling`'s entity axis:
- **Dirty tracking** should change no byte: it decides which fields the sync extracts and diffs, not what is sent. Its question is CPU: what does the sync's scan of the whole state cost with dirty tracking off, against the dirty-path extraction with it on?
  - What this ablation can't measure: the marking. A `ReactiveDictionary` records a dirty key on every write whether dirty tracking is on or off (`Sources/SwiftStateTree/State/ReactiveDictionary.swift:58`, `:74`, `:90`, `:108`); the switch only changes how the adapter extracts and diffs. Both forms pay the marking, so the difference measured here is the sync side only, not the whole cost of tracking. Measuring the marking would take a micro-benchmark of a write with and without it (a build of the state layer with marking compiled out), which this topic doesn't build.
- **Dynamic-key compression** changes bytes: off sends every dynamic key as its full string instead of a table slot after first use (#59, #170). Its question is bytes, and whether off still rebuilds every view.

## Where, and why a new topic

`single-room-entity-scaling` fixes both knobs for its main table: it runs dirty tracking at `auto` and refuses dynamic-key compression off (`regenerate.py:75`). Loosening those gates there would put two kinds of result in one table. So this is its own topic, `deep-research/wire-ablation-2026-11/`. It reuses that topic's run shape (one room, the same cells and flags), its runmeta, and the shared `serverenv.py`, `wireform.py` and `provenance.py`, and cross-checks its bytes against that topic's ablation (§ Gates).

## Environment

The measurement host: release build of EncodingBenchmark, CPUs 0-7 pinned (`taskset`), Swift 6.2.4. Serial sync (`--parallel false`), the delta strategy, the shipped sync path: run.sh unsets every `serverenv.py` variable, and the knobs are set by the benchmark's own flags (`--dirty-tracking on|off`, `--dynamic-key-compression on|off`, `--path-index on --field-merge on`), which apply them inside the process before any adapter exists and record them in the result's metadata (`dirtyTracking`, `dirtyTrackingEffective`, `dynamicKeyCompression`, `pathIndex`, `fieldMerge`).

**Same Sources as the rerun.** The run records the git tree IDs of `Sources/` and `Package.swift` at its commit (`git rev-parse HEAD:Sources`, `HEAD:Package.swift`). `regenerate.py` refuses any other than those of `75222b87`, the rerun's commit, so these numbers sit beside the rerun's even though the run is at a later commit (scripts only).

## Cells

Each point of `single-room-entity-scaling`'s axis (12 points: `monsters-cap4/10/50/100` at 5 idle players; `idle-players` 10, 20, 50; `active-players` 5, 10, 20, 50; `joint` 20 active players, cap 20), each `--room-counts 1 --iterations 200 --ticks-per-sync 2`, in six forms:

| Form | Format | Dirty tracking | Dynamic-key compression |
|---|---|---|---|
| `mp-dt-dk` | messagepack-pathhash, path index on, field merge on | on | on |
| `mp-dt-nodk` | same | on | off |
| `mp-nodt-dk` | same | off | on |
| `mp-nodt-nodk` | same | off | off |
| `oj-dk` | opcode-json-pathhash, path index on, field merge on | on | on |
| `oj-nodk` | same | on | off |

`mp-dt-dk` is the shipped wire form with dirty tracking pinned on (the shipped default is `auto`, which starts on; `on` disables the auto switch, so the run can't change mode midway). The two `oj-*` forms show dynamic-key compression in the JSON opcode form, which also uses it; dirty tracking isn't repeated there, since its question is the same scan.

72 (point, form) cells (12 points × 6 forms) × 4 repeats = **288 measured results**, from 42 benchmark processes per repeat (168 in all; a process runs a cell's player counts in turn), then one capture pass per cell (42 processes, 72 results) as its own block after all four measured repeats (`CAPTURE_ONLY=1`), so verify-views' projection work never warms or heats the CPU just before a measured form.

**Order (ABBA across the knobs).** Each cell is one benchmark process per form: `idle-players` and `active-players` run their 3 and 4 player counts in one process, one after another, so the order is per cell. Within a cell, repeats 1 and 4 run the forms in the order above and repeats 2 and 3 in reverse, so every pair of forms is measured twice in each order. Cells run in the same order in every repeat. That's 7 cells × 6 forms = 42 benchmark processes per repeat.

## Measured (per cell, per repeat)

- `bytes_per_sync`: `totalBytes / iterations`, and `bytes_per_player_per_sync`.
- `sync_ms_per_sync`: the benchmark's `syncMs` (serial runs: the time in `syncNow()` alone, which is the extraction, the diff, the encode and the hand-off to the counting transport; not the ticks or the move injection) over the iterations. This is the dirty-tracking comparison.
- `iteration_cpu_ms`: the benchmark's `cpuMs` (process CPU time, user + system, over the spans `timeMs` covers: the ticks, the move injection and the sync) over the iterations. A whole-iteration figure, reported for context; it isn't tracking's overhead.
- From the capture pass: the frames' sha256 (each frame's target and bytes, in order, for the room), for the byte-identity gate.

Tables: bytes (dynamic-key on vs off, both formats; dirty tracking shown only as "identical"), and time per sync (dirty tracking on vs off, dynamic-key on vs off), each as the median of the four repeats with their min-max.

## Gates

`collect.py` evaluates them per cell; `regenerate.py` refuses a result set that fails any, and `--check` reproduces every number in the README from `results/`.

1. **Dirty tracking doesn't change the bytes.** For each point and dynamic-key setting, `mp-dt-*` and `mp-nodt-*` have equal `totalBytes` in every repeat, and their capture passes have the same frame and sync counts and the same frames sha256 (`frames.py` hashes each sync's index and frame count before its frames, so a frame sent one sync later doesn't hash alike). A difference is a refusal and a finding (dirty tracking skipped a change, or scanned one it shouldn't send), not data.
   - The frames compare byte for byte only if nothing in them depends on the process's hash seed. Dynamic-key slots no longer do (#292, fixed by #311: a frame's new slots in byte order). To keep any other hash-ordered iteration out of the comparison, the capture passes run with `SWIFT_DETERMINISTIC_HASHING=1`; the measured passes don't (their bytes are compared by total, and their timings stay comparable with `single-room-entity-scaling`'s). With both forms at the same seed, frames that differ only in order are still a behavior difference (dirty tracking changed the order patches go out), so any difference stops the run as a finding, not data.
   - So verify-views runs here only under deterministic hashing; `single-room-entity-scaling` covers the seeded case.
2. **The knob reached the run.** The metadata's `dirtyTracking` and `dynamicKeyCompression` are the form's. With `--dirty-tracking on` or `off` the benchmark also turns the auto switch off (`AUTO_DIRTY_TRACKING=false`, `Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkConfig.swift:84-91`), so the adapters keep that mode for the whole run; the scalability matrix doesn't export the per-adapter effective count (`dirtyTrackingEffective` is in the other modes' results only), so the requested mode is what is checked. Dirty tracking can't be checked through the bytes (gate 1 holds them equal); its timing difference is the measurement. Dynamic-key off gives **more** bytes than on at **every** point, in **every** repeat, else the knob didn't reach the encoder.
   - Every point can differ: in the path-hash formats each dictionary key below `players` and `monsters` is a dynamic key (an `Int` monster ID as its string), and every point has moving monsters, at least 4 (`final_monster_count` at every point of `single-room-entity-scaling`'s 2026-11-09 run at `75222b87`: 4 at the cap-4 and player points, 10, 50, 100 at the other caps, 20 at `joint`), whose keys are referenced every sync. So no point has only first-use keys, and the gate is strict (off > on) everywhere; there is no "≥" point.
3. **Off still rebuilds every view.** Each cell's capture pass passes ws-loadtest's verify-views (every recipient's rebuilt state equals its projection after every sync), dynamic-key off included.
4. **Deterministic bytes.** Each cell has the same `totalBytes` in all four repeats.
5. **Cross-check with the rerun.** `mp-dt-dk`'s bytes equal `single-room-entity-scaling`'s `on-on` form at the same point (dirty tracking `auto` there, `on` here). The comparison reads `deep-research/single-room-entity-scaling/results/<cell>-p<players>-on-on-rep1.json` (repeat 1; its gate already holds every repeat to the same bytes), takes its `meta.git_sha`, and resolves that commit's Sources tree ID with `git rev-parse <sha>:Sources` (and `:Package.swift`), as `wireform.py` resolves commits from history. The two runs must also have the same parameters, from each result's metadata: the point (players, monster cap, active or idle), `iterations`, `ticksPerSync`, the room count, the format and its flags (`pathIndex`, `fieldMerge`, `dynamicKeyCompression`) and the sync strategy; otherwise a parameter drift would show up as unequal bytes, or two drifts could match by chance. The RNG seed isn't a parameter: it derives from the land ID, which the benchmark fixes (`benchmark-<room>`, `EncodingBenchmarkMain.swift:104-111`). A tree ID other than this topic's (75222b87's), a parameter that differs, a missing file, or unequal bytes are refusals. Gate 5 runs in `regenerate.py` (and so at `--check`), not in `collect.py`: the run doesn't need `single-room-entity-scaling`'s results, but the tables are refused until that topic's 75222b87 results are committed.
6. **The run.** Pinned CPUs, release build, clean tree (`git.dirty` false), Swift 6.2.4, every `serverenv.py` variable unset, the Sources and `Package.swift` tree IDs of `75222b87`, one commit for the whole set (`provenance.py`).

## Host time

The recorded run took **about 20 minutes** with a warm build cache: the four measured repeats (168 processes) 4 min 22 s in all, and the capture block (42 processes with verify-views) 15 min 51 s. A cold cache adds the release build of EncodingBenchmark and ws-loadtest's build.

## Commands

```bash
cd deep-research/wire-ablation-2026-11
for r in 1 2 3 4; do REPEAT=$r bash run.sh; done
CAPTURE_ONLY=1 bash run.sh          # the capture block: one pass per cell, with verify-views
python3 collect.py
python3 regenerate.py --markdown   # the Results section
python3 regenerate.py --check
```

`DRY_RUN=1 REPEAT=1 bash run.sh` prints every command. `CELLS=`/`FORMS=` select a smoke, which `collect.py` skips; an unpinned or dirty run is refused.

Files:
- `run.sh`: one measured repeat (`REPEAT=1..4`) or the capture block (`CAPTURE_ONLY=1`), raw outputs under `raw/<RUN_ID>/` (ignored), with `run.json` (`runmeta.py`: the kind, repeat and order, the commit, dirty flag and Sources/Package.swift trees, Swift and Node, the server environment).
- `frames.py`: the capture block's frame hashes (`<tag>.frames.json`).
- `collect.py`: `results/<cell>-p<P>-<form>-rep<n>.json` and `results/capture/<cell>-p<P>-<form>.json`.
- `regenerate.py`: the gates and the tables; `--check` compares README's Results with them.
- `test_topic.py`: the gates, the collector, the frame hash and run.sh's dry run, on fixtures.

## Results

Provenance, from the results' meta: commit `6f3783aadc34ea2390e2fe8575ad9591b756935c`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

Sources tree `cf82bd38` and Package.swift `ee126eb9`, those of the rerun's commit 75222b87. One room, 200 syncs of 2 ticks, serial; each figure is the median of 4 repeats with their min–max (ABBA order).

### Bytes per sync

Dirty tracking on and off sent identical bytes and frames at every point (gate 1), so only dirty tracking on is shown.

| Point | MsgPack, dynamic keys on | MsgPack, off | Off vs on | Opcode JSON, dynamic keys on | Opcode JSON, off | Off vs on |
|---|---:|---:|---:|---:|---:|---:|
| monsters-cap4 (5 idle) | 425.6 | 472.6 | +11.0 % | 840.2 | 889.8 | +5.9 % |
| monsters-cap10 (5 idle) | 1,030.8 | 1,158.4 | +12.4 % | 2,078.0 | 2,209.5 | +6.3 % |
| monsters-cap50 (5 idle) | 4,427.1 | 5,002.7 | +13.0 % | 8,672.5 | 9,210.2 | +6.2 % |
| monsters-cap100 (5 idle) | 8,768.4 | 9,675.1 | +10.3 % | 16,428.7 | 17,442.9 | +6.2 % |
| idle-players p10 | 828.4 | 914.4 | +10.4 % | 1,611.3 | 1,703.5 | +5.7 % |
| idle-players p20 | 1,814.5 | 2,018.8 | +11.3 % | 3,601.4 | 3,814.8 | +5.9 % |
| idle-players p50 | 4,355.2 | 4,851.0 | +11.4 % | 8,925.5 | 9,437.5 | +5.7 % |
| active-players p5 | 1,065.8 | 1,447.4 | +35.8 % | 2,065.2 | 2,473.9 | +19.8 % |
| active-players p10 | 3,474.1 | 4,937.6 | +42.1 % | 6,688.3 | 8,215.2 | +22.8 % |
| active-players p20 | 12,237.6 | 18,162.3 | +48.4 % | 23,522.3 | 29,575.1 | +25.7 % |
| active-players p50 | 69,958.5 | 107,276.0 | +53.3 % | 135,116.0 | 172,748.2 | +27.9 % |
| joint (20 active) | 18,543.7 | 25,117.6 | +35.5 % | 36,633.8 | 43,125.6 | +17.7 % |

### Sync time per sync, dirty tracking on vs off (ms)

`syncMs` over the syncs: the extraction, the diff, the encode and the hand-off inside `syncNow()`. The dirty-key marking on every write is paid in both forms and isn't in this comparison.

| Point | Dynamic keys on: tracking on | Tracking off | Off vs on | Dynamic keys off: tracking on | Tracking off | Off vs on |
|---|---:|---:|---:|---:|---:|---:|
| monsters-cap4 (5 idle) | 0.154 [0.150–0.155] | 0.152 [0.148–0.156] | -1.4 % | 0.151 [0.148–0.158] | 0.153 [0.145–0.178] | +1.5 % |
| monsters-cap10 (5 idle) | 0.245 [0.239–0.246] | 0.239 [0.232–0.248] | -2.5 % | 0.240 [0.235–0.245] | 0.237 [0.232–0.250] | -1.2 % |
| monsters-cap50 (5 idle) | 0.767 [0.759–0.856] | 0.763 [0.758–0.768] | -0.5 % | 0.768 [0.759–0.796] | 0.756 [0.743–0.760] | -1.6 % |
| monsters-cap100 (5 idle) | 1.463 [1.432–1.545] | 1.401 [1.366–1.429] | -4.3 % | 1.420 [1.379–1.532] | 1.397 [1.382–1.426] | -1.6 % |
| idle-players p10 | 0.175 [0.170–0.176] | 0.171 [0.168–0.174] | -2.1 % | 0.173 [0.172–0.181] | 0.171 [0.168–0.173] | -1.1 % |
| idle-players p20 | 0.228 [0.224–0.238] | 0.221 [0.216–0.224] | -2.8 % | 0.223 [0.222–0.229] | 0.218 [0.217–0.223] | -2.2 % |
| idle-players p50 | 0.358 [0.347–0.364] | 0.349 [0.343–0.360] | -2.4 % | 0.355 [0.351–0.360] | 0.356 [0.351–0.363] | +0.4 % |
| active-players p5 | 0.231 [0.229–0.241] | 0.228 [0.226–0.229] | -1.2 % | 0.230 [0.226–0.261] | 0.231 [0.227–0.242] | +0.2 % |
| active-players p10 | 0.330 [0.326–0.342] | 0.330 [0.326–0.338] | +0.0 % | 0.329 [0.325–0.361] | 0.328 [0.327–0.332] | -0.5 % |
| active-players p20 | 0.532 [0.527–0.540] | 0.530 [0.526–0.541] | -0.4 % | 0.539 [0.532–0.554] | 0.530 [0.529–0.542] | -1.7 % |
| active-players p50 | 1.134 [1.123–1.153] | 1.143 [1.115–1.169] | +0.8 % | 1.132 [1.107–1.181] | 1.135 [1.124–1.155] | +0.3 % |
| joint (20 active) | 0.748 [0.745–0.751] | 0.749 [0.747–0.750] | +0.1 % | 0.741 [0.738–0.745] | 0.744 [0.740–0.765] | +0.4 % |

### Whole-iteration CPU per sync (ms, context)

`cpuMs` over the syncs: process CPU over the ticks, the move injection and the sync. Context for the table above, not tracking's overhead.

| Point | Tracking on | Tracking off |
|---|---:|---:|
| monsters-cap4 (5 idle) | 0.199 [0.193–0.200] | 0.196 [0.190–0.202] |
| monsters-cap10 (5 idle) | 0.314 [0.306–0.315] | 0.307 [0.297–0.319] |
| monsters-cap50 (5 idle) | 1.071 [1.057–1.193] | 1.063 [1.057–1.068] |
| monsters-cap100 (5 idle) | 2.416 [2.355–2.501] | 2.328 [2.268–2.372] |
| idle-players p10 | 0.230 [0.224–0.232] | 0.225 [0.221–0.230] |
| idle-players p20 | 0.321 [0.317–0.340] | 0.313 [0.304–0.316] |
| idle-players p50 | 0.662 [0.645–0.671] | 0.644 [0.635–0.667] |
| active-players p5 | 0.441 [0.437–0.458] | 0.436 [0.435–0.440] |
| active-players p10 | 0.675 [0.667–0.699] | 0.673 [0.667–0.700] |
| active-players p20 | 1.171 [1.167–1.185] | 1.172 [1.156–1.186] |
| active-players p50 | 2.795 [2.771–2.833] | 2.818 [2.767–2.887] |
| joint (20 active) | 1.479 [1.466–1.480] | 1.480 [1.472–1.481] |

## Measurement note

Between iterations, outside the timed spans, EncodingBenchmark waits for the outbound writer (`TransportAdapter.waitForOutboundDrain`). That wait polls with a 1 ms sleep, so when a sync is shorter than the writer's drain, each iteration sleeps once, and the idle core can run the next span slower.

A check on the measurement host at `6f3783aa` (Linux, CPUs 0-7 pinned) compared it with a wait that polls with `Task.yield()`, on the `mp-dt-dk` form:
- monster cap 4: sync 0.149 → 0.139 ms (−6.5 %) and tick 0.038 → 0.033 ms (−13 %), the same sign in all 4 pairs;
- cap 100: −1.5 %, within its own run-to-run spread;
- active players p10: 0 %.

What this means for the tables here:
- The smallest cells (sync below about 0.35 ms) may read high by a few µs.
- Every form and variant runs the same wait, so comparisons between them hold.
- Cells with a longer sync, at cap 100 and above in the check, are unaffected.
- Byte counts are unaffected.
- On a Mac the same sleep can slow the next span 2–2.5×, so Mac timings from this harness aren't comparable with the host's.

The published numbers are kept. Details: `Notes/solutions/2026-11-10-a-sleep-between-timed-spans-slows-the-next-span.md`. Replacing the sleep is #442, after the current measurement round.

## Caveats

- Four repeats of 200 syncs: a time difference smaller than the repeats' min-max spread is reported as no difference.
- `syncMs` includes the hand-off to the counting transport; it is the same for every form of a point except for the bytes handed over.
- Dirty tracking's marking (a dirty key recorded on every write) is paid with dirty tracking on and off alike, so this topic measures the sync side of tracking only (see Question).
- The capture pass's timings aren't measurements (it computes a projection per player per sync).

## After the sync tables default

The results here predate the commit that removed the auto dirty switch. From it on, `--dirty-tracking` takes `on` (the default) or `off`; `auto` is an error, and `on` no longer needs to turn a switch off (the benchmark no longer sets `AUTO_DIRTY_TRACKING`). The shipped default the text above calls `auto` is `on` from then on.
