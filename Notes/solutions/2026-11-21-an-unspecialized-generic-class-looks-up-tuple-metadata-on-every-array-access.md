---
title: "An unspecialized generic class looks up tuple metadata on every array access"
module: SwiftStateTurns
date: 2026-11-21
problem_type: performance_collapse
component: turn-lane
symptoms:
  - "a cheap locked read (`isEmpty`) costs hundreds of instructions per call"
  - "perf shows `swift::LockingConcurrentMap<TupleCacheEntry>` and `swift_getTupleTypeMetadata` near the top"
  - "a generic class's methods are @usableFromInline, not @inlinable, so callers in other modules run the unspecialized body"
root_cause: an_unspecialized_generic_class_storing_an_array_of_tuples_resolves_the_tuple_metadata_at_run_time_on_each_access
resolution_type: code_fix
severity: medium
tags:
  - turns
  - performance
  - generics
  - specialization
  - metadata
  - lock
related:
  - "#725"
---

# An unspecialized generic class looks up tuple metadata on every array access

## Problem

`TurnLane<Report>` keeps `reports: [(sequence: UInt64, report: Report)]` behind an `NSLock`. Its methods are `@usableFromInline` but not `@inlinable`, because the lock and the storage are private, so a caller in another module runs the unspecialized generic body. With the lane on and empty, a dirty `emit` cost about +1030 instructions per op over the same machine with the lane off. Most of that came from two `isEmpty` reads and one more in the segment's epilogue.

## Root cause

In the unspecialized body, `reports.count` needs the metadata of `Array<(UInt64, Report)>`, which needs the metadata of the tuple `(UInt64, Report)`. Tuple metadata for a generic element is looked up at run time through the runtime's tuple cache, a locked concurrent map. That ran on every access. A profile of the lane-on `emit` cell showed `LockingConcurrentMap<TupleCacheEntry>` at 14 % and `pthread_mutex_lock` at 16 %.

## Fix

- `TurnLane` keeps `count` as a plain `Int`, updated under the lock, so `isEmpty` and the capacity check touch no generic storage.
- The epilogue reads the lane only after a spent budget (plan §3.3), which drops one lock round trip per entry.

Together, the lane-on cost fell from about +1030 to +396 instructions per `emit` (`TurnsLaneBench`, `perf stat -e instructions:u`).

## Prevention

- In a generic type whose hot methods can't be `@inlinable`, keep what the hot path reads (counts, flags, sequence numbers) in concrete stored properties, not derived from generic collections.
- Profile with `perf record -e instructions:u` and look for `swift_get*Metadata` and `MetadataCache` frames before tuning locks.
