# snapshot-baseline — same-testbed full-snapshot vs delta synchronization

## Question

At equal encoding (opcode MessagePack + PathHash), how much does delta synchronization
(only changed fields) save over a per-sync full snapshot (each recipient's complete view
every sync), and does the saving track |ΔSt| / |S| as Eq. (6) of the paper predicts?

This is a **same-testbed internal baseline**: the same hero-defense Land, the same workload
generator, the same encoder, the same machine, the same sweep — the only variable is the
`SyncStrategy` (`delta` vs `full-snapshot`) introduced in PR #53. It is deliberately not a
cross-framework comparison (see `deep-research/related-systems-matrix.md` for that axis).

Design note: `Notes/plans/specs/2026-09-15-snapshot-baseline-design.md` (§3 semantics,
§6 matrix). Equivalence of the two strategies is proven by
`Tests/SwiftStateTreeTransportTests/SyncStrategyEquivalenceTests.swift`: both rebuild
byte-identical client views after every sync on both extraction paths, so the difference
below is purely transmitted volume.

## Environment

- git_sha: `d2c647b` (main; includes PR #53 and `EncodingBenchmark --sync-strategy`)
- swift_version: Apple Swift 6.3.2, build_config: release
- host: Apple M2, macOS (Darwin 25.6.0), arm64, 8 cores, 16 GB — same machine as
  `deep-research/single-room-entity-scaling`
- encoding: `messagepack-pathhash`; `USE_SNAPSHOT_FOR_SYNC=false` (same legacy
  extraction path as `single-room-entity-scaling`, so its delta cells are directly comparable)
- `bytesPerSync` convention: room-level aggregate — the sum over recipients of each
  recipient's merged update at one sync event (same as the paper's §IV.A convention)

## Command(s)

`run.sh` executes every strategy cell (12 invocations, 22 cells); extra runs provide the JSON rows of the
Table VI replacement and all rows of the Table IX replacement (100/300/500 rooms) and moves the raw
scalability-matrix JSONs into `raw/`; `collect.py` splits them into one `results/<cell>.json`
per cell; `regenerate.py` produces the tables below.

```bash
cd Examples/GameDemo
export USE_SNAPSHOT_FOR_SYNC=false
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
# JSON rows for the Table VI replacement (delta only)
swift run -c release EncodingBenchmark --scalability --format json-object \
  --players-per-room-list 5 --room-counts 10,30,50 --iterations 200 --ticks-per-sync 2
# Table IX replacement (100/300/500 rooms): JSON delta, MsgPack delta, MsgPack full-snapshot
swift run -c release EncodingBenchmark --scalability --format json-object \
  --players-per-room-list 5 --room-counts 100,300,500 --iterations 200 --ticks-per-sync 2
for S in delta full-snapshot; do
  swift run -c release EncodingBenchmark --scalability --format messagepack-pathhash \
    --players-per-room-list 5 --room-counts 100,300,500 --iterations 200 --ticks-per-sync 2 \
    --sync-strategy $S
done
```

`--sync-strategy full-snapshot` sets `SYNC_STRATEGY` for the benchmark process; every
`TransportAdapter` then diffs each recipient's view against an empty snapshot (all present
fields as `.set`, plus `.delete` for top-level fields that vanished since the previous sync),
every sync, even when nothing changed. Late-join initial sync and encoding are unchanged.

## Parameter matrix

| Axis | Swept | Held fixed | Strategies |
|---|---|---|---|
| Rooms | 10, 30, 50 rooms | players 5 per room, natural spawn | delta, full-snapshot (+ JSON-object delta for the Table VI replacement) |
| Rooms, large (Table IX) | 100, 300, 500 rooms | players 5 per room, natural spawn | delta, full-snapshot, JSON-object delta |
| Monsters | monster cap 4, 10, 50, 100 | rooms 1, players 5 idle | delta, full-snapshot |
| Active players | players 5, 10, 20, 50, all moving every tick | rooms 1, monster cap 4 | delta, full-snapshot |

Fixed everywhere: `messagepack-pathhash`, `ticksPerSync = 2`, `iterations = 200`, release
build, single machine, `USE_SNAPSHOT_FOR_SYNC=false`. Metrics: `bytes_per_sync` (primary),
`avg_cost_per_sync_ms` (secondary, same runs; reported, not interpreted).

## Results

### Rooms axis (RQ1 workload: players 5 per room, natural spawn)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs | full avgCostPerSyncMs |
|---|---:|---:|---:|---:|---:|---:|
| rooms 10 (players 50) | 5,063 | 48,374 | 9.55× | 89.5% | 0.136 | 0.152 |
| rooms 30 (players 150) | 15,117 | 145,637 | 9.63× | 89.6% | 0.127 | 0.154 |
| rooms 50 (players 250) | 25,203 | 242,885 | 9.64× | 89.6% | 0.123 | 0.143 |

