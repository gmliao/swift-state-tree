---
title: "Keeping a copy, then `removeAll(keepingCapacity:)`, allocates"
module: SwiftStateTurns
date: 2026-11-21
problem_type: gotcha
component: turn-driver
symptoms:
  - "A capture written as `let copy = array; array.removeAll(keepingCapacity: true)` allocates a buffer on every call"
  - "A per-job or per-step path that used to be allocation-free starts allocating after a refactor that keeps a copy of a collection"
root_cause: remove_all_keeping_capacity_on_a_shared_buffer_allocates
resolution_type: code_fix
severity: medium
tags:
  - copy-on-write
  - allocation
  - keepingCapacity
  - turns
  - performance
related:
  - "#725"
  - "#738"
---

# Keeping a copy, then `removeAll(keepingCapacity:)`, allocates

## Problem

The post lane's revision made `continueBatch` capture its due follow-ups before the lane's take, so an `.afterBatch` follow-up a report arms steps in the next job. The first version kept a copy, then emptied the original:

```swift
var due = core.rt.dueFollowUps
core.rt.dueFollowUps.removeAll(keepingCapacity: true)
```

That runs on every continuation job of every machine with follow-ups, lane or not, on a path that was allocation-free.

## Root cause

`due` and `core.rt.dueFollowUps` share one buffer after the copy. `removeAll(keepingCapacity: true)` on a non-unique buffer can't empty it in place, because `due` still reads it. It allocates a fresh buffer of the same capacity instead. The keep-capacity flag, meant to avoid reallocating, is what forces the allocation here.

## Fix

Move the buffer instead of sharing it: `swap(&due, &core.rt.dueFollowUps)`, then give it back after the take, with anything armed meanwhile appended. Machines that can't arm a follow-up from a report (no lane) keep the original code, which pushes and empties in place (`Sources/SwiftStateTurns/TurnActor.swift`, `continueBatch`).

## Prevention

- To take a collection's contents and keep its capacity, swap it out (or iterate and empty it in place). Don't copy it, then `removeAll(keepingCapacity: true)` the original.
- When a refactor changes a shared hot path only to serve one feature, keep the old code on the branch the static gate (`usesLane`, `usesFollowUps`) selects for machines without the feature, so their cost can't move.
