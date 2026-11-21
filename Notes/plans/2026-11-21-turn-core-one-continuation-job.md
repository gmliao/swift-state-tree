# Turn core: one continuation job for the drain and the follow-ups (#723)

**Status:** rev 1, plan only, for review. No code until Review's GO.

## 1. Today

Since #719, `TurnActor` can schedule two continuation jobs for one machine. Both are unstructured `Task { self.… }` on the actor (`Sources/SwiftStateTurns/TurnActor.swift`):

- **`continueDrain`** is scheduled by a segment that leaves a releasable key at `budget == 0` (`runSegment`, guarded by `core.drainScheduled`). Its segment releases parked inputs under a fresh budget. It never steps a follow-up: due follow-ups stay in `rt.dueFollowUps`.
- **`continueFollowUps`** is scheduled by a segment's epilogue when `rt.dueFollowUps` isn't empty (guarded by `core.followUpJobScheduled`). It moves the due follow-ups into `followUpsToStep`, in arm order, and runs a segment. That segment also releases parked inputs up to the cap, since releases aren't gated on `drainScheduled`.

Nothing orders the two jobs. When a capped segment schedules both, either may run first, so a batch's content depends on job order:
- The drain's segment may release inputs whose steps arm follow-ups. Those go to `dueFollowUps`, and a follow-ups job that runs after it takes them, so it steps more.
- The follow-ups job may release the inputs the drain was scheduled for, and the drain then finds less to do.

So the docs and the follow-ups plan carry a caveat (`2026-11-20-turn-core-follow-ups.md` §3.3, "No order between the two jobs"). Case 27 in `FollowUpTests.swift` asserts no order between those later jobs.

## 2. Design: one job, one flag, its content fixed at its start

- **One flag.** `core.drainScheduled` and `core.followUpJobScheduled` become one, `core.continuationScheduled`.
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
- **Two schedule points, one guard.** The capped branch of `runSegment` and the epilogue both schedule `continueBatch` only when `!core.continuationScheduled`. A segment that is both capped and leaves follow-ups due schedules one job.
- **`runSegment`'s loop is unchanged.** The order stays: products, abandoned, queued, releases (capped), follow-ups. #725's lane, if it lands first, adds its take after the products (that plan, §3.4).

### 2.1 What one job contains

The job takes the follow-ups that were due when it started, and releases parked inputs under a fresh budget. In the job's segment:
1. queued sends that arrived before it, as in any segment;
2. releases, at most `maxReleasesPerBatch`, in the runtime's release order;
3. the follow-ups taken at its start, in arm order, each one re-checked (consumed, ended or closed after the take: skipped, as today).

What this job's steps arm goes to `dueFollowUps`, and a capped release leaves the rest parked. Either way the epilogue schedules the next job. So a follow-up that keeps re-arming itself is still a chain of jobs, each yielding the actor (follow-ups plan §3.3).

**Releases before follow-ups.** That is the loop's order in every segment today, a capped one included, and keeping it means no segment changes. The other order (follow-ups first) would let a follow-up's step change what the releases find, within the same job. Both orders are deterministic, and the existing one has the tests behind it. Q1.

### 2.2 What becomes deterministic, and what doesn't

**Deterministic.** For a given sequence of actor entries (sends, calls, completions, timers, gate returns), the batches the core schedules for itself have fixed content. Each continuation job's content is a function of the core's state at the job's start, and there is at most one such job queued at a time.

**Not changed.** The order between the core's own job and other entries that are already queued on the actor (another task's `send`, an effect's result) still depends on the executor. That is Swift's order between tasks, and the core can't fix it. The generated-orders harness and replay already treat those entries as the input sequence.

So the caveat goes from "two jobs, unordered" to "the core's continuation is one job; other entries interleave with it as with any job".

### 2.3 Counters

`counters.drainContinuations` counts jobs a capped segment schedules today. It becomes `counters.continuationJobs`, counting every `continueBatch` scheduled, for either reason.
- The old name stays as a deprecated alias for one release. `TurnCore.Counters` is public.
- The test at `OrderedChecksTests.swift:244` (`drainContinuations >= 4`) keeps its bound under the new name.

Whether a separate counter of follow-up-only jobs is worth keeping is Q2. Recommended: no, as nothing reads one today.

## 3. Cost (#621)

