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

Filled from the results' `meta` when the measurement host's sweep lands: the commit, Swift and
node versions, build configuration (release), CPU and pinning. Mac runs check correctness and
the tooling only; their numbers aren't in this README.

## Command(s)

```bash
REPEAT=1 ./run.sh                    # one sweep: every cell, three variants, capture passes
REPEAT=2 ORDER=b2-first CAPTURE=0 ./run.sh
python3 collect.py                   # raw/<RUN_ID>/ → results/<run-id>.json
python3 regenerate.py --markdown     # the tables below
python3 regenerate.py --check        # OK when the README's Results match the results
python3 test_topic.py                # run.sh's dry run, collect.py, regenerate.py (no build)
python3 test_projhash.py             # projhash.py on a capture-shaped directory
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
  Metrics).

## Results

_No results yet: the measurement host's run fills this section._

## Conclusion

None yet: the sweep hasn't run on the measurement host.

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
  noisy, and covers SST's sync running in the same process.
