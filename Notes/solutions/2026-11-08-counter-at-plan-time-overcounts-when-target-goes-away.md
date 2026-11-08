---
module: Examples/GameDemo (ServerLoadTest)
date: 2026-11-08
problem_type: measurement_pitfall
component: load-generator-counters
symptoms:
  - "the records hold fewer inputs than totalActionsCompleted"
  - "record check failed: recordedActions != actionsCompleted"
  - "actions completed in a ramp-down second although every session closed in it"
root_cause: counter_incremented_for_work_whose_target_was_removed_between_plan_and_send
resolution_type: code_fix
severity: low
tags:
  - measurement
  - load-test
  - counters
  - ramp-down
  - methodology
related:
  - "#127"
---

# A counter incremented at plan or send time overcounts when the target goes away in between

## Problem

A recomputation-cost smoke (2 players per room, 4 rooms, 1 s ramp-down) recorded 160 client
events while ServerLoadTest reported `totalActionsCompleted` = 192. The 32 missing ones are one
ramp-down second's worth (8 players × 4 per second), and the records held exactly the steady
phase's 160.

## Root cause

In the paced path (`--pacing spread|aligned`, since #127), `ClientSimulator.planSecond` planned a
ramp-down second's actions from the joined sessions, then closed that second's sessions, and
returned the plan; the sends ran afterwards. Actions planned for a closing session reached it
closed and were dropped, but `actionCompleted()` counts a send when `handleIncomingMessage`
returns, which it does for a closed session too. The legacy path awaited its actions before it
closed sessions, so it never showed this.

## Fix

`LoadTestPacing.rampDownPeriod(joined:closeCount:)` splits the joined sessions into the ones a
ramp-down second closes and the ones its actions go to; `planSecond` closes the first and plans
actions only for the second. The topic's action rate now uses the steady seconds'
`actionsCompletedThisSecond`, not the total over the steady duration, and its record check counts
client events as well as actions.

Published data was not affected: every committed ServerLoadTest result predates the paced path,
and no report derived a figure from `totalActionsCompleted` that includes ramp-down seconds.

## Prevention

- A counter named for completion has to count completion: if it is incremented when work is
  planned or handed over, anything that removes the target in between (a close, a leave, a
  shutdown) makes it overcount. Decide the targets after the removal, or count on the receiver.
- Cross-check a client-side count against what the server recorded at least once per tool
  (here the record check: recorded inputs equal actions completed). A one-second ramp-down makes
  the gap large enough to see.
- Report rates over the steady window from per-second samples, not from a run total.
- `LoadTestPacingTests` pins that a ramp-down period's action targets exclude the sessions it
  closes; the recomputation-cost record check pins the totals end to end.
