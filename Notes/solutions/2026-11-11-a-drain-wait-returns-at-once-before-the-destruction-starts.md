---
module: SwiftStateTreeTransport
date: 2026-11-11
problem_type: gotcha
component: land-manager
symptoms:
  - "A join for a land ID that is being stopped gets a second instance beside the old one"
  - "A creation that should wait for the previous instance's destruction goes on at once"
root_cause: wait_on_a_signal_the_awaited_work_has_not_started
resolution_type: design_rule
severity: medium
tags:
  - land-manager
  - drain
  - land-stop
  - wait-signal
  - lost-wakeup
related:
  - "#102"
---

# A drain wait returns at once before the destruction starts

## Problem

A creation for a land ID waits for any previous instance of that ID to finish its destruction (`waitForDrains`, through `keeper.waitUntilDrained()`). A land stop (#102) detaches the instance first, then runs its sessions' leaves, then destroys it. A join during the leaves listed the detached instance, called `waitUntilDrained()`, got an immediate return, and built a second instance beside the one still being stopped.

## Root cause

`waitUntilDrained()` returns at once when no destruction has started. That is the right answer for a keeper that will never be destroyed, and the wrong one for a keeper whose destruction is decided but not yet started. The wait asked "is it draining?" when the question was "is it gone?".

## Fix

A stop marks its detached entry `stopping`. A creation waits for a stopping entry until the manager drops that epoch (`dropDetached`, run by the instance's own `onLandDestroyed`), not for its keeper's drain. Two details make the wait safe:
- **No lost wakeup:** the wait checks that the epoch is still detached and registers its continuation in one manager segment, and the drop removes the entry and resumes its waiters in one segment (the only removal path).
- **No leak on give-up:** a wait that times out or is cancelled removes its own waiter, so a destroy that hangs doesn't collect one per join attempt.

The waiters live in a manager dictionary keyed by (land ID, epoch), not in the entry, so replacing an entry can't lose them.

## Prevention

- Before waiting for "X has finished", check that the signal you await starts when X is decided, not later. If X is decided now but starts later, wait for its end state (the entry's removal), with the check and the registration in one segment.
- Tests: hold the stop between its detach and its destroy, start a join, wait until its creation is parked on the drop (an internal manager callback run in the wait's own segment), then release the stop, and expect the fresh instance published only after the old one's AfterFinalize (`LandStopTests.joinDuringStopWaitsForTheDestroy`). Releasing the stop before the creation parks isn't a test: the creation's own awaits can let the old destroy finish first, and a creation that doesn't wait passes too. Hold the creation after it listed the instance, finish the stop, then release, and expect it to go on at once (`dropBeforeTheWaitIsSeen`).
