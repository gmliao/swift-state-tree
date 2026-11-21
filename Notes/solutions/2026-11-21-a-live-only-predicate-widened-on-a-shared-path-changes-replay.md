---
module: SwiftStateTree (LandKeeper)
date: 2026-11-21
problem_type: logic_error
component: runtime-routing
symptoms:
  - "after a routing change, replays of tickless records report serverEventVerification .failed: the replay emitted no events"
  - "a replay mismatch where the record holds the events and the replayed list is empty"
  - "inTurn arms fail too, although the change looks like it only affects keepers with no port"
root_cause: a_live_only_condition_was_widened_on_a_function_the_reevaluation_keeper_also_runs
resolution_type: code_fix
severity: high
tags:
  - replay
  - reevaluation
  - routing
  - tickless
  - turns
related:
  - "#546"
---

# A live-only predicate widened on a shared path changes replay

## Problem

#546 L2d-2 routes every live keeper through turns. In `runInputTurn` it changed the branch that takes a turn's events and sync request from `!batch.isEmpty, let transport, usesInTurnSync` to `!batch.isEmpty`, so that a portless live turn also drains its output collector and records the events. Afterwards, 14 tickless record-and-replay tests failed. Only their verdict failed (`serverEventVerification`), not their record checks. A mismatch dump showed tick 0 expected `[1, 3, 5]` and actual `[]`: the *replay* emitted nothing. The `inTurn: true` arms failed too, which pointed away from the portless live path.

## Root cause

The re-evaluation keeper replays a tickless pass through the same `runInputTurn`. The old condition was false there, since `usesInTurnSync` requires `mode == .live`, so a replayed pass left its events for the replay's flush to the sink. The widened condition dropped the mode half with the transport half. The replayed turn then took the events into its turn output and, having no port, delivered them nowhere.

## Fix

Keep the mode in the condition: `!batch.isEmpty, routesThroughTurn` (`mode == .live`). Delivery stays under `syncsInTurn`. The replay keeps its own path, and the dropped half is reachable only by live keepers.

## Prevention

- When you split or rename a predicate that combines a mode with something else (`usesInTurnSync` = live ∧ transport opts in), check every function both keeper modes run. A condition that loses its `mode == .live` half changes replay, even when the change is about live keepers.
- A replay test that compares the replayed sink with the record pins it. "Replay runs each pass as an input turn: observable at the turn hold, nothing left over, tick 0" (TicklessReplayPassTests) asserts the replayed sequences equal the recorded ones. The mutant (drop `routesThroughTurn` from the condition) fails it and 13 other replay tests by name.
- Read a failure's arms before guessing: an arm the change shouldn't touch failing (here `inTurn: true`) means the cause is on a path both arms share, often the replay.

## Recurrence (#739 review)

The same PR then deleted the sync loop's trailing `syncNowFromTransport` "because a re-evaluation keeper has no transport". One can: `ReevaluationOutputMode.transportAndSink` is public, and the attach check exempts re-evaluation keepers. Such a keeper kept its broadcast-only syncs and silently lost its periodic `syncNow`. The tail is back for `.reevaluation` until #612, and a test drives one sync loop iteration of such a keeper.

- A premise like "mode X never has Y" needs a check against the public API, not against the callers in this repository. Here a public option made the premise false.
- Deleting a call is the widest change a predicate can make: the call is gone for every mode. List the modes that reach the function before you delete it.
