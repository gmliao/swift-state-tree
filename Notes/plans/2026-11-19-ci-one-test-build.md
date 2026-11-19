# CI: one debug test build for the four Swift variant jobs

Status: proposal. Expands lever 7 of `2026-11-19-dev-speed.md` ("Share one build across the env-only variants") with measurements; the CI test audit's V5 measurement (`2026-11-19-ci-test-audit.md`) brought it up again. It assumes V4 (#649) has merged.

## Question

Four jobs in `Swift Build & Test` build the same debug package and tests from scratch, then run the tests for 30–55 s:
- `build (in-turn sync true)`;
- `build (in-turn sync false)`;
- `build (sync tables off)`;
- `build (per-player sync tables off)`.

They differ only in environment variables read at run time. Can one build serve all four, and what does it cost in wall time?

## Baseline (measured)

Six successful `push` runs on `main`: 44452126904, 44455844438, 44461176493, 44469926776, 44471241660, 44484927089.
- **These runs predate #642.** sync-tables-off still ran the full suite in them, so its numbers are higher than it is now.
- **Since #642,** that job runs about 1,209 tests instead of 2,443. On #642's own PR run, 44487857946, its build took 664.83 s and its tests 27.1 s, so the build dominates either way.

### The four jobs per run

- **span:** from the first job's start to the last job's end, including any wait for a runner.
- **sum:** the runner time of the four jobs.

| run | span | sum | longest job | start offsets (s) |
|---|---:|---:|---:|---|
| 44452126904 | 1,053 s | 2,597 s | 876 s | 0, 0, 301, 327 |
| 44455844438 | 725 s | 2,575 s | 724 s | 0, 0, 1, 1 |
| 44461176493 | 803 s | 2,614 s | 803 s | 0, 0, 0, 0 |
| 44469926776 | 859 s | 2,707 s | 859 s | 0, 0, 0, 0 |
| 44471241660 | 1,005 s | 2,733 s | 844 s | 0, 6, 69, 240 |
| 44484927089 | 1,422 s | 2,956 s | 890 s | 0, 161, 532, 553 |
| **median** | **932 s** [725–1,422] | **2,660 s** [2,575–2,956] | 852 s | |

In three of the six runs, a job waited minutes for a runner. That wait is part of the span.

### Per job

Medians of the same six runs, in seconds, with min–max in brackets. Each bracket's min and max can come from different runs.

| job | job | `Build` | `Run tests` |
|---|---:|---:|---:|
| build (in-turn sync true) | 755 [654–876] | 278 [243–347] | 313 [263–378] |
| build (in-turn sync false) | 686 [460–890] | 248 [158–345] | 282 [190–367] |
| build (sync tables off) | 540 [472–765] | one step, 490 [427–722] | |
| build (per-player sync tables off) | 662 [417–726] | one step, 619 [370–686] | |

### Inside the steps

From SwiftPM's own lines in #642's run 44487857946:

| job | `swift build` | `swift test`'s build | the tests |
|---|---:|---:|---:|
| in-turn sync true | 346.44 s | 316.44 s (test targets) | 54.0 s (2,443 tests) |
| in-turn sync false | 310.18 s | 293.69 s (test targets) | 46.5 s (2,443 tests) |
| sync tables off | (none) | 664.83 s (libraries and tests) | 27.1 s (1,209 tests) |
| per-player sync tables off | (none) | 657.35 s (libraries and tests) | 28.2 s (1,209 tests) |

- `swift test` after `swift build` compiles only the test targets. In run 44484927089's false leg, all 181 of its `Compiling …` lines name a `…Tests` module.
- A full debug build with tests is about 600–665 s, and each of the four jobs pays it. Across the four that's about 2,600 s of build against about 155 s of tests.

## Why one build is valid

The four jobs differ only in these variables:

| variable | job | read by |
|---|---|---|
| `IN_TURN_SYNC` | the two build legs | `InTurnSync.isEnabled()` |
| `USE_SYNC_TABLES`, `TYPED_LEAF_VALUES` | sync tables off | `TransportEnvConfig` |
| `PER_PLAYER_SYNC_TABLES` | per-player sync tables off | `TransportEnvConfig` |

