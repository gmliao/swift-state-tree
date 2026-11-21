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
- **Not bounded:** code inside a `// docs:` block. The documentation test (`documentationMatchesTheTests`) needs those lines verbatim:
  - WorkedExampleTests' first `sendAndWait`;
  - ConceptsTests' `scoreboard-use` quiescence wait.

  The quiescence wait returns false when its task is cancelled, so the suite's time limit still ends it. The worked example's call uses `ImmediateProfiles`, so no gate holds its reply.

## Verification

- `SwiftStateTurnsTests` in debug and release.
- `scripts/lint-turns.sh`.
- `scripts/lint-wall-clock-tests.sh` with no baseline raise.
- The seed-79 mutant (drop the supersede's withdraw in `Turn.start`): the full `SwiftStateTurnsTests` run must end, failing.
- One event-withholding mutant per converted suite.
