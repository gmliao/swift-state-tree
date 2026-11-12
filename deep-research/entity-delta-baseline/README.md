# Entity-delta baseline

## Question

On the same hero-defense simulation, with the same per-player visible state at the same sync
frequency, how many bytes, how much server CPU, how much client decode time and how much
encoder memory does a conventional entity-delta snapshot protocol (Quake 3–style: entity slots,
per-type field tables, a changed-field mask per entity, a delta against the previous frame sent
to that client) need, compared with SST's sync output? And the same for `@colyseus/schema`, a widely used state-sync
library, declared and driven as a Colyseus server would for this state?

The design, its metric definitions and the alternatives rejected are in
`Notes/plans/2026-11-07-entity-delta-baseline.md`. The entity-delta baseline is called B2 below,
the `@colyseus/schema` one B1.

## Environment

The measured commit, its dirty flag, the Swift and Node versions and the build configuration open
the Results section: `regenerate.py` writes that line from the results' `meta` and refuses
results with no commit, from more than one commit, or from a dirty tree (`--check` verifies it
with the tables). The measurement host runs pinned (`run.sh`). Mac runs check correctness and the
tooling only; their numbers aren't in this README.

## Command(s)

```bash
REPEAT=1 ./run.sh                    # one sweep: every cell, three variants, capture passes
REPEAT=2 ORDER=b2-first CAPTURE=0 ./run.sh
STATE_ONLY=1 ./run.sh                # SST's sync state by the counting rule, from one capture pass per cell
python3 collect.py                   # raw/<RUN_ID>/ → results/<run-id>.json, results/state/<run-id>.json
python3 regenerate.py --markdown     # the tables below
python3 regenerate.py --check        # OK when the README's Results match the results
python3 test_topic.py                # run.sh's dry run, collect.py, regenerate.py (no build)
python3 test_projhash.py             # projhash.py on a capture-shaped directory
python3 test_stateshape.py           # stateshape.py's counting rule on a capture-shaped directory
```

`DRY_RUN=1 REPEAT=1 ./run.sh` prints every command without running anything. `run.sh`'s header
lists every option.

Every cell runs three variants as separate processes, back to back:
- `sst-events`: SST as it ships (`messagepack-pathhash`, delta strategy, server events on);
- `sst`: the same with server events off (`--no-server-events`);
- `b2`: `--baseline entity-delta --no-server-events`. The SST sync still runs in that process,
  and B2 times only its own spans.

