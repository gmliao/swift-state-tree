# Entity-delta baseline (Quake 3–style) on the hero-defense workload

Status: open (plan rev 1, for review before implementation).

## Question

On the same simulation, with the same per-player visible state at the same sync frequency, how many bytes, how much encode/decode CPU and how much memory does a conventional entity-delta snapshot protocol need, compared with SST's sync output? The baseline follows the Quake 3 design: entity slots, per-entity-type field tables, a changed-field bitmask per entity, and a delta against the client's last acknowledged snapshot. Over a reliable, ordered transport the acknowledged snapshot is the previous one sent, so every frame is a delta against the previous frame for that client.

This plan covers that baseline (B2). A second baseline built on `@colyseus/schema` (B1, bytes only) is a separate plan.

## What is shared and what is replaced

- **Shared:** the hero-defense simulation as `EncodingBenchmark` runs it (same cells, same seeds, same room and player IDs, same ticks per sync), and each player's projection after each sync: `SyncEngine.snapshot(for:from:mode: .all)`, the values the `--capture-views` gate already compares against.
- **Replaced:** only the sync layer. B2 takes each player's projection at each sync and encodes it against the previous projection sent to that player. SST's diff, patch encoding and transport aren't involved.

So the comparison is projection in, bytes out, on identical inputs.

## Design

### Entities

A projection is split into entities:
- one root entity (the top-level scalar fields: `score`, and `base`'s fields as nested leaf paths);
- one entity per child of each keyed collection (`players`, `monsters`, `turrets`), keyed by `(collection, key)`.

Each entity is a map from leaf path to leaf value. Atomic values (`Position2`, `Angle`) are leaves of their components (`position.v.x`, `position.v.y`), the same values SST sends after the atomic encoding.

### Frame

Per player, per sync, one frame:
1. field definitions new to this stream (entity type, leaf path), once per path;
2. removed entities: their slot numbers;
3. created entities: slot number, entity type, key;
4. changed entities: slot, changed-field bitmask (varint over the type's field table), then the changed values in field order.

Slots are reused after removal (lowest free first), like Quake 3's entity numbers. New fields and new entities are emitted in a canonical sorted order, so the bytes of a deterministic run don't depend on hash order (unlike SST's dynamic-key slots today, #292).

### Value coding

Byte-aligned, as SST's MessagePack is:
- integers: zigzag varint;
- floating point: float32 when the value round-trips exactly through `Float`, else float64; a tag says which;
- strings: varint length plus UTF-8;
- null, booleans, empty object and absent each a one-byte tag.

Quake 3 packs values at bit level with per-field widths. A bit-packed variant would mostly measure a value-coding choice that SST doesn't make either, so it is out of this plan; the README states that a bit-packed implementation would be smaller.

### Field tables in band

Field definitions travel in the stream (step 1 of the frame), so the baseline needs no schema compiled into the client. Their cost lands almost entirely on the first frame, which is reported separately from the steady state. The rejected alternative, tables derived from the schema on both sides, saves those first-frame bytes and changes nothing after them.

### One encoder state per client

Each client has its own encoder state (field tables, slot map, last values), as in Quake 3, and its frame is encoded for that client alone. In hero-defense every player's projection is the same, so B2 encodes the same content once per recipient where SST encodes a broadcast once. The CPU metric counts every per-client encode; the README states this difference.

### Server events

SST's frames also carry the land's server events (opcode 107 merges them into the state frame). B2 carries no events. To compare state bytes on equal terms, both sides run the cells with server events turned off by an `Examples/`-only benchmark switch (events don't change the state). The SST rows with events on stay the main SST rows; the events-off SST rows exist only for this comparison.

## Correctness gate

The client decoder is a separate TypeScript implementation in `Examples/GameDemo/ws-loadtest/` (`src/entity-delta.ts`), not a Swift round trip in the encoder's process. `EncodingBenchmark --baseline entity-delta --capture-views <dir>` writes the same capture format as SST's runs: per sync, every frame with its recipient, and every player's projection. The header records `format: "entity-delta"`. `verify-views` decodes those frames with the TypeScript decoder, rebuilds each recipient's state, and compares it with that player's projection after every sync, with the same `compareStates`. Any difference, decode error, or trailing byte fails the cell.

The capture pass is separate from the measured pass, as for SST, since computing every projection for the gate costs time.

## Metrics

Per cell, matching `deep-research/snapshot-baseline/` where a metric already exists:
- `bytes_per_sync`: the sum over recipients of each recipient's frame at one sync (the room-level aggregate used there), steady state (syncs after the first); the first sync's bytes separately, as `first_sync_bytes`;
- `encode_us_per_sync`: server-side time per sync to encode every recipient's frame, from the projections; the projection extraction time separately (`project_us_per_sync`), since both protocols need the projection and SST's own figure includes its extraction;
- `decode_us_per_frame`: client decode plus apply, with `time-decode` (TypeScript SDK side for SST, the TypeScript decoder for B2), median pass;
- `encoder_state_bytes`: the size of every client's encoder state at the end of the run (field tables, slot maps, last values), computed from the entries; and the process RSS before and after the measured pass.

Formal numbers come only from the measurement host, release build, on the frozen commit. Mac runs check correctness and the tooling only.

## Cells

The snapshot-baseline matrix: rooms 10/30/50/100/300/500 (5 players, natural spawn), monster cap 4/10/50/100 (1 room, 5 idle players), active players 5/10/20/50 (1 room, cap 4). Same iterations (200) and ticks per sync (2).

## Where the code goes

All of it under `Examples/GameDemo/`, so it lands on `main` directly:
- `Sources/EncodingBenchmark/EntityDeltaBaseline.swift`: entity split, encoder, per-client state, metrics;
- `EncodingBenchmark` flag `--baseline entity-delta`, wired into the multi-room and single-room runs;
- the events-off switch for the benchmark only;
- `ws-loadtest/src/entity-delta.ts`, its use in `verify-views` and `time-decode`, and tests: frames produced by the Swift encoder in a fixture, decoded and compared; a mutant check that a dropped changed-field bit or a reused slot that isn't cleared fails the gate.

If any of it turns out to need `Sources/`, that part goes through a PR.

## Steps

1. Encoder and capture output; TypeScript decoder; `verify-views` on the Mac for every cell (debug build is enough for correctness).
2. Metrics in the result JSON; `time-decode` support.
3. Topic `deep-research/entity-delta-baseline/`: `run.sh`, `collect.py`, `regenerate.py` in the snapshot-baseline pattern; README with the question, environment, commands, matrix, results, conclusion, caveats.
4. Host run after the refreeze; tables.

## Caveats to carry into the README

- Byte-aligned value coding; a bit-packed Quake 3 implementation would be smaller.
- One encode per client, no broadcast sharing (as Quake 3 does it).
- Field tables in band; their cost is in `first_sync_bytes`.
- State only: both sides without server events for the comparison.
- The baseline requires a fixed entity model (top-level keyed collections of flat records); deeper nesting is flattened into leaf paths. Hero-defense fits it.

## Reference

A throwaway feasibility check (never merged) encoded one active-player room this way and reached about 147 B per player per sync, with its round trip equal to the projection at every sync. That check predates SST's atomic value encoding and the capture gate. This plan reimplements it with the gate and the full matrix.
