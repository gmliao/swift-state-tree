# Single-room entity scaling — bytesPerSync vs. players, monsters and the wire form

## Question

In one hero-defense room, how does `bytesPerSync` grow as the players and the monsters grow (each
alone and together), and how much of the MessagePack path-hash format's size do the path index and
the field merge each save at every point?

## Environment

The measurement host, release build of EncodingBenchmark, CPUs 0-7 pinned. Each result records the
git commit, whether the tree was clean, `swift --version`, the wire knobs the benchmark ran with
(`pathIndex`, `fieldMerge`, `dynamicKeyCompression` in its metadata) and the server environment
run.sh left unset (`run.json` `serverEnv`: every variable that changes what the server sends or how
it syncs, the sync path, the wire knobs, dirty tracking and hero-defense's server events; the list
is `deep-research/serverenv.py`, shared with snapshot-baseline, entity-delta-baseline and visibility). The shipped sync path: `USE_SNAPSHOT_FOR_SYNC` unset,
the delta strategy, serial sync (`--parallel false`).

The 2026-08-31 results (Apple M2, Swift 6.3.2, `USE_SNAPSHOT_FOR_SYNC=false`, before either knob
existed) are kept under `results/pre-refreeze/` with their raw envelopes in `raw/*.json`; see
Pre-refreeze record below.

## Command(s)

```bash
cd deep-research/single-room-entity-scaling
REPEAT=1 bash run.sh && REPEAT=2 bash run.sh   # on the measurement host, at one commit
python3 collect.py && python3 regenerate.py --check
```

`DRY_RUN=1 REPEAT=1 bash run.sh` prints every command. A smoke run off the host:
`CELLS="monsters-cap4 joint" PIN_CPUS= REPEAT=1 RUN_ID=smoke bash run.sh`; `collect.py` skips such a
sweep (CELLS or FORMS) and `regenerate.py` refuses an unpinned or dirty run.

Each cell is one `EncodingBenchmark --scalability --room-counts 1 --iterations 200 --ticks-per-sync 2
--parallel false` per wire form, with the cell's `--players-per-room-list`, `--monster-cap` and
`--active-players`. After each measured run the same run repeats with `--capture-views`, and
ws-loadtest's verify-views checks that every recipient's rebuilt state equals its projection after
every sync: a form whose bytes shrink because it lost information fails there. The gate is
required per (cell, point, form), once: with the bytes identical in every repeat, one passing
capture covers the repeats, so this is equivalent to gating every run.

- `--monster-cap N`: spawn interval 1, refilled to N every tick (clamped by the land), so about N
  monsters live for the whole run (`finalMonsterCount`).
- `--active-players`: every iteration injects a deterministic `MoveTo` event per player through the
  real `handleClientEvent` path, so every player produces a position/rotation diff every tick.

## Parameter matrix

| Cell | players | monster cap | workload |
|---|---|---|---|
| monsters-cap4/10/50/100 | 5 | 4, 10, 50, 100 | idle |
| idle-players | 10, 20, 50 | 4 | idle |
| active-players | 5, 10, 20, 50 | 4 | active |
| joint | 20 | 20 | active |

