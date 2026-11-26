---
title: "A refusal that ends a turn before its handler must record that it ended the inputs, or replay runs the handler"
module: SwiftStateTree
date: 2026-11-26
problem_type: gotcha
component: land-keeper
symptoms:
  - "replay reports server-event or sync-output mismatches at the tick where the land failed"
  - "a failure's recorded position has `endsInputs` nil although live skipped that tick's handler"
  - "a new `callOut` before a tick's inputs ends the land, and only an unrecorded test passes"
root_cause: failure_position_does_not_say_what_the_failure_skipped
resolution_type: established_pattern
severity: high
tags:
  - replay
  - record
  - failure
  - callout
  - turns
  - reentrancy
related:
  - "#700"
  - "#891"
  - "2026-11-26-a-port-witness-read-through-a-computed-property-bypasses-the-call-out"
---

# A refusal that ends a turn before its handler must record that it ended the inputs, or replay runs the handler

## Problem

K1b-5a step 2 (#891) made the tick turn a turn body. Every port call goes through `callOut`, and a call whose callee re-enters the keeper ends the land in that call. The fold report (`noteInTurnSyncFold`) runs before the tick's inputs. A refusal there ended the land, so live took the failure branch: no inputs, no tick handler, no sync.

The failure was recorded with `endsInputs` nil, though. Replay skips a tick's handler only when the failure's position says `endsInputs == true` (`ReevaluationEngine`, `replayEndsHere`). So replay ran a handler that live never ran, and its events and writes showed up as mismatches. Before the change the fold report had no refusal point: a re-entry there went to the backstop after the handler, and the record stayed consistent.

## Root cause

A failure's position is the record's statement of what the failure cut short. `failLand` records `endsInputs` only when its caller passes it. A new place that can end the land has to say where it sits in the turn: before the handler (it ended the inputs), or after it (the handler ran). `callOut`'s refusal used the default, after the handler, even at a call before it. The nth-call tests ran without a recorder, so nothing compared the record with what live did.

## Fix

Pass the position at each refusal point: `callOut(&m, &side, &outputs, endsInputs: true, appliedInputs: false, …)` for the fold report. On a tick land that records `endsInputs: true` and no pass. Keep `appliedInputs` a separate argument instead of deriving it from `endsInputs`: the join report ends the inputs after a join applied, and the fold report ends them before any.

Pin it two ways: assert `failure?.position.endsInputs` for every site in the nth-call loop, and record one refused tick and replay it with server-event verification.

## Prevention

- When a change adds a point that can end a turn, decide what the record must say the failure skipped, and pass it. A default is right only for the points it was written for.
- Test a new refusal point with a recorder at least once, and replay the record. A test without a recorder checks only the live side.
