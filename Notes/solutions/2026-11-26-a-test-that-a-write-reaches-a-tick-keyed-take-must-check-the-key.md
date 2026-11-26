---
title: "A test that a write reaches a tick-keyed take must check that the key it writes is one a turn takes"
module: SwiftStateTree
date: 2026-11-26
problem_type: testing_practice
component: land-keeper
symptoms:
  - "a handler's sync request or event, written outside a tick, never goes out on a tick land"
  - "a planned test says the request 'reaches the take', and the table still holds the key after the turn"
root_cause: write_keyed_on_a_tick_no_turn_takes
resolution_type: established_pattern
severity: medium
tags:
  - sync
  - events
  - testing
  - turns
related:
  - "#66"
  - "#700"
---

# A test that a write reaches a tick-keyed take must check that the key it writes is one a turn takes

## Problem

The K2 plan's draft test T5 (K2 plan §4.4) said that `requestSyncNow` and `requestSyncBroadcastOnly` from CanJoin and the sync handler "reach the turn's `takeSyncRequest`". Review found they don't on a tick land:
- the contexts of CanJoin and of the sync handler are keyed on `lastCommittedTickId`;
- a tick turn takes only its own tick's key, `nextTickId`'s.

So the requests, and CanJoin's events, stay in `syncRequestsByTick` and `emittedEvents` live, under a key no turn takes (#66's class). A test written to the plan's wording would have checked that the table holds the request, which it does, and passed.

## Root cause

`syncRequestsByTick` and the emitted events are tables keyed by tick, and a turn takes one key. Whether a write is ever taken depends on which key the writer's context captured, not on the write. "The request is in the table" and "a turn takes it" are different claims.

## Fix

T5 became a golden: after a run, the table equals P-K2E-1's output, the keys no turn takes included. P-K2E-1 prints every key left in both tables after each turn. The stranding itself is #66's to fix.

## Prevention

- For a write into a tick-keyed table, assert the key the writer used and that a turn took it: the table is empty of that key after the turn. Presence alone proves nothing.
- Print every key left after a turn when probing such a table.