Each is read at run time through `EnvHelpers`. The table switches are process-local `static let`s, so each `swift test` process starts with fresh values. Nothing reads them when the package is built:
- `Package.swift` reads no environment;
- there is no build plugin, and no macro reads the environment;
- no job passes `-Xswiftc -D…` built from them;
- all four run a plain debug `swift build` / `swift test` in the same image with the same flags;
- the conditional compilation in `Sources/` is `#if DEBUG` and platform constants, the same for every job on one image (dev-speed § Build variants).

The SwiftPM shared cache holds only dependency clones and prebuilts.

## Design: one job, steps in a row

**The job keeps the id `build`.** The SwiftPM cache key starts with `${{ github.job }}`, so its existing entries still restore; a new id would start the first runs with a cold cache. The job's `name` changes to `build (variants)`, and the matrix goes away.

```
build:
  checkout, cache, Lint lessons, Lint turns, clean, Show toolchain
  Build (id: build):  swift build --build-tests
  Must-not-compile:   as today
  Tests, in-turn sync on:
      env IN_TURN_SYNC=true;   swift test --skip-build
  Tests, in-turn sync off:
      env IN_TURN_SYNC=false;  swift test --skip-build
  Tests, sync tables off:
      env USE_SYNC_TABLES=false, TYPED_LEAF_VALUES=false, FILTER (V3's);
      swift test --skip-build ${FILTER:+--filter "$FILTER"}
  Tests, per-player sync tables off:
      env PER_PLAYER_SYNC_TABLES=false;
      swift test --skip-build --filter 'SwiftStateTreeTransportTests\.|SwiftStateTreeNIOTests\.'
  Wall-clock cadence smoke:  as below
  Summary:  if: always()
```

### Each variant step

- **`if: ${{ !cancelled() && steps.build.outcome == 'success' }}`.** A failed variant still lets the next one run. A failed build stops them all; `--skip-build` must not run on missing or partial products (`Notes/solutions/2026-11-10-skip-build-after-a-failed-build-runs-the-old-tests.md`).
- **A name of its own and its own `timeout-minutes`.** Today's limit is 30 min for the legs and 40 for the two off jobs.
- **A log of its own, behind `set -o pipefail; … | tee <variant>.log`.**
- **The pin greps carry over unchanged, each on its own variant's log:**
  - the two table pins on the tables-off log;
  - the per-player pin on the per-player log.

  Each fails the step with `::error::` when its pin test didn't run, as today.
- **On failure, an annotation:** `echo "::error title=<variant>::swift test failed"`. It shows on the PR's Checks page and in the Files view. With one check, the job failing is all a reader sees at first, so the annotation names the variant.
- **A summary step, `if: always()`,** writes a table of each variant's outcome (`steps.<id>.outcome`) and its `Test run with …` line to `$GITHUB_STEP_SUMMARY`.

### The wall-clock cadence smoke

It runs once, with `IN_TURN_SYNC` at its default (true), as today: `WALL_CLOCK_TESTS=1 swift test --skip-build --no-parallel --filter WallClockCadenceSmokeTests`, with the grep that proves it ran.
- Today both legs run it.
- It passes `inTurn: [true, false]` itself, but the adapter ANDs that with `IN_TURN_SYNC` (`TransportAdapter.swift:941`). So the false leg runs the legacy path twice, and the true leg already covers both paths.

### The job's limit

The step limits add up to about 145–150 min:
- 30 min for each of the two in-turn variants;
- 40 min for each of the two off variants;
- 5 min for the cadence smoke.

That comes before the build and must-not-compile. The job gets `timeout-minutes: 180`, set on purpose, so the job's limit never ends a step that is still within its own.

### A rerun

A rerun repeats the build and every variant. Today's "re-run failed jobs" could rerun one leg alone; now it reruns the job, about 16 min.

### Rejected: build once, fan out with an artifact

One job would upload `.build`, and four jobs would download it and run their tests.
- The tests run 27–54 s each. A full debug `.build` is several GB, to be measured if this is ever revisited. Uploading it and downloading it four times would cost about as much as the tests.
- It needs the same checkout path in every job, which the container gives, but it is one more thing that can break.
- It would keep a little wall time and give back much of the runner time.

## The guards carry over

