---
module: SwiftStateTree, tests
date: 2026-11-05
problem_type: testing_practice
component: concurrency-tests
symptoms:
  - "A race test passes locally and fails intermittently on CI, or never fails at all"
  - "A test needs `sleep` calls to make the bad interleaving likely"
  - "TSan reports nothing, yet the bug reproduces in production-like runs"
  - "A test waiting for a hold at a loop's entry hangs only when the suite runs in parallel"
root_cause: timing_based_interleaving_in_tests
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - reentrancy
  - hold-points
  - determinism
  - tsan
  - input-drain
related:
  - "#146"
---

# Force the interleaving with hold points, not timing

## Problem

Reentrancy and ordering bugs depend on another call running at one specific `await`. A test that relies on `sleep`, `Task.yield()` or "run it 1000 times" makes that interleaving likely at best; it is flaky on a loaded CI runner and silent on a fast laptop. TSan doesn't help: actor reentrancy is not a data race.

## Fix

`HoldPoints` (`Sources/SwiftStateTree/Support/HoldPoints.swift`, #146): one optional hook per instance, awaited at named points.

```swift
enum HoldPoint: Hashable, Sendable { case afterLandLookup }
var holds = HoldPoints<HoldPoint>()
...
await holds.at(.afterLandLookup)
```

- The test installs a hook that suspends at the point, issues the competing call, then releases the hook.
- With nothing installed it is a single `nil` check and doesn't suspend, and it runs on the caller's executor (`isolation: isolated (any Actor)? = #isolation`), so production code before and after the point stays one synchronous segment. A plain nonisolated `async` method would hop off the actor there and open a reentrancy window in production.
- Tests combine it with a gate (for example `TestGate`) to wait until the held code has reached the point before issuing the competing call.

## Prevention

- Every reentrancy or ordering fix gets a test that holds the code at the `await` where the race happens. Without the fix the test fails every time, not sometimes.
- Check the test with mutations: remove the fix's check or mark and confirm the test fails.
- Assert the precondition that makes the interleaving meaningful (for example, that an entry was evicted before the admission runs), so a test can't pass because the setup didn't happen.
- No `sleep`-based waits in race tests (`CLAUDE.md` § Reentrancy: "Tests force the interleaving with a hold at the `await` (`HoldPoints`, `TestGate`), never timing").
- **Gate and hold keys must be unique per test.** A static gate registry keeps one gate per key for the whole process, and Swift Testing runs tests in parallel. A key reused by two tests opens the other test's gate: #350's static gate, and `key(10)` reused in legacy mode on #353's first head. Hand out keys from a counter (`TicklessActionJobTests`' `freshKey()`), never a literal; the shared helper with a duplicate-registration check is #354.

## When a test has to measure time

Some properties are about time, for example "encoding is linear, not quadratic". Two rules keep such a test from flaking or starving others:

- **Count the work instead of timing it, when the property is about work.** A ratio of times still moves with load: #260's `largeContainersEncodeInPlace` (8x the elements, threshold 24x) failed a correct encoder at 25.3x in a loaded 30-run loop (#340). It now counts how often each of the encoder's growing buffers moves to new storage (`CanonicalBufferMoves`, debug builds): about log2(n) moves in place (14 for 16,000 elements), one per append when an append copies the buffer. A mutant that takes the buffer out, appends and puts it back fails it on each of the three buffers. Use the timing ratio below only when no such count exists.
- **Compare a ratio, not an absolute bound.** Time the same work at n and k·n and compare the ratio with a threshold between the linear and the bad growth: with k = 8, linear is about 8×, quadratic about 64×, so a threshold of 24 leaves about 2.7× margin on each side. Take the best of three per size, and time only the operation (build the inputs outside the timed closure, or the linear setup dilutes the signal). Check with a mutation that puts the bad growth back and fails every run (#260's first `largeContainersEncodeInPlace`, now a count: above).
- **Keep it small.** Swift Testing runs tests in parallel in one process, so a test that burns seconds of CPU can push another test's wall-clock wait past its deadline. #260's first version, about 1.4 s of CPU in debug, made "OnInitialize completes before tick starts" (a 2 s wait) fail on CI. Shrinking it didn't stop the failures, though: the wait itself was the cause (next section).
- **A CPU-heavy test makes every wall-clock test beside it fail: shrink it, and remove the wall-clock wait.** On #266, a truncation test that reopened a record at every byte and a 10,000-tick memory test (10–12 s each) doubled the suite's time. They failed "Replay runner pipeline preserves tick ordering through service queue" (a 2 s status poll) and the cadence smoke on both sync legs, while neither failed on main. Cutting each record only at its boundary cases and running 2,000 ticks brought them to 0.07 s and 0.55 s.

- **A test that must measure real time runs in a process of its own.** `.serialized` orders the tests of its own suite only; every other suite still runs beside it in the same process. Gate the suite on an env var (`WALL_CLOCK_TESTS=1`) and run it with `--filter` and `--no-parallel` in a separate step, which fails when the filter matched nothing, so a rename can't skip it silently (the cadence smoke, `WallClockCadenceSmokeTests`).

- **A process of its own isn't enough on a shared machine: assert on what the code decided, not on when it happened.** ws-loadtest's spread-send test (#285) still failed (`13 ≤ 6`) run alone, under Node 20, on a Mac other work was loading. A stall of the worker's event loop fires the timers it delayed together, so arrivals bunch whatever the schedule was. It now checks the intended send times each action's samples record (a mutation that zeroes the offsets fails it, `20 ≤ 6`). The join-failure tests, which check which failures a phase lists, turn the phase's latency gates off, since a loaded machine's RTT adds a failure they aren't about.

## Waiting for a scheduler or a timer

A test that polls state until a tick loop or a timer has fired ("wait up to 2 s for `ticks >= 1`") is a timing test in disguise. Under parallel tests on a loaded runner the loop can stall past any deadline. "OnInitialize completes before tick starts" (#264) failed this way on three runs in a row, on both sync legs, while the order it asserted held every time.

- **Step it, don't wait for it.** Build the keeper with `autoStartLoops: false` and call `stepTickOnce()` once per tick. Or, when the loop's start is part of what's tested, give it an interval that never fires in a test (an hour) and step the ticks by hand. Then assert exact counts (`== 3`), not `>=`.
- **Await what the code awaits.** Use the initialization itself (`awaitInitialization()`) or the timer's task (`destroyTimerForTesting()`, then `await timer.value`). A cancelled timer's task ends at once, so a test checks cancellation with `isCancelled` and the timer's identity, never by sleeping past the delay. Make that check `try #require(timer.isCancelled)` before `await timer.value`: with a 1 h delay, a regression that leaves the timer running would otherwise hang the test (and a mutation run) instead of failing it.
- **A loop's task can still write after "the loop started".** The keeper sets `appliedTickPhaseOffset` when it configures the tick loop, but the loop's task writes the first tick deadline later, in its own turn. A test that set the deadline in between had it overwritten by now + 1 h, the next sync didn't fold, and "a transport that doesn't record folds is not called" counted 1 fold instead of 2 under load. Wait for the point after the write: bind a `TickLoopClock` whose `sleepUntil` reports the loop's first sleep (`InTurnSyncFoldReportTests`). Holding the loop's phase-offset sleep and releasing it after the test's write reproduces the failure every time.
- **Before saving a record, wait for the work that writes it, not for time.** `LandKeeperClientEventQueueTests` slept 100 ms after `handleClientEvent` and then saved. The event is applied by a task of its own, and since #337 its record goes through the keeper's ordered submission queue. On a loaded Linux runner the record was still queued at `save` (about 1 run in 20), so the file was complete but held no frame, and `maxTickId` was -1. Draining the submission queue alone isn't enough: it can't see a task that hasn't submitted yet. Wait for the keeper's in-flight input tasks to end, then drain the queue (`waitForInFlightWorkForTesting()`).
- **A deadline built from `ContinuousClock.now` is wall time, even in a stepped test.** `cadenceMatchesLegacy` stepped its simulated second by hand but set each coincident tick to `ContinuousClock.now + 1 ms`. The sync loop then read the real clock, so a runner that stalled for 1 ms between the two calls counted the fold as overdue (#335). Capture one `now` and pass it to both the deadline and the code under test (`runSyncLoopIterationForTesting(at: now)`). Check the fix by putting a 5 ms sleep between them: the old form fails every time, the fixed form passes. Keep a control that a deadline before `now` is still counted as late. And wait for the tick loop to have written its own first deadline before setting one (the first-sleep handshake above, `FirstTickSleepSignal`), not for `appliedSyncPhaseOffset`: the loop's task writes it later and would overwrite the test's.
- **No shared static gate across tests that run in parallel.** A `TestGate` lets every later arrival through once opened, so one static gate used by two tests lets the first test's `open()` release the second's code early: in #350, a land whose initialization should have failed succeeded, and a hold waiting for its drain hung until the time limit. Key each gate by the test's own instance (a land ID, a per-test token) so a test can open only its own.
- **Make the assertion tell the orders apart.** A marker that a later step overwrites can't show which ran first. Write the marker conditionally, for example OnInitialize writing -1 only when no tick ran before it.

## A hold at a loop's entry needs the previous loop to have ended

A hold at the start of a drain loop (`.inputDrain`) fires only when a new drain starts. If an earlier drain is still in its loop, past that hold and yielding between turns, it takes the next input itself, no new drain starts, and a test waiting for the hold (`gate.waitUntilEntered()`) waits forever. The tickless multi-input pass test (#325) installed the hold right after `join` returned. Alone it passed; with eight tests in parallel the join's drain was still yielding when the client event arrived, so the test hung every run, with no thread blocked and no time limit reached, because the await never resumed.

- **Wait for the earlier loop's end, not for time.** Before installing the hold, wait for the drain's end probe (`setInTurnProbeForTesting`, `"input-drain-end"`), for example through an `AsyncStream` the probe yields to.
- **Classify a parallel-only hang first.** If the suite hangs in parallel but never `.serialized`, and one test repeated 16 times under parameterized arguments hangs alone, the cause is in that test's own interleaving, not state shared between tests. Checkpoints written to stderr (unbuffered) show the last step each case reached. Don't ship `.serialized` as the fix.
