---
module: Tests
date: 2026-11-17
problem_type: testing_practice
component: land-failure
symptoms:
  - "Expectation failed: await keeper.waitForFailureForTesting()"
  - "a land-failure test passes locally and times out after about 30 s in CI's build (in-turn sync false) job"
  - "build (in-turn sync false) fails, build (in-turn sync true) passes"
root_cause: legacy_sync_failure_applied_at_the_next_turn_but_the_test_stepped_one_tick
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - in-turn-sync
  - legacy-sync
  - land-failure
  - tick
related:
  - "#535"
  - "#580"
  - "#581"
---

**Problem.** Twice on 2026-11-17 a test that makes a tick land's sync fail passed in the full local `swift test` and failed only in CI's `build (in-turn sync false)` job: `PathIndexTests` "A per-player frame with a patch outside the schema ends the land" (#580) and `CollidingKeysTests` "A synced map whose keys collide ends the land" (#581). Both timed out in `waitForFailureForTesting()` after about 30 s.

**Root cause.** The two sync paths end the land at different times.
- **In-turn sync (the default, `IN_TURN_SYNC` unset or true).** The keeper ends the land in the same turn as the failing sync (`applyInTurnSyncResult`). One `stepTickOnce()` is enough.
- **Legacy sync (`IN_TURN_SYNC=false`).** The sync runs outside the turn. The adapter submits the failure (`submitLandFailure`), and the keeper applies it at its next turn. On a land with a tick handler that next turn is the next tick: `kickServerInputTurn` returns early when there is a tick handler, and a test that steps ticks by hand has no tick loop running.

The tests stepped one tick, so on the legacy path the failure was submitted but never applied. The local run used the default, so only CI's legacy job saw it.

**Fix.** After the tick whose sync fails, step one more tick when in-turn sync is off:

```swift
if !InTurnSync.isEnabled() {
    // Legacy sync runs outside the turn and submits the failure, which the keeper applies
    // in its next turn: on this tick land, the next tick.
    await keeper.stepTickOnce()
}
```

The test then checks that the land ends on both paths. A test that can't reach the legacy path's end in its harness skips it with `guard InTurnSync.isEnabled() else { return }` and says why, as `adapterUnmappedBroadcastPatchEndsTheLand` does.

**Prevention.**
- For a test that ends a land through its sync, or asserts anything a turn applies after the sync, run its suite locally with `IN_TURN_SYNC=false` as well as the default before pushing. A full run with each setting takes about 10 s per target.
- On a tick land, assert a submitted failure after the keeper's next turn, never right after the tick that failed.
- The same holds for an in-turn join on a tick land. It flips only in a turn, so `performJoin` waits for a tick that a hand-stepped test never runs. Join through `simulateRouterJoin` and step a tick instead.

**Update (#546 L1):** the `IN_TURN_SYNC` switch and its CI leg are removed. The off mode stays reachable only through `package` API until #546 L2 removes it: a test that needs it passes `inTurnSync: false` explicitly.
