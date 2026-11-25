---
title: "A verdict never checked on one land kind"
module: SwiftStateTree
date: 2026-11-14
problem_type: testing_practice
component: replay-sync-output-verifier
symptoms:
  - "sync output mismatch at tick -1 on a tickless land's replay, for a record whose passes and events verify"
  - "first differing patch: recorded 1 patches, replayed 0"
root_cause: outputs_located_by_observed_tick_and_every_tickless_output_observes_tick_minus_one
resolution_type: design_rule
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

The first fix placed a tick `-1` entry by its read sequence among tick 0's passes. It was wrong, and it was reverted before merge. An input takes its sequence at intake, while a pass's `sequenceBefore` is the counter when its turn starts. An event-free action's output therefore reads at its own pass's `sequenceBefore`, and the next pass can start at the same value, so the sequence can't break the tie. #565 reported a tickless record's sync outputs as `skipped`, with the reason, instead of a false `failed`. Record format 3.4 (#563) places them unambiguously: the live land numbers each tickless pass in the segment that applies it, and every output and seed records the pass it read after (`afterPass`). Replay steps the driver after each pass and locates entries by that number, so a 3.4 tickless record's sync outputs are verified. A tickless record older than 3.4 stays `skipped`, with the reason.

## Prevention

- A verdict that holds for every record kind is tested on every record kind. For replay checks that means a tick land and a tickless land, with in-turn sync on, and the verdict itself asserted, not only the checks around it.
- A position that is constant on one land kind can't locate anything there. When an entry's locator (here `observedTickId`) never changes on a land kind, the check needs a finer one (the read sequence) or must report the record as unverified.
- A locator has to be checked for ties, not only for order: two values that are equal can stand for entries on both sides of a pass. Test the tie on purpose, with an input that emits nothing.
- When no recorded value locates an entry, report it as not verified, never as a mismatch.
- Pinned by `SyncStreamLeaveReplayTests` (3.4 records, three leave cases on each land kind: tick `passed`; tickless `passed`, or `partial` where the leave's own output doesn't address the departed player, listed as unverified) and `TicklessPassOrdinalTests` (the tie itself, a 3.4 tickless record `passed`, a freeze settle's output located by its pass, 3.3 and 3.0 tickless records `skipped`; a driver that locates by tick fails three of them).
