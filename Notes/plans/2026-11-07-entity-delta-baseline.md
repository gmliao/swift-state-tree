# Entity-delta baseline (Quake 3–style) on the hero-defense workload

Status: open (plan rev 2; rev 1 was 2540101a). Steps 1–3 done: the encoder, decoder and gate, the metrics, and the topic `deep-research/entity-delta-baseline/` (scripts, no results). Step 4, the measurement host run, waits for the refreeze.

## Question

On the same simulation, with the same per-player visible state at the same sync frequency, how many bytes, how much encode/decode CPU and how much memory does a conventional entity-delta snapshot protocol need, compared with SST's sync output? The baseline follows the Quake 3 design: entity slots, per-entity-type field tables, a changed-field bitmask per entity, and a delta against the client's last acknowledged snapshot. Over a reliable, ordered transport the acknowledged snapshot is the previous one sent, so every frame is a delta against the previous frame for that client.

This plan covers that baseline (B2). A second baseline built on `@colyseus/schema` (B1, bytes only) is a separate plan; the events-off switch below applies to it too.

## What is shared and what is replaced

- **Shared:** the hero-defense simulation as `EncodingBenchmark` runs it (same cells, same seeds, same room and player IDs, same warm-up, same ticks per sync), and each player's projection after each sync: `SyncEngine.snapshot(for:from:mode: .all)`, the values the `--capture-views` gate already compares against.
- **Replaced:** only the sync layer. B2 takes each player's full projection at each sync and encodes it against the previous projection sent to that player, as Quake 3 builds a full snapshot per client per frame. SST doesn't build a full projection per sync: it diffs from dirty tracking. So the CPU comparison is B2's projection plus encode against SST's whole sync (below), not part against part.

The SST adapter keeps running in a B2 cell (it drives nothing in the state), and B2 times only its own spans.

## SST rows compared

`messagepack-pathhash` (opcode MessagePack), delta strategy, at the frozen commit, with the path-index setting that commit ships as default; the README names both the commit and the setting. Every SST row in the comparison is rerun at that commit with the same flags, events on and events off.

## Design

### Entities

