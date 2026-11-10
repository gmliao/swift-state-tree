# snapshot-baseline — same-testbed full-snapshot vs delta synchronization

## Question

At equal encoding (opcode MessagePack + PathHash), how much does delta synchronization
(only changed fields) save over a per-sync full snapshot (each recipient's complete view
every sync), and does the saving track the changed fraction |ΔSt| / |S|?

This is a **same-testbed internal baseline**: the same hero-defense Land, the same workload
generator, the same encoder, the same machine, the same sweep — the only variable is the
`SyncStrategy` (`delta` vs `full-snapshot`) introduced in PR #53. It is deliberately not a
cross-framework comparison.

Design note: `Notes/plans/specs/2026-09-15-snapshot-baseline-design.md` (§3 semantics,
§6 matrix). Equivalence of the two strategies is proven by
`Tests/SwiftStateTreeTransportTests/SyncStrategyEquivalenceTests.swift`: both rebuild
byte-identical client views after every sync on both extraction paths, so the difference
below is purely transmitted volume.

## Environment

The rerun's provenance (its commit, dirty flag, Swift version and build) opens the Results section: `regenerate.py` writes it from the results' `meta` and refuses results with no commit or from more than one, measured on a dirty tree, or without a dirty flag at a commit outside `GRANDFATHERED_COMMITS` (the commits of the tracked results collected before the flag was recorded; `collect.py` refuses a sweep whose run.json lacks it) (`--check` verifies the line). The list below is the pre-refreeze record's.