B1 (`@colyseus/schema` 5.0.42, pinned in `Examples/GameDemo/ws-loadtest/package-lock.json`) has
no Swift side. In the `sst` variant's capture pass, `ws-loadtest`'s `colyseus-baseline` converter
turns that capture's projections into B1's frames, in two typings: `b1`, every number declared
`number` (Colyseus's default), and `b1-tuned`, each field the narrowest fixed type covering the
values it took in the run. One encoder per room (every player's projection is the same in
hero-defense; the converter refuses otherwise), each frame to every client; the gate decodes
with Colyseus's own `Decoder`.

After each measured variant, a capture pass reruns it with `--capture-views`. `verify-views`
checks every recipient's rebuilt state against its projection after every sync: the SDK's
reconstruction for SST, the separate TypeScript decoder (`ws-loadtest/src/entity-delta.ts`) for
B2. `time-decode` times the client decode and computes the bytes per room before and after
permessage-deflate. `regenerate.py` refuses results whose gate failed, whose decode figures
come from an unverified time-decode run (a dirty tree, or the SDK and benchmark at different
commits), whose sweep ran from a dirty tree, whose build isn't release or has no Swift version, an SST
result not in the intended wire form (the path index and field merge on, the defaults since #308, read from the
EncodingBenchmark metadata and resolved with `deep-research/wireform.py`; B1 and B2 are other encoders and aren't gated), a matrix that lacks a cell or one
of repeats 1 and 2 in a cell (a partial matrix isn't rendered), whose cell lacks a measured variant in some repeat or a B1 variant in a
repeat that captured, or whose captured projections differ between variants.

## Parameter matrix

| Axis | Values | Fixed |
|---|---|---|
| Rooms | 10, 30, 50, 100, 300, 500 | 5 players per room, natural spawn |
| Monster cap | 4, 10, 50, 100 | 1 room, 5 idle players |
| Active players | 5, 10, 20, 50 | 1 room, monster cap 4, every player moves every tick |

Every cell: 200 measured syncs, 2 ticks per sync, serial sync (`--parallel false`),
the shipped sync path (every server variable unset, below), SST format `messagepack-pathhash` with the delta strategy, the
same seeds and the same room and player IDs as `deep-research/snapshot-baseline`.

**The sync path.** `run.sh` unsets every server variable (`deep-research/serverenv.py`), so a run takes the shipped sync path (`USE_SNAPSHOT_FOR_SYNC` unset); `run.json` records them and `regenerate.py` refuses a run with any set. The sync path doesn't change what is sent: with `USE_SNAPSHOT_FOR_SYNC=false` and unset, every frame's length and every recipient's projection after every sync were equal, and both captures passed `verify-views` (at e8692a37, one cell per variant: snapshot-baseline monster cap 4 delta and full-snapshot and 10 rooms delta, entity-delta-baseline monster cap 4 sst-events, sst and b2, visibility default cell radius and all; 1,005 to 10,015 frames per cell; as negative controls, sst vs sst-events and delta vs full-snapshot differ in frame lengths). Frames aren't byte-identical, nor are two runs of either path: the order of entries within a frame varies between processes (#314).

Metric units (from the plan):
- `bytes_per_sync`: frame payload bytes (no WebSocket or TCP framing) summed over every
  recipient of every room, divided by the 200 measured syncs. The window starts after the joins,
  the initial sync and the warm-up flush.
- `first_sync_bytes` (B2): every recipient's first frame, field tables included, outside the
  window.
- `bytes_per_sync_bitpacked_bound` (B2): the bytes a fixed-width bit packing of the same frames
  would need at least, with each field's width chosen with hindsight (the run's observed range).
- `bytes_per_room_sync_deflate`: per room per measured sync over the captured rooms (the first
  10 at most), each recipient's whole stream compressed in order with one raw-deflate context,
  as `ws` runs permessage-deflate by default.
- `sync_us_per_room_sync` (SST): time in `syncNow()` alone, serial, per room per sync.
- `encode_us_per_room_sync` (B2): projection plus one encode per client, serial, per room per
  sync. `encode_shared_us_per_room_sync`: one encode per group of clients with the same encoder
  state and projection.
- `decode_apply_us_per_frame`: client decode plus apply in Node (the SDK for SST,
  `entity-delta.ts` for B2, Colyseus's `Decoder.decode` for B1), per recipient frame, the median
  pass after the warm-up passes. The gate's mapping back to the projection's shape isn't timed.
- B1: `bytes_per_room_sync_captured` and `bytes_per_room_sync_deflate` only (no all-rooms
  figure: the capture holds the first 10 rooms at most), `first_sync_bytes_per_room` (the join
  state, `encodeAll()`), and `encode_us_per_room_sync_node`, recorded but not tabled (Node
  against Swift isn't like for like).
- `encoder_state_bytes` (B2): the per-client encoder state by a fixed counting rule (plan,
  Metrics): per field-table entry its path's UTF-8 bytes plus 8, per slot entry its key's UTF-8
  bytes plus 16, per stored value 9 bytes; summed over every client of every room.
- SST's sync state (`results/state/`, `stateshape.py`): what SST keeps for a land's sync, counted
  by the same rule, constant for constant. SST keeps one broadcast snapshot per room (the fields
  whose policy is broadcast), one per-player snapshot per client (every other synced field:
  masked, perPlayer and perPlayerSlice), and, with the path-hash formats and dynamic-key
  compression on, one dynamic-key table per scope (the room's broadcast frames, and each client's
  per-player frames): a key string and its slot, never freed, recreated when the encoder sends a
  firstSync or resync in that scope. Every keyed entry of a snapshot (a struct field or a map entry, both entries of a
  `[String: SnapshotValue]` dictionary) counts B2's slot-entry constant (its key's UTF-8 bytes
  plus 16), every leaf value B2's stored-value constant (9 bytes), and every dynamic-key table
  entry the slot-entry constant. B2's field-table term has no SST counterpart: SST keeps no
  per-client field table (the paths and their hashes are the schema's, shared by every
  connection). Not counted on either side: the schema's path-index table, the transport and
  adapter's per-session bookkeeping (outbound writers, sync-lag ack state, tickets), the recorder,
  and scratch buffers. The figures come from a capture pass (`STATE_ONLY=1`, or any captured
  sweep's `sst` variant): each player's projection after the last sync is the same snapshot tree
  SST caches, and the dynamic-key tables are replayed from the captured frames as the encoder
  fills them: the keys each scope's frames define (`[slot, "key"]`, which the encoder sends only
  for a key on an encoded patch path), emptied at that scope's firstSync or resync. A slot a frame
  uses before its scope defines it fails the count. The
  tables show it in B2's scope (every client of every room: the shared part once per room, the
  per-client part once per client) and per client, with and without the client's share of its
  room's shared part.

## Results

Provenance, from the results' meta: commit `75222b87eb008b1ad94e99d7ae96b83528c9d0a4`, clean tree; Swift 6.2.4 (SST and B2 runs); Node v24.22.2; build release (SST and B2 runs).

Medians over 2 repeat(s) (1, 2). B2 is the entity-delta baseline; SST and B2 run with server events off, `SST events on` is SST as it ships. SST's wire form: messagepack-pathhash, pathIndex on, fieldMerge on (checked per run).

### Rooms axis (5 players per room, natural spawn)

Bytes per sync (every recipient of every room, measured window):

| Cell | SST events on | SST | B2 | B2 / SST | B2 bit-packed bound | B2 first sync | B2 encoder state (B) | SST sync state (B) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rooms 10 | 2,680 | 2,327 | 1,713 | 0.74 | 1,091 | 27,700 | 64,090 | 32,620 |
| rooms 30 | 8,023 | 6,929 | 5,101 | 0.74 | 3,251 | 83,600 | 190,610 | 97,860 |
| rooms 50 | 13,367 | 11,562 | 8,511 | 0.74 | 5,425 | 139,500 | 320,010 | 163,100 |
| rooms 100 | 26,756 | 23,143 | 17,043 | 0.74 | 10,861 | 279,250 | 643,150 | 326,200 |
| rooms 300 | 80,329 | 69,344 | 51,054 | 0.74 | 32,539 | 843,250 | 1,933,510 | 978,600 |
| rooms 500 | 133,926 | 115,582 | 85,104 | 0.74 | 54,240 | 1,407,250 | 3,229,630 | 1,631,000 |

Sync state by one counting rule (bytes; README, Metrics): B2's per-client encoder state, and SST's state shared by a room (the broadcast snapshot and its dynamic-key table) and kept per client (the per-player snapshot and its table), with the shared part divided over the room's clients:

| Cell | B2 per client | SST shared per room | SST per client | SST per client, with its share |
|---|---:|---:|---:|---:|
| rooms 10 | 1,282 | 3,262 | 0 | 652 |
| rooms 30 | 1,271 | 3,262 | 0 | 652 |
| rooms 50 | 1,280 | 3,262 | 0 | 652 |
| rooms 100 | 1,286 | 3,262 | 0 | 652 |
| rooms 300 | 1,289 | 3,262 | 0 | 652 |
| rooms 500 | 1,292 | 3,262 | 0 | 652 |

SST per client is 0 in these cells because Hero Defense declares only broadcast and serverOnly fields; a land with perPlayer, perPlayerSlice or masked fields keeps per-client state as well.

Bytes per room per sync over the same captured rooms, before and after permessage-deflate (B1 is `@colyseus/schema`: `number` is every number declared `number`, `tuned` each field the narrowest fixed type covering the run's values):

| Cell | SST | SST deflate | B2 | B2 deflate | B1 number | B1 number deflate | B1 tuned | B1 tuned deflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rooms 10 | 232.7 | 142.4 | 171.3 | 143.8 | 177.7 | 135.7 | 187.0 | 147.9 |
| rooms 30 | 232.7 | 142.7 | 171.3 | 143.8 | 177.7 | 135.7 | 187.0 | 147.9 |
| rooms 50 | 232.7 | 142.8 | 171.3 | 143.8 | 177.7 | 135.7 | 187.0 | 147.9 |
| rooms 100 | 232.7 | 142.2 | 171.3 | 143.8 | 177.7 | 135.7 | 187.0 | 147.9 |
| rooms 300 | 232.7 | 142.5 | 171.3 | 143.8 | 177.7 | 135.7 | 187.0 | 147.9 |
| rooms 500 | 232.7 | 142.6 | 171.3 | 143.8 | 177.7 | 135.7 | 187.0 | 147.9 |

Captured rooms against every room, per room per sync (whether the captured rooms are representative):

| Cell | SST captured | SST all rooms | B2 captured | B2 all rooms |
|---|---:|---:|---:|---:|
| rooms 10 | 232.7 | 232.7 | 171.3 | 171.3 |
| rooms 30 | 232.7 | 231.0 | 171.3 | 170.0 |
| rooms 50 | 232.7 | 231.2 | 171.3 | 170.2 |
| rooms 100 | 232.7 | 231.4 | 171.3 | 170.4 |
| rooms 300 | 232.7 | 231.1 | 171.3 | 170.2 |
| rooms 500 | 232.7 | 231.2 | 171.3 | 170.2 |

Server CPU per room per sync (µs, serial; SST: `syncNow()`; B2: projection plus encode):

| Cell | SST sync | B2 project | B2 encode per client | B2 total per client | B2 encode shared | B2 total shared |
|---|---:|---:|---:|---:|---:|---:|
| rooms 10 | 118.0 | 212.9 | 98.8 | 311.7 | 33.5 | 246.4 |
| rooms 30 | 116.2 | 210.0 | 98.1 | 308.1 | 33.2 | 243.1 |
| rooms 50 | 115.9 | 210.1 | 98.1 | 308.2 | 33.2 | 243.3 |
| rooms 100 | 116.3 | 212.4 | 101.2 | 313.6 | 33.9 | 246.2 |
| rooms 300 | 120.0 | 215.0 | 106.0 | 321.0 | 34.9 | 249.9 |
| rooms 500 | 122.1 | 214.8 | 107.7 | 322.5 | 35.1 | 249.9 |

Client decode per frame (µs, Node; B2's and B1's decoders apply while they parse, so they have decode plus apply only):

| Cell | SST decode | SST decode + apply | B2 decode + apply | B1 number decode + apply | B1 tuned decode + apply |
|---|---:|---:|---:|---:|---:|
| rooms 10 | 2.01 | 5.58 | 0.43 | 0.80 | 0.86 |
| rooms 30 | 1.96 | 5.59 | 0.40 | 0.82 | 0.84 |
| rooms 50 | 1.95 | 5.57 | 0.41 | 0.79 | 0.86 |
| rooms 100 | 1.97 | 5.62 | 0.41 | 0.80 | 0.87 |
| rooms 300 | 1.94 | 5.57 | 0.45 | 0.79 | 0.84 |
| rooms 500 | 1.96 | 5.59 | 0.41 | 0.80 | 0.87 |

### Monster axis (1 room, 5 idle players)

Bytes per sync (every recipient of every room, measured window):

| Cell | SST events on | SST | B2 | B2 / SST | B2 bit-packed bound | B2 first sync | B2 encoder state (B) | SST sync state (B) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| monster cap 4 | 426 | 364 | 268 | 0.74 | 168 | 3,105 | 6,625 | 3,701 |
| monster cap 10 | 1,031 | 874 | 640 | 0.73 | 386 | 3,805 | 8,785 | 5,939 |
| monster cap 50 | 4,427 | 4,146 | 3,057 | 0.74 | 1,864 | 8,665 | 23,435 | 19,125 |
| monster cap 100 | 8,768 | 8,485 | 6,021 | 0.71 | 3,725 | 14,965 | 41,685 | 35,963 |

Sync state by one counting rule (bytes; README, Metrics): B2's per-client encoder state, and SST's state shared by a room (the broadcast snapshot and its dynamic-key table) and kept per client (the per-player snapshot and its table), with the shared part divided over the room's clients:

| Cell | B2 per client | SST shared per room | SST per client | SST per client, with its share |
|---|---:|---:|---:|---:|
| monster cap 4 | 1,325 | 3,701 | 0 | 740 |
| monster cap 10 | 1,757 | 5,939 | 0 | 1,188 |
| monster cap 50 | 4,687 | 19,125 | 0 | 3,825 |
| monster cap 100 | 8,337 | 35,963 | 0 | 7,193 |

Bytes per room per sync over the same captured rooms, before and after permessage-deflate (B1 is `@colyseus/schema`: `number` is every number declared `number`, `tuned` each field the narrowest fixed type covering the run's values):

| Cell | SST | SST deflate | B2 | B2 deflate | B1 number | B1 number deflate | B1 tuned | B1 tuned deflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| monster cap 4 | 363.5 | 225.1 | 268.2 | 220.1 | 288.8 | 217.2 | 309.1 | 225.5 |
| monster cap 10 | 873.7 | 535.8 | 640.0 | 535.2 | 726.2 | 527.2 | 762.5 | 528.2 |
| monster cap 50 | 4,146.0 | 2,504.1 | 3,057.4 | 2,311.5 | 3,606.9 | 2,403.2 | 3,809.1 | 2,367.3 |
| monster cap 100 | 8,485.1 | 4,756.4 | 6,020.5 | 4,393.3 | 7,475.8 | 4,554.3 | 7,854.1 | 4,518.6 |

Captured rooms against every room, per room per sync (whether the captured rooms are representative):

| Cell | SST captured | SST all rooms | B2 captured | B2 all rooms |
|---|---:|---:|---:|---:|
| monster cap 4 | 363.5 | 363.5 | 268.2 | 268.2 |
| monster cap 10 | 873.7 | 873.7 | 640.0 | 640.0 |
| monster cap 50 | 4,146.0 | 4,146.0 | 3,057.4 | 3,057.4 |
| monster cap 100 | 8,485.1 | 8,485.1 | 6,020.5 | 6,020.5 |

Server CPU per room per sync (µs, serial; SST: `syncNow()`; B2: projection plus encode):

| Cell | SST sync | B2 project | B2 encode per client | B2 total per client | B2 encode shared | B2 total shared |
|---|---:|---:|---:|---:|---:|---:|
| monster cap 4 | 151.5 | 259.2 | 116.4 | 375.6 | 39.1 | 298.3 |
| monster cap 10 | 232.1 | 398.4 | 189.8 | 588.2 | 61.1 | 459.5 |
| monster cap 50 | 889.8 | 1,309.7 | 936.1 | 2,245.8 | 259.2 | 1,568.9 |
| monster cap 100 | 1,463.8 | 2,442.8 | 1,824.0 | 4,266.8 | 496.4 | 2,939.2 |

Client decode per frame (µs, Node; B2's and B1's decoders apply while they parse, so they have decode plus apply only):

| Cell | SST decode | SST decode + apply | B2 decode + apply | B1 number decode + apply | B1 tuned decode + apply |
|---|---:|---:|---:|---:|---:|
| monster cap 4 | 3.26 | 9.32 | 0.91 | 1.40 | 1.44 |
| monster cap 10 | 6.87 | 21.17 | 1.82 | 3.16 | 3.15 |
| monster cap 50 | 30.68 | 99.45 | 7.39 | 13.74 | 14.50 |
| monster cap 100 | 62.37 | 199.18 | 14.44 | 27.14 | 28.90 |

### Active-player axis (1 room, monster cap 4, every player moves every tick)

Bytes per sync (every recipient of every room, measured window):

| Cell | SST events on | SST | B2 | B2 / SST | B2 bit-packed bound | B2 first sync | B2 encoder state (B) | SST sync state (B) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| players 5 | 1,066 | 1,003 | 832 | 0.83 | 490 | 3,105 | 7,335 | 4,001 |
| players 10 | 3,474 | 3,336 | 2,797 | 0.84 | 1,651 | 8,280 | 20,670 | 6,252 |
| players 20 | 12,238 | 11,970 | 10,144 | 0.85 | 6,011 | 25,000 | 65,540 | 10,684 |
| players 50 | 69,958 | 69,264 | 59,448 | 0.86 | 35,436 | 125,350 | 345,350 | 24,052 |

Sync state by one counting rule (bytes; README, Metrics): B2's per-client encoder state, and SST's state shared by a room (the broadcast snapshot and its dynamic-key table) and kept per client (the per-player snapshot and its table), with the shared part divided over the room's clients:

| Cell | B2 per client | SST shared per room | SST per client | SST per client, with its share |
|---|---:|---:|---:|---:|
| players 5 | 1,467 | 4,001 | 0 | 800 |
| players 10 | 2,067 | 6,252 | 0 | 625 |
| players 20 | 3,277 | 10,684 | 0 | 534 |
| players 50 | 6,907 | 24,052 | 0 | 481 |

Bytes per room per sync over the same captured rooms, before and after permessage-deflate (B1 is `@colyseus/schema`: `number` is every number declared `number`, `tuned` each field the narrowest fixed type covering the run's values):

| Cell | SST | SST deflate | B2 | B2 deflate | B1 number | B1 number deflate | B1 tuned | B1 tuned deflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| players 5 | 1,003.3 | 623.8 | 832.4 | 640.6 | 906.3 | 649.1 | 926.2 | 617.9 |
| players 10 | 3,335.8 | 2,065.8 | 2,796.8 | 2,076.6 | 3,088.1 | 2,166.1 | 3,095.2 | 2,024.3 |
| players 20 | 11,970.1 | 7,406.5 | 10,143.8 | 6,946.5 | 11,241.3 | 7,666.1 | 11,185.3 | 7,162.4 |
| players 50 | 69,264.2 | 38,759.0 | 59,448.5 | 35,280.0 | 65,927.0 | 39,461.5 | 65,475.0 | 36,093.8 |

Captured rooms against every room, per room per sync (whether the captured rooms are representative):

| Cell | SST captured | SST all rooms | B2 captured | B2 all rooms |
|---|---:|---:|---:|---:|
| players 5 | 1,003.3 | 1,003.3 | 832.4 | 832.4 |
| players 10 | 3,335.8 | 3,335.8 | 2,796.8 | 2,796.8 |
| players 20 | 11,970.1 | 11,970.1 | 10,143.8 | 10,143.8 |
| players 50 | 69,264.2 | 69,264.2 | 59,448.5 | 59,448.5 |

Server CPU per room per sync (µs, serial; SST: `syncNow()`; B2: projection plus encode):

| Cell | SST sync | B2 project | B2 encode per client | B2 total per client | B2 encode shared | B2 total shared |
|---|---:|---:|---:|---:|---:|---:|
| players 5 | 239.7 | 257.0 | 145.1 | 402.1 | 45.5 | 302.5 |
| players 10 | 359.8 | 710.2 | 470.6 | 1,180.8 | 104.6 | 814.9 |
| players 20 | 579.9 | 2,222.1 | 1,802.2 | 4,024.2 | 305.2 | 2,527.3 |
| players 50 | 1,274.8 | 11,714.2 | 13,111.7 | 24,825.9 | 1,641.3 | 13,355.4 |

Client decode per frame (µs, Node; B2's and B1's decoders apply while they parse, so they have decode plus apply only):

| Cell | SST decode | SST decode + apply | B2 decode + apply | B1 number decode + apply | B1 tuned decode + apply |
|---|---:|---:|---:|---:|---:|
| players 5 | 8.67 | 28.92 | 1.70 | 3.62 | 3.94 |
| players 10 | 14.27 | 49.56 | 3.00 | 6.01 | 6.28 |
| players 20 | 25.35 | 89.84 | 5.04 | 10.68 | 11.51 |
| players 50 | 59.72 | 212.77 | 11.59 | 25.02 | 26.55 |

## Conclusion

From the Results at `75222b87` (medians over 2 repeats; state only, server events off on both sides):

- **Bytes:** B2, the Quake 3–style entity delta, sends 0.71–0.86 of SST's bytes per sync: 0.74 on
  the rooms axis, 0.71–0.74 on the monster axis, 0.83–0.86 on the active-player axis.
- **After permessage-deflate** the gap closes, and in some cells reverses (bytes per room per
  sync). B2 is above SST on the rooms axis (143.8 against 142.2–142.8; B1 135.7 `number`, 147.9
  `tuned`) and at players 5 and 10 (640.6 against 623.8; 2,076.6 against 2,065.8). It stays below
  on the monster axis (cap 100: 4,393.3 against 4,756.4) and at players 20 and 50 (50: 35,280.0
  against 38,759.0).
- **Server CPU:** SST's sync costs less than B2's projection plus encode in every cell, with B2's
  encode shared or per client: rooms 115.9–122.1 µs against 243.1–249.9 (shared) and 308.1–322.5
  (per client); monster cap 100 1,463.8 against 2,939.2 and 4,266.8; players 50 1,274.8 against
  13,355.4 and 24,825.9.
- **Client decode:** SST's decode plus apply costs more than B2's and B1's in every cell: rooms
  5.57–5.62 µs against B2 0.40–0.45 and B1 0.79–0.87; monster cap 100 199.18 against 14.44 and
  27.14–28.90; players 50 212.77 against 11.59 and 25.02–26.55.
- **Sync state:** SST's state per client, with its share of the room's, is below B2's per-client
  encoder state in every cell (rooms 652 B against 1,271–1,292; monster cap 4 to 100 740–7,193
  against 1,325–8,337; players 5 to 50 800 down to 481 against 1,467–6,907). SST keeps nothing per
  client here only because Hero Defense declares no per-player fields.

The Caveats bound these: B2 is byte-aligned on purpose (its bit-packed bound is lower), the
first-sync figures aren't like for like, and the comparison is state only (the `SST events on`
column is SST as it ships).

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

- B2's values are byte-aligned (varints, tags), on purpose: that is the representation level of
  SST's MessagePack frames, so the two compare what is sent, not how tightly it is packed. The
  comparison places SST's cost against a classic per-client delta scheme; it is not a contest
  for the smallest encoding. There is no bit-packed variant. Instead, the per-field bit-need
  estimate (`bytes_per_sync_bitpacked_bound`) bounds what bit packing could save: in the smoke
  runs it is about 40 % below B2's bytes, so bit packing could cut B2 by up to about 40 %. It is
  an estimate (each field's width chosen with hindsight from the run's range), not a measured
  encoder. Quake 3's codec also sends some values (zero, for example) in fewer bits than the
  field's width, which can go below that bound for some fields.
- B2 encodes per client, as Quake 3 does. The shared-encode figure is shown next to it. SST's
  figure is its sync as it runs, with the broadcast encoded once.
- B2 sends its field tables in band; SST's schema travels out of band, and so do B1's schema
  classes (the decoder takes them from the capture header, as a Colyseus client takes them from
  the reflection handshake at join). So B1's and SST's first-sync figures exclude the schema and
  B2's include its field tables: they aren't like for like.
- The comparison is state only: both sides run with server events off. The events-on SST row
  is shown next to it. `regenerate.py` refuses a cell whose captured projections (every player,
  every sync, hashed by `projhash.py`) differ between `sst-events`, `sst` and `b2`. B1's hash
  holds by construction, since the converter copies the sst capture's projections; it only shows
  that the converted capture kept every sync. B1's check is the gate's decode and compare.
- B2's decoder applies while it parses, so it has no decode-only figure.
- The baseline needs a fixed entity model (top-level keyed collections of flat records); deeper
  nesting is flattened into leaf paths. Hero-defense fits it.
- B1's figures are per room over the captured rooms, next to SST's and B2's over the same rooms;
  a table shows SST's and B2's captured-rooms against all-rooms per-room bytes. No all-rooms B1
  figure is extrapolated. Sweeps with `CAPTURE=0` have no B1.
- B1's `number` isn't a varint: it uses MessagePack's width classes (1, 2, 3 or 5 bytes for an
  integer), as SST's MessagePack does. `tuned` picks each field's type with hindsight, the best a
  fixed declaration could do on that run; neither typing is smaller in every cell.
- B1's encode time runs in Node and isn't compared with the Swift encoders.
- `rss_delta_mib` is in the results but not tabled: it's process RSS around the measured pass,
  noisy, and covers SST's sync running in the same process. The two sync-state columns are counting
  rules, not heap measurements: they compare what each side keeps per client, not what the
  allocator spends on it.

## Reruns from the sync tables default on

From the commit that made the typed sync tables the default and removed the auto dirty switch, EncodingBenchmark runs without `--dirty-tracking` record `dirtyTracking: on`, where the results here record `auto` (which started on, and could switch off). A rerun from then on also runs the broadcast diff on the typed tables with typed leaf values; the frames are the same bytes.