Wire forms, every cell: `json` (json-object; the knobs don't apply), and messagepack-pathhash with
`--path-index` / `--field-merge` `on-on` (the shipped default), `on-off`, `off-on`, `off-off`.
Two repeats; bytes are deterministic, so `regenerate.py` requires the same bytes in both.

Fixed: rooms 1, ticksPerSync 2 (20 Hz tick, 10 Hz sync), iterations 200, no turrets, dirty
tracking at its default, dynamic key compression on.

`regenerate.py` refuses a result that isn't a clean, pinned release build, whose server environment
isn't the shipped defaults (all of `serverEnv` unset), whose parameters aren't the matrix's, whose
recorded wire form isn't its form label (resolved with `deep-research/wireform.py`), whose
verify-views gate failed or never ran, a point that lacks a form or a repeat, bytes that differ
between repeats, results from more than one commit, and a point where on/on's bytes equal
off/off's, off-on's or on-off's. The metadata records the requested modes, not what the encoder
did; a knob that reaches the encoder changes the bytes at every point of this matrix (each has
repeated paths to index and parents with several changed fields to merge), so equal bytes mean
that knob never reached it, and the point is refused rather than reported as a 0 % saving. No
point is exempt.
The pre-refreeze record must resolve to both knobs off.

## Results

Wire-form ablation at commit 75222b87, the shipped sync path (USE_SNAPSHOT_FOR_SYNC unset), delta strategy, serial sync; bytesPerSync per form (identical in repeats 1, 2). The MsgPack columns are messagepack-pathhash with the path index (PI) and field merge (FM) on or off; on/on is the shipped default. JSON Object is the reference (neither knob applies to it). Saving: on/on against off/off; PI alone and FM alone: that knob on, the other off, against off/off.

### Monster axis (idle, players = 5)

| players | monster cap | JSON Object | MsgPack off/off | PI only | FM only | on/on | saving on/on | saving PI alone | saving FM alone |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 | 4 | 3,014 | 587 | 458 | 512 | 426 | 27.5% | 22.0% | 12.8% |
| 5 | 10 | 7,209 | 1,427 | 1,112 | 1,247 | 1,031 | 27.8% | 22.1% | 12.6% |
| 5 | 50 | 33,156 | 6,362 | 4,838 | 5,463 | 4,427 | 30.4% | 24.0% | 14.1% |
| 5 | 100 | 64,216 | 12,675 | 9,698 | 10,809 | 8,768 | 30.8% | 23.5% | 14.7% |

### Player axis — idle players (monster cap = 4)

| players | monster cap | JSON Object | MsgPack off/off | PI only | FM only | on/on | saving on/on | saving PI alone | saving FM alone |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 | 4 | 3,014 | 587 | 458 | 512 | 426 | 27.5% | 22.0% | 12.8% |
| 10 | 4 | 5,770 | 1,132 | 885 | 999 | 828 | 26.8% | 21.8% | 11.7% |
| 20 | 4 | 12,216 | 2,448 | 1,936 | 2,166 | 1,814 | 25.9% | 20.9% | 11.5% |
| 50 | 4 | 30,587 | 5,958 | 4,667 | 5,233 | 4,355 | 26.9% | 21.7% | 12.2% |

### Player axis — active players (monster cap = 4)

| players | monster cap | JSON Object | MsgPack off/off | PI only | FM only | on/on | saving on/on | saving PI alone | saving FM alone |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 | 4 | 10,186 | 1,708 | 1,284 | 1,248 | 1,066 | 37.6% | 24.9% | 26.9% |
| 10 | 4 | 34,841 | 5,696 | 4,253 | 4,039 | 3,474 | 39.0% | 25.3% | 29.1% |
| 20 | 4 | 128,384 | 20,442 | 15,157 | 14,166 | 12,238 | 40.1% | 25.9% | 30.7% |
| 50 | 4 | 761,929 | 118,985 | 87,764 | 80,782 | 69,958 | 41.2% | 26.2% | 32.1% |

### Joint cell — active, players 20 × monster cap 20

| players | monster cap | JSON Object | MsgPack off/off | PI only | FM only | on/on | saving on/on | saving PI alone | saving FM alone |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 20 | 20 | 172,642 | 29,229 | 21,978 | 21,785 | 18,544 | 36.6% | 24.8% | 25.5% |

### Pre-refreeze record (pathIndex off, fieldMerge off; USE_SNAPSHOT_FOR_SYNC=false; commits 648fce5, 9f65c9e)

Measured on 2026-08-31 before the path index and field merge existed, on the legacy sync path, on a development machine (Apple M2, Swift 6.3.2). Kept as the record of that form, not compared with the tables above.

#### Monster axis (idle, players = 5)

| Format | players | monster cap | final monsters | bytesPerSync |
|---|---:|---:|---:|---:|
| JSON Object | 5 | 4 | 4 | 2954 |
| JSON Object | 5 | 10 | 10 | 7050 |
| JSON Object | 5 | 50 | 50 | 32854 |
| JSON Object | 5 | 100 | 100 | 63941 |
| Opcode MsgPack (PathHash) | 5 | 4 | 4 | 828 |
| Opcode MsgPack (PathHash) | 5 | 10 | 10 | 2032 |
| Opcode MsgPack (PathHash) | 5 | 50 | 50 | 9112 |
| Opcode MsgPack (PathHash) | 5 | 100 | 100 | 18139 |

#### Player axis — idle players (monster cap = 4)

| Format | players | monster cap | final monsters | bytesPerSync | bytes/player |
|---|---:|---:|---:|---:|---:|
| JSON Object | 5 | 4 | 4 | 2954 | 591 |
| JSON Object | 10 | 4 | 4 | 5713 | 571 |
| JSON Object | 20 | 4 | 4 | 11744 | 587 |
| JSON Object | 50 | 4 | 4 | 29415 | 588 |
| Opcode MsgPack (PathHash) | 5 | 4 | 4 | 828 | 166 |
| Opcode MsgPack (PathHash) | 10 | 4 | 4 | 1593 | 159 |
| Opcode MsgPack (PathHash) | 20 | 4 | 4 | 3362 | 168 |
| Opcode MsgPack (PathHash) | 50 | 4 | 4 | 8384 | 168 |

#### Player axis — active players (monster cap = 4)

| Format | players | monster cap | final monsters | bytesPerSync | bytes/player |
|---|---:|---:|---:|---:|---:|
| JSON Object | 5 | 4 | 4 | 10125 | 2025 |
| JSON Object | 10 | 4 | 4 | 34670 | 3467 |
| JSON Object | 20 | 4 | 4 | 128010 | 6400 |
| JSON Object | 50 | 4 | 4 | 760889 | 15218 |
| Opcode MsgPack (PathHash) | 5 | 4 | 4 | 2490 | 498 |
| Opcode MsgPack (PathHash) | 10 | 4 | 4 | 8340 | 834 |
| Opcode MsgPack (PathHash) | 20 | 4 | 4 | 30148 | 1507 |
| Opcode MsgPack (PathHash) | 50 | 4 | 4 | 176264 | 3525 |

#### Joint cell — active, players and monsters raised together

| Format | players | monster cap | final monsters | bytesPerSync | bytes/player |
|---|---:|---:|---:|---:|---:|
| JSON Object | 20 | 4 | 4 | 128010 | 6400 |
| JSON Object | 20 | 20 | 20 | 170634 | 8532 |
| Opcode MsgPack (PathHash) | 20 | 4 | 4 | 30148 | 1507 |
| Opcode MsgPack (PathHash) | 20 | 20 | 20 | 42470 | 2124 |

#### Marginal payload cost per monster (idle, players = 5, cap 4 → 100)

| Format | bytes/monster |
|---|---:|
| JSON Object | 635.3 |
| Opcode MsgPack (PathHash) | 180.3 |

## Conclusion

Wire-form ablation at `75222b87` (the shipped sync path, delta strategy; bytesPerSync identical
in both repeats):

- **Growth, both knobs on:** 426 → 8,768 B as the monster cap goes 4 → 100 (5 idle players),
  426 → 4,355 B as idle players go 5 → 50, and 1,066 → 69,958 B as active players go 5 → 50;
  18,544 B in the joint cell (20 active players, cap 20).
- **Saving of both knobs** over MsgPack off/off: 27.5–30.8 % on the monster axis, 25.9–27.5 % on
  the idle-player axis, 37.6–41.2 % on the active-player axis, 36.6 % in the joint cell.
- **Each alone:** the path index saves 20.9–26.2 % in every cell. The field merge saves
  11.5–14.7 % where players are idle and 25.5–32.1 % where they're active, more than the path index
  on the active-player axis (26.9–32.1 % against 24.9–26.2 %).

Pre-refreeze record (2026-08-31, both knobs off, legacy sync path): `bytesPerSync` was not constant
as the state tree grew; it followed **cost ∝ |changed nodes| × |recipients|**:

- **Monster axis** (changed nodes ↑, 5 recipients): linear, about 635 B per monster in JSON and
  180 B in MsgPack (≈ 28 % of JSON).
- **Idle player axis** (changed nodes ≈ 4 monsters, recipients ↑): linear, with nearly constant
  bytes per player (JSON ~588 B, MsgPack ~166 B).
- **Active player axis** (changed nodes ≈ n, recipients = n): about n² in total; bytes per player
  grow linearly with n (MsgPack 498 → 3,525 B).
- **Joint cell**: going from cap 4 to cap 20 at p20 adds 16 monsters and 12.3 KB in MsgPack, about
  770 B per monster ≈ 20 recipients × ~38 B, the same formula.

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

- **Coupled to `snapshot-baseline`.** That topic's drift table splits its drift with this ablation's
  off-off and on-on forms and requires them at its own commit, with on-on equal to its re-run's bytes.
  Re-running this topic means re-running `snapshot-baseline`.
- **What bytesPerSync counts**: `CountingTransport` adds up the bytes of every `send()`. Every
  session gets its own update, so the figure already includes × recipients: it is the room's
  whole downstream application payload per sync, not one encoded update.
- Active players' `MoveTo` events also put `targetPosition` (a broadcast field) in the diff, as a
  real client would.
- The monster axis uses refill-to-cap, not natural spawning and kills.
- Not varied: ticksPerSync, iterations, turrets (0), rooms (1), dirty tracking (default), dynamic
  key compression (on).
- Pre-refreeze record: its first version (commit `27e2673`) had invalid idle p20/p50 data: the
  hero-defense land hard-coded `MaxPlayers(10)`, and the benchmark silently dropped the extra joins,
  so those rooms held 10 players. Since `9f65c9e` `makeLand(maxPlayers:)` takes the count and the
  benchmark reconciles joins. The record ran on a development machine (Apple M2, macOS) on the
  legacy sync path, one run per cell; compare its tables with the ablation's only for trends.

## Reruns from the sync tables default on

From the commit that made the typed sync tables the default and removed the auto dirty switch, EncodingBenchmark runs without `--dirty-tracking` record `dirtyTracking: on`, where the results here record `auto` (which started on, and could switch off). A rerun from then on also runs the broadcast diff on the typed tables with typed leaf values; the frames are the same bytes.
