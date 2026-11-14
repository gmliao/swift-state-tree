---
module: SwiftStateTree
date: 2026-11-14
problem_type: testing_practice
component: replay-sync-output-verifier
symptoms:
  - "sync output mismatch at tick -1 on a tickless land's replay, for a record whose passes and events verify"
  - "first differing patch: recorded 1 patches, replayed 0"
root_cause: outputs_located_by_observed_tick_and_every_tickless_output_observes_tick_minus_one
resolution_type: code_fix
severity: medium
tags:
  - replay
  - tickless
  - sync-output
  - verifier
  - testing
related:
  - "#563"
  - "#553"
---

# A verdict never checked on one land kind

## Problem

The replay's sync-output check failed every tickless record. The first output after a pass that changed a synced field reported a `hash` mismatch on `broadcast`: the patch was in the record, and missing from the replay. Passes and server events verified, so the record was correct. The check had been wrong since it was written. No test asserted the sync-output verdict on a tickless land; the tickless replay tests checked passes and events only. It came out when a regression test for #553 asked for zero mismatches on both land kinds.

## Root cause

`SyncOutputReplayDriver` located each recorded output and seed by its `observedTickId`, the keeper's last committed tick at the read. A tickless land never commits a tick, so every entry observes `-1`, and the driver compared each with the state after OnInitialize, before any pass ran.

## Fix

A tick `-1` entry of a record with tickless passes is placed by its read sequence among tick 0's recorded passes. A pass numbers at least one input from its `sequenceBefore` on, so a read at sequence S follows exactly the passes that started below S. The engine asks the keeper to keep the replayed state after each pass an entry needs (`setReplayPassStatesNeeded`, `takeReplayPassStates`).

## Prevention

- A verdict that holds for every record kind is tested on every record kind. For replay checks that means a tick land and a tickless land, with in-turn sync on, and the verdict itself asserted, not only the checks around it.
- A position that is constant on one land kind can't locate anything there. When an entry's locator (here `observedTickId`) never changes on a land kind, the check needs a finer one (the read sequence) or must report the record as unverified.
- Pinned by `SyncStreamLeaveReplayTests` (tick and tickless, three leave cases, the verdict `passed`).