### Table VI replacement (all rows measured at the same commit)

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

### Monster axis (rooms 1, players 5 idle, |ΔSt| ↑)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs | full avgCostPerSyncMs |
|---|---:|---:|---:|---:|---:|---:|
| monster cap 4 | 828 | 5,456 | 6.59× | 84.8% | 0.371 | 0.402 |
| monster cap 10 | 2,014 | 7,765 | 3.86× | 74.1% | 0.609 | 1.159 |
| monster cap 50 | 9,164 | 22,685 | 2.48× | 59.6% | 2.193 | 6.490 |
| monster cap 100 | 18,140 | 41,517 | 2.29× | 56.3% | 4.770 | 3.699 |

### Active-player axis (rooms 1, monster cap 4, every player moves every tick, |ΔSt| ≈ |R| = n)

| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | delta avgCostPerSyncMs | full avgCostPerSyncMs |
|---|---:|---:|---:|---:|---:|---:|
| players 5 | 2,490 | 5,818 | 2.34× | 57.2% | 0.644 | 0.505 |
| players 10 | 8,349 | 19,164 | 2.30× | 56.4% | 1.393 | 1.080 |
| players 20 | 30,143 | 68,604 | 2.28× | 56.1% | 3.227 | 2.730 |
| players 50 | 176,264 | 397,714 | 2.26× | 55.7% | 12.938 | 12.318 |

### Table IX replacement (100/300/500 rooms, same commit)

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

### Drift check: re-run delta cells vs archived `single-room-entity-scaling`

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

### Rooms axis vs the paper's archived RQ1 tables (per-room bytesPerSync)

| Format | archived Table VI (2026-01-25, 10 rooms) | archived Table IX (2026-02-06, 100 rooms) | this topic (10 rooms) | this topic (100 rooms) |
|---|---:|---:|---:|---:|
| JSON Object | 1,762.7 | 1,754.7 | 1,809.0 | 1,802.0 |
| Opcode MsgPack (PathHash) | 457.2 | 498.5 | 506.3 | 504.6 |


## Conclusion

Under identical encoding, delta synchronization transmits 2.3×–9.7× fewer bytes per sync
than a per-sync full snapshot across all 14 cell pairs (rooms 10–500, monsters, active players). The saving is largest where most of
the tree is unchanged each tick (rooms axis ≈ 90%, monster cap 4 ≈ 85%) and settles at
≈ 56% when nearly every entity changes every tick (monster cap 100, and the whole
active-player axis): even then delta pays only for the changed *fields* of each entity
(position, rotation) while a snapshot resends every field of every entity. The re-run delta
cells reproduce the archived `single-room-entity-scaling` numbers within ±0.9%, so the
baseline is compared against exactly the data the paper already reports.

## Caveats

- Not varied: encoding (MessagePack PathHash only — a JSON × full-snapshot cell would only
  compound two known-bad choices), `ticksPerSync`, iterations, machine, interest
  management / sync scope (all cells use the hero-defense global-broadcast scope).
- `full-snapshot` is a measurement baseline, not a production mode; it re-sends the full
  view even on ticks with no change, which is exactly what a naive snapshot protocol does.
- `avg_cost_per_sync_ms` is a single-run, in-process timing on a laptop; the two strategies
  are within noise of each other on most cells and no claim is made from it.
- **Why the rooms-axis delta cells differ from the paper's Table VI.** The 2026-01-25 Table VI
  archive (4,572 / 13,612 / 22,713 B, commit `92dd620`) reproduces exactly on this machine, so
  the gap is code, not hardware. Landmark re-runs on the same machine give 5,002 B at commit
  `db694e1~1` (2026-02-08) and 5,063 B from 2026-08 onwards; the paper's own Table IX
  (2026-02-06, 100 rooms) already implies 4,985 B per 10 rooms. The step between 01-25 and
  02-06 coincides with the opcode-107 wire-format change (state update and server events
  merged into one MessagePack frame, `4423693`), which affects only the MessagePack path —
  consistent with the JSON-object per-room figure being unchanged across all three
  measurements (1,763 / 1,755 / 1,809 B). Table VI and Table IX in the paper were therefore
  measured under different wire formats; the "Table VI replacement" and "Table IX replacement" above re-measure every
  row of both tables at one commit (`d2c647b`) and should replace them wholesale; the
  per-room figures now agree between 10 and 100 rooms within 0.4%. The PR #47
  determinism fix is **not** the cause (5,063 B is already observed at `e119b04`, the commit
  before it).
- Prior to PR #53 the default extraction path (`USE_SNAPSHOT_FOR_SYNC` unset) could seed the
  diff cache incompletely (fixed in `ed9b80e`); this topic and `single-room-entity-scaling`
  both use `USE_SNAPSHOT_FOR_SYNC=false`, which was never affected, and the drift table
  above confirms it.
