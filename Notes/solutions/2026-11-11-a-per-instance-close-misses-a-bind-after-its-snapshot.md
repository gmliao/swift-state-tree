---
module: SwiftStateTreeTransport
date: 2026-11-11
problem_type: bug_class
component: land-router
symptoms:
  - "A land stop closes every session bound to the instance, yet one session stays bound to the stopped instance"
  - "A join that looked up the land before the stop binds to it after the stop's session list was taken"
  - "A session is admitted to an instance that is about to be destroyed"
  - "A host shutdown during a land stop destroys the instance before the stop's leaves run, so OnLeave is skipped"
root_cause: per_instance_close_snapshot_without_a_mark_the_bind_checks
resolution_type: design_rule
severity: medium
tags:
  - reentrancy
  - router
  - land-stop
  - snapshot
  - bind
  - shutdown
related:
  - "#102"
---

# A per-instance close misses a bind after its snapshot

## Problem

Stopping one land instance (the admin `DELETE /admin/lands/:landID`, #102) closes the sessions bound to that instance: it takes the list of bound sessions and runs each one's leave and close. A join that looked up the instance's container before the stop, and was suspended at an `await` before its bind, binds after the list was taken. It isn't in the list, so it is never closed, and it stays bound to an instance that is then destroyed.

## Root cause

The list is a snapshot of state that a concurrent call can still add to. The join's lookup and its bind are in different actor segments (the lookup awaits the manager), so "the instance is live" was true when the join checked it and false when it acted. A snapshot alone doesn't stop later additions; it needs a mark that the adding side checks.

## Fix

`LandRouter.closeSessions(boundTo:close:)` records the epoch in `closingEpochs` and takes the snapshot in one synchronous segment. The join's bind checks `closingEpochs` for the container's epoch in the segment where it binds, and refuses the join (`landShuttingDown`) if it's marked. Every bind for that instance then happens either before the mark (and is in the snapshot) or after it (and is refused). The mark goes once the instance is destroyed (`endClosing`): a bind after that is refused at admission by the destroyed keeper.

**The other side of the same snapshot.** The stop removes its sessions from the router, so a host shutdown that starts during the stop doesn't find them in its own snapshot, and its destroy step could destroy the instance before the stop's leaves ran. The stop counts its sessions in `disconnectForwardsInFlight`, the counter the shutdown's sessions step already waits on, from the removal's segment until each leave has run.

## Prevention

- A "close everything in X" operation sets a mark on X and takes its snapshot in the same segment, and every "add to X" checks the mark in the segment where it adds. A snapshot with no mark is a check-then-act across the adder's `await` (see [Check, await, act](2026-11-05-await-resumes-on-stale-state.md)).
- An operation that takes entries out of a shared registry hides them from every other snapshot of it. If another path (a shutdown) must still wait for their work, count them, in the removal's segment, in the in-flight counter that path waits on, and lower it as each one's work ends.
- Test it with a hold, not timing: hold the join after its lookup (`LandRouterHoldPoint.afterLand`), let the close take its snapshot (`.stopSnapshot`), release the join, and expect it refused and unbound (`LandStopTests.joinRacingTheStopIsRefused`). The mutant without the bind's check leaves the session bound.
- For the counter: hold the stop after its removal (`.stopSnapshot`), start the shutdown, wait for whichever comes first, the shutdown's wait for in-flight leaves or the destroy, then release, and expect the leave before the destroy (`LandStopTests.shutdownDuringStopKeepsItsLeaves`).