`scripts/check-variant-test-selection.sh` is retargeted at the merged job in the same PR, with its self-tests. Without that, it fails, or gets loosened. Its sections become:

**1. The sync-tables-off variant.**
- It reads the merged job's `Tests, sync tables off` step: exactly one step, with its own `FILTER` env of today's form, and exactly one `swift test --skip-build ${FILTER:+--filter "$FILTER"}`.
- The scan of the targets outside the filter (R1–R3) is unchanged.
- The self-tests' sample workflow takes the new shape. These cells move to the step:
  - no FILTER;
  - a FILTER in another step;
  - a command that ignores it;
  - two `swift test`s;
  - an alternative that isn't a whole target.

**2. Variant variables (replaces S4/S6).**
- `IN_TURN_SYNC`, `USE_SYNC_TABLES`, `TYPED_LEAF_VALUES` and `PER_PLAYER_SYNC_TABLES` appear only in a test step's `env`. They never appear:
  - in the job's or the workflow's `env`;
  - on the build step or must-not-compile;
  - in any `run:` line (`$VAR`), in an `if:` (`env.VAR`), or in `-Xswiftc`.
- `Package.swift` reads no environment (`ProcessInfo`, `getenv`, `environment[`).
- The build job has no `strategy.matrix`. A new matrix would bring back the variant runs this check reasons about.
- The once-only steps (lints, must-not-compile) read none of the variables: S4's scan of the scripts, kept.
- One cell for each form, including the bracket and `env.` forms Review named for S6.

## Isolation between the runs

Each `swift test` is a new process, but the four share one container and one checkout.
- The fixed binds (ports 39399/39400) close their channels.
- NIO replay tests write UUID-named files under the checkout's `reevaluation-records/`, with deferred removal. A failed or timed-out step skips that removal.
- `ReevaluationRecordLogTests` spools under `record-log-tests-<8 characters of a UUID>` in the temporary directory.

**The PR proves it on its branch, against one build:**
1. Run the four variants twice in a row.
2. Run once more with a variant made to fail (a forced `exit 1` after its `swift test`, on a throwaway commit), followed by the others.
3. After each sequence: `git status --porcelain` must show no tracked fixture changed, and the leftover files under `reevaluation-records/` and the temporary directory are listed.

Leftovers that a later variant could read are fixed in the tests before the merge.

## The trade

| | today (four jobs) | one job |
|---|---:|---:|
| runner time | 2,660 s median (sum of four) | ≈ 970 s |
| span of this work | 932 s median [725–1,422], including waits for runners | ≈ 970 s, plus one wait for a runner |
| jobs queued per push | 4 | 1 |

Where the 970 s comes from:
- 35 s containers;
- 650 s build with tests;
- 100 s must-not-compile;
- 20 s lints;
- 155 s for the four test runs;
- 10 s wall clock.

- **Runner time:** about 28 runner-min less per push, roughly a quarter of a push's ~110. That's the sum minus the estimate on the stated components.
- **The span:** dev-speed lever 7 expected no wall-clock gain, since the runs go in a row. Measured, it's about the same at the median, since today's span already includes the waits for three more runners. It's longer when four runners start at once and a slow runner gets the one job. The PR measures it.
- **The workflow's end:** `turns (release)` is 898 s median and 1,102 s max, so it stays level with or ahead of this job.
- **Unchanged:** the E2E workflow runs separately.

## The nightly

`nightly.yml` calls this workflow with `full_matrix: true`, as today.
- The sync-tables-off step runs the whole suite (FILTER empty).
- `turns (release)` keeps its exclusivity step.
- It is the same job, so it can't drift from the push runs.

The PR also dispatches the nightly on its branch (`gh workflow run nightly.yml --ref <branch>`) and quotes it: editing the called workflow doesn't trigger one.

## Measurement on the PR

- The PR's runs and two dispatched nightlies on its branch.
- From each: the job's total and span, every step's time, and the four `Test run with … tests` lines.
- The SwiftPM cache step's restore: it should be an exact or prefix hit, not cold.
- Runner time and span against the table above, and the same for the first three `main` push runs after the merge, added to this plan.

## Out of scope

- `turns (release)`: a release build, a different configuration.
- `examples`: its own packages.
- The E2E workflow's GameServer builds; the audit plan notes their lever.
