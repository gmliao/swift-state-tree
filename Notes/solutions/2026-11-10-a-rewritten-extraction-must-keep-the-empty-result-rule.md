---
module: SwiftStateTreeTransport
date: 2026-11-10
problem_type: bug_class
component: sync-extraction
symptoms:
  - "an extra empty firstSync frame per session after a key scope reset"
  - "frame counts differ between two sync paths while every patch is the same"
  - "byte-identity passes on lands with per-player fields and fails on a land without them"
root_cause: empty_entry_instead_of_no_entry
resolution_type: code_fix
severity: medium
tags:
  - sync
  - extraction
  - per-player
  - byte-identity
  - equivalence-tests
  - testing
related:
  - "#443"
---

# A rewritten extraction must keep the old path's empty-result rule

## Problem

The broadcast diff moved to the typed sync tables behind a switch, and the per-player fields
stayed on the snapshot path. With the switch on, the adapter no longer calls the one-pass
extraction (`snapshotForSync`), which returned both parts, so the per-player part was extracted
on its own, one `extractPerPlayerSnapshot` per player. The frames had to stay byte-identical.

On a land whose state has no per-player fields, each session got one extra frame whenever a plan
reset the key scopes: an empty per-player `firstSync`.

## Root cause

The two extractions disagree on "nothing to extract":

- The macro's `snapshotForSync` creates a per-player entry only when the state has per-player
  fields. Without any, `perPlayer` is an empty dictionary, and the plan skips the per-player
  update of every recipient (`collectPerPlayerOnlyPendingUpdates` has no snapshot to diff).
- `extractPerPlayerSnapshot` returns a snapshot for every player it is asked about, empty when
  there is nothing. An empty snapshot is still an entry, so an update is planned, and a key scope
  reset types it `firstSync` and sends it even without patches.

"No entry" and "an empty entry" are different inputs to the code that follows, although both
hold no values.

## Fix

Beside the tables, the per-player extraction follows the one-pass rules exactly
(`extractSyncSnapshots` in `TransportAdapter.swift`): every per-player field of every player, no
entry at all when the state has no per-player fields, and the separate per-field extraction when
a dirty broadcast field or a per-player field throws, as `extractWithSnapshotForSync` falls back.

## Prevention

- When a rewrite replaces a function that returns a collection, write down what the old one
  returns when there is nothing: an empty collection, an entry with an empty value, or nil. The
  callers usually branch on it.
- Equivalence fixtures need a state with **no fields in a category** (no per-player fields, no
  broadcast fields, no dynamic keys), not only states that have some of each. Here the cells over
  states with per-player fields and both E2E suites passed; the shape matrix land, which has
  none, found the difference (`SyncTablesLandCellTests`).
- Compare frame counts per recipient before comparing bytes, and report the first differing
  frame. Equal patches with unequal counts point at planning, not at the diff.