A projection is split into entities:
- one root entity (the top-level scalar fields: `score`, and `base`'s fields as nested leaf paths);
- one entity per child of each keyed collection (`players`, `monsters`, `turrets`), keyed by `(collection, key)`.

Each entity is a map from leaf path to leaf value. Atomic values (`Position2`, `Angle`) are leaves of their components (`position.v.x`, `position.v.y`), the values SST sends after the atomic encoding.

### Frame

Per player, per sync, one frame:
1. field definitions new to this stream (entity type, leaf path), once per path;
2. removed entities: their slot numbers;
3. created entities: slot number, entity type, key;
4. changed entities: slot, changed-field bitmask (varint over the type's field table), then the changed values in field order.

Removals come before creations, so a slot freed in a frame can be reused in it. Slots are reused lowest free first, like Quake 3's entity numbers. New fields and new entities are emitted in a canonical sorted order, so the bytes of a deterministic run don't depend on hash order (unlike SST's dynamic-key slots today, #292).

### Value coding

Byte-aligned, as SST's MessagePack is: integers as zigzag varints; strings as varint length plus UTF-8; null, booleans, empty object and absent as one-byte tags. Floating point would be float32 when exact and float64 otherwise, but hero-defense's synced numbers are all fixed-point integers, so that branch never runs in these cells.

The value writer sits behind one interface (`EntityDeltaValueWriter`, and its reader on the TypeScript side), so a bit-packed writer can replace the byte-aligned one without touching the entity, slot or mask logic.

**Bit-packing bound.** Quake 3 packs values at bit level with fixed per-field widths. Instead of a second codec, the encoder computes a bound from the same frames: for each field, the width that covers every value it took in the run (the observed range, zigzag); for each frame, the sum over changed values of their field's width, plus the bitmask as one bit per table field, plus slot numbers at the width the run's highest slot needs, plus the counts. Reported as `bytes_per_sync_bitpacked_bound`, the same unit as `bytes_per_sync`. It's a lower bound on what a fixed-width bit packing of these frames would send (field widths chosen with hindsight), so "a bit-packed implementation would be smaller" becomes "at most this much smaller, for fixed per-field widths". Quake 3's codec also sends some values (zero, for example) in fewer bits than its field's width, which can go below this bound for some fields; the README says so. Whether to build the bit-packed codec is decided from that number.

### Field tables in band

Field definitions travel in the stream (step 1 of the frame), so the baseline needs no schema compiled into the client. Their cost lands on the first frame, reported apart from the steady state. SST's schema travels out of band (fetched once, not in the sync stream), so the first-sync figures aren't like for like; the README says so.

### Per-client encode, and a shared-encode variant

Each client has its own encoder state (field tables, slot map, last values), as in Quake 3, and the CPU figure `encode_us_per_room_sync` counts an encode per client. Over a reliable, ordered transport, two clients with the same encoder state and the same projection get byte-identical frames, so a server can encode once per distinct (encoder state, projection) pair. In hero-defense every projection is the same, so the per-client figure grows with players for no reason. The encoder also reports `encode_shared_us_per_room_sync`: clients grouped by a hash of their encoder state and projection, one encode per group, the frame reused for the rest (the bytes don't change, since every client still receives its frame).

SST's figure is reported both ways too: its sync with the broadcast encoded once (as it runs), and per client, from the per-player path (`SYNC_STRATEGY` unchanged, broadcast sharing off) if the frozen commit has a switch for it; if it hasn't, the README says that only the shared figure exists for SST.

### Server events

SST's frames also carry the land's server events (opcode 107 merges them into the state frame). B2 carries no events. To compare state bytes on equal terms, both sides run the cells with server events turned off by an `Examples/`-only benchmark switch. The SST rows with events on are reported next to the comparison, with both rows' bytes, so the events' share is visible.

The switch must not change the state: for one cell per axis, the capture gate also checks that every player's projection hash is the same at every sync with events on and off.

### Compression

Q3 Huffman-coded its packets, and WebSocket can run permessage-deflate. Both sides get a compressed-bytes column, `bytes_per_room_sync_deflate`: each recipient's frames compressed in order with one raw-deflate context per recipient (context takeover, as permessage-deflate does it), payload bytes after compression. It is computed offline from the capture, so the measured pass doesn't change. The capture covers the first `--capture-rooms` rooms (default 10) only, so the column is per room over the captured rooms (bytes per room per sync, mean over the captured rooms), shown next to the per-room `bytes_per_sync`, not a full-cell sum.

## Correctness gate

The client decoder is a separate TypeScript implementation in `Examples/GameDemo/ws-loadtest/` (`src/entity-delta.ts`), not a Swift round trip in the encoder's process. `EncodingBenchmark --baseline entity-delta --capture-views <dir>` writes the same capture format as SST's runs: per sync, every frame with its recipient, and every player's projection; the header records `format: "entity-delta"`. `verify-views` decodes those frames with the TypeScript decoder, rebuilds each recipient's state, and compares it with that player's projection after every sync, with the same `compareStates`. Any difference, decode error, or trailing byte fails the cell. Mutants that must fail it: a dropped changed-field bit; a reused slot whose old values aren't cleared; a removal applied after the creations.

The capture pass is separate from the measured pass, as for SST, since computing every projection for the gate costs time.

## Metrics: what one unit counts

They match `deep-research/snapshot-baseline/`, where a metric already exists there.

- `bytes_per_sync`: frame payload bytes (no WebSocket or TCP framing; SST's figure counts the same, the bytes handed to the transport), summed over every recipient of every room in the cell, divided by the measured syncs (200). The measured window starts after the joins, the initial sync and the warm-up flush, as for SST. The per-room column divides by the room count. No client joins during the window, so every frame in it is a delta.
- `first_sync_bytes`: the bytes of each recipient's first frame (from an empty baseline, field tables included), summed the same way. It sits outside the measured window, like SST's join and initial sync.
- `bytes_per_sync_bitpacked_bound`: the same unit as `bytes_per_sync`.
- `bytes_per_room_sync_deflate`: per room per sync over the captured rooms (see Compression), next to the per-room `bytes_per_sync`.
- `encode_us_per_room_sync`: wall time on one thread (serial runs only), per room per sync: B2's projection extraction plus encoding every recipient's frame. Its parts are reported separately (`project_us_per_room_sync`, `encode_only_us_per_room_sync`). The SST figure it's compared with is `syncMs` (the time in `syncNow()` alone, serial) per room per sync, which covers SST's whole sync output.
- `encode_shared_us_per_room_sync`: the same, with one encode per distinct (encoder state, projection) pair.
- `decode_us_per_frame`: µs per recipient frame, decode plus apply, as `time-decode` measures: in each pass, the stream's total time divided by its frames; the figure is the median over passes after the warm-up passes. TypeScript on both sides: the SDK for SST, `entity-delta.ts` for B2.
- Memory: `encoder_state_bytes` counts B2's per-client state by a fixed rule (per field-table entry its path's UTF-8 bytes plus 8; per slot entry its key's UTF-8 bytes plus 16; per stored value 9 bytes), B2-only, since SST's caches aren't counted by the same rule. The comparison across both uses the process RSS after the measured pass minus before it, which is noisy and reported as such.

Formal numbers come only from the measurement host, release build, on the frozen commit. Mac runs check correctness and the tooling only.

## Cells

The snapshot-baseline matrix: rooms 10/30/50/100/300/500 (5 players, natural spawn), monster cap 4/10/50/100 (1 room, 5 idle players), active players 5/10/20/50 (1 room, cap 4). Same iterations (200) and ticks per sync (2).

## Where the code goes

All of it under `Examples/GameDemo/`, so it lands on `main` directly:
- `Sources/EncodingBenchmark/EntityDeltaBaseline.swift`: entity split, encoder, value writer, per-client state, shared-encode grouping, bit-packing bound, metrics;
- `EncodingBenchmark` flags `--baseline entity-delta` and `--no-server-events`, wired into the hero-defense multi-room run;
- the events-off switch itself, for benchmark use only;
- `ws-loadtest/src/entity-delta.ts`, its use in `verify-views` and `time-decode`, the deflate column, and tests: frames produced by the Swift encoder in a fixture, decoded and compared, and the mutants above.

If any of it turns out to need `Sources/`, that part goes through a PR.

## Steps

1. Encoder and capture output; TypeScript decoder; `verify-views` on the Mac for every cell (debug build is enough for correctness); the events-on/off projection check.
2. Metrics in the result JSON; `time-decode` and the deflate column.
3. Topic `deep-research/entity-delta-baseline/`: `run.sh`, `collect.py`, `regenerate.py` in the snapshot-baseline pattern; README with the question, environment, commands, matrix, results, conclusion, caveats.
4. Host run after the refreeze; tables.

## Caveats to carry into the README

- Byte-aligned value coding, with the bit-packing bound next to it.
- Per-client encode as in Quake 3, and the shared-encode figure.
- Field tables in band, SST's schema out of band: first-sync figures aren't like for like.
- State only: both sides without server events for the comparison; the events-on SST rows beside it.
- Bytes before and after deflate.
- The baseline requires a fixed entity model (top-level keyed collections of flat records); deeper nesting is flattened into leaf paths. Hero-defense fits it.

## Reference

A throwaway feasibility check (never merged) encoded one active-player room this way and reached about 147 B per player per sync, with its round trip equal to the projection at every sync. That check predates SST's atomic value encoding and the capture gate. This plan reimplements it with the gate and the full matrix.
