# Wire ablation: dirty tracking and dynamic-key compression

_Nothing here is measured yet: the measurement host's run fills the Results section._

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

72 (point, form) cells (12 points × 6 forms) × 4 repeats = **288 measured results**, from 42 benchmark processes per repeat (168 in all; a process runs a cell's player counts in turn), then one capture pass per cell (42 processes, 72 results) as its own block after all four measured repeats (`CAPTURE_ONLY=1`), so verify-views' projection work never warms or heats the CPU just before a measured form. The measured repeats run with `CAPTURE=0`.

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
   - Every point can differ: in the path-hash formats each dictionary key below `players` and `monsters` is a dynamic key (an `Int` monster ID as its string), and every point has moving monsters, at least 4 (`final_monster_count` at every point of `single-room-entity-scaling`'s 2026-11-08 run: 4 at the cap-4 and player points, 10, 50, 100 at the other caps, 20 at `joint`), whose keys are referenced every sync. So no point has only first-use keys, and the gate is strict (off > on) everywhere; there is no "≥" point.
3. **Off still rebuilds every view.** Each cell's capture pass passes ws-loadtest's verify-views (every recipient's rebuilt state equals its projection after every sync), dynamic-key off included.
4. **Deterministic bytes.** Each cell has the same `totalBytes` in all four repeats.
5. **Cross-check with the rerun.** `mp-dt-dk`'s bytes equal `single-room-entity-scaling`'s `on-on` form at the same point (dirty tracking `auto` there, `on` here). The comparison reads `deep-research/single-room-entity-scaling/results/<cell>-p<players>-on-on-rep1.json` (repeat 1; its gate already holds every repeat to the same bytes), takes its `meta.git_sha`, and resolves that commit's Sources tree ID with `git rev-parse <sha>:Sources` (and `:Package.swift`), as `wireform.py` resolves commits from history. The two runs must also have the same parameters, from each result's metadata: the point (players, monster cap, active or idle), `iterations`, `ticksPerSync`, the room count, the format and its flags (`pathIndex`, `fieldMerge`, `dynamicKeyCompression`) and the sync strategy; otherwise a parameter drift would show up as unequal bytes, or two drifts could match by chance. The RNG seed isn't a parameter: it derives from the land ID, which the benchmark fixes (`benchmark-<room>`, `EncodingBenchmarkMain.swift:104-111`). A tree ID other than this topic's (75222b87's), a parameter that differs, a missing file, or unequal bytes are refusals. Gate 5 runs in `regenerate.py` (and so at `--check`), not in `collect.py`: the run doesn't need `single-room-entity-scaling`'s results, but the tables are refused until that topic's 75222b87 results are committed.
6. **The run.** Pinned CPUs, release build, clean tree (`git.dirty` false), Swift 6.2.4, every `serverenv.py` variable unset, the Sources and `Package.swift` tree IDs of `75222b87`, one commit for the whole set (`provenance.py`).

## Host time

From the 2026-11-08 run of `single-room-entity-scaling`, with the same cells: 7 cells × 5 forms × 2 repeats = 70 measured processes and 35 capture processes with verify-views took about 13 minutes. Here 7 × 6 × 4 = 168 measured processes and 42 capture processes are about 2.4 times the measured work and 1.2 times the capture work: about **25 minutes**, plus the release build of EncodingBenchmark and ws-loadtest's build (about 5-10 minutes with a warm cache). **About 35-40 minutes** in all.

## Commands

```bash
cd deep-research/wire-ablation-2026-11
for r in 1 2 3 4; do REPEAT=$r CAPTURE=0 bash run.sh; done
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

_No results yet: the measurement host's run fills this section._

## Caveats

- Four repeats of 200 syncs: a time difference smaller than the repeats' min-max spread is reported as no difference.
- `syncMs` includes the hand-off to the counting transport; it is the same for every form of a point except for the bytes handed over.
- Dirty tracking's marking (a dirty key recorded on every write) is paid with dirty tracking on and off alike, so this topic measures the sync side of tracking only (see Question).
- The capture pass's timings aren't measurements (it computes a projection per player per sync).
