---
module: SwiftStateTreeNIO tests
date: 2026-11-20
problem_type: testing_practice
component: test-fixtures
symptoms:
  - "an OnLeave on a land the test never left"
  - "a flake on a slow leg only, after a join helper returned"
  - "the test's next step races the tail of the operation a helper started"
root_cause: helper_returns_on_a_state_condition_before_the_operation_it_started_finishes
resolution_type: design_rule
severity: medium
tags:
  - testing
  - fixtures
  - join
  - polling
  - land-stop
  - flaky
related:
  - "#634"
  - "#683"
---

# A helper that returns on state leaves its operation running

## Problem

`FailedLandStopTests.failureDuringAdminStopGives4016` failed once on Linux, with an OnLeave on a land that was meant to fail before any leave ran (#634). The test joined a player with the file's `Fixture.join`, held an admin stop after its snapshot, failed the land, and then released the stop.

## Root cause

`Fixture.join` started `router.onMessage(join)` in a Task and polled until the land had the player. The land has the player from OnJoin on, which happens inside `adapter.admitJoin`. After that, the router's join still checks its attempt (`isCurrent`, after the `.afterAdmit` hold point). If the session is gone by then, it undoes its admission with `adapter.onDisconnect`.

The stop removes its sessions before its `.stopSnapshot` hold. A join tail that reached the check after that found its session gone and undid the join, so OnLeave ran while the stop was held, before the failure. The undo is correct behaviour. The helper's postcondition ("the player is in the state") was weaker than what the test assumed ("the join is done"), and only a slow scheduler showed the gap.

## Fix

The helper returns once the router's join has returned (bounded), and then checks the state (#683). Its first half, `startJoin`, hands back the join's Task for tests that hold the join.

## Prevention

- A helper that starts an operation waits for that operation to end, not for one of its effects. An effect (a player in the state, a frame sent, a counter) can show up before the operation's tail, and the tail can still act: undo, send, or clean up. Poll a state condition only when the operation has no end you can await, and then say in the helper's doc which tail can still run.
- Writing the helper's doc as "returns once …" makes the gap visible: "once the land has the player" is not "once the join has returned".
- Pin it with a hold in the tail (`LandRouterHoldPoint.afterAdmit`). Let the next step of the test run while the tail is held, release the tail, and expect what it does (`FailedLandStopTests.joinTailUndoneByAStop`). For the helper itself: with the tail held, it must not return (`fixtureJoinWaitsForTheRoutersJoin`). The hold makes that check unable to fail on a correct helper. A short pause only gives a state-polling helper the time to show itself, so it decides mutant strength, never flakiness.
- Related: [A returned send is not a delivered frame](2026-11-10-a-returned-send-is-not-a-delivered-frame.md) (another "returned" that is weaker than what the caller assumed), and [Force the interleaving with hold points, not timing](2026-11-05-hold-points-not-timing-in-race-tests.md).
