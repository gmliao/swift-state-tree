---
module: SwiftStateTree
date: 2026-11-10
problem_type: testing_practice
component: sync-diff
symptoms:
  - "a new diff passes every hand-written case but disagrees with the old one after a few hundred random steps"
  - "the old diff sets a whole field (`/rows`) where the new one sets one row (`/rows/-3`)"
  - "the same patches in a different order: one key spelled `é` (NFC) on one side and `e` + U+0301 (NFD) on the other"
root_cause: old_diff_behaviour_depends_on_its_cache_history
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - differential
  - sync-diff
  - unicode
  - dirty-tracking
related:
  - "#443"
---

# A diff replacement must match the old diff's quirks, found by a differential test

## Problem

The typed broadcast diff (flat storage step 2, #443) replaces `SyncEngine`'s snapshot diff, and it must send the same patches. Hand-written cases passed. A random differential test against the old diff then failed twice. Both times the cause was behaviour of the old diff that depends on what its cache went through, not on the two states being compared.

## Root cause

**An empty dirty set replaces the cache.** `computeBroadcastDiffFromSnapshot` with `.dirtyTracking([])` takes the branch for "no dirty tracking" and stores the current snapshot as the whole cache. In dirty mode that snapshot is empty, so every field later counts as added and is set whole. The adapter never makes that call, since it maps an empty dirty set to `.all` (`TransportAdapter.swift`, broadcast mode in the sync extraction), but a harness that does is measuring something the server never runs.

**A key is addressed by its cached spelling.** Swift's `String` equality is canonical equivalence, so a dictionary holds `é` (NFC) and `e` + U+0301 (NFD) as one key. The old diff walks `Set(oldObject.keys).union(newObject.keys)`, so a key present on both sides takes the cached spelling, and the next cache takes the live spelling. Bytes on the wire follow those spellings.

## Fix

- **The harness plans like the adapter:** no dirty field means `.all`.
- **The typed diff addresses a key on both sides by its last-sent spelling** (`old.index(forKey:)`). It rewrites a row whose key spelling changed, so last-sent takes the live spelling as the old cache does.
- **One case is left out:** a value map keeps the spelling of its last change. The differential test leaves out keys in two spellings there, and the PR records the gap.

## Prevention

- **Replace a diff (or any stateful encoder) behind a differential test against the old one.** Run random mutation sequences, with failed plans and carried dirty fields, and compare every step. Print the seed and replay it from an environment variable. The cases you would think to write by hand are the ones that already agree.
- **Drive both sides the way production does.** A mode or argument the production caller never uses can make the old side do something odd. Then the comparison fails on a path that doesn't exist.
- **When a dictionary key is a `String`, decide whose spelling is addressed.** Equality and bytes differ for canonically equivalent keys. The wire carries bytes, so a key index compares with `String` equality, and the address takes an explicit spelling.
