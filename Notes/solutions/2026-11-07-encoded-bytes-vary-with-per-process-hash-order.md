---
module: SwiftStateTreeTransport (state-update encoders), EncodingBenchmark
date: 2026-11-07
problem_type: measurement_pitfall
component: dynamic-key slot assignment
symptoms:
  - "The same benchmark cell, repeated, gives totalBytes a few dozen bytes apart"
  - "bytesPerSync is equal across repeats but totalBytes isn't"
  - "Only cells with many dynamic keys (high monster caps) differ"
root_cause: per_process_hash_order_feeds_slot_assignment
resolution_type: methodology
severity: medium
tags:
  - measurement
  - determinism
  - encoding
  - dynamic-keys
  - benchmark
related:
  - "https://github.com/gmliao/swift-state-tree/issues/292"
---

# Encoded bytes vary run to run when a per-process hash order feeds slot assignment

## Problem

Three repeats of the snapshot-baseline sweep gave byte-identical results in every cell but two: the monster-cap-50 and cap-100 delta cells differed by 55–60 bytes in about 1.3 and 2.5 MB. `bytesPerSync` (rounded) was equal; `totalBytes` wasn't. Replay determinism rests on the sync output being deterministic, so it mattered whether the game, the diff or only the encoding varied.

## Root cause

The diff produces patches in dictionary order (`SyncEngine` iterates a `Set` of keys), and Swift seeds its hasher per process. The state-update encoders assign dynamic-key slots in the order they first meet each key (`DynamicKeyTable.getSlot`), so two keys first seen in the same sync can swap slots between runs. A swap changes the size only when the two slots straddle a MessagePack integer-width boundary (127/128, 255/256) and the keys are later referenced a different number of times. The table never frees a slot, so only lands that create more than 127 dynamic keys show it: over 200 syncs the cap-10 cell creates 63 monster keys, cap 50 creates 211, cap 100 creates 413.

Checked on one cell (cap-50 delta, 200 syncs):

- `SWIFT_DETERMINISTIC_HASHING=1`, 8 runs: one `totalBytes` value, 8 of 8.
- Default hashing, 8 runs: four values, 1,272,255 to 1,272,515 bytes.
- Default hashing, 4 runs with `--capture-views`: the players' projections after every sync are identical in all four (one hash), while the frame bytes differ in every run.

So the game and the synced content are deterministic; only the encoding of the same patches varies.

## Fix

#292: before encoding a frame, the opcode encoders reserve every dynamic key it uses (`DynamicKeyTable.reserve`); the frame's new keys get their slots in UTF-8 byte order and are still defined at first use. A frame's slots now depend on the set of its new keys, not their order, so encoded **sizes** are the same across runs. Byte order within a frame still follows the diff's patch order, so bytes are not guaranteed identical. Tables made before #292 report bytes as identical up to dynamic-key slot assignment, with each cell's spread.

## Prevention

- Say "the sync output's content is deterministic (canonical patch lists)", never "the encoded bytes are identical across runs". Compare runs with `CanonicalPatchList`, which orders patches canonically and ignores slots and frame order, not with encoded bytes.
- Since #292, a "sizes identical across repeats" check is exact; a "bytes identical" check is exact only with `SWIFT_DETERMINISTIC_HASHING=1` (patch order within a frame still varies). For runs made before #292, allow the slot spread, and check that it disappears with deterministic hashing before calling a difference a bug.
- Two adapters in one process have different seeds too, so a test that runs the same script on two adapters (for example dirty tracking on and off) sees both kinds of order vary: a frame's patch order, and the interleaving of sends across sessions. Compare per recipient, in that recipient's order, and decode a differing frame to compare its entries as a multiset (`DirtyTrackingByteIdentityTests`, #391).
- When a byte count differs between runs of a deterministic workload, look for an order that comes from hashing (a `Set` or `Dictionary` iteration) feeding something stateful, such as a table, an ID or a cache.
