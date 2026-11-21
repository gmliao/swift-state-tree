# Turn core: one continuation job for the drain and the follow-ups (#723)

**Status:** rev 2, plan only, for review. No code until Review's GO.

**Rev 2** (Review's NOT GO on rev 1: 2 must-fix, 3 should; the design itself was right):
- §2.2: the guarantee is rewritten (MF 1). There is one pending self-continuation. The job's loop re-picks after each step: eligible parked work takes precedence while releases are enabled, and captured follow-ups step in arm order. Parked inputs keep FIFO per key. Batch content is deterministic given where the job lands among the actor's entries.
- §4: each mutant names the test that kills it. A dropped guard at the capped point is killed only by a case with a job already pending (case 3). The tests witness enqueues and job runs directly (MF 2).
- §2.3: the settlement point lost between today's two jobs is accepted, with a test.
- §4: case 27's expected log is derived from §2.2, with its `armed` lines. P2 and C share a segment.
- The cap's wording: a withdrawn parked input spends a release slot.
- Decided: Q1 = releases first; Q3 = no 50-run case; Q2 = a plain rename of `TurnStats.drainContinuations` to `continuationJobs`, with no alias (the maintainer's decision).

## 1. Today

Since #719, `TurnActor` can schedule two continuation jobs for one machine. Both are unstructured `Task { self.… }` on the actor (`Sources/SwiftStateTurns/TurnActor.swift`):
- **`continueDrain`** is scheduled by a segment that leaves a releasable key at `budget == 0` (guarded by `core.drainScheduled`). Its segment releases parked inputs under a fresh budget. It never steps a follow-up: due follow-ups stay in `rt.dueFollowUps`.
- **`continueFollowUps`** is scheduled by a segment's epilogue when `rt.dueFollowUps` isn't empty (guarded by `core.followUpJobScheduled`). It moves the due follow-ups into `followUpsToStep`, in arm order, and runs a segment. That segment also releases parked inputs up to the cap, because releases aren't gated on `drainScheduled`.

Nothing orders the two jobs, so a capped segment that schedules both gets batches whose content depends on job order:
- If the drain runs first, its releases may arm follow-ups. Those go to `dueFollowUps`, and the follow-ups job that runs after it takes them.
- If the follow-ups job runs first, it may release the inputs the drain was scheduled for, and the drain then finds less to do.

The follow-ups plan carries the caveat (`2026-11-20-turn-core-follow-ups.md` §3.3, "No order between the two jobs"). Case 27 in `FollowUpTests.swift` asserts no order between those later jobs.

## 2. Design: one job, one flag, its follow-ups captured at its start

- **One flag.** `core.drainScheduled` and `core.followUpJobScheduled` become `core.continuationScheduled`.
- **One job.** `continueBatch()` replaces both:
  ```swift
  @inlinable func continueBatch() {
      let core = self.core
      core.continuationScheduled = false
      beginEntry()
      if TurnCore<M>.usesFollowUps {
          for id in core.rt.dueFollowUps { core.followUpsToStep.push(id) }
          core.rt.dueFollowUps.removeAll(keepingCapacity: true)
      }
      runSegment()
  }
  ```
- **Two schedule points, one guard.** The capped branch of `runSegment` and the epilogue each schedule `continueBatch` only when `!core.continuationScheduled`, and each schedule counts `continuationJobs`. A segment that is both capped and leaves follow-ups due schedules one job.
- **`runSegment`'s loop is unchanged.** #725's lane, if it lands first, adds its take right after the products (that plan, §3.4).

### 2.1 The loop, as it is

Each iteration of `runSegment` drains products, then picks the first kind with work, steps one item, and loops:
1. abandonments;
2. queued sends;
3. a release, while releases are enabled (not `capped`), from the key `nextReleasable()` picks at that moment;
4. a captured follow-up (`followUpsToStep`), re-checked: one that was consumed, ended or closed after the capture is skipped.

Releases are spent from `maxReleasesPerBatch`, one per attempt.
- **A withdrawn input spends its slot.** A parked input whose token is withdrawn is refused, not stepped, and the slot is still spent.
- **The cap disables releases.** When a releasable key is left at budget 0, the segment schedules the continuation and sets `capped`. Releases stop for the rest of the segment, and the captured follow-ups still step.

### 2.2 The guarantee

- **One pending self-continuation.** At most one `continueBatch` is queued at a time, whatever scheduled it.
- **What a job captures.** At its start, a job captures the follow-ups that are due, in arm order. Anything armed during the job goes to `dueFollowUps` for the next job. So a follow-up that keeps re-arming itself is still a chain of jobs, each yielding the actor (follow-ups plan §3.3).
- **Precedence inside the job.** The loop re-picks after each step, so the job is not "all releases, then all follow-ups".
  - While releases are enabled, eligible parked work goes first. A release is chosen live, at each iteration, so a follow-up's step that makes a key releasable can be followed by that release, before the next follow-up, if budget remains.
  - The captured follow-ups that survive their re-check step in arm order.
  - Parked inputs keep FIFO per key.
- **A job can run empty.** An entry that ran a segment before it may have done its work: releases aren't reserved for the job, and a captured follow-up may have been consumed since. The job then steps nothing. Queued sends are usually empty in a job, because an entry takes them.
- **What is deterministic.** Given where the job lands among the actor's entries, its content is a function of the core's state at its start, and no second core-scheduled job can run before or between it.
- **What isn't.** Where the job lands against other entries already queued on the actor (another task's `send`, an effect's result) still depends on the executor. That is Swift's order between tasks, which the core can't fix. The generated-orders harness and replay treat those entries as the input sequence.

So the docs' caveat goes from "two jobs, unordered" to "the core's continuation is one job; other entries interleave with it as with any job".

### 2.3 One settlement point fewer

Today, when the two jobs run one after the other, each segment's epilogue settles the quiescence waiters, so there are two settlement points. A waiter whose count was reached by the first job woke before the second job's steps. With one job there is one epilogue, so such a waiter wakes after the whole job, follow-ups included.
- **This is accepted.** The wait's contract is "the count was reached at a settlement point". It never promised a point between the core's own batches. The follow-ups plan's §3.5 defines the points as segment epilogues, and one job is one segment.
- **New case 4 pins it:** a `.requests` waiter whose count a release in the job reaches wakes at the job's end, with `true`, after the captured follow-up stepped.

### 2.4 Counters

`TurnStats.drainContinuations` becomes `TurnStats.continuationJobs`, a plain rename, with no alias. It counts every `continueBatch` scheduled, for either reason.
- The rename is public and was decided by the maintainer. The PR body lists it under "Public API".
- `OrderedChecksTests.swift:244` (`drainContinuations >= 4`) keeps its bound under the new name.

## 3. Cost (#621)

- **Without follow-ups (`FollowUpSlot == Never`).** `continueBatch` is `continueDrain` with a renamed flag: the follow-up capture folds away under `usesFollowUps`, and so does the epilogue's check. The capped branch keeps `if !TurnCore<M>.usesFollowUps { break }`.
- **With follow-ups.** A busy machine schedules one `Task` where it scheduled two, and one flag test replaces two.

**Measured** with the follow-ups plan's §10 procedure, while holding the measurement lock:
- `perf stat -e instructions:u`, in a throwaway container from the pinned `swift:6.2.4-noble` image;
- base is the merge base, head is the PR head, both built `-c release` in that container, with `swift --version` recorded;
- 5 runs per cell and side, alternating, per-op = (n − the n = 0 run) / n;
- a regression is head's mean above base's by more than max(0.5 %, 3 × base's spread).

The cells:
- **Gated:** `emit`, `call` and `idle`, on the bench's machine (no follow-ups). They must not regress. `idle` is the control.
- **Recorded:** `follow-up` and `follow-up-join`, on the follow-up machine. They aren't gated, but a rise is explained in the PR.

The epilogue's check stays inline at its call site (`2026-11-21-a-feature-path-in-the-driver-costs-machines-that-do-not-use-it.md`).

## 4. Tests

**Witnesses.** A debug-only hook on the core records each `continueBatch` run and the steps between two runs: `jobRunsForTesting`, a log of `(job, step labels)`. The tests assert enqueue counts (`continuationJobs`) and job boundaries directly, not only the machine's log.

**Case 27** (`FollowUpTests.swift`, "the release budget exhausted with follow-ups due…", `maxReleasesPerBatch: 1`). From §2.2, the expected log is:

```
armed A, armed B                           (the script's step)
ran A, armed C, parked P1, ran B           (job 1: A's step ends key 1 and arms C; P1 is released; capped; B steps)
parked P2, ran C                           (job 2: P2 is released, capped again; C, captured at its start, steps)
parked P3                                  (job 3)
```

So P2 and C share a segment (job 2), P2 first. The hook's job log must show exactly three job runs after the script's segment, and `continuationJobs` must go up by 3. The exact lines are confirmed against a run before the assertion is fixed.

**Case 27b** (a gate's return that releases past the cap) is unchanged: the arm steps in the gate's own segment.

**`OrderedChecksTests:244`** keeps the same bound under the new counter name.

**The generated orders.** The comment at `GeneratedOrderTests.swift:12` (the drain "continues in a job of its own") is updated, and the budget-2 seeds cover the merged job.

New cases:
1. **Both reasons, one job.** A segment that is capped and leaves a follow-up due: `continuationJobs` goes up by 1, the job log shows one run, and in it the release steps before the follow-up.
2. **The capture.** A follow-up armed by a release inside the job isn't stepped in that job. The job log shows it in the next run.
3. **A job already pending.** A follow-up job is pending, and then, before it runs, another entry's segment is capped (a control send releasing past the cap). Still one job (`continuationJobs` up by 1 in all, one run in the job log), and it does both.
4. **The settlement point (§2.3).** A `.requests` waiter reached by a release in the job wakes after the job's captured follow-up stepped, with `true`.
5. **An empty job.** A control send runs a segment that takes the job's releases and consumes its captured follow-up before the job runs. The job runs, steps nothing, and the job log shows an empty run.

Mutants, each with the test that kills it:

| Mutant | Killed by |
|---|---|
| the follow-up capture removed from `continueBatch` | case 1 and case 27 (C never steps) |
| the guard dropped at the capped point (a second job scheduled while one is pending) | case 3 only: `continuationJobs` up by 2 and two runs in the job log. Case 1 doesn't kill it, because its segment schedules from the capped point once and the epilogue's guard then sees the flag. |
| the guard dropped at the epilogue | case 1 (two jobs for one segment) |
| the capture taken at the end of the job's segment instead of its start | case 2 |

## 5. Docs

- The "No order between the two jobs" bullet in `2026-11-20-turn-core-follow-ups.md` §3.3 gets a note that this plan supersedes it. Plans aren't rewritten.
- `docs/turns/README.md` and `.zh-TW.md`, and the DocC CoreConcepts page, describe `.afterBatch` as "in a new batch, as the actor's own job after the current one". They gain one sentence: the core's continuation is one job, which releases capped inputs and steps the follow-ups that were due when it started; other entries can run before it.
- `Values.swift`'s `.afterBatch` doc comment says the same in short.

## 6. Steps

One SwiftStateTurns PR (core path), in two commits:
1. the merged job, the flag, the counter rename, the job hook and the tests;
2. the docs.

The PR body carries the bench table (§3) with both SHAs and `swift --version`, and lists the rename under "Public API". It can land before or after #725. Whichever is second adds the lane's take to the same loop, and that loop is unchanged here.

## 7. Questions

Decided: Q1 = releases first (§2.1), Q2 = the plain rename with no alias (§2.4, the maintainer), Q3 = no 50-run case. None open.
