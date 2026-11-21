# Bound the turn suites' own waits (#711)

Status: implementation on `test/711-bound-turn-suite-waits`, stacked on #719.

## Goal

A regression in the turn core makes a turn-suite test fail within the hang bound (60 s) instead of parking the run. The seed-79 mutant (a supersede that skips its withdraw) used to hold the full `SwiftStateTurnsTests` run forever. With this change the run ends, failing, in about 63 s.

The rule comes from `Notes/solutions/2026-11-20-a-time-limit-does-not-end-a-wait-that-never-resumes.md`. A suite's `.timeLimit` cancels only the test's task, and a wait that ignores cancellation, or a task the test awaits, outlives it. #719 applied the rule to `FollowUpTests`; this change applies it to the other turn suites.

## Helpers (`Tests/SwiftStateTurnsTests/Support/HangBound.swift`)

#719 adds `raceHangBound`: a reader task and a timer race to resume one continuation, and the loser is never awaited. `reach`, `settled` and `bounded` are built on it. This change adds:

- `firstOrBound(task)`: `task`'s result, or nil with an issue recorded. It doesn't cancel the task, so a call made with `.ignoresCancel` keeps the policy the case checks. If the task never ends, it is abandoned parked and never awaited; the test fails.
- `boundedResult(task)`: `firstOrBound` for a call task's `Result<Int, any Error>`. A task that never ends reads as `.failure(TurnHangBoundExceeded())`, so `outcome(_:)` and its expectation see it.

## Sites

The counts come from a grep at #719's head, then each site was read.

| Suite | `f.wait` → `f.reach` | call task → `boundedResult` | `.value` → `firstOrBound` | quiescence → `bounded` |
|---|---|---|---|---|
| CancellationTests | 3 | 7 | – | – |
| ClockAndTimerTests | 11 | – | – | – |
| ComparisonTests | 3 | 2 | 1 (`join.value`) | – |
| ConceptsTests | – | – | – | 1 |
| GeneratedOrderTests | – | – | 1 (`call.task.value`) | – |
| LifetimeTests | 3 | – | – | – |
| MembershipModelTests | 22 | 30 | – | – |
| OrderedChecksTests | 22 | 20 | – | – |
| WorkedExampleTests | – | 1 | – | – |

- **Converted:**
  - every `Fixture.wait` made from the test's own task;
  - every `.result` of a call task;
  - every direct `try? await a.sendAndWait(…, .ignoresCancel)` made from the test's task, now wrapped in a task under `boundedResult`.
- **Kept on purpose:**
  - `Fixture.wait` inside effects and checks, where a test may end with one parked at a gate;
  - the yield loops in ComparisonTests, GeneratedOrderTests (`settle`), LifetimeTests and ConceptsTests. Each is `for _ in 0 ..< 10_000` and so ends; all are already marked `wall-clock:` and in the baseline.
- **Found by the mutants (below), not by the grep:**
  - `waitForLog(n)` in `DemoActor` and `MembershipActor`, an `.ignoresCancel` call the test makes through the actor. It now goes through `firstOrBound`.
  - `await register(…).result` and the like in MembershipModelTests: a helper that returns a call task. 11 sites, now `boundedResult`.
  - The generated-orders harness's `notes.wait`, now `Notes.reach` (one failure ends the seed).
  - Its call tasks, awaited one by one. They now share one bound per seed.
- **Doc blocks:** code inside a `// docs:` block stays verbatim, because the documentation test (`documentationMatchesTheTests`) compares it. The three tests with such waits (ConceptsTests' room and scoreboard, WorkedExampleTests' lobby) run their whole body under `withinTestHangBound`, which records an issue and abandons a body that never ends. The documentation test ignores the indentation this adds.
- **Waits one after another:** a test that makes many waits in turn (the orders in M8–M10, the generated seeds) costs one bound per wait under a mutant: many minutes, not one. Once any wait in the process has run out its bound, `HangBoundTrip` gives later waits 1 s. A run with a hung core then ends in about one bound.

## Verification

- `SwiftStateTurnsTests` in debug and release.
- `scripts/lint-turns.sh`.
- `scripts/lint-wall-clock-tests.sh` with no baseline raise.
- The seed-79 mutant (drop the supersede's withdraw in `Turn.start`): the full `SwiftStateTurnsTests` run must end, failing.
- Two event-withholding mutants, each touching every converted suite:
  - `reply`: successful replies are withheld, while errors (a `.cancelsCall` caller's `CancellationError`) still go. Withholding the error too would leave the documented `.cancelsCall` calls with nothing to end them.
  - `launch`: no effect is launched, so no gate event comes.

  Each full run must end, failing. Before the fixes above, both ran past a 900 s timeout. Results are in the PR.
