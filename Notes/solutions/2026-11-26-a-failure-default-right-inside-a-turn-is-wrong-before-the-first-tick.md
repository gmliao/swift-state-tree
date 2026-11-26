---
title: "A failure's default position, right inside a turn, is wrong before a tick land's first tick: derive it where the frame is chosen"
module: SwiftStateTree
date: 2026-11-26
problem_type: bug_class
component: land-keeper
symptoms:
  - "replay of a tick land that failed before its first tick reports a server-event mismatch at tick 0 (`failed(ticks: [0])`)"
  - "the recorded failure has `tickId` nil and `endsInputs` nil, and the live land ran no tick"
  - "a hand fix at one refusal site passes its test, and the same record shape fails at every other site"
root_cause: frame_handler_state_known_only_to_keeper_not_to_call_site
resolution_type: established_pattern
severity: high
tags:
  - replay
  - record
  - failure
  - turns
related:
  - "#901"
  - "#896"
  - "2026-11-26-a-refusal-before-a-handler-must-record-that-it-ended-the-inputs"
---

# A failure's default position, right inside a turn, is wrong before a tick land's first tick: derive it where the frame is chosen

## Problem

`failLand` writes a tick land's terminal entry into the frame `max(nextTickId - 1, 0)`. Replay applies that frame's inputs and skips its tick handler only when the failure says `endsInputs == true`. A failure outside any tick turn (a sync-only turn, a settle, an intake's backstop, the transport mailbox, initialization) took the default, nil. Between ticks that is right: the frame is the last committed tick, whose handler ran. Before the first tick, the frame is 0, no handler ran, and replay ran tick 0's handler anyway. #896 fixed one site (the stale-join refusal) by passing the flag; a probe then found the same mismatch at every other site.

## Root cause

Whether the frame's handler ran is keeper state, not something a call site knows. The earlier fix for refusals inside a tick turn (`2026-11-26-a-refusal-before-a-handler-must-record-that-it-ended-the-inputs`) was per site because each site there knows where it sits in its turn. Outside a tick turn no site does.

## Fix

Decide it in `failLand`, next to the frame: a tick land's frame that hasn't committed (`m.lastCommittedTickId < frame`) never ran its handler, so the failure ends its inputs. A tick turn commits right after its handler step, and every site before that commit already passes `true`, so the rule changes nothing inside a tick. The stale-join site's hand fix was removed.

## Prevention

- When a record's flag depends on what the keeper has done (has a tick run, has the frame committed), compute it where the record's frame is chosen, not at each caller.
- Probe a new class of failure site before and after the first tick, with a recorder, and replay the record. The first tick is the edge where "the frame" and "the last committed tick" stop being the same thing.