- git_sha: `d2c647b` (main; includes PR #53 and `EncodingBenchmark --sync-strategy`)
- swift_version: Apple Swift 6.3.2, build_config: release
- host: Apple M2, macOS (Darwin 25.6.0), arm64, 8 cores, 16 GB — same machine as
  `deep-research/single-room-entity-scaling`
- encoding: `messagepack-pathhash`; `USE_SNAPSHOT_FOR_SYNC=false` for the pre-refreeze record (same legacy
  extraction path as `single-room-entity-scaling`, so its delta cells are directly comparable); a `run.sh`
  sweep takes the shipped sync path (below)
- `bytesPerSync` convention: room-level aggregate — the sum over recipients of each
  recipient's merged update at one sync event (the room-level aggregate convention used by the archived 2026-02 tables)

## Command(s)

`run.sh` executes every strategy cell (12 invocations, 22 cells); extra runs provide the JSON rows of the
10/30/50-room re-measurement and all rows of the 100/300/500-room re-measurement and moves the raw
scalability-matrix JSONs into `raw/`; `collect.py` splits them into one `results/<cell>.json`
per cell; `regenerate.py` produces the tables below.

```bash
cd Examples/GameDemo
export USE_SNAPSHOT_FOR_SYNC=false   # the pre-refreeze record; run.sh sweeps unset it
for S in delta full-snapshot; do
  # Rooms axis (RQ1 workload)
  swift run -c release EncodingBenchmark --scalability --format messagepack-pathhash \
    --players-per-room-list 5 --room-counts 10,30,50 --iterations 200 --ticks-per-sync 2 \
    --sync-strategy $S
  # Monster axis
  for CAP in 4 10 50 100; do
    swift run -c release EncodingBenchmark --scalability --format messagepack-pathhash \
      --players-per-room-list 5 --room-counts 1 --monster-cap $CAP --iterations 200 \
      --ticks-per-sync 2 --sync-strategy $S
  done
  # Active-player axis
  swift run -c release EncodingBenchmark --scalability --format messagepack-pathhash \
    --players-per-room-list 5,10,20,50 --room-counts 1 --monster-cap 4 --active-players \
    --iterations 200 --ticks-per-sync 2 --sync-strategy $S
done
# JSON rows for the 10/30/50-room re-measurement (delta only)
swift run -c release EncodingBenchmark --scalability --format json-object \
  --players-per-room-list 5 --room-counts 10,30,50 --iterations 200 --ticks-per-sync 2
# 100/300/500-room re-measurement: JSON delta, MsgPack delta, MsgPack full-snapshot
swift run -c release EncodingBenchmark --scalability --format json-object \
  --players-per-room-list 5 --room-counts 100,300,500 --iterations 200 --ticks-per-sync 2
for S in delta full-snapshot; do
  swift run -c release EncodingBenchmark --scalability --format messagepack-pathhash \
    --players-per-room-list 5 --room-counts 100,300,500 --iterations 200 --ticks-per-sync 2 \
    --sync-strategy $S
done
```

**Method change for the rerun.** The results below were taken with every scalability run
measuring both a serial and a parallel pass and reporting the parallel half, unpinned. `run.sh`
now passes `--parallel false`, so each cell runs the serial pass alone and reports it (the raw
JSON then has only a `serial` half and `config.mode: "serial"`; `collect.py` reads that half), and
pins the benchmark to CPUs 0-7 with `taskset` (`PIN_CPUS`). After each measured cell, `run.sh`
runs the same cell again with `--capture-views` and checks it with ws-loadtest's `verify-views`:
for every recipient of the first 10 rooms, the state the TypeScript SDK rebuilds from the frames
addressed to it must equal that player's projection after every sync, or the sweep stops. Its
report is `raw/<tag>.views.json`. The capture pass is not timed into any result; `VERIFY_VIEWS=0` skips it (repeats after one gated sweep).

For the rerun, `run.sh` puts every output of one invocation under `raw/<RUN_ID>/`, with its record `raw/<RUN_ID>/run.json` (`runmeta.py`): the options, the git commit and whether the tree was dirty, `swift --version`, `node --version`, the start and end times, and each cell's status as it finishes. Options (environment):

- `REPEAT=<n>` is required: the repeat the sweep is. `collect.py` takes the repeat and the order from `run.json` only, never from a directory name or a time, and writes each cell as `results/<cell>-rep<n>.json` with `params.repeat`, `params.order` and `params.sweep` (the `RUN_ID`). Two sweeps claiming the same repeat are refused unless all but one are marked superseded (`python3 runmeta.py supersede raw/<RUN_ID> "<reason>"`). The tables in the intended wire form are per-cell medians over repeats 1, 2 and 3 (`regenerate.py` `merge_repeats`): a cell missing a repeat or holding one twice, a run outside repeats 1–3, or repeats from different commits are refused. The tables need every row, so each of the three sweeps runs with `EXTRA=1`: `REPEAT=1 EXTRA=1 bash run.sh`, then `REPEAT=2 ORDER=snapshot-first VERIFY_VIEWS=0 EXTRA=1` and `REPEAT=3 VERIFY_VIEWS=0 EXTRA=1`. The pre-refreeze record is the one unrepeated sweep (no `repeat`).
- `RUN_ID` defaults to `<UTC yyyymmddTHHMMSSZ>-<short sha>`, generated once at start and printed first (`RUN_ID=<id>`), in a real run and a dry run alike. An existing `RUN_ID` is refused; with `OVERWRITE=1` (same repeat only) its cells are redone, `run.json` records the redo, and each replaced file is logged to `overwrites.log` there.
- `ORDER=delta-first|snapshot-first`: which strategy runs first within each axis; the other runs right after it.
- `EXTRA=1` is required (`run.sh` refuses a sweep without it unless `SMOKE=1`, for a smoke run): it adds the extra rows above, with the same pinning and `--parallel false`: JSON-object delta at 10/30/50 rooms, gated like every cell, and the three 100/300/500-room rows, not gated. The capture keeps only the first 10 rooms, whose frames come from the same encoder and room code as the 10/30/50-room cells, so a gate pass there would check nothing new, and at 500 rooms it takes as long as the measured pass.
- `DRY_RUN=1` prints every command with its final arguments and output paths, builds included, and runs none. `test_run.py` checks the commands through it, and runs whole sweeps against a stand-in benchmark to check `run.json`, the refusals and `collect.py`.

**The sync path.** `run.sh` unsets every server variable (`deep-research/serverenv.py`), so a run takes the shipped sync path (`USE_SNAPSHOT_FOR_SYNC` unset); `run.json` records them and `regenerate.py` refuses a run with any set. The sync path doesn't change what is sent: with `USE_SNAPSHOT_FOR_SYNC=false` and unset, every frame's length and every recipient's projection after every sync were equal, and both captures passed `verify-views` (at e8692a37, one cell per variant: snapshot-baseline monster cap 4 delta and full-snapshot and 10 rooms delta, entity-delta-baseline monster cap 4 sst-events, sst and b2, visibility default cell radius and all; 1,005 to 10,015 frames per cell; as negative controls, sst vs sst-events and delta vs full-snapshot differ in frame lengths). Frames aren't byte-identical, nor are two runs of either path: the order of entries within a frame varies between processes (#314).

`--sync-strategy full-snapshot` sets `SYNC_STRATEGY` for the benchmark process; every
`TransportAdapter` then diffs each recipient's view against an empty snapshot (all present
fields as `.set`, plus `.delete` for top-level fields that vanished since the previous sync),
every sync, even when nothing changed. Late-join initial sync and encoding are unchanged.

## Parameter matrix

| Axis | Swept | Held fixed | Strategies |
|---|---|---|---|
| Rooms | 10, 30, 50 rooms | players 5 per room, natural spawn | delta, full-snapshot (+ JSON-object delta for the 10/30/50-room re-measurement) |
| Rooms, large | 100, 300, 500 rooms | players 5 per room, natural spawn | delta, full-snapshot, JSON-object delta |
| Monsters | monster cap 4, 10, 50, 100 | rooms 1, players 5 idle | delta, full-snapshot |
| Active players | players 5, 10, 20, 50, all moving every tick | rooms 1, monster cap 4 | delta, full-snapshot |

Fixed everywhere: `messagepack-pathhash`, `ticksPerSync = 2`, `iterations = 200`, release
build, single machine, the shipped sync path (`USE_SNAPSHOT_FOR_SYNC=false` in the pre-refreeze record). Metrics: `bytes_per_sync` (primary),
`avg_cost_per_sync_ms` (secondary, same runs; reported, not interpreted).

## Results

Wire form of these tables: pathIndex on, fieldMerge on, checked per run.

Provenance, from the results' meta: commit `75222b8`, dirty flag not recorded; Swift 6.2.4; build release.

Each value is the median over repeats 1–3 of its cell.

### Rooms axis (RQ1 workload: players 5 per room, natural spawn)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) | full avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) |
|---|---:|---:|---:|---:|---:|---:|
| rooms 10 (players 50) | 2,680 | 37,779 | 14.10× | 92.9% | 0.146 | 0.157 |
| rooms 30 (players 150) | 8,023 | 113,890 | 14.20× | 93.0% | 0.143 | 0.146 |
| rooms 50 (players 250) | 13,367 | 189,969 | 14.21× | 93.0% | 0.143 | 0.146 |

### 10/30/50-room re-measurement (all rows measured at the same commit)

| Format / Strategy | Rooms | Total Players | bytesPerSync |
|---|---:|---:|---:|
| JSON Object, delta | 10 | 50 | 18,430 |
| JSON Object, delta | 30 | 150 | 54,994 |
| JSON Object, delta | 50 | 250 | 91,686 |
| Opcode MsgPack (PathHash), delta | 10 | 50 | 2,680 |
| Opcode MsgPack (PathHash), delta | 30 | 150 | 8,023 |
| Opcode MsgPack (PathHash), delta | 50 | 250 | 13,367 |
| Opcode MsgPack (PathHash), full-snapshot | 10 | 50 | 37,779 |
| Opcode MsgPack (PathHash), full-snapshot | 30 | 150 | 113,890 |
| Opcode MsgPack (PathHash), full-snapshot | 50 | 250 | 189,969 |

### Monster axis (rooms 1, players 5 idle, |ΔSt| ↑)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) | full avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) |
|---|---:|---:|---:|---:|---:|---:|
| monster cap 4 | 425 | 4,274 | 10.06× | 90.1% | 0.186 | 0.192 |
| monster cap 10 | 1,030 | 6,132 | 5.95× | 83.2% | 0.299 | 0.262 |
| monster cap 50 | 4,427 | 18,064 | 4.08× | 75.5% | 1.093 | 0.780 |
| monster cap 100 | 8,768 | 33,181 | 3.78× | 73.6% | 2.358 | 1.733 |

### Active-player axis (rooms 1, monster cap 4, every player moves every tick, |ΔSt| ≈ |R| = n)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) | full avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) |
|---|---:|---:|---:|---:|---:|---:|
| players 5 | 1,065 | 4,464 | 4.19× | 76.1% | 0.426 | 0.356 |
| players 10 | 3,474 | 14,632 | 4.21× | 76.3% | 0.671 | 0.569 |
| players 20 | 12,237 | 52,332 | 4.28× | 76.6% | 1.194 | 0.946 |
| players 50 | 69,958 | 302,838 | 4.33× | 76.9% | 2.895 | 2.250 |

### 100/300/500-room re-measurement (same commit)

| Format / Strategy | Rooms | Total Players | bytesPerSync |
|---|---:|---:|---:|
| JSON Object, delta | 100 | 500 | 183,620 |
| JSON Object, delta | 300 | 1500 | 550,426 |
| JSON Object, delta | 500 | 2500 | 917,638 |
| Opcode MsgPack (PathHash), delta | 100 | 500 | 26,755 |
| Opcode MsgPack (PathHash), delta | 300 | 1500 | 80,329 |
| Opcode MsgPack (PathHash), delta | 500 | 2500 | 133,926 |
| Opcode MsgPack (PathHash), full-snapshot | 100 | 500 | 380,227 |
| Opcode MsgPack (PathHash), full-snapshot | 300 | 1500 | 1,146,220 |
| Opcode MsgPack (PathHash), full-snapshot | 500 | 2500 | 1,912,450 |

### Drift check: re-run delta cells vs archived `single-room-entity-scaling`

The archived cells were measured at `648fce5`, `9f65c9e`, before the path index and field merge; the pre-refreeze record below reproduces them. The re-run differs from them by more than the wire form. Among the changes between the two, #178 stopped sending players' server-only fields (monster cap 4: 828 → 818 B), #271 and #278 send positions and rotations as arrays of their leaves instead of keyed maps, and #210 encodes identifiers as strings; at the path index's base, the form with neither the index nor the merge measured 587 B at monster cap 4 (#297). How 818 → 587 splits among the changes was not measured. The columns therefore separate the two: *code changes* is archived → off/off, both knobs off at the re-run's commit (`single-room-entity-scaling`'s ablation, `75222b8`); *wire form* is that ablation's off/off → on/on, the path index and field merge alone. The archived and re-run columns are EncodingBenchmark's `bytesPerSync`, truncated to whole bytes; off/off is `totalBytes / iterations` (shown rounded), and the wire-form column compares the ablation's two forms at that precision. The archive's truncation (under 1 B) moves the code-changes column by at most 0.09 percentage points. The table shows that the archive and the re-run differ by a measured amount; only the wire-form column measures the wire form.

| Cell | archived | off/off, same commit | re-run (on/on) | code changes | wire form |
|---|---:|---:|---:|---:|---:|
| monster cap 4 | 828 | 587 | 425 | -29.1% | -27.5% |
| monster cap 10 | 2,032 | 1,427 | 1,030 | -29.8% | -27.8% |
| monster cap 50 | 9,112 | 6,362 | 4,427 | -30.2% | -30.4% |
| monster cap 100 | 18,139 | 12,675 | 8,768 | -30.1% | -30.8% |
| active players 5 | 2,490 | 1,708 | 1,065 | -31.4% | -37.6% |
| active players 10 | 8,340 | 5,696 | 3,474 | -31.7% | -39.0% |
| active players 20 | 30,148 | 20,442 | 12,237 | -32.2% | -40.1% |
| active players 50 | 176,264 | 118,985 | 69,958 | -32.5% | -41.2% |

### Rooms axis vs the archived 2026-01/02 payload tables (per-room bytesPerSync)

| Format | archived 2026-01-25 (10 rooms) | archived 2026-02-06 (100 rooms) | this topic (10 rooms) | this topic (100 rooms) |
|---|---:|---:|---:|---:|
| JSON Object | 1,762.7 | 1,754.7 | 1,843.0 | 1,836.2 |
| Opcode MsgPack (PathHash) | 457.2 | 498.5 | 268.0 | 267.6 |

### Pre-refreeze record (pathIndex off, fieldMerge off; commit b8e798b, c0118d6, d2c647b)

Measured before the path index and field merge existed. Kept as the record of that form, not compared with the tables above.

#### Rooms axis (RQ1 workload: players 5 per room, natural spawn)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) | full avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) |
|---|---:|---:|---:|---:|---:|---:|
| rooms 10 (players 50) | 5,063 | 48,374 | 9.55× | 89.5% | 0.136 | 0.152 |
| rooms 30 (players 150) | 15,117 | 145,637 | 9.63× | 89.6% | 0.127 | 0.154 |
| rooms 50 (players 250) | 25,203 | 242,885 | 9.64× | 89.6% | 0.123 | 0.143 |

#### 10/30/50-room re-measurement (all rows measured at the same commit)

| Format / Strategy | Rooms | Total Players | bytesPerSync |
|---|---:|---:|---:|
| JSON Object, delta | 10 | 50 | 18,090 |
| JSON Object, delta | 30 | 150 | 53,952 |
| JSON Object, delta | 50 | 250 | 89,971 |
| Opcode MsgPack (PathHash), delta | 10 | 50 | 5,063 |
| Opcode MsgPack (PathHash), delta | 30 | 150 | 15,117 |
| Opcode MsgPack (PathHash), delta | 50 | 250 | 25,203 |
| Opcode MsgPack (PathHash), full-snapshot | 10 | 50 | 48,374 |
| Opcode MsgPack (PathHash), full-snapshot | 30 | 150 | 145,637 |
| Opcode MsgPack (PathHash), full-snapshot | 50 | 250 | 242,885 |

#### Monster axis (rooms 1, players 5 idle, |ΔSt| ↑)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) | full avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) |
|---|---:|---:|---:|---:|---:|---:|
| monster cap 4 | 828 | 5,456 | 6.59× | 84.8% | 0.371 | 0.402 |
| monster cap 10 | 2,014 | 7,765 | 3.86× | 74.1% | 0.609 | 1.159 |
| monster cap 50 | 9,164 | 22,685 | 2.48× | 59.6% | 2.193 | 6.490 |
| monster cap 100 | 18,140 | 41,517 | 2.29× | 56.3% | 4.770 | 3.699 |

#### Active-player axis (rooms 1, monster cap 4, every player moves every tick, |ΔSt| ≈ |R| = n)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) | full avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) |
|---|---:|---:|---:|---:|---:|---:|
| players 5 | 2,490 | 5,818 | 2.34× | 57.2% | 0.644 | 0.505 |
| players 10 | 8,349 | 19,164 | 2.30× | 56.4% | 1.393 | 1.080 |
| players 20 | 30,143 | 68,604 | 2.28× | 56.1% | 3.227 | 2.730 |
| players 50 | 176,264 | 397,714 | 2.26× | 55.7% | 12.938 | 12.318 |

#### 100/300/500-room re-measurement (same commit)

| Format / Strategy | Rooms | Total Players | bytesPerSync |
|---|---:|---:|---:|
| JSON Object, delta | 100 | 500 | 180,196 |
| JSON Object, delta | 300 | 1500 | 540,170 |
| JSON Object, delta | 500 | 2500 | 900,564 |
| Opcode MsgPack (PathHash), delta | 100 | 500 | 50,463 |
| Opcode MsgPack (PathHash), delta | 300 | 1500 | 151,346 |
| Opcode MsgPack (PathHash), delta | 500 | 2500 | 252,319 |
| Opcode MsgPack (PathHash), full-snapshot | 100 | 500 | 486,059 |
| Opcode MsgPack (PathHash), full-snapshot | 300 | 1500 | 1,463,595 |
| Opcode MsgPack (PathHash), full-snapshot | 500 | 2500 | 2,441,395 |

#### Drift check: re-run delta cells vs archived `single-room-entity-scaling`

| Cell | archived bytesPerSync | re-run bytesPerSync | drift |
|---|---:|---:|---:|
| monster cap 4 | 828 | 828 | +0.0% |
| monster cap 10 | 2,032 | 2,014 | -0.9% |
| monster cap 50 | 9,112 | 9,164 | +0.6% |
| monster cap 100 | 18,139 | 18,140 | +0.0% |
| active players 5 | 2,490 | 2,490 | +0.0% |
| active players 10 | 8,340 | 8,349 | +0.1% |
| active players 20 | 30,148 | 30,143 | -0.0% |
| active players 50 | 176,264 | 176,264 | +0.0% |

#### Rooms axis vs the archived 2026-01/02 payload tables (per-room bytesPerSync)

| Format | archived 2026-01-25 (10 rooms) | archived 2026-02-06 (100 rooms) | this topic (10 rooms) | this topic (100 rooms) |
|---|---:|---:|---:|---:|
| JSON Object | 1,762.7 | 1,754.7 | 1,809.0 | 1,802.0 |
| Opcode MsgPack (PathHash) | 457.2 | 498.5 | 506.3 | 504.6 |

## Conclusion

Under identical encoding, delta synchronization sends 3.78×–14.21× fewer bytes per sync than a
per-sync full snapshot in the current record (commit `75222b8`, pathIndex on, fieldMerge on), across
the 11 cells of the three axes; the delta saving is 73.6–93.0%:

- rooms 10–50: 14.10×–14.21× (92.9–93.0%);
- monster cap 4 to 100: 10.06× down to 3.78× (90.1% down to 73.6%);
- active players 5–50: 4.19×–4.33× (76.1–76.9%).

The saving is largest where most of the tree is unchanged each tick (the rooms axis, monster cap 4)
and smallest where nearly every entity changes every tick (monster cap 100, the active-player
axis): even then delta pays only for the changed *fields* of each entity (position, rotation)
while a snapshot resends every field of every entity.

The pre-refreeze record (commits `b8e798b`, `c0118d6`, `d2c647b`, pathIndex off, fieldMerge off)
measured 2.26×–9.64× on the same three axes (rooms 9.55×–9.64×, 89.5–89.6%; monster cap 4 to 100
6.59× down to 2.29×, 84.8% down to 56.3%; active players 2.26×–2.34×, 55.7–57.2%). Its delta
cells reproduce the archived `single-room-entity-scaling` numbers within ±0.9%, so that record is
compared against exactly the archived data. The current record's drift table does not reproduce the
archive: it separates the code changes since the archive from the wire form.

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
- On a Mac the same sleep can slow the next span 2–2.5×, so Mac timings from this harness aren't comparable with the host's. The pre-refreeze record ran on a Mac: compare its timings only with each other.

The published numbers are kept. Details: `Notes/solutions/2026-11-10-a-sleep-between-timed-spans-slows-the-next-span.md`. Replacing the sleep is #442, after the current measurement round.

## Caveats

- **Coupled to `single-room-entity-scaling`.** The intended form's drift table splits its drift with that
  topic's wire-form ablation at the same commit, and `regenerate.py` refuses it otherwise (another commit,
  a missing point, a failed gate of that topic, or on-on bytes that aren't this re-run's). Re-running
  either topic means re-running the other.