- **Without follow-ups (`FollowUpSlot == Never`).** `continueBatch` is `continueDrain` with a renamed flag: the follow-up move folds away under `usesFollowUps`, and so does the epilogue's check. The capped branch keeps `if !TurnCore<M>.usesFollowUps { break }`.
- **With follow-ups.** A busy machine schedules one `Task` where it scheduled two, and one flag test replaces two.

**Measured** with the follow-ups plan's §10 procedure, while holding the measurement lock:
- `perf stat -e instructions:u`, in a throwaway container from the pinned `swift:6.2.4-noble` image;
- base is the merge base, head is the PR head, both built `-c release` in that container, with `swift --version` recorded;
- 5 runs per cell and side, alternating, per-op = (n − the n = 0 run) / n;
- a regression is head's mean above base's by more than max(0.5 %, 3 × base's spread).

The cells:
- **Gated:** `emit`, `call` and `idle`, on the bench's machine (no follow-ups). They must not regress. `idle` is the control.
- **Recorded:** `follow-up` and `follow-up-join`, on the follow-up machine. They aren't gated, but a rise is explained in the PR.

The lesson `2026-11-21-a-feature-path-in-the-driver-costs-machines-that-do-not-use-it.md` applies: the epilogue's check stays inline at its call site.

## 4. Tests

The tests that pin today's behavior, and what each becomes:
- **Case 27** (`FollowUpTests.swift`, "the release budget exhausted with follow-ups due…"). It now asserts the order it couldn't: P2's release and C's step are in the same job, P2 first (§2.1), then P3 in the job after. The expected log is `ran A, parked P1, ran B, parked P2, ran C, parked P3` (to be confirmed against the run before the assertion is fixed), and the per-segment check (`f.segments.allSatisfy { $0 <= 1 }`) stays.
- **Case 27b** (a gate's return that releases past the cap) is unchanged. The arm steps in the gate's own segment, as today.
- **`OrderedChecksTests` line 244.** Same bound, new counter name.
- **The generated orders.** Their model doesn't name the two jobs (`GeneratedOrderTests.swift:12`, the drain "continues in a job of its own"). The comment is updated, and the budget-2 seeds cover the merged job.

New cases:
1. One job for both reasons: a segment that is capped and leaves a follow-up due schedules one job (`continuationJobs` up by 1), and that job releases, then steps the follow-up.
2. The snapshot: a follow-up armed by a release in the job is not stepped in that job. It steps in the next one.
3. A job scheduled for follow-ups only, while another entry's segment gets capped before it runs: still one job, which does both.
4. Determinism: the same script run 50 times on one actor gives the same log each time. It is bounded, and it passes on today's code only by chance, so it is evidence rather than a gate. Q3 asks whether to keep it.

Mutants:
- the follow-up move removed from `continueBatch` (case 1, case 27);
- the guard dropped at the capped point, so two jobs are scheduled (case 1's count);
- the follow-up snapshot taken at the end of the job instead of the start (case 2).

## 5. Docs

- The "No order between the two jobs" bullet in `2026-11-20-turn-core-follow-ups.md` §3.3 gets a note that this plan supersedes it. Plans aren't rewritten.
- `docs/turns/README.md` and `.zh-TW.md`, and the DocC CoreConcepts page, where `.afterBatch` is described ("in a new batch, as the actor's own job after the current one"), gain one sentence: the core's continuation is one job, which releases capped inputs and then steps the follow-ups due when it started.
- `Values.swift`'s `.afterBatch` doc comment says the same in short.

## 6. Steps

One SwiftStateTurns PR (core path), in two commits:
1. the merged job, the flag, the counter and the tests;
2. the docs.

The PR body carries the bench table (§3) with both SHAs and `swift --version`. It can land before or after #725. Whichever is second adds the lane's take to the same loop, and that loop is unchanged here.

## 7. Questions for Review

- **Q1.** Within one job, releases before the follow-ups taken at its start (today's loop order), or follow-ups first? Recommended: releases first (§2.1).
- **Q2.** One counter, `continuationJobs`, with `drainContinuations` deprecated, or keep a separate follow-up job counter? Recommended: one (§2.3).
- **Q3.** Keep the 50-run determinism case (§4, new case 4), or rely on the exact-order assertion in case 27? Recommended: drop it, keep case 27.
