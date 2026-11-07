---
module: EncodingBenchmark, deep-research/snapshot-baseline
date: 2026-11-07
problem_type: measurement_pitfall
component: room-count consistency check
symptoms:
  - "Per-room bytes per sync differ between 10 and 100 rooms for one sync strategy but not another"
  - "A 'same per room at every room count' check fails systematically, the same in every repeat"
root_cause: identifiers_carry_the_room_index
resolution_type: methodology
severity: low
tags:
  - measurement
  - benchmark
  - encoding
  - methodology
---

# Per-room bytes grow with identifier length when a strategy resends the IDs

## Problem

The snapshot baseline checks that per-room bytes per sync agree between 10 and 100 rooms within 0.5 %. Delta passed (0.27 %); full snapshot failed by 0.63 %, identically in three repeats.

## Root cause

The benchmark's player IDs carry the room index (`room<i>-player-<j>`), so the mean ID length grows with the number of rooms: 1 index digit at 10 rooms, 1.9 at 100, 2.78 at 500. A full snapshot resends every player's ID as a string key in every recipient's snapshot every sync; delta sends a slot number after the first use. Fitting full-snapshot per-room bytes per sync at 10, 30, 50, 100, 300 and 500 rooms against the mean number of index digits gave 26.00 B per extra digit (R² 0.9995, residuals within ±0.5 B). A capture of rooms 9 and 10 shows 25 occurrences of a room-indexed ID per sync (5 players' IDs in each of 5 recipients' snapshots); the remaining byte is within the room-to-room variation of the game state, which moves the delta rows by up to 1.4 B per room. Delta per room shows no trend with the digits.

## Fix

The check is per strategy: it applies to strategies whose bytes don't resend identifiers (delta). For full snapshot, report the identifier-length term and check the residual after removing it. Room IDs stay as they are (zero-padding them would change the workload against earlier baselines).

## Prevention

- Before comparing per-unit sizes across scales, check what in the payload scales with the scale itself: identifiers, indices, counters printed as text.
- A consistency bound across room counts is a statement about one strategy's wire form; say which, and why it holds there.