- Not varied: encoding (MessagePack PathHash only — a JSON × full-snapshot cell would only
  compound two known-bad choices), `ticksPerSync`, iterations, machine, interest
  management / sync scope (all cells use the hero-defense global-broadcast scope).
- `full-snapshot` is a measurement baseline, not a production mode; it re-sends the full
  view even on ticks with no change, which is exactly what a naive snapshot protocol does.
- `avg_cost_per_sync_ms` is a single-run, in-process timing on a laptop; the two strategies
  are within noise of each other on most cells and no claim is made from it.
- **Why the rooms-axis delta cells differ from the 2026-01-25 archive.** The 2026-01-25
  archive (4,572 / 13,612 / 22,713 B, commit `92dd620`) reproduces exactly on this machine, so
  the gap is code, not hardware. Landmark re-runs on the same machine give 5,002 B at commit
  `db694e1~1` (2026-02-08) and 5,063 B from 2026-08 onwards; the 2026-02-06 archive
  (100 rooms) already implies 4,985 B per 10 rooms. The step between 01-25 and
  02-06 coincides with the opcode-107 wire-format change (state update and server events
  merged into one MessagePack frame, `4423693`), which affects only the MessagePack path —
  consistent with the JSON-object per-room figure being unchanged across all three
  measurements (1,763 / 1,755 / 1,809 B). The two archives were therefore
  measured under different wire formats; the two re-measurements above re-measure every
  row of both at one commit (`d2c647b`) and supersede them; the
  per-room figures now agree between 10 and 100 rooms within 0.4%. The PR #47
  determinism fix is **not** the cause (5,063 B is already observed at `e119b04`, the commit
  before it).
- Prior to PR #53 the default extraction path (`USE_SNAPSHOT_FOR_SYNC` unset) could seed the
  diff cache incompletely (fixed in `ed9b80e`); this topic and `single-room-entity-scaling`
  both use `USE_SNAPSHOT_FOR_SYNC=false`, which was never affected, and the pre-refreeze
  record's drift table confirms it.
